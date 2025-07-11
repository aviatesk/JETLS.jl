import Base: isless, ∈

Base.isless(pos1::Position, pos2::Position) =
    pos1.line < pos2.line || (pos1.line == pos2.line && pos1.character < pos2.character)

rng1::Range ∈ rng2::Range = rng2.start ≤ rng1.start && rng1.var"end" ≤ rng2.var"end"

overlap(rng1::Range, rng2::Range) = max(rng1.start, rng2.start) <= min(rng1.var"end", rng2.var"end")

# LSP utilities

@define_override_constructor LSP.CompletionItem
@define_override_constructor LSP.Position
@define_override_constructor LSP.Range

const DEFAULT_DOCUMENT_SELECTOR = DocumentFilter[
    DocumentFilter(; language = "julia")
]

"""
    create_source_location_link(uri::URI, showtext::Union{Nothing,AbstractString}=nothing;
                                line::Union{Integer,Nothing}=nothing,
                                character::Union{Integer,Nothing}=nothing)

Create a markdown-style link to a source location that can be displayed in LSP clients.

This function generates clickable links in the format `[display text](uri#L<line>C<character>)`
that LSP clients can use to navigate to specific file locations. While not explicitly part of
the LSP specification, this markdown link format is widely supported by LSP clients including
VS Code, Neovim, and others.

# Arguments
- `uri::URI`: The file URI to link to
- `showtext::Union{Nothing,AbstractString}`: Optional display text for the link.
  If unspecified, automatically generated using `full_loc_text` from the URI's filename.
- `line::Union{Integer,Nothing}=nothing`: Optional 1-based line number to link to
- `character::Union{Integer,Nothing}=nothing`: Optional 1-based character position within the line.
  Note: `character` is only used when `line` is also specified.

# Returns
A markdown-formatted string containing the clickable link that can be rendered in hover
documentation, completion items, or other LSP responses supporting markdown content.

[remote file](http://example.com/file.jl#L5)

# Examples
```julia
# Basic file link
uri = URI("file:///path/to/file.jl")
create_source_location_link(uri, "file.jl")
# Returns: "[file.jl](file:///path/to/file.jl)"

# Link with line number
create_source_location_link(uri, "file.jl:42"; line=42)
# Returns: "[file.jl:42](file:///path/to/file.jl#L42)"

# Link with line and character position
create_source_location_link(uri, "file.jl:42:10"; line=42, character=10)
# Returns: "[file.jl:42:10](file:///path/to/file.jl#L42C10)"

# Using URI with automatic display text
uri = URI("file:///path/to/file.jl")
create_source_location_link(uri; line=42)
# Returns: "[/path/to/file.jl:42](file:///path/to/file.jl#L42)"
```
"""
function create_source_location_link(uri::URI,
                                     showtext::Union{Nothing,AbstractString}=nothing;
                                     line::Union{Integer,Nothing}=nothing,
                                     character::Union{Integer,Nothing}=nothing)
    linktext = string(uri)
    if line !== nothing
        linktext *= "#L$line"
        if character !== nothing
            linktext *= "C$character"
        end
    end
    if isnothing(showtext)
        showtext = full_loc_text(uri; line)
    end
    return "[$showtext]($linktext)"
end

function full_loc_text(uri::URI; line::Union{Integer,Nothing}=nothing)
    loctext = uri2filename(uri)
    Base.stacktrace_contract_userdir() && (loctext = Base.contractuser(loctext))
    if line !== nothing
        loctext *= string(":", line)
    end
    return loctext
end

function simple_loc_text(uri::URI; line::Union{Integer,Nothing}=nothing)
    loctext = basename(uri2filename(uri))
    if line !== nothing
        loctext *= string(":", line)
    end
    return loctext
end

function file_cache_error(uri::URI; data=nothing)
    message = lazy"File cache for $uri is not found"
    return request_failed_error(message; data)
end

function request_failed_error(message::AbstractString; data=nothing)
    return ResponseError(;
        code = ErrorCodes.RequestFailed,
        message,
        data)
end

"""
    get_text_and_positions(text::AbstractString, matcher::Regex=r"│") -> (clean_text::String, positions::Vector{Position})

Extract positions of markers in text and return the cleaned text with markers removed.

This function is primarily used in tests to mark specific positions in code snippets.
It finds all occurrences of the marker pattern, records their positions as LSP-compatible
`Position` objects, and returns the text with all markers removed.

# Arguments
- `text::AbstractString`: The input text containing position markers
- `matcher::Regex=r"│"`: The regex pattern to match position markers (default: `│`)

# Returns
`(clean_text::String, positions::Vector{Position})`:
- `clean_text::String`: The input text with all markers removed
- `positions::Vector{Position}`: LSP Position objects (0-based line and character indices)

# Notes
- Character positions are calculated correctly for multi-byte characters (e.g., Unicode)
- The function properly converts byte offsets to character offsets as required by LSP
- Positions are 0-based as per LSP specification

# Example
```julia
text = \"\"\"
function foo()
    return x│ + 1
end
\"\"\"
clean_text, positions = get_text_and_positions(text)
# clean_text: "function foo()\\n    return x + 1\\nend\\n"
# positions: [Position(line=1, character=11)]
```
"""
function get_text_and_positions(text::AbstractString, matcher::Regex=r"│")
    positions = Position[]
    lines = split(text, '\n')

    for (i, line) in enumerate(lines)
        char_offset_adjustment = 0
        for m in eachmatch(matcher, line)
            # Convert byte offset to character offset
            # Count the number of characters before the match
            char_offset = 0
            byte_pos = 1
            while byte_pos < m.offset
                char_offset += 1
                byte_pos = nextind(line, byte_pos)
            end

            adjusted_char_offset = char_offset - char_offset_adjustment
            push!(positions, Position(; line=i-1, character=adjusted_char_offset))
            char_offset_adjustment += length(m.match)
        end
    end

    for (i, line) in enumerate(lines)
        lines[i] = replace(line, matcher => "")
    end

    return join(lines, '\n'), positions
end

"""
    show_error_message(server::Server, message::String)

Send an error notification to the client using window/showMessage.
"""
function show_error_message(server::Server, message::String)
    send(server, ShowMessageNotification(;
        params = ShowMessageParams(;
            type = MessageType.Error,
            message)))
end

"""
    show_info_message(server::Server, message::String)

Send an info notification to the client using window/showMessage.
"""
function show_info_message(server::Server, message::String)
    send(server, ShowMessageNotification(;
        params = ShowMessageParams(;
            type = MessageType.Info,
            message)))
end

"""
    show_warning_message(server::Server, message::String)

Send a warning notification to the client using window/showMessage.
"""
function show_warning_message(server::Server, message::String)
    send(server, ShowMessageNotification(;
        params = ShowMessageParams(;
            type = MessageType.Warning,
            message)))
end

"""
    show_log_message(server::Server, message::String)

Send a log message to the client using window/logMessage.
This appears in the client's output channel rather than as a popup.
"""
function show_log_message(server::Server, message::String)
    send(server, LogMessageNotification(;
        params = LogMessageParams(;
            type = MessageType.Log,
            message)))
end

"""
    show_debug_message(server::Server, message::String)

Send a debug message to the client using window/logMessage.
This appears in the client's output channel and is typically only shown
when the client is in debug/verbose mode.
"""
function show_debug_message(server::Server, message::String)
    send(server, LogMessageNotification(;
        params = LogMessageParams(;
            type = MessageType.Debug,
            message)))
end
