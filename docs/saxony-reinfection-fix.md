# Quarantine and tracing regressions in the Saxony model

The MocosSim commit `36ef4d3aa4efaaf638607da173b93f00fe59d1d1`
(2026-09-27, "Add reinfections with configurable cross-immunity") introduced
two incompatible assumptions that can stop a simulation before day 28:

1. `resetdetected!` reset every new infection to `Undetected`, including a
   household infection during an active quarantine. The next quarantine or
   quarantine-end event requires at least `UnderObservation`.
2. Recovery now returns a person to `Healthy`, but `forwardtrace!` still asserted
   that a historically infected contact could never be `Healthy`.

These regressions are in **MocosSim**, not the temporal optimizer. Raising the
score tolerance, dropping failed trajectories, disabling tracing, or removing
assertions would not repair the state transitions.

The fixes are on the MocosSim branch `codex/preserve-quarantine-observation`:

- `57dcc36`: preserve `UnderObservation` when resetting detection during an
  active quarantine; keep resetting episode-specific detection for free people.
- `ad945c0`: allow recovered susceptible contacts in forward tracing, checking
  that their infection is recorded rather than asserting an active infection.

The model's original assertion and event accounting for quarantine remain in
place. Regression tests cover household transmission into quarantine,
overlapping quarantines and their end events, detection resets, and tracing a
recovered contact. The full MocosSim test suite passes (1623 assertions) with
Julia 1.7.0 and the tested launcher dependency environment.

The supplied 28-day candidate (seed `430638884`, school `0.13704351933896425`,
class `0.19285923895480306`, age coupling `0.3`) completed with both fixes on
the LFS population, contact matrix and immunity-event inputs. Its daily output
contains 28 finite days: 349 detections, 14 deaths and 89 hospital admissions.
Equal detections/deaths weights and seven-day smoothing give normalized RMSE
`0.7762817522082064`, so this particular candidate does not meet tolerance `0.5`.
This verifies execution for one candidate, not convergence of the full search.

The optimizer also declares `CodecZlib` explicitly to read the launcher's
compressed JLD2 outputs in an isolated Julia environment. Update its packages
after pulling the integration changes:

```sh
git pull --ff-only
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

## Install in the launcher environment

From the MocosSimTemporalAdjustment repository root, for a launcher checkout
located at `./MocosSimLauncher`:

```sh
julia --project=./MocosSimLauncher -e '
using Pkg
Pkg.add(PackageSpec(
    url="https://github.com/marcinb-pwr/MocosSim",
    rev="ad945c004763f544da4f80d7ea433625147c29d6"))
using MocosSimLauncher
Pkg.status("MocosSim")
'
```

This updates the launcher's Manifest to the fixed model revision. Installing
the dependency only in the optimizer environment would not affect subprocess
simulations. Use the Julia executable and depot used by your launcher profile.

Set a new `launcher.output_dir` and `search.checkpoint_dir` in the fit TOML, then
start a new fit:

```sh
julia --project=. scripts/fit_launcher.jl experiments/saxony_baseline.toml --check
julia --project=. scripts/fit_launcher.jl experiments/saxony_baseline.toml
```

Changing the model can change trajectories and losses; old candidate scores
should not be treated as results of the fixed model. The previous run's
artifacts remain useful for diagnostics.
