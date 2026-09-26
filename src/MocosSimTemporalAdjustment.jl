module MocosSimTemporalAdjustment

using Random
using Serialization
using Statistics

export Parameter, SearchOptions, Candidate, temporal_search, load_checkpoint

"""A bounded simulation parameter. `scale` is `:linear` or `:log`."""
struct Parameter
    name::Symbol
    lower::Float64
    upper::Float64
    scale::Symbol
    function Parameter(name::Symbol, lower::Real, upper::Real; scale::Symbol=:linear)
        0 <= lower < upper || throw(ArgumentError("expected 0 <= lower < upper"))
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
    initial_radius::Float64 = 0.20
    radius_decay::Float64 = 0.75
    min_separation::Float64 = 0.03
    seed::Int = 1
    checkpoint_dir::String = "checkpoints"
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
    issorted(options.horizons) && all(>(0), options.horizons) ||
        throw(ArgumentError("horizons must be positive and sorted"))
    options.survivors > 0 || throw(ArgumentError("survivors must be positive"))
    options.trials_per_survivor >= 0 || throw(ArgumentError("trials_per_survivor cannot be negative"))
    options.random_starts > 0 || throw(ArgumentError("random_starts must be positive"))
    options.repetitions > 0 || throw(ArgumentError("repetitions must be positive"))
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

function _evaluate(evaluator, values, horizon, repetitions, rng)
    scores = Float64[]
    for _ in 1:repetitions
        score = Float64(evaluator(copy(values), horizon, rand(rng, 1:typemax(Int))))
        isfinite(score) && push!(scores, score)
    end
    Candidate(copy(values), isempty(scores) ? Inf : median(scores), horizon, scores)
end

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
        candidate in selected || push!(selected, candidate)
        length(selected) == min(n, length(candidates)) && break
    end
    selected
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

"""
    temporal_search(evaluator, parameters; options=SearchOptions(), initial=[])

Fit progressively longer prefixes of a time series. `evaluator(values, horizon, seed)`
must run the simulator and return a finite loss (lower is better). At each horizon,
the prior stage's survivors are re-scored, locally perturbed, and combined with
fresh random candidates. Replicate scores are combined by their median.

Every completed stage is atomically serialized before the next stage begins. The
return value is the final stage's ranked survivor vector.
"""
function temporal_search(evaluator, parameters::Vector{Parameter};
                         options::SearchOptions=SearchOptions(),
                         initial::Vector{Dict{Symbol,Float64}}=Dict{Symbol,Float64}[])
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

    for (stage, horizon) in enumerate(options.horizons)
        proposals = Dict{Symbol,Float64}[]
        append!(proposals, parents)
        random_count = stage == 1 ? options.random_starts : max(1, options.random_starts ÷ 4)
        append!(proposals, (_random_values(rng, parameters) for _ in 1:random_count))
        if stage > 1
            for parent in parents, _ in 1:options.trials_per_survivor
                push!(proposals, _mutate(rng, parent, parameters, radius))
            end
        end

        candidates = [_evaluate(evaluator, values, horizon, options.repetitions, rng)
                      for values in proposals]
        survivors = _select(candidates, options.survivors,
                            options.min_separation, parameters)
        state = (stage=stage, horizon=horizon, radius=radius,
                 survivors=survivors, options=options, parameters=parameters)
        _save_checkpoint(joinpath(options.checkpoint_dir,
                                  "stage_$(lpad(stage, 3, '0'))_day_$(horizon).jls"), state)
        parents = [copy(candidate.values) for candidate in survivors]
        radius = max(radius * options.radius_decay, 1e-4)
    end

    state = load_checkpoint(joinpath(options.checkpoint_dir,
        "stage_$(lpad(length(options.horizons), 3, '0'))_day_$(last(options.horizons)).jls"))
    state.survivors
end

end
