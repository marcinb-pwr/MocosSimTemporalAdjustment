# MocosSimTemporalAdjustment

A small, restart-friendly search procedure for fitting MocosSim to progressively
longer prefixes of a constrained period. It deliberately resembles a productive
manual workflow: keep several plausible scenarios, perturb each of them, inspect
their performance on a little more data, and only then narrow the search.

## Why a temporal candidate ladder?

A single large CMA-ES run can spend substantial compute distinguishing parameter
sets that are indistinguishable early in the outbreak, or exploit one noisy run.
This package instead uses a **beam of diverse candidates**:

1. Explore broadly on the first `X` days (normally 14).
2. Keep several good, separated candidates rather than only the winner.
3. Increase `X`, re-run every survivor on the longer interval, and search its
   neighbourhood. Add a few random candidates so an early mistake is recoverable.
4. Aggregate repeated stochastic simulations with the median.
5. Atomically checkpoint every rung before continuing.

This is not presented as a universally superior optimizer. It is a reliable
orchestration layer in which a human can seed interesting guesses and compare the
candidate trajectories at each checkpoint.

## Connect it to MocosSimLauncher

The package intentionally makes no assumptions about the launcher's JSON schema
or the observed-data loss. Supply one function with this contract:

```julia
evaluator(values::Dict{Symbol,Float64}, horizon::Int, seed::Int)::Real
```

That function should copy a base JSON configuration into an isolated run
directory, replace the fitted values, set the simulation seed and end time, run
`MocosSimLauncher`, and compare its output only through `horizon`. Return a loss
where lower is better. A non-finite result is treated as a failed simulation.

```julia
using MocosSimTemporalAdjustment

parameters = [
    Parameter(:contact_rate, 0.03, 1.2; scale=:log),
    Parameter(:reporting_fraction, 0.05, 1.0),
    Parameter(:detection_delay, 1, 14),
]

function launch_and_score(values, horizon, seed)
    # render_config(base_config, values; stop_day=horizon, seed=seed)
    # run(`MocosSimLauncher generated-config.json`)
    # return weighted_loss(simulation_output, observations[1:horizon])
end

options = SearchOptions(
    horizons=collect(14:14:112),
    survivors=16,
    random_starts=128,
    trials_per_survivor=12,
    repetitions=3,
    seed=20260926,
    checkpoint_dir="runs/autumn-fit/checkpoints",
)

handmade_guesses = [Dict(:contact_rate => 0.24,
                         :reporting_fraction => 0.6,
                         :detection_delay => 5.0)]

finalists = temporal_search(launch_and_score, parameters;
                            options=options, initial=handmade_guesses)
```

The evaluator owns process isolation, timeouts, and the precise scientific loss
because those depend on the launcher and data formats. It should use a unique
directory per call if simulations run concurrently. The search itself is
currently sequential and deterministic for a fixed evaluator and seed; that is a
useful correctness baseline before adding distributed execution.

## Choosing a loss

Record component losses as well as the scalar returned to this package. A useful
starting point is a weighted sum of errors for cases, hospital occupancy, deaths,
and any intervention-specific targets. Normalize each series (for example by its
measurement uncertainty or a fixed domain scale) so the numerically largest
series does not dominate. Decide weights before searching, and keep a held-out
tail that is not involved in candidate selection.

For stochastic runs, start with one replicate during broad exploration and use
three or more when promoting close candidates. The current `repetitions` setting
is deliberately uniform and conservative; adaptive replication is a natural next
step once launcher integration is measured.

## Inspecting and resuming

Each `stage_NNN_day_X.jls` file contains the horizon, radius, parameters, options,
and ranked survivors:

```julia
stage = load_checkpoint("runs/autumn-fit/checkpoints/stage_003_day_42.jls")
stage.survivors[1].values
stage.survivors[1].replicate_scores
```

To restart after examining a stage, pass its survivor values as `initial` and set
`horizons` to the remaining horizons. Use a new checkpoint directory so the
original audit trail remains intact.

## Recommended first experiment

Run the procedure against a cheap synthetic target whose true parameters are
known. Confirm parameter recovery, deterministic checkpointing, launcher failure
handling, and the absence of information after each horizon. Then replay one of
the old handmade fits and compare trajectories—not merely aggregate loss—at every
14-day rung. Only after that should the candidate counts or parallelism be scaled
up.
