"""A day-based IntervalsModulations vector whose current interval is fitted."""
struct TemporalParameter
    name::Symbol
    path::String
    lower::Float64
    upper::Float64
    scale::Symbol
    times::Vector{Float64}
    values::Vector{Float64}
    function TemporalParameter(name, path, lower, upper, times, values; scale=:linear)
        bound = Parameter(Symbol(name), lower, upper; scale=scale)
        ts, vs = Float64.(times), Float64.(values)
        all(isfinite, ts) && issorted(ts) && allunique(ts) && all(>(0), ts) ||
            throw(ArgumentError("temporal interval_times must be finite, positive and strictly increasing"))
        length(vs) == length(ts) + 1 && all(isfinite, vs) ||
            throw(ArgumentError("temporal interval_values must contain one more finite value than interval_times"))
        all(v -> bound.lower <= v <= bound.upper, vs) ||
            throw(ArgumentError("temporal baseline values must be within the configured bounds"))
        new(bound.name, String(path), bound.lower, bound.upper, bound.scale, ts, vs)
    end
end

Base.isequal(a::TemporalParameter, b::TemporalParameter) =
    all(isequal(getfield(a, key), getfield(b, key)) for key in fieldnames(TemporalParameter))
Base.:(==)(a::TemporalParameter, b::TemporalParameter) = isequal(a, b)

_temporal_name(t, index) = Symbol(t.name, "_", index)
_temporal_index(t, horizon) = searchsortedlast(t.times, horizon) + 1

function _temporal_parameters(temporal)
    [Parameter(_temporal_name(t, i), t.lower, t.upper; scale=t.scale)
     for t in temporal for i in eachindex(t.values)]
end

_temporal_defaults(temporal) = Dict(_temporal_name(t, i) => t.values[i]
                                   for t in temporal for i in eachindex(t.values))

function _active_parameters(parameters, temporal, horizon)
    isempty(temporal) && return parameters
    temporal_names = Set(p.name for p in _temporal_parameters(temporal))
    active_names = Set(_temporal_name(t, _temporal_index(t, horizon)) for t in temporal)
    [p for p in parameters if !(p.name in temporal_names) || p.name in active_names]
end

# Histories stay attached to a survivor, including for fresh random proposals.
function _random_proposal(rng, parameters, temporal, parents)
    isempty(temporal) && return _random_values(rng, parameters)
    inherited = isempty(parents) ? _temporal_defaults(temporal) : copy(rand(rng, parents))
    merge!(inherited, _random_values(rng, parameters))
end

function _mutate_proposal(rng, parent, parameters, radius, temporal)
    isempty(temporal) && return _mutate(rng, parent, parameters, radius)
    merge(copy(parent), _mutate(rng, parent, parameters, radius))
end
