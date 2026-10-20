using DataFrames
using JLD2

length(ARGS) == 2 || error(
    "Usage: julia --project=MocosSimLauncher scripts/convert_saxony_population.jl INPUT.csv OUTPUT.jld2"
)

input_path, output_path = abspath.(ARGS)
isfile(input_path) || error("CSV file does not exist: $input_path")
input_path == output_path && error("Input and output paths must be different")
!ispath(output_path) || error("Refusing to overwrite existing output: $output_path")

expected_header = [
    "age",
    "gender",
    "household_index",
    "class_index",
    "school_index",
    "attending_school",
]

parse_bool(value, line_number, column) = if value == "True"
    true
elseif value == "False"
    false
else
    error("Expected True or False in $column at CSV line $line_number, got $(repr(value))")
end

num_rows = countlines(input_path) - 1
num_rows > 0 || error("CSV has no data rows")

ages = Vector{UInt8}(undef, num_rows)
genders = Vector{Bool}(undef, num_rows)
household_indices = Vector{Int32}(undef, num_rows)
class_indices = Vector{UInt16}(undef, num_rows)
school_indices = Vector{UInt16}(undef, num_rows)
attending_school = Vector{Bool}(undef, num_rows)

open(input_path, "r") do io
    header = split(chomp(readline(io)), ',')
    header == expected_header || error("Unexpected CSV header: $(join(header, ','))")

    for row in 1:num_rows
        line_number = row + 1
        fields = split(chomp(readline(io)), ','; keepempty=true)
        length(fields) == length(expected_header) ||
            error("Expected 6 columns at CSV line $line_number, got $(length(fields))")

        age = parse(Int, fields[1])
        household_index = parse(Int, fields[3])
        class_index = parse(Int, fields[4])
        school_index = parse(Int, fields[5])

        0 <= age <= typemax(UInt8) || error("Age out of range at CSV line $line_number")
        0 <= household_index <= typemax(Int32) ||
            error("Household index out of range at CSV line $line_number")
        0 <= class_index <= typemax(UInt16) ||
            error("Class index out of range at CSV line $line_number")
        0 <= school_index <= typemax(UInt16) ||
            error("School index out of range at CSV line $line_number")

        ages[row] = age
        genders[row] = parse_bool(fields[2], line_number, "gender")
        household_indices[row] = household_index
        class_indices[row] = class_index
        school_indices[row] = school_index
        attending_school[row] = parse_bool(fields[6], line_number, "attending_school")
    end

    eof(io) || error("CSV has more rows than expected")
end

# The CSV does not include healthcare-worker status. This dataset's baseline
# config has hospital transmission disabled, so no healthcare workers are marked.
individuals_df = DataFrame(
    age=ages,
    gender=genders,
    household_index=household_indices,
    class_index=class_indices,
    school_index=school_indices,
    attending_school=attending_school,
    ishealthcare=falses(num_rows),
)

jldopen(output_path, "w") do file
    file["individuals_df"] = individuals_df
end

println("Wrote $num_rows individuals to $output_path")
