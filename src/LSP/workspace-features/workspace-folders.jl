"""
Since version 3.6.0

Many tools support more than one root folder per workspace. Examples for this are VS Code’s
multi-root support, Atom’s project folder support or Sublime’s project support. If a client
workspace consists of multiple roots then a server typically needs to know about this.
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
    registered on the client side. The ID can be used to unregister for these events using
    the `client/unregisterCapability` request.
    """
    changeNotifications::Union{String, Bool, Nothing} = nothing
end

@interface WorkspaceFolder begin
    "The associated URI for this workspace folder."
    uri::URI

    """
    The name of the workspace folder. Used to refer to this workspace folder in the user
    interface.
    """
    name::String
end
