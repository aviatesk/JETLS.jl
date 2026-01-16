#!/usr/bin/env julia

using JSON3
using Printf

struct HeapNode
    type::String
    name::String
    id::Int
    self_size::Int
    edge_count::Int
end

struct HeapEdge
    type::String
    name_or_index::Union{String,Int}
    from_node::Int
    to_node::Int
end

function HeapEdge(type::String, name_or_index::Real, from_node::Int, to_node::Int)
    # JSON3 may return large pointer-like values as Float64 that exceed Int64 range
    idx = unsafe_trunc(Int, name_or_index)
    HeapEdge(type, idx, from_node, to_node)
end

struct HeapSnapshot
    nodes::Vector{HeapNode}
    edges::Vector{HeapEdge}
    retainers::Dict{Int,Vector{Int}}  # node_index => [edge_indices that point to it]
end

struct TypeSummary
    count::Int
    shallow_size::Int
end

function parse_heapsnapshot(path::String; parse_edges::Bool=false)
    data = open(path) do io
        JSON3.read(io)
    end

    snapshot = data["snapshot"]
    meta = snapshot["meta"]
    node_fields = meta["node_fields"]
    node_types = meta["node_types"][1]
    edge_fields = meta["edge_fields"]
    edge_types = meta["edge_types"][1]
    strings = data["strings"]
    nodes_array = data["nodes"]
    edges_array = data["edges"]

    node_field_count = length(node_fields)
    edge_field_count = length(edge_fields)
    node_count = snapshot["node_count"]

    type_idx = findfirst(==("type"), node_fields)
    name_idx = findfirst(==("name"), node_fields)
    id_idx = findfirst(==("id"), node_fields)
    self_size_idx = findfirst(==("self_size"), node_fields)
    edge_count_idx = findfirst(==("edge_count"), node_fields)

    edge_type_idx = findfirst(==("type"), edge_fields)
    edge_name_idx = findfirst(==("name_or_index"), edge_fields)
    edge_to_node_idx = findfirst(==("to_node"), edge_fields)

    nodes = Vector{HeapNode}(undef, node_count)
    for i in 1:node_count
        base = (i - 1) * node_field_count
        type_index = nodes_array[base + type_idx] + 1
        name_index = nodes_array[base + name_idx] + 1
        node_type = node_types[type_index]
        node_name = strings[name_index]
        node_id = nodes_array[base + id_idx]
        self_size = nodes_array[base + self_size_idx]
        edge_count = nodes_array[base + edge_count_idx]
        nodes[i] = HeapNode(node_type, node_name, node_id, self_size, edge_count)
    end

    edges = HeapEdge[]
    retainers = Dict{Int,Vector{Int}}()

    if parse_edges
        edge_count = snapshot["edge_count"]
        resize!(edges, edge_count)

        edge_idx = 1
        for from_node in 1:node_count
            for _ in 1:nodes[from_node].edge_count
                base = (edge_idx - 1) * edge_field_count
                etype_index = edges_array[base + edge_type_idx] + 1
                etype = edge_types[etype_index]
                name_or_index_raw = edges_array[base + edge_name_idx]
                # For "element" edges, name_or_index is an array index; otherwise it's a string index
                name_or_index = if etype == "element"
                    name_or_index_raw
                else
                    strings[name_or_index_raw + 1]
                end
                to_node_offset = edges_array[base + edge_to_node_idx]
                to_node = to_node_offset ÷ node_field_count + 1

                edges[edge_idx] = HeapEdge(etype, name_or_index, from_node, to_node)

                if !haskey(retainers, to_node)
                    retainers[to_node] = Int[]
                end
                push!(retainers[to_node], edge_idx)

                edge_idx += 1
            end
        end
    end

    return HeapSnapshot(nodes, edges, retainers)
end

function summarize_by_type(nodes::Vector{HeapNode})
    summary = Dict{String,TypeSummary}()
    for node in nodes
        key = "($(node.type)) $(node.name)"
        existing = get(summary, key, TypeSummary(0, 0))
        summary[key] = TypeSummary(existing.count + 1, existing.shallow_size + node.self_size)
    end
    return summary
end

# Uses binary units (1 KB = 1024 bytes), consistent with macOS and htop.
# Note: Chrome DevTools uses SI units (1 KB = 1000 bytes), so values will differ slightly.
function format_size(bytes::Int)
    if bytes >= 1024 * 1024
        return @sprintf("%.1f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024
        return @sprintf("%.1f KB", bytes / 1024)
    else
        return "$bytes B"
    end
end

function print_summary(summary::Dict{String,TypeSummary}; top_n::Int=50)
    sorted = sort(collect(summary); by = x -> x.second.shallow_size, rev = true)

    total_size = sum(s.shallow_size for (_, s) in summary)
    total_count = sum(s.count for (_, s) in summary)

    wide = 120

    println()
    println("=" ^ wide)
    println("HEAP SNAPSHOT SUMMARY")
    println("=" ^ wide)
    @printf("Total objects: %d\n", total_count)
    @printf("Total shallow size: %s\n", format_size(total_size))
    println()
    println("-" ^ wide)
    @printf("%-80s %10s %14s %12s\n", "Type/Name", "Count", "Shallow Size", "% of Total")
    println("-" ^ wide)

    for (i, (key, s)) in enumerate(sorted)
        i > top_n && break
        pct = 100.0 * s.shallow_size / total_size
        display_key = length(key) > 80 ? key[1:77] * "..." : key
        @printf("%-80s %10d %14s %11.1f%%\n", display_key, s.count, format_size(s.shallow_size), pct)
    end

    println("-" ^ wide)
    println()
end

function find_nodes_by_type(snapshot::HeapSnapshot, typename::AbstractString)::Vector{Int}
    matched = Int[]
    for (i, node) in enumerate(snapshot.nodes)
        if node.type == typename
            push!(matched, i)
        end
    end
    return matched
end

function find_nodes_by_name(snapshot::HeapSnapshot, name::AbstractString)::Vector{Int}
    matched = Int[]
    for (i, node) in enumerate(snapshot.nodes)
        if occursin(name, node.name)
            push!(matched, i)
        end
    end
    return matched
end

function print_retainers(snapshot::HeapSnapshot, node_indices::Vector{Int};
                         max_depth::Int=5, max_nodes::Int=1000)
    nodes = snapshot.nodes
    edges = snapshot.edges
    retainers = snapshot.retainers

    println()
    println("=" ^ 100)
    println("RETAINERS ANALYSIS")
    println("=" ^ 100)

    if isempty(node_indices)
        println("No matching nodes found.")
        return
    end

    sampled = first(node_indices, max_nodes)
    if length(node_indices) > max_nodes
        println("Found $(length(node_indices)) matching nodes, sampling $max_nodes for analysis")
    else
        println("Analyzing $(length(node_indices)) node(s)")
    end
    println()

    # Aggregate retainers across sampled nodes using DFS
    retainer_counts = Dict{String,Int}()
    for node_idx in sampled
        visited = Set{Int}()
        stack = [(node_idx, 0)]

        while !isempty(stack)
            (current, depth) = pop!(stack)
            depth >= max_depth && continue
            current in visited && continue
            push!(visited, current)

            edge_indices = get(retainers, current, Int[])
            for edge_idx in edge_indices
                edge = edges[edge_idx]
                from_node = nodes[edge.from_node]
                key = "($(from_node.type)) $(from_node.name)"
                retainer_counts[key] = get(retainer_counts, key, 0) + 1

                if edge.from_node ∉ visited
                    push!(stack, (edge.from_node, depth + 1))
                end
            end
        end
    end

    sorted = sort(collect(retainer_counts); by = x -> x.second, rev = true)

    println("-" ^ 100)
    @printf("%-80s %15s\n", "Retainer Type/Name", "Reference Count")
    println("-" ^ 100)

    for (i, (key, count)) in enumerate(sorted)
        i > 50 && break
        display_key = length(key) > 80 ? key[1:77] * "..." : key
        @printf("%-80s %15d\n", display_key, count)
    end
    println("-" ^ 100)
    println()
end

function print_retainer_chain(snapshot::HeapSnapshot, node_idx::Int; max_depth::Int=10)
    nodes = snapshot.nodes
    edges = snapshot.edges
    retainers = snapshot.retainers

    node = nodes[node_idx]
    println()
    println("Retainer chain for: ($(node.type)) $(node.name) [@$(node.id)]")
    println()

    function print_chain(current::Int, depth::Int, visited::Set{Int})
        depth > max_depth && return
        current in visited && return
        push!(visited, current)

        edge_indices = get(retainers, current, Int[])
        isempty(edge_indices) && return

        for (i, edge_idx) in enumerate(edge_indices)
            i > 5 && (println("  " ^ depth, "... and $(length(edge_indices) - 5) more"); break)

            edge = edges[edge_idx]
            from_node = nodes[edge.from_node]
            edge_label = edge.name_or_index isa String ? edge.name_or_index : "[$(edge.name_or_index)]"
            println("  " ^ depth, "← ($(edge.type): $edge_label) ($(from_node.type)) $(from_node.name) [@$(from_node.id)]")

            print_chain(edge.from_node, depth + 1, visited)
        end
    end

    print_chain(node_idx, 0, Set{Int}())
end

function print_help()::Nothing
    println("""
    scripts/analyze-heapsnapshot.jl - Heap Snapshot Analyzer

    USAGE:
        julia scripts/analyze-heapsnapshot.jl <path-to-heapsnapshot> [OPTIONS]

    DESCRIPTION:
        Analyzes V8 heap snapshot files (.heapsnapshot) generated by JETLS
        and displays memory usage summary by object type.

    OPTIONS:
        --top=N           Show top N entries (default: 50)
        --retainers=NAME  Show retainers for nodes whose name contains NAME
        --help, -h        Show this help message

    EXAMPLES:
        # Show memory summary
        julia scripts/analyze-heapsnapshot.jl JETLS_20251203_120000.heapsnapshot

        # Show top 100 entries
        julia scripts/analyze-heapsnapshot.jl JETLS_20251203_120000.heapsnapshot --top=100

        # Analyze retainers for CodeInstance objects
        julia scripts/analyze-heapsnapshot.jl JETLS_20251203_120000.heapsnapshot --retainers=CodeInstance
    """)
end

function parse_args(args::Vector{String})::@NamedTuple{path::String, top_n::Int, retainers_pattern::Union{String,Nothing}}
    path = nothing
    top_n = 50
    retainers_pattern = nothing

    for arg in args
        if arg == "--help" || arg == "-h"
            print_help()
            exit(0)
        elseif startswith(arg, "--top=")
            top_n = parse(Int, split(arg, "="; limit=2)[2])
        elseif startswith(arg, "--retainers=")
            retainers_pattern = split(arg, "="; limit=2)[2]
        elseif !startswith(arg, "-")
            path = arg
        else
            @warn "Unknown argument: $arg"
            println("\nRun with --help for usage information")
            exit(1)
        end
    end

    if path === nothing
        error("Heap snapshot path is required\nRun with --help for usage information")
    end

    return (; path, top_n, retainers_pattern)
end

function (@main)(args::Vector{String})
    (; path, top_n, retainers_pattern) = parse_args(args)

    if !isfile(path)
        error("File not found: $path")
    end

    parse_edges = retainers_pattern !== nothing
    snapshot = parse_heapsnapshot(path; parse_edges)

    summary = summarize_by_type(snapshot.nodes)
    print_summary(summary; top_n)

    if retainers_pattern !== nothing
        node_indices = find_nodes_by_name(snapshot, retainers_pattern)
        print_retainers(snapshot, node_indices)
    end
end
