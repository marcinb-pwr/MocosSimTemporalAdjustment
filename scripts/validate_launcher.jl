using MocosSimTemporalAdjustment

2 <= length(ARGS) <= 5 || error(
    "Usage: julia --project=. scripts/validate_launcher.jl FIT.toml CHECKPOINT.jls [SEEDS=5] [TOP_N=3] [TOLERANCE=0.5]")
threshold = length(ARGS)>=5 ? parse(Float64,ARGS[5]) : .5
result = validate_launcher(ARGS[1],ARGS[2];
    repetitions=length(ARGS)>=3 ? parse(Int,ARGS[3]) : 5,
    top_n=length(ARGS)>=4 ? parse(Int,ARGS[4]) : 3,
    score_tolerance=threshold)
println("Validation report: ",joinpath(result.directory,"validation_result.json"))
println("Best validation score: ",first(result.candidates).score)
println("Threshold $threshold: ",first(result.candidates).score<=threshold ? "PASS" : "NOT REACHED")
isfinite(first(result.candidates).score) || error("All validation candidates failed; inspect the run reports")
