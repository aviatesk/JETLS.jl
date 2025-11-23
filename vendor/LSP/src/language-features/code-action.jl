"""
The kind of a code action.

Kinds are a hierarchical list of identifiers separated by `.`,
e.g. `"refactor.extract.function"`.

The set of kinds is open and client needs to announce the kinds it supports
to the server during initialization.
"""
@namespace CodeActionKind::String begin
    """
    Empty kind.
    """
    Empty = ""

    """
    Base kind for quickfix actions: 'quickfix'.
    """
    QuickFix = "quickfix"

    """
    Base kind for refactoring actions: 'refactor'.
    """
    Refactor = "refactor"

    """
    Base kind for refactoring extraction actions: 'refactor.extract'.

    Example extract actions:

    - Extract method
    - Extract function
    - Extract variable
    - Extract interface from class
    - ...
    """
    RefactorExtract = "refactor.extract"

    """
    Base kind for refactoring inline actions: 'refactor.inline'.

    Example inline actions:

    - Inline function
    - Inline variable
    - Inline constant
    - ...
    """
    RefactorInline = "refactor.inline"

    """
    Base kind for refactoring rewrite actions: 'refactor.rewrite'.

    Example rewrite actions:

    - Convert JavaScript function to class
    - Add or remove parameter
    - Encapsulate field
    - Make method static
    - Move method to base class
    - ...
    """
    RefactorRewrite = "refactor.rewrite"

    """
    Base kind for source actions: `source`.

    Source code actions apply to the entire file.
    """
    Source = "source"

    """
    Base kind for an organize imports source action:
    `source.organizeImports`.
    """
    SourceOrganizeImports = "source.organizeImports"

    """
    Base kind for a 'fix all' source action: `source.fixAll`.

    'Fix all' actions automatically fix errors that have a clear fix that
    do not require user input. They should not suppress errors or perform
    unsafe fixes such as generating new types or classes.

    # Tags
    - since - 3.17.0
    """
    SourceFixAll = "source.fixAll"
end

"""
The reason why code actions were requested.

# Tags
- since - 3.17.0
"""
@namespace CodeActionTriggerKind::Int begin
    """
    Code actions were explicitly requested by the user or by an extension.
    """
    Invoked = 1

    """
    Code actions were requested automatically.

    This typically happens when current selection in a file changes, but can
    also be triggered when file content changes.
    """
    Automatic = 2
end

@interface CodeActionClientCapabilities begin
    """
    Whether code action supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    The client supports code action literals as a valid
    response of the `textDocument/codeAction` request.

    # Tags
    - since - 3.8.0
    """
    codeActionLiteralSupport::Union{Nothing, @interface begin
        """
        The code action kind is supported with the following value
        set.
        """
        codeActionKind::(@interface begin
            """
            The code action kind values the client supports. When this
            property exists the client also guarantees that it will
            handle values outside its set gracefully and falls back
            to a default value when unknown.
            """
            valueSet::Vector{CodeActionKind.Ty}
        end)
    end} = nothing

    """
    Whether code action supports the `isPreferred` property.

    # Tags
    - since - 3.15.0
    """
    isPreferredSupport::Union{Nothing, Bool} = nothing

    """
    Whether code action supports the `disabled` property.

    # Tags
    - since - 3.16.0
    """
    disabledSupport::Union{Nothing, Bool} = nothing

    """
    Whether code action supports the `data` property which is
    preserved between a `textDocument/codeAction` and a
    `codeAction/resolve` request.

    # Tags
    - since - 3.16.0
    """
    dataSupport::Union{Nothing, Bool} = nothing

    """
    Whether the client supports resolving additional code action
    properties via a separate `codeAction/resolve` request.

    # Tags
    - since - 3.16.0
    """
    resolveSupport::Union{Nothing, @interface begin
        """
        The properties that a client can resolve lazily.
        """
        properties::Vector{String}
    end} = nothing

    """
    Whether the client honors the change annotations in
    text edits and resource operations returned via the
    `CodeAction#edit` property by for example presenting
    the workspace edit in the user interface and asking
    for confirmation.

    # Tags
    - since - 3.16.0
    """
    honorsChangeAnnotations::Union{Nothing, Bool} = nothing
end

@interface CodeActionOptions @extends WorkDoneProgressOptions begin
    """
    CodeActionKinds that this server may return.

    The list of kinds may be generic, such as `CodeActionKind.Refactor`,
    or the server may list out every specific kind they provide.
    """
    codeActionKinds::Union{Nothing, Vector{CodeActionKind.Ty}} = nothing

    """
    The server provides support to resolve additional
    information for a code action.

    # Tags
    - since - 3.16.0
    """
    resolveProvider::Union{Nothing, Bool} = nothing
end

@interface CodeActionRegistrationOptions @extends TextDocumentRegistrationOptions, CodeActionOptions begin
end

"""
Contains additional diagnostic information about the context in which
a code action is run.
"""
@interface CodeActionContext begin
    """
    An array of diagnostics known on the client side overlapping the range
    provided to the `textDocument/codeAction` request. They are provided so
    that the server knows which errors are currently presented to the user
    for the given range. There is no guarantee that these accurately reflect
    the error state of the resource. The primary parameter
    to compute code actions is the provided range.
    """
    diagnostics::Vector{Diagnostic}

    """
    Requested kind of actions to return.

    Actions not of this kind are filtered out by the client before being
    shown. So servers can omit computing them.
    """
    only::Union{Nothing, Vector{CodeActionKind.Ty}} = nothing

    """
    The reason why code actions were requested.

    # Tags
    - since - 3.17.0
    """
    triggerKind::Union{Nothing, CodeActionTriggerKind.Ty} = nothing
end

"""
A code action represents a change that can be performed in code, e.g. to fix
a problem or to refactor code.

A CodeAction must set either `edit` and/or a `command`. If both are supplied,
the `edit` is applied first, then the `command` is executed.
"""
@interface CodeAction begin
    """
    A short, human-readable, title for this code action.
    """
    title::String

    """
    The kind of the code action.

    Used to filter code actions.
    """
    kind::Union{Nothing, CodeActionKind.Ty} = nothing

    """
    The diagnostics that this code action resolves.
    """
    diagnostics::Union{Nothing, Vector{Diagnostic}} = nothing

    """
    Marks this as a preferred action. Preferred actions are used by the
    `auto fix` command and can be targeted by keybindings.

    A quick fix should be marked preferred if it properly addresses the
    underlying error. A refactoring should be marked preferred if it is the
    most reasonable choice of actions to take.

    # Tags
    - since - 3.15.0
    """
    isPreferred::Union{Nothing, Bool} = nothing

    """
    Marks that the code action cannot currently be applied.

    Clients should follow the following guidelines regarding disabled code
    actions:

    - Disabled code actions are not shown in automatic lightbulbs code
      action menus.

    - Disabled actions are shown as faded out in the code action menu when
      the user request a more specific type of code action, such as
      refactorings.

    - If the user has a keybinding that auto applies a code action and only
      a disabled code actions are returned, the client should show the user
      an error message with `reason` in the editor.

    # Tags
    - since - 3.16.0
    """
    disabled::Union{Nothing, @interface begin
        """
        Human readable description of why the code action is currently
        disabled.

        This is displayed in the code actions UI.
        """
        reason::String
    end} = nothing

    """
    The workspace edit this code action performs.
    """
    edit::Union{Nothing, WorkspaceEdit} = nothing

    """
    A command this code action executes. If a code action
    provides an edit and a command, first the edit is
    executed and then the command.
    """
    command::Union{Nothing, Command} = nothing

    """
    A data entry field that is preserved on a code action between
    a `textDocument/codeAction` and a `codeAction/resolve` request.

    # Tags
    - since - 3.16.0
    """
    data::Union{Nothing, LSPAny} = nothing
end

"""
Params for the CodeActionRequest
"""
@interface CodeActionParams @extends WorkDoneProgressParams, PartialResultParams begin
    """
    The document in which the command was invoked.
    """
    textDocument::TextDocumentIdentifier

    """
    The range for which the command was invoked.
    """
    range::Range

    """
    Context carrying additional information.
    """
    context::CodeActionContext
end

"""
The code action request is sent from the client to the server to compute commands
for a given text document and range. These commands are typically code fixes to
either fix problems or to beautify/refactor code. The result of a
`textDocument/codeAction` request is an array of `Command` literals which are
typically presented in the user interface. To ensure that a server is useful in
many clients the commands specified in a code actions should be handled by the
server and not by the client (see `workspace/executeCommand` and
`ServerCapabilities.executeCommandProvider`). If the client supports providing
edits with a code action then that mode should be used.

# Tags
- since - 3.8.0 - support for CodeAction literals to enable the following scenarios:
  - the ability to directly return a workspace edit from the code action request.
    This avoids having another server roundtrip to execute an actual code action.
    However server providers should be aware that if the code action is expensive
    to compute or the edits are huge it might still be beneficial if the result
    is simply a command and the actual edit is only computed when needed.
  - the ability to group code actions using a kind. Clients are allowed to ignore
    that information. However it allows them to better group code action for
    example into corresponding menus (e.g. all refactor code actions into a
    refactor menu).
- since - 3.16.0 - a client can offer a server to delay the computation of code
  action properties during a 'textDocument/codeAction' request
"""
@interface CodeActionRequest @extends RequestMessage begin
    method::String = "textDocument/codeAction"
    params::CodeActionParams
end

@interface CodeActionResponse @extends ResponseMessage begin
    result::Union{Vector{Union{Command, CodeAction}}, Null, Nothing}
end

"""
The request is sent from the client to the server to resolve additional
information for a given code action. This is usually used to compute the `edit`
property of a code action to avoid its unnecessary computation during the
`textDocument/codeAction` request.

Consider the clients announces the `edit` property as a property that can be
resolved lazy using the client capability

```typescript
textDocument.codeAction.resolveSupport = { properties: ['edit'] };
```

then a code action needs to be resolved using the `codeAction/resolve` request
before it can be applied.

# Tags
- since - 3.16.0
"""
@interface CodeActionResolveRequest @extends RequestMessage begin
    method::String = "codeAction/resolve"
    params::CodeAction
end

@interface CodeActionResolveResponse @extends ResponseMessage begin
    result::Union{CodeAction, Nothing}
end
