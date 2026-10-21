"""Execution controls, separate from search options so existing checkpoints remain readable.

Workers are cooperative tasks that wait on independent launcher processes; the
optimizer itself does not need multiple Julia threads. Each worker evaluates one
candidate's repetitions in sequence. Candidate results retain proposal order.
"""
struct ExecutionOptions
    max_workers::Int
    progress::Bool
    progress_interval_seconds::Float64
    function ExecutionOptions(; max_workers::Int=1, progress::Bool=false,
                              progress_interval_seconds::Real=30)
        max_workers > 0 || throw(ArgumentError("max_workers must be positive"))
        isfinite(progress_interval_seconds) && progress_interval_seconds > 0 ||
            throw(ArgumentError("progress_interval_seconds must be finite and positive"))
        new(max_workers, progress, Float64(progress_interval_seconds))
    end
end

function _evaluate_candidates(evaluator, proposals, horizon, seeds, execution::ExecutionOptions;
                              round::Int=1, max_rounds::Int=1)
    isempty(proposals) && return Candidate[]
    workers = min(execution.max_workers, length(proposals))
    total = length(proposals) * length(seeds)
    started = time()
    completed = Ref(0)
    failed = Ref(0)
    last_report = Ref(started)
    first_error = Ref{Any}(nothing)
    if execution.progress
        println(stderr, "day=$horizon round=$round/$max_rounds workers=$workers ",
                "candidates=$(length(proposals)) runs=$total")
    end
    function on_replicate(score)
        first_error[] === nothing || throw(first_error[])
        completed[] += 1
        isfinite(score) || (failed[] += 1)
        now = time()
        if execution.progress && (completed[] == 1 || completed[] == total ||
                                   now - last_report[] >= execution.progress_interval_seconds)
            elapsed = max(now - started, 0.0)
            remaining = elapsed / completed[] * (total - completed[])
            println(stderr, "day=$horizon round=$round/$max_rounds ",
                    "completed=$(completed[])/$total failed=$(failed[]) ",
                    "elapsed_minutes=$(Base.round(elapsed / 60; digits=1)) ",
                    "eta_minutes=$(Base.round(remaining / 60; digits=1))")
            last_report[] = now
        end
        nothing
    end
    if workers == 1
        return [_evaluate(evaluator, values, horizon, seeds; on_replicate=on_replicate)
                for values in proposals]
    end
    jobs = Channel{Int}(length(proposals))
    for index in eachindex(proposals)
        put!(jobs, index)
    end
    close(jobs)
    results = Vector{Candidate}(undef, length(proposals))
    # @async deliberately keeps scoring/JLD2 access on one scheduler thread.
    # Simulation processes run in parallel while these tasks wait for them.
    tasks = Task[]
    try
        @sync for _ in 1:workers
            task = @async begin
                for index in jobs
                    first_error[] === nothing || break
                    try
                        results[index] = _evaluate(evaluator, proposals[index], horizon, seeds;
                                                   on_replicate=on_replicate)
                    catch err
                        if first_error[] === nothing
                            first_error[] = err
                            _cancel_evaluations(evaluator)
                        end
                        break
                    end
                end
            end
            push!(tasks, task)
        end
    catch err
        # In particular, Ctrl-C while waiting for the queue must not orphan simulators.
        first_error[] = err
        _cancel_evaluations(evaluator)
        for task in tasks
            try
                wait(task)
            catch
            end
        end
        rethrow()
    end
    first_error[] === nothing || throw(first_error[])
    results
end
