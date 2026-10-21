function _validation_seeds(saved, repetitions, seed)
    rng = MersenneTwister(seed)
    excluded = Set(saved.replicate_seeds)
    seeds = Int[]
    while length(seeds)<repetitions
        value = rand(rng,1:typemax(Int32))
        value in excluded && continue
        push!(seeds,value)
        push!(excluded,value)
    end
    seeds
end

"""Re-evaluate the checkpoint's best candidates with fresh paired seeds.

Does not mutate the checkpoint or advance the search. Reports go into a new
validation directory. The default validation threshold is 0.65, independent of
the exploration profile's threshold. Replicate losses remain data-only.
"""
function validate_launcher(path::AbstractString, checkpoint::AbstractString;
                           repetitions::Int=5, top_n::Int=3, seed::Int=2026,
                           score_tolerance::Real=0.65)
    repetitions>0 && top_n>0 || throw(ArgumentError("repetitions and top_n must be positive"))
    isfinite(score_tolerance) && score_tolerance>=0 ||
        throw(ArgumentError("validation score_tolerance must be finite and nonnegative"))
    fit = load_fit_config(path)
    saved = load_checkpoint(checkpoint)
    isequal(saved.parameters,fit.parameters) || throw(ArgumentError("validation parameters differ"))
    isequal(get(saved,:temporal,TemporalParameter[]),fit.temporal) ||
        throw(ArgumentError("validation temporal definitions differ"))
    isequal(get(saved,:temporal_controls,TemporalControls()),fit.temporal_controls) ||
        throw(ArgumentError("validation temporal constraints differ"))
    training = sort(saved.survivors;by=c->c.score)
    isempty(training) && throw(ArgumentError("checkpoint has no candidates"))
    training = training[1:min(top_n,length(training))]
    seeds = _validation_seeds(saved,repetitions,seed)
    root = joinpath(fit.evaluator.config.output_dir,"validation")
    mkpath(root)
    directory = mktempdir(root;prefix="day_$(saved.horizon)_",cleanup=false)
    original = fit.evaluator.config
    config = LauncherConfig(; (key => (key==:output_dir ? joinpath(directory,"runs") :
        getfield(original,key)) for key in fieldnames(LauncherConfig))...)
    evaluator = LauncherEvaluator(config,fit.evaluator.parameter_paths,fit.evaluator.targets;
        smoothing_days=fit.evaluator.smoothing_days,
        integer_parameters=collect(fit.evaluator.integer_parameters))
    fit.execution.progress && println(stderr,"Validation: $(length(training)) candidates × $repetitions fresh seeds; horizon=$(saved.horizon)")
    validated = _evaluate_candidates(evaluator,getfield.(training,:values),saved.horizon,seeds,fit.execution;
        regularizer=(v,h)->_temporal_penalty(v,fit.temporal,h,fit.temporal_controls).total)
    order = sortperm(getfield.(validated,:score))
    finite_or_null(x) = isfinite(x) ? x : nothing
    rows = [Dict("validation_rank"=>rank,"training_rank"=>index,
        "training_score"=>finite_or_null(training[index].score),
        "score"=>finite_or_null(validated[index].score),
        "data_score"=>finite_or_null(median(validated[index].replicate_scores)),
        "replicate_scores"=>finite_or_null.(validated[index].replicate_scores),
        "failed_replicates"=>count(!isfinite,validated[index].replicate_scores),
        "data_score_std"=>(repetitions>1 && all(isfinite,validated[index].replicate_scores) ?
            std(validated[index].replicate_scores) : nothing),
        "temporal_regularization"=>Dict(String(k)=>v for (k,v) in pairs(
            _temporal_penalty(validated[index].values,fit.temporal,saved.horizon,fit.temporal_controls))),
        "passed_tolerance"=>validated[index].score<=score_tolerance,
        "values"=>Dict(String(k)=>v for (k,v) in validated[index].values))
        for (rank,index) in enumerate(order)]
    _write_json(joinpath(directory,"validation_result.json"),Dict(
        "kind"=>"fresh-seed validation","profile"=>abspath(path),
        "checkpoint"=>abspath(checkpoint),"horizon"=>saved.horizon,
        "temporal_interval_policy"=>TEMPORAL_INTERVAL_POLICY,
        "training_temporal_interval_policy"=>get(saved,:temporal_interval_policy,"horizon_time_v1"),
        "repetitions"=>repetitions,"validation_seed"=>seed,"replicate_seeds"=>seeds,
        "excluded_checkpoint_seeds"=>saved.replicate_seeds,
        "score_tolerance"=>score_tolerance,"candidates"=>rows))
    ranked = validated[order]
    if isfinite(first(ranked).score)
        _write_json(joinpath(directory,"best_config.json"),
            render_candidate(evaluator,first(ranked).values,saved.horizon,first(seeds)))
    end
    (directory=directory,candidates=ranked,replicate_seeds=seeds)
end
