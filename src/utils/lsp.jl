# LSP utilities

const DEFAULT_DOCUMENT_SELECTOR = DocumentFilter[
    DocumentFilter(; language = "julia")
]

"""
    create_source_location_link(filepath::AbstractString, [showtext::AbstractString];
                                line=nothing, character=nothing)

Create a markdown-style link to a source location that can be displayed in LSP clients.

This function generates links in the format `"[show text](file://path#L#C)"` which, while
not explicitly stated in the LSP specification, is supported by most LSP clients for
navigation to specific file locations.

# Arguments
- `filepath::AbstractString`: The file path to link to
- `showtext::AbstractString`: Optional display text for the link. If not provided,
  defaults to the filepath with optional line number
- `line::Union{Integer,Nothing}=nothing`: Optional 1-based line number
- `character::Union{Integer,Nothing}=nothing`: Optional character position (requires `line` to be specified)

# Returns
A markdown-formatted string containing the clickable link.

# Examples
```julia
create_source_location_link("/path/to/file.jl")
# Returns: "[/path/to/file.jl](file:///path/to/file.jl)"

create_source_location_link("/path/to/file.jl", line=42)
# Returns: "[/path/to/file.jl:42](file:///path/to/file.jl#L42)"

create_source_location_link("/path/to/file.jl", line=42, character=10)
# Returns: "[/path/to/file.jl:42](file:///path/to/file.jl#L42C10)"
```
"""
function create_source_location_link(filepath::AbstractString, showtext::AbstractString;
                                     line::Union{Integer,Nothing}=nothing,
                                     character::Union{Integer,Nothing}=nothing)
    linktext = string(filepath2uri(filepath))
    if line !== nothing
        linktext *= "#L$line"
        if character !== nothing
            linktext *= "C$character"
        end
    end
    return "[$showtext]($linktext)"
end

function create_source_location_link(filepath::AbstractString;
                                     line::Union{Integer,Nothing}=nothing,
                                     character::Union{Integer,Nothing}=nothing)
    create_source_location_link(filepath, full_loc_text(filepath; line); line, character)
end

function full_loc_text(filepath::AbstractString;
                       line::Union{Integer,Nothing}=nothing)
    loctext = filepath
    Base.stacktrace_contract_userdir() && (loctext = Base.contractuser(loctext))
    if line !== nothing
        loctext *= string(":", line)
    end
    return loctext
end

function simple_loc_text(filepath::AbstractString; line::Union{Integer,Nothing}=nothing)
    loctext = basename(filepath)
    if line !== nothing
        loctext *= string(":", line)
    end
    return loctext
end

function file_cache_error(uri::URI; data=nothing)
    message = lazy"File cache for $uri is not initialized"
    return request_failed_error(message; data)
end

function request_failed_error(message::AbstractString; data=nothing)
    return ResponseError(;
        code = ErrorCodes.RequestFailed,
        message,
        data)
end

function get_text_and_positions(text::AbstractString, matcher::Regex=r"│")
    positions = Position[]
    lines = split(text, '\n')

    # First pass to collect positions
    for (i, line) in enumerate(lines)
        offset_adjustment = 0
        for m in eachmatch(matcher, line)
            # Position is 0-based
            # Adjust the character position by subtracting the length of previous matches
            adjusted_offset = m.offset - offset_adjustment
            push!(positions, Position(; line=i-1, character=adjusted_offset-1))
            offset_adjustment += length(m.match)
        end
    end

    # Second pass to replace all occurrences
    for (i, line) in enumerate(lines)
        lines[i] = replace(line, matcher => "")
    end

    return join(lines, '\n'), positions
end
