"""
The base protocol offers also support to report progress in a generic fashion.
This mechanism can be used to report any kind of progress including work done progress
(usually used to report progress in the user interface using a progress bar) and partial
result progress to support streaming of results.

A progress notification has the following properties:
"""
const ProgressToken = Union{Int, String}

@interface WorkDoneProgressParams begin
    "An optional token that a server can use to report work done progress."
    workDoneToken::Union{ProgressToken, Nothing} = nothing
end

@interface WorkDoneProgressOptions begin
    workDoneProgress::Union{Bool, Nothing} = nothing
end

@interface PartialResultParams begin
    "An optional token that a server can use to report partial results (e.g. streaming) to the client."
    partialResultToken::Union{ProgressToken, Nothing} = nothing
end

"""
A TraceValue represents the level of verbosity with which the server systematically reports
its execution trace using \$/logTrace notifications. The initial trace value is set by the
client at initialization and can be modified later using the \$/setTrace notification.
"""
@namespace TraceValue::String begin
    off = "off"
    messages = "messages"
    verbose = "verbose"
end
