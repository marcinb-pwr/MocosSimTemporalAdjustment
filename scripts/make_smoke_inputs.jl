# Run under the LAUNCHER project: population DataFrames must match its dependency versions.
using DataFrames
using JLD2
using JSON

directory = abspath(only(ARGS))
mkpath(directory)
population = DataFrame(
    household_index=[1, 1, 2, 2, 3, 3],
    attending_school=[1, 0, 1, 0, 0, 0],
    school_index=[1, 0, 1, 0, 0, 0],
    class_index=[1, 0, 1, 0, 0, 0],
    age=[10, 40, 12, 45, 60, 65],
    gender=[0, 1, 1, 0, 0, 1],
    ishealthcare=fill(false, 6),
)
jldopen(joinpath(directory, "population.jld2"), "w") do file
    file["individuals_df"] = population
end
config = Dict{String,Any}(
    "population_path" => "population.jld2",
    "num_trajectories" => 1,
    "params_seed" => 42,
    "mild_detection_prob" => 0.0,
    "stop_simulation_threshold" => 100,
    "stop_simulation_time" => 4,
    "initial_conditions" => Dict{String,Any}(),
    "screening" => Dict("adherence_pmf" => [1.0]),
    "contact_tracing" => Dict("probability" => 0.0, "detection_delay" => 1.0, "testing_time" => 0.25),
    "transmission_probabilities" => Dict("constant" => 0.0, "household" => 0.0,
                                          "school" => 0.0, "class" => 0.0),
    "imported_cases" => [Dict("function" => "InstantOutsideCases",
        "params" => Dict("import_time" => 0.0, "num_infections" => 1, "strain" => "Chinese"))],
)
open(joinpath(directory, "base.json"), "w") do io
    JSON.print(io, config, 2)
end
write(joinpath(directory, "detections.csv"), "day,value\n1,0\n2,0\n3,0\n4,0\n")
