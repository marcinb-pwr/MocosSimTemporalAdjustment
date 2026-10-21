@testset "temporal step limits, regularization and checkpoint migration" begin
    @test_throws ArgumentError TemporalControls(max_step=0)
    @test_throws ArgumentError TemporalControls(max_step=Inf)
    @test_throws ArgumentError TemporalControls(smoothness_weight=-1)
    @test_throws ArgumentError TemporalControls(reversal_weight=NaN)
    t = TemporalParameter(:infection,"infection_modulation.params.interval_values",.05,1.,
                          [30,60,90],[.5,.9,.2,.8])
    temporal = [t]
    controls = TemporalControls(max_step=.1,smoothness_weight=.2,reversal_weight=.1)
    parameters = vcat([Parameter(:school,.1,.9)],MTA._temporal_parameters(temporal))
    defaults = merge(MTA._temporal_defaults(temporal),Dict(:school=>.5))
    projected = MTA._constrain_temporal!(copy(defaults),temporal,42,controls)
    @test projected[:infection_2] ≈ .6
    @test projected[:infection_1] == defaults[:infection_1]
    @test projected[:infection_3] == defaults[:infection_3]
    @test MTA._temporal_bounds(t,defaults,14,controls) == (.4,.6)
    @test MTA._temporal_bounds(t,defaults,42,controls) == (.4,.6)
    # Flat segments do not disguise a reversal. Future values cannot affect penalty.
    trend = Dict(:infection_1=>.2,:infection_2=>.3,:infection_3=>.4,:infection_4=>.9)
    zigzag = Dict(:infection_1=>.2,:infection_2=>.3,:infection_3=>.2,:infection_4=>.9)
    a=MTA._temporal_penalty(trend,temporal,84,controls)
    b=MTA._temporal_penalty(zigzag,temporal,84,controls)
    @test a.smoothness ≈ .1
    @test a.reversal == 0 && b.reversal == 1
    @test b.smoothness ≈ .3
    @test b.total > a.total
    zigzag[:infection_4] = .05
    @test MTA._temporal_penalty(zigzag,temporal,84,controls) == b
    flat = Dict(:infection_1=>.2,:infection_2=>.3,:infection_3=>.3,:infection_4=>.2)
    @test MTA._temporal_penalty(flat,temporal,100,controls).reversal == 1
    @test MTA._temporal_penalty(trend,temporal,14,controls).total == 0
    # Replicate scores stay data-only; Candidate.score adds the deterministic penalty.
    candidates=MTA._evaluate_candidates((v,h,s)->.4,[trend,zigzag],84,[1,2],
        ExecutionOptions(max_workers=2);regularizer=(v,h)->MTA._temporal_penalty(v,temporal,h,controls).total)
    @test candidates[1].replicate_scores == [.4,.4]
    @test candidates[1].score ≈ .4+a.total
    @test candidates[2].score > candidates[1].score
    mktempdir() do directory
        options = SearchOptions(horizons=[14,28,42,56,70,84],random_starts=8,
            survivors=3,trials_per_survivor=3,repetitions=2,
            checkpoint_dir=directory,seed=7)
        calls=Dict{Int,Vector{Dict{Symbol,Float64}}}()
        evaluator=function(v,h,s)
            push!(get!(calls,h,Dict{Symbol,Float64}[]),copy(v))
            (v[:school]-.4)^2
        end
        full=temporal_search(evaluator,parameters;options=options,temporal=temporal,temporal_controls=controls)
        for (h,values) in calls
            active=MTA._temporal_index(t,h)
            @test all(abs(v[MTA._temporal_name(t,active)]-
                (active==1 ? t.values[1] : v[MTA._temporal_name(t,active-1)])) <= .1+1e-12 for v in values)
            @test length(unique(v[MTA._temporal_name(t,active)] for v in values))>1
        end
        checkpoint=joinpath(directory,"stage_003_day_42.jls")
        resumed=temporal_search(evaluator,parameters;options=options,temporal=temporal,
            temporal_controls=controls,resume_from=checkpoint,execution=ExecutionOptions(max_workers=3))
        @test getfield.(resumed,:values) == getfield.(full,:values)
        @test getfield.(resumed,:score) == getfield.(full,:score)
        @test_throws ArgumentError temporal_search(evaluator,parameters;options=options,temporal=temporal,
            resume_from=checkpoint,temporal_controls=TemporalControls(max_step=.2))
        # Explicit warm start can add constraints to an existing temporal experiment.
        warmed=temporal_search(evaluator,parameters;options=options,temporal=temporal,
            warm_start_from=checkpoint,temporal_controls=TemporalControls(max_step=.05))
        @test isfinite(first(warmed).score)
        # A scalar checkpoint can be warm-started with tighter scalar bounds.
        temporal_search((v,h,s)->0.,[Parameter(:school,0.,1.)];options=options,
            initial=[Dict(:school=>0.)])
        empty!(calls)
        temporal_search(evaluator,parameters;options=options,temporal=temporal,
            warm_start_from=checkpoint,temporal_controls=controls)
        @test all(.1 <= v[:school] <= .9 for values in Base.values(calls) for v in values)
        @test_throws ArgumentError temporal_search(evaluator,[Parameter(:school,0.,1.)];
            options=options,temporal_controls=controls)
    end
end
