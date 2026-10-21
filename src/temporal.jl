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

"""Hard adjacent-value limit and soft jump/curvature and reversal penalties."""
struct TemporalControls
    max_step::Union{Nothing,Float64}
    smoothness_weight::Float64
    reversal_weight::Float64
    function TemporalControls(; max_step::Union{Nothing,Real}=nothing,
                              smoothness_weight::Real=0, reversal_weight::Real=0)
        max_step === nothing || (isfinite(max_step) && max_step > 0) ||
            throw(ArgumentError("temporal max_step must be finite and positive"))
        all(x -> isfinite(x) && x >= 0, (smoothness_weight, reversal_weight)) ||
            throw(ArgumentError("temporal penalty weights must be finite and nonnegative"))
        new(max_step === nothing ? nothing : Float64(max_step),
            Float64(smoothness_weight), Float64(reversal_weight))
    end
end

function _temporal_bounds(t, values, horizon, controls)
    index = _temporal_index(t,horizon)
    controls.max_step === nothing && return (t.lower,t.upper)
    # There is no preceding interval for entry 1; anchor it to the seed value.
    anchor = index == 1 ? t.values[1] : values[_temporal_name(t,index-1)]
    (max(t.lower,anchor-controls.max_step), min(t.upper,anchor+controls.max_step))
end

function _constrain_temporal!(values, temporal, horizon, controls)
    controls.max_step === nothing && return values
    for t in temporal
        key = _temporal_name(t,_temporal_index(t,horizon))
        lower,upper = _temporal_bounds(t,values,horizon,controls)
        values[key] = clamp(values[key],lower,upper)
    end
    values
end

function _temporal_penalty(values, temporal, horizon, controls)
    jumps, reversals = Float64[],Float64[]
    for t in temporal
        # Future seed values must not affect the score at the current horizon.
        prefix = [values[_temporal_name(t,i)] for i in 1:_temporal_index(t,horizon)]
        differences = diff(prefix)
        push!(jumps, isempty(differences) ? 0.0 :
            mean(abs.(differences)) + (length(differences)<2 ? 0.0 : mean(abs.(diff(differences)))))
        signs = [sign(x) for x in differences if abs(x)>1e-12]
        push!(reversals,length(signs)<2 ? 0.0 :
            count(i->signs[i]!=signs[i-1],2:length(signs))/(length(signs)-1))
    end
    smoothness = isempty(jumps) ? 0.0 : mean(jumps)
    reversal = isempty(reversals) ? 0.0 : mean(reversals)
    (smoothness=smoothness,reversal=reversal,
     total=controls.smoothness_weight*smoothness+controls.reversal_weight*reversal)
end

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
function _random_proposal(rng, parameters, temporal, parents;
                          horizon::Int=0, controls::TemporalControls=TemporalControls())
    isempty(temporal) && return _random_values(rng, parameters)
    inherited = isempty(parents) ? _temporal_defaults(temporal) : copy(rand(rng, parents))
    controls.max_step === nothing && return merge!(inherited, _random_values(rng, parameters))
    active = Dict(_temporal_name(t,_temporal_index(t,horizon))=>t for t in temporal)
    for p in parameters
        lower,upper = haskey(active,p.name) ? _temporal_bounds(active[p.name],inherited,horizon,controls) : (p.lower,p.upper)
        u = rand(rng)
        inherited[p.name] = p.scale == :log ? exp(log(lower)+u*(log(upper)-log(lower))) : lower+u*(upper-lower)
    end
    inherited
end

function _mutate_proposal(rng, parent, parameters, radius, temporal;
                          horizon::Int=0, controls::TemporalControls=TemporalControls())
    isempty(temporal) && return _mutate(rng, parent, parameters, radius)
    _constrain_temporal!(merge(copy(parent), _mutate(rng, parent, parameters, radius)),temporal,horizon,controls)
end

function _report_temporal_proposals(io, temporal, proposals, horizon, round, parent_count, random_count)
    isempty(temporal) && return
    mutated = length(proposals) - parent_count - random_count
    println(io, "day=$horizon round=$round retained=$parent_count random=$random_count mutated=$mutated")
    for t in temporal
        index = _temporal_index(t, horizon)
        name = _temporal_name(t, index)
        values = [p[name] for p in proposals]
        lower = index == 1 ? 0.0 : t.times[index-1]
        upper = index > length(t.times) ? Inf : t.times[index]
        println(io, "day=$horizon round=$round temporal=$name interval=[$lower,$upper) ",
                "proposed_min=$(minimum(values)) proposed_max=$(maximum(values)) ",
                "distinct=$(length(unique(values)))")
    end
end
