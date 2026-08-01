#!/usr/bin/env julia

using Downloads: request

const RAW_BASE_URL =
    "https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/"
const PUBLIC_BASE_URL =
    "https://microsoft.github.io/language-server-protocol/specifications/lsp"
const SPEC_ROOT = "_specifications/lsp"
const INCLUDE_ROOT = "_includes"

const FRONT_MATTER_RE = r"\A---\n(.*?)\n---\n?"s
const INCLUDE_RE = r"\{%\s*(include_relative|include)\s+([^\s%]+)[^%]*%\}"
const TABLE_CLASS_RE = r"^\{:\s+[^}]+\}\s*$"
const TABLE_SEPARATOR_RE = Regex(
    raw"^\s*\|?\s*:?-{3,}:?\s*" *
        raw"(\|\s*:?-{3,}:?\s*)+\|?\s*$"
)
const BULLET_RE = r"^(\s*)\*\s+"
const HEADING_ANCHOR_RE = Regex(
    raw"""^(#{1,6})\s+<a\s+""" *
        raw"""href="#[^"]*"\s+name="([^"]+)"\s+""" *
        raw"""class="anchor">(.*?)</a>\s*$"""
)
const TEXT_ANCHOR_RE = Regex(
    raw"""^<a\s+href="#[^"]*"\s+name="([^"]+)"\s+""" *
        raw"""class="anchor">(.*?)</a>\s*$"""
)
const ANCHOR_HOLDER_RE = Regex(
    raw"""^<div\s+class="anchorHolder"><a\s+href="#[^"]*"\s+""" *
        raw"""name="([^"]+)"\s+class="linkableAnchor"></a></div>\s*$"""
)
const EMOJI_MARKER_RE =
    r"\s*\(:[A-Za-z0-9_+-]+:(?:\s+:[A-Za-z0-9_+-]+:)*\)\s*$"
const LOCAL_LINK_RE = r"(?<!!)\[([^\]]+)\]\(#([A-Za-z0-9_.\[\]-]+)\)"
const META_MODEL_LINK_RE = r"\]\(\.\./metaModel/([^\)]+)\)"
const HTML_ENTITY_RE =
    r"&(#(?:x|X)[0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]+);"

const HTML_ENTITIES = Dict(
    "amp" => "&",
    "apos" => "'",
    "gt" => ">",
    "hellip" => "…",
    "ldquo" => "“",
    "lsquo" => "‘",
    "lt" => "<",
    "mdash" => "—",
    "nbsp" => "\u00a0",
    "ndash" => "–",
    "quot" => "\"",
    "rdquo" => "”",
    "rsquo" => "’",
)

struct SpecificationUpdateError <: Exception
    message::String
end

Base.showerror(io::IO, error::SpecificationUpdateError) = print(io, error.message)

mutable struct SourceExpander
    version::String
    cache::Dict{String, String}
    stack::Vector{String}
end

SourceExpander(version::String) =
    SourceExpander(version, Dict{String, String}(), String[])

function required_capture(m::RegexMatch, index::Int)
    return String(@something m.captures[index] error("missing capture $index"))
end

function fetch_text(url::String)
    output = IOBuffer()
    try
        request(url; output)
    catch error
        message = sprint(showerror, error)
        throw(SpecificationUpdateError("failed to fetch $url: $message"))
    end
    return String(take!(output))
end

function parse_front_matter(text::String)
    front_matter =
        @something match(FRONT_MATTER_RE, text) return Dict{String, String}(), text

    data = Dict{String, String}()
    for line in eachline(IOBuffer(required_capture(front_matter, 1)))
        if isempty(line) || startswith(line, " ") || !contains(line, ':')
            continue
        end
        key, value = split(line, ':'; limit = 2)
        value = strip(character -> character == '"', strip(value))
        data[String(strip(key))] = String(value)
    end
    body = replace(text, FRONT_MATTER_RE => ""; count = 1)
    return data, body
end

root_path(expander::SourceExpander) = "$SPEC_ROOT/$(expander.version)/specification.md"

function fetch_path!(expander::SourceExpander, path::String)
    return get!(expander.cache, path) do
        fetch_text(RAW_BASE_URL * path) # FIXME: JETLS
    end
end

function expand_path!(
        expander::SourceExpander, path::String, strip_front_matter::Bool,
    )
    if path in expander.stack
        cycle = join([expander.stack; path], " -> ")
        throw(SpecificationUpdateError("recursive include cycle: $cycle"))
    end

    push!(expander.stack, path)
    try
        text = fetch_path!(expander, path)
        metadata = Dict{String, String}()
        if strip_front_matter
            metadata, text = parse_front_matter(text)
        end
        return metadata, expand_includes!(expander, text, path)
    finally
        pop!(expander.stack)
    end
end

function expand_includes!(
        expander::SourceExpander,
        text::String,
        current_path::String,
    )
    current_dir = dirname(current_path)
    return replace(
        text, INCLUDE_RE => included -> begin
            included_match =
                @something match(INCLUDE_RE, included) error("invalid include match")
            kind = required_capture(included_match, 1)
            include_path = required_capture(included_match, 2)
            path = if kind == "include_relative"
                normpath(joinpath(current_dir, include_path))
            else
                normpath(joinpath(INCLUDE_ROOT, include_path))
            end
            _, expanded = expand_path!(expander, path, #=strip_front_matter=# false)
            return expanded
        end
    )
end

function decode_html_entity(entity::String)
    base, digits = if startswith(entity, "#x") || startswith(entity, "#X")
        16, entity[3:end]
    elseif startswith(entity, "#")
        10, entity[2:end]
    else
        return get(HTML_ENTITIES, entity, nothing)
    end
    value = @something tryparse(Int, digits; base) return nothing
    return try
        string(Char(value))
    catch
        nothing
    end
end

function html_unescape(text::String)
    return replace(
        text, HTML_ENTITY_RE => escaped -> begin
            entity_match =
                @something match(HTML_ENTITY_RE, escaped) error("invalid HTML entity match")
            return @something decode_html_entity(required_capture(entity_match, 1)) escaped
        end
    )
end

function clean_heading_title(title::String)
    return String(strip(replace(html_unescape(title), EMOJI_MARKER_RE => "")))
end

function slugify_heading(title::String)
    slug = lowercase(title)
    slug = replace(slug, r"[^\w\s-]" => "")
    slug = replace(strip(slug), r"\s+" => "-")
    slug = replace(slug, r"-+" => "-")
    return isempty(slug) ? "section" : slug
end

function heading_anchor_map(text::String)
    anchors = Dict{String, String}()
    used = Dict{String, Int}()
    for line in eachline(IOBuffer(text))
        heading = match(HEADING_ANCHOR_RE, line)
        isnothing(heading) && continue
        anchor_id = required_capture(heading, 2)
        title = required_capture(heading, 3)
        slug = slugify_heading(clean_heading_title(title))
        count = get(used, slug, 0)
        used[slug] = count + 1
        anchors[anchor_id] = count == 0 ? slug : "$slug-$count"
    end
    return anchors
end

function normalize_anchors(text::String)
    lines = String[]
    for line in eachline(IOBuffer(text))
        occursin(ANCHOR_HOLDER_RE, line) && continue

        heading = match(HEADING_ANCHOR_RE, line)
        if !isnothing(heading)
            level = required_capture(heading, 1)
            title = required_capture(heading, 3)
            push!(lines, "$level $(clean_heading_title(title))")
            continue
        end

        text_anchor = match(TEXT_ANCHOR_RE, line)
        if !isnothing(text_anchor)
            title = required_capture(text_anchor, 2)
            push!(lines, html_unescape(title))
            continue
        end

        push!(lines, line)
    end
    return join(lines, '\n')
end

function normalize_local_links(text::String, anchors::Dict{String, String})
    return replace(
        text, LOCAL_LINK_RE => linked -> begin
            link_match =
                @something match(LOCAL_LINK_RE, linked) error("invalid local link match")
            label = required_capture(link_match, 1)
            target = required_capture(link_match, 2)
            anchor = @something get(anchors, target, nothing) return label
            return "[$label](#$anchor)"
        end
    )
end

function normalize_links(text::String, version::String)
    meta_model_base = "$PUBLIC_BASE_URL/$version/metaModel"
    return replace(
        text, META_MODEL_LINK_RE => linked -> begin
            link_match = @something match(META_MODEL_LINK_RE, linked) error(
                "invalid meta model link match",
            )
            return "]($meta_model_base/$(required_capture(link_match, 1)))"
        end
    )
end

function format_table_row(line::String)
    contents = strip(character -> character == '|', strip(line))
    cells = [strip(cell) for cell in split(contents, '|')]
    return "| " * join(cells, " | ") * " |"
end

function normalize_tables(text::String)
    source = collect(eachline(IOBuffer(text)))
    lines = String[]
    in_fence = false
    index = 1

    while index <= length(source)
        line = source[index]
        stripped = strip(line)
        if startswith(stripped, "```")
            in_fence = !in_fence
            push!(lines, line)
            index += 1
            continue
        end

        has_table =
            !in_fence &&
            index < length(source) &&
            contains(line, '|') &&
            occursin(TABLE_SEPARATOR_RE, source[index + 1])
        if has_table
            while index <= length(source) && contains(source[index], '|')
                push!(lines, format_table_row(source[index]))
                index += 1
            end
            continue
        end

        push!(lines, line)
        index += 1
    end

    return join(lines, '\n')
end

function needs_leading_blank(line::String, in_fence::Bool)
    (in_fence || isempty(line)) && return false
    return startswith(line, "#") || startswith(line, "<a id=") || startswith(line, "```")
end

function normalize_lines(text::String)
    lines = String[]
    blank_count = 0
    in_fence = false

    for source_line in eachline(IOBuffer(text))
        line = source_line
        stripped = strip(line)

        !in_fence && occursin(TABLE_CLASS_RE, stripped) && continue

        if !in_fence
            line = replace(rstrip(line), BULLET_RE => s"\1- "; count = 1)
        end

        if needs_leading_blank(line, in_fence) && !isempty(lines) && !isempty(lines[end])
            push!(lines, "")
            blank_count = 1
        end

        if !in_fence && isempty(line)
            blank_count += 1
            blank_count > 1 && continue
        else
            blank_count = 0
        end

        push!(lines, line)
        if startswith(stripped, "```")
            in_fence = !in_fence
        end
    end

    return strip(join(lines, '\n')) * "\n"
end

function build_specification(version::String)
    expander = SourceExpander(version)
    metadata, body = expand_path!(expander, root_path(expander), #=strip_front_matter=# true)
    title = get(
        metadata, "fullTitle", "Language Server Protocol Specification - $version",
    )
    body = String(lstrip(body))
    anchors = heading_anchor_map(body)
    body = normalize_anchors(body)
    body = normalize_local_links(body, anchors)
    body = normalize_links(body, version)
    body = normalize_tables(body)
    return normalize_lines("# $title\n\n$body")
end

function print_usage(io::IO, program::String)
    return println(
        io, """usage: $program [--version VERSION] [--output PATH]

        Regenerate LSP/specification.md from the upstream LSP spec.

        options:
          -h, --help         show this help message
          --version VERSION  LSP version to fetch (default: 3.18)
          --output PATH      output Markdown path (default: LSP/specification.md)"""
    )
end

function parse_options(args::Vector{String})
    version = "3.18"
    output = "LSP/specification.md"
    arguments = Iterators.Stateful(args)

    for argument in arguments
        if argument == "-h" || argument == "--help"
            return nothing
        elseif argument == "--version" || argument == "--output"
            isempty(arguments) && throw(ArgumentError("$argument requires a value"))
            value = popfirst!(arguments)
            if argument == "--version"
                version = value
            else
                output = value
            end
        elseif startswith(argument, "--version=")
            version = String(chopprefix(argument, "--version="))
        elseif startswith(argument, "--output=")
            output = String(chopprefix(argument, "--output="))
        else
            throw(ArgumentError("unrecognized argument: $argument"))
        end
    end

    return (; version, output)
end

function (@main)(args::Vector{String})
    program = isempty(PROGRAM_FILE) ? "scripts/update-lsp-specification.jl" : PROGRAM_FILE
    options = try
        parse_options(args)
    catch error
        error isa ArgumentError || rethrow()
        println(stderr, "error: ", error.msg)
        print_usage(stderr, program)
        return 2
    end

    if isnothing(options)
        print_usage(stdout, program)
        return 0
    end

    text = try
        build_specification(options.version)
    catch error
        error isa SpecificationUpdateError || rethrow()
        println(stderr, error)
        return 1
    end

    write(options.output, text)
    println("wrote $(options.output) for LSP $(options.version)")
    return 0
end
