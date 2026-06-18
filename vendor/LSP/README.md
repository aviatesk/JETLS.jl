# LSP.jl

[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/LSP.jl.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/LSP.jl.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg?flag=LSP.jl)](https://codecov.io/gh/aviatesk/JETLS.jl&flags[0]=LSP.jl)

In this directory, the Julia version of the
[LSP specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification)
is defined.

The Julia implementation leverages custom `@interface` and `@namespace` macros
to faithfully translate the TypeScript LSP specification into idiomatic Julia code:

- **`@interface` macro**: Creates Julia structs with keyword constructors
  (`@kwdef`) that mirror TypeScript `interface`s:
  - Uses `Union{Nothing, Type} = nothing` field to represent TypeScript's optional properties (`field?: Type`)
  - Supports inheritance through `@extends` to compose interfaces (similar to TypeScript's `extends`)
  - Enables anonymous interface definitions within `Union` types for inline type specifications
  - Automatically configures `StructTypes.omitempties()` to omit optional fields during JSON serialization
  - Creates method dispatchers for `RequestMessage` and `NotificationMessage` types to enable LSP message routing

- **`@namespace` macro**: Creates Julia modules containing typed constants that correspond to TypeScript `namespace`s:
  - Defines constants with proper type annotations and documentation
  - Provides a `Ty` type alias for convenient type references: See also the [Caveats](#caveats) section

These macros create Julia types that mirror the original TypeScript interfaces
while handling type conversions, optional fields, and inheritance relationships.
This approach ensures that the Julia code maintains semantic equivalence with
the TypeScript specification while taking advantage of Julia's type system,
making the implementation both accurate and performant.

## Caveats

- **Namespace Type References**: Due to the design that mimics TypeScript
  `namespace`s using Julia's `module` system, namespace types must be referenced
  with the `.Ty` suffix (e.g., `SignatureHelpTriggerKind.Ty` below).
  This is a constraint of Julia's module scoping rules, where constants and
  type aliases within modules cannot be accessed without explicit qualification.

## Original specification

The original LSP specification is managed in [specification.md](./specification.md),
which is just Markdown file.
By passing the Markdown text of the LSP specification you want to convert
to an LLM model along with this documentation, you can request automatic
conversion to Julia LSP definitions.

To regenerate `specification.md` from the upstream LSP sources, run this
from the repository root:

```sh
python3 scripts/update-lsp-specification.py \
  --version 3.18 \
  --output LSP/specification.md
```

The script expands Jekyll includes from the upstream `gh-pages` branch and
normalizes the result into a standalone Markdown file.

## Example conversion

As an example of the conversion, it is shown below how the
"Signature Help Request" specification is converted to Julia code.

[The original LSP text](./specification.md#signature-help-request):
> #### Signature Help Request
>
> The signature help request is sent from the client to the server to request signature information at a given cursor position.
>
> _Client Capability_:
> - property name (optional): `textDocument.signatureHelp`
> - property type: `SignatureHelpClientCapabilities` defined as follows:
>
> ```typescript
> export interface SignatureHelpClientCapabilities {
> 	/**
> 	 * Whether signature help supports dynamic registration.
> 	 */
> 	dynamicRegistration?: boolean;
>
> 	/**
> 	 * The client supports the following `SignatureInformation`
> 	 * specific properties.
> 	 */
> 	signatureInformation?: ClientSignatureInformationOptions;
>
> 	/**
> 	 * The client supports sending additional context information for a
> 	 * `textDocument/signatureHelp` request. A client that opts into
> 	 * contextSupport will also support the `retriggerCharacters` on
> 	 * `SignatureHelpOptions`.
> 	 *
> 	 * @since 3.15.0
> 	 */
> 	contextSupport?: boolean;
> }
> ```
>
> ```typescript
> export type ClientSignatureInformationOptions = {
> 	/**
> 	 * Client supports the following content formats for the documentation
> 	 * property. The order describes the preferred format of the client.
> 	 */
> 	documentationFormat?: MarkupKind[];
>
> 	/**
> 	 * Client capabilities specific to parameter information.
> 	 */
> 	parameterInformation?: ClientSignatureParameterInformationOptions;
>
> 	/**
> 	 * The client supports the `activeParameter` property on
> 	 * `SignatureInformation` literal.
> 	 *
> 	 * @since 3.16.0
> 	 */
> 	activeParameterSupport?: boolean;
>
> 	/**
> 	 * The client supports the `activeParameter` property on
> 	 * `SignatureHelp`/`SignatureInformation` being set to `null` to
> 	 * indicate that no parameter should be active.
> 	 *
> 	 * @since 3.18.0
> 	 */
> 	noActiveParameterSupport?: boolean;
> };
> ```
>
> ```typescript
> export type ClientSignatureParameterInformationOptions = {
> 	/**
> 	 * The client supports processing label offsets instead of a
> 	 * simple label string.
> 	 *
> 	 * @since 3.14.0
> 	 */
> 	labelOffsetSupport?: boolean;
> };
> ```
>
> _Server Capability_:
> - property name (optional): `signatureHelpProvider`
> - property type: `SignatureHelpOptions` defined as follows:
>
> ```typescript
> export interface SignatureHelpOptions extends WorkDoneProgressOptions {
> 	/**
> 	 * The characters that trigger signature help
> 	 * automatically.
> 	 */
> 	triggerCharacters?: string[];
>
> 	/**
> 	 * List of characters that re-trigger signature help.
> 	 *
> 	 * These trigger characters are only active when signature help is already
> 	 * showing. All trigger characters are also counted as re-trigger
> 	 * characters.
> 	 *
> 	 * @since 3.15.0
> 	 */
> 	retriggerCharacters?: string[];
> }
> ```
>
> _Registration Options_: `SignatureHelpRegistrationOptions` defined as follows:
>
> ```typescript
> export interface SignatureHelpRegistrationOptions
> 	extends TextDocumentRegistrationOptions, SignatureHelpOptions {
> }
> ```
>
> _Request_:
> - method: `textDocument/signatureHelp`
> - params: `SignatureHelpParams` defined as follows:
>
> ```typescript
> export interface SignatureHelpParams extends TextDocumentPositionParams,
> 	WorkDoneProgressParams {
> 	/**
> 	 * The signature help context. This is only available if the client
> 	 * specifies to send this using the client capability
> 	 * `textDocument.signatureHelp.contextSupport === true`
> 	 *
> 	 * @since 3.15.0
> 	 */
> 	context?: SignatureHelpContext;
> }
> ```
>
> ```typescript
> /**
>  * How a signature help was triggered.
>  *
>  * @since 3.15.0
>  */
> export namespace SignatureHelpTriggerKind {
> 	/**
> 	 * Signature help was invoked manually by the user or by a command.
> 	 */
> 	export const Invoked: 1 = 1;
> 	/**
> 	 * Signature help was triggered by a trigger character.
> 	 */
> 	export const TriggerCharacter: 2 = 2;
> 	/**
> 	 * Signature help was triggered by the cursor moving or by the document
> 	 * content changing.
> 	 */
> 	export const ContentChange: 3 = 3;
> }
> export type SignatureHelpTriggerKind = 1 | 2 | 3;
> ```
>
> ```typescript
> /**
>  * Additional information about the context in which a signature help request
>  * was triggered.
>  *
>  * @since 3.15.0
>  */
> export interface SignatureHelpContext {
> 	/**
> 	 * Action that caused signature help to be triggered.
> 	 */
> 	triggerKind: SignatureHelpTriggerKind;
>
> 	/**
> 	 * Character that caused signature help to be triggered.
> 	 *
> 	 * This is undefined when triggerKind !==
> 	 * SignatureHelpTriggerKind.TriggerCharacter
> 	 */
> 	triggerCharacter?: string;
>
> 	/**
> 	 * `true` if signature help was already showing when it was triggered.
> 	 *
> 	 * Retriggers occur when the signature help is already active and can be
> 	 * caused by actions such as typing a trigger character, a cursor move, or
> 	 * document content changes.
> 	 */
> 	isRetrigger: boolean;
>
> 	/**
> 	 * The currently active `SignatureHelp`.
> 	 *
> 	 * The `activeSignatureHelp` has its `SignatureHelp.activeSignature` field
> 	 * updated based on the user navigating through available signatures.
> 	 */
> 	activeSignatureHelp?: SignatureHelp;
> }
> ```
>
> _Response_:
> - result: `SignatureHelp` \| `null` defined as follows:
>
> ```typescript
> /**
>  * Signature help represents the signature of something
>  * callable. There can be multiple signatures,
>  * but only one active one and only one active parameter.
>  */
> export interface SignatureHelp {
> 	/**
> 	 * One or more signatures. If no signatures are available,
> 	 * the signature help request should return `null`.
> 	 */
> 	signatures: SignatureInformation[];
>
> 	/**
> 	 * The active signature. If omitted or the value lies outside the
> 	 * range of `signatures`, the value defaults to zero or is ignored if
> 	 * the `SignatureHelp` has no signatures.
> 	 *
> 	 * Whenever possible, implementers should make an active decision about
> 	 * the active signature and shouldn't rely on a default value.
> 	 *
> 	 * In future versions of the protocol, this property might become
> 	 * mandatory to better express this.
> 	 */
> 	activeSignature?: uinteger;
>
> 	/**
> 	 * The active parameter of the active signature.
> 	 *
> 	 * If `null`, no parameter of the signature is active (for example, a named
> 	 * argument that does not match any declared parameters). This is only valid
> 	 * since 3.18.0 and if the client specifies the client capability
> 	 * `textDocument.signatureHelp.noActiveParameterSupport === true`.
> 	 *
> 	 * If omitted or the value lies outside the range of
> 	 * `signatures[activeSignature].parameters`, it defaults to 0 if the active
> 	 * signature has parameters.
> 	 *
> 	 * If the active signature has no parameters, it is ignored.
> 	 *
> 	 * Since version 3.16.0 the `SignatureInformation` itself provides a
> 	 * `activeParameter` property and it should be used instead of this one.
> 	 */
> 	activeParameter?: uinteger | null;
> }
> ```
>
> ```typescript
> /**
>  * Represents the signature of something callable. A signature
>  * can have a label, like a function-name, a doc-comment, and
>  * a set of parameters.
>  */
> export interface SignatureInformation {
> 	/**
> 	 * The label of this signature. Will be shown in the UI.
> 	 */
> 	label: string;
>
> 	/**
> 	 * The human-readable doc-comment of this signature.
>      * Will be shown in the UI but can be omitted.
> 	 */
> 	documentation?: string | MarkupContent;
>
> 	/**
> 	 * The parameters of this signature.
> 	 */
> 	parameters?: ParameterInformation[];
>
> 	/**
> 	 * The index of the active parameter.
> 	 *
> 	 * If `null`, no parameter of the signature is active (for example, a named
> 	 * argument that does not match any declared parameters). This is only valid
> 	 * since 3.18.0 and if the client specifies the client capability
> 	 * `textDocument.signatureHelp.noActiveParameterSupport === true`.
> 	 *
> 	 * If provided (or `null`), this is used in place of
> 	 * `SignatureHelp.activeParameter`.
> 	 *
> 	 * @since 3.16.0
> 	 */
> 	activeParameter?: uinteger | null;
> }
> ```
>
> ```typescript
> /**
>  * Represents a parameter of a callable-signature. A parameter can
>  * have a label and a doc-comment.
>  */
> export interface ParameterInformation {
>
> 	/**
> 	 * The label of this parameter information.
> 	 *
> 	 * Either a string or an inclusive start and exclusive end offset within
> 	 * its containing signature label (see SignatureInformation.label). The
> 	 * offsets are based on a UTF-16 string representation, as `Position` and
> 	 * `Range` do.
> 	 *
> 	 * To avoid ambiguities, a server should use the [start, end] offset value
> 	 * instead of using a substring. Whether a client support this is
> 	 * controlled via `labelOffsetSupport` client capability.
> 	 *
> 	 * *Note*: a label of type string should be a substring of its containing
> 	 * signature label. Its intended use case is to highlight the parameter
> 	 * label part in the `SignatureInformation.label`.
> 	 */
> 	label: string | [uinteger, uinteger];
>
> 	/**
> 	 * The human-readable doc-comment of this parameter. Will be shown
> 	 * in the UI but can be omitted.
> 	 */
> 	documentation?: string | MarkupContent;
> }
> ```
>
> - error: code and message set in case an exception happens during the signature help request.

[The converted Julia code](./src/language-features/signature-help.jl):
```julia
@interface ClientSignatureParameterInformationOptions begin
    """
    The client supports processing label offsets instead of a
    simple label string.

    - `@since` 3.14.0
    """
    labelOffsetSupport::Union{Nothing, Bool} = nothing
end

@interface ClientSignatureInformationOptions begin
    """
    Client supports the following content formats for the documentation
    property. The order describes the preferred format of the client.
    """
    documentationFormat::Union{Nothing, Vector{MarkupKind.Ty}} = nothing

    """
    Client capabilities specific to parameter information.
    """
    parameterInformation::Union{Nothing, ClientSignatureParameterInformationOptions} = nothing

    """
    The client supports the `activeParameter` property on
    `SignatureInformation` literal.

    - `@since` 3.16.0
    """
    activeParameterSupport::Union{Nothing, Bool} = nothing

    """
    The client supports the `activeParameter` property on
    `SignatureHelp`/`SignatureInformation` being set to `null` to
    indicate that no parameter should be active.

    - `@since` 3.18.0
    """
    noActiveParameterSupport::Union{Nothing, Bool} = nothing
end

@interface SignatureHelpClientCapabilities begin
    """
    Whether signature help supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    The client supports the following `SignatureInformation`
    specific properties.
    """
    signatureInformation::Union{Nothing, ClientSignatureInformationOptions} = nothing

    """
    The client supports sending additional context information for a
    `textDocument/signatureHelp` request. A client that opts into
    contextSupport will also support the `retriggerCharacters` on
    `SignatureHelpOptions`.

    - `@since` 3.15.0
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

    - `@since` 3.15.0
    """
    retriggerCharacters::Union{Nothing, Vector{String}} = nothing
end

@interface SignatureHelpRegistrationOptions @extends TextDocumentRegistrationOptions, SignatureHelpOptions begin
end

"""
How a signature help was triggered.

- `@since` 3.15.0
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

    Either a string or an inclusive start and exclusive end offset within
    its containing signature label (see SignatureInformation.label). The
    offsets are based on a UTF-16 string representation, as `Position` and
    `Range` do.

    To avoid ambiguities, a server should use the [start, end] offset value
    instead of using a substring. Whether a client support this is
    controlled via `labelOffsetSupport` client capability.

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
    The label of this signature. Will be shown in the UI.
    """
    label::String

    """
    The human-readable doc-comment of this signature.
    Will be shown in the UI but can be omitted.
    """
    documentation::Union{Nothing, String, MarkupContent} = nothing

    """
    The parameters of this signature.
    """
    parameters::Union{Nothing, Vector{ParameterInformation}} = nothing

    """
    The index of the active parameter.

    If `null`, no parameter of the signature is active (for example, a named
    argument that does not match any declared parameters). This is only valid
    since 3.18.0 and if the client specifies the client capability
    `textDocument.signatureHelp.noActiveParameterSupport === true`.

    If provided (or `null`), this is used in place of `SignatureHelp.activeParameter`.

    - `@since` 3.16.0
    """
    activeParameter::Union{Nothing, UInt, Null} = nothing
end

"""
Signature help represents the signature of something
callable. There can be multiple signatures,
but only one active one and only one active parameter.
"""
@interface SignatureHelp begin
    """
    One or more signatures. If no signatures are available,
    the signature help request should return `null`.
    """
    signatures::Vector{SignatureInformation}

    """
    The active signature. If omitted or the value lies outside the
    range of `signatures`, the value defaults to zero or is ignored if
    the `SignatureHelp` has no signatures.

    Whenever possible, implementers should make an active decision about
    the active signature and shouldn't rely on a default value.

    In future versions of the protocol, this property might become
    mandatory to better express this.
    """
    activeSignature::Union{Nothing, UInt} = nothing

    """
    The active parameter of the active signature.

    If `null`, no parameter of the signature is active (for example, a named
    argument that does not match any declared parameters). This is only valid
    since 3.18.0 and if the client specifies the client capability
    `textDocument.signatureHelp.noActiveParameterSupport === true`.

    If omitted or the value lies outside the range of
    `signatures[activeSignature].parameters`, it defaults to 0 if the active
    signature has parameters.

    If the active signature has no parameters, it is ignored.

    Since version 3.16.0 the `SignatureInformation` itself provides a
    `activeParameter` property and it should be used instead of this one.
    """
    activeParameter::Union{Nothing, UInt, Null} = nothing
end

"""
Additional information about the context in which a signature help request
was triggered.

- `@since` 3.15.0
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

    - `@since` 3.15.0
    """
    context::Union{Nothing, SignatureHelpContext} = nothing
end

"""
The signature help request is sent from the client to the server to request
signature information at a given cursor position.
"""
@interface SignatureHelpRequest @extends RequestMessage begin
    method::String = "textDocument/signatureHelp"
    params::SignatureHelpParams
end

@interface SignatureHelpResponse @extends ResponseMessage begin
    result::Union{SignatureHelp, Null, Nothing}
end
```
