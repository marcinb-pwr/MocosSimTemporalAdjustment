function _config_path(base, raw)
    value = replace(String(raw), r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}" => match -> begin
        name = match[3:end-1]
        haskey(ENV, name) || throw(ArgumentError("environment variable $name is not set"))
        ENV[name]
    end)
    isabspath(value) ? normpath(value) : normpath(joinpath(base, value))
end

function _reject_unknown(section, allowed, label)
    unknown = setdiff(Set(keys(section)), Set(String.(allowed)))
    isempty(unknown) || throw(ArgumentError("unknown $label settings: $(join(sort!(collect(unknown)), ", "))"))
end

"""Load and preflight a TOML fit profile without creating output or launching Julia."""
function load_fit_config(path::AbstractString)
    raw = TOML.parsefile(path)
    base = dirname(abspath(path))
    _reject_unknown(raw, ["launcher", "search", "parameters", "temporal_parameters", "temporal_constraints", "metrics", "scoring", "execution"], "top-level")
    launcher = copy(raw["launcher"])
    _reject_unknown(launcher, fieldnames(LauncherConfig), "launcher")
    for key in ("project_dir", "base_config", "advanced_cli", "output_dir", "input_base_dir")
        haskey(launcher, key) && (launcher[key] = _config_path(base, launcher[key]))
    end
    if haskey(launcher, "julia_bin")
        value = String(launcher["julia_bin"])
        # A bare command is resolved via PATH; paths and environment placeholders are config-relative.
        launcher["julia_bin"] = occursin(r"[/\\$]", value) ? _config_path(base, value) : value
    end
    haskey(launcher, "output_dir") || (launcher["output_dir"] = joinpath(base, "runs", "launcher"))
    config = LauncherConfig(; (Symbol(k) => v for (k,v) in launcher)...)
    search = copy(get(raw, "search", Dict{String,Any}()))
    _reject_unknown(search, vcat(collect(String.(fieldnames(SearchOptions))), ["start_day", "step_days", "end_day"]), "search")
    if haskey(search, "horizons")
        any(haskey(search, k) for k in ("start_day", "step_days", "end_day")) &&
            throw(ArgumentError("use horizons OR start_day/step_days/end_day"))
    else
        search["horizons"] = day_horizons(; (Symbol(k) => pop!(search, k)
            for k in ("start_day", "step_days", "end_day") if haskey(search, k))...)
    end
    search["checkpoint_dir"] = haskey(search, "checkpoint_dir") ?
        _config_path(base, search["checkpoint_dir"]) : joinpath(config.output_dir, "checkpoints")
    options = SearchOptions(; (Symbol(k) => v for (k,v) in search)...)
    execution_config = copy(get(raw, "execution", Dict{String,Any}()))
    if haskey(execution_config, "batch_size")
        haskey(execution_config, "max_workers") &&
            throw(ArgumentError("use execution.batch_size OR execution.max_workers, not both"))
        execution_config["max_workers"] = pop!(execution_config, "batch_size")
    end
    _reject_unknown(execution_config, fieldnames(ExecutionOptions), "execution")
    get!(execution_config, "progress", true)
    execution = ExecutionOptions(; (Symbol(k) => v for (k,v) in execution_config)...)
    parameters = Parameter[]
    paths = Dict{Symbol,String}()
    integers = Symbol[]
    for item in raw["parameters"]
        _reject_unknown(item, ["name", "path", "lower", "upper", "scale", "integer"], "parameter")
        name = Symbol(get(item, "name", item["path"]))
        push!(parameters, Parameter(name, item["lower"], item["upper"]; scale=Symbol(get(item, "scale", "linear"))))
        paths[name] = String(item["path"])
        get(item, "integer", false) && push!(integers, name)
    end
    temporal = TemporalParameter[]
    baseline = JSON.parsefile(config.base_config)
    for item in get(raw, "temporal_parameters", [])
        _reject_unknown(item, ["name", "path", "lower", "upper", "scale"], "temporal parameter")
        root = String(item["path"])
        root in ("infection_modulation", "mild_detection_modulation", "tracing_modulation") ||
            throw(ArgumentError("unsupported temporal modulation: $root"))
        modulation = get(baseline, root, nothing)
        modulation isa AbstractDict && get(modulation, "function", nothing) == "IntervalsModulations" ||
            throw(ArgumentError("$root must use IntervalsModulations"))
        params = modulation["params"]
        get(params, "weight_days", 0) == 1 && get(params, "weight_detected", 0) == 0 &&
            get(params, "weight_deaths", 0) == 0 ||
            throw(ArgumentError("$root must be day-based: weight_days=1, weight_detected=weight_deaths=0"))
        t = TemporalParameter(Symbol(get(item, "name", root)), "$root.params.interval_values",
            item["lower"], item["upper"], params["interval_times"], params["interval_values"];
            scale=Symbol(get(item, "scale", "linear")))
        push!(temporal, t)
        append!(parameters, _temporal_parameters([t]))
        for i in eachindex(t.values)
            paths[_temporal_name(t, i)] = "$(t.path)[$i]"
        end
    end
    _validate(parameters, options)
    constraints = get(raw,"temporal_constraints",Dict{String,Any}())
    _reject_unknown(constraints,fieldnames(TemporalControls),"temporal constraint")
    temporal_controls = TemporalControls(; (Symbol(k)=>v for (k,v) in constraints)...)
    isempty(temporal) && (temporal_controls.max_step !== nothing ||
        temporal_controls.smoothness_weight>0 || temporal_controls.reversal_weight>0) &&
        throw(ArgumentError("temporal constraints require [[temporal_parameters]] entries"))
    targets = MetricTarget[]
    for item in raw["metrics"]
        _reject_unknown(item, ["name", "file", "weight", "scale"], "metric")
        push!(targets, MetricTarget(item["name"], load_observations(_config_path(base, item["file"]));
                                   weight=get(item, "weight", 1), scale=get(item, "scale", nothing)))
    end
    scoring = get(raw, "scoring", Dict{String,Any}())
    _reject_unknown(scoring, ["smoothing_days"], "scoring")
    evaluator = LauncherEvaluator(config, paths, targets;
        smoothing_days=get(scoring, "smoothing_days", 7), integer_parameters=integers)
    # Detect an unusable first horizon without paying for a simulation.
    for target in targets
        any(!ismissing(_smooth_at(target.observed, day, evaluator.smoothing_days))
            for day in 1:min(first(options.horizons), length(target.observed))) ||
            throw(ArgumentError("$(target.name) has no usable observations at the first horizon"))
    end
    (evaluator=evaluator, parameters=parameters, options=options, execution=execution,
     temporal=temporal,temporal_controls=temporal_controls)
end

"""Fit a launcher TOML profile and export the best full-horizon JSON configuration."""
function fit_launcher(path::AbstractString; resume_from::Union{Nothing,AbstractString}=nothing,
                      warm_start_from::Union{Nothing,AbstractString}=nothing)
    fit = load_fit_config(path)
    if fit.execution.progress
        println(stderr, "Fit profile: ", abspath(path))
        println(stderr,"Simulation seeds per candidate: ",fit.options.repetitions,
                "; score tolerance: ",fit.options.score_tolerance)
        println(stderr, "Temporal fitting: ", isempty(fit.temporal) ?
            "disabled (no [[temporal_parameters]] entries)" :
            join(string.(getfield.(fit.temporal, :name)), ", "))
        isempty(fit.temporal) || println(stderr,"Temporal constraints: ",fit.temporal_controls)
        isempty(fit.temporal) || println(stderr,"Temporal interval policy: ",TEMPORAL_INTERVAL_POLICY)
    end
    finalists = temporal_search(fit.evaluator, fit.parameters; options=fit.options,
                               resume_from=resume_from, warm_start_from=warm_start_from,
                               temporal=fit.temporal,temporal_controls=fit.temporal_controls,
                               execution=fit.execution)
    best = first(finalists)
    isfinite(best.score) || error("All final candidates failed." *
                                 _evaluation_failure_hint(fit.evaluator, best.horizon))
    stage_path = joinpath(fit.options.checkpoint_dir,
        "stage_$(lpad(length(fit.options.horizons), 3, '0'))_day_$(best.horizon).jls")
    checkpoint = resume_from !== nothing && !isfile(stage_path) ? load_checkpoint(resume_from) : load_checkpoint(stage_path)
    candidate = render_candidate(fit.evaluator, best.values, best.horizon, first(checkpoint.replicate_seeds))
    mkpath(fit.evaluator.config.output_dir)
    _write_json(joinpath(fit.evaluator.config.output_dir, "best_config.json"), candidate)
    _write_json(joinpath(fit.evaluator.config.output_dir, "fit_result.json"),
        Dict("score" => best.score, "horizon" => best.horizon,
             "data_score" => median(best.replicate_scores),
             "temporal_regularization" => Dict(String(k)=>v for (k,v) in
                 pairs(_temporal_penalty(best.values,fit.temporal,best.horizon,fit.temporal_controls))),
             "values" => Dict(String(k) => v for (k,v) in best.values),
             "replicate_scores" => best.replicate_scores,
             "replicate_seeds" => checkpoint.replicate_seeds,
             "tolerance_met" => checkpoint.tolerance_met,
             "score_tolerance" => fit.options.score_tolerance,
             "best_config_seed" => first(checkpoint.replicate_seeds)))
    finalists
end
