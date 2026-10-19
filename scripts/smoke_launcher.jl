using MocosSimTemporalAdjustment
using TOML
using JSON

length(ARGS) in (1, 2) || error("Usage: julia --project=. scripts/smoke_launcher.jl LAUNCHER_DIR [OUTPUT_DIR]")
launcher_dir = abspath(ARGS[1])
isfile(joinpath(launcher_dir, "advanced_cli.jl")) || error("No advanced_cli.jl in $launcher_dir")
directory = if length(ARGS) == 2
    path = abspath(ARGS[2])
    ispath(path) && error("Choose a new output directory: $path already exists")
    mkpath(path)
    path
else
    mktempdir(; prefix="mocossim_smoke_", cleanup=false)
end
println("Smoke test output: ", directory)
println("Julia version: ", VERSION)
println("Generating a six-person population using the launcher environment...")
julia = joinpath(Sys.BINDIR, Base.julia_exename())
fixture_script = joinpath(@__DIR__, "make_smoke_inputs.jl")
run(`$julia --startup-file=no --project=$launcher_dir $fixture_script $directory`)
profile = Dict{String,Any}(
    "launcher" => Dict("project_dir" => launcher_dir, "base_config" => "base.json",
        "output_dir" => "runs", "julia_bin" => julia, "threads" => 1,
        "num_trajectories" => 1, "timeout_seconds" => 180.0),
    "search" => Dict("start_day" => 2, "step_days" => 2, "end_day" => 4,
        "survivors" => 1, "random_starts" => 1, "trials_per_survivor" => 1,
        "repetitions" => 1, "max_rounds_per_horizon" => 1,
        "score_tolerance" => 0.20, "require_tolerance" => true, "seed" => 42),
    "scoring" => Dict("smoothing_days" => 1),
    "parameters" => [Dict("name" => "school", "path" => "transmission_probabilities.school",
                           "lower" => 0.0, "upper" => 0.01),
                       Dict("name" => "class", "path" => "transmission_probabilities.class",
                           "lower" => 0.0, "upper" => 0.01)],
    "metrics" => [Dict("name" => "daily_detections", "file" => "detections.csv", "weight" => 1.0)],
)
path = joinpath(directory, "fit.toml")
open(path, "w") do io
    TOML.print(io, profile)
end
println("Running two horizons (2 and 4 days), four real launcher invocations...")
finalists = fit_launcher(path)
best = first(finalists)
@assert best.horizon == 4 && isfinite(best.score)
reports = [JSON.parsefile(joinpath(root, "evaluation.json"))
           for (root, _, files) in walkdir(joinpath(directory, "runs")) if "evaluation.json" in files]
@assert length(reports) == 4
@assert all(report["status"] == "completed" for report in reports)
@assert isfile(joinpath(directory, "runs", "best_config.json"))
println("PASS: real launcher integration; 4/4 runs completed; best score = ", best.score)
println("Editable profile: ", path)
println("Best launcher config: ", joinpath(directory, "runs", "best_config.json"))
