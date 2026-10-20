using JSON
using JLD2
using TOML

const MTA = MocosSimTemporalAdjustment

@testset "day increments, tolerance, failure and resume" begin
    @test day_horizons(start_day=3, step_days=3, end_day=8) == [3, 6, 8]
    @test_throws ArgumentError day_horizons(step_days=0)
    parameters = [Parameter(:x, 0, 1)]
    for options in (SearchOptions(horizons=[2, 2]), SearchOptions(initial_radius=NaN),
                    SearchOptions(score_tolerance=-1.0), SearchOptions(max_rounds_per_horizon=0))
        @test_throws ArgumentError temporal_search((args...) -> 0, parameters; options=options)
    end
    # Diversity fallback must not return an out-of-order archive or too many entries.
    candidates = [Candidate(Dict(:x=>x), score, 2, [score]) for (x, score) in [(0.0,0.0), (0.01,1.0), (1.0,2.0)]]
    @test getfield.(MTA._select(candidates, 3, 0.5, parameters), :score) == [0.0, 1.0, 2.0]
    @test length(MTA._select(candidates, 1, 0.5, parameters)) == 1
    scores = [0.1, Inf, 0.2]
    candidate = MTA._evaluate((args...) -> popfirst!(scores), Dict(:x=>0.5), 2, [1,2,3])
    @test isinf(candidate.score)
    @test candidate.replicate_scores == [0.1, Inf, 0.2]
    mktempdir() do directory
        options = SearchOptions(horizons=[2], random_starts=1, survivors=1,
            max_rounds_per_horizon=3, score_tolerance=0.2, checkpoint_dir=directory)
        calls = Ref(0)
        evaluator = (args...) -> (calls[] += 1; 0.1)
        temporal_search(evaluator, parameters; options=options)
        @test calls[] == 1
        impossible = (args...) -> 0.3
        @test_throws ErrorException temporal_search(impossible, parameters; options=options)
        saved = load_checkpoint(joinpath(directory, "stage_001_day_2.jls"))
        @test !saved.accepted && saved.rounds == 3
        @test_throws ArgumentError temporal_search(impossible, parameters; options=options,
            resume_from=joinpath(directory, "stage_001_day_2.jls"))
    end
    mktempdir() do directory
        options = SearchOptions(horizons=[2,4,6], random_starts=4, survivors=2,
            max_rounds_per_horizon=2, repetitions=2, seed=10, checkpoint_dir=directory)
        evaluator = (v,h,s) -> (v[:x] - 0.3)^2 + (s % 7) / 1000
        full = temporal_search(evaluator, parameters; options=options)
        resumed = temporal_search(evaluator, parameters; options=options,
            resume_from=joinpath(directory, "stage_001_day_2.jls"))
        @test getfield.(resumed, :values) == getfield.(full, :values)
        @test getfield.(resumed, :replicate_scores) == getfield.(full, :replicate_scores)
    end
end

function write_daily(path, values; metric="daily_detections", count=1)
    jldopen(path, "w"; compress=true) do file
        for id in 1:count
            group = JLD2.Group(file, string(id))
            group[metric] = values
        end
    end
end

@testset "index-preserving scoring and output validation" begin
    mktempdir() do directory
        csv = joinpath(directory, "gt.csv")
        write(csv, "day,value\n2,2\n3,-1\n4,4\n")
        @test isequal(load_observations(csv), [missing, 2.0, missing, 4.0])
        target = MetricTarget("daily_detections", load_observations(csv))
        path = joinpath(directory, "daily.jld2")
        write_daily(path, [99.,2.,99.,4.,999.])
        result = score_daily(path, [target], 4; smoothing_days=1)
        @test result.score == 0
        @test result.components[target.name]["days"] == [2,4]
        # Values after the fitting horizon must never influence the score or its scale.
        target2 = MetricTarget("daily_detections", [1.,2.,9999.]; scale=1.)
        write_daily(path, [1.,4.,-999.])
        @test score_daily(path, [target2], 2; smoothing_days=1).score ≈ sqrt(2.)
        @test_throws ErrorException score_daily(path, [target2], 3; smoothing_days=1)
        write_daily(path, [1.])
        @test_throws ErrorException score_daily(path, [target2], 2)
        write_daily(path, [1.,2.]; metric="daily_deaths")
        @test_throws ErrorException score_daily(path, [target2], 2)
        write_daily(path, [1.,2.]; count=2)
        @test_throws ErrorException score_daily(path, [target2], 2)
        @test score_daily(path, [target2], 2; smoothing_days=1, expected_trajectories=2).score == 0
        # Real launcher outputs use DEFLATE compression, unlike the old synthetic fixture.
        compressed = fill(2.0, 1000)
        write_daily(path, compressed)
        @test score_daily(path, [MetricTarget("daily_detections", compressed)], 28).score == 0
        write(csv, "day,value\n1,2\n1,3\n")
        @test_throws ArgumentError load_observations(csv)
        @test_throws ArgumentError MetricTarget("x", [NaN])
        @test_throws ArgumentError MetricTarget("x", [1.]; scale=0.)
    end
end

# This CLI fixture executes as a separate Julia process with the real adapter contract.
function fixture_project(directory)
    project = joinpath(directory, "launcher with spaces")
    mkpath(project)
    # Reuse this package's project so the fixture has exactly the tested JSON/JLD2 versions.
    for filename in ("Project.toml", "Manifest.toml")
        cp(joinpath(@__DIR__, "..", filename), joinpath(project, filename))
    end
    script = joinpath(project, "advanced_cli.jl")
    write(script, raw"""
using JSON, JLD2
config = JSON.parsefile(ARGS[1])
mode = get(config, "fixture_mode", "ok")
mode == "timeout" && sleep(30)
mode == "exit" && (println(stderr, "fixture launcher dependency error"); exit(3))
mode == "missing" && exit(0)
daily = ARGS[findfirst(==("--output-daily"), ARGS)+1]
summary_idx = findfirst(==("--output-summary"), ARGS)
summary = summary_idx === nothing ? nothing : ARGS[summary_idx+1]
mode == "malformed" && (write(daily, "not JLD2"); exit(0))
n = config["num_trajectories"]
horizon = config["stop_simulation_time"]
jldopen(daily, "w") do file
    for id in 1:n
        group = JLD2.Group(file, string(id))
        group["daily_detections"] = fill(config["transmission_probabilities"]["school"], horizon)
    end
end
if summary !== nothing
    jldopen(summary, "w") do file
        file["num_infections"] = zeros(Int, n)
    end
end
""")
    write(joinpath(directory, "population.jld2"), "fixture input")
    seed = Dict{String,Any}("population_path"=>"population.jld2", "stop_simulation_threshold"=>100,
        "transmission_probabilities"=>Dict{String,Any}("school"=>0.1),
        "mild_detection_prob"=>0.1, "contact_tracing"=>Dict("probability"=>0.1),
        "initial_conditions"=>Dict(), "imported_cases"=>[Dict("params"=>Dict("num_infections"=>1))])
    path = joinpath(directory, "seed.json")
    MTA._write_json(path, seed)
    project, path, seed
end

@testset "subprocess launcher adapter and portable fit profile" begin
    mktempdir() do directory
        project, seed_path, seed = fixture_project(directory)
        target = MetricTarget("daily_detections", [0.25,0.25]; scale=1.)
        config = LauncherConfig(project_dir=project, base_config=seed_path,
            output_dir=joinpath(directory,"runs"), timeout_seconds=120., write_summary=true)
        evaluator = LauncherEvaluator(config, Dict(:school=>"transmission_probabilities.school"), [target]; smoothing_days=1)
        candidate = render_candidate(evaluator, Dict(:school=>0.25), 2, 37)
        @test candidate["params_seed"] == 37 && candidate["stop_simulation_time"] == 2
        @test candidate["population_path"] == joinpath(directory, "population.jld2")
        @test evaluator.base["transmission_probabilities"]["school"] == 0.1
        @test evaluator(Dict(:school=>0.25), 2, 37) == 0
        directories = readdir(config.output_dir; join=true)
        report = JSON.parsefile(joinpath(only(directories), "evaluation.json"))
        @test report["status"] == "completed" && report["exit_code"] == 0
        @test JSON.parsefile(joinpath(only(directories), "config_candidate.json"))["params_seed"] == 37
        for mode in ("exit", "missing", "malformed", "timeout")
            seed["fixture_mode"] = mode
            MTA._write_json(seed_path, seed)
            failure_config = LauncherConfig(project_dir=project, base_config=seed_path,
                output_dir=joinpath(directory, mode), timeout_seconds=mode == "timeout" ? 0.05 : 120.)
            failure = LauncherEvaluator(failure_config, Dict(:school=>"transmission_probabilities.school"), [target])
            @test isinf(failure(Dict(:school=>0.2), 2, 1))
            failure_report = JSON.parsefile(joinpath(only(readdir(failure_config.output_dir; join=true)), "evaluation.json"))
            @test failure_report["status"] == "failed"
            mode == "timeout" && @test failure_report["timed_out"]
            if mode == "exit"
                # All-failed candidates must surface the launcher error rather than suggest a looser tolerance.
                options = SearchOptions(horizons=[2], random_starts=1, survivors=1,
                    score_tolerance=0.2, checkpoint_dir=joinpath(directory, "failed-checkpoint"))
                err = try
                    temporal_search(failure, [Parameter(:school, 0, 1)]; options=options)
                    nothing
                catch exception
                    exception
                end
                @test err isa ErrorException
                message = sprint(showerror, err)
                @test occursin("All candidate evaluations failed", message)
                @test occursin("fixture launcher dependency error", message)
                @test occursin("evaluation.json", message)
            end
        end
        delete!(seed, "fixture_mode")
        MTA._write_json(seed_path, seed)
        # Indexed paths use one-based indexing and preserve the JSON integer type.
        mapped = LauncherEvaluator(config, Dict(:imports=>"imported_cases[1].params.num_infections"), [target]; integer_parameters=[:imports])
        @test render_candidate(mapped, Dict(:imports=>3.4), 2, 1)["imported_cases"][1]["params"]["num_infections"] === 3
        @test_throws ArgumentError LauncherEvaluator(config, Dict(:bad=>"does.not.exist"), [target])
        write(joinpath(directory, "gt.csv"), "day,value\n1,0.25\n2,0.25\n")
        profile = Dict("launcher"=>Dict("project_dir"=>project, "base_config"=>"seed.json", "output_dir"=>"fit-runs"),
            "search"=>Dict{String,Any}("start_day"=>2,"step_days"=>1,"end_day"=>2,"random_starts"=>1,"survivors"=>1),
            "parameters"=>[Dict("name"=>"school","path"=>"transmission_probabilities.school","lower"=>0.0,"upper"=>1.0)],
            "metrics"=>[Dict("name"=>"daily_detections","file"=>"gt.csv")])
        profile_path = joinpath(directory,"fit.toml")
        open(io -> TOML.print(io, profile), profile_path, "w")
        loaded = load_fit_config(profile_path)
        @test loaded.options.horizons == [2]
        @test !ispath(loaded.evaluator.config.output_dir)
        result = fit_launcher(profile_path)
        @test isfinite(first(result).score)
        @test isfile(joinpath(loaded.evaluator.config.output_dir, "best_config.json"))
        profile["search"]["tolerance"] = 0.1
        open(io -> TOML.print(io, profile), profile_path, "w")
        @test_throws ArgumentError load_fit_config(profile_path)
    end
end
