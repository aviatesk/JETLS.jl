"""
The file event type.
"""
@namespace FileChangeType::Int begin
    "The file got created."
    Created = 1
    "The file got changed."
    Changed = 2
    "The file got deleted."
    Deleted = 3
end

"""
An event describing a file change.
"""
@interface FileEvent begin
    "The file's URI."
    uri::DocumentUri
    "The change type."
    type::FileChangeType.Ty
end

"""
The watched files notification is sent from the client to the server when the client
detects changes to file watched by the language client.
"""
@interface DidChangeWatchedFilesParams begin
    "The actual file events."
    changes::Vector{FileEvent}
end

"""
The watched files notification is sent from the client to the server when the client
detects changes to file watched by the language client.
"""
@interface DidChangeWatchedFilesNotification @extends NotificationMessage begin
    method::String = "workspace/didChangeWatchedFiles"
    params::DidChangeWatchedFilesParams
end

"""
The kind of watcher events to register for.
"""
@namespace WatchKind::Int begin
    "Interested in create events."
    Create = 1
    "Interested in change events."
    Change = 2
    "Interested in delete events."
    Delete = 4
end

# Type aliases for glob patterns
const Pattern = String

"""
A relative pattern is a helper to construct glob patterns that are matched
relatively to a base URI. The common value for a baseUri is a workspace
folder root, but it can be another absolute URI as well.

# Tags
- since – 3.17.0
"""
@interface RelativePattern begin
    """
    A workspace folder or a base URI to which this pattern will be matched
    against relatively.
    """
    baseUri::Union{WorkspaceFolder, URI}

    """
    The actual glob pattern.
    """
    pattern::Pattern
end

"""
The glob pattern. Either a string pattern or a relative pattern.

# Tags
- since – 3.17.0
"""
const GlobPattern = Union{Pattern, RelativePattern}

"""
A glob pattern specifying which files to watch.
"""
@interface FileSystemWatcher begin
    """
    The glob pattern to watch. See {@link GlobPattern glob pattern}
    for more detail.

    # Tags
    - since – 3.17.0 support for relative patterns.
    """
    globPattern::GlobPattern

    """
    The kind of events of interest. If omitted it defaults
    to WatchKind.Create | WatchKind.Change | WatchKind.Delete
    which is 7.
    """
    kind::Union{WatchKind.Ty, Nothing} = nothing
end

"""
Describe options to be used when registering for file system change events.
"""
@interface DidChangeWatchedFilesRegistrationOptions begin
    "The watchers to register."
    watchers::Vector{FileSystemWatcher}
end

"""
Capabilities specific to the `workspace/didChangeWatchedFiles` notification.
"""
@interface DidChangeWatchedFilesClientCapabilities begin
    """
    Did change watched files notification supports dynamic registration.
    Please note that the current protocol doesn't support static
    configuration for file changes from the server side.
    """
    dynamicRegistration::Union{Bool, Nothing} = nothing

    """
    Whether the client has support for relative patterns
    or not.

    # Tags
    - since – 3.17.0
    """
    relativePatternSupport::Union{Bool, Nothing} = nothing
end
