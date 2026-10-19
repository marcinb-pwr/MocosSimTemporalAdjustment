using MocosSimTemporalAdjustment

if isempty(ARGS) || length(ARGS) > 3 || (length(ARGS) == 2 && ARGS[2] != "--check") ||
   (length(ARGS) == 3 && ARGS[2] != "--resume")
    error("Usage: julia --project=. scripts/fit_launcher.jl FIT.toml [--check | --resume CHECKPOINT.jls]")
end

if length(ARGS) == 2
    fit = load_fit_config(ARGS[1])
    println("Configuration valid; no simulation started.")
    println("Horizons: ", fit.options.horizons)
    println("Parameters: ", join(string.(getfield.(fit.parameters, :name)), ", "))
    println("Score tolerance: ", fit.options.score_tolerance)
else
    finalists = fit_launcher(ARGS[1]; resume_from=length(ARGS) == 3 ? ARGS[3] : nothing)
    println("Best score: ", first(finalists).score, " at day ", first(finalists).horizon)
end
