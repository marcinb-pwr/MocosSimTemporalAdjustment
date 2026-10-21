"""External launcher settings. Paths are resolved once, before any simulation."""
struct LauncherConfig
    project_dir::String
    base_config::String
    julia_bin::String
    advanced_cli::String
    output_dir::String
    input_base_dir::String
    threads::Int
    num_trajectories::Int
    timeout_seconds::Float64
    compiled_modules::Bool
    write_summary::Bool
end

function LauncherConfig(; project_dir::AbstractString, base_config::AbstractString,
                        julia_bin::AbstractString=joinpath(Sys.BINDIR, Base.julia_exename()),
                        advanced_cli::AbstractString=joinpath(project_dir, "advanced_cli.jl"),
                        output_dir::AbstractString="runs/launcher",
                        input_base_dir::AbstractString=dirname(abspath(base_config)),
                        threads::Int=1, num_trajectories::Int=1,
                        timeout_seconds::Real=3600, compiled_modules::Bool=true,
                        write_summary::Bool=false)
    executable = isabspath(julia_bin) ? String(julia_bin) : Sys.which(julia_bin)
    executable === nothing && throw(ArgumentError("Julia executable not found: $julia_bin"))
    for (name, path) in (("project_dir", project_dir), ("base_config", base_config),
                         ("julia_bin", executable), ("advanced_cli", advanced_cli),
                         ("input_base_dir", input_base_dir))
        ispath(path) || throw(ArgumentError("$name does not exist: $path"))
    end
    isfile(joinpath(project_dir, "Project.toml")) ||
        throw(ArgumentError("launcher project must contain Project.toml"))
    threads > 0 && num_trajectories > 0 || throw(ArgumentError("threads and num_trajectories must be positive"))
    isfinite(timeout_seconds) && timeout_seconds > 0 || throw(ArgumentError("timeout_seconds must be finite and positive"))
    LauncherConfig(abspath(project_dir), abspath(base_config), abspath(executable),
                   abspath(advanced_cli), abspath(output_dir), abspath(input_base_dir),
                   threads, num_trajectories, Float64(timeout_seconds), compiled_modules, write_summary)
end

"""Observed daily counts for one launcher output metric; missing days keep their indices."""
struct MetricTarget
    name::String
    observed::Vector{Union{Missing,Float64}}
    weight::Float64
    scale::Union{Nothing,Float64}
end

function MetricTarget(name::AbstractString, observed::AbstractVector;
                      weight::Real=1, scale::Union{Nothing,Real}=nothing)
    !isempty(name) || throw(ArgumentError("metric name must not be empty"))
    isfinite(weight) && weight > 0 || throw(ArgumentError("metric weight must be finite and positive"))
    scale === nothing || (isfinite(scale) && scale > 0) ||
        throw(ArgumentError("metric scale must be finite and positive"))
    values = Union{Missing,Float64}[ismissing(x) ? missing : Float64(x) for x in observed]
    all(x -> ismissing(x) || (isfinite(x) && x >= 0), values) ||
        throw(ArgumentError("observed counts must be nonnegative and finite, or missing"))
    any(!ismissing, values) || throw(ArgumentError("metric $name has no observations"))
    MetricTarget(String(name), values, Float64(weight), scale === nothing ? nothing : Float64(scale))
end

"""Read an unquoted `day,value` CSV. Blank/NA/missing/-1 values are missing, never zero."""
function load_observations(path::AbstractString)
    lines = readlines(path)
    isempty(lines) && throw(ArgumentError("empty observations file: $path"))
    header = strip.(split(first(lines), ','))
    di, vi = findfirst(==("day"), header), findfirst(==("value"), header)
    di !== nothing && vi !== nothing || throw(ArgumentError("$path requires day,value columns"))
    rows = Tuple{Int,Union{Missing,Float64}}[]
    previous = 0
    for (line_number, line) in enumerate(lines[2:end])
        isempty(strip(line)) && continue
        cells = strip.(split(line, ','; keepempty=true))
        length(cells) >= max(di, vi) || throw(ArgumentError("malformed CSV row $(line_number + 1) in $path"))
        day = tryparse(Int, cells[di])
        day !== nothing && day > previous || throw(ArgumentError("days must be positive, unique and increasing in $path"))
        raw = cells[vi]
        value = if lowercase(raw) in ("", "na", "missing", "-1")
            missing
        else
            parsed = tryparse(Float64, raw)
            parsed !== nothing && isfinite(parsed) && parsed >= 0 ||
                throw(ArgumentError("invalid observed count on day $day in $path"))
            parsed
        end
        push!(rows, (day, value))
        previous = day
    end
    isempty(rows) && throw(ArgumentError("no observation rows in $path"))
    values = Union{Missing,Float64}[missing for _ in 1:previous]
    for (day, value) in rows
        values[day] = value
    end
    values
end

# Paths may address a scalar or an indexed entry, e.g. imported_cases[1].params.num_infections.
function _path_parts(path::AbstractString)
    parts = Any[]
    for segment in split(path, '.')
        m = match(r"^([^\[\]]+)((?:\[\d+\])*)$", segment)
        m === nothing && throw(ArgumentError("invalid parameter path: $path"))
        push!(parts, String(m.captures[1]))
        for index in eachmatch(r"\[(\d+)\]", m.captures[2])
            i = parse(Int, index.captures[1])
            i > 0 || throw(ArgumentError("parameter indices are one-based: $path"))
            push!(parts, i)
        end
    end
    parts
end

function _get_path(config, path)
    node = config
    for part in _path_parts(path)
        node = node[part]
    end
    node
end

function _set_path!(config, path, value)
    parts = _path_parts(path)
    node = config
    for part in parts[1:end-1]
        node = node[part]
    end
    node[last(parts)] = value
    config
end

function _normalize_input_paths!(node, base)
    if node isa AbstractDict
        for (key, value) in node
            if value isa AbstractString && (endswith(key, "_path") ||
                    key in ("order_file", "order_data", "immunity_events"))
                path = isabspath(value) ? normpath(value) : normpath(joinpath(base, value))
                isfile(path) || throw(ArgumentError("launcher input $key does not exist: $path"))
                node[key] = path
            else
                _normalize_input_paths!(value, base)
            end
        end
    elseif node isa AbstractVector
        foreach(value -> _normalize_input_paths!(value, base), node)
    end
    node
end

struct LauncherEvaluator
    config::LauncherConfig
    base::Dict{String,Any}
    parameter_paths::Dict{Symbol,String}
    integer_parameters::Set{Symbol}
    targets::Vector{MetricTarget}
    smoothing_days::Int
    active_processes::IdDict{Task,Any}
end

function LauncherEvaluator(config::LauncherConfig, parameter_paths::AbstractDict,
                           targets::Vector{MetricTarget}; smoothing_days::Int=7,
                           integer_parameters=Symbol[])
    smoothing_days > 0 || throw(ArgumentError("smoothing_days must be positive"))
    !isempty(targets) && allunique(t.name for t in targets) ||
        throw(ArgumentError("provide at least one target, with unique metric names"))
    base = JSON.parsefile(config.base_config)
    for key in ("population_path", "stop_simulation_threshold", "transmission_probabilities",
                "mild_detection_prob", "contact_tracing", "imported_cases", "initial_conditions")
        haskey(base, key) || throw(ArgumentError("base launcher config is missing $key"))
    end
    _normalize_input_paths!(base, config.input_base_dir)
    paths = Dict(Symbol(k) => String(v) for (k, v) in parameter_paths)
    isempty(paths) && throw(ArgumentError("provide at least one parameter mapping"))
    allunique(values(paths)) || throw(ArgumentError("parameter paths must be unique"))
    for (name, path) in paths
        # School/class have documented launcher defaults, so permit adding these two optional keys.
        if path in ("transmission_probabilities.school", "transmission_probabilities.class")
            get!(base["transmission_probabilities"], last(split(path, '.')), 0.0)
        end
        value = try _get_path(base, path) catch
            throw(ArgumentError("parameter $name points to a missing field: $path"))
        end
        value isa Real && !(value isa Bool) && isfinite(value) ||
            throw(ArgumentError("parameter $name must point to a finite numeric scalar"))
        path in ("stop_simulation_time", "params_seed", "num_trajectories", "window_start", "checkpoint_time") &&
            throw(ArgumentError("$path is controlled by the adapter, not a fitted parameter"))
    end
    integers = Set(Symbol.(integer_parameters))
    issubset(integers, Set(keys(paths))) || throw(ArgumentError("unknown integer parameter"))
    LauncherEvaluator(config, base, paths, integers, targets, smoothing_days, IdDict{Task,Any}())
end

function _cancel_evaluations(evaluator::LauncherEvaluator)
    for process in values(evaluator.active_processes)
        try
            process_exited(process) || kill(process, Base.SIGKILL)
        catch
            # A process may exit between the check and kill. Its worker owns wait/cleanup.
        end
    end
    nothing
end

"""Make the exact JSON object used for one full-prefix launcher run."""
function render_candidate(evaluator::LauncherEvaluator, values::AbstractDict, horizon::Int, seed::Int)
    horizon > 0 || throw(ArgumentError("horizon must be positive"))
    Set(keys(values)) == Set(keys(evaluator.parameter_paths)) ||
        throw(ArgumentError("candidate names must match parameter mappings exactly"))
    candidate = deepcopy(evaluator.base)
    for (name, path) in evaluator.parameter_paths
        value = values[name]
        isfinite(value) || throw(ArgumentError("nonfinite parameter $name"))
        _set_path!(candidate, path, name in evaluator.integer_parameters ? round(Int, value) : value)
    end
    candidate["stop_simulation_time"] = horizon
    candidate["params_seed"] = seed
    candidate["num_trajectories"] = evaluator.config.num_trajectories
    # This adapter reruns from day zero; it never transfers simulator state between candidates.
    delete!(candidate, "checkpoint_time")
    candidate["window_start"] = 0
    candidate
end

function _smooth_at(values, day, window)
    bucket = values[max(1, day - window + 1):day]
    any(ismissing, bucket) && return missing
    mean(bucket)
end

"""Weighted normalized RMSE, averaged over trajectories. No zero-padding of short output."""
function score_daily(path::AbstractString, targets::Vector{MetricTarget}, horizon::Int;
                     smoothing_days::Int=7, expected_trajectories::Int=1)
    horizon > 0 && smoothing_days > 0 && expected_trajectories > 0 ||
        throw(ArgumentError("horizon, smoothing_days and expected_trajectories must be positive"))
    isempty(targets) && throw(ArgumentError("at least one metric is required"))
    components = Dict{String,Any}()
    jldopen(path, "r") do file
        ids = sort!(filter(k -> tryparse(Int, k) !== nothing, collect(keys(file))); by=x -> parse(Int, x))
        ids == string.(1:expected_trajectories) || error("missing or unexpected trajectory groups")
        for target in targets
            stop = min(horizon, length(target.observed))
            days = Int[]
            observed = Float64[]
            for day in 1:stop
                value = _smooth_at(target.observed, day, smoothing_days)
                ismissing(value) && continue
                push!(days, day)
                push!(observed, value)
            end
            isempty(days) && error("no usable observations for $(target.name) through day $horizon")
            scale = target.scale === nothing ? max(mean(abs.(observed)), 1.0) : target.scale
            losses = Float64[]
            for id in ids
                group = file[id]
                haskey(group, target.name) || error("trajectory $id lacks $(target.name)")
                raw = group[target.name]
                raw isa AbstractVector && length(raw) >= horizon || error("short or malformed $(target.name) trajectory $id")
                predicted = Float64.(raw[1:horizon])
                all(x -> isfinite(x) && x >= 0, predicted) || error("invalid $(target.name) trajectory $id")
                residuals = [_smooth_at(predicted, day, smoothing_days) - observed[i] for (i, day) in enumerate(days)]
                push!(losses, sqrt(mean(abs2, residuals)) / scale)
            end
            components[target.name] = Dict("score" => mean(losses), "scale" => scale,
                                          "weight" => target.weight, "days" => days,
                                          "trajectory_scores" => losses)
        end
    end
    score = sum(target.weight * components[target.name]["score"] for target in targets) /
            sum(target.weight for target in targets)
    (score=score, components=components)
end

function _write_json(path, value)
    open(path, "w") do io
        JSON.print(io, value, 2)
        println(io)
    end
end

function _evaluation_failure_hint(evaluator::LauncherEvaluator, horizon)
    root = evaluator.config.output_dir
    isdir(root) || return "\nLauncher output directory: $root"
    reports = filter(path -> isdir(path) && isfile(joinpath(path, "evaluation.json")),
                     readdir(root; join=true))
    sort!(reports; by=path -> mtime(joinpath(path, "evaluation.json")), rev=true)
    for directory in reports
        report = try JSON.parsefile(joinpath(directory, "evaluation.json")) catch; continue end
        get(report, "horizon", nothing) == horizon || continue
        get(report, "status", "") == "failed" || continue
        detail = get(report, "error", "unknown launcher failure")
        lines = String["", "Launcher failure: $detail",
            "Report: $(joinpath(directory, "evaluation.json"))",
            "Stderr: $(joinpath(directory, "stderr.log"))"]
        log = joinpath(directory, "stderr.log")
        if isfile(log)
            contents = readlines(log)
            if !isempty(contents)
                push!(lines, "Launcher stderr:")
                if length(contents) > 40
                    append!(lines, contents[1:20])
                    push!(lines, "[... middle of stderr omitted; see the full log above ...]")
                    append!(lines, contents[end-19:end])
                else
                    append!(lines, contents)
                end
            end
        end
        return join(lines, "\n")
    end
    "\nLauncher output directory: $root"
end

function _launcher_command(config, config_path, daily_path, summary_path)
    args = [config.julia_bin, "--startup-file=no", "--project=$(config.project_dir)",
            "--threads=$(config.threads)"]
    !config.compiled_modules && push!(args, "--compiled-modules=no")
    append!(args, [config.advanced_cli, config_path, "--output-daily", daily_path])
    config.write_summary && append!(args, ["--output-summary", summary_path])
    Cmd(Cmd(args); dir=config.project_dir)
end

function (evaluator::LauncherEvaluator)(values, horizon, seed)
    candidate = render_candidate(evaluator, values, horizon, seed)
    config = evaluator.config
    mkpath(config.output_dir)
    directory = mktempdir(config.output_dir; prefix="day_$(horizon)_seed_$(seed)_", cleanup=false)
    config_path = joinpath(directory, "config_candidate.json")
    daily_path = joinpath(directory, "output_daily.jld2")
    summary_path = joinpath(directory, "summary.jld2")
    _write_json(config_path, candidate)
    cmd = _launcher_command(config, config_path, daily_path, summary_path)
    report = Dict{String,Any}("status" => "failed", "score" => nothing,
        "horizon" => horizon, "seed" => seed, "command" => collect(cmd),
        "fitted_parameters" => Dict(String(k) => v for (k,v) in values),
        "working_directory" => config.project_dir, "timeout_seconds" => config.timeout_seconds,
        "timed_out" => false, "exit_code" => nothing)
    score = Inf
    try
        open(joinpath(directory, "stdout.log"), "w") do stdout_io
            open(joinpath(directory, "stderr.log"), "w") do stderr_io
                process = run(pipeline(cmd; stdout=stdout_io, stderr=stderr_io); wait=false)
                evaluator.active_processes[current_task()] = process
                try
                    status = timedwait(() -> process_exited(process), config.timeout_seconds; pollint=min(0.1, config.timeout_seconds))
                    if status == :timed_out
                        report["timed_out"] = true
                        kill(process, Base.SIGKILL)
                    end
                    wait(process)
                    report["exit_code"] = process.exitcode
                    report["timed_out"] && error("launcher timed out")
                    success(process) || error("launcher exited with code $(process.exitcode)")
                finally
                    try
                        if !process_exited(process)
                            kill(process, Base.SIGKILL)
                            wait(process)
                        end
                    finally
                        delete!(evaluator.active_processes, current_task())
                    end
                end
            end
        end
        if config.write_summary
            isfile(summary_path) || error("launcher summary is missing")
            jldopen(summary_path, "r") do file
                haskey(file, "num_infections") && length(file["num_infections"]) == config.num_trajectories ||
                    error("launcher summary has an unexpected trajectory count")
            end
        end
        result = score_daily(daily_path, evaluator.targets, horizon;
            smoothing_days=evaluator.smoothing_days, expected_trajectories=config.num_trajectories)
        isfinite(result.score) || error("nonfinite score")
        score = result.score
        report["score"] = score
        report["metrics"] = result.components
        report["status"] = "completed"
    catch err
        err isa InterruptException && rethrow()
        report["error"] = sprint(showerror, err)
    finally
        _write_json(joinpath(directory, "evaluation.json"), report)
    end
    score
end
