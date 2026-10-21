@testset "active temporal intervals and survivor histories" begin
    temporal = [TemporalParameter(Symbol(root), "$root.params.interval_values", 0, 2,
                                  [30,60,90], [.4,.5,.6,.7])
                for root in ("infection_modulation", "mild_detection_modulation", "tracing_modulation")]
    scalar = [Parameter(:school, 0, 1)]
    parameters = vcat(scalar, MTA._temporal_parameters(temporal))
    @test [MTA._temporal_index(first(temporal), h) for h in [14,28,30,42,60,84,90,600]] ==
        [1,1,2,2,3,3,4,4]
    @test_throws ArgumentError TemporalParameter(:x,"x",0,2,[30,30],[1,1,1])
    @test_throws ArgumentError TemporalParameter(:x,"x",0,2,[30],[1])
    @test_throws ArgumentError TemporalParameter(:x,"x",0,1,[30],[1,2])
    mktempdir() do directory
        options = SearchOptions(horizons=[14,28,42,56,70,84,90], random_starts=5,
            survivors=3, trials_per_survivor=2, repetitions=2,
            checkpoint_dir=directory, seed=42)
        calls = Dict{Int,Vector{Dict{Symbol,Float64}}}()
        evaluator = function(v,h,s)
            push!(get!(calls,h,Dict{Symbol,Float64}[]),copy(v))
            sum((v[p.name]-.3)^2 for p in MTA._active_parameters(parameters,temporal,h))
        end
        full = temporal_search(evaluator,parameters;options=options,temporal=temporal)
        for (stage,horizon) in enumerate(options.horizons)
            frozen = [MTA._temporal_name(t,i) for t in temporal for i in eachindex(t.values)
                      if i != MTA._temporal_index(t,horizon)]
            histories = if stage == 1
                [MTA._temporal_defaults(temporal)]
            else
                previous = load_checkpoint(joinpath(directory,
                    "stage_$(lpad(stage-1,3,'0'))_day_$(options.horizons[stage-1]).jls"))
                getfield.(previous.survivors,:values)
            end
            @test all(any(all(v[k] == parent[k] for k in frozen) for parent in histories)
                      for v in calls[horizon])
        end
        checkpoint = joinpath(directory,"stage_003_day_42.jls")
        resumed = temporal_search(evaluator,parameters;options=options,temporal=temporal,
            resume_from=checkpoint,execution=ExecutionOptions(max_workers=3))
        @test getfield.(full,:values) == getfield.(resumed,:values)
        @test getfield.(full,:score) == getfield.(resumed,:score)
        different = deepcopy(temporal)
        different[1].times[3] = 91
        @test_throws ArgumentError temporal_search(evaluator,parameters;options=options,
            temporal=different,resume_from=checkpoint)
        # Adding temporal dimensions is explicitly a warm start, not exact resume.
        temporal_search((v,h,s)->v[:school],scalar;options=options)
        @test_throws ArgumentError temporal_search(evaluator,parameters;options=options,
            temporal=temporal,resume_from=checkpoint)
        empty!(calls)
        warm = temporal_search(evaluator,parameters;options=options,temporal=temporal,
            warm_start_from=checkpoint)
        @test sort!(collect(keys(calls))) == [56,70,84,90]
        defaults = MTA._temporal_defaults(temporal)
        @test all(v[:infection_modulation_1] == defaults[:infection_modulation_1] &&
                  v[:infection_modulation_3] == defaults[:infection_modulation_3]
                  for v in calls[56])
        proposals = calls[56][1:options.repetitions:end]
        active = [MTA._temporal_name(t, MTA._temporal_index(t,56)) for t in temporal]
        @test all(all(v[k] == defaults[k] for k in active)
                  for v in proposals[1:options.survivors])
        @test all(any(v[k] != defaults[k] for v in proposals[options.survivors+1:end]) for k in active)
        progress = IOBuffer()
        MTA._report_temporal_proposals(progress,temporal,proposals,56,1,3,1)
        log = String(take!(progress))
        @test occursin("retained=3 random=1 mutated=6",log)
        @test occursin("temporal=infection_modulation_2 interval=[30.0,60.0)",log)
        @test isfinite(first(warm).score)
        saved = load_checkpoint(joinpath(directory,"stage_007_day_90.jls"))
        @test saved.temporal == temporal && saved.warm_start_from == checkpoint
    end
end

@testset "temporal TOML, indexed rendering and batch size" begin
    mktempdir() do directory
        project, seed_path, seed = fixture_project(directory)
        roots = ["infection_modulation", "mild_detection_modulation", "tracing_modulation"]
        for root in roots
            seed[root] = Dict("function"=>"IntervalsModulations", "params"=>Dict(
                "weight_days"=>1,"weight_detected"=>0,"weight_deaths"=>0,
                "interval_times"=>[30,60,90], "interval_values"=>[.4,.5,.6,.7]))
        end
        MTA._write_json(seed_path,seed)
        write(joinpath(directory,"gt.csv"),"day,value\n1,1\n")
        profile = Dict{String,Any}(
            "launcher"=>Dict("project_dir"=>project,"base_config"=>seed_path),
            "execution"=>Dict("batch_size"=>8),
            "search"=>Dict("horizons"=>[84]),
            "parameters"=>[Dict("name"=>"school","path"=>"transmission_probabilities.school",
                                "lower"=>0.,"upper"=>1.)],
            "temporal_parameters"=>[Dict("path"=>root,"lower"=>0.,"upper"=>2.) for root in roots],
            "metrics"=>[Dict("name"=>"daily_detections","file"=>"gt.csv")])
        path = joinpath(directory,"fit.toml")
        save() = open(io->TOML.print(io,profile),path,"w")
        save()
        fit = load_fit_config(path)
        @test fit.execution.max_workers == 8
        @test length(fit.parameters) == 13 && length(fit.temporal) == 3
        values = merge(MTA._temporal_defaults(fit.temporal),Dict(:school=>.3))
        for root in roots
            values[Symbol(root,"_3")] = 1.2
        end
        candidate = render_candidate(fit.evaluator,values,84,37)
        @test all(candidate[root]["params"]["interval_values"] == [.4,.5,1.2,.7] for root in roots)
        @test all(fit.evaluator.base[root]["params"]["interval_values"] == [.4,.5,.6,.7] for root in roots)
        profile["execution"]["max_workers"] = 4
        save()
        @test_throws ArgumentError load_fit_config(path)
        delete!(profile["execution"],"max_workers")
        profile["execution"]["batch_size"] = 0
        save()
        @test_throws ArgumentError load_fit_config(path)
        profile["execution"]["batch_size"] = 8
        save()
        profile["temporal_constraints"] = Dict("max_step"=>.15,"smoothness_weight"=>.2,"reversal_weight"=>.1)
        save()
        @test load_fit_config(path).temporal_controls.max_step == .15
        profile["temporal_constraints"]["max_step"] = -.1
        save()
        @test_throws ArgumentError load_fit_config(path)
        profile["temporal_constraints"]["max_step"] = .15
        save()
        seed["infection_modulation"]["params"]["weight_detected"] = 1
        MTA._write_json(seed_path,seed)
        @test_throws ArgumentError load_fit_config(path)
    end
end
