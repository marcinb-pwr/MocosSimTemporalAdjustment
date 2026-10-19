# MocosSimTemporalAdjustment

Fit MocosSim parameters to progressively longer day prefixes, keeping several
plausible candidates at each step. Runs sequentially and invokes
MocosSimLauncher in a separate Julia process. Tested with Julia **1.7.0** and
launcher branch **`mbodych/class_and_school`**, revision
`4c0149d0f3a5037acd51a4c9f08e510e4414e920`.

## Run a small test locally first

Use a Julia 1.7.0 executable for every command below (`julia --version`).
These commands assume sibling repository directories, starting in their parent:

```sh
git clone --branch mbodych/class_and_school https://github.com/marcinb-pwr/MocosSimLauncher.git
# MocosSimTemporalAdjustment should contain this integration's changes.
julia --project=MocosSimLauncher -e 'using Pkg; Pkg.instantiate()'
julia --project=MocosSimTemporalAdjustment -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
julia --project=MocosSimTemporalAdjustment MocosSimTemporalAdjustment/scripts/smoke_launcher.jl ./MocosSimLauncher
```

The last command generates a **six-person synthetic population**, a seed JSON,
observations, and an editable `fit.toml`. It runs **four real launcher processes**
at horizons of 2 and 4 days, fitting school/class parameters. No production data
or environment variables are needed. The first invocation can take longer while
Julia compiles dependencies. Use the launcher's checked-in Manifest; its MocosSim
dependency is not a registered General package.

Expected last lines:

```text
PASS: real launcher integration; 4/4 runs completed; best score = ...
Editable profile: /.../fit.toml
Best launcher config: /.../runs/best_config.json
```

This tests wiring, not scientific parameter recovery. Synthetic detections are
zero and several parameter settings may fit equally well. Outputs are retained
in the temporary directory printed by the command. To choose a persistent
location, append a **new** directory:

```sh
julia --project=MocosSimTemporalAdjustment MocosSimTemporalAdjustment/scripts/smoke_launcher.jl ./MocosSimLauncher ./smoke-output
```

## Fit your own data

From the MocosSimTemporalAdjustment repository:

```sh
export MOCOSSIM_LAUNCHER_DIR=/absolute/path/to/MocosSimLauncher
export MOCOSSIM_SEED_CONFIG=/absolute/path/to/working-launcher-config.json
export MOCOSSIM_GT_DIR=/absolute/path/to/observations

# Edit examples/launcher_fit.toml before running.
julia --project=. scripts/fit_launcher.jl examples/launcher_fit.toml --check
julia --project=. scripts/fit_launcher.jl examples/launcher_fit.toml
```

`--check` validates the profile, mappings, input paths and observations without
starting a simulation or creating output directories. It does not instantiate
the launcher or validate the contents of its population file. In the TOML file,
`${VARIABLE}` placeholders are expanded in paths. Literal absolute paths work
too. Other paths are relative to that TOML file. The launcher Julia executable
defaults to the same executable running the optimizer; override `julia_bin` when
needed. Typographical errors in configuration keys fail preflight.

Input paths **inside the seed JSON** are resolved relative to the seed JSON's
directory. If the working seed was authored relative to the launcher checkout,
set `launcher.input_base_dir` to that checkout. Population, contact-matrix,
immunity-event and other `*_path` inputs must exist. Each simulation runs with
the launcher checkout as its working directory.

Observations are simple unquoted CSVs:

```csv
day,value
1,10
2,12
4,15
```

Days are one-based: day 1 represents simulation times `[0, 1)`. Gaps, blank
values, `NA`, `missing` and `-1` denote missing observations; they do not shift
later days and are never converted to zero. Other negative/nonfinite counts,
duplicate days and unordered days are errors. You must align the simulation's
day zero with the observations yourself. `daily_hospitalizations` is daily
**admissions**, not hospital occupancy.

## Configure day steps, tolerance and search effort

All of these settings go in `[search]`:

| Setting | Meaning | Example |
| --- | --- | --- |
| `start_day` | First prefix to fit | `14` |
| `step_days` | Number of days added at each stage | `14` |
| `end_day` | Last fitting day; always included | `84` |
| `horizons` | Explicit alternative to the three day settings | `[14, 28, 56, 84]` |
| `score_tolerance` | Acceptable combined normalized error at each stage; omit to disable | `0.20` |
| `require_tolerance` | Stop after saving a checkpoint if the stage misses the tolerance | `true` |
| `max_rounds_per_horizon` | Maximum refinement rounds at each stage | `5` |
| `survivors` | Number of candidate parameter sets retained | `12` |
| `random_starts` | Random proposals in the first round; later rounds add one quarter, at least one | `48` |
| `trials_per_survivor` | Mutations per parent in later rounds/stages | `8` |
| `repetitions` | Separate launcher invocations per candidate | `3` |
| `initial_radius` | Gaussian mutation standard deviation in normalized parameter space | `0.20` |
| `radius_decay` | Multiplier applied after each completed stage | `0.75` |
| `min_separation` | Preferred Euclidean distance between survivors in normalized space | `0.03` |
| `seed` | Optimizer RNG seed | `42` |
| `checkpoint_dir` | Directory for stage checkpoints | `"../runs/fit/checkpoints"` |

A stage stops refining as soon as its **best candidate** meets
`score_tolerance`; otherwise it uses its round budget. With `require_tolerance =
true`, an unmet target stops the search before extending the horizon. Set it to
`false` to continue on budget exhaustion and record the unmet target. Tolerance
does not require every survivor or every metric to pass independently. Without
`score_tolerance`, all configured rounds run. The Julia API defaults to one
round per horizon, no score threshold, and one repetition.

The radius is a parameter step, **not a fit tolerance**. For linear bounds
`[0.05, 0.30]`, radius `0.20` gives a mutation standard deviation of `0.05` in
that parameter before boundary clipping. `scale = "log"` uses log-space bounds.
The radius decays once per stage, with a floor of `1e-4`.

Each later round evaluates up to `survivors * (1 + trials_per_survivor) +
max(1, random_starts ÷ 4)` proposals, times `repetitions`. Start small when
checking your machine; the example's larger settings can launch thousands of
simulations. Candidate proposals are evaluated sequentially. `launcher.threads`
controls threads **inside each launcher process**.

## Score and parameter mappings

For each metric and trajectory, the built-in objective computes RMSE divided by
`max(mean(abs(observed)), 1)` over the observed days of the current prefix. An
explicit metric `scale` replaces that denominator. Metric scores are averaged
over trajectories and combined as `sum(weight * score) / sum(weight)`.

`[scoring].smoothing_days = 7` applies the same trailing average to observations
and predictions; `1` disables smoothing. Windows containing missing observations
are skipped as a whole, preserving day identity. No values after the stage's
horizon affect the score or normalization. A tolerance of `0.20` means combined
normalized RMSE at most 0.20; it is not a per-day 20% error bound. Changing
weights, smoothing or scales changes its interpretation. Keep a separate test
period outside `end_day` for evaluating generalization.

Each `[[parameters]]` maps a name and bounds to a numeric JSON `path`, e.g.
`transmission_probabilities.school`, `transmission_probabilities.class`, or
`infection_modulation.params.interval_values[1]`. Array indices are **one-based**.
Use `integer = true` for integer-valued launcher fields such as
`imported_cases[1].params.num_infections`. Only the optional school/class keys
are inserted automatically; other paths must already exist. Bound choices in
the example are illustrative, not recommended scientific priors.

This implementation optimizes a fixed parameter list. It does not automatically
unlock additional modulation intervals as time increases. Start with scalars;
explicitly indexed interval parameters are supported, but future-only intervals
are not identifiable from earlier horizons.

`[[metrics]]` can reference any daily output metric from this branch, including
`daily_student_detections` and `daily_age_05_14_detections`. Each selected metric
must exist in every trajectory and have usable observations. There are no
implicit CSV filename aliases: `file` always names the actual source.

## Outputs, failures and resume

Each adapter invocation retains its effective `config_candidate.json`,
`output_daily.jld2`, `stdout.log`, `stderr.log` and
`evaluation.json`. The adapter sets `stop_simulation_time`, `params_seed`,
`num_trajectories` and a zero `window_start`; the seed JSON is never modified.
It starts from day zero for each candidate, without simulator-state reuse.

Summary output is disabled by default: at the tested launcher revision its
summary writer accesses `state.forest.inedges`, which the pinned MocosSim's
`RobinForest` does not provide. Daily output works independently and supplies
the trajectory validation and scoring. Set `launcher.write_summary = true`
only with a compatible summary writer; then the adapter also checks the summary.

Nonzero process exits, timeouts, missing/malformed output, missing trajectories,
short series and nonfinite/negative predictions fail the invocation. Short
series are not silently padded: this may reject a genuinely extinct epidemic,
which needs an explicit termination/padding policy before using this adapter
for that case. Every repetition must succeed; otherwise the candidate score is
`Inf`. Successful repetition scores are combined using their median. Candidates
at a stage share replicate seeds for paired comparisons; changing `params_seed`
does not by itself establish independence of all simulator RNG streams.

The adapter kills a timed-out launcher process and records the error. Its
`launcher.timeout_seconds` includes Julia startup and compilation time. The
launcher must already have its dependencies installed.

A successful fit writes `best_config.json` (directly runnable with the launcher)
and `fit_result.json`. The exported configuration uses the first stage replicate
seed, which is recorded in the result; the fit score is the median across all
replicates, not a claim about that single seed.

Stage checkpoints include sorted survivors, all replicate scores, paired seeds,
RNG state, radius, number of rounds and tolerance status. Resume **after an
accepted stage** with identical search options and parameters:

```sh
julia --project=. scripts/fit_launcher.jl examples/launcher_fit.toml --resume runs/launcher-fit/checkpoints/stage_003_day_42.jls
```

Keep launcher version, seed JSON, observations and scoring settings unchanged
for equivalent results. Exact resume covers optimizer state between stages; an
interrupted stage is recomputed. Checkpoints from the earlier implementation
cannot be resumed exactly. A failed mandatory-tolerance stage cannot be skipped
via resume; adjust the configuration and start a fresh run instead.

## Custom evaluators

The original generic API remains available:

```julia
using MocosSimTemporalAdjustment
parameters = [Parameter(:rate, 0.01, 1.0; scale=:log)]
evaluator(values, horizon, seed) = (values[:rate] - 0.3)^2
options = SearchOptions(horizons=day_horizons(start_day=7, step_days=7, end_day=28),
    score_tolerance=0.01, max_rounds_per_horizon=5, checkpoint_dir="runs/custom")
finalists = temporal_search(evaluator, parameters; options=options)
```

Custom evaluator exceptions propagate; the launcher adapter converts operational
simulation failures into logged `Inf` results. For the Julia API, construct
`LauncherConfig`, `MetricTarget`, and `LauncherEvaluator` directly, or call
`load_fit_config` / `fit_launcher` with a TOML profile.
