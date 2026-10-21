module MocosSimTemporalAdjustment

using Random
using Serialization
using Statistics
using CodecZlib
using JSON
using JLD2
using TOML

export Parameter, TemporalParameter, SearchOptions, ExecutionOptions, Candidate, temporal_search, load_checkpoint,
       day_horizons, LauncherConfig, MetricTarget, LauncherEvaluator,
       load_observations, score_daily, render_candidate, fit_launcher, load_fit_config

"""A bounded simulation parameter. `scale` is `:linear` or `:log`."""
struct Parameter
    name::Symbol
    lower::Float64
    upper::Float64
    scale::Symbol
    function Parameter(name::Symbol, lower::Real, upper::Real; scale::Symbol=:linear)
        isfinite(lower) && isfinite(upper) && 0 <= lower < upper ||
            throw(ArgumentError("expected finite 0 <= lower < upper"))
        scale in (:linear, :log) || throw(ArgumentError("scale must be :linear or :log"))
        scale == :log && lower == 0 && throw(ArgumentError("a log-scaled lower bound must be positive"))
        new(name, Float64(lower), Float64(upper), scale)
    end
end

Base.@kwdef struct SearchOptions
    horizons::Vector{Int} = collect(14:14:84)
    survivors::Int = 12
    trials_per_survivor::Int = 8
    random_starts::Int = 48
    repetitions::Int = 1
    max_rounds_per_horizon::Int = 1
    score_tolerance::Union{Nothing,Float64} = nothing
    require_tolerance::Bool = true
    initial_radius::Float64 = 0.20
    radius_decay::Float64 = 0.75
    min_separation::Float64 = 0.03
    seed::Int = 1
    checkpoint_dir::String = "checkpoints"
end

"""Day prefixes, including `end_day` even when the increment does not divide it."""
function day_horizons(; start_day::Int=14, step_days::Int=14, end_day::Int=84)
    0 < start_day <= end_day || throw(ArgumentError("expected 0 < start_day <= end_day"))
    step_days > 0 || throw(ArgumentError("step_days must be positive"))
    days = collect(start_day:step_days:end_day)
    last(days) == end_day || push!(days, end_day)
    days
end

"""One evaluated parameter set. Lower scores are better."""
struct Candidate
    values::Dict{Symbol,Float64}
    score::Float64
    horizon::Int
    replicate_scores::Vector{Float64}
end

function _validate(parameters, options)
    isempty(parameters) && throw(ArgumentError("at least one parameter is required"))
    isempty(options.horizons) && throw(ArgumentError("at least one horizon is required"))
    issorted(options.horizons) && all(>(0), options.horizons) &&
        allunique(options.horizons) ||
        throw(ArgumentError("horizons must be positive and strictly increasing"))
    allunique(p.name for p in parameters) || throw(ArgumentError("parameter names must be unique"))
    options.survivors > 0 || throw(ArgumentError("survivors must be positive"))
    options.trials_per_survivor >= 0 || throw(ArgumentError("trials_per_survivor cannot be negative"))
    options.random_starts > 0 || throw(ArgumentError("random_starts must be positive"))
    options.repetitions > 0 || throw(ArgumentError("repetitions must be positive"))
    options.max_rounds_per_horizon > 0 || throw(ArgumentError("max_rounds_per_horizon must be positive"))
    options.score_tolerance === nothing ||
        (isfinite(options.score_tolerance) && options.score_tolerance >= 0) ||
        throw(ArgumentError("score_tolerance must be finite and nonnegative"))
    isfinite(options.initial_radius) && options.initial_radius > 0 ||
        throw(ArgumentError("initial_radius must be finite and positive"))
    isfinite(options.min_separation) && options.min_separation >= 0 ||
        throw(ArgumentError("min_separation must be finite and nonnegative"))
    0 < options.radius_decay <= 1 || throw(ArgumentError("radius_decay must be in (0, 1]"))
end

_unit(p::Parameter, value) = p.scale == :log ?
    (log(value) - log(p.lower)) / (log(p.upper) - log(p.lower)) :
    (value - p.lower) / (p.upper - p.lower)

_value(p::Parameter, unit) = p.scale == :log ?
    exp(log(p.lower) + unit * (log(p.upper) - log(p.lower))) :
    p.lower + unit * (p.upper - p.lower)

function _random_values(rng, parameters)
    Dict(p.name => _value(p, rand(rng)) for p in parameters)
end

function _mutate(rng, values, parameters, radius)
    Dict(p.name => _value(p, clamp(_unit(p, values[p.name]) + radius * randn(rng), 0, 1))
         for p in parameters)
end

include("temporal.jl")

function _evaluate(evaluator, values, horizon, seeds; on_replicate=score -> nothing)
    scores = Float64[]
    for seed in seeds
        score = Float64(evaluator(copy(values), horizon, seed))
        push!(scores, isfinite(score) ? score : Inf)
        on_replicate(last(scores))
    end
    # A failed replicate cannot make an unreliable parameter set look better.
    Candidate(copy(values), all(isfinite, scores) ? median(scores) : Inf, horizon, scores)
end

include("execution.jl")

function _distance(a, b, parameters)
    sqrt(sum((_unit(p, a[p.name]) - _unit(p, b[p.name]))^2 for p in parameters))
end

function _select(candidates, n, separation, parameters)
    selected = Candidate[]
    for candidate in sort(candidates; by=c -> c.score)
        all(_distance(candidate.values, other.values, parameters) >= separation for other in selected) &&
            push!(selected, candidate)
        length(selected) == n && break
    end
    # Diversity is a preference, not a reason to return fewer than requested.
    for candidate in sort(candidates; by=c -> c.score)
        length(selected) >= min(n, length(candidates)) && break
        candidate in selected || push!(selected, candidate)
    end
    sort!(selected; by=c -> c.score)
end

function _save_checkpoint(path, state)
    mkpath(dirname(path))
    temporary = path * ".tmp"
    open(temporary, "w") do io
        serialize(io, state)
    end
    mv(temporary, path; force=true)
end

"""Load a stage checkpoint produced by [`temporal_search`](@ref)."""
load_checkpoint(path::AbstractString) = open(deserialize, path)

# Adapters may provide actionable diagnostics without coupling the search to their I/O.
_evaluation_failure_hint(evaluator, horizon) = ""
_cancel_evaluations(evaluator) = nothing

"""
    temporal_search(evaluator, parameters; options=SearchOptions(), initial=[],
                    resume_from=nothing, execution=ExecutionOptions())

Fit progressively longer prefixes of a time series. `evaluator(values, horizon, seed)`
must run the simulator and return a finite loss (lower is better). At each horizon,
the prior stage's survivors are re-scored, locally perturbed, and combined with
fresh random candidates. Repeat up to `max_rounds_per_horizon` rounds, stopping
early when the best score reaches `score_tolerance` (when configured). If a
mandatory tolerance is missed, save the stage and stop before the next horizon.
All replicates must be finite; successful replicate scores use their median.

Every completed stage is atomically serialized before the next stage begins. The
return value is the final stage's ranked survivor vector. `resume_from` restores
the optimizer RNG and radius after an accepted stage; search options (except
the checkpoint directory) and parameter definitions must match.
`execution.max_workers` bounds concurrent candidate evaluations and may change
on resume. Proposal RNG generation and result ordering do not depend on scheduling.
"""
function temporal_search(evaluator, parameters::Vector{Parameter};
                         options::SearchOptions=SearchOptions(),
                         initial::Vector{Dict{Symbol,Float64}}=Dict{Symbol,Float64}[],
                         resume_from::Union{Nothing,AbstractString}=nothing,
                         warm_start_from::Union{Nothing,AbstractString}=nothing,
                         temporal::Vector{TemporalParameter}=TemporalParameter[],
                         execution::ExecutionOptions=ExecutionOptions())
    resume_from !== nothing && warm_start_from !== nothing &&
        throw(ArgumentError("resume_from and warm_start_from are mutually exclusive"))
    isempty(temporal) || all(p -> p in parameters, _temporal_parameters(temporal)) ||
        throw(ArgumentError("parameters must include all expanded temporal entries"))
    _validate(parameters, options)
    for guess in initial, parameter in parameters
        haskey(guess, parameter.name) ||
            throw(ArgumentError("initial guess is missing $(parameter.name)"))
        parameter.lower <= guess[parameter.name] <= parameter.upper ||
            throw(ArgumentError("initial $(parameter.name) is outside its bounds"))
    end
    rng = MersenneTwister(options.seed)
    parents = copy(initial)
    radius = options.initial_radius
    first_stage = 1
    survivors = Candidate[]
    checkpoint_path = resume_from === nothing ? warm_start_from : resume_from
    if checkpoint_path !== nothing
        isempty(initial) || throw(ArgumentError("initial and resume_from are mutually exclusive"))
        saved = load_checkpoint(checkpoint_path)
        hasproperty(saved, :schema_version) && saved.schema_version == 1 ||
            throw(ArgumentError("checkpoint does not support exact resume"))
        if warm_start_from === nothing
            isequal(saved.parameters, parameters) || throw(ArgumentError("resume parameters differ; use warm_start_from to add temporal vectors"))
            isequal(get(saved, :temporal, TemporalParameter[]), temporal) ||
                throw(ArgumentError("resume temporal definitions differ"))
        else
            !isempty(temporal) && isempty(get(saved, :temporal, TemporalParameter[])) ||
                throw(ArgumentError("warm start supports adding temporal vectors to a scalar-only checkpoint"))
            temporal_names = Set(p.name for p in _temporal_parameters(temporal))
            isequal(saved.parameters, [p for p in parameters if !(p.name in temporal_names)]) ||
                throw(ArgumentError("warm start scalar parameters differ"))
        end
        if warm_start_from !== nothing
            length(options.horizons) >= saved.stage &&
                options.horizons[1:saved.stage] == saved.options.horizons[1:saved.stage] ||
                throw(ArgumentError("warm start must preserve the completed horizon prefix"))
        end
        all(isequal(getfield(saved.options, k), getfield(options, k))
            for k in fieldnames(SearchOptions)
            if k != :checkpoint_dir && !(warm_start_from !== nothing && k == :horizons)) ||
            throw(ArgumentError("resume search options differ"))
        saved.accepted || throw(ArgumentError("cannot resume past a stage that failed its tolerance"))
        rng = deepcopy(saved.rng)
        parents = [copy(c.values) for c in saved.survivors]
        if warm_start_from !== nothing
            parents = [merge(_temporal_defaults(temporal), parent) for parent in parents]
        end
        radius = saved.next_radius
        first_stage = saved.stage + 1
        survivors = saved.survivors
        warm_start_from !== nothing && first_stage > length(options.horizons) &&
            throw(ArgumentError("warm start needs at least one remaining horizon"))
    end

    for (stage, horizon) in enumerate(options.horizons)
        stage < first_stage && continue
        active_parameters = _active_parameters(parameters, temporal, horizon)
        # Paired seeds make comparisons fair across candidates and refinement rounds.
        seeds = rand(rng, 1:typemax(Int32), options.repetitions)
        rounds = 0
        for round in 1:options.max_rounds_per_horizon
            rounds = round
            proposals = Dict{Symbol,Float64}[]
            append!(proposals, parents)
            random_count = stage == 1 && round == 1 ? options.random_starts : max(1, options.random_starts ÷ 4)
            append!(proposals, (_random_proposal(rng, active_parameters, temporal, parents) for _ in 1:random_count))
            if stage > 1 || round > 1
                for parent in parents, _ in 1:options.trials_per_survivor
                    push!(proposals, _mutate_proposal(rng, parent, active_parameters, radius, temporal))
                end
            end
            candidates = _evaluate_candidates(evaluator, proposals, horizon, seeds, execution;
                                             round=round, max_rounds=options.max_rounds_per_horizon)
            survivors = _select(candidates, options.survivors, options.min_separation, active_parameters)
            parents = [copy(candidate.values) for candidate in survivors]
            options.score_tolerance !== nothing &&
                first(survivors).score <= options.score_tolerance && break
        end
        met = options.score_tolerance === nothing || first(survivors).score <= options.score_tolerance
        accepted = met || !options.require_tolerance
        next_radius = max(radius * options.radius_decay, 1e-4)
        state = (schema_version=1, stage=stage, horizon=horizon, radius=radius,
                 next_radius=next_radius, rng=deepcopy(rng), rounds=rounds,
                 replicate_seeds=seeds, tolerance_met=met, accepted=accepted,
                 survivors=survivors, options=options, parameters=parameters)
        isempty(temporal) || (state = merge(state, (temporal=temporal,)))
        warm_start_from === nothing || (state = merge(state, (warm_start_from=abspath(warm_start_from),)))
        _save_checkpoint(joinpath(options.checkpoint_dir,
                                  "stage_$(lpad(stage, 3, '0'))_day_$(horizon).jls"), state)
        if !accepted
            if !isfinite(first(survivors).score)
                error("All candidate evaluations failed at day $horizon; checkpoint saved. " *
                      "This is an evaluation failure, not a score-tolerance mismatch." *
                      _evaluation_failure_hint(evaluator, horizon))
            end
            error("Score tolerance $(options.score_tolerance) not reached at day $horizon " *
                  "after $rounds rounds (best=$(first(survivors).score)); checkpoint saved")
        end
        radius = next_radius
    end

    survivors
end

include("launcher.jl")
include("fit_config.jl")

end
