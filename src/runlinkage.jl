module runlinkage

export run_linkage

using CSV
using DataFrames
using Dates
using Logging
using Schemata

using ..utils
using ..config
using ..link


function run_linkage(configfile::String)
    @info "$(now()) Configuring linkage run"
    cfg = LinkageConfig(configfile)

    @info "$(now()) Initialising output directory: $(cfg.output_directory)"
    d = cfg.output_directory
    mkdir(d)
    mkdir(joinpath(d, "input"))
    mkdir(joinpath(d, "output"))
    mkdir(joinpath(d, "output", "deidentified"))
    mkdir(joinpath(d, "output", "identified"))
    cp(configfile, joinpath(d, "input", basename(configfile)))      # Copy config file to d/input
    software_versions = utils.construct_software_versions_table()
    CSV.write(joinpath(d, "output", "deidentified", "SoftwareVersions.csv"), software_versions; delim=',')  # Write software_versions to d/output
    iterations = utils.construct_iterations_table(cfg)
    CSV.write(joinpath(d, "output", "deidentified", "Iterations.csv"), iterations; delim=',')               # Write iterations to d/output

    @info "$(now()) Importing spine"
    spine = DataFrame(CSV.File(cfg.spine.datafile; type=String))    # We only compare Strings...avoids parsing values

    @info "$(now()) Appending spineid to spine"
    utils.append_spineid!(spine, cfg.spine.schema.primarykey)

    @info "$(now()) Writing spine_identified.tsv to disk"
    CSV.write(joinpath(cfg.output_directory, "output", "identified", "spine_identified.tsv"), spine[!, vcat(:spineid, cfg.spine.schema.primarykey)]; delim='\t')

    @info "$(now()) Writing spine_deidentified.tsv to disk for reporting"
    spine_deidentified = DataFrame(spineid = spine[!, :spineid])
    CSV.write(joinpath(cfg.output_directory, "output", "deidentified", "spine_deidentified.tsv"), spine_deidentified; delim='\t')

    # Replace the spine's primary key with [:spineid]
    empty!(cfg.spine.schema.primarykey)
    push!(cfg.spine.schema.primarykey, :spineid)

    # Do the linkage
    link.linktables(cfg, spine)

    @info "$(now()) Finished linkage"
end

end
