using MocosSimTemporalAdjustment

if isempty(ARGS) || length(ARGS) > 3 || (length(ARGS) == 2 && ARGS[2] != "--check") ||
   (length(ARGS) == 3 && !(ARGS[2] in ("--resume", "--warm-start")))
    error("Usage: julia --project=. scripts/fit_launcher.jl FIT.toml [--check | --resume CHECKPOINT.jls | --warm-start CHECKPOINT.jls]")
end

if length(ARGS) == 2
    fit = load_fit_config(ARGS[1])
    println("Configuration valid; no simulation started.")
    println("Horizons: ", fit.options.horizons)
    println("Parameters: ", join(string.(getfield.(fit.parameters, :name)), ", "))
    println("Score tolerance: ", fit.options.score_tolerance)
    println("Candidate workers: ", fit.execution.max_workers)
    println("Threads per launcher: ", fit.evaluator.config.threads)
    println("Temporal fitting: ", isempty(fit.temporal) ? "disabled" : "enabled")
    for t in fit.temporal, day in fit.options.horizons
        i = MocosSimTemporalAdjustment._temporal_index(t, day)
        println("Day $day: $(t.name) interval_values[$i]")
    end
else
    finalists = fit_launcher(ARGS[1];
        resume_from=length(ARGS) == 3 && ARGS[2] == "--resume" ? ARGS[3] : nothing,
        warm_start_from=length(ARGS) == 3 && ARGS[2] == "--warm-start" ? ARGS[3] : nothing)
    println("Best score: ", first(finalists).score, " at day ", first(finalists).horizon)
end
