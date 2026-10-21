@testset "bounded evaluation queue" begin
    @test_throws ArgumentError ExecutionOptions(max_workers=0)
    @test_throws ArgumentError ExecutionOptions(progress_interval_seconds=0)
    proposals = [Dict(:x=>Float64(i)) for i in 1:8]
    seeds = [11,22,33]
    active = Ref(0)
    peak = Ref(0)
    calls = Tuple{Float64,Int}[]
    evaluator = function(values, horizon, seed)
        active[] += 1
        peak[] = max(peak[], active[])
        push!(calls, (values[:x],seed))
        try
            sleep(0.002 * (9 - Int(values[:x])))
            values[:x] + seed / 100
        finally
            active[] -= 1
        end
    end
    queued = MTA._evaluate_candidates(evaluator, proposals, 14, seeds,
                                     ExecutionOptions(max_workers=3))
    serial = MTA._evaluate_candidates((v,h,s)->v[:x]+s/100, proposals, 14, seeds,
                                     ExecutionOptions())
    @test peak[] == 3
    @test active[] == 0
    @test length(calls) == length(proposals)*length(seeds)
    @test getfield.(queued, :values) == getfield.(serial, :values)
    @test getfield.(queued, :replicate_scores) == getfield.(serial, :replicate_scores)
    @test getfield.(queued, :score) == getfield.(serial, :score)
    @test all([s for (x,s) in calls if x == i] == seeds for i in 1.:8.)
    # Operational failures stay attached to their candidate and do not stop the queue.
    failed = MTA._evaluate_candidates((v,h,s)->s==22 ? Inf : v[:x], proposals, 14, seeds,
                                     ExecutionOptions(max_workers=3))
    @test all(isinf(c.score) && c.replicate_scores[2]==Inf for c in failed)
    @test_throws ErrorException MTA._evaluate_candidates((args...)->error("fixture evaluator error"),
        proposals,14,seeds,ExecutionOptions(max_workers=3))
    # A change in scheduling must not alter search RNG consumption or resume results.
    mktempdir() do directory
        options = SearchOptions(horizons=[2,4], random_starts=8, survivors=3,
            trials_per_survivor=2, repetitions=2, max_rounds_per_horizon=2,
            checkpoint_dir=directory, seed=9)
        evaluator = (v,h,s)->(sleep(0.001); (v[:x]-.3)^2 + (s%5)/1000)
        parameters = [Parameter(:x,0,1)]
        original = temporal_search(evaluator,parameters;options=options)
        parallel = temporal_search(evaluator,parameters;options=options,execution=ExecutionOptions(max_workers=3))
        resumed = temporal_search(evaluator,parameters;options=options,execution=ExecutionOptions(max_workers=2),
            resume_from=joinpath(directory,"stage_001_day_2.jls"))
        @test getfield.(original,:values) == getfield.(parallel,:values) == getfield.(resumed,:values)
        @test getfield.(original,:replicate_scores) == getfield.(parallel,:replicate_scores) == getfield.(resumed,:replicate_scores)
    end
    # Progress counts individual repetitions rather than only whole candidates.
    mktemp() do path, io
        redirect_stderr(io) do
            MTA._evaluate_candidates((v,h,s)->s==22 ? Inf : 0., proposals[1:2],14,seeds,
                                    ExecutionOptions(max_workers=2,progress=true))
        end
        flush(io)
        log = read(path,String)
        @test occursin("candidates=2 runs=6",log)
        @test occursin("completed=6/6 failed=2",log)
    end
end

@testset "launcher subprocess queue" begin
    mktempdir() do directory
        project,seed_path,seed=fixture_project(directory)
        seed["fixture_pause"]=2.0
        MTA._write_json(seed_path,seed)
        config=LauncherConfig(project_dir=project,base_config=seed_path,
            output_dir=joinpath(directory,"parallel-runs"),timeout_seconds=120.)
        evaluator=LauncherEvaluator(config,Dict(:school=>"transmission_probabilities.school"),
            [MetricTarget("daily_detections",fill(.25,2);scale=1.)];smoothing_days=1)
        candidates=MTA._evaluate_candidates(evaluator,[Dict(:school=>x) for x in [.25,.5,.75,1.]],
            2,[37],ExecutionOptions(max_workers=2))
        @test getfield.(candidates,:score) ≈ [0.,.25,.5,.75]
        runs=readdir(config.output_dir;join=true)
        @test length(runs)==4
        @test all(JSON.parsefile(joinpath(run,"evaluation.json"))["status"]=="completed" for run in runs)
        timings=[JSON.parsefile(joinpath(run,"worker_timing.json")) for run in runs]
        @test length(unique(record["pid"] for record in timings))==4
        events=sort!(vcat([(r["started"],1) for r in timings],[(r["finished"],-1) for r in timings]);by=first)
        active,peak=0,0
        for (_,delta) in events
            active+=delta
            peak=max(peak,active)
        end
        @test peak==2
        @test isempty(evaluator.active_processes)
        # Cancellation terminates each active child and lets its worker write diagnostics.
        seed["fixture_mode"]="timeout"
        MTA._write_json(seed_path,seed)
        stopped=LauncherEvaluator(config,Dict(:school=>"transmission_probabilities.school"),
            [MetricTarget("daily_detections",fill(.25,2))])
        task=@async MTA._evaluate_candidates(stopped,[Dict(:school=>.25),Dict(:school=>.5)],
            2,[37],ExecutionOptions(max_workers=2))
        @test timedwait(()->length(stopped.active_processes)==2,30.)==:ok
        MTA._cancel_evaluations(stopped)
        @test all(isinf(c.score) for c in fetch(task))
        @test isempty(stopped.active_processes)
    end
end
