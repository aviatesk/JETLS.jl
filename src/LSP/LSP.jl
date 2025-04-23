module LSP

using StructTypes

const exports = Set{Symbol}()
const method_dispatcher = Dict{String,DataType}()

include("utils/interface.jl")
include("utils/namespace.jl")

"""
A special object representing `null` value.
When used as a field specified as `StructTypes.omitempties`, the key-value pair is not
omitted in the serialized JSON but instead appears as `null`.
This special object is specifically intended for use in `ResponseMessage`.
"""
struct Null end
const null = Null()
StructTypes.StructType(::Type{Null}) = StructTypes.CustomStruct()
StructTypes.lower(::Null) = nothing
push!(exports, :Null, :null)

const boolean = Bool
# const null = Nothing
const string = String

"""
Defines an integer number in the range of -2^31 to 2^31 - 1.
"""
const integer = Int

"""
Defines an unsigned integer number in the range of 0 to 2^31 - 1.
"""
const uinteger = UInt

@doc """
Defines a decimal number.
Since decimal numbers are very rare in the language server specification we denote the exact
range with every decimal using the mathematics interval notation (e.g. `[0, 1]` denotes all
decimals `d` with `0 <= d <= 1`).
"""
const decimal = Float64

@doc """
The LSP any type

# Tags
- since – 3.17.0
"""
const LSPAny = Any

@doc """
LSP object definition.

# Tags
- since – 3.17.0
"""
const LSPObject = Dict{String,Any}

@doc """
LSP arrays.

# Tags
- since – 3.17.0
"""
const LSPArray = Vector{Any}

const URI = String


include("messages.jl")
include("documents.jl")

@interface WorkspaceFolder begin
    "The associated URI for this workspace folder."
    uri::URI

    "The name of the workspace folder. Used to refer to this workspace folder in the user interface."
    name::String
end

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

@interface WorkDoneProgressOptions begin
    workDoneProgress::Union{Bool, Nothing} = nothing
end

"""
Since version 3.6.0

Many tools support more than one root folder per workspace.
Examples for this are VS Code’s multi-root support, Atom’s project folder support or Sublime’s project support.
If a client workspace consists of multiple roots then a server typically needs to know about this.
The protocol up to now assumes one root folder which is announced to the server by the
`rootUri` property of the `InitializeParams`. If the client supports workspace folders and
announces them via the corresponding `workspaceFolders` client capability,
the `InitializeParams` contain an additional property `workspaceFolders` with the configured
workspace folders when the server starts.

The `workspace/workspaceFolders` request is sent from the server to the client to fetch the
current open list of workspace folders.
Returns null in the response if only a single file is open in the tool.
Returns an empty array if a workspace is open but no folders are configured.
"""
@interface WorkspaceFoldersServerCapabilities begin
    "The server has support for workspace folders"
    supported::Union{Bool, Nothing} = nothing
    """
    Whether the server wants to receive workspace folder change notifications.

    If a string is provided, the string is treated as an ID under which the notification is
    registered on the client side.
    The ID can be used to unregister for these events using the `client/unregisterCapability` request.
    """
    changeNotifications::Union{Union{String, Bool}, Nothing} = nothing
end

@interface ShutdownRequest @extends RequestMessage begin
    method::String = "shutdown"
end

@interface ShutdownResponse @extends ResponseMessage begin
    result::Union{Null, Nothing} = nothing
end

@interface ExitNotification @extends NotificationMessage begin
    method::String = "exit"
end

include("diagnostics.jl")

for name in exports
    Core.eval(@__MODULE__, Expr(:export, name))
end

export
    method_dispatcher

end # module LSP
