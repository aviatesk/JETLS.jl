@interface CompletionOptions @extends WorkDoneProgressOptions begin
    """
    The additional characters, beyond the defaults provided by the client (typically
    [a-zA-Z]), that should automatically trigger a completion request. For example
    `.` in JavaScript represents the beginning of an object property or method and is
    thus a good candidate for triggering a completion request.

    Most tools trigger a completion request automatically without explicitly
    requesting it using a keyboard shortcut (e.g. Ctrl+Space). Typically they
    do so when the user starts to type an identifier. For example if the user
    types `c` in a JavaScript file code complete will automatically pop up
    present `console` besides others as a completion item. Characters that
    make up identifiers don't need to be listed here.
    """
    triggerCharacters::Union{Vector{String}, Nothing} = nothing

    """
    The list of all possible characters that commit a completion. This field
    can be used if clients don't support individual commit characters per
    completion item. See client capability
    `completion.completionItem.commitCharactersSupport`.

    If a server provides both `allCommitCharacters` and commit characters on
    an individual completion item the ones on the completion item win.

    # Tags
    - since - 3.2.0
    """
    allCommitCharacters::Union{Vector{String}, Nothing} = nothing

    """
    The server provides support to resolve additional
    information for a completion item.
    """
    resolveProvider::Union{Bool, Nothing} = nothing

    """
    The server supports the following `CompletionItem` specific
    capabilities.

    # Tags
    - since - 3.17.0
    """
    completionItem::Union{Nothing, @interface begin
        """
        The server has support for completion item label
        details (see also `CompletionItemLabelDetails`) when receiving
        a completion item in a resolve call.

        # Tags
        - since - 3.17.0
        """
        labelDetailsSupport::Union{Bool, Nothing} = nothing
    end} = nothing
end

@interface CompletionRegistrationOptions @extends TextDocumentRegistrationOptions, CompletionOptions begin
end

"How a completion was triggered"
@namespace CompletionTriggerKind::Int begin
    "Completion was triggered by typing an identifier (24x7 code
    complete), manual invocation (e.g Ctrl+Space) or via API."
    Invoked = 1

    "Completion was triggered by a trigger character specified by
    the `triggerCharacters` properties of the
    `CompletionRegistrationOptions`."
    TriggerCharacter = 2

    "Completion was re-triggered as the current completion list is incomplete."
    TriggerForIncompleteCompletions = 3
end

"""
Contains additional information about the context in which a completion
request is triggered.
"""
@interface CompletionContext begin
    "How the completion was triggered."
    triggerKind::CompletionTriggerKind.Ty

    "The trigger character (a single character) that has trigger code
    complete. Is undefined if
    `triggerKind !== CompletionTriggerKind.TriggerCharacter`"
    triggerCharacter::Union{String, Nothing} = nothing
end

@interface CompletionParams @extends TextDocumentPositionParams, WorkDoneProgressParams, PartialResultParams begin
    """
    The completion context. This is only available if the client specifies
    to send this using the client capability
    `completion.contextSupport === true`
    """
    context::Union{CompletionContext, Nothing} = nothing
end

"""
Defines whether the insert text in a completion item should be interpreted as
plain text or a snippet.
"""
@namespace InsertTextFormat::Int begin
    """
    The primary text to be inserted is treated as a plain string.
    """
    PlainText = 1

    """
    The primary text to be inserted is treated as a snippet.

    A snippet can define tab stops and placeholders with `\$1`, `\$2`
    and `\${3:foo}`. `\$0` defines the final tab stop, it defaults to
    the end of the snippet. Placeholders with equal identifiers are linked,
    that is typing in one will update others too.
    """
    Snippet = 2
end

"""
How whitespace and indentation is handled during completion
item insertion

# Tags
- since - 3.16.0
"""
@namespace InsertTextMode::Int begin
    """
    The insertion or replace strings is taken as it is. If the
    value is multi line the lines below the cursor will be
    inserted using the indentation defined in the string value.
    The client will not apply any kind of adjustments to the
    string.
    """
    asIs = 1

    """
    The editor adjusts leading whitespace of new lines so that
    they match the indentation up to the cursor of the line for
    which the item is accepted.

    Consider a line like this: <2tabs><cursor><3tabs>foo. Accepting a
    multi line completion item is indented using 2 tabs and all
    following lines inserted will be indented using 2 tabs as well.
    """
    adjustIndentation = 2
end

"""
The kind of a completion entry.
"""
@namespace CompletionItemKind::Int begin
    Text = 1
    Method = 2
    Function = 3
    Constructor = 4
    Field = 5
    Variable = 6
    Class = 7
    Interface = 8
    Module = 9
    Property = 10
    Unit = 11
    Value = 12
    Enum = 13
    Keyword = 14
    Snippet = 15
    Color = 16
    File = 17
    Reference = 18
    Folder = 19
    EnumMember = 20
    Constant = 21
    Struct = 22
    Event = 23
    Operator = 24
    TypeParameter = 25
end

"""
Completion item tags are extra annotations that tweak the rendering of a
completion item.

# Tags
- since - 3.15.0
"""
@namespace CompletionItemTag::Int begin
    "Render a completion as obsolete, usually using a strike-out."
    Deprecated = 1
end

"""
A special text edit to provide an insert and a replace operation.

# Tags
- since - 3.16.0
"""
@interface InsertReplaceEdit begin
    "The string to be inserted."
    newText::String

    "The range if the insert is requested"
    insert::Range

    "The range if the replace is requested."
    replace::Range
end

"""
Additional details for a completion item label
# Tags
- since - 3.17.0
"""
@interface CompletionItemLabelDetails begin

    """
    An optional string which is rendered less prominently directly after
    {@link CompletionItem.label label}, without any spacing. Should be
    used for function signatures or type annotations.
    """
    detail::Union{String, Nothing} = nothing

    """
    An optional string which is rendered less prominently after
    {@link CompletionItemLabelDetails.detail}. Should be used for fully qualified
    names or file path.
    """
    description::Union{String, Nothing} = nothing
end

# our own data structure for `data` field of `CompletionItem`
struct CompletionData
    name::String
end
export CompletionData

@interface CompletionItem begin
    """
    The label of this completion item.

    The label property is also by default the text that
    is inserted when selecting this completion.

    If label details are provided the label itself should
    be an unqualified name of the completion item.
    """
    label::String

    """
    Additional details for the label

    # Tags
    - since - 3.17.0
    """
    labelDetails::Union{CompletionItemLabelDetails, Nothing} = nothing

    """
    The kind of this completion item. Based of the kind
    an icon is chosen by the editor. The standardized set
    of available values is defined in `CompletionItemKind`.
    """
    kind::Union{CompletionItemKind.Ty, Nothing} = nothing

    """
    Tags for this completion item.

    # Tags
    - since - 3.15.0
    """
    tags::Union{Vector{CompletionItemTag.Ty}, Nothing} = nothing

    "A human-readable string with additional information
    about this item, like type or symbol information."
    detail::Union{String, Nothing} = nothing

    "A human-readable string that represents a doc-comment."
    documentation::Union{MarkupContent, String, Nothing} = nothing

    """
    Indicates if this item is deprecated.

    @deprecated Use `tags` instead if supported.
    """
    deprecated::Union{Bool, Nothing} = nothing

    """
    Select this item when showing.

    *Note* that only one completion item can be selected and that the
    tool / client decides which item that is. The rule is that the *first*
    item of those that match best is selected.
    """
    preselect::Union{Bool, Nothing} = nothing

    """
    A string that should be used when comparing this item
    with other items. When omitted the label is used
    as the sort text for this item.
    """
    sortText::Union{String, Nothing} = nothing

    """
    A string that should be used when filtering a set of
    completion items. When omitted the label is used as the
    filter text for this item.
    """
    filterText::Union{String, Nothing} = nothing

    """
    A string that should be inserted into a document when selecting
    this completion. When omitted the label is used as the insert text
    for this item.

    The `insertText` is subject to interpretation by the client side.
    Some tools might not take the string literally. For example
    VS Code when code complete is requested in this example
    `con<cursor position>` and a completion item with an `insertText` of
    `console` is provided it will only insert `sole`. Therefore it is
    recommended to use `textEdit` instead since it avoids additional client
    side interpretation.
    """
    insertText::Union{String, Nothing} = nothing

    """
    The format of the insert text. The format applies to both the
    `insertText` property and the `newText` property of a provided
    `textEdit`. If omitted defaults to `InsertTextFormat.PlainText`.

    Please note that the insertTextFormat doesn't apply to
    `additionalTextEdits`.
    """
    insertTextFormat::Union{InsertTextFormat.Ty, Nothing} = nothing

    """
    How whitespace and indentation is handled during completion
    item insertion. If not provided the client's default value depends on
    the `textDocument.completion.insertTextMode` client capability.

    # Tags

    - since - 3.16.0
    - since - 3.17.0 - support for `textDocument.completion.insertTextMode`
    """
    insertTextMode::Union{InsertTextMode.Ty, Nothing} = nothing

    """
    An edit which is applied to a document when selecting this completion.
    When an edit is provided the value of `insertText` is ignored.

    *Note:* The range of the edit must be a single line range and it must
    contain the position at which completion has been requested.

    Most editors support two different operations when accepting a completion
    item. One is to insert a completion text and the other is to replace an
    existing text with a completion text. Since this can usually not be
    predetermined by a server it can report both ranges. Clients need to
    signal support for `InsertReplaceEdit`s via the
    `textDocument.completion.completionItem.insertReplaceSupport` client
    capability property.

    *Note 1:* The text edit's range as well as both ranges from an insert
    replace edit must be a [single line] and they must contain the position
    at which completion has been requested.
    *Note 2:* If an `InsertReplaceEdit` is returned the edit's insert range
    must be a prefix of the edit's replace range, that means it must be
    contained and starting at the same position.

    # Tags
    - since - 3.16.0 additional type `InsertReplaceEdit`
    """
    textEdit::Union{TextEdit, InsertReplaceEdit, Nothing} = nothing

    """
    The edit text used if the completion item is part of a CompletionList and
    CompletionList defines an item default for the text edit range.

    Clients will only honor this property if they opt into completion list
    item defaults using the capability `completionList.itemDefaults`.

    If not provided and a list's default range is provided the label
    property is used as a text.

    # Tags
    - since - 3.17.0
    """
    textEditText::Union{String, Nothing} = nothing

    """
    An optional array of additional text edits that are applied when
    selecting this completion. Edits must not overlap (including the same
    insert position) with the main edit nor with themselves.

    Additional text edits should be used to change text unrelated to the
    current cursor position (for example adding an import statement at the
    top of the file if the completion item will insert an unqualified type).
    """
    additionalTextEdits::Union{Vector{TextEdit}, Nothing} = nothing

    """
    An optional set of characters that when pressed while this completion is
    active will accept it first and then type that character. *Note* that all
    commit characters should have `length=1` and that superfluous characters
    will be ignored.
    """
    commitCharacters::Union{Vector{String}, Nothing} = nothing

    """
    An optional command that is executed *after* inserting this completion.
    *Note* that additional modifications to the current document should be
    described with the additionalTextEdits-property.
    """
    command::Union{Command, Nothing} = nothing

    """
    A data entry field that is preserved on a completion item between
    a completion and a completion resolve request.
    """
    data::Union{CompletionData, Nothing} = nothing
end

"""
Represents a collection of [completion items](#CompletionItem) to be
presented in the editor.
"""
@interface CompletionList begin
    """
    This list is not complete. Further typing should result in recomputing
    this list.

    Recomputed lists have all their items replaced (not appended) in the
    incomplete completion sessions.
    """
    isIncomplete::Bool

    """
    In many cases the items of an actual completion result share the same
    value for properties like `commitCharacters` or the range of a text
    edit. A completion list can therefore define item defaults which will
    be used if a completion item itself doesn't specify the value.

    If a completion list specifies a default value and a completion item
    also specifies a corresponding value the one from the item is used.

    Servers are only allowed to return default values if the client
    signals support for this via the `completionList.itemDefaults`
    capability.

    # Tags
    - since - 3.17.0
    """
    itemDefaults::Union{Nothing, @interface begin
        """
        A default commit character set.

        # Tags
        - since - 3.17.0
        """
        commitCharacters::Union{Vector{String}, Nothing} = nothing

        """
        A default edit range

        # Tags
        - since - 3.17.0
        """
        editRange::Union{Range, Nothing, @interface begin
            insert::Range
            replace::Range
        end} = nothing

        """
        A default insert text format

        # Tags
        - since - 3.17.0
        """
        insertTextFormat::Union{InsertTextFormat.Ty, Nothing} = nothing

        """
        A default insert text mode

        # Tags
        - since - 3.17.0
        """
        insertTextMode::Union{InsertTextMode.Ty, Nothing} = nothing

        """
        A default data value.

        # Tags
        - since - 3.17.0
        """
        data::Union{CompletionData, Nothing} = nothing
    end} = nothing

    """
    The completion items.
    """
    items::Vector{CompletionItem}
end

"""
The Completion request is sent from the client to the server to compute completion
items at a given cursor position. Completion items are presented in the
[IntelliSense](https://code.visualstudio.com/docs/editor/intellisense) user
interface. If computing full completion items is expensive, servers can
additionally provide a handler for the completion item resolve request
(`completionItem/resolve`). This request is sent when a completion item is
selected in the user interface. A typical use case is for example: the
[`textDocument/completion`](@ref CompletionRequest) request doesn't fill in the
`documentation` property for returned completion items since it is expensive to
compute. When the item is selected in the user interface then a
`completionItem/resolve` request is sent with the selected completion item as a
parameter. The returned completion item should have the documentation property
filled in. By default the request can only delay the computation of the `detail`
and `documentation` properties. Since 3.16.0 the client can signal that it can
resolve more properties lazily. This is done using the
[`completionItem.resolveSupport`](@ref ClientCapabilities) client capability which lists
all properties that can be filled in during a `completionItem/resolve` request. All other
properties (usually `sortText`, `filterText`, `insertText` and `textEdit`) must
be provided in the [`textDocument/completion`](@ref CompletionResponse) response and
must not be changed during resolve.

The language server protocol uses the following model around completions:

- to achieve consistency across languages and to honor different clients usually
  the client is responsible for filtering and sorting. This has also the advantage
  that client can experiment with different filter and sorting models. However
  servers can enforce different behavior by setting a `filterText` / `sortText`
- for speed clients should be able to filter an already received completion list
  if the user continues typing. Servers can opt out of this using a
  [`CompletionList`](@ref) and mark it as `isIncomplete`.

A completion item provides additional means to influence filtering and sorting.
They are expressed by either creating a [`CompletionItem`](@ref) with a `insertText`
or with a `textEdit`.
The two modes differ as follows:

- **Completion item provides an `insertText` / `label` without a text edit**: in the
  model the client should filter against what the user has already typed using the
  word boundary rules of the language (e.g. resolving the word under the cursor
  position). The reason for this mode is that it makes it extremely easy for a
  server to implement a basic completion list and get it filtered on the client.
- **Completion Item with [`TextEdit`](@ref)s**: in this mode the server tells the client
  that it actually knows what it is doing. If you create a completion item with a
  [`TextEdit`](@ref) at the current cursor position no word guessing takes place and no
  automatic filtering (like with an `insertText`) should happen. This mode can be
  combined with a `sortText` and `filterText` to customize two things. If the text
  edit is a replace edit then the range denotes the word used for filtering. If
  the replace changes the text it most likely makes sense to specify a filter text
  to be used.
"""
@interface CompletionRequest @extends RequestMessage begin
    method::String = "textDocument/completion"
    params::CompletionParams
end

"""
If a `Vector{CompletionItem}` is provided it is interpreted to be complete.
So it is the same as [`{ isIncomplete: false, items }`](@ref CompletionList).
"""
@interface CompletionResponse @extends ResponseMessage begin
    result::Union{Vector{CompletionItem}, CompletionList, Null, Nothing}
end

"""
The request is sent from the client to the server to resolve additional information for a given completion item.
"""
@interface CompletionResolveRequest @extends RequestMessage begin
    method::String = "completionItem/resolve"
    params::CompletionItem
end

@interface CompletionResolveResponse @extends ResponseMessage begin
    result::Union{CompletionItem, Nothing}
end

@interface CompletionClientCapabilities begin
    """
    Whether completion supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    The client supports the following `CompletionItem` specific
    capabilities.
    """
    completionItem::Union{Nothing, @interface begin
        """
        Client supports snippets as insert text.

        A snippet can define tab stops and placeholders with `\$1`, `\$2`
        and `\${3:foo}`. `\$0` defines the final tab stop, it defaults to
        the end of the snippet. Placeholders with equal identifiers are
        linked, that is typing in one will update others too.
        """
        snippetSupport::Union{Nothing, Bool} = nothing

        """
        Client supports commit characters on a completion item.
        """
        commitCharactersSupport::Union{Nothing, Bool} = nothing

        """
        Client supports the follow content formats for the documentation
        property. The order describes the preferred format of the client.
        """
        documentationFormat::Union{Nothing, Vector{MarkupKind.Ty}} = nothing

        """
        Client supports the deprecated property on a completion item.
        """
        deprecatedSupport::Union{Nothing, Bool} = nothing

        """
        Client supports the preselect property on a completion item.
        """
        preselectSupport::Union{Nothing, Bool} = nothing

        """
        Client supports the tag property on a completion item. Clients
        supporting tags have to handle unknown tags gracefully. Clients
        especially need to preserve unknown tags when sending a completion
        item back to the server in a resolve call.

        # Tags
        - since - 3.15.0
        """
        tagSupport::Union{Nothing, @interface begin
            """
            The tags supported by the client.
            """
            valueSet::Vector{CompletionItemTag.Ty}
        end} = nothing

        """
        Client supports insert replace edit to control different behavior if
        a completion item is inserted in the text or should replace text.

        # Tags
        - since - 3.16.0
        """
        insertReplaceSupport::Union{Nothing, Bool} = nothing

        """
        Indicates which properties a client can resolve lazily on a
        completion item. Before version 3.16.0 only the predefined properties
        `documentation` and `detail` could be resolved lazily.

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
        The client supports the `insertTextMode` property on
        a completion item to override the whitespace handling mode
        as defined by the client (see `insertTextMode`).

        # Tags
        - since - 3.16.0
        """
        insertTextModeSupport::Union{Nothing, @interface begin
            valueSet::Vector{InsertTextMode.Ty}
        end} = nothing

        """
        The client has support for completion item label
        details (see also `CompletionItemLabelDetails`).

        # Tags
        - since - 3.17.0
        """
        labelDetailsSupport::Union{Nothing, Bool} = nothing
    end} = nothing

    completionItemKind::Union{Nothing, @interface begin
        """
        The completion item kind values the client supports. When this
        property exists the client also guarantees that it will
        handle values outside its set gracefully and falls back
        to a default value when unknown.

        If this property is not present the client only supports
        the completion items kinds from `Text` to `Reference` as defined in
        the initial version of the protocol.
        """
        valueSet::Union{Nothing, Vector{CompletionItemKind.Ty}} = nothing
    end} = nothing

    """
    The client supports to send additional context information for a
    `textDocument/completion` request.
    """
    contextSupport::Union{Nothing, Bool} = nothing

    """
    The client's default when the completion item doesn't provide a
    `insertTextMode` property.

    # Tags
    - since - 3.17.0
    """
    insertTextMode::Union{Nothing, InsertTextMode.Ty} = nothing

    """
    The client supports the following `CompletionList` specific
    capabilities.

    # Tags
    - since - 3.17.0
    """
    completionList::Union{Nothing, @interface begin
        """
        The client supports the following itemDefaults on
        a completion list.

        The value lists the supported property names of the
        `CompletionList.itemDefaults` object. If omitted
        no properties are supported.

        # Tags
        - since - 3.17.0
        """
        itemDefaults::Union{Nothing, Vector{String}} = nothing
    end} = nothing
end
