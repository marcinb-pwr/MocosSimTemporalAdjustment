@testset "temporal windows match exclusive daily-output horizon" begin
    t=TemporalParameter(:infection,"infection_modulation.params.interval_values",.05,1.,
        [30,60,90,120],[.5,.6,.7,.8,.9])
    temporal=[t]
    for (horizon,index) in [(30,1),(60,2),(90,3),(120,4)]
        @test MTA._temporal_index(t,horizon)==index
        # Cross-component contract: launcher bins floor(time)+1, while MocosSim
        # selects searchsortedlast(times,time)+1. The next interval contributes
        # to output day horizon+1, outside the scored prefix.
        last_event_time=horizon-.25
        @test floor(Int,last_event_time)+1==horizon
        @test searchsortedlast(t.times,last_event_time)+1==index
        @test floor(Int,Float64(horizon))+1==horizon+1
        @test searchsortedlast(t.times,Float64(horizon))+1==index+1
    end
    values=MTA._temporal_defaults(temporal)
    controls=TemporalControls(smoothness_weight=.2,reversal_weight=.1)
    penalty=MTA._temporal_penalty(values,temporal,60,controls)
    values[:infection_3]=.05
    @test MTA._temporal_penalty(values,temporal,60,controls)==penalty
    mktempdir() do directory
        parameters=MTA._temporal_parameters(temporal)
        options=SearchOptions(horizons=[30,60],random_starts=5,survivors=2,
            trials_per_survivor=2,checkpoint_dir=directory)
        calls=Dict{Int,Vector{Dict{Symbol,Float64}}}()
        evaluator=function(v,h,s)
            push!(get!(calls,h,Dict{Symbol,Float64}[]),copy(v))
            sum((v[MTA._temporal_name(t,i)]-.4)^2 for i in 1:MTA._temporal_index(t,h))
        end
        temporal_search(evaluator,parameters;options=options,temporal=temporal)
        @test length(unique(v[:infection_1] for v in calls[30]))>1
        @test all(v[:infection_2]==t.values[2] for v in calls[30])
        @test length(unique(v[:infection_2] for v in calls[60]))>1
        @test all(v[:infection_3]==t.values[3] for v in calls[60])
        checkpoint=joinpath(directory,"stage_001_day_30.jls")
        saved=load_checkpoint(checkpoint)
        @test saved.temporal_interval_policy=="scored_prefix_v2"
        legacy=(; (k=>getfield(saved,k) for k in propertynames(saved) if k!=:temporal_interval_policy)...)
        old_path=joinpath(directory,"old_day30.jls")
        MTA._save_checkpoint(old_path,legacy)
        @test_throws ArgumentError temporal_search(evaluator,parameters;options=options,
            temporal=temporal,resume_from=old_path)
        empty!(calls)
        temporal_search(evaluator,parameters;options=options,temporal=temporal,warm_start_from=old_path)
        @test collect(keys(calls))==[60]
        @test MTA._check_temporal_interval_policy(legacy,temporal,[14,28,42,56])===nothing
    end
end
