using MocosSimTemporalAdjustment
using Test

@testset "progressive temporal search" begin
    directory = mktempdir()
    calls = Tuple{Int,Int}[]
    evaluator = function (values, horizon, seed)
        push!(calls, (horizon, seed))
        (values[:contact_rate] - 0.3)^2 + (values[:delay] - 4.0)^2 / horizon
    end
    parameters = [Parameter(:contact_rate, 0.05, 1.0; scale=:log),
                  Parameter(:delay, 1, 10)]
    options = SearchOptions(horizons=[7, 14], survivors=4, random_starts=30,
                            trials_per_survivor=5, repetitions=2, seed=42,
                            checkpoint_dir=directory)

    result = temporal_search(evaluator, parameters; options=options)

    @test length(result) == 4
    @test issorted(getfield.(result, :score))
    @test result[1].horizon == 14
    @test Set(first.(calls)) == Set([7, 14])
    @test length(result[1].replicate_scores) == 2
    checkpoint = load_checkpoint(joinpath(directory, "stage_002_day_14.jls"))
    @test checkpoint.horizon == 14
    @test getfield.(checkpoint.survivors, :score) == getfield.(result, :score)
end

@testset "validation and failed simulations" begin
    @test_throws ArgumentError Parameter(:bad, 0, 1; scale=:log)
    options = SearchOptions(horizons=[2], survivors=1, random_starts=2,
                            repetitions=1, checkpoint_dir=mktempdir())
    result = temporal_search((args...) -> NaN, [Parameter(:x, 0, 1)]; options=options)
    @test isinf(only(result).score)
    @test_throws ArgumentError temporal_search((args...) -> 0,
        [Parameter(:x, 0, 1)]; options=options,
        initial=[Dict(:x => 2.0)])
end
