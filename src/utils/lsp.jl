import Base: isless, ∈

Base.isless(pos1::Position, pos2::Position) =
    pos1.line < pos2.line || (pos1.line == pos2.line && pos1.character < pos2.character)

pos::Position ∈ rng::Range = rng.start ≤ pos ≤ rng.var"end"

rng1::Range ∈ rng2::Range = rng2.start ≤ rng1.start && rng1.var"end" ≤ rng2.var"end"

overlap(rng1::Range, rng2::Range) = max(rng1.start, rng2.start) <= min(rng1.var"end", rng2.var"end")

# LSP utilities

@define_override_constructor LSP.CompletionItem
@define_override_constructor LSP.Diagnostic
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

This function generates clickable links in the format `[display text](uri#L<line>,<character>)`
that LSP clients can use to navigate to specific file locations. While not explicitly part of
the LSP specification, this markdown link format is supported by VS Code and LSP clients that
follow the same convention (e.g. Sublime Text's LSP plugin).

See: https://github.com/microsoft/vscode/blob/25c94ab342a6b167d4b97ade0829955d4f7e094e/src/vs/platform/opener/common/opener.ts#L131-L143

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
# Returns: "[file.jl:42:10](file:///path/to/file.jl#L42,10)"

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
            linktext *= ",$character"
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

function request_cancelled_error(message::AbstractString="Request was cancelled"; data=nothing)
    return ResponseError(;
        code = ErrorCodes.RequestCancelled,
        message,
        data)
end

"""
    show_error_message(server::Server, message::AbstractString)

Send an error notification to the client using window/showMessage.
"""
function show_error_message(server::Server, message::AbstractString)
    send(server, ShowMessageNotification(;
        params = ShowMessageParams(;
            type = MessageType.Error,
            message)))
end

"""
    show_info_message(server::Server, message::AbstractString)

Send an info notification to the client using window/showMessage.
"""
function show_info_message(server::Server, message::AbstractString)
    send(server, ShowMessageNotification(;
        params = ShowMessageParams(;
            type = MessageType.Info,
            message)))
end

"""
    show_warning_message(server::Server, message::AbstractString)

Send a warning notification to the client using window/showMessage.
"""
function show_warning_message(server::Server, message::AbstractString)
    send(server, ShowMessageNotification(;
        params = ShowMessageParams(;
            type = MessageType.Warning,
            message)))
end

"""
    show_log_message(server::Server, message::AbstractString)

Send a log message to the client using window/logMessage.
This appears in the client's output channel rather than as a popup.
"""
function show_log_message(server::Server, message::AbstractString)
    send(server, LogMessageNotification(;
        params = LogMessageParams(;
            type = MessageType.Log,
            message)))
end

"""
    show_debug_message(server::Server, message::AbstractString)

Send a debug message to the client using window/logMessage.
This appears in the client's output channel and is typically only shown
when the client is in debug/verbose mode.
"""
function show_debug_message(server::Server, message::AbstractString)
    send(server, LogMessageNotification(;
        params = LogMessageParams(;
            type = MessageType.Debug,
            message)))
end

"""
    handle_response_error(server::Server, msg::Dict{Symbol,Any}, context::AbstractString)

Common error handling for response messages. Checks for error field and shows appropriate message.
Returns true if an error was handled, false otherwise.
"""
function handle_response_error(server::Server, msg::Dict{Symbol,Any}, context::AbstractString)
    if haskey(msg, :error)
        error_msg = get(msg[:error], "message", "Unknown error")
        show_error_message(server, "Failed to $context: $error_msg")
        return true
    end
    return false
end

function send_progress(server::Server, token::ProgressToken, value::WorkDoneProgressValue)
    send(server, ProgressNotification(; params = ProgressParams(; token, value)))
    if value isa WorkDoneProgressEnd
        put!(server.state.message_queue, HandledToken(token))
    end
end
