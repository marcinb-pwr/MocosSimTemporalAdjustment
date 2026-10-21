#!/usr/bin/env python3
"""Measure aggregate launcher RSS on macOS/Linux; requires only Python 3.

Runs independent copies of one candidate, with one trajectory/thread each.
RSS includes shared pages in every process; it is a conservative RAM estimate.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def process_memory(pids):
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss="], text=True)
    processes = [tuple(map(int, row.split())) for row in rows.splitlines()]
    family = set(pids)
    while True:
        children = {pid for pid, parent, _ in processes if parent in family}
        if children <= family:
            break
        family.update(children)
    return [rss * 1024 for pid, _, rss in processes if pid in family]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path, help="A launcher JSON with absolute input paths")
    parser.add_argument("--project", type=Path, required=True, help="Launcher Julia project")
    parser.add_argument("--cli", type=Path, help="Defaults to PROJECT/advanced_cli.jl")
    parser.add_argument("--julia", default="julia")
    parser.add_argument("--workers", type=int, nargs="+", default=[4, 6, 8])
    parser.add_argument("--days", type=int, default=42)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit-gib", type=float, default=48,
                        help="Stop batch if sampled aggregate RSS exceeds this (default 48)")
    args = parser.parse_args()
    if min(args.workers) < 1 or args.days < 1 or args.limit_gib <= 0:
        parser.error("workers, days, and limit must be positive")
    args.output.mkdir(parents=True, exist_ok=False)
    project = args.project.resolve()
    cli = (args.cli or project / "advanced_cli.jl").resolve()
    base = json.loads(args.config.read_text())
    results = []
    for count in args.workers:
        processes, logs = [], []
        peak = individual_peak = 0
        status = "completed"
        started = time.monotonic()
        try:
            for index in range(count):
                directory = args.output / f"workers_{count}" / f"run_{index + 1}"
                directory.mkdir(parents=True)
                config = dict(base, stop_simulation_time=args.days, num_trajectories=1,
                              params_seed=base.get("params_seed", 42) + index)
                config_path = directory / "config.json"
                config_path.write_text(json.dumps(config, indent=2))
                log = (directory / "launcher.log").open("w")
                logs.append(log)
                processes.append(subprocess.Popen([
                    args.julia, "--startup-file=no", f"--project={project}", "--threads=1",
                    str(cli), str(config_path.resolve()), "--output-daily",
                    str((directory / "output_daily.jld2").resolve()),
                ], cwd=project, stdout=log, stderr=subprocess.STDOUT, start_new_session=True))
            while True:
                memory = process_memory([p.pid for p in processes])
                peak = max(peak, sum(memory))
                individual_peak = max(individual_peak, max(memory, default=0))
                if sum(memory) > args.limit_gib * 2**30:
                    status = "memory_limit"
                    break
                if all(p.poll() is not None for p in processes):
                    break
                time.sleep(0.25)
        finally:
            for process in processes:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            for log in logs:
                log.close()
        codes = [p.returncode for p in processes]
        if status == "completed" and any(codes):
            status = "failed"
        result = dict(workers=count, days=args.days, peak_total_rss_gib=peak / 2**30,
                      peak_individual_rss_gib=individual_peak / 2**30,
                      elapsed_seconds=time.monotonic() - started,
                      status=status, exit_codes=codes)
        results.append(result)
        (args.output / "results.json").write_text(json.dumps(results, indent=2))
        with (args.output / "results.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(result))
            writer.writeheader()
            writer.writerows(results)
        print(json.dumps(result), flush=True)
        if status != "completed":
            break


if __name__ == "__main__":
    main()
