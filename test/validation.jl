@testset "fresh-seed launcher validation" begin
    mktempdir() do directory
        project,seed_path,seed=fixture_project(directory)
        write(joinpath(directory,"gt.csv"),"day,value\n1,0.25\n2,0.25\n")
        profile=Dict{String,Any}(
            "launcher"=>Dict("project_dir"=>project,"base_config"=>seed_path,
                             "output_dir"=>joinpath(directory,"fit-runs")),
            "execution"=>Dict("batch_size"=>2,"progress"=>false),
            "search"=>Dict("horizons"=>[2],"random_starts"=>4,"survivors"=>2,"repetitions"=>1),
            "scoring"=>Dict("smoothing_days"=>1),
            "parameters"=>[Dict("name"=>"school","path"=>"transmission_probabilities.school",
                                "lower"=>0.,"upper"=>1.)],
            "metrics"=>[Dict("name"=>"daily_detections","file"=>"gt.csv","scale"=>1.)])
        path=joinpath(directory,"fit.toml")
        save()=open(io->TOML.print(io,profile),path,"w")
        save()
        fit=load_fit_config(path)
        temporal_search((v,h,s)->abs(v[:school]-.25),fit.parameters;options=fit.options)
        checkpoint=joinpath(fit.options.checkpoint_dir,"stage_001_day_2.jls")
        original=read(checkpoint)
        saved=load_checkpoint(checkpoint)
        result=validate_launcher(path,checkpoint;repetitions=2,top_n=2)
        @test read(checkpoint)==original
        @test length(result.candidates)==2 && length(unique(result.replicate_seeds))==2
        @test isempty(intersect(result.replicate_seeds,saved.replicate_seeds))
        @test result.replicate_seeds==MTA._validation_seeds(saved,2,2026)
        @test all(c.score≈abs(c.values[:school]-.25) for c in result.candidates)
        @test issorted(getfield.(result.candidates,:score))
        runs=readdir(joinpath(result.directory,"runs");join=true)
        @test length(runs)==4
        @test all(JSON.parsefile(joinpath(run,"evaluation.json"))["seed"] in result.replicate_seeds for run in runs)
        report=JSON.parsefile(joinpath(result.directory,"validation_result.json"))
        @test report["score_tolerance"]==.5 && report["repetitions"]==2
        @test report["candidates"][1]["data_score"]≈first(result.candidates).score
        @test isfile(joinpath(result.directory,"best_config.json"))
        @test_throws ArgumentError validate_launcher(path,checkpoint;repetitions=0)
        # Failed validation writes null scores and diagnostics, never a winning config.
        seed["fixture_mode"]="exit"
        MTA._write_json(seed_path,seed)
        failed=validate_launcher(path,checkpoint;repetitions=1,top_n=1)
        @test isinf(first(failed.candidates).score)
        failure=JSON.parsefile(joinpath(failed.directory,"validation_result.json"))["candidates"][1]
        @test failure["score"]===nothing && !failure["passed_tolerance"]
        @test failure["failed_replicates"]==1
        @test !isfile(joinpath(failed.directory,"best_config.json"))
        profile["parameters"][1]["upper"] = .9
        save()
        @test_throws ArgumentError validate_launcher(path,checkpoint)
    end
end

@testset "changed exploration budget retries a failed horizon" begin
    mktempdir() do directory
        t=TemporalParameter(:infection,"infection_modulation.params.interval_values",.05,1.,[30],[.5,.6])
        temporal=[t]
        parameters=vcat([Parameter(:school,.1,.9)],MTA._temporal_parameters(temporal))
        original=SearchOptions(horizons=[14,28],random_starts=1,survivors=1,repetitions=3,
            score_tolerance=.1,checkpoint_dir=joinpath(directory,"original"))
        @test_throws ErrorException temporal_search((v,h,s)->.9,parameters;
            options=original,temporal=temporal)
        checkpoint=joinpath(original.checkpoint_dir,"stage_001_day_14.jls")
        @test !load_checkpoint(checkpoint).accepted
        faster=SearchOptions(horizons=[14,28],random_starts=1,survivors=1,repetitions=1,
            score_tolerance=.6,checkpoint_dir=joinpath(directory,"fast"))
        @test_throws ArgumentError temporal_search((v,h,s)->.2,parameters;
            options=faster,temporal=temporal,resume_from=checkpoint)
        days=Int[]
        temporal_search((v,h,s)->(push!(days,h);.2),parameters;options=faster,temporal=temporal,
            warm_start_from=checkpoint)
        @test sort!(unique(days))==[14,28]
        retried=load_checkpoint(joinpath(faster.checkpoint_dir,"stage_001_day_14.jls"))
        @test retried.radius==original.initial_radius
        @test retried.accepted && length(retried.replicate_seeds)==1
    end
end
