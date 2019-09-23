module link

using CSV
using Dates
using DataFrames
using Logging
using Schemata

using ..TableIndexes
using ..distances
using ..config


function linktables(cfg::LinkageConfig, spine::DataFrame)
    spineschema = cfg.spine.schema
    linkmap     = init_linkmap(spineschema, 0)
    for table_iterations in cfg.iterations
        # Make an output directory for the table
        tablename = table_iterations[1].tablename
        @info "$(now()) Starting linkage for table $(tablename)"
        tabledir  = joinpath(joinpath(cfg.output_directory, "output"), tablename)
        mkdir(tabledir)

        # Create an empty linkmap and store it in the output directory
        linkmap_file = joinpath(tabledir, "linkmap-$(tablename).tsv")
        CSV.write(linkmap_file, linkmap; delim='\t')

        # Create an empty output file for the data and store it in the output directory
        table_schema  = cfg.tables[tablename].schema
        data          = init_data(table_schema, 0)  # Columns are [:recordid, primarykey_columns...]
        table_outfile = joinpath(tabledir, "$(tablename).tsv")
        CSV.write(table_outfile, data; delim='\t')

        # Construct some convenient lookups for computational efficiency
        iterationid2index = construct_table_indexes(table_iterations, spine)  # iteration.id => TableIndex(spine, colnames, index)
        iterationid2key   = Dict(id => fill("", length(tableindex.colnames)) for (id, tableindex) in iterationid2index)  # Place-holder for lookup keys

        # Run the data through each iteration
        table_infile = cfg.tables[tablename].datafile
        linktable(spine, spineschema, table_infile, table_outfile, table_schema, linkmap_file, table_iterations, iterationid2index, iterationid2key)
    end
end


function linktable(spine::DataFrame, spineschema::TableSchema,
                   table_infile::String, table_outfile::String, table_schema::TableSchema,
                   linkmap_file::String,
                   iterations::Vector{LinkageIteration}, iterationid2index::Dict{Int, TableIndex}, iterationid2key::Dict{Int, Vector{String}})
    linkmap   = init_linkmap(spineschema, 1_000_000)  # Process the data in batches of 1_000_000 rows
    data      = init_data(table_schema,   1_000_000)  # Process the data in batches of 1_000_000 rows
    i_linkmap = 0
    i_data    = 0
    nlinks    = 0
    row       = Dict{Symbol, String}()  # colname => value
    delim     = table_infile[(end - 2):end] == "csv" ? "," : "\t"
    idx2colname      = nothing
    colnames_done    = false
    data_primarykey  = table_schema.primarykey
    spine_primarykey = spineschema.primarykey[1]
    f = open(table_infile)
    for line in eachline(f)
        # Parse column names.
        if !colnames_done
            idx2colname   = Dict(j => Symbol(colname) for (j, colname) in enumerate(strip.(String.(split(line, delim)))))
            colnames_done = true
            continue
        end

        # Extract row from line
        extract_row!(row, line, delim, idx2colname)

        # Store recordid and primary key
        i_data += 1
        data[i_data, :recordid] = hash(line)
        for colname in data_primarykey
            data[i_data, colname] = row[colname]
        end

        # Loop through each LinkageIteration
        for iteration in iterations
            # Identify the best matching spine record (if it exists)
            tableindex = iterationid2index[iteration.id]
            k = constructkey!(iterationid2key[iteration.id], row, tableindex.colnames)
            !haskey(tableindex.index, k) && continue  # Row doesn't match any spine records on iteration.exactmatchcols
            candidate_indices = tableindex.index[k]   # Indices of rows of the spine that satisfy iteration.exactmatchcols
            spineid = select_best_candidate(spine, spine_primarykey, candidate_indices, row, iteration.fuzzymatches)
            spineid == 0  && continue

            # Create a record in the linkmap
            i_linkmap += 1
            linkmap[i_linkmap, :spineid]     = spineid
            linkmap[i_linkmap, :recordid]    = data[i_data, :recordid]
            linkmap[i_linkmap, :iterationid] = iteration.id
            break  # Row has been linked, no need to link on other criteria
        end

        # If data is full, write to disk
        if i_data == 1_000_000
            CSV.write(table_outfile, data; delim='\t', append=true)
            i_data = 0  # Reset the row number
        end

        # If linkmap is full, write to disk
        if i_linkmap == 1_000_000
            nlinks    = write_linkmap_to_disk(linkmap_file, linkmap, nlinks)
            i_linkmap = 0  # Reset the row number
        end
    end
    i_linkmap != 0 && write_linkmap_to_disk(linkmap_file, linkmap[1:i_linkmap, :], nlinks)
    close(f)
end


################################################################################
# Utils

"Returns: Dict(iterationid => TableIndex(spine, colnames))"
function construct_table_indexes(iterations::Vector{LinkageIteration}, spine)
    # Create TableIndexes
    tmp = Dict{Int, TableIndex}()
    for iteration in iterations
        colnames = [spine_colname for (data_colname, spine_colname) in iteration.exactmatchcols]
        tmp[iteration.id] = TableIndex(spine, colnames)
    end

    # Replace spine colnames with data colnames
    # A hack to avoid converting from sine colnames to data colnames on each lookup
    result = Dict{Int, TableIndex}()
    for iteration in iterations
        data_colnames = [data_colname for (data_colname, spine_colname) in iteration.exactmatchcols]
        tableindex    = tmp[iteration.id]
        result[iteration.id] = TableIndex(spine, data_colnames, tableindex.index)
    end
    result
end

function init_linkmap(spineschema::TableSchema, n::Int)
    pk_colname  = spineschema.primarykey[1]        # Assumes the spine's primary key has 1 column
    colnames    = [pk_colname, :recordid, :iterationid]
    coltypes    = [String, UInt, Int]
    DataFrame(coltypes, colnames, n)
end

function init_data(tableschema::TableSchema, n::Int)
    colnames = vcat(:recordid, tableschema.primarykey)
    coltypes = [UInt]
    for colname in tableschema.primarykey
        colschema = tableschema.columns[colname]
        push!(coltypes, colschema.datatype)
    end
    DataFrame(coltypes, colnames, n)
end

function write_linkmap_to_disk(linkmap_file, linkmap, nlinks)
    nlinks += size(linkmap, 1)
    CSV.write(linkmap_file, linkmap; delim='\t', append=true)
    @info "$(now()) $(nlinks) links created"
    nlinks
end

function extract_row!(row::Dict{Symbol, String}, line::String, delim::String, idx2colname::Dict{Int, Symbol})
    i_start    = 1
    colidx     = 0
    linelength = length(line)
    for j = 1:10_000  # Maximum of 10_000 columns
        r       = findnext(delim, line, i_start)        # r = i:i, where line[i] == '\t'
        i_end   = isnothing(r) ? linelength : r[1] - 1  # If r is nothing then we're in the last column
        colidx += 1
        row[idx2colname[colidx]] = String(line[i_start:i_end])
        i_end == linelength && break
        i_start = i_end + 2
    end
end

function constructkey!(result::Vector{String}, datarow::Dict{Symbol, String}, colnames::Vector{Symbol})
    for (j, colname) in enumerate(colnames)  # Populate result with the row's values of tableindex.colnames (iteration.exactmatchcols)
        result[j] = datarow[colname]
    end
    Tuple(result)
end

function select_best_candidate(spine, spine_primarykey::Symbol, candidate_indices::Vector{Int}, row::Dict{Symbol, String}, fuzzymatches::Vector{FuzzyMatch})
    if isempty(fuzzymatches)
        length(candidate_indices) == 1 && return spine[candidate_indices[1], spine_primarykey]  # There is 1 candidate and no further selection criteria to be met
        return 0  # There is more than 1 candidate and no way to select the best one
    end
    result = 0
    min_distance = 1.0
    for i_spine in candidate_indices
        dist = 0.0
        ok   = true  # Each FuzzyMatch criterion is satisfied
        for fuzzymatch in fuzzymatches
            d = distance(fuzzymatch.distancemetric, row[fuzzymatch.datacolumn], spine[i_spine, fuzzymatch.spinecolumn])
            if d <= fuzzymatch.threshold
                dist += d
            else
                ok = false
                break
            end
        end
        !ok && continue  # Not every FuzzyMatch criterion is satisfied
        dist >= min_distance && continue  # distance(row, candidate) is not minimal among candidates tested so far
        min_distance = dist
        result = spine[i_spine, spine_primarykey]
    end
    result
end

end