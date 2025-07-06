@interface SignatureHelpClientCapabilities begin
    """
    Whether signature help supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    The client supports the following `SignatureInformation`
    specific properties.
    """
    signatureInformation::Union{Nothing, @interface begin
        """
        Client supports the follow content formats for the documentation
        property. The order describes the preferred format of the client.
        """
        documentationFormat::Union{Nothing, Vector{MarkupKind.Ty}} = nothing

        """
        Client capabilities specific to parameter information.
        """
        parameterInformation::Union{Nothing, @interface begin
            """
            The client supports processing label offsets instead of a
            simple label string.

            # Tags
            - since - 3.14.0
            """
            labelOffsetSupport::Union{Nothing, Bool} = nothing
        end} = nothing

        """
        The client supports the `activeParameter` property on
        `SignatureInformation` literal.

        # Tags
        - since - 3.16.0
        """
        activeParameterSupport::Union{Nothing, Bool} = nothing
    end} = nothing

    """
    The client supports to send additional context information for a
    `textDocument/signatureHelp` request. A client that opts into
    contextSupport will also support the `retriggerCharacters` on
    `SignatureHelpOptions`.

    # Tags
    - since - 3.15.0
    """
    contextSupport::Union{Nothing, Bool} = nothing
end

@interface SignatureHelpOptions @extends WorkDoneProgressOptions begin
    """
    The characters that trigger signature help
    automatically.
    """
    triggerCharacters::Union{Nothing, Vector{String}} = nothing

    """
    List of characters that re-trigger signature help.

    These trigger characters are only active when signature help is already
    showing. All trigger characters are also counted as re-trigger
    characters.

    # Tags
    - since - 3.15.0
    """
    retriggerCharacters::Union{Nothing, Vector{String}} = nothing
end

@interface SignatureHelpRegistrationOptions @extends TextDocumentRegistrationOptions, SignatureHelpOptions begin
end

"""
How a signature help was triggered.

# Tags
- since - 3.15.0
"""
@namespace SignatureHelpTriggerKind::Int begin
    """
    Signature help was invoked manually by the user or by a command.
    """
    Invoked = 1
    """
    Signature help was triggered by a trigger character.
    """
    TriggerCharacter = 2
    """
    Signature help was triggered by the cursor moving or by the document
    content changing.
    """
    ContentChange = 3
end

"""
Represents a parameter of a callable-signature. A parameter can
have a label and a doc-comment.
"""
@interface ParameterInformation begin

    """
    The label of this parameter information.

    Either a string or an inclusive start and exclusive end offsets within
    its containing signature label. (see SignatureInformation.label). The
    offsets are based on a UTF-16 string representation as `Position` and
    `Range` does.

    *Note*: a label of type string should be a substring of its containing
    signature label. Its intended use case is to highlight the parameter
    label part in the `SignatureInformation.label`.
    """
    label::Union{String, Vector{UInt}} # vector should have length 2

    """
    The human-readable doc-comment of this parameter. Will be shown
    in the UI but can be omitted.
    """
    documentation::Union{Nothing, String, MarkupContent} = nothing
end

"""
Represents the signature of something callable. A signature
can have a label, like a function-name, a doc-comment, and
a set of parameters.
"""
@interface SignatureInformation begin
    """
    The label of this signature. Will be shown in
    the UI.
    """
    label::String

    """
    The human-readable doc-comment of this signature. Will be shown
    in the UI but can be omitted.
    """
    documentation::Union{Nothing, String, MarkupContent} = nothing

    """
    The parameters of this signature.
    """
    parameters::Union{Nothing, Vector{ParameterInformation}} = nothing

    """
    The index of the active parameter.

    If provided, this is used in place of `SignatureHelp.activeParameter`.

     # Tags
    - since - 3.16.0
    """
    activeParameter::Union{Nothing, UInt} = nothing
end

"""
Signature help represents the signature of something
callable. There can be multiple signature but only one
active and only one active parameter.
"""
@interface SignatureHelp begin
    """
    One or more signatures. If no signatures are available the signature help
    request should return `null`.
    """
    signatures::Vector{SignatureInformation}

    """
    The active signature. If omitted or the value lies outside the
    range of `signatures` the value defaults to zero or is ignore if
    the `SignatureHelp` as no signatures.

    Whenever possible implementors should make an active decision about
    the active signature and shouldn't rely on a default value.

    In future version of the protocol this property might become
    mandatory to better express this.
    """
    activeSignature::Union{Nothing, UInt} = nothing

    """
    The active parameter of the active signature. If omitted or the value
    lies outside the range of `signatures[activeSignature].parameters`
    defaults to 0 if the active signature has parameters. If
    the active signature has no parameters it is ignored.
    In future version of the protocol this property might become
    mandatory to better express the active parameter if the
    active signature does have any.
    """
    activeParameter::Union{Nothing, UInt} = nothing
end

"""
Additional information about the context in which a signature help request
was triggered.

# Tags
- since - 3.15.0
"""
@interface SignatureHelpContext begin
    """
    Action that caused signature help to be triggered.
    """
    triggerKind::SignatureHelpTriggerKind.Ty

    """
    Character that caused signature help to be triggered.

    This is undefined when triggerKind !==
    SignatureHelpTriggerKind.TriggerCharacter
    """
    triggerCharacter::Union{Nothing, String} = nothing

    """
    `true` if signature help was already showing when it was triggered.

    Retriggers occur when the signature help is already active and can be
    caused by actions such as typing a trigger character, a cursor move, or
    document content changes.
    """
    isRetrigger::Bool

    """
    The currently active `SignatureHelp`.

    The `activeSignatureHelp` has its `SignatureHelp.activeSignature` field
    updated based on the user navigating through available signatures.
    """
    activeSignatureHelp::Union{Nothing, SignatureHelp} = nothing
end

@interface SignatureHelpParams @extends TextDocumentPositionParams, WorkDoneProgressParams begin
    """
    The signature help context. This is only available if the client
    specifies to send this using the client capability
    `textDocument.signatureHelp.contextSupport === true`

    # Tags
    - since - 3.15.0
    """
    context::Union{Nothing, SignatureHelpContext} = nothing
end

"""
The signature help request is sent from the client to the server to request signature
information at a given cursor position.
"""
@interface SignatureHelpRequest @extends RequestMessage begin
    method::String = "textDocument/signatureHelp"
    params::SignatureHelpParams
end

@interface SignatureHelpResponse @extends ResponseMessage begin
    result::Union{SignatureHelp, Null, Nothing}
end
