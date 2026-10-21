# MocosSimTemporalAdjustment

Fit MocosSim parameters to progressively longer day prefixes, keeping several
plausible candidates at each step. Uses a bounded candidate queue and invokes
MocosSimLauncher in separate Julia processes. Tested with Julia **1.7.0** and
launcher branch **`mbodych/class_and_school`**, revision
`4c0149d0f3a5037acd51a4c9f08e510e4414e920`.

## Run a small test locally first

Use a Julia 1.7.0 executable for every command below (`julia --version`).
These commands assume sibling repository directories, starting in their parent:

```sh
git clone --branch mbodych/class_and_school https://github.com/marcinb-pwr/MocosSimLauncher.git
# MocosSimTemporalAdjustment should contain this integration's changes.
julia --project=MocosSimLauncher -e 'using Pkg; Pkg.instantiate()'
julia --project=MocosSimTemporalAdjustment -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
julia --project=MocosSimTemporalAdjustment MocosSimTemporalAdjustment/scripts/smoke_launcher.jl ./MocosSimLauncher
```

The last command generates a **six-person synthetic population**, a seed JSON,
observations, and an editable `fit.toml`. It runs **four real launcher processes**
at horizons of 2 and 4 days, fitting school/class parameters. No production data
or environment variables are needed. The first invocation can take longer while
Julia compiles dependencies. Use the launcher's checked-in Manifest; its MocosSim
dependency is not a registered General package.

Expected last lines:

```text
PASS: real launcher integration; 4/4 runs completed; best score = ...
Editable profile: /.../fit.toml
Best launcher config: /.../runs/best_config.json
```

This tests wiring, not scientific parameter recovery. Synthetic detections are
zero and several parameter settings may fit equally well. Outputs are retained
in the temporary directory printed by the command. To choose a persistent
location, append a **new** directory:

```sh
julia --project=MocosSimTemporalAdjustment MocosSimTemporalAdjustment/scripts/smoke_launcher.jl ./MocosSimLauncher ./smoke-output
```

## Fit your own data

If a smoke test reports that `MocosSim` is not installed, instantiate the
**launcher** project with the same Julia executable and `JULIA_DEPOT_PATH`:

```sh
julia --project=/absolute/path/to/MocosSimLauncher -e 'using Pkg; Pkg.instantiate(); using MocosSimLauncher'
```

Instantiating the optimizer does not install the launcher's separate dependencies.
The smoke test checks that the launcher loads before starting the search. Runtime
failures include the evaluation report path and launcher stderr in the error.
Run the relative commands below from the repository root, not `experiments/`.

From the MocosSimTemporalAdjustment repository:

```sh
export MOCOSSIM_LAUNCHER_DIR=/absolute/path/to/MocosSimLauncher
export MOCOSSIM_SEED_CONFIG=/absolute/path/to/working-launcher-config.json
export MOCOSSIM_GT_DIR=/absolute/path/to/observations

# Edit experiments/saxony_baseline.toml before running.
julia --project=. scripts/fit_launcher.jl experiments/saxony_baseline.toml --check
julia --project=. scripts/fit_launcher.jl experiments/saxony_baseline.toml
```

`--check` validates the profile, mappings, input paths and observations without
starting a simulation or creating output directories. It does not instantiate
the launcher or validate the contents of its population file. In the TOML file,
`${VARIABLE}` placeholders are expanded in paths. Literal absolute paths work
too. Other paths are relative to that TOML file. The launcher Julia executable
defaults to the same executable running the optimizer; override `julia_bin` when
needed. Typographical errors in configuration keys fail preflight.

Input paths **inside the seed JSON** are resolved relative to the seed JSON's
directory. If the working seed was authored relative to the launcher checkout,
set `launcher.input_base_dir` to that checkout. Population, contact-matrix,
immunity-event and other `*_path` inputs must exist. Each simulation runs with
the launcher checkout as its working directory.

Observations are simple unquoted CSVs:

```csv
day,value
1,10
2,12
4,15
```

Days are one-based: day 1 represents simulation times `[0, 1)`. Gaps, blank
values, `NA`, `missing` and `-1` denote missing observations; they do not shift
later days and are never converted to zero. Other negative/nonfinite counts,
duplicate days and unordered days are errors. You must align the simulation's
day zero with the observations yourself. `daily_hospitalizations` is daily
**admissions**, not hospital occupancy.

## Configure day steps, tolerance and search effort

All of these settings go in `[search]`:

| Setting | Meaning | Example |
| --- | --- | --- |
| `start_day` | First prefix to fit | `14` |
| `step_days` | Number of days added at each stage | `14` |
| `end_day` | Last fitting day; always included | `84` |
| `horizons` | Explicit alternative to the three day settings | `[14, 28, 56, 84]` |
| `score_tolerance` | Acceptable combined normalized error at each stage; omit to disable | `0.20` |
| `require_tolerance` | Stop after saving a checkpoint if the stage misses the tolerance | `true` |
| `max_rounds_per_horizon` | Maximum refinement rounds at each stage | `5` |
| `survivors` | Number of candidate parameter sets retained | `12` |
| `random_starts` | Random proposals in the first round; later rounds add one quarter, at least one | `48` |
| `trials_per_survivor` | Mutations per parent in later rounds/stages | `8` |
| `repetitions` | Separate launcher invocations per candidate | `3` |
| `initial_radius` | Gaussian mutation standard deviation in normalized parameter space | `0.20` |
| `radius_decay` | Multiplier applied after each completed stage | `0.75` |
| `min_separation` | Preferred Euclidean distance between survivors in normalized space | `0.03` |
| `seed` | Optimizer RNG seed | `42` |
| `checkpoint_dir` | Directory for stage checkpoints | `"../runs/fit/checkpoints"` |

A stage stops refining as soon as its **best candidate** meets
`score_tolerance`; otherwise it uses its round budget. With `require_tolerance =
true`, an unmet target stops the search before extending the horizon. Set it to
`false` to continue on budget exhaustion and record the unmet target. Tolerance
does not require every survivor or every metric to pass independently. Without
`score_tolerance`, all configured rounds run. The Julia API defaults to one
round per horizon, no score threshold, and one repetition.

The radius is a parameter step, **not a fit tolerance**. For linear bounds
`[0.05, 0.30]`, radius `0.20` gives a mutation standard deviation of `0.05` in
that parameter before boundary clipping. `scale = "log"` uses log-space bounds.
The radius decays once per stage, with a floor of `1e-4`.

Each later round evaluates up to `survivors * (1 + trials_per_survivor) +
max(1, random_starts ÷ 4)` proposals, times `repetitions`. Start small when
checking your machine; the example's larger settings can launch thousands of
simulations. `execution.max_workers` controls concurrent candidate evaluations;
`launcher.threads` controls threads **inside each launcher process**.

## Run candidates concurrently

For the 8-core Intel i9 / 64 GB local machine, start with this configuration:

```toml
[launcher]
# Other launcher paths/settings as before.
threads = 1
num_trajectories = 1

[execution]
max_workers = 4
progress = true
progress_interval_seconds = 30.0
```

At most four candidates are evaluated at once. Each worker runs its candidate's
three repetitions sequentially, then takes the next candidate. Simulations run
in independent processes and isolated output directories. Scoring runs in the
optimizer as each simulation finishes. Tasks share a single scheduler thread
for scoring/JLD2 I/O; no multithreaded access to JLD2 is introduced. This queue
overlaps external processes and waiting; custom CPU-only Julia evaluators do
not become CPU-parallel just by increasing the worker count.

The launcher parallelizes trajectories, not the event loop within a single
trajectory. With `num_trajectories = 1`, extra launcher threads allocate unused
simulation states. One thread per process plus several candidate workers uses
the machine more efficiently. Each worker still needs memory for its population,
simulation state and events; memory usage grows with the worker limit. The
default worker limit is one when `[execution]` is omitted. The supplied Saxony
profile explicitly uses four workers. No `julia --threads=4` flag is required
for the optimizer process.

You will see progress such as:

```text
day=42 round=2/5 workers=4 candidates=120 runs=360
day=42 round=2/5 completed=60/360 failed=0 elapsed_minutes=12.0 eta_minutes=60.0
```

Counts refer to individual evaluator calls (one launcher process per repetition),
including failed runs. ETA is an estimate for the current round. It updates on
completions, so a long run can leave the display unchanged. The queue preserves
proposal ordering and seed assignment; results are selected after the entire
round, using the same rules as sequential execution. It changes wall time, not
the number of candidate simulations. Every invocation still starts a fresh
launcher process, so Julia startup and compilation costs remain.

Execution settings are separate from the serialized `SearchOptions`: existing
stage checkpoints remain readable, and the worker count may change on resume.
The current process cannot switch to the new queue live. To preserve a long
running fit, let the current stage complete, stop before running additional
stages if practical, and restart with `--resume` from its accepted checkpoint:

```sh
# From the repository root, after the current stage has saved its checkpoint.
git pull --ff-only
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. scripts/fit_launcher.jl experiments/saxony_baseline.toml --resume runs/launcher-fit/checkpoints/stage_003_day_42.jls
```

Keep the existing `[search]`, parameters, observations, seed configuration and
model version unchanged when resuming. Preserve your own TOML edits when pulling
the updated sample profile. Mid-stage progress is not checkpointed; stopping
during day 42 requires repeating day 42 from the day-28 checkpoint. An unmet
mandatory-tolerance stage cannot be skipped via resume. Ctrl-C/error handling
stops scheduling new candidates and terminates active launcher children.

In the Julia API, pass `execution=ExecutionOptions(max_workers=4, progress=true)`
to `temporal_search`. The API is quiet by default; TOML-driven fits enable
progress by default.

`execution.batch_size` is an alias for `execution.max_workers`. Use either name,
not both. For example, `[execution] batch_size = 8` permits eight concurrent
candidate simulations. This setting belongs in the **fit TOML**, since the
optimizer owns the queue. `launcher.threads = 1` still controls each simulation.

## Fit only the current temporal interval

`experiments/saxony_temporal.toml` extends the scalar Saxony profile with all
three modulation vectors and eight candidate workers. The scalar-only profile
is retained so existing experiments can continue with exact resume.

```toml
[[temporal_parameters]]
path = "infection_modulation"
lower = 0.05
upper = 1.50

[[temporal_parameters]]
path = "mild_detection_modulation"
lower = 0.05
upper = 1.00

[[temporal_parameters]]
path = "tracing_modulation"
lower = 0.05
upper = 1.50
```

Bounds are editable search choices, not calibrated confidence intervals. All
baseline entries must be within their vector's bounds. The vectors and their
breakpoints come from the launcher's seed JSON; they are not replaced with a new
grid. The modulation must be `IntervalsModulations`, with `weight_days=1` and
both case/death weights zero, so that its input is the simulation day.

MocosSim uses `searchsortedlast(interval_times, day) + 1` (one-based indexing):

| Horizon | Active interval with 30-day breakpoints | Fitted vector entry |
| --- | --- | --- |
| 14, 28 | `[0,30)` | `interval_values[1]` |
| 42, 56 | `[30,60)` | `interval_values[2]` |
| 60, 70, 84 | `[60,90)` | `interval_values[3]` |
| 90 | `[90,120)` | `interval_values[4]` |

Only the interval containing the **current horizon** is changed, even if a stage
spans several intervals. At an exact boundary the new interval is active,
matching the simulator. Earlier entries remain frozen within each survivor's
history; future entries retain baseline values until their interval becomes
active. A new random proposal inherits one survivor's history and randomizes
only its active temporal entries and scalar parameters. Mutations also change
only active entries and scalars. Retained parents are re-evaluated as before.
The three vectors can use different breakpoints. Diversity is measured over the
currently fitted entries and scalars. The score still covers the full prefix
from day zero, and each simulation reruns that prefix.

School, class, and age coupling keep their existing mutation/radius rules. They
are global parameters, so changing them can affect earlier days even when older
temporal entries are frozen.

Start a fresh temporal experiment with:

```sh
julia --project=. scripts/fit_launcher.jl experiments/saxony_temporal.toml --check
julia --project=. scripts/fit_launcher.jl experiments/saxony_temporal.toml
```

To carry the uploaded scalar-only day-42 survivors into a **new experiment**:

```sh
# The new profile writes to runs/saxony-temporal, preserving the original fit.
julia --project=. scripts/fit_launcher.jl experiments/saxony_temporal.toml \
  --warm-start runs/launcher-fit/checkpoints/stage_003_day_42.jls
```

Warm start preserves scalar survivor values, the optimizer RNG and next radius,
then starts at the next horizon (day 56 in this example). Temporal values begin
with the current seed JSON's baseline; earlier intervals were not retrospectively
fitted. Old scores are not reused for subsequent stages. Scalar parameter
definitions and search settings must match the checkpoint, except output paths
and an optional extension of the unfinished horizon schedule. The completed
horizon prefix must match. Use separate output/checkpoint directories to retain
the previous experiment. Changing the baseline also makes this a new experiment.

For later continuations of that temporal experiment, use `--resume`, not
`--warm-start`. Exact resume checks temporal definitions, baseline vector values
and breakpoints in addition to the existing parameter/search checks. It assumes
the same launcher/model, observations and remaining seed configuration.

### Measure memory for 4, 6 and 8 workers

Use a previously generated `config_candidate.json` containing absolute input
paths. The Python 3 helper needs no extra packages and works on macOS and Linux:

```sh
python3 scripts/benchmark_launcher_memory.py runs/launcher-fit/day_42_seed_EXAMPLE/config_candidate.json \
  --project ./MocosSimLauncher --workers 4 6 8 --days 42 \
  --limit-gib 48 --output runs/memory-benchmark
```

Replace the example candidate directory with an actual run directory. Run this
after stopping the fit so competing simulations do not distort the comparison.
The output directory must be new. Use `--julia /path/to/julia` if needed.
Each batch runs that many simulations with one thread and one trajectory per
process, preserving the candidate's parameters and using consecutive seeds.
JSON/CSV reports include peak aggregate RSS, peak individual RSS, elapsed time,
and exit codes. The total is the largest simultaneous sum sampled every 0.25 s,
not the sum of individual historical peaks. Shared pages are counted per process;
this can overestimate physical RAM. The optimizer, other applications and OS
memory are excluded. The default 48 GiB stop threshold leaves headroom on a
64 GB machine; it is a sampled guard, not a hard memory limit. A stopped/failed
batch is incomplete and prevents larger batches from starting. Longer horizons
and different epidemic trajectories can have higher peaks, so these results
are measurements for the tested inputs, not an upper bound for all fits.

## How mutations work

For each retained parent, every fitted parameter is perturbed independently:

```text
u = (value - lower) / (upper - lower)
u_new = clamp(u + radius * randn(), 0, 1)
value_new = lower + u_new * (upper - lower)
```

Log-scaled parameters use the corresponding normalization and inverse mapping in
log space. One mutation changes all fitted coordinates, rather than choosing one
coordinate. There is no crossover. The parent itself is also proposed again,
along with fresh random candidates. Each parent generates
`trials_per_survivor` mutations.

With `initial_radius=0.20` and `radius_decay=0.75`, the radius is `0.20`, `0.15`,
`0.1125`, ... at successive horizons. It is fixed across rounds within a stage.
The first round at the first horizon generates random proposals (and any
explicit initial guesses) without mutations. Clipping can produce identical
candidates at a boundary; the current implementation does not deduplicate them
or cache repeated parent evaluations.

## Score and parameter mappings

For each metric and trajectory, the built-in objective computes RMSE divided by
`max(mean(abs(observed)), 1)` over the observed days of the current prefix. An
explicit metric `scale` replaces that denominator. Metric scores are averaged
over trajectories and combined as `sum(weight * score) / sum(weight)`.

`[scoring].smoothing_days = 7` applies the same trailing average to observations
and predictions; `1` disables smoothing. Windows containing missing observations
are skipped as a whole, preserving day identity. No values after the stage's
horizon affect the score or normalization. A tolerance of `0.20` means combined
normalized RMSE at most 0.20; it is not a per-day 20% error bound. Changing
weights, smoothing or scales changes its interpretation. Keep a separate test
period outside `end_day` for evaluating generalization.

Each `[[parameters]]` maps a name and bounds to a numeric JSON `path`, e.g.
`transmission_probabilities.school`, `transmission_probabilities.class`, or
`infection_modulation.params.interval_values[1]`. Array indices are **one-based**.
Use `integer = true` for integer-valued launcher fields such as
`imported_cases[1].params.num_infections`. Only the optional school/class keys
are inserted automatically; other paths must already exist. Bound choices in
the example are illustrative, not recommended scientific priors.

This implementation optimizes a fixed parameter list. It does not automatically
unlock additional modulation intervals as time increases. Start with scalars;
explicitly indexed interval parameters are supported, but future-only intervals
are not identifiable from earlier horizons.

`[[metrics]]` can reference any daily output metric from this branch, including
`daily_student_detections` and `daily_age_05_14_detections`. Each selected metric
must exist in every trajectory and have usable observations. There are no
implicit CSV filename aliases: `file` always names the actual source.

## Outputs, failures and resume

For the Saxony `UnderObservation` quarantine assertion or `Healthy` forward
tracing assertion, see [the model regression fix](docs/saxony-reinfection-fix.md).
The fix must be installed in the launcher environment.

Each adapter invocation retains its effective `config_candidate.json`,
`output_daily.jld2`, `stdout.log`, `stderr.log` and
`evaluation.json`. The adapter sets `stop_simulation_time`, `params_seed`,
`num_trajectories` and a zero `window_start`; the seed JSON is never modified.
It starts from day zero for each candidate, without simulator-state reuse.

Summary output is disabled by default: at the tested launcher revision its
summary writer accesses `state.forest.inedges`, which the pinned MocosSim's
`RobinForest` does not provide. Daily output works independently and supplies
the trajectory validation and scoring. Set `launcher.write_summary = true`
only with a compatible summary writer; then the adapter also checks the summary.

Nonzero process exits, timeouts, missing/malformed output, missing trajectories,
short series and nonfinite/negative predictions fail the invocation. Short
series are not silently padded: this may reject a genuinely extinct epidemic,
which needs an explicit termination/padding policy before using this adapter
for that case. Every repetition must succeed; otherwise the candidate score is
`Inf`. Successful repetition scores are combined using their median. Candidates
at a stage share replicate seeds for paired comparisons; changing `params_seed`
does not by itself establish independence of all simulator RNG streams.

The adapter kills a timed-out launcher process and records the error. Its
`launcher.timeout_seconds` includes Julia startup and compilation time. The
launcher must already have its dependencies installed.

A successful fit writes `best_config.json` (directly runnable with the launcher)
and `fit_result.json`. The exported configuration uses the first stage replicate
seed, which is recorded in the result; the fit score is the median across all
replicates, not a claim about that single seed.

Stage checkpoints include sorted survivors, all replicate scores, paired seeds,
RNG state, radius, number of rounds and tolerance status. Resume **after an
accepted stage** with identical search options and parameters:

```sh
julia --project=. scripts/fit_launcher.jl experiments/saxony_baseline.toml --resume runs/launcher-fit/checkpoints/stage_003_day_42.jls
```

Keep launcher version, seed JSON, observations and scoring settings unchanged
for equivalent results. Exact resume covers optimizer state between stages; an
interrupted stage is recomputed. Checkpoints from the earlier implementation
cannot be resumed exactly. A failed mandatory-tolerance stage cannot be skipped
via resume; adjust the configuration and start a fresh run instead.

## Custom evaluators

The original generic API remains available:

```julia
using MocosSimTemporalAdjustment
parameters = [Parameter(:rate, 0.01, 1.0; scale=:log)]
evaluator(values, horizon, seed) = (values[:rate] - 0.3)^2
options = SearchOptions(horizons=day_horizons(start_day=7, step_days=7, end_day=28),
    score_tolerance=0.01, max_rounds_per_horizon=5, checkpoint_dir="runs/custom")
finalists = temporal_search(evaluator, parameters; options=options)
```

Custom evaluator exceptions propagate; the launcher adapter converts operational
simulation failures into logged `Inf` results. For the Julia API, construct
`LauncherConfig`, `MetricTarget`, and `LauncherEvaluator` directly, or call
`load_fit_config` / `fit_launcher` with a TOML profile.
