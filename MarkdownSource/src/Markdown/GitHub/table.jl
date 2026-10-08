# This file is a part of Julia. License is MIT: https://julialang.org/license

# Forked from `stdlib/Markdown/src/GitHub/table.jl` of JuliaLang/julia at the commit in
# `upstream.toml`. Local changes record source locations and drop the renderers.

mutable struct Table <: MarkdownElement
    rows::Vector{Vector{Any}}
    align::Vector{Symbol}
end

function parserow(stream::IO)
    withstream(stream) do
        line = readline(stream)
        row = split(line, r"(?<!\\)\|")
        length(row) == 1 && return
        isempty(row[1]) && popfirst!(row)
        map!(x -> strip(replace(x, "\\|" => "|")), row, row)
        isempty(row[end]) && pop!(row)
        return row
    end
end

function rowlength!(row, len)
    while length(row) < len push!(row, "") end
    while length(row) > len pop!(row) end
    return row
end

const default_align = :l

function parsealign(row)
    align = Symbol[]
    for s in row
        (length(s) ≥ 3 && s ⊆ Set("-:")) || return
        push!(align,
              s[1] == ':' ? (s[end] == ':' ? :c : :l) :
              s[end] == ':' ? :r :
              default_align)
    end
    return align
end

function github_table(stream::IO, md::MD)
    withstream(stream) do
        skipblank(stream)
        rows = []
        cols = 0
        align = nothing
        while (line_start = position(stream); row = parserow(stream)) !== nothing
            if length(rows) == 0
                cols = length(row)
            end
            if align === nothing && length(rows) == 1 # Must have a --- row
                align = parsealign(row)
                (align === nothing || length(align) != cols) && return false
            else
                let line_start=line_start
                    push!(rows, [parseinline(cellstream(x, stream, line_start, j), md)
                                 for (j, x) in enumerate(rowlength!(row, cols))])
                end
            end
        end
        length(rows) <= 1 && return false
        push!(md, Table(rows, align::Vector{Symbol}))
        return true
    end
end
