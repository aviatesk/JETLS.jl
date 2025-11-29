# Language Server Protocol Specification - 3.17

This document describes the 3.17.x version of the language server protocol. An implementation for node of the 3.17.x version of the protocol can be found [here](https://github.com/Microsoft/vscode-languageserver-node).

**Note:** edits to this specification can be made via a pull request against this markdown [document](https://github.com/Microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/specification.md).

## What’s new in 3.17

All new 3.17 features are tagged with a corresponding since version 3.17 text or in JSDoc using `@since 3.17.0` annotation. Major new feature are: type hierarchy, inline values, inlay hints, notebook document support and a meta model that describes the 3.17 LSP version.

A detailed list of the changes can be found in the [change log](#version3170) <a id="version3170"></a>

The version of the specification is used to group features into a new specification release and to refer to their first appearance. Features in the spec are kept compatible using so called capability flags which are exchanged between the client and the server during initialization.

## Base Protocol

The base protocol consists of a header and a content part (comparable to HTTP). The header and content part are separated by a ‘\\r\\n’.

### Header Part

The header part consists of header fields. Each header field is comprised of a name and a value, separated by ‘: ‘ (a colon and a space). The structure of header fields conform to the [HTTP semantic](https://tools.ietf.org/html/rfc7230#section-3.2). Each header field is terminated by ‘\\r\\n’. Considering the last header field and the overall header itself are each terminated with ‘\\r\\n’, and that at least one header is mandatory, this means that two ‘\\r\\n’ sequences always immediately precede the content part of a message.

Currently the following header fields are supported:

| Header Field Name | Value Type | Description |
| --- | --- | --- |
| Content-Length | number | The length of the content part in bytes. This header is required. |
| Content-Type | string | The mime type of the content part. Defaults to application/vscode-jsonrpc; charset=utf-8 |

The header part is encoded using the ‘ascii’ encoding. This includes the ‘\\r\\n’ separating the header and content part.

### Content Part

Contains the actual content of the message. The content part of a message uses [JSON-RPC](http://www.jsonrpc.org/) to describe requests, responses and notifications. The content part is encoded using the charset provided in the Content-Type field. It defaults to `utf-8`, which is the only encoding supported right now. If a server or client receives a header with a different encoding than `utf-8` it should respond with an error.

(Prior versions of the protocol used the string constant `utf8` which is not a correct encoding constant according to [specification](http://www.iana.org/assignments/character-sets/character-sets.xhtml).) For backwards compatibility it is highly recommended that a client and a server treats the string `utf8` as `utf-8`.

### Example:

```plaintext
Content-Length: ...\r\n
\r\n
{
	"jsonrpc": "2.0",
	"id": 1,
	"method": "textDocument/completion",
	"params": {
		...
	}
}
```

### Base Protocol JSON structures

The following TypeScript definitions describe the base [JSON-RPC protocol](http://www.jsonrpc.org/specification):

#### Base Types

The protocol use the following definitions for integers, unsigned integers, decimal numbers, objects and arrays:

```typescript
/**
 * Defines an integer number in the range of -2^31 to 2^31 - 1.
 */
export type integer = number;
```

```typescript
/**
 * Defines an unsigned integer number in the range of 0 to 2^31 - 1.
 */
export type uinteger = number;
```

```typescript
/**
 * Defines a decimal number. Since decimal numbers are very
 * rare in the language server specification we denote the
 * exact range with every decimal using the mathematics
 * interval notation (e.g. [0, 1] denotes all decimals d with
 * 0 <= d <= 1.
 */
export type decimal = number;
```

```typescript
/**
 * The LSP any type
 *
 * @since 3.17.0
 */
export type LSPAny = LSPObject | LSPArray | string | integer | uinteger |
	decimal | boolean | null;
```

```typescript
/**
 * LSP object definition.
 *
 * @since 3.17.0
 */
export type LSPObject = { [key: string]: LSPAny };
```

```typescript
/**
 * LSP arrays.
 *
 * @since 3.17.0
 */
export type LSPArray = LSPAny[];
```

#### Abstract Message

A general message as defined by JSON-RPC. The language server protocol always uses “2.0” as the `jsonrpc` version.

```typescript
interface Message {
	jsonrpc: string;
}
```

#### Request Message

A request message to describe a request between the client and the server. Every processed request must send a response back to the sender of the request.

```typescript
interface RequestMessage extends Message {

	/**
	 * The request id.
	 */
	id: integer | string;

	/**
	 * The method to be invoked.
	 */
	method: string;

	/**
	 * The method's params.
	 */
	params?: array | object;
}
```

#### Response Message

A Response Message sent as a result of a request. If a request doesn’t provide a result value the receiver of a request still needs to return a response message to conform to the JSON-RPC specification. The result property of the ResponseMessage should be set to `null` in this case to signal a successful request.

```typescript
interface ResponseMessage extends Message {
	/**
	 * The request id.
	 */
	id: integer | string | null;

	/**
	 * The result of a request. This member is REQUIRED on success.
	 * This member MUST NOT exist if there was an error invoking the method.
	 */
	result?: LSPAny;

	/**
	 * The error object in case a request fails.
	 */
	error?: ResponseError;
}
```

```typescript
interface ResponseError {
	/**
	 * A number indicating the error type that occurred.
	 */
	code: integer;

	/**
	 * A string providing a short description of the error.
	 */
	message: string;

	/**
	 * A primitive or structured value that contains additional
	 * information about the error. Can be omitted.
	 */
	data?: LSPAny;
}
```

```typescript
export namespace ErrorCodes {
	// Defined by JSON-RPC
	export const ParseError: integer = -32700;
	export const InvalidRequest: integer = -32600;
	export const MethodNotFound: integer = -32601;
	export const InvalidParams: integer = -32602;
	export const InternalError: integer = -32603;

	/**
	 * This is the start range of JSON-RPC reserved error codes.
	 * It doesn't denote a real error code. No LSP error codes should
	 * be defined between the start and end range. For backwards
	 * compatibility the \`ServerNotInitialized\` and the \`UnknownErrorCode\`
	 * are left in the range.
	 *
	 * @since 3.16.0
	 */
	export const jsonrpcReservedErrorRangeStart: integer = -32099;
	/** @deprecated use jsonrpcReservedErrorRangeStart */
	export const serverErrorStart: integer = jsonrpcReservedErrorRangeStart;

	/**
	 * Error code indicating that a server received a notification or
	 * request before the server has received the \`initialize\` request.
	 */
	export const ServerNotInitialized: integer = -32002;
	export const UnknownErrorCode: integer = -32001;

	/**
	 * This is the end range of JSON-RPC reserved error codes.
	 * It doesn't denote a real error code.
	 *
	 * @since 3.16.0
	 */
	export const jsonrpcReservedErrorRangeEnd = -32000;
	/** @deprecated use jsonrpcReservedErrorRangeEnd */
	export const serverErrorEnd: integer = jsonrpcReservedErrorRangeEnd;

	/**
	 * This is the start range of LSP reserved error codes.
	 * It doesn't denote a real error code.
	 *
	 * @since 3.16.0
	 */
	export const lspReservedErrorRangeStart: integer = -32899;

	/**
	 * A request failed but it was syntactically correct, e.g the
	 * method name was known and the parameters were valid. The error
	 * message should contain human readable information about why
	 * the request failed.
	 *
	 * @since 3.17.0
	 */
	export const RequestFailed: integer = -32803;

	/**
	 * The server cancelled the request. This error code should
	 * only be used for requests that explicitly support being
	 * server cancellable.
	 *
	 * @since 3.17.0
	 */
	export const ServerCancelled: integer = -32802;

	/**
	 * The server detected that the content of a document got
	 * modified outside normal conditions. A server should
	 * NOT send this error code if it detects a content change
	 * in it unprocessed messages. The result even computed
	 * on an older state might still be useful for the client.
	 *
	 * If a client decides that a result is not of any use anymore
	 * the client should cancel the request.
	 */
	export const ContentModified: integer = -32801;

	/**
	 * The client has canceled a request and a server has detected
	 * the cancel.
	 */
	export const RequestCancelled: integer = -32800;

	/**
	 * This is the end range of LSP reserved error codes.
	 * It doesn't denote a real error code.
	 *
	 * @since 3.16.0
	 */
	export const lspReservedErrorRangeEnd: integer = -32800;
}
```

#### Notification Message

A notification message. A processed notification message must not send a response back. They work like events.

```typescript
interface NotificationMessage extends Message {
	/**
	 * The method to be invoked.
	 */
	method: string;

	/**
	 * The notification's params.
	 */
	params?: array | object;
}
```

#### $ Notifications and Requests

Notification and requests whose methods start with `$/` are messages which are protocol implementation dependent and might not be implementable in all clients or servers. For example if the server implementation uses a single threaded synchronous programming language then there is little a server can do to react to a `$/cancelRequest` notification. If a server or client receives notifications starting with `$/` it is free to ignore the notification. If a server or client receives a request starting with `$/` it must error the request with error code `MethodNotFound` (e.g. `-32601`).

#### Cancellation Support

The base protocol offers support for request cancellation. To cancel a request, a notification message with the following properties is sent:

*Notification*:

- method: ‘$/cancelRequest’
- params: [`CancelParams`](#cancellation-support) defined as follows:

```typescript
interface CancelParams {
	/**
	 * The request id to cancel.
	 */
	id: integer | string;
}
```

A request that got canceled still needs to return from the server and send a response back. It can not be left open / hanging. This is in line with the JSON-RPC protocol that requires that every request sends a response back. In addition it allows for returning partial results on cancel. If the request returns an error response on cancellation it is advised to set the error code to `ErrorCodes.RequestCancelled`.

#### Progress Support

> *Since version 3.15.0*

The base protocol offers also support to report progress in a generic fashion. This mechanism can be used to report any kind of progress including [work done progress](#work-done-progress) (usually used to report progress in the user interface using a progress bar) and partial result progress to support streaming of results.

A progress notification has the following properties:

*Notification*:

- method: ‘$/progress’
- params: [`ProgressParams`](#progress-support) defined as follows:

```typescript
type ProgressToken = integer | string;
```

```typescript
interface ProgressParams<T> {
	/**
	 * The progress token provided by the client or server.
	 */
	token: ProgressToken;

	/**
	 * The progress data.
	 */
	value: T;
}
```

Progress is reported against a token. The token is different than the request ID which allows to report progress out of band and also for notification.

## Language Server Protocol

The language server protocol defines a set of JSON-RPC request, response and notification messages which are exchanged using the above base protocol. This section starts describing the basic JSON structures used in the protocol. The document uses TypeScript interfaces in strict mode to describe these. This means for example that a `null` value has to be explicitly listed and that a mandatory property must be listed even if a falsify value might exist. Based on the basic JSON structures, the actual requests with their responses and the notifications are described.

An example would be a request send from the client to the server to request a hover value for a symbol at a certain position in a text document. The request’s method would be [`textDocument/hover`](#hover-request) with a parameter like this:

```typescript
interface HoverParams {
	textDocument: string; /** The text document's URI in string form */
	position: { line: uinteger; character: uinteger; };
}
```

The result of the request would be the hover to be presented. In its simple form it can be a string. So the result looks like this:

```typescript
interface HoverResult {
	value: string;
}
```

Please also note that a response return value of `null` indicates no result. It doesn’t tell the client to resend the request.

In general, the language server protocol supports JSON-RPC messages, however the base protocol defined here uses a convention such that the parameters passed to request/notification messages should be of `object` type (if passed at all). However, this does not disallow using `Array` parameter types in custom messages.

The protocol currently assumes that one server serves one tool. There is currently no support in the protocol to share one server between different tools. Such a sharing would require additional protocol e.g. to lock a document to support concurrent editing.

### Capabilities

Not every language server can support all features defined by the protocol. LSP therefore provides ‘capabilities’. A capability groups a set of language features. A development tool and the language server announce their supported features using capabilities. As an example, a server announces that it can handle the [`textDocument/hover`](#hover-request) request, but it might not handle the `workspace/symbol` request. Similarly, a development tool announces its ability to provide `about to save` notifications before a document is saved, so that a server can compute textual edits to format the edited document before it is saved.

The set of capabilities is exchanged between the client and server during the [initialize](#initialize-request) request.

### Request, Notification and Response Ordering

Responses to requests should be sent in roughly the same order as the requests appear on the server or client side. So for example if a server receives a [`textDocument/completion`](#completion-request) request and then a [`textDocument/signatureHelp`](#signature-help-request) request it will usually first return the response for the [`textDocument/completion`](#completion-request) and then the response for [`textDocument/signatureHelp`](#signature-help-request).

However, the server may decide to use a parallel execution strategy and may wish to return responses in a different order than the requests were received. The server may do so as long as this reordering doesn’t affect the correctness of the responses. For example, reordering the result of [`textDocument/completion`](#completion-request) and [`textDocument/signatureHelp`](#signature-help-request) is allowed, as each of these requests usually won’t affect the output of the other. On the other hand, the server most likely should not reorder [`textDocument/definition`](#goto-definition-request) and [`textDocument/rename`](#rename-request) requests, since executing the latter may affect the result of the former.

### Message Documentation

As said LSP defines a set of requests, responses and notifications. Each of those are documented using the following format:

- a header describing the request
- an optional *Client capability* section describing the client capability of the request. This includes the client capabilities property path and JSON structure.
- an optional *Server Capability* section describing the server capability of the request. This includes the server capabilities property path and JSON structure. Clients should ignore server capabilities they don’t understand (e.g. the initialize request shouldn’t fail in this case).
- an optional *Registration Options* section describing the registration option if the request or notification supports dynamic capability registration. See the [register](#register-capability) and [unregister](#register-capability) request for how this works in detail.
- a *Request* section describing the format of the request sent. The method is a string identifying the request, the params are documented using a TypeScript interface. It is also documented whether the request supports work done progress and partial result progress.
- a *Response* section describing the format of the response. The result item describes the returned data in case of a success. The optional partial result item describes the returned data of a partial result notification. The error.data describes the returned data in case of an error. Please remember that in case of a failure the response already contains an error.code and an error.message field. These fields are only specified if the protocol forces the use of certain error codes or messages. In cases where the server can decide on these values freely they aren’t listed here.

### Basic JSON Structures

There are quite some JSON structures that are shared between different requests and notifications. Their structure and capabilities are documented in this section.

#### URI

URI’s are transferred as strings. The URI’s format is defined in [https://tools.ietf.org/html/rfc3986](https://tools.ietf.org/html/rfc3986)

```plaintext
  foo://example.com:8042/over/there?name=ferret#nose
  \_/   \______________/\_________/ \_________/ \__/
   |           |            |            |        |
scheme     authority       path        query   fragment
   |   _____________________|__
  / \ /                        \
  urn:example:animal:ferret:nose
```

We also maintain a node module to parse a string into `scheme`, `authority`, `path`, `query`, and `fragment` URI components. The GitHub repository is [https://github.com/Microsoft/vscode-uri](https://github.com/Microsoft/vscode-uri), and the npm module is [https://www.npmjs.com/package/vscode-uri](https://www.npmjs.com/package/vscode-uri).

Many of the interfaces contain fields that correspond to the URI of a document. For clarity, the type of such a field is declared as a [`DocumentUri`](#documentUri). Over the wire, it will still be transferred as a string, but this guarantees that the contents of that string can be parsed as a valid URI. <a id="documentUri"></a>

Care should be taken to handle encoding in URIs. For example, some clients (such as VS Code) may encode colons in drive letters while others do not. The URIs below are both valid, but clients and servers should be consistent with the form they use themselves to ensure the other party doesn’t interpret them as distinct URIs. Clients and servers should not assume that each other are encoding the same way (for example a client encoding colons in drive letters cannot assume server responses will have encoded colons). The same applies to casing of drive letters - one party should not assume the other party will return paths with drive letters cased the same as itself.

```plaintext
file:///c:/project/readme.md
file:///C%3A/project/readme.md
```

```typescript
type DocumentUri = string;
```

There is also a tagging interface for normal non document URIs. It maps to a `string` as well.

#### Regular Expressions

Regular expression are a powerful tool and there are actual use cases for them in the language server protocol. However the downside with them is that almost every programming language has its own set of regular expression features so the specification can not simply refer to them as a regular expression. So the LSP uses a two step approach to support regular expressions:

- the client will announce which regular expression engine it will use. This will allow server that are written for a very specific client make full use of the regular expression capabilities of the client
- the specification will define a set of regular expression features that should be supported by a client. Instead of writing a new specification LSP will refer to the [ECMAScript Regular Expression specification](https://tc39.es/ecma262/#sec-regexp-regular-expression-objects) and remove features from it that are not necessary in the context of LSP or hard to implement for other clients. <a id="regExp"></a>

*Client Capability*:

The following client capability is used to announce a client’s regular expression engine

- property path (optional): `general.regularExpressions`
- property type: [`RegularExpressionsClientCapabilities`](#regExp) defined as follows:

```typescript
/**
 * Client capabilities specific to regular expressions.
 */
export interface RegularExpressionsClientCapabilities {
	/**
	 * The engine's name.
	 */
	engine: string;

	/**
	 * The engine's version.
	 */
	version?: string;
}
```

The following table lists the well known engine values. Please note that the table should be driven by the community which integrates LSP into existing clients. It is not the goal of the spec to list all available regular expression engines.

| Engine | Version | Documentation |
| --- | --- | --- |
| ECMAScript | `ES2020` | [ECMAScript 2020](https://tc39.es/ecma262/#sec-regexp-regular-expression-objects) & [MDN](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Regular_Expressions) |

*Regular Expression Subset*:

The following features from the [ECMAScript 2020](https://tc39.es/ecma262/#sec-regexp-regular-expression-objects) regular expression specification are NOT mandatory for a client:

- *Assertions*: Lookahead assertion, Negative lookahead assertion, lookbehind assertion, negative lookbehind assertion.
- *Character classes*: matching control characters using caret notation (e.g. `\cX`) and matching UTF-16 code units (e.g. `\uhhhh`).
- *Group and ranges*: named capturing groups.
- *Unicode property escapes*: none of the features needs to be supported.

The only regular expression flag that a client needs to support is ‘i’ to specify a case insensitive search.

#### Enumerations

The protocol supports two kind of enumerations: (a) integer based enumerations and (b) string based enumerations. Integer based enumerations usually start with `1`. The ones that don’t are historical and they were kept to stay backwards compatible. If appropriate, the value set of an enumeration is announced by the defining side (e.g. client or server) and transmitted to the other side during the initialize handshake. An example is the [`CompletionItemKind`](#completionItemKind) enumeration. It is announced by the client using the `textDocument.completion.completionItemKind` client property. <a id="completionItemKind"></a>

To support the evolution of enumerations the using side of an enumeration shouldn’t fail on an enumeration value it doesn’t know. It should simply ignore it as a value it can use and try to do its best to preserve the value on round trips. Lets look at the [`CompletionItemKind`](#completionItemKind) enumeration as an example again: if in a future version of the specification an additional completion item kind with the value `n` gets added and announced by a client an (older) server not knowing about the value should not fail but simply ignore the value as a usable item kind. <a id="completionItemKind"></a>

#### Text Documents

The current protocol is tailored for textual documents whose content can be represented as a string. There is currently no support for binary documents. A position inside a document (see Position definition below) is expressed as a zero-based line and character offset.

> New in 3.17

Prior to 3.17 the offsets were always based on a UTF-16 string representation. So in a string of the form `a𐐀b` the character offset of the character `a` is 0, the character offset of `𐐀` is 1 and the character offset of b is 3 since `𐐀` is represented using two code units in UTF-16. Since 3.17 clients and servers can agree on a different string encoding representation (e.g. UTF-8). The client announces it’s supported encoding via the client capability [`general.positionEncodings`](#capabilities). The value is an array of position encodings the client supports, with decreasing preference (e.g. the encoding at index `0` is the most preferred one). To stay backwards compatible the only mandatory encoding is UTF-16 represented via the string `utf-16`. The server can pick one of the encodings offered by the client and signals that encoding back to the client via the initialize result’s property [`capabilities.positionEncoding`](#capabilities). If the string value `utf-16` is missing from the client’s capability `general.positionEncodings` servers can safely assume that the client supports UTF-16. If the server omits the position encoding in its initialize result the encoding defaults to the string value `utf-16`. Implementation considerations: since the conversion from one encoding into another requires the content of the file / line the conversion is best done where the file is read which is usually on the server side.

To ensure that both client and server split the string into the same line representation the protocol specifies the following end-of-line sequences: ‘\\n’, ‘\\r\\n’ and ‘\\r’. Positions are line end character agnostic. So you can not specify a position that denotes `\r|\n` or `\n|` where `|` represents the character offset.

```typescript
export const EOL: string[] = ['\n', '\r\n', '\r'];
```

#### Position

Position in a text document expressed as zero-based line and zero-based character offset. A position is between two characters like an ‘insert’ cursor in an editor. Special values like for example `-1` to denote the end of a line are not supported.

```typescript
interface Position {
	/**
	 * Line position in a document (zero-based).
	 */
	line: uinteger;

	/**
	 * Character offset on a line in a document (zero-based). The meaning of this
	 * offset is determined by the negotiated \`PositionEncodingKind\`.
	 *
	 * If the character value is greater than the line length it defaults back
	 * to the line length.
	 */
	character: uinteger;
}
```

When describing positions the protocol needs to specify how offsets (specifically character offsets) should be interpreted. The corresponding [`PositionEncodingKind`](#position) is negotiated between the client and the server during initialization.

```typescript
/**
 * A type indicating how positions are encoded,
 * specifically what column offsets mean.
 *
 * @since 3.17.0
 */
export type PositionEncodingKind = string;

/**
 * A set of predefined position encoding kinds.
 *
 * @since 3.17.0
 */
export namespace PositionEncodingKind {

	/**
	 * Character offsets count UTF-8 code units (e.g bytes).
	 */
	export const UTF8: PositionEncodingKind = 'utf-8';

	/**
	 * Character offsets count UTF-16 code units.
	 *
	 * This is the default and must always be supported
	 * by servers
	 */
	export const UTF16: PositionEncodingKind = 'utf-16';

	/**
	 * Character offsets count UTF-32 code units.
	 *
	 * Implementation note: these are the same as Unicode code points,
	 * so this \`PositionEncodingKind\` may also be used for an
	 * encoding-agnostic representation of character offsets.
	 */
	export const UTF32: PositionEncodingKind = 'utf-32';
}
```

#### Range

A range in a text document expressed as (zero-based) start and end positions. A range is comparable to a selection in an editor. Therefore, the end position is exclusive. If you want to specify a range that contains a line including the line ending character(s) then use an end position denoting the start of the next line. For example:

```typescript
{
    start: { line: 5, character: 23 },
    end : { line: 6, character: 0 }
}
```

```typescript
interface Range {
	/**
	 * The range's start position.
	 */
	start: Position;

	/**
	 * The range's end position.
	 */
	end: Position;
}
```

#### TextDocumentItem

An item to transfer a text document from the client to the server.

```typescript
interface TextDocumentItem {
	/**
	 * The text document's URI.
	 */
	uri: DocumentUri;

	/**
	 * The text document's language identifier.
	 */
	languageId: string;

	/**
	 * The version number of this document (it will increase after each
	 * change, including undo/redo).
	 */
	version: integer;

	/**
	 * The content of the opened text document.
	 */
	text: string;
}
```

Text documents have a language identifier to identify a document on the server side when it handles more than one language to avoid re-interpreting the file extension. If a document refers to one of the programming languages listed below it is recommended that clients use those ids.

| Language | Identifier |
| --- | --- |
| ABAP | `abap` |
| Windows Bat | `bat` |
| BibTeX | `bibtex` |
| Clojure | `clojure` |
| Coffeescript | `coffeescript` |
| C | `c` |
| C++ | `cpp` |
| C# | `csharp` |
| CSS | `css` |
| Diff | `diff` |
| Dart | `dart` |
| Dockerfile | `dockerfile` |
| Elixir | `elixir` |
| Erlang | `erlang` |
| F# | `fsharp` |
| Git | `git-commit` and `git-rebase` |
| Go | `go` |
| Groovy | `groovy` |
| Handlebars | `handlebars` |
| HTML | `html` |
| Ini | `ini` |
| Java | `java` |
| JavaScript | `javascript` |
| JavaScript React | `javascriptreact` |
| JSON | `json` |
| LaTeX | `latex` |
| Less | `less` |
| Lua | `lua` |
| Makefile | `makefile` |
| Markdown | `markdown` |
| Objective-C | `objective-c` |
| Objective-C++ | `objective-cpp` |
| Perl | `perl` |
| Perl 6 | `perl6` |
| PHP | `php` |
| Powershell | `powershell` |
| Pug | `jade` |
| Python | `python` |
| R | `r` |
| Razor (cshtml) | `razor` |
| Ruby | `ruby` |
| Rust | `rust` |
| SCSS | `scss` (syntax using curly brackets), `sass` (indented syntax) |
| Scala | `scala` |
| ShaderLab | `shaderlab` |
| Shell Script (Bash) | `shellscript` |
| SQL | `sql` |
| Swift | `swift` |
| TypeScript | `typescript` |
| TypeScript React | `typescriptreact` |
| TeX | `tex` |
| Visual Basic | `vb` |
| XML | `xml` |
| XSL | `xsl` |
| YAML | `yaml` |

#### TextDocumentIdentifier

Text documents are identified using a URI. On the protocol level, URIs are passed as strings. The corresponding JSON structure looks like this:

```typescript
interface TextDocumentIdentifier {
	/**
	 * The text document's URI.
	 */
	uri: DocumentUri;
}
```

#### VersionedTextDocumentIdentifier

An identifier to denote a specific version of a text document. This information usually flows from the client to the server.

```typescript
interface VersionedTextDocumentIdentifier extends TextDocumentIdentifier {
	/**
	 * The version number of this document.
	 *
	 * The version number of a document will increase after each change,
	 * including undo/redo. The number doesn't need to be consecutive.
	 */
	version: integer;
}
```

An identifier which optionally denotes a specific version of a text document. This information usually flows from the server to the client.

```typescript
interface OptionalVersionedTextDocumentIdentifier extends TextDocumentIdentifier {
	/**
	 * The version number of this document. If an optional versioned text document
	 * identifier is sent from the server to the client and the file is not
	 * open in the editor (the server has not received an open notification
	 * before) the server can send \`null\` to indicate that the version is
	 * known and the content on disk is the master (as specified with document
	 * content ownership).
	 *
	 * The version number of a document will increase after each change,
	 * including undo/redo. The number doesn't need to be consecutive.
	 */
	version: integer | null;
}
```

#### TextDocumentPositionParams

Was `TextDocumentPosition` in 1.0 with inlined parameters.

A parameter literal used in requests to pass a text document and a position inside that document. It is up to the client to decide how a selection is converted into a position when issuing a request for a text document. The client can for example honor or ignore the selection direction to make LSP request consistent with features implemented internally.

```typescript
interface TextDocumentPositionParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The position inside the text document.
	 */
	position: Position;
}
```

#### DocumentFilter

A document filter denotes a document through properties like `language`, `scheme` or `pattern`. An example is a filter that applies to TypeScript files on disk. Another example is a filter that applies to JSON files with name `package.json`:

```typescript
{ language: 'typescript', scheme: 'file' }
{ language: 'json', pattern: '**/package.json' }
```

```typescript
export interface DocumentFilter {
	/**
	 * A language id, like \`typescript\`.
	 */
	language?: string;

	/**
	 * A Uri scheme, like \`file\` or \`untitled\`.
	 */
	scheme?: string;

	/**
	 * A glob pattern, like \`*.{ts,js}\`.
	 *
	 * Glob patterns can have the following syntax:
	 * - \`*\` to match one or more characters in a path segment
	 * - \`?\` to match on one character in a path segment
	 * - \`**\` to match any number of path segments, including none
	 * - \`{}\` to group sub patterns into an OR expression. (e.g. \`**​/*.{ts,js}\`
	 *   matches all TypeScript and JavaScript files)
	 * - \`[]\` to declare a range of characters to match in a path segment
	 *   (e.g., \`example.[0-9]\` to match on \`example.0\`, \`example.1\`, …)
	 * - \`[!...]\` to negate a range of characters to match in a path segment
	 *   (e.g., \`example.[!0-9]\` to match on \`example.a\`, \`example.b\`, but
	 *   not \`example.0\`)
	 */
	pattern?: string;
}
```

Please note that for a document filter to be valid at least one of the properties for `language`, `scheme`, or `pattern` must be set. To keep the type definition simple all properties are marked as optional.

A document selector is the combination of one or more document filters.

```typescript
export type DocumentSelector = DocumentFilter[];
```

#### TextEdit & AnnotatedTextEdit <a id="annotatedTextEdit"></a>

> New in version 3.16: Support for [`AnnotatedTextEdit`](#annotatedTextEdit).

A textual edit applicable to a text document.

```typescript
interface TextEdit {
	/**
	 * The range of the text document to be manipulated. To insert
	 * text into a document create a range where start === end.
	 */
	range: Range;

	/**
	 * The string to be inserted. For delete operations use an
	 * empty string.
	 */
	newText: string;
}
```

Since 3.16.0 there is also the concept of an annotated text edit which supports to add an annotation to a text edit. The annotation can add information describing the change to the text edit.

```typescript
/**
 * Additional information that describes document changes.
 *
 * @since 3.16.0
 */
export interface ChangeAnnotation {
	/**
	 * A human-readable string describing the actual change. The string
	 * is rendered prominent in the user interface.
	 */
	label: string;

	/**
	 * A flag which indicates that user confirmation is needed
	 * before applying the change.
	 */
	needsConfirmation?: boolean;

	/**
	 * A human-readable string which is rendered less prominent in
	 * the user interface.
	 */
	description?: string;
}
```

Usually clients provide options to group the changes along the annotations they are associated with. To support this in the protocol an edit or resource operation refers to a change annotation using an identifier and not the change annotation literal directly. This allows servers to use the identical annotation across multiple edits or resource operations which then allows clients to group the operations under that change annotation. The actual change annotations together with their identifiers are managed by the workspace edit via the new property `changeAnnotations`.

```typescript
/**
 * An identifier referring to a change annotation managed by a workspace
 * edit.
 *
 * @since 3.16.0.
 */
export type ChangeAnnotationIdentifier = string;
``` <a id="annotatedTextEdit"></a>
```typescript
/**
 * A special text edit with an additional change annotation.
 *
 * @since 3.16.0.
 */
export interface AnnotatedTextEdit extends TextEdit {
	/**
	 * The actual annotation identifier.
	 */
	annotationId: ChangeAnnotationIdentifier;
}
```

#### TextEdit[]

Complex text manipulations are described with an array of [`TextEdit`](#textedit[])’s or [`AnnotatedTextEdit`](#annotatedTextEdit)’s, representing a single change to the document. <a id="annotatedTextEdit"></a>

All text edits ranges refer to positions in the document they are computed on. They therefore move a document from state S1 to S2 without describing any intermediate state. Text edits ranges must never overlap, that means no part of the original document must be manipulated by more than one edit. However, it is possible that multiple edits have the same start position: multiple inserts, or any number of inserts followed by a single remove or replace edit. If multiple inserts have the same position, the order in the array defines the order in which the inserted strings appear in the resulting text.

#### TextDocumentEdit

> New in version 3.16: support for [`AnnotatedTextEdit`](#annotatedTextEdit). The support is guarded by the client capability `workspace.workspaceEdit.changeAnnotationSupport`. If a client doesn’t signal the capability, servers shouldn’t send [`AnnotatedTextEdit`](#annotatedTextEdit) literals back to the client. <a id="annotatedTextEdit"></a>

Describes textual changes on a single text document. The text document is referred to as a [`OptionalVersionedTextDocumentIdentifier`](#optionalVersionedTextDocumentIdentifier) to allow clients to check the text document version before an edit is applied. A [`TextDocumentEdit`](#textdocumentedit) describes all changes on a version Si and after they are applied move the document to version Si+1. So the creator of a [`TextDocumentEdit`](#textdocumentedit) doesn’t need to sort the array of edits or do any kind of ordering. However the edits must be non overlapping. <a id="optionalVersionedTextDocumentIdentifier"></a>

```typescript
export interface TextDocumentEdit {
	/**
	 * The text document to change.
	 */
	textDocument: OptionalVersionedTextDocumentIdentifier;

	/**
	 * The edits to be applied.
	 *
	 * @since 3.16.0 - support for AnnotatedTextEdit. This is guarded by the
	 * client capability \`workspace.workspaceEdit.changeAnnotationSupport\`
	 */
	edits: (TextEdit | AnnotatedTextEdit)[];
}
```

#### Location

Represents a location inside a resource, such as a line inside a text file.

```typescript
interface Location {
	uri: DocumentUri;
	range: Range;
}
```

#### LocationLink

Represents a link between a source and a target location.

```typescript
interface LocationLink {

	/**
	 * Span of the origin of this link.
	 *
	 * Used as the underlined span for mouse interaction. Defaults to the word
	 * range at the mouse position.
	 */
	originSelectionRange?: Range;

	/**
	 * The target resource identifier of this link.
	 */
	targetUri: DocumentUri;

	/**
	 * The full target range of this link. If the target for example is a symbol
	 * then target range is the range enclosing this symbol not including
	 * leading/trailing whitespace but everything else like comments. This
	 * information is typically used to highlight the range in the editor.
	 */
	targetRange: Range;

	/**
	 * The range that should be selected and revealed when this link is being
	 * followed, e.g the name of a function. Must be contained by the
	 * \`targetRange\`. See also \`DocumentSymbol#range\`
	 */
	targetSelectionRange: Range;
}
```

#### Diagnostic

Represents a diagnostic, such as a compiler error or warning. Diagnostic objects are only valid in the scope of a resource.

```typescript
export interface Diagnostic {
	/**
	 * The range at which the message applies.
	 */
	range: Range;

	/**
	 * The diagnostic's severity. To avoid interpretation mismatches when a
	 * server is used with different clients it is highly recommended that
	 * servers always provide a severity value. If omitted, it’s recommended
	 * for the client to interpret it as an Error severity.
	 */
	severity?: DiagnosticSeverity;

	/**
	 * The diagnostic's code, which might appear in the user interface.
	 */
	code?: integer | string;

	/**
	 * An optional property to describe the error code.
	 *
	 * @since 3.16.0
	 */
	codeDescription?: CodeDescription;

	/**
	 * A human-readable string describing the source of this
	 * diagnostic, e.g. 'typescript' or 'super lint'.
	 */
	source?: string;

	/**
	 * The diagnostic's message.
	 */
	message: string;

	/**
	 * Additional metadata about the diagnostic.
	 *
	 * @since 3.15.0
	 */
	tags?: DiagnosticTag[];

	/**
	 * An array of related diagnostic information, e.g. when symbol-names within
	 * a scope collide all definitions can be marked via this property.
	 */
	relatedInformation?: DiagnosticRelatedInformation[];

	/**
	 * A data entry field that is preserved between a
	 * \`textDocument/publishDiagnostics\` notification and
	 * \`textDocument/codeAction\` request.
	 *
	 * @since 3.16.0
	 */
	data?: LSPAny;
}
```

The protocol currently supports the following diagnostic severities and tags:

```typescript
export namespace DiagnosticSeverity {
	/**
	 * Reports an error.
	 */
	export const Error: 1 = 1;
	/**
	 * Reports a warning.
	 */
	export const Warning: 2 = 2;
	/**
	 * Reports an information.
	 */
	export const Information: 3 = 3;
	/**
	 * Reports a hint.
	 */
	export const Hint: 4 = 4;
}

export type DiagnosticSeverity = 1 | 2 | 3 | 4;
```

```typescript
/**
 * The diagnostic tags.
 *
 * @since 3.15.0
 */
export namespace DiagnosticTag {
	/**
	 * Unused or unnecessary code.
	 *
	 * Clients are allowed to render diagnostics with this tag faded out
	 * instead of having an error squiggle.
	 */
	export const Unnecessary: 1 = 1;
	/**
	 * Deprecated or obsolete code.
	 *
	 * Clients are allowed to rendered diagnostics with this tag strike through.
	 */
	export const Deprecated: 2 = 2;
}

export type DiagnosticTag = 1 | 2;
```

[`DiagnosticRelatedInformation`](#diagnostic) is defined as follows:

```typescript
/**
 * Represents a related message and source code location for a diagnostic.
 * This should be used to point to code locations that cause or are related to
 * a diagnostics, e.g when duplicating a symbol in a scope.
 */
export interface DiagnosticRelatedInformation {
	/**
	 * The location of this related diagnostic information.
	 */
	location: Location;

	/**
	 * The message of this related diagnostic information.
	 */
	message: string;
}
```

[`CodeDescription`](#codeDescription) is defined as follows: <a id="codeDescription"></a>
```typescript
/**
 * Structure to capture a description for an error code.
 *
 * @since 3.16.0
 */
export interface CodeDescription {
	/**
	 * An URI to open with more information about the diagnostic error.
	 */
	href: URI;
}
```

#### Command

Represents a reference to a command. Provides a title which will be used to represent a command in the UI. Commands are identified by a string identifier. The recommended way to handle commands is to implement their execution on the server side if the client and server provides the corresponding capabilities. Alternatively the tool extension code could handle the command. The protocol currently doesn’t specify a set of well-known commands.

```typescript
interface Command {
	/**
	 * Title of the command, like \`save\`.
	 */
	title: string;
	/**
	 * The identifier of the actual command handler.
	 */
	command: string;
	/**
	 * Arguments that the command handler should be
	 * invoked with.
	 */
	arguments?: LSPAny[];
}
```

#### MarkupContent

A [`MarkupContent`](#markupContentInnerDefinition) literal represents a string value which content can be represented in different formats. Currently `plaintext` and `markdown` are supported formats. A [`MarkupContent`](#markupContentInnerDefinition) is usually used in documentation properties of result literals like [`CompletionItem`](#completion-item-resolve-request) or [`SignatureInformation`](#signatureInformation). If the format is `markdown` the content should follow the [GitHub Flavored Markdown Specification](https://github.github.com/gfm/). <a id="markupContentInnerDefinition"></a>

```typescript
/**
 * Describes the content type that a client supports in various
 * result literals like \`Hover\`, \`ParameterInfo\` or \`CompletionItem\`.
 *
 * Please note that \`MarkupKinds\` must not start with a \`$\`. This kinds
 * are reserved for internal usage.
 */
export namespace MarkupKind {
	/**
	 * Plain text is supported as a content format
	 */
	export const PlainText: 'plaintext' = 'plaintext';

	/**
	 * Markdown is supported as a content format
	 */
	export const Markdown: 'markdown' = 'markdown';
}
export type MarkupKind = 'plaintext' | 'markdown';
```

```typescript
/**
 * A \`MarkupContent\` literal represents a string value which content is
 * interpreted base on its kind flag. Currently the protocol supports
 * \`plaintext\` and \`markdown\` as markup kinds.
 *
 * If the kind is \`markdown\` then the value can contain fenced code blocks like
 * in GitHub issues.
 *
 * Here is an example how such a string can be constructed using
 * JavaScript / TypeScript:
 * \`\`\`typescript
 * let markdown: MarkdownContent = {
 * 	kind: MarkupKind.Markdown,
 * 	value: [
 * 		'# Header',
 * 		'Some text',
 * 		'\`\`\`typescript',
 * 		'someCode();',
 * 		'\`\`\`'
 * 	].join('\n')
 * };
 * \`\`\`
 *
 * *Please Note* that clients might sanitize the return markdown. A client could
 * decide to remove HTML from the markdown to avoid script execution.
 */
export interface MarkupContent {
	/**
	 * The type of the Markup
	 */
	kind: MarkupKind;

	/**
	 * The content itself
	 */
	value: string;
}
```

In addition clients should signal the markdown parser they are using via the client capability `general.markdown` introduced in version 3.16.0 defined as follows:

```typescript
/**
 * Client capabilities specific to the used markdown parser.
 *
 * @since 3.16.0
 */
export interface MarkdownClientCapabilities {
	/**
	 * The name of the parser.
	 */
	parser: string;

	/**
	 * The version of the parser.
	 */
	version?: string;

	/**
	 * A list of HTML tags that the client allows / supports in
	 * Markdown.
	 *
	 * @since 3.17.0
	 */
	allowedTags?: string[];
}
```

Known markdown parsers used by clients right now are:

| Parser | Version | Documentation |
| --- | --- | --- |
| marked | 1.1.0 | [Marked Documentation](https://marked.js.org/) |
| Python-Markdown | 3.2.2 | [Python-Markdown Documentation](https://python-markdown.github.io/) |

### File Resource changes

> New in version 3.13. Since version 3.16 file resource changes can carry an additional property `changeAnnotation` to describe the actual change in more detail. Whether a client has support for change annotations is guarded by the client capability `workspace.workspaceEdit.changeAnnotationSupport`.

File resource changes allow servers to create, rename and delete files and folders via the client. Note that the names talk about files but the operations are supposed to work on files and folders. This is in line with other naming in the Language Server Protocol (see file watchers which can watch files and folders). The corresponding change literals look as follows:

```typescript
/**
 * Options to create a file.
 */
export interface CreateFileOptions {
	/**
	 * Overwrite existing file. Overwrite wins over \`ignoreIfExists\`
	 */
	overwrite?: boolean;

	/**
	 * Ignore if exists.
	 */
	ignoreIfExists?: boolean;
}
```

```typescript
/**
 * Create file operation
 */
export interface CreateFile {
	/**
	 * A create
	 */
	kind: 'create';

	/**
	 * The resource to create.
	 */
	uri: DocumentUri;

	/**
	 * Additional options
	 */
	options?: CreateFileOptions;

	/**
	 * An optional annotation identifier describing the operation.
	 *
	 * @since 3.16.0
	 */
	annotationId?: ChangeAnnotationIdentifier;
}
```

```typescript
/**
 * Rename file options
 */
export interface RenameFileOptions {
	/**
	 * Overwrite target if existing. Overwrite wins over \`ignoreIfExists\`
	 */
	overwrite?: boolean;

	/**
	 * Ignores if target exists.
	 */
	ignoreIfExists?: boolean;
}
```

```typescript
/**
 * Rename file operation
 */
export interface RenameFile {
	/**
	 * A rename
	 */
	kind: 'rename';

	/**
	 * The old (existing) location.
	 */
	oldUri: DocumentUri;

	/**
	 * The new location.
	 */
	newUri: DocumentUri;

	/**
	 * Rename options.
	 */
	options?: RenameFileOptions;

	/**
	 * An optional annotation identifier describing the operation.
	 *
	 * @since 3.16.0
	 */
	annotationId?: ChangeAnnotationIdentifier;
}
```

```typescript
/**
 * Delete file options
 */
export interface DeleteFileOptions {
	/**
	 * Delete the content recursively if a folder is denoted.
	 */
	recursive?: boolean;

	/**
	 * Ignore the operation if the file doesn't exist.
	 */
	ignoreIfNotExists?: boolean;
}
```

```typescript
/**
 * Delete file operation
 */
export interface DeleteFile {
	/**
	 * A delete
	 */
	kind: 'delete';

	/**
	 * The file to delete.
	 */
	uri: DocumentUri;

	/**
	 * Delete options.
	 */
	options?: DeleteFileOptions;

	/**
	 * An optional annotation identifier describing the operation.
	 *
	 * @since 3.16.0
	 */
	annotationId?: ChangeAnnotationIdentifier;
}
```

#### WorkspaceEdit

A workspace edit represents changes to many resources managed in the workspace. The edit should either provide `changes` or `documentChanges`. If the client can handle versioned document edits and if `documentChanges` are present, the latter are preferred over `changes`.

Since version 3.13.0 a workspace edit can contain resource operations (create, delete or rename files and folders) as well. If resource operations are present clients need to execute the operations in the order in which they are provided. So a workspace edit for example can consist of the following two changes: (1) create file a.txt and (2) a text document edit which insert text into file a.txt. An invalid sequence (e.g. (1) delete file a.txt and (2) insert text into file a.txt) will cause failure of the operation. How the client recovers from the failure is described by the client capability: `workspace.workspaceEdit.failureHandling`

```typescript
export interface WorkspaceEdit {
	/**
	 * Holds changes to existing resources.
	 */
	changes?: { [uri: DocumentUri]: TextEdit[]; };

	/**
	 * Depending on the client capability
	 * \`workspace.workspaceEdit.resourceOperations\` document changes are either
	 * an array of \`TextDocumentEdit\`s to express changes to n different text
	 * documents where each text document edit addresses a specific version of
	 * a text document. Or it can contain above \`TextDocumentEdit\`s mixed with
	 * create, rename and delete file / folder operations.
	 *
	 * Whether a client supports versioned document edits is expressed via
	 * \`workspace.workspaceEdit.documentChanges\` client capability.
	 *
	 * If a client neither supports \`documentChanges\` nor
	 * \`workspace.workspaceEdit.resourceOperations\` then only plain \`TextEdit\`s
	 * using the \`changes\` property are supported.
	 */
	documentChanges?: (
		TextDocumentEdit[] |
		(TextDocumentEdit | CreateFile | RenameFile | DeleteFile)[]
	);

	/**
	 * A map of change annotations that can be referenced in
	 * \`AnnotatedTextEdit\`s or create, rename and delete file / folder
	 * operations.
	 *
	 * Whether clients honor this property depends on the client capability
	 * \`workspace.changeAnnotationSupport\`.
	 *
	 * @since 3.16.0
	 */
	changeAnnotations?: {
		[id: string /* ChangeAnnotationIdentifier */]: ChangeAnnotation;
	};
}
```

##### WorkspaceEditClientCapabilities

> New in version 3.13: [`ResourceOperationKind`](#resourceOperationKind) and [`FailureHandlingKind`](#failureHandlingKind) and the client capability `workspace.workspaceEdit.resourceOperations` as well as `workspace.workspaceEdit.failureHandling`. <a id="resourceOperationKind"></a>

The capabilities of a workspace edit has evolved over the time. Clients can describe their support using the following client capability:

*Client Capability*:

- property path (optional): `workspace.workspaceEdit`
- property type: [`WorkspaceEditClientCapabilities`](#workspaceeditclientcapabilities) defined as follows:

```typescript
export interface WorkspaceEditClientCapabilities {
	/**
	 * The client supports versioned document changes in \`WorkspaceEdit\`s
	 */
	documentChanges?: boolean;

	/**
	 * The resource operations the client supports. Clients should at least
	 * support 'create', 'rename' and 'delete' files and folders.
	 *
	 * @since 3.13.0
	 */
	resourceOperations?: ResourceOperationKind[];

	/**
	 * The failure handling strategy of a client if applying the workspace edit
	 * fails.
	 *
	 * @since 3.13.0
	 */
	failureHandling?: FailureHandlingKind;

	/**
	 * Whether the client normalizes line endings to the client specific
	 * setting.
	 * If set to \`true\` the client will normalize line ending characters
	 * in a workspace edit to the client specific new line character(s).
	 *
	 * @since 3.16.0
	 */
	normalizesLineEndings?: boolean;

	/**
	 * Whether the client in general supports change annotations on text edits,
	 * create file, rename file and delete file changes.
	 *
	 * @since 3.16.0
	 */
	changeAnnotationSupport?: {
		/**
		 * Whether the client groups edits with equal labels into tree nodes,
		 * for instance all edits labelled with "Changes in Strings" would
		 * be a tree node.
		 */
		groupsOnLabel?: boolean;
	};
}
```

```typescript
/**
 * The kind of resource operations supported by the client.
 */
export type ResourceOperationKind = 'create' | 'rename' | 'delete';

export namespace ResourceOperationKind {

	/**
	 * Supports creating new files and folders.
	 */
	export const Create: ResourceOperationKind = 'create';

	/**
	 * Supports renaming existing files and folders.
	 */
	export const Rename: ResourceOperationKind = 'rename';

	/**
	 * Supports deleting existing files and folders.
	 */
	export const Delete: ResourceOperationKind = 'delete';
}
```

```typescript
export type FailureHandlingKind = 'abort' | 'transactional' | 'undo'
	| 'textOnlyTransactional';

export namespace FailureHandlingKind {

	/**
	 * Applying the workspace change is simply aborted if one of the changes
	 * provided fails. All operations executed before the failing operation
	 * stay executed.
	 */
	export const Abort: FailureHandlingKind = 'abort';

	/**
	 * All operations are executed transactional. That means they either all
	 * succeed or no changes at all are applied to the workspace.
	 */
	export const Transactional: FailureHandlingKind = 'transactional';

	/**
	 * If the workspace edit contains only textual file changes they are
	 * executed transactional. If resource changes (create, rename or delete
	 * file) are part of the change the failure handling strategy is abort.
	 */
	export const TextOnlyTransactional: FailureHandlingKind
		= 'textOnlyTransactional';

	/**
	 * The client tries to undo the operations already executed. But there is no
	 * guarantee that this is succeeding.
	 */
	export const Undo: FailureHandlingKind = 'undo';
}
```

#### Work Done Progress

> *Since version 3.15.0*

Work done progress is reported using the generic [`$/progress`](#work-done-progress-begin) notification. The value payload of a work done progress notification can be of three different forms.

##### Work Done Progress Begin

To start progress reporting a [`$/progress`](#work-done-progress-begin) notification with the following payload must be sent:

```typescript
export interface WorkDoneProgressBegin {

	kind: 'begin';

	/**
	 * Mandatory title of the progress operation. Used to briefly inform about
	 * the kind of operation being performed.
	 *
	 * Examples: "Indexing" or "Linking dependencies".
	 */
	title: string;

	/**
	 * Controls if a cancel button should show to allow the user to cancel the
	 * long running operation. Clients that don't support cancellation are
	 * allowed to ignore the setting.
	 */
	cancellable?: boolean;

	/**
	 * Optional, more detailed associated progress message. Contains
	 * complementary information to the \`title\`.
	 *
	 * Examples: "3/25 files", "project/src/module2", "node_modules/some_dep".
	 * If unset, the previous progress message (if any) is still valid.
	 */
	message?: string;

	/**
	 * Optional progress percentage to display (value 100 is considered 100%).
	 * If not provided infinite progress is assumed and clients are allowed
	 * to ignore the \`percentage\` value in subsequent report notifications.
	 *
	 * The value should be steadily rising. Clients are free to ignore values
	 * that are not following this rule. The value range is [0, 100].
	 */
	percentage?: uinteger;
}
```

##### Work Done Progress Report

Reporting progress is done using the following payload:

```typescript
export interface WorkDoneProgressReport {

	kind: 'report';

	/**
	 * Controls enablement state of a cancel button. This property is only valid
	 * if a cancel button got requested in the \`WorkDoneProgressBegin\` payload.
	 *
	 * Clients that don't support cancellation or don't support control the
	 * button's enablement state are allowed to ignore the setting.
	 */
	cancellable?: boolean;

	/**
	 * Optional, more detailed associated progress message. Contains
	 * complementary information to the \`title\`.
	 *
	 * Examples: "3/25 files", "project/src/module2", "node_modules/some_dep".
	 * If unset, the previous progress message (if any) is still valid.
	 */
	message?: string;

	/**
	 * Optional progress percentage to display (value 100 is considered 100%).
	 * If not provided infinite progress is assumed and clients are allowed
	 * to ignore the \`percentage\` value in subsequent report notifications.
	 *
	 * The value should be steadily rising. Clients are free to ignore values
	 * that are not following this rule. The value range is [0, 100].
	 */
	percentage?: uinteger;
}
```

##### Work Done Progress End

Signaling the end of a progress reporting is done using the following payload:

```typescript
export interface WorkDoneProgressEnd {

	kind: 'end';

	/**
	 * Optional, a final message indicating to for example indicate the outcome
	 * of the operation.
	 */
	message?: string;
}
```

##### Initiating Work Done Progress

Work Done progress can be initiated in two different ways:

1. by the sender of a request (mostly clients) using the predefined `workDoneToken` property in the requests parameter literal. The document will refer to this kind of progress as client initiated progress.
2. by a server using the request `window/workDoneProgress/create`. The document will refer to this kind of progress as server initiated progress.

###### Client Initiated Progress

Consider a client sending a `textDocument/reference` request to a server and the client accepts work done progress reporting on that request. To signal this to the server the client would add a `workDoneToken` property to the reference request parameters. Something like this:

```json
{
	"textDocument": {
		"uri": "file:///folder/file.ts"
	},
	"position": {
		"line": 9,
		"character": 5
	},
	"context": {
		"includeDeclaration": true
	},
	// The token used to report work done progress.
	"workDoneToken": "1d546990-40a3-4b77-b134-46622995f6ae"
}
```

The corresponding type definition for the parameter property looks like this:

```typescript
export interface WorkDoneProgressParams {
	/**
	 * An optional token that a server can use to report work done progress.
	 */
	workDoneToken?: ProgressToken;
}
```

A server uses the `workDoneToken` to report progress for the specific `textDocument/reference`. For the above request the [`$/progress`](#work-done-progress-begin) notification params look like this:

```json
{
	"token": "1d546990-40a3-4b77-b134-46622995f6ae",
	"value": {
		"kind": "begin",
		"title": "Finding references for A#foo",
		"cancellable": false,
		"message": "Processing file X.ts",
		"percentage": 0
	}
}
```

The token received via the `workDoneToken` property in a request’s param literal is only valid as long as the request has not send a response back. Canceling work done progress is done by simply canceling the corresponding request.

There is no specific client capability signaling whether a client will send a progress token per request. The reason for this is that this is in many clients not a static aspect and might even change for every request instance for the same request type. So the capability is signal on every request instance by the presence of a `workDoneToken` property.

To avoid that clients set up a progress monitor user interface before sending a request but the server doesn’t actually report any progress a server needs to signal general work done progress reporting support in the corresponding server capability. For the above find references example a server would signal such a support by setting the `referencesProvider` property in the server capabilities as follows:

```json
{
	"referencesProvider": {
		"workDoneProgress": true
	}
}
```

The corresponding type definition for the server capability looks like this:

```typescript
export interface WorkDoneProgressOptions {
	workDoneProgress?: boolean;
}
```

###### Server Initiated Progress

Servers can also initiate progress reporting using the `window/workDoneProgress/create` request. This is useful if the server needs to report progress outside of a request (for example the server needs to re-index a database). The token can then be used to report progress using the same notifications used as for client initiated progress. The token provided in the create request should only be used once (e.g. only one begin, many report and one end notification should be sent to it).

To keep the protocol backwards compatible servers are only allowed to use `window/workDoneProgress/create` request if the client signals corresponding support using the client capability `window.workDoneProgress` which is defined as follows:

```typescript
	/**
	 * Window specific client capabilities.
	 */
	window?: {
		/**
		 * Whether client supports server initiated progress using the
		 * \`window/workDoneProgress/create\` request.
		 */
		workDoneProgress?: boolean;
	};
```

#### Partial Result Progress

> *Since version 3.15.0*

Partial results are also reported using the generic [`$/progress`](#work-done-progress-begin) notification. The value payload of a partial result progress notification is in most cases the same as the final result. For example the `workspace/symbol` request has `SymbolInformation[]` | `WorkspaceSymbol[]` as the result type. Partial result is therefore also of type `SymbolInformation[]` | `WorkspaceSymbol[]`. Whether a client accepts partial result notifications for a request is signaled by adding a `partialResultToken` to the request parameter. For example, a `textDocument/reference` request that supports both work done and partial result progress might look like this:

```json
{
	"textDocument": {
		"uri": "file:///folder/file.ts"
	},
	"position": {
		"line": 9,
		"character": 5
	},
	"context": {
		"includeDeclaration": true
	},
	// The token used to report work done progress.
	"workDoneToken": "1d546990-40a3-4b77-b134-46622995f6ae",
	// The token used to report partial result progress.
	"partialResultToken": "5f6f349e-4f81-4a3b-afff-ee04bff96804"
}
```

The `partialResultToken` is then used to report partial results for the find references request.

If a server reports partial result via a corresponding [`$/progress`](#work-done-progress-begin), the whole result must be reported using n [`$/progress`](#work-done-progress-begin) notifications. Each of the n [`$/progress`](#work-done-progress-begin) notification appends items to the result. The final response has to be empty in terms of result values. This avoids confusion about how the final result should be interpreted, e.g. as another partial result or as a replacing result.

If the response errors the provided partial results should be treated as follows:

- the `code` equals to `RequestCancelled`: the client is free to use the provided results but should make clear that the request got canceled and may be incomplete.
- in all other cases the provided partial results shouldn’t be used.

#### PartialResultParams

A parameter literal used to pass a partial result token.

```typescript
export interface PartialResultParams {
	/**
	 * An optional token that a server can use to report partial results (e.g.
	 * streaming) to the client.
	 */
	partialResultToken?: ProgressToken;
}
```

#### TraceValue

A [`TraceValue`](#tracevalue) represents the level of verbosity with which the server systematically reports its execution trace using [$/logTrace](#logTrace) notifications. The initial trace value is set by the client at initialization and can be modified later using the [$/setTrace](#setTrace) notification. <a id="logTrace"></a>

```typescript
export type TraceValue = 'off' | 'messages' | 'verbose';
```

### Server lifecycle

The current protocol specification defines that the lifecycle of a server is managed by the client (e.g. a tool like VS Code or Emacs). It is up to the client to decide when to start (process-wise) and when to shutdown a server.

#### Initialize Request

The initialize request is sent as the first request from the client to the server. If the server receives a request or notification before the `initialize` request it should act as follows:

- For a request the response should be an error with `code: -32002`. The message can be picked by the server.
- Notifications should be dropped, except for the exit notification. This will allow the exit of a server without an initialize request.

Until the server has responded to the `initialize` request with an [`InitializeResult`](#initializeResult), the client must not send any additional requests or notifications to the server. In addition the server is not allowed to send any requests or notifications to the client until it has responded with an [`InitializeResult`](#initializeResult), with the exception that during the `initialize` request the server is allowed to send the notifications `window/showMessage`, `window/logMessage` and [`telemetry/event`](#telemetryevent) as well as the `window/showMessageRequest` request to the client. In case the client sets up a progress token in the initialize params (e.g. property `workDoneToken`) the server is also allowed to use that token (and only that token) using the [`$/progress`](#work-done-progress-begin) notification sent from the server to the client. <a id="initializeResult"></a>

The `initialize` request may only be sent once.

*Request*:

- method: ‘initialize’
- params: [`InitializeParams`](#initializeParams) defined as follows: <a id="initializeParams"></a>
```typescript
interface InitializeParams extends WorkDoneProgressParams {
	/**
	 * The process Id of the parent process that started the server. Is null if
	 * the process has not been started by another process. If the parent
	 * process is not alive then the server should exit (see exit notification)
	 * its process.
	 */
	processId: integer | null;

	/**
	 * Information about the client
	 *
	 * @since 3.15.0
	 */
	clientInfo?: {
		/**
		 * The name of the client as defined by the client.
		 */
		name: string;

		/**
		 * The client's version as defined by the client.
		 */
		version?: string;
	};

	/**
	 * The locale the client is currently showing the user interface
	 * in. This must not necessarily be the locale of the operating
	 * system.
	 *
	 * Uses IETF language tags as the value's syntax
	 * (See https://en.wikipedia.org/wiki/IETF_language_tag)
	 *
	 * @since 3.16.0
	 */
	locale?: string;

	/**
	 * The rootPath of the workspace. Is null
	 * if no folder is open.
	 *
	 * @deprecated in favour of \`rootUri\`.
	 */
	rootPath?: string | null;

	/**
	 * The rootUri of the workspace. Is null if no
	 * folder is open. If both \`rootPath\` and \`rootUri\` are set
	 * \`rootUri\` wins.
	 *
	 * @deprecated in favour of \`workspaceFolders\`
	 */
	rootUri: DocumentUri | null;

	/**
	 * User provided initialization options.
	 */
	initializationOptions?: LSPAny;

	/**
	 * The capabilities provided by the client (editor or tool)
	 */
	capabilities: ClientCapabilities;

	/**
	 * The initial trace setting. If omitted trace is disabled ('off').
	 */
	trace?: TraceValue;

	/**
	 * The workspace folders configured in the client when the server starts.
	 * This property is only available if the client supports workspace folders.
	 * It can be \`null\` if the client supports workspace folders but none are
	 * configured.
	 *
	 * @since 3.6.0
	 */
	workspaceFolders?: WorkspaceFolder[] | null;
}
```

Where [`ClientCapabilities`](#capabilities) and [`TextDocumentClientCapabilities`](#textdocumentclientcapabilities) are defined as follows:

##### TextDocumentClientCapabilities

[`TextDocumentClientCapabilities`](#textdocumentclientcapabilities) define capabilities the editor / tool provides on text documents.

```typescript
/**
 * Text document specific client capabilities.
 */
export interface TextDocumentClientCapabilities {

	synchronization?: TextDocumentSyncClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/completion\` request.
	 */
	completion?: CompletionClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/hover\` request.
	 */
	hover?: HoverClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/signatureHelp\` request.
	 */
	signatureHelp?: SignatureHelpClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/declaration\` request.
	 *
	 * @since 3.14.0
	 */
	declaration?: DeclarationClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/definition\` request.
	 */
	definition?: DefinitionClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/typeDefinition\` request.
	 *
	 * @since 3.6.0
	 */
	typeDefinition?: TypeDefinitionClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/implementation\` request.
	 *
	 * @since 3.6.0
	 */
	implementation?: ImplementationClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/references\` request.
	 */
	references?: ReferenceClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/documentHighlight\` request.
	 */
	documentHighlight?: DocumentHighlightClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/documentSymbol\` request.
	 */
	documentSymbol?: DocumentSymbolClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/codeAction\` request.
	 */
	codeAction?: CodeActionClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/codeLens\` request.
	 */
	codeLens?: CodeLensClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/documentLink\` request.
	 */
	documentLink?: DocumentLinkClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/documentColor\` and the
	 * \`textDocument/colorPresentation\` request.
	 *
	 * @since 3.6.0
	 */
	colorProvider?: DocumentColorClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/formatting\` request.
	 */
	formatting?: DocumentFormattingClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/rangeFormatting\` request.
	 */
	rangeFormatting?: DocumentRangeFormattingClientCapabilities;

	/** request.
	 * Capabilities specific to the \`textDocument/onTypeFormatting\` request.
	 */
	onTypeFormatting?: DocumentOnTypeFormattingClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/rename\` request.
	 */
	rename?: RenameClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/publishDiagnostics\`
	 * notification.
	 */
	publishDiagnostics?: PublishDiagnosticsClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/foldingRange\` request.
	 *
	 * @since 3.10.0
	 */
	foldingRange?: FoldingRangeClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/selectionRange\` request.
	 *
	 * @since 3.15.0
	 */
	selectionRange?: SelectionRangeClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/linkedEditingRange\` request.
	 *
	 * @since 3.16.0
	 */
	linkedEditingRange?: LinkedEditingRangeClientCapabilities;

	/**
	 * Capabilities specific to the various call hierarchy requests.
	 *
	 * @since 3.16.0
	 */
	callHierarchy?: CallHierarchyClientCapabilities;

	/**
	 * Capabilities specific to the various semantic token requests.
	 *
	 * @since 3.16.0
	 */
	semanticTokens?: SemanticTokensClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/moniker\` request.
	 *
	 * @since 3.16.0
	 */
	moniker?: MonikerClientCapabilities;

	/**
	 * Capabilities specific to the various type hierarchy requests.
	 *
	 * @since 3.17.0
	 */
	typeHierarchy?: TypeHierarchyClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/inlineValue\` request.
	 *
	 * @since 3.17.0
	 */
	inlineValue?: InlineValueClientCapabilities;

	/**
	 * Capabilities specific to the \`textDocument/inlayHint\` request.
	 *
	 * @since 3.17.0
	 */
	inlayHint?: InlayHintClientCapabilities;

	/**
	 * Capabilities specific to the diagnostic pull model.
	 *
	 * @since 3.17.0
	 */
	diagnostic?: DiagnosticClientCapabilities;
}
```

##### NotebookDocumentClientCapabilities

[`NotebookDocumentClientCapabilities`](#notebookdocumentclientcapabilities) define capabilities the editor / tool provides on notebook documents.

```typescript
/**
 * Capabilities specific to the notebook document support.
 *
 * @since 3.17.0
 */
export interface NotebookDocumentClientCapabilities {
	/**
	 * Capabilities specific to notebook document synchronization
	 *
	 * @since 3.17.0
	 */
	synchronization: NotebookDocumentSyncClientCapabilities;
}
```

[`ClientCapabilities`](#capabilities) define capabilities for dynamic registration, workspace and text document features the client supports. The `experimental` can be used to pass experimental capabilities under development. For future compatibility a [`ClientCapabilities`](#capabilities) object literal can have more properties set than currently defined. Servers receiving a [`ClientCapabilities`](#capabilities) object literal with unknown properties should ignore these properties. A missing property should be interpreted as an absence of the capability. If a missing property normally defines sub properties, all missing sub properties should be interpreted as an absence of the corresponding capability.

Client capabilities got introduced with version 3.0 of the protocol. They therefore only describe capabilities that got introduced in 3.x or later. Capabilities that existed in the 2.x version of the protocol are still mandatory for clients. Clients cannot opt out of providing them. So even if a client omits the `ClientCapabilities.textDocument.synchronization` it is still required that the client provides text document synchronization (e.g. open, changed and close notifications).

```typescript
interface ClientCapabilities {
	/**
	 * Workspace specific client capabilities.
	 */
	workspace?: {
		/**
		 * The client supports applying batch edits
		 * to the workspace by supporting the request
		 * 'workspace/applyEdit'
		 */
		applyEdit?: boolean;

		/**
		 * Capabilities specific to \`WorkspaceEdit\`s
		 */
		workspaceEdit?: WorkspaceEditClientCapabilities;

		/**
		 * Capabilities specific to the \`workspace/didChangeConfiguration\`
		 * notification.
		 */
		didChangeConfiguration?: DidChangeConfigurationClientCapabilities;

		/**
		 * Capabilities specific to the \`workspace/didChangeWatchedFiles\`
		 * notification.
		 */
		didChangeWatchedFiles?: DidChangeWatchedFilesClientCapabilities;

		/**
		 * Capabilities specific to the \`workspace/symbol\` request.
		 */
		symbol?: WorkspaceSymbolClientCapabilities;

		/**
		 * Capabilities specific to the \`workspace/executeCommand\` request.
		 */
		executeCommand?: ExecuteCommandClientCapabilities;

		/**
		 * The client has support for workspace folders.
		 *
		 * @since 3.6.0
		 */
		workspaceFolders?: boolean;

		/**
		 * The client supports \`workspace/configuration\` requests.
		 *
		 * @since 3.6.0
		 */
		configuration?: boolean;

		/**
		 * Capabilities specific to the semantic token requests scoped to the
		 * workspace.
		 *
		 * @since 3.16.0
		 */
		 semanticTokens?: SemanticTokensWorkspaceClientCapabilities;

		/**
		 * Capabilities specific to the code lens requests scoped to the
		 * workspace.
		 *
		 * @since 3.16.0
		 */
		codeLens?: CodeLensWorkspaceClientCapabilities;

		/**
		 * The client has support for file requests/notifications.
		 *
		 * @since 3.16.0
		 */
		fileOperations?: {
			/**
			 * Whether the client supports dynamic registration for file
			 * requests/notifications.
			 */
			dynamicRegistration?: boolean;

			/**
			 * The client has support for sending didCreateFiles notifications.
			 */
			didCreate?: boolean;

			/**
			 * The client has support for sending willCreateFiles requests.
			 */
			willCreate?: boolean;

			/**
			 * The client has support for sending didRenameFiles notifications.
			 */
			didRename?: boolean;

			/**
			 * The client has support for sending willRenameFiles requests.
			 */
			willRename?: boolean;

			/**
			 * The client has support for sending didDeleteFiles notifications.
			 */
			didDelete?: boolean;

			/**
			 * The client has support for sending willDeleteFiles requests.
			 */
			willDelete?: boolean;
		};

		/**
		 * Client workspace capabilities specific to inline values.
		 *
		 * @since 3.17.0
		 */
		inlineValue?: InlineValueWorkspaceClientCapabilities;

		/**
		 * Client workspace capabilities specific to inlay hints.
		 *
		 * @since 3.17.0
		 */
		inlayHint?: InlayHintWorkspaceClientCapabilities;

		/**
		 * Client workspace capabilities specific to diagnostics.
		 *
		 * @since 3.17.0.
		 */
		diagnostics?: DiagnosticWorkspaceClientCapabilities;
	};

	/**
	 * Text document specific client capabilities.
	 */
	textDocument?: TextDocumentClientCapabilities;

	/**
	 * Capabilities specific to the notebook document support.
	 *
	 * @since 3.17.0
	 */
	notebookDocument?: NotebookDocumentClientCapabilities;

	/**
	 * Window specific client capabilities.
	 */
	window?: {
		/**
		 * It indicates whether the client supports server initiated
		 * progress using the \`window/workDoneProgress/create\` request.
		 *
		 * The capability also controls Whether client supports handling
		 * of progress notifications. If set servers are allowed to report a
		 * \`workDoneProgress\` property in the request specific server
		 * capabilities.
		 *
		 * @since 3.15.0
		 */
		workDoneProgress?: boolean;

		/**
		 * Capabilities specific to the showMessage request
		 *
		 * @since 3.16.0
		 */
		showMessage?: ShowMessageRequestClientCapabilities;

		/**
		 * Client capabilities for the show document request.
		 *
		 * @since 3.16.0
		 */
		showDocument?: ShowDocumentClientCapabilities;
	};

	/**
	 * General client capabilities.
	 *
	 * @since 3.16.0
	 */
	general?: {
		/**
		 * Client capability that signals how the client
		 * handles stale requests (e.g. a request
		 * for which the client will not process the response
		 * anymore since the information is outdated).
		 *
		 * @since 3.17.0
		 */
		staleRequestSupport?: {
			/**
			 * The client will actively cancel the request.
			 */
			cancel: boolean;

			/**
			 * The list of requests for which the client
			 * will retry the request if it receives a
			 * response with error code \`ContentModified\`\`
			 */
			 retryOnContentModified: string[];
		}

		/**
		 * Client capabilities specific to regular expressions.
		 *
		 * @since 3.16.0
		 */
		regularExpressions?: RegularExpressionsClientCapabilities;

		/**
		 * Client capabilities specific to the client's markdown parser.
		 *
		 * @since 3.16.0
		 */
		markdown?: MarkdownClientCapabilities;

		/**
		 * The position encodings supported by the client. Client and server
		 * have to agree on the same position encoding to ensure that offsets
		 * (e.g. character position in a line) are interpreted the same on both
		 * side.
		 *
		 * To keep the protocol backwards compatible the following applies: if
		 * the value 'utf-16' is missing from the array of position encodings
		 * servers can assume that the client supports UTF-16. UTF-16 is
		 * therefore a mandatory encoding.
		 *
		 * If omitted it defaults to ['utf-16'].
		 *
		 * Implementation considerations: since the conversion from one encoding
		 * into another requires the content of the file / line the conversion
		 * is best done where the file is read which is usually on the server
		 * side.
		 *
		 * @since 3.17.0
		 */
		positionEncodings?: PositionEncodingKind[];
	};

	/**
	 * Experimental client capabilities.
	 */
	experimental?: LSPAny;
}
```

*Response*:

- result: [`InitializeResult`](#initializeResult) defined as follows: <a id="initializeResult"></a>
```typescript
interface InitializeResult {
	/**
	 * The capabilities the language server provides.
	 */
	capabilities: ServerCapabilities;

	/**
	 * Information about the server.
	 *
	 * @since 3.15.0
	 */
	serverInfo?: {
		/**
		 * The name of the server as defined by the server.
		 */
		name: string;

		/**
		 * The server's version as defined by the server.
		 */
		version?: string;
	};
}
```

- error.code:

```typescript
/**
 * Known error codes for an \`InitializeErrorCodes\`;
 */
export namespace InitializeErrorCodes {

	/**
	 * If the protocol version provided by the client can't be handled by
	 * the server.
	 *
	 * @deprecated This initialize error got replaced by client capabilities.
	 * There is no version handshake in version 3.0x
	 */
	export const unknownProtocolVersion: 1 = 1;
}

export type InitializeErrorCodes = 1;
```

- error.data:

```typescript
interface InitializeError {
	/**
	 * Indicates whether the client execute the following retry logic:
	 * (1) show the message provided by the ResponseError to the user
	 * (2) user selects retry or cancel
	 * (3) if user selected retry the initialize method is sent again.
	 */
	retry: boolean;
}
```

The server can signal the following capabilities:

```typescript
interface ServerCapabilities {

	/**
	 * The position encoding the server picked from the encodings offered
	 * by the client via the client capability \`general.positionEncodings\`.
	 *
	 * If the client didn't provide any position encodings the only valid
	 * value that a server can return is 'utf-16'.
	 *
	 * If omitted it defaults to 'utf-16'.
	 *
	 * @since 3.17.0
	 */
	positionEncoding?: PositionEncodingKind;

	/**
	 * Defines how text documents are synced. Is either a detailed structure
	 * defining each notification or for backwards compatibility the
	 * TextDocumentSyncKind number. If omitted it defaults to
	 * \`TextDocumentSyncKind.None\`.
	 */
	textDocumentSync?: TextDocumentSyncOptions | TextDocumentSyncKind;

	/**
	 * Defines how notebook documents are synced.
	 *
	 * @since 3.17.0
	 */
	notebookDocumentSync?: NotebookDocumentSyncOptions
		| NotebookDocumentSyncRegistrationOptions;

	/**
	 * The server provides completion support.
	 */
	completionProvider?: CompletionOptions;

	/**
	 * The server provides hover support.
	 */
	hoverProvider?: boolean | HoverOptions;

	/**
	 * The server provides signature help support.
	 */
	signatureHelpProvider?: SignatureHelpOptions;

	/**
	 * The server provides go to declaration support.
	 *
	 * @since 3.14.0
	 */
	declarationProvider?: boolean | DeclarationOptions
		| DeclarationRegistrationOptions;

	/**
	 * The server provides goto definition support.
	 */
	definitionProvider?: boolean | DefinitionOptions;

	/**
	 * The server provides goto type definition support.
	 *
	 * @since 3.6.0
	 */
	typeDefinitionProvider?: boolean | TypeDefinitionOptions
		| TypeDefinitionRegistrationOptions;

	/**
	 * The server provides goto implementation support.
	 *
	 * @since 3.6.0
	 */
	implementationProvider?: boolean | ImplementationOptions
		| ImplementationRegistrationOptions;

	/**
	 * The server provides find references support.
	 */
	referencesProvider?: boolean | ReferenceOptions;

	/**
	 * The server provides document highlight support.
	 */
	documentHighlightProvider?: boolean | DocumentHighlightOptions;

	/**
	 * The server provides document symbol support.
	 */
	documentSymbolProvider?: boolean | DocumentSymbolOptions;

	/**
	 * The server provides code actions. The \`CodeActionOptions\` return type is
	 * only valid if the client signals code action literal support via the
	 * property \`textDocument.codeAction.codeActionLiteralSupport\`.
	 */
	codeActionProvider?: boolean | CodeActionOptions;

	/**
	 * The server provides code lens.
	 */
	codeLensProvider?: CodeLensOptions;

	/**
	 * The server provides document link support.
	 */
	documentLinkProvider?: DocumentLinkOptions;

	/**
	 * The server provides color provider support.
	 *
	 * @since 3.6.0
	 */
	colorProvider?: boolean | DocumentColorOptions
		| DocumentColorRegistrationOptions;

	/**
	 * The server provides document formatting.
	 */
	documentFormattingProvider?: boolean | DocumentFormattingOptions;

	/**
	 * The server provides document range formatting.
	 */
	documentRangeFormattingProvider?: boolean | DocumentRangeFormattingOptions;

	/**
	 * The server provides document formatting on typing.
	 */
	documentOnTypeFormattingProvider?: DocumentOnTypeFormattingOptions;

	/**
	 * The server provides rename support. RenameOptions may only be
	 * specified if the client states that it supports
	 * \`prepareSupport\` in its initial \`initialize\` request.
	 */
	renameProvider?: boolean | RenameOptions;

	/**
	 * The server provides folding provider support.
	 *
	 * @since 3.10.0
	 */
	foldingRangeProvider?: boolean | FoldingRangeOptions
		| FoldingRangeRegistrationOptions;

	/**
	 * The server provides execute command support.
	 */
	executeCommandProvider?: ExecuteCommandOptions;

	/**
	 * The server provides selection range support.
	 *
	 * @since 3.15.0
	 */
	selectionRangeProvider?: boolean | SelectionRangeOptions
		| SelectionRangeRegistrationOptions;

	/**
	 * The server provides linked editing range support.
	 *
	 * @since 3.16.0
	 */
	linkedEditingRangeProvider?: boolean | LinkedEditingRangeOptions
		| LinkedEditingRangeRegistrationOptions;

	/**
	 * The server provides call hierarchy support.
	 *
	 * @since 3.16.0
	 */
	callHierarchyProvider?: boolean | CallHierarchyOptions
		| CallHierarchyRegistrationOptions;

	/**
	 * The server provides semantic tokens support.
	 *
	 * @since 3.16.0
	 */
	semanticTokensProvider?: SemanticTokensOptions
		| SemanticTokensRegistrationOptions;

	/**
	 * Whether server provides moniker support.
	 *
	 * @since 3.16.0
	 */
	monikerProvider?: boolean | MonikerOptions | MonikerRegistrationOptions;

	/**
	 * The server provides type hierarchy support.
	 *
	 * @since 3.17.0
	 */
	typeHierarchyProvider?: boolean | TypeHierarchyOptions
		 | TypeHierarchyRegistrationOptions;

	/**
	 * The server provides inline values.
	 *
	 * @since 3.17.0
	 */
	inlineValueProvider?: boolean | InlineValueOptions
		 | InlineValueRegistrationOptions;

	/**
	 * The server provides inlay hints.
	 *
	 * @since 3.17.0
	 */
	inlayHintProvider?: boolean | InlayHintOptions
		 | InlayHintRegistrationOptions;

	/**
	 * The server has support for pull model diagnostics.
	 *
	 * @since 3.17.0
	 */
	diagnosticProvider?: DiagnosticOptions | DiagnosticRegistrationOptions;

	/**
	 * The server provides workspace symbol support.
	 */
	workspaceSymbolProvider?: boolean | WorkspaceSymbolOptions;

	/**
	 * Workspace specific server capabilities
	 */
	workspace?: {
		/**
		 * The server supports workspace folder.
		 *
		 * @since 3.6.0
		 */
		workspaceFolders?: WorkspaceFoldersServerCapabilities;

		/**
		 * The server is interested in file notifications/requests.
		 *
		 * @since 3.16.0
		 */
		fileOperations?: {
			/**
			 * The server is interested in receiving didCreateFiles
			 * notifications.
			 */
			didCreate?: FileOperationRegistrationOptions;

			/**
			 * The server is interested in receiving willCreateFiles requests.
			 */
			willCreate?: FileOperationRegistrationOptions;

			/**
			 * The server is interested in receiving didRenameFiles
			 * notifications.
			 */
			didRename?: FileOperationRegistrationOptions;

			/**
			 * The server is interested in receiving willRenameFiles requests.
			 */
			willRename?: FileOperationRegistrationOptions;

			/**
			 * The server is interested in receiving didDeleteFiles file
			 * notifications.
			 */
			didDelete?: FileOperationRegistrationOptions;

			/**
			 * The server is interested in receiving willDeleteFiles file
			 * requests.
			 */
			willDelete?: FileOperationRegistrationOptions;
		};
	};

	/**
	 * Experimental server capabilities.
	 */
	experimental?: LSPAny;
}
```

#### Initialized Notification

The initialized notification is sent from the client to the server after the client received the result of the `initialize` request but before the client is sending any other request or notification to the server. The server can use the `initialized` notification, for example, to dynamically register capabilities. The `initialized` notification may only be sent once.

*Notification*:

- method: ‘initialized’
- params: [`InitializedParams`](#initialized-notification) defined as follows:

```typescript
interface InitializedParams {
}
```

#### Register Capability

The `client/registerCapability` request is sent from the server to the client to register for a new capability on the client side. Not all clients need to support dynamic capability registration. A client opts in via the `dynamicRegistration` property on the specific client capabilities. A client can even provide dynamic registration for capability A but not for capability B (see [`TextDocumentClientCapabilities`](#textdocumentclientcapabilities) as an example).

Server must not register the same capability both statically through the initialize result and dynamically for the same document selector. If a server wants to support both static and dynamic registration it needs to check the client capability in the initialize request and only register the capability statically if the client doesn’t support dynamic registration for that capability.

*Request*:

- method: ‘client/registerCapability’
- params: [`RegistrationParams`](#registrationParams) <a id="registrationParams"></a>

Where [`RegistrationParams`](#registrationParams) are defined as follows:

```typescript
/**
 * General parameters to register for a capability.
 */
export interface Registration {
	/**
	 * The id used to register the request. The id can be used to deregister
	 * the request again.
	 */
	id: string;

	/**
	 * The method / capability to register for.
	 */
	method: string;

	/**
	 * Options necessary for the registration.
	 */
	registerOptions?: LSPAny;
}
``` <a id="registrationParams"></a>
```typescript
export interface RegistrationParams {
	registrations: Registration[];
}
```

Since most of the registration options require to specify a document selector there is a base interface that can be used. See [`TextDocumentRegistrationOptions`](#textDocumentRegistrationOptions). <a id="textDocumentRegistrationOptions"></a>

An example JSON-RPC message to register dynamically for the [`textDocument/willSaveWaitUntil`](#willsavewaituntiltextdocument-request) feature on the client side is as follows (only details shown):

```json
{
	"method": "client/registerCapability",
	"params": {
		"registrations": [
			{
				"id": "79eee87c-c409-4664-8102-e03263673f6f",
				"method": "textDocument/willSaveWaitUntil",
				"registerOptions": {
					"documentSelector": [
						{ "language": "javascript" }
					]
				}
			}
		]
	}
}
```

This message is sent from the server to the client and after the client has successfully executed the request further [`textDocument/willSaveWaitUntil`](#willsavewaituntiltextdocument-request) requests for JavaScript text documents are sent from the client to the server.

*Response*:

- result: void.
- error: code and message set in case an exception happens during the request.

[`StaticRegistrationOptions`](#staticRegistrationOptions) can be used to register a feature in the initialize result with a given server control ID to be able to un-register the feature later on. <a id="staticRegistrationOptions"></a>
```typescript
/**
 * Static registration options to be returned in the initialize request.
 */
export interface StaticRegistrationOptions {
	/**
	 * The id used to register the request. The id can be used to deregister
	 * the request again. See also Registration#id.
	 */
	id?: string;
}
```

[`TextDocumentRegistrationOptions`](#textDocumentRegistrationOptions) can be used to dynamically register for requests for a set of text documents. <a id="textDocumentRegistrationOptions"></a>
```typescript
/**
 * General text document registration options.
 */
export interface TextDocumentRegistrationOptions {
	/**
	 * A document selector to identify the scope of the registration. If set to
	 * null the document selector provided on the client side will be used.
	 */
	documentSelector: DocumentSelector | null;
}
```

#### Unregister Capability

The `client/unregisterCapability` request is sent from the server to the client to unregister a previously registered capability.

*Request*:

- method: ‘client/unregisterCapability’
- params: [`UnregistrationParams`](#unregistrationParams) <a id="unregistrationParams"></a>

Where [`UnregistrationParams`](#unregistrationParams) are defined as follows:

```typescript
/**
 * General parameters to unregister a capability.
 */
export interface Unregistration {
	/**
	 * The id used to unregister the request or notification. Usually an id
	 * provided during the register request.
	 */
	id: string;

	/**
	 * The method / capability to unregister for.
	 */
	method: string;
}
``` <a id="unregistrationParams"></a>
```typescript
export interface UnregistrationParams {
	// This should correctly be named \`unregistrations\`. However changing this
	// is a breaking change and needs to wait until we deliver a 4.x version
	// of the specification.
	unregisterations: Unregistration[];
}
```

An example JSON-RPC message to unregister the above registered [`textDocument/willSaveWaitUntil`](#willsavewaituntiltextdocument-request) feature looks like this:

```json
{
	"method": "client/unregisterCapability",
	"params": {
		"unregisterations": [
			{
				"id": "79eee87c-c409-4664-8102-e03263673f6f",
				"method": "textDocument/willSaveWaitUntil"
			}
		]
	}
}
```

*Response*:

- result: void.
- error: code and message set in case an exception happens during the request.

#### SetTrace Notification

A notification that should be used by the client to modify the trace setting of the server.

*Notification*:

- method: ‘$/setTrace’
- params: [`SetTraceParams`](#setTrace) defined as follows: <a id="setTrace"></a>
```typescript
interface SetTraceParams {
	/**
	 * The new value that should be assigned to the trace setting.
	 */
	value: TraceValue;
}
```

#### LogTrace Notification <a id="logTrace"></a>

A notification to log the trace of the server’s execution. The amount and content of these notifications depends on the current `trace` configuration. If `trace` is `'off'`, the server should not send any `logTrace` notification. If `trace` is `'messages'`, the server should not add the `'verbose'` field in the [`LogTraceParams`](#logTrace).

`$/logTrace` should be used for systematic trace reporting. For single debugging messages, the server should send [`window/logMessage`](#windowlogMessage) notifications. <a id="windowlogMessage"></a>

*Notification*:

- method: ‘$/logTrace’
- params: [`LogTraceParams`](#logTrace) defined as follows: <a id="logTrace"></a>
```typescript
interface LogTraceParams {
	/**
	 * The message to be logged.
	 */
	message: string;
	/**
	 * Additional information that can be computed if the \`trace\` configuration
	 * is set to \`'verbose'\`
	 */
	verbose?: string;
}
```

#### Shutdown Request

The shutdown request is sent from the client to the server. It asks the server to shut down, but to not exit (otherwise the response might not be delivered correctly to the client). There is a separate exit notification that asks the server to exit. Clients must not send any notifications other than `exit` or requests to a server to which they have sent a shutdown request. Clients should also wait with sending the `exit` notification until they have received a response from the `shutdown` request.

If a server receives requests after a shutdown request those requests should error with `InvalidRequest`.

*Request*:

- method: ‘shutdown’
- params: none

*Response*:

- result: null
- error: code and message set in case an exception happens during shutdown request.

#### Exit Notification

A notification to ask the server to exit its process. The server should exit with `success` code 0 if the shutdown request has been received before; otherwise with `error` code 1.

*Notification*:

- method: ‘exit’
- params: none

### Text Document Synchronization

Client support for [`textDocument/didOpen`](#textDocumentdidOpen), [`textDocument/didChange`](#textDocumentdidChange) and [`textDocument/didClose`](#textDocumentdidClose) notifications is mandatory in the protocol and clients can not opt out supporting them. This includes both full and incremental synchronization in the [`textDocument/didChange`](#textDocumentdidChange) notification. In addition a server must either implement all three of them or none. Their capabilities are therefore controlled via a combined client and server capability. Opting out of text document synchronization makes only sense if the documents shown by the client are read only. Otherwise the server might receive request for documents, for which the content is managed in the client (e.g. they might have changed). <a id="textDocumentdidOpen"></a>

- property path (optional): `textDocument.synchronization.dynamicRegistration`
- property type: `boolean`

Controls whether text document synchronization supports dynamic registration.

- property path (optional): `textDocumentSync`
- property type: `TextDocumentSyncKind | TextDocumentSyncOptions`. The below definition of the [`TextDocumentSyncOptions`](#textDocumentSyncOptions) only covers the properties specific to the open, change and close notifications. A complete definition covering all properties can be found [here](#textDocumentdidClose): <a id="textDocumentdidClose"></a>

```typescript
/**
 * Defines how the host (editor) should sync document changes to the language
 * server.
 */
export namespace TextDocumentSyncKind {
	/**
	 * Documents should not be synced at all.
	 */
	export const None = 0;

	/**
	 * Documents are synced by always sending the full content
	 * of the document.
	 */
	export const Full = 1;

	/**
	 * Documents are synced by sending the full content on open.
	 * After that only incremental updates to the document are
	 * sent.
	 */
	export const Incremental = 2;
}

export type TextDocumentSyncKind = 0 | 1 | 2;
``` <a id="textDocumentSyncOptions"></a>
```typescript
export interface TextDocumentSyncOptions {
	/**
	 * Open and close notifications are sent to the server. If omitted open
	 * close notifications should not be sent.
	 */
	openClose?: boolean;

	/**
	 * Change notifications are sent to the server. See
	 * TextDocumentSyncKind.None, TextDocumentSyncKind.Full and
	 * TextDocumentSyncKind.Incremental. If omitted it defaults to
	 * TextDocumentSyncKind.None.
	 */
	change?: TextDocumentSyncKind;
}
```

#### DidOpenTextDocument Notification

The document open notification is sent from the client to the server to signal newly opened text documents. The document’s content is now managed by the client and the server must not try to read the document’s content using the document’s Uri. Open in this sense means it is managed by the client. It doesn’t necessarily mean that its content is presented in an editor. An open notification must not be sent more than once without a corresponding close notification send before. This means open and close notification must be balanced and the max open count for a particular textDocument is one. Note that a server’s ability to fulfill requests is independent of whether a text document is open or closed.

The [`DidOpenTextDocumentParams`](#didOpenTextDocumentParams) contain the language id the document is associated with. If the language id of a document changes, the client needs to send a [`textDocument/didClose`](#textDocumentdidClose) to the server followed by a [`textDocument/didOpen`](#textDocumentdidOpen) with the new language id if the server handles the new language id as well. <a id="textDocumentdidClose"></a>

*Client Capability*: See general synchronization [client capabilities](#text-document-synchronization).

*Server Capability*: See general synchronization [server capabilities](#text-document-synchronization).

*Registration Options*: [`TextDocumentRegistrationOptions`](#textDocumentRegistrationOptions) <a id="textDocumentRegistrationOptions"></a>

*Notification*:

- method: ‘textDocument/didOpen’
- params: [`DidOpenTextDocumentParams`](#didOpenTextDocumentParams) defined as follows: <a id="didOpenTextDocumentParams"></a> <a id="didOpenTextDocumentParams"></a>
```typescript
interface DidOpenTextDocumentParams {
	/**
	 * The document that was opened.
	 */
	textDocument: TextDocumentItem;
}
```

#### DidChangeTextDocument Notification

The document change notification is sent from the client to the server to signal changes to a text document. Before a client can change a text document it must claim ownership of its content using the [`textDocument/didOpen`](#textDocumentdidOpen) notification. In 2.0 the shape of the params has changed to include proper version numbers. <a id="textDocumentdidOpen"></a>

*Client Capability*: See general synchronization [client capabilities](#text-document-synchronization).

*Server Capability*: See general synchronization [server capabilities](#text-document-synchronization).

*Registration Options*: [`TextDocumentChangeRegistrationOptions`](#textDocumentChangeRegistrationOptions) defined as follows: <a id="textDocumentChangeRegistrationOptions"></a>
```typescript
/**
 * Describe options to be used when registering for text document change events.
 */
export interface TextDocumentChangeRegistrationOptions
	extends TextDocumentRegistrationOptions {
	/**
	 * How documents are synced to the server. See TextDocumentSyncKind.Full
	 * and TextDocumentSyncKind.Incremental.
	 */
	syncKind: TextDocumentSyncKind;
}
```

*Notification*:

- method: [`textDocument/didChange`](#textDocumentdidChange) <a id="textDocumentdidChange"></a>
- params: [`DidChangeTextDocumentParams`](#didChangeTextDocumentParams) defined as follows: <a id="didChangeTextDocumentParams"></a>
```typescript
interface DidChangeTextDocumentParams {
	/**
	 * The document that did change. The version number points
	 * to the version after all provided content changes have
	 * been applied.
	 */
	textDocument: VersionedTextDocumentIdentifier;

	/**
	 * The actual content changes. The content changes describe single state
	 * changes to the document. So if there are two content changes c1 (at
	 * array index 0) and c2 (at array index 1) for a document in state S then
	 * c1 moves the document from S to S' and c2 from S' to S''. So c1 is
	 * computed on the state S and c2 is computed on the state S'.
	 *
	 * To mirror the content of a document using change events use the following
	 * approach:
	 * - start with the same initial content
	 * - apply the 'textDocument/didChange' notifications in the order you
	 *   receive them.
	 * - apply the \`TextDocumentContentChangeEvent\`s in a single notification
	 *   in the order you receive them.
	 */
	contentChanges: TextDocumentContentChangeEvent[];
}
```

```typescript
/**
 * An event describing a change to a text document. If only a text is provided
 * it is considered to be the full content of the document.
 */
export type TextDocumentContentChangeEvent = {
	/**
	 * The range of the document that changed.
	 */
	range: Range;

	/**
	 * The optional length of the range that got replaced.
	 *
	 * @deprecated use range instead.
	 */
	rangeLength?: uinteger;

	/**
	 * The new text for the provided range.
	 */
	text: string;
} | {
	/**
	 * The new text of the whole document.
	 */
	text: string;
};
```

#### WillSaveTextDocument Notification

The document will save notification is sent from the client to the server before the document is actually saved. If a server has registered for open / close events clients should ensure that the document is open before a `willSave` notification is sent since clients can’t change the content of a file without ownership transferal.

*Client Capability*:

- property name (optional): `textDocument.synchronization.willSave`
- property type: `boolean`

The capability indicates that the client supports [`textDocument/willSave`](#willsavetextdocument-notification) notifications.

*Server Capability*:

- property name (optional): `textDocumentSync.willSave`
- property type: `boolean`

The capability indicates that the server is interested in [`textDocument/willSave`](#willsavetextdocument-notification) notifications.

*Registration Options*: [`TextDocumentRegistrationOptions`](#textDocumentRegistrationOptions) <a id="textDocumentRegistrationOptions"></a>

*Notification*:

- method: ‘textDocument/willSave’
- params: [`WillSaveTextDocumentParams`](#willSaveTextDocumentParams) defined as follows: <a id="willSaveTextDocumentParams"></a>
```typescript
/**
 * The parameters send in a will save text document notification.
 */
export interface WillSaveTextDocumentParams {
	/**
	 * The document that will be saved.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The 'TextDocumentSaveReason'.
	 */
	reason: TextDocumentSaveReason;
}
```

```typescript
/**
 * Represents reasons why a text document is saved.
 */
export namespace TextDocumentSaveReason {

	/**
	 * Manually triggered, e.g. by the user pressing save, by starting
	 * debugging, or by an API call.
	 */
	export const Manual = 1;

	/**
	 * Automatic after a delay.
	 */
	export const AfterDelay = 2;

	/**
	 * When the editor lost focus.
	 */
	export const FocusOut = 3;
}

export type TextDocumentSaveReason = 1 | 2 | 3;
```

#### WillSaveWaitUntilTextDocument Request

The document will save request is sent from the client to the server before the document is actually saved. The request can return an array of TextEdits which will be applied to the text document before it is saved. Please note that clients might drop results if computing the text edits took too long or if a server constantly fails on this request. This is done to keep the save fast and reliable. If a server has registered for open / close events clients should ensure that the document is open before a `willSaveWaitUntil` notification is sent since clients can’t change the content of a file without ownership transferal.

*Client Capability*:

- property name (optional): `textDocument.synchronization.willSaveWaitUntil`
- property type: `boolean`

The capability indicates that the client supports [`textDocument/willSaveWaitUntil`](#willsavewaituntiltextdocument-request) requests.

*Server Capability*:

- property name (optional): `textDocumentSync.willSaveWaitUntil`
- property type: `boolean`

The capability indicates that the server is interested in [`textDocument/willSaveWaitUntil`](#willsavewaituntiltextdocument-request) requests.

*Registration Options*: [`TextDocumentRegistrationOptions`](#textDocumentRegistrationOptions) <a id="textDocumentRegistrationOptions"></a>

*Request*:

- method: [`textDocument/willSaveWaitUntil`](#willsavewaituntiltextdocument-request)
- params: [`WillSaveTextDocumentParams`](#willSaveTextDocumentParams) <a id="willSaveTextDocumentParams"></a>

*Response*:

- result: [`TextEdit[]`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textEdit) | `null`
- error: code and message set in case an exception happens during the [`textDocument/willSaveWaitUntil`](#willsavewaituntiltextdocument-request) request.

#### DidSaveTextDocument Notification

The document save notification is sent from the client to the server when the document was saved in the client.

*Client Capability*:

- property name (optional): `textDocument.synchronization.didSave`
- property type: `boolean`

The capability indicates that the client supports [`textDocument/didSave`](#textDocumentdidSave) notifications. <a id="textDocumentdidSave"></a>

*Server Capability*:

- property name (optional): `textDocumentSync.save`
- property type: `boolean | SaveOptions` where [`SaveOptions`](#saveOptions) is defined as follows: <a id="saveOptions"></a>
```typescript
export interface SaveOptions {
	/**
	 * The client is supposed to include the content on save.
	 */
	includeText?: boolean;
}
```

The capability indicates that the server is interested in [`textDocument/didSave`](#textDocumentdidSave) notifications. <a id="textDocumentdidSave"></a>

*Registration Options*: [`TextDocumentSaveRegistrationOptions`](#textDocumentSaveRegistrationOptions) defined as follows: <a id="textDocumentSaveRegistrationOptions"></a>
```typescript
export interface TextDocumentSaveRegistrationOptions
	extends TextDocumentRegistrationOptions {
	/**
	 * The client is supposed to include the content on save.
	 */
	includeText?: boolean;
}
```

*Notification*:

- method: [`textDocument/didSave`](#textDocumentdidSave) <a id="textDocumentdidSave"></a>
- params: [`DidSaveTextDocumentParams`](#didSaveTextDocumentParams) defined as follows: <a id="didSaveTextDocumentParams"></a>
```typescript
interface DidSaveTextDocumentParams {
	/**
	 * The document that was saved.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * Optional the content when saved. Depends on the includeText value
	 * when the save notification was requested.
	 */
	text?: string;
}
```

#### DidCloseTextDocument Notification

The document close notification is sent from the client to the server when the document got closed in the client. The document’s master now exists where the document’s Uri points to (e.g. if the document’s Uri is a file Uri the master now exists on disk). As with the open notification the close notification is about managing the document’s content. Receiving a close notification doesn’t mean that the document was open in an editor before. A close notification requires a previous open notification to be sent. Note that a server’s ability to fulfill requests is independent of whether a text document is open or closed.

*Client Capability*: See general synchronization [client capabilities](#text-document-synchronization).

*Server Capability*: See general synchronization [server capabilities](#text-document-synchronization).

*Registration Options*: [`TextDocumentRegistrationOptions`](#textDocumentRegistrationOptions) <a id="textDocumentRegistrationOptions"></a>

*Notification*:

- method: [`textDocument/didClose`](#textDocumentdidClose) <a id="textDocumentdidClose"></a>
- params: [`DidCloseTextDocumentParams`](#didCloseTextDocumentParams) defined as follows: <a id="didCloseTextDocumentParams"></a>
```typescript
interface DidCloseTextDocumentParams {
	/**
	 * The document that was closed.
	 */
	textDocument: TextDocumentIdentifier;
}
```

#### Renaming a document

Document renames should be signaled to a server sending a document close notification with the document’s old name followed by an open notification using the document’s new name. Major reason is that besides the name other attributes can change as well like the language that is associated with the document. In addition the new document could not be of interest for the server anymore.

Servers can participate in a document rename by subscribing for the [`workspace/didRenameFiles`](#didrenamefiles-notification) notification or the [`workspace/willRenameFiles`](#willrenamefiles-request) request.

The final structure of the [`TextDocumentSyncClientCapabilities`](#capabilities) and the [`TextDocumentSyncOptions`](#textDocumentSyncOptions) server options look like this

```typescript
export interface TextDocumentSyncClientCapabilities {
	/**
	 * Whether text document synchronization supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports sending will save notifications.
	 */
	willSave?: boolean;

	/**
	 * The client supports sending a will save request and
	 * waits for a response providing text edits which will
	 * be applied to the document before it is saved.
	 */
	willSaveWaitUntil?: boolean;

	/**
	 * The client supports did save notifications.
	 */
	didSave?: boolean;
}
``` <a id="textDocumentSyncOptions"></a>
```typescript
export interface TextDocumentSyncOptions {
	/**
	 * Open and close notifications are sent to the server. If omitted open
	 * close notification should not be sent.
	 */
	openClose?: boolean;
	/**
	 * Change notifications are sent to the server. See
	 * TextDocumentSyncKind.None, TextDocumentSyncKind.Full and
	 * TextDocumentSyncKind.Incremental. If omitted it defaults to
	 * TextDocumentSyncKind.None.
	 */
	change?: TextDocumentSyncKind;
	/**
	 * If present will save notifications are sent to the server. If omitted
	 * the notification should not be sent.
	 */
	willSave?: boolean;
	/**
	 * If present will save wait until requests are sent to the server. If
	 * omitted the request should not be sent.
	 */
	willSaveWaitUntil?: boolean;
	/**
	 * If present save notifications are sent to the server. If omitted the
	 * notification should not be sent.
	 */
	save?: boolean | SaveOptions;
}
```

### Notebook Document Synchronization

Notebooks are becoming more and more popular. Adding support for them to the language server protocol allows notebook editors to reuse language smarts provided by the server inside a notebook or a notebook cell, respectively. To reuse protocol parts and therefore server implementations notebooks are modeled in the following way in LSP:

- *notebook document*: a collection of notebook cells typically stored in a file on disk. A notebook document has a type and can be uniquely identified using a resource URI.
- *notebook cell*: holds the actual text content. Cells have a kind (either code or markdown). The actual text content of the cell is stored in a text document which can be synced to the server like all other text documents. Cell text documents have an URI however servers should not rely on any format for this URI since it is up to the client on how it will create these URIs. The URIs must be unique across ALL notebook cells and can therefore be used to uniquely identify a notebook cell or the cell’s text document.

The two concepts are defined as follows:

```typescript
/**
 * A notebook document.
 *
 * @since 3.17.0
 */
export interface NotebookDocument {

	/**
	 * The notebook document's URI.
	 */
	uri: URI;

	/**
	 * The type of the notebook.
	 */
	notebookType: string;

	/**
	 * The version number of this document (it will increase after each
	 * change, including undo/redo).
	 */
	version: integer;

	/**
	 * Additional metadata stored with the notebook
	 * document.
	 */
	metadata?: LSPObject;

	/**
	 * The cells of a notebook.
	 */
	cells: NotebookCell[];
}
```

```typescript
/**
 * A notebook cell.
 *
 * A cell's document URI must be unique across ALL notebook
 * cells and can therefore be used to uniquely identify a
 * notebook cell or the cell's text document.
 *
 * @since 3.17.0
 */
export interface NotebookCell {

	/**
	 * The cell's kind
	 */
	kind: NotebookCellKind;

	/**
	 * The URI of the cell's text document
	 * content.
	 */
	document: DocumentUri;

	/**
	 * Additional metadata stored with the cell.
	 */
	metadata?: LSPObject;

	/**
	 * Additional execution summary information
	 * if supported by the client.
	 */
	executionSummary?: ExecutionSummary;
}
```

```typescript
/**
 * A notebook cell kind.
 *
 * @since 3.17.0
 */
export namespace NotebookCellKind {

	/**
	 * A markup-cell is formatted source that is used for display.
	 */
	export const Markup: 1 = 1;

	/**
	 * A code-cell is source code.
	 */
	export const Code: 2 = 2;
}
```

```typescript
export interface ExecutionSummary {
	/**
	 * A strict monotonically increasing value
	 * indicating the execution order of a cell
	 * inside a notebook.
	 */
	executionOrder: uinteger;

	/**
	 * Whether the execution was successful or
	 * not if known by the client.
	 */
	success?: boolean;
}
```

Next we describe how notebooks, notebook cells and the content of a notebook cell should be synchronized to a language server.

Syncing the text content of a cell is relatively easy since clients should model them as text documents. However since the URI of a notebook cell’s text document should be opaque, servers can not know its scheme nor its path. However what is know is the notebook document itself. We therefore introduce a special filter for notebook cell documents:

```typescript
/**
 * A notebook cell text document filter denotes a cell text
 * document by different properties.
 *
 * @since 3.17.0
 */
export interface NotebookCellTextDocumentFilter {
	/**
	 * A filter that matches against the notebook
	 * containing the notebook cell. If a string
	 * value is provided it matches against the
	 * notebook type. '*' matches every notebook.
	 */
	notebook: string | NotebookDocumentFilter;

	/**
	 * A language id like \`python\`.
	 *
	 * Will be matched against the language id of the
	 * notebook cell document. '*' matches every language.
	 */
	language?: string;
}
```

```typescript
/**
 * A notebook document filter denotes a notebook document by
 * different properties.
 *
 * @since 3.17.0
 */
export type NotebookDocumentFilter = {
	/** The type of the enclosing notebook. */
	notebookType: string;

	/** A Uri scheme, like \`file\` or \`untitled\`. */
	scheme?: string;

	/** A glob pattern. */
	pattern?: string;
} | {
	/** The type of the enclosing notebook. */
	notebookType?: string;

	/** A Uri scheme, like \`file\` or \`untitled\`.*/
	scheme: string;

	/** A glob pattern. */
	pattern?: string;
} | {
	/** The type of the enclosing notebook. */
	notebookType?: string;

	/** A Uri scheme, like \`file\` or \`untitled\`. */
	scheme?: string;

	/** A glob pattern. */
	pattern: string;
};
```

Given these structures a Python cell document in a Jupyter notebook stored on disk in a folder having `books1` in its path can be identified as follows;

```typescript
{
	notebook: {
		scheme: 'file',
		pattern '**/books1/**',
		notebookType: 'jupyter-notebook'
	},
	language: 'python'
}
```

A [`NotebookCellTextDocumentFilter`](#notebookCellTextDocumentFilter) can be used to register providers for certain requests like code complete or hover. If such a provider is registered the client will send the corresponding `textDocument/*` requests to the server using the cell text document’s URI as the document URI. <a id="notebookCellTextDocumentFilter"></a>

There are cases where simply only knowing about a cell’s text content is not enough for a server to reason about the cells content and to provide good language smarts. Sometimes it is necessary to know all cells of a notebook document including the notebook document itself. Consider a notebook that has two JavaScript cells with the following content

Cell one:

```javascript
function add(a, b) {
	return a + b;
}
```

Cell two:

Requesting code assist in cell two at the marked cursor position should propose the function `add` which is only possible if the server knows about cell one and cell two and knows that they belong to the same notebook document.

The protocol will therefore support two modes when it comes to synchronizing cell text content:

- *cellContent*: in this mode only the cell text content is synchronized to the server using the standard `textDocument/did*` notification. No notebook document and no cell structure is synchronized. This mode allows for easy adoption of notebooks since servers can reuse most of it implementation logic.
- *notebook*: in this mode the notebook document, the notebook cells and the notebook cell text content is synchronized to the server. To allow servers to create a consistent picture of a notebook document the cell text content is NOT synchronized using the standard `textDocument/did*` notifications. It is instead synchronized using special `notebookDocument/did*` notifications. This ensures that the cell and its text content arrives on the server using one open, change or close event.

To request the cell content only a normal document selector can be used. For example the selector [`{ language: 'python' }]` will synchronize Python notebook document cells to the server. However since this might synchronize unwanted documents as well a document filter can also be a `[NotebookCellTextDocumentFilter`](#notebookCellTextDocumentFilter). So `{ notebook: { scheme: 'file', notebookType: 'jupyter-notebook' }, language: 'python' }` synchronizes all Python cells in a Jupyter notebook stored on disk. <a id="notebookCellTextDocumentFilter"></a>

To synchronize the whole notebook document a server provides a `notebookDocumentSync` in its server capabilities. For example:

```typescript
{
	notebookDocumentSync: {
		notebookSelector: [
			{
				notebook: { scheme: 'file', notebookType: 'jupyter-notebook' },
				cells: [{ language: 'python' }]
			}
		]
	}
}
```

Synchronizes the notebook including all Python cells to the server if the notebook is stored on disk.

*Client Capability*:

The following client capabilities are defined for notebook documents:

- property name (optional): `notebookDocument.synchronization`
- property type: [`NotebookDocumentSyncClientCapabilities`](#capabilities) defined as follows

```typescript
/**
 * Notebook specific client capabilities.
 *
 * @since 3.17.0
 */
export interface NotebookDocumentSyncClientCapabilities {

	/**
	 * Whether implementation supports dynamic registration. If this is
	 * set to \`true\` the client supports the new
	 * \`(NotebookDocumentSyncRegistrationOptions & NotebookDocumentSyncOptions)\`
	 * return value for the corresponding server capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports sending execution summary data per cell.
	 */
	executionSummarySupport?: boolean;
}
```

*Server Capability*:

The following server capabilities are defined for notebook documents:

- property name (optional): `notebookDocumentSync`
- property type: `NotebookDocumentSyncOptions | NotebookDocumentSyncRegistrationOptions` where `NotebookDocumentOptions` is defined as follows:

```typescript
/**
 * Options specific to a notebook plus its cells
 * to be synced to the server.
 *
 * If a selector provides a notebook document
 * filter but no cell selector all cells of a
 * matching notebook document will be synced.
 *
 * If a selector provides no notebook document
 * filter but only a cell selector all notebook
 * documents that contain at least one matching
 * cell will be synced.
 *
 * @since 3.17.0
 */
export interface NotebookDocumentSyncOptions {
	/**
	 * The notebooks to be synced
	 */
	notebookSelector: ({
		/**
		 * The notebook to be synced. If a string
		 * value is provided it matches against the
		 * notebook type. '*' matches every notebook.
		 */
		notebook: string | NotebookDocumentFilter;

		/**
		 * The cells of the matching notebook to be synced.
		 */
		cells?: { language: string }[];
	} | {
		/**
		 * The notebook to be synced. If a string
		 * value is provided it matches against the
		 * notebook type. '*' matches every notebook.
		 */
		notebook?: string | NotebookDocumentFilter;

		/**
		 * The cells of the matching notebook to be synced.
		 */
		cells: { language: string }[];
	})[];

	/**
	 * Whether save notification should be forwarded to
	 * the server. Will only be honored if mode === \`notebook\`.
	 */
	save?: boolean;
}
```

*Registration Options*: `notebookDocumentSyncRegistrationOptions` defined as follows:

```typescript
/**
 * Registration options specific to a notebook.
 *
 * @since 3.17.0
 */
export interface NotebookDocumentSyncRegistrationOptions extends
	NotebookDocumentSyncOptions, StaticRegistrationOptions {
}
```

#### DidOpenNotebookDocument Notification

The open notification is sent from the client to the server when a notebook document is opened. It is only sent by a client if the server requested the synchronization mode `notebook` in its `notebookDocumentSync` capability.

*Notification*:

- method: [`notebookDocument/didOpen`](#notebookDocumentdidOpen) <a id="notebookDocumentdidOpen"></a>
- params: [`DidOpenNotebookDocumentParams`](#didOpenNotebookDocumentParams) defined as follows: <a id="didOpenNotebookDocumentParams"></a>
```typescript
/**
 * The params sent in an open notebook document notification.
 *
 * @since 3.17.0
 */
export interface DidOpenNotebookDocumentParams {

	/**
	 * The notebook document that got opened.
	 */
	notebookDocument: NotebookDocument;

	/**
	 * The text documents that represent the content
	 * of a notebook cell.
	 */
	cellTextDocuments: TextDocumentItem[];
}
```

#### DidChangeNotebookDocument Notification

The change notification is sent from the client to the server when a notebook document changes. It is only sent by a client if the server requested the synchronization mode `notebook` in its `notebookDocumentSync` capability.

*Notification*:

- method: [`notebookDocument/didChange`](#notebookDocumentdidChange) <a id="notebookDocumentdidChange"></a>
- params: [`DidChangeNotebookDocumentParams`](#didChangeNotebookDocumentParams) defined as follows: <a id="didChangeNotebookDocumentParams"></a>
```typescript
/**
 * The params sent in a change notebook document notification.
 *
 * @since 3.17.0
 */
export interface DidChangeNotebookDocumentParams {

	/**
	 * The notebook document that did change. The version number points
	 * to the version after all provided changes have been applied.
	 */
	notebookDocument: VersionedNotebookDocumentIdentifier;

	/**
	 * The actual changes to the notebook document.
	 *
	 * The change describes single state change to the notebook document.
	 * So it moves a notebook document, its cells and its cell text document
	 * contents from state S to S'.
	 *
	 * To mirror the content of a notebook using change events use the
	 * following approach:
	 * - start with the same initial content
	 * - apply the 'notebookDocument/didChange' notifications in the order
	 *   you receive them.
	 */
	change: NotebookDocumentChangeEvent;
}
```

```typescript
/**
 * A versioned notebook document identifier.
 *
 * @since 3.17.0
 */
export interface VersionedNotebookDocumentIdentifier {

	/**
	 * The version number of this notebook document.
	 */
	version: integer;

	/**
	 * The notebook document's URI.
	 */
	uri: URI;
}
```

```typescript
/**
 * A change event for a notebook document.
 *
 * @since 3.17.0
 */
export interface NotebookDocumentChangeEvent {
	/**
	 * The changed meta data if any.
	 */
	metadata?: LSPObject;

	/**
	 * Changes to cells
	 */
	cells?: {
		/**
		 * Changes to the cell structure to add or
		 * remove cells.
		 */
		structure?: {
			/**
			 * The change to the cell array.
			 */
			array: NotebookCellArrayChange;

			/**
			 * Additional opened cell text documents.
			 */
			didOpen?: TextDocumentItem[];

			/**
			 * Additional closed cell text documents.
			 */
			didClose?: TextDocumentIdentifier[];
		};

		/**
		 * Changes to notebook cells properties like its
		 * kind, execution summary or metadata.
		 */
		data?: NotebookCell[];

		/**
		 * Changes to the text content of notebook cells.
		 */
		textContent?: {
			document: VersionedTextDocumentIdentifier;
			changes: TextDocumentContentChangeEvent[];
		}[];
	};
}
```

```typescript
/**
 * A change describing how to move a \`NotebookCell\`
 * array from state S to S'.
 *
 * @since 3.17.0
 */
export interface NotebookCellArrayChange {
	/**
	 * The start offset of the cell that changed.
	 */
	start: uinteger;

	/**
	 * The deleted cells
	 */
	deleteCount: uinteger;

	/**
	 * The new cells, if any
	 */
	cells?: NotebookCell[];
}
```

#### DidSaveNotebookDocument Notification

The save notification is sent from the client to the server when a notebook document is saved. It is only sent by a client if the server requested the synchronization mode `notebook` in its `notebookDocumentSync` capability.

*Notification*:

- method: [`notebookDocument/didSave`](#notebookDocumentdidSave) <a id="notebookDocumentdidSave"></a>
- params: [`DidSaveNotebookDocumentParams`](#didSaveNotebookDocumentParams) defined as follows: <a id="didSaveNotebookDocumentParams"></a>
```typescript
/**
 * The params sent in a save notebook document notification.
 *
 * @since 3.17.0
 */
export interface DidSaveNotebookDocumentParams {
	/**
	 * The notebook document that got saved.
	 */
	notebookDocument: NotebookDocumentIdentifier;
}
```

#### DidCloseNotebookDocument Notification

The close notification is sent from the client to the server when a notebook document is closed. It is only sent by a client if the server requested the synchronization mode `notebook` in its `notebookDocumentSync` capability.

*Notification*:

- method: [`notebookDocument/didClose`](#notebookDocumentdidClose) <a id="notebookDocumentdidClose"></a>
- params: [`DidCloseNotebookDocumentParams`](#didCloseNotebookDocumentParams) defined as follows: <a id="didCloseNotebookDocumentParams"></a>
```typescript
/**
 * The params sent in a close notebook document notification.
 *
 * @since 3.17.0
 */
export interface DidCloseNotebookDocumentParams {

	/**
	 * The notebook document that got closed.
	 */
	notebookDocument: NotebookDocumentIdentifier;

	/**
	 * The text documents that represent the content
	 * of a notebook cell that got closed.
	 */
	cellTextDocuments: TextDocumentIdentifier[];
}
```

```typescript
/**
 * A literal to identify a notebook document in the client.
 *
 * @since 3.17.0
 */
export interface NotebookDocumentIdentifier {
	/**
	 * The notebook document's URI.
	 */
	uri: URI;
}
```

### Language Features

Language Features provide the actual smarts in the language server protocol. They are usually executed on a \[text document, position\] tuple. The main language feature categories are:

- code comprehension features like Hover or Goto Definition.
- coding features like diagnostics, code complete or code actions.

The language features should be computed on the [synchronized state](#text-document-synchronization) of the document.

#### Goto Declaration Request

> *Since version 3.14.0*

The go to declaration request is sent from the client to the server to resolve the declaration location of a symbol at a given text document position.

The result type [`LocationLink`](#locationlink)\[\] got introduced with version 3.14.0 and depends on the corresponding client capability `textDocument.declaration.linkSupport`.

*Client Capability*:

- property name (optional): `textDocument.declaration`
- property type: [`DeclarationClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DeclarationClientCapabilities {
	/**
	 * Whether declaration supports dynamic registration. If this is set to
	 * \`true\` the client supports the new \`DeclarationRegistrationOptions\`
	 * return value for the corresponding server capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports additional metadata in the form of declaration links.
	 */
	linkSupport?: boolean;
}
```

*Server Capability*:

- property name (optional): `declarationProvider`
- property type: `boolean | DeclarationOptions | DeclarationRegistrationOptions` where [`DeclarationOptions`](#declarationOptions) is defined as follows: <a id="declarationRegistrationOptions"></a> <a id="declarationOptions"></a>
```typescript
export interface DeclarationOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`DeclarationRegistrationOptions`](#declarationRegistrationOptions) defined as follows:

*Request*:

- method: [`textDocument/declaration`](#textDocumentdeclaration) <a id="textDocumentdeclaration"></a>
- params: [`DeclarationParams`](#declarationParams) defined as follows: <a id="declarationParams"></a>

*Response*:

- result: [`Location`](#location) | [`Location`](#location)\[\] | [`LocationLink`](#locationlink)\[\] |`null`
- partial result: [`Location`](#location)\[\] | [`LocationLink`](#locationlink)\[\]
- error: code and message set in case an exception happens during the declaration request.

#### Goto Definition Request

The go to definition request is sent from the client to the server to resolve the definition location of a symbol at a given text document position.

The result type [`LocationLink`](#locationlink)\[\] got introduced with version 3.14.0 and depends on the corresponding client capability `textDocument.definition.linkSupport`.

*Client Capability*:

- property name (optional): `textDocument.definition`
- property type: [`DefinitionClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DefinitionClientCapabilities {
	/**
	 * Whether definition supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports additional metadata in the form of definition links.
	 *
	 * @since 3.14.0
	 */
	linkSupport?: boolean;
}
```

*Server Capability*:

- property name (optional): `definitionProvider`
- property type: `boolean | DefinitionOptions` where [`DefinitionOptions`](#definitionOptions) is defined as follows: <a id="definitionOptions"></a>
```typescript
export interface DefinitionOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`DefinitionRegistrationOptions`](#definitionRegistrationOptions) defined as follows: <a id="definitionRegistrationOptions"></a>

*Request*:

- method: [`textDocument/definition`](#goto-definition-request)
- params: [`DefinitionParams`](#definitionParams) defined as follows: <a id="definitionParams"></a>

*Response*:

- result: [`Location`](#location) | [`Location`](#location)\[\] | [`LocationLink`](#locationlink)\[\] | `null`
- partial result: [`Location`](#location)\[\] | [`LocationLink`](#locationlink)\[\]
- error: code and message set in case an exception happens during the definition request.

#### Goto Type Definition Request

> *Since version 3.6.0*

The go to type definition request is sent from the client to the server to resolve the type definition location of a symbol at a given text document position.

The result type [`LocationLink`](#locationlink)\[\] got introduced with version 3.14.0 and depends on the corresponding client capability `textDocument.typeDefinition.linkSupport`.

*Client Capability*:

- property name (optional): `textDocument.typeDefinition`
- property type: [`TypeDefinitionClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface TypeDefinitionClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * \`true\` the client supports the new \`TypeDefinitionRegistrationOptions\`
	 * return value for the corresponding server capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports additional metadata in the form of definition links.
	 *
	 * @since 3.14.0
	 */
	linkSupport?: boolean;
}
```

*Server Capability*:

- property name (optional): `typeDefinitionProvider`
- property type: `boolean | TypeDefinitionOptions | TypeDefinitionRegistrationOptions` where [`TypeDefinitionOptions`](#typeDefinitionOptions) is defined as follows: <a id="typeDefinitionRegistrationOptions"></a> <a id="typeDefinitionOptions"></a>
```typescript
export interface TypeDefinitionOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`TypeDefinitionRegistrationOptions`](#typeDefinitionRegistrationOptions) defined as follows:

*Request*:

- method: [`textDocument/typeDefinition`](#goto-type-definition-request)
- params: [`TypeDefinitionParams`](#typeDefinitionParams) defined as follows: <a id="typeDefinitionParams"></a>

*Response*:

- result: [`Location`](#location) | [`Location`](#location)\[\] | [`LocationLink`](#locationlink)\[\] | `null`
- partial result: [`Location`](#location)\[\] | [`LocationLink`](#locationlink)\[\]
- error: code and message set in case an exception happens during the definition request.

#### Goto Implementation Request

> *Since version 3.6.0*

The go to implementation request is sent from the client to the server to resolve the implementation location of a symbol at a given text document position.

The result type [`LocationLink`](#locationlink)\[\] got introduced with version 3.14.0 and depends on the corresponding client capability `textDocument.implementation.linkSupport`.

*Client Capability*:

- property name (optional): `textDocument.implementation`
- property type: [`ImplementationClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface ImplementationClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * \`true\` the client supports the new \`ImplementationRegistrationOptions\`
	 * return value for the corresponding server capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports additional metadata in the form of definition links.
	 *
	 * @since 3.14.0
	 */
	linkSupport?: boolean;
}
```

*Server Capability*:

- property name (optional): `implementationProvider`
- property type: `boolean | ImplementationOptions | ImplementationRegistrationOptions` where [`ImplementationOptions`](#implementationOptions) is defined as follows: ^implementationRegistrationOptions <a id="implementationOptions"></a>
```typescript
export interface ImplementationOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`ImplementationRegistrationOptions`](#implementationRegistrationOptions) defined as follows:

*Request*:

- method: [`textDocument/implementation`](#textDocumentimplementation) <a id="textDocumentimplementation"></a>
- params: [`ImplementationParams`](#implementationParams) defined as follows: <a id="implementationParams"></a>

*Response*:

- result: [`Location`](#location) | [`Location`](#location)\[\] | [`LocationLink`](#locationlink)\[\] | `null`
- partial result: [`Location`](#location)\[\] | [`LocationLink`](#locationlink)\[\]
- error: code and message set in case an exception happens during the definition request.

#### Find References Request

The references request is sent from the client to the server to resolve project-wide references for the symbol denoted by the given text document position.

*Client Capability*:

- property name (optional): `textDocument.references`
- property type: [`ReferenceClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface ReferenceClientCapabilities {
	/**
	 * Whether references supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `referencesProvider`
- property type: `boolean | ReferenceOptions` where [`ReferenceOptions`](#referenceOptions) is defined as follows: <a id="referenceOptions"></a>
```typescript
export interface ReferenceOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`ReferenceRegistrationOptions`](#referenceRegistrationOptions) defined as follows: <a id="referenceRegistrationOptions"></a>

*Request*:

- method: [`textDocument/references`](#textDocumentreferences) <a id="textDocumentreferences"></a>
- params: [`ReferenceParams`](#referenceParams) defined as follows: <a id="referenceParams"></a>

```typescript
export interface ReferenceContext {
	/**
	 * Include the declaration of the current symbol.
	 */
	includeDeclaration: boolean;
}
```

*Response*:

- result: [`Location`](#location)\[\] | `null`
- partial result: [`Location`](#location)\[\]
- error: code and message set in case an exception happens during the reference request.

#### Prepare Call Hierarchy Request

> *Since version 3.16.0*

The call hierarchy request is sent from the client to the server to return a call hierarchy for the language element of given text document positions. The call hierarchy requests are executed in two steps:

1. first a call hierarchy item is resolved for the given text document position
2. for a call hierarchy item the incoming or outgoing call hierarchy items are resolved.

*Client Capability*:

- property name (optional): `textDocument.callHierarchy`
- property type: [`CallHierarchyClientCapabilities`](#capabilities) defined as follows:

```typescript
interface CallHierarchyClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * \`true\` the client supports the new \`(TextDocumentRegistrationOptions &
	 * StaticRegistrationOptions)\` return value for the corresponding server
	 * capability as well.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `callHierarchyProvider`
- property type: `boolean | CallHierarchyOptions | CallHierarchyRegistrationOptions` where [`CallHierarchyOptions`](#callHierarchyOptions) is defined as follows: ^callHierarchyRegistrationOptions <a id="callHierarchyOptions"></a>
```typescript
export interface CallHierarchyOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`CallHierarchyRegistrationOptions`](#callHierarchyRegistrationOptions) defined as follows:

*Request*:

- method: [`textDocument/prepareCallHierarchy`](#prepare-call-hierarchy-request)
- params: [`CallHierarchyPrepareParams`](#callHierarchyPrepareParams) defined as follows: <a id="callHierarchyPrepareParams"></a>

*Response*:

- result: `CallHierarchyItem[] | null` defined as follows:

```typescript
export interface CallHierarchyItem {
	/**
	 * The name of this item.
	 */
	name: string;

	/**
	 * The kind of this item.
	 */
	kind: SymbolKind;

	/**
	 * Tags for this item.
	 */
	tags?: SymbolTag[];

	/**
	 * More detail for this item, e.g. the signature of a function.
	 */
	detail?: string;

	/**
	 * The resource identifier of this item.
	 */
	uri: DocumentUri;

	/**
	 * The range enclosing this symbol not including leading/trailing whitespace
	 * but everything else, e.g. comments and code.
	 */
	range: Range;

	/**
	 * The range that should be selected and revealed when this symbol is being
	 * picked, e.g. the name of a function. Must be contained by the
	 * [\`range\`](#CallHierarchyItem.range).
	 */
	selectionRange: Range;

	/**
	 * A data entry field that is preserved between a call hierarchy prepare and
	 * incoming calls or outgoing calls requests.
	 */
	data?: LSPAny;
}
```

- error: code and message set in case an exception happens during the ‘textDocument/prepareCallHierarchy’ request

#### Call Hierarchy Incoming Calls

> *Since version 3.16.0*

The request is sent from the client to the server to resolve incoming calls for a given call hierarchy item. The request doesn’t define its own client and server capabilities. It is only issued if a server registers for the [`textDocument/prepareCallHierarchy`](#prepare-call-hierarchy-request) request.

*Request*:

- method: [`callHierarchy/incomingCalls`](#call-hierarchy-incoming-calls)
- params: [`CallHierarchyIncomingCallsParams`](#call-hierarchy-incoming-calls) defined as follows:

*Response*:

- result: `CallHierarchyIncomingCall[] | null` defined as follows:

```typescript
export interface CallHierarchyIncomingCall {

	/**
	 * The item that makes the call.
	 */
	from: CallHierarchyItem;

	/**
	 * The ranges at which the calls appear. This is relative to the caller
	 * denoted by [\`this.from\`](#CallHierarchyIncomingCall.from).
	 */
	fromRanges: Range[];
}
```

- partial result: `CallHierarchyIncomingCall[]`
- error: code and message set in case an exception happens during the ‘callHierarchy/incomingCalls’ request

#### Call Hierarchy Outgoing Calls

> *Since version 3.16.0*

The request is sent from the client to the server to resolve outgoing calls for a given call hierarchy item. The request doesn’t define its own client and server capabilities. It is only issued if a server registers for the [`textDocument/prepareCallHierarchy`](#prepare-call-hierarchy-request) request.

*Request*:

- method: [`callHierarchy/outgoingCalls`](#call-hierarchy-outgoing-calls)
- params: [`CallHierarchyOutgoingCallsParams`](#call-hierarchy-outgoing-calls) defined as follows:

*Response*:

- result: `CallHierarchyOutgoingCall[] | null` defined as follows:

```typescript
export interface CallHierarchyOutgoingCall {

	/**
	 * The item that is called.
	 */
	to: CallHierarchyItem;

	/**
	 * The range at which this item is called. This is the range relative to
	 * the caller, e.g the item passed to \`callHierarchy/outgoingCalls\` request.
	 */
	fromRanges: Range[];
}
```

- partial result: `CallHierarchyOutgoingCall[]`
- error: code and message set in case an exception happens during the ‘callHierarchy/outgoingCalls’ request

#### Prepare Type Hierarchy Request

> *Since version 3.17.0*

The type hierarchy request is sent from the client to the server to return a type hierarchy for the language element of given text document positions. Will return `null` if the server couldn’t infer a valid type from the position. The type hierarchy requests are executed in two steps:

1. first a type hierarchy item is prepared for the given text document position.
2. for a type hierarchy item the supertype or subtype type hierarchy items are resolved.

*Client Capability*:

- property name (optional): `textDocument.typeHierarchy`
- property type: [`TypeHierarchyClientCapabilities`](#capabilities) defined as follows:

```typescript
type TypeHierarchyClientCapabilities = {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * \`true\` the client supports the new \`(TextDocumentRegistrationOptions &
	 * StaticRegistrationOptions)\` return value for the corresponding server
	 * capability as well.
	 */
	dynamicRegistration?: boolean;
};
```

*Server Capability*:

- property name (optional): `typeHierarchyProvider`
- property type: `boolean | TypeHierarchyOptions | TypeHierarchyRegistrationOptions` where [`TypeHierarchyOptions`](#typeHierarchyOptions) is defined as follows: ^typeHierarchyRegistrationOptions <a id="typeHierarchyOptions"></a>
```typescript
export interface TypeHierarchyOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`TypeHierarchyRegistrationOptions`](#typeHierarchyRegistrationOptions) defined as follows:

*Request*:

- method: ‘textDocument/prepareTypeHierarchy’
- params: [`TypeHierarchyPrepareParams`](#typeHierarchyPrepareParams) defined as follows: <a id="typeHierarchyPrepareParams"></a>

*Response*:

- result: `TypeHierarchyItem[] | null` defined as follows:

```typescript
export interface TypeHierarchyItem {
	/**
	 * The name of this item.
	 */
	name: string;

	/**
	 * The kind of this item.
	 */
	kind: SymbolKind;

	/**
	 * Tags for this item.
	 */
	tags?: SymbolTag[];

	/**
	 * More detail for this item, e.g. the signature of a function.
	 */
	detail?: string;

	/**
	 * The resource identifier of this item.
	 */
	uri: DocumentUri;

	/**
	 * The range enclosing this symbol not including leading/trailing whitespace
	 * but everything else, e.g. comments and code.
	 */
	range: Range;

	/**
	 * The range that should be selected and revealed when this symbol is being
	 * picked, e.g. the name of a function. Must be contained by the
	 * [\`range\`](#TypeHierarchyItem.range).
	 */
	selectionRange: Range;

	/**
	 * A data entry field that is preserved between a type hierarchy prepare and
	 * supertypes or subtypes requests. It could also be used to identify the
	 * type hierarchy in the server, helping improve the performance on
	 * resolving supertypes and subtypes.
	 */
	data?: LSPAny;
}
```

- error: code and message set in case an exception happens during the ‘textDocument/prepareTypeHierarchy’ request

#### Type Hierarchy Supertypes

> *Since version 3.17.0*

The request is sent from the client to the server to resolve the supertypes for a given type hierarchy item. Will return `null` if the server couldn’t infer a valid type from `item` in the params. The request doesn’t define its own client and server capabilities. It is only issued if a server registers for the [`textDocument/prepareTypeHierarchy` request](#prepare-type-hierarchy-request).

*Request*:

- method: ‘typeHierarchy/supertypes’
- params: [`TypeHierarchySupertypesParams`](#type-hierarchy-supertypes) defined as follows:

*Response*:

- result: `TypeHierarchyItem[] | null`
- partial result: `TypeHierarchyItem[]`
- error: code and message set in case an exception happens during the ‘typeHierarchy/supertypes’ request

#### Type Hierarchy Subtypes

> *Since version 3.17.0*

The request is sent from the client to the server to resolve the subtypes for a given type hierarchy item. Will return `null` if the server couldn’t infer a valid type from `item` in the params. The request doesn’t define its own client and server capabilities. It is only issued if a server registers for the [`textDocument/prepareTypeHierarchy` request](#prepare-type-hierarchy-request).

*Request*:

- method: ‘typeHierarchy/subtypes’
- params: [`TypeHierarchySubtypesParams`](#type-hierarchy-subtypes) defined as follows:

*Response*:

- result: `TypeHierarchyItem[] | null`
- partial result: `TypeHierarchyItem[]`
- error: code and message set in case an exception happens during the ‘typeHierarchy/subtypes’ request

#### Document Highlights Request

The document highlight request is sent from the client to the server to resolve document highlights for a given text document position. For programming languages this usually highlights all references to the symbol scoped to this file. However, we kept ‘textDocument/documentHighlight’ and ‘textDocument/references’ separate requests since the first one is allowed to be more fuzzy. Symbol matches usually have a [`DocumentHighlightKind`](#documentHighlightKind) of `Read` or `Write` whereas fuzzy or textual matches use `Text` as the kind. <a id="documentHighlightKind"></a>

*Client Capability*:

- property name (optional): `textDocument.documentHighlight`
- property type: [`DocumentHighlightClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DocumentHighlightClientCapabilities {
	/**
	 * Whether document highlight supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `documentHighlightProvider`
- property type: `boolean | DocumentHighlightOptions` where [`DocumentHighlightOptions`](#documentHighlightOptions) is defined as follows: <a id="documentHighlightOptions"></a>
```typescript
export interface DocumentHighlightOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`DocumentHighlightRegistrationOptions`](#documentHighlightRegistrationOptions) defined as follows: <a id="documentHighlightRegistrationOptions"></a>

*Request*:

- method: [`textDocument/documentHighlight`](#textDocumentdocumentHighlight) <a id="textDocumentdocumentHighlight"></a>
- params: [`DocumentHighlightParams`](#documentHighlightParams) defined as follows: <a id="documentHighlightParams"></a>

*Response*:

- result: `DocumentHighlight[]` | `null` defined as follows:

```typescript
/**
 * A document highlight is a range inside a text document which deserves
 * special attention. Usually a document highlight is visualized by changing
 * the background color of its range.
 *
 */
export interface DocumentHighlight {
	/**
	 * The range this highlight applies to.
	 */
	range: Range;

	/**
	 * The highlight kind, default is DocumentHighlightKind.Text.
	 */
	kind?: DocumentHighlightKind;
}
```

```typescript
/**
 * A document highlight kind.
 */
export namespace DocumentHighlightKind {
	/**
	 * A textual occurrence.
	 */
	export const Text = 1;

	/**
	 * Read-access of a symbol, like reading a variable.
	 */
	export const Read = 2;

	/**
	 * Write-access of a symbol, like writing to a variable.
	 */
	export const Write = 3;
}

export type DocumentHighlightKind = 1 | 2 | 3;
```

- partial result: `DocumentHighlight[]`
- error: code and message set in case an exception happens during the document highlight request.

#### Document Link Request

The document links request is sent from the client to the server to request the location of links in a document.

*Client Capability*:

- property name (optional): `textDocument.documentLink`
- property type: [`DocumentLinkClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DocumentLinkClientCapabilities {
	/**
	 * Whether document link supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Whether the client supports the \`tooltip\` property on \`DocumentLink\`.
	 *
	 * @since 3.15.0
	 */
	tooltipSupport?: boolean;
}
```

*Server Capability*:

- property name (optional): `documentLinkProvider`
- property type: [`DocumentLinkOptions`](#documentLinkOptions) defined as follows: <a id="documentLinkOptions"></a>

```typescript
export interface DocumentLinkOptions extends WorkDoneProgressOptions {
	/**
	 * Document links have a resolve provider as well.
	 */
	resolveProvider?: boolean;
}
```

*Registration Options*: [`DocumentLinkRegistrationOptions`](#documentLinkRegistrationOptions) defined as follows: <a id="documentLinkRegistrationOptions"></a>

*Request*:

- method: [`textDocument/documentLink`](#document-link-request)
- params: [`DocumentLinkParams`](#documentLinkParams) defined as follows: <a id="documentLinkParams"></a>
```typescript
interface DocumentLinkParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The document to provide document links for.
	 */
	textDocument: TextDocumentIdentifier;
}
```

*Response*:

- result: `DocumentLink[]` | `null`.

```typescript
/**
 * A document link is a range in a text document that links to an internal or
 * external resource, like another text document or a web site.
 */
interface DocumentLink {
	/**
	 * The range this link applies to.
	 */
	range: Range;

	/**
	 * The uri this link points to. If missing a resolve request is sent later.
	 */
	target?: URI;

	/**
	 * The tooltip text when you hover over this link.
	 *
	 * If a tooltip is provided, is will be displayed in a string that includes
	 * instructions on how to trigger the link, such as \`{0} (ctrl + click)\`.
	 * The specific instructions vary depending on OS, user settings, and
	 * localization.
	 *
	 * @since 3.15.0
	 */
	tooltip?: string;

	/**
	 * A data entry field that is preserved on a document link between a
	 * DocumentLinkRequest and a DocumentLinkResolveRequest.
	 */
	data?: LSPAny;
}
```

- partial result: `DocumentLink[]`
- error: code and message set in case an exception happens during the document link request.

#### Document Link Resolve Request

The document link resolve request is sent from the client to the server to resolve the target of a given document link.

*Request*:

- method: [`documentLink/resolve`](#document-link-resolve-request)
- params: [`DocumentLink`](#document-link-request)

*Response*:

- result: [`DocumentLink`](#document-link-request)
- error: code and message set in case an exception happens during the document link resolve request.

#### Hover Request

The hover request is sent from the client to the server to request hover information at a given text document position.

*Client Capability*:

- property name (optional): `textDocument.hover`
- property type: [`HoverClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface HoverClientCapabilities {
	/**
	 * Whether hover supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Client supports the follow content formats if the content
	 * property refers to a \`literal of type MarkupContent\`.
	 * The order describes the preferred format of the client.
	 */
	contentFormat?: MarkupKind[];
}
```

*Server Capability*:

- property name (optional): `hoverProvider`
- property type: `boolean | HoverOptions` where [`HoverOptions`](#hoverOptions) is defined as follows: <a id="hoverOptions"></a>
```typescript
export interface HoverOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`HoverRegistrationOptions`](#hoverRegistrationOptions) defined as follows: <a id="hoverRegistrationOptions"></a>

*Request*:

- method: [`textDocument/hover`](#hover-request)
- params: [`HoverParams`](#hoverParams) defined as follows: <a id="hoverParams"></a>
```typescript
export interface HoverParams extends TextDocumentPositionParams,
	WorkDoneProgressParams {
}
```

*Response*:

- result: [`Hover`](#hover-request) | `null` defined as follows:
```typescript
/**
 * The result of a hover request.
 */
export interface Hover {
	/**
	 * The hover's content
	 */
	contents: MarkedString | MarkedString[] | MarkupContent;

	/**
	 * An optional range is a range inside a text document
	 * that is used to visualize a hover, e.g. by changing the background color.
	 */
	range?: Range;
}
```

Where [`MarkedString`](#markedString) is defined as follows: <a id="markedString"></a>

```typescript
/**
 * MarkedString can be used to render human readable text. It is either a
 * markdown string or a code-block that provides a language and a code snippet.
 * The language identifier is semantically equal to the optional language
 * identifier in fenced code blocks in GitHub issues.
 *
 * The pair of a language and a value is an equivalent to markdown:
 * \`\`\`${language}
 * ${value}
 * \`\`\`
 *
 * Note that markdown strings will be sanitized - that means html will be
 * escaped.
 *
 * @deprecated use MarkupContent instead.
 */
type MarkedString = string | { language: string; value: string };
```

- error: code and message set in case an exception happens during the hover request.

#### Code Lens Request

The code lens request is sent from the client to the server to compute code lenses for a given text document.

*Client Capability*:

- property name (optional): `textDocument.codeLens`
- property type: [`CodeLensClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface CodeLensClientCapabilities {
	/**
	 * Whether code lens supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `codeLensProvider`
- property type: [`CodeLensOptions`](#codeLensOptions) defined as follows: <a id="codeLensOptions"></a>

```typescript
export interface CodeLensOptions extends WorkDoneProgressOptions {
	/**
	 * Code lens has a resolve provider as well.
	 */
	resolveProvider?: boolean;
}
```

*Registration Options*: [`CodeLensRegistrationOptions`](#codeLensRegistrationOptions) defined as follows: <a id="codeLensRegistrationOptions"></a>

*Request*:

- method: [`textDocument/codeLens`](#code-lens-request)
- params: [`CodeLensParams`](#codeLensParams) defined as follows: <a id="codeLensParams"></a>
```typescript
interface CodeLensParams extends WorkDoneProgressParams, PartialResultParams {
	/**
	 * The document to request code lens for.
	 */
	textDocument: TextDocumentIdentifier;
}
```

*Response*:

- result: `CodeLens[]` | `null` defined as follows:

```typescript
/**
 * A code lens represents a command that should be shown along with
 * source text, like the number of references, a way to run tests, etc.
 *
 * A code lens is _unresolved_ when no command is associated to it. For
 * performance reasons the creation of a code lens and resolving should be done
 * in two stages.
 */
interface CodeLens {
	/**
	 * The range in which this code lens is valid. Should only span a single
	 * line.
	 */
	range: Range;

	/**
	 * The command this code lens represents.
	 */
	command?: Command;

	/**
	 * A data entry field that is preserved on a code lens item between
	 * a code lens and a code lens resolve request.
	 */
	data?: LSPAny;
}
```

- partial result: `CodeLens[]`
- error: code and message set in case an exception happens during the code lens request.

#### Code Lens Resolve Request

The code lens resolve request is sent from the client to the server to resolve the command for a given code lens item.

*Request*:

- method: [`codeLens/resolve`](#code-lens-resolve-request)
- params: [`CodeLens`](#code-lens-request)

*Response*:

- result: [`CodeLens`](#code-lens-request)
- error: code and message set in case an exception happens during the code lens resolve request.

#### Code Lens Refresh Request

> *Since version 3.16.0*

The [`workspace/codeLens/refresh`](#code-lens-refresh-request) request is sent from the server to the client. Servers can use it to ask clients to refresh the code lenses currently shown in editors. As a result the client should ask the server to recompute the code lenses for these editors. This is useful if a server detects a configuration change which requires a re-calculation of all code lenses. Note that the client still has the freedom to delay the re-calculation of the code lenses if for example an editor is currently not visible.

*Client Capability*:

- property name (optional): `workspace.codeLens`
- property type: [`CodeLensWorkspaceClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface CodeLensWorkspaceClientCapabilities {
	/**
	 * Whether the client implementation supports a refresh request sent from the
	 * server to the client.
	 *
	 * Note that this event is global and will force the client to refresh all
	 * code lenses currently shown. It should be used with absolute care and is
	 * useful for situation where a server for example detect a project wide
	 * change that requires such a calculation.
	 */
	refreshSupport?: boolean;
}
```

*Request*:

- method: [`workspace/codeLens/refresh`](#code-lens-refresh-request)
- params: none

*Response*:

- result: void
- error: code and message set in case an exception happens during the ‘workspace/codeLens/refresh’ request

#### Folding Range Request

> *Since version 3.10.0*

The folding range request is sent from the client to the server to return all folding ranges found in a given text document.

*Client Capability*:

- property name (optional): `textDocument.foldingRange`
- property type: [`FoldingRangeClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface FoldingRangeClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration for folding range
	 * providers. If this is set to \`true\` the client supports the new
	 * \`FoldingRangeRegistrationOptions\` return value for the corresponding
	 * server capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The maximum number of folding ranges that the client prefers to receive
	 * per document. The value serves as a hint, servers are free to follow the
	 * limit.
	 */
	rangeLimit?: uinteger;

	/**
	 * If set, the client signals that it only supports folding complete lines.
	 * If set, client will ignore specified \`startCharacter\` and \`endCharacter\`
	 * properties in a FoldingRange.
	 */
	lineFoldingOnly?: boolean;

	/**
	 * Specific options for the folding range kind.
	 *
	 * @since 3.17.0
	 */
	foldingRangeKind? : {
		/**
		 * The folding range kind values the client supports. When this
		 * property exists the client also guarantees that it will
		 * handle values outside its set gracefully and falls back
		 * to a default value when unknown.
		 */
		valueSet?: FoldingRangeKind[];
	};

	/**
	 * Specific options for the folding range.
	 * @since 3.17.0
	 */
	foldingRange?: {
		/**
		* If set, the client signals that it supports setting collapsedText on
		* folding ranges to display custom labels instead of the default text.
		*
		* @since 3.17.0
		*/
		collapsedText?: boolean;
	};
}
```

*Server Capability*:

- property name (optional): `foldingRangeProvider`
- property type: `boolean | FoldingRangeOptions | FoldingRangeRegistrationOptions` where [`FoldingRangeOptions`](#range) is defined as follows:

```typescript
export interface FoldingRangeOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`FoldingRangeRegistrationOptions`](#range) defined as follows:

*Request*:

- method: [`textDocument/foldingRange`](#folding-range-request)
- params: [`FoldingRangeParams`](#range) defined as follows

```typescript
export interface FoldingRangeParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;
}
```

*Response*:

- result: `FoldingRange[] | null` defined as follows:

```typescript
/**
 * A set of predefined range kinds.
 */
export namespace FoldingRangeKind {
	/**
	 * Folding range for a comment
	 */
	export const Comment = 'comment';

	/**
	 * Folding range for imports or includes
	 */
	export const Imports = 'imports';

	/**
	 * Folding range for a region (e.g. \`#region\`)
	 */
	export const Region = 'region';
}

/**
 * The type is a string since the value set is extensible
 */
export type FoldingRangeKind = string;
```

```typescript
/**
 * Represents a folding range. To be valid, start and end line must be bigger
 * than zero and smaller than the number of lines in the document. Clients
 * are free to ignore invalid ranges.
 */
export interface FoldingRange {

	/**
	 * The zero-based start line of the range to fold. The folded area starts
	 * after the line's last character. To be valid, the end must be zero or
	 * larger and smaller than the number of lines in the document.
	 */
	startLine: uinteger;

	/**
	 * The zero-based character offset from where the folded range starts. If
	 * not defined, defaults to the length of the start line.
	 */
	startCharacter?: uinteger;

	/**
	 * The zero-based end line of the range to fold. The folded area ends with
	 * the line's last character. To be valid, the end must be zero or larger
	 * and smaller than the number of lines in the document.
	 */
	endLine: uinteger;

	/**
	 * The zero-based character offset before the folded range ends. If not
	 * defined, defaults to the length of the end line.
	 */
	endCharacter?: uinteger;

	/**
	 * Describes the kind of the folding range such as \`comment\` or \`region\`.
	 * The kind is used to categorize folding ranges and used by commands like
	 * 'Fold all comments'. See [FoldingRangeKind](#FoldingRangeKind) for an
	 * enumeration of standardized kinds.
	 */
	kind?: FoldingRangeKind;

	/**
	 * The text that the client should show when the specified range is
	 * collapsed. If not defined or not supported by the client, a default
	 * will be chosen by the client.
	 *
	 * @since 3.17.0 - proposed
	 */
	collapsedText?: string;
}
```

- partial result: `FoldingRange[]`
- error: code and message set in case an exception happens during the ‘textDocument/foldingRange’ request

#### Selection Range Request

> *Since version 3.15.0*

The selection range request is sent from the client to the server to return suggested selection ranges at an array of given positions. A selection range is a range around the cursor position which the user might be interested in selecting.

A selection range in the return array is for the position in the provided parameters at the same index. Therefore positions\[i\] must be contained in result\[i\].range. To allow for results where some positions have selection ranges and others do not, result\[i\].range is allowed to be the empty range at positions\[i\].

Typically, but not necessary, selection ranges correspond to the nodes of the syntax tree.

*Client Capability*:

- property name (optional): `textDocument.selectionRange`
- property type: [`SelectionRangeClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface SelectionRangeClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration for selection range
	 * providers. If this is set to \`true\` the client supports the new
	 * \`SelectionRangeRegistrationOptions\` return value for the corresponding
	 * server capability as well.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `selectionRangeProvider`
- property type: `boolean | SelectionRangeOptions | SelectionRangeRegistrationOptions` where [`SelectionRangeOptions`](#range) is defined as follows:

```typescript
export interface SelectionRangeOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`SelectionRangeRegistrationOptions`](#range) defined as follows:

*Request*:

- method: [`textDocument/selectionRange`](#selection-range-request)
- params: [`SelectionRangeParams`](#range) defined as follows:

```typescript
export interface SelectionRangeParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The positions inside the text document.
	 */
	positions: Position[];
}
```

*Response*:

- result: `SelectionRange[] | null` defined as follows:

```typescript
export interface SelectionRange {
	/**
	 * The [range](#Range) of this selection range.
	 */
	range: Range;
	/**
	 * The parent selection range containing this range. Therefore
	 * \`parent.range\` must contain \`this.range\`.
	 */
	parent?: SelectionRange;
}
```

- partial result: `SelectionRange[]`
- error: code and message set in case an exception happens during the ‘textDocument/selectionRange’ request

#### Document Symbols Request

The document symbol request is sent from the client to the server. The returned result is either

- `SymbolInformation[]` which is a flat list of all symbols found in a given text document. Then neither the symbol’s location range nor the symbol’s container name should be used to infer a hierarchy.
- `DocumentSymbol[]` which is a hierarchy of symbols found in a given text document.

Servers should whenever possible return [`DocumentSymbol`](#document-symbols-request) since it is the richer data structure.

*Client Capability*:

- property name (optional): `textDocument.documentSymbol`
- property type: [`DocumentSymbolClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DocumentSymbolClientCapabilities {
	/**
	 * Whether document symbol supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Specific capabilities for the \`SymbolKind\` in the
	 * \`textDocument/documentSymbol\` request.
	 */
	symbolKind?: {
		/**
		 * The symbol kind values the client supports. When this
		 * property exists the client also guarantees that it will
		 * handle values outside its set gracefully and falls back
		 * to a default value when unknown.
		 *
		 * If this property is not present the client only supports
		 * the symbol kinds from \`File\` to \`Array\` as defined in
		 * the initial version of the protocol.
		 */
		valueSet?: SymbolKind[];
	};

	/**
	 * The client supports hierarchical document symbols.
	 */
	hierarchicalDocumentSymbolSupport?: boolean;

	/**
	 * The client supports tags on \`SymbolInformation\`. Tags are supported on
	 * \`DocumentSymbol\` if \`hierarchicalDocumentSymbolSupport\` is set to true.
	 * Clients supporting tags have to handle unknown tags gracefully.
	 *
	 * @since 3.16.0
	 */
	tagSupport?: {
		/**
		 * The tags supported by the client.
		 */
		valueSet: SymbolTag[];
	};

	/**
	 * The client supports an additional label presented in the UI when
	 * registering a document symbol provider.
	 *
	 * @since 3.16.0
	 */
	labelSupport?: boolean;
}
```

*Server Capability*:

- property name (optional): `documentSymbolProvider`
- property type: `boolean | DocumentSymbolOptions` where [`DocumentSymbolOptions`](#documentSymbolOptions) is defined as follows: <a id="documentSymbolOptions"></a>
```typescript
export interface DocumentSymbolOptions extends WorkDoneProgressOptions {
	/**
	 * A human-readable string that is shown when multiple outlines trees
	 * are shown for the same document.
	 *
	 * @since 3.16.0
	 */
	label?: string;
}
```

*Registration Options*: [`DocumentSymbolRegistrationOptions`](#documentSymbolRegistrationOptions) defined as follows: <a id="documentSymbolRegistrationOptions"></a>

*Request*:

- method: [`textDocument/documentSymbol`](#textDocumentdocumentSymbol) <a id="textDocumentdocumentSymbol"></a>
- params: [`DocumentSymbolParams`](#documentSymbolParams) defined as follows: <a id="documentSymbolParams"></a>
```typescript
export interface DocumentSymbolParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;
}
```

*Response*:

- result: `DocumentSymbol[]` | `SymbolInformation[]` | `null` defined as follows:

```typescript
/**
 * A symbol kind.
 */
export namespace SymbolKind {
	export const File = 1;
	export const Module = 2;
	export const Namespace = 3;
	export const Package = 4;
	export const Class = 5;
	export const Method = 6;
	export const Property = 7;
	export const Field = 8;
	export const Constructor = 9;
	export const Enum = 10;
	export const Interface = 11;
	export const Function = 12;
	export const Variable = 13;
	export const Constant = 14;
	export const String = 15;
	export const Number = 16;
	export const Boolean = 17;
	export const Array = 18;
	export const Object = 19;
	export const Key = 20;
	export const Null = 21;
	export const EnumMember = 22;
	export const Struct = 23;
	export const Event = 24;
	export const Operator = 25;
	export const TypeParameter = 26;
}

export type SymbolKind = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 | 24 | 25 | 26;
```

```typescript
/**
 * Symbol tags are extra annotations that tweak the rendering of a symbol.
 *
 * @since 3.16
 */
export namespace SymbolTag {

	/**
	 * Render a symbol as obsolete, usually using a strike-out.
	 */
	export const Deprecated: 1 = 1;
}

export type SymbolTag = 1;
```

```typescript
/**
 * Represents programming constructs like variables, classes, interfaces etc.
 * that appear in a document. Document symbols can be hierarchical and they
 * have two ranges: one that encloses its definition and one that points to its
 * most interesting range, e.g. the range of an identifier.
 */
export interface DocumentSymbol {

	/**
	 * The name of this symbol. Will be displayed in the user interface and
	 * therefore must not be an empty string or a string only consisting of
	 * white spaces.
	 */
	name: string;

	/**
	 * More detail for this symbol, e.g the signature of a function.
	 */
	detail?: string;

	/**
	 * The kind of this symbol.
	 */
	kind: SymbolKind;

	/**
	 * Tags for this document symbol.
	 *
	 * @since 3.16.0
	 */
	tags?: SymbolTag[];

	/**
	 * Indicates if this symbol is deprecated.
	 *
	 * @deprecated Use tags instead
	 */
	deprecated?: boolean;

	/**
	 * The range enclosing this symbol not including leading/trailing whitespace
	 * but everything else like comments. This information is typically used to
	 * determine if the clients cursor is inside the symbol to reveal in the
	 * symbol in the UI.
	 */
	range: Range;

	/**
	 * The range that should be selected and revealed when this symbol is being
	 * picked, e.g. the name of a function. Must be contained by the \`range\`.
	 */
	selectionRange: Range;

	/**
	 * Children of this symbol, e.g. properties of a class.
	 */
	children?: DocumentSymbol[];
}
```

```typescript
/**
 * Represents information about programming constructs like variables, classes,
 * interfaces etc.
 *
 * @deprecated use DocumentSymbol or WorkspaceSymbol instead.
 */
export interface SymbolInformation {
	/**
	 * The name of this symbol.
	 */
	name: string;

	/**
	 * The kind of this symbol.
	 */
	kind: SymbolKind;

	/**
	 * Tags for this symbol.
	 *
	 * @since 3.16.0
	 */
	tags?: SymbolTag[];

	/**
	 * Indicates if this symbol is deprecated.
	 *
	 * @deprecated Use tags instead
	 */
	deprecated?: boolean;

	/**
	 * The location of this symbol. The location's range is used by a tool
	 * to reveal the location in the editor. If the symbol is selected in the
	 * tool the range's start information is used to position the cursor. So
	 * the range usually spans more then the actual symbol's name and does
	 * normally include things like visibility modifiers.
	 *
	 * The range doesn't have to denote a node range in the sense of an abstract
	 * syntax tree. It can therefore not be used to re-construct a hierarchy of
	 * the symbols.
	 */
	location: Location;

	/**
	 * The name of the symbol containing this symbol. This information is for
	 * user interface purposes (e.g. to render a qualifier in the user interface
	 * if necessary). It can't be used to re-infer a hierarchy for the document
	 * symbols.
	 */
	containerName?: string;
}
```

- partial result: `DocumentSymbol[]` | `SymbolInformation[]`. `DocumentSymbol[]` and `SymbolInformation[]` can not be mixed. That means the first chunk defines the type of all the other chunks.
- error: code and message set in case an exception happens during the document symbol request.

#### Semantic Tokens

> *Since version 3.16.0*

The request is sent from the client to the server to resolve semantic tokens for a given file. Semantic tokens are used to add additional color information to a file that depends on language specific symbol information. A semantic token request usually produces a large result. The protocol therefore supports encoding tokens with numbers. In addition optional support for deltas is available.

*General Concepts*

Tokens are represented using one token type combined with n token modifiers. A token type is something like `class` or `function` and token modifiers are like `static` or `async`. The protocol defines a set of token types and modifiers but clients are allowed to extend these and announce the values they support in the corresponding client capability. The predefined values are:

```typescript
export enum SemanticTokenTypes {
	namespace = 'namespace',
	/**
	 * Represents a generic type. Acts as a fallback for types which
	 * can't be mapped to a specific type like class or enum.
	 */
	type = 'type',
	class = 'class',
	enum = 'enum',
	interface = 'interface',
	struct = 'struct',
	typeParameter = 'typeParameter',
	parameter = 'parameter',
	variable = 'variable',
	property = 'property',
	enumMember = 'enumMember',
	event = 'event',
	function = 'function',
	method = 'method',
	macro = 'macro',
	keyword = 'keyword',
	modifier = 'modifier',
	comment = 'comment',
	string = 'string',
	number = 'number',
	regexp = 'regexp',
	operator = 'operator',
	/**
	 * @since 3.17.0
	 */
	decorator = 'decorator'
}
```

```typescript
export enum SemanticTokenModifiers {
	declaration = 'declaration',
	definition = 'definition',
	readonly = 'readonly',
	static = 'static',
	deprecated = 'deprecated',
	abstract = 'abstract',
	async = 'async',
	modification = 'modification',
	documentation = 'documentation',
	defaultLibrary = 'defaultLibrary'
}
```

The protocol defines an additional token format capability to allow future extensions of the format. The only format that is currently specified is `relative` expressing that the tokens are described using relative positions (see Integer Encoding for Tokens below).

```typescript
export namespace TokenFormat {
	export const Relative: 'relative' = 'relative';
}

export type TokenFormat = 'relative';
```

*Integer Encoding for Tokens*

On the capability level types and modifiers are defined using strings. However the real encoding happens using numbers. The server therefore needs to let the client know which numbers it is using for which types and modifiers. They do so using a legend, which is defined as follows:

```typescript
export interface SemanticTokensLegend {
	/**
	 * The token types a server uses.
	 */
	tokenTypes: string[];

	/**
	 * The token modifiers a server uses.
	 */
	tokenModifiers: string[];
}
```

Token types are looked up by index, so a `tokenType` value of `1` means `tokenTypes[1]`. Since a token type can have n modifiers, multiple token modifiers can be set by using bit flags, so a `tokenModifier` value of `3` is first viewed as binary `0b00000011`, which means `[tokenModifiers[0], tokenModifiers[1]]` because bits 0 and 1 are set.

There are different ways how the position of a token can be expressed in a file. Absolute positions or relative positions. The protocol for the token format `relative` uses relative positions, because most tokens remain stable relative to each other when edits are made in a file. This simplifies the computation of a delta if a server supports it. So each token is represented using 5 integers. A specific token `i` in the file consists of the following array indices:

- at index `5*i` - `deltaLine`: token line number, relative to the start of the previous token
- at index `5*i+1` - `deltaStart`: token start character, relative to the start of the previous token (relative to 0 or the previous token’s start if they are on the same line)
- at index `5*i+2` - `length`: the length of the token.
- at index `5*i+3` - `tokenType`: will be looked up in `SemanticTokensLegend.tokenTypes`. We currently ask that `tokenType` < 65536.
- at index `5*i+4` - `tokenModifiers`: each set bit will be looked up in `SemanticTokensLegend.tokenModifiers`

The `deltaStart` and the `length` values must be encoded using the encoding the client and server agrees on during the `initialize` request (see also [TextDocuments](#text-documents)). Whether a token can span multiple lines is defined by the client capability `multilineTokenSupport`. If multiline tokens are not supported and a tokens length takes it past the end of the line, it should be treated as if the token ends at the end of the line and will not wrap onto the next line.

The client capability `overlappingTokenSupport` defines whether tokens can overlap each other.

Lets look at a concrete example which uses single line tokens without overlaps for encoding a file with 3 tokens in a number array. We start with absolute positions to demonstrate how they can easily be transformed into relative positions:

```typescript
{ line: 2, startChar:  5, length: 3, tokenType: "property",
	tokenModifiers: ["private", "static"]
},
{ line: 2, startChar: 10, length: 4, tokenType: "type", tokenModifiers: [] },
{ line: 5, startChar:  2, length: 7, tokenType: "class", tokenModifiers: [] }
```

First of all, a legend must be devised. This legend must be provided up-front on registration and capture all possible token types and modifiers. For the example we use this legend:

```typescript
{
   tokenTypes: ['property', 'type', 'class'],
   tokenModifiers: ['private', 'static']
}
```

The first transformation step is to encode `tokenType` and `tokenModifiers` as integers using the legend. As said, token types are looked up by index, so a `tokenType` value of `1` means `tokenTypes[1]`. Multiple token modifiers can be set by using bit flags, so a `tokenModifier` value of `3` is first viewed as binary `0b00000011`, which means `[tokenModifiers[0], tokenModifiers[1]]` because bits 0 and 1 are set. Using this legend, the tokens now are:

```typescript
{ line: 2, startChar:  5, length: 3, tokenType: 0, tokenModifiers: 3 },
{ line: 2, startChar: 10, length: 4, tokenType: 1, tokenModifiers: 0 },
{ line: 5, startChar:  2, length: 7, tokenType: 2, tokenModifiers: 0 }
```

The next step is to represent each token relative to the previous token in the file. In this case, the second token is on the same line as the first token, so the `startChar` of the second token is made relative to the `startChar` of the first token, so it will be `10 - 5`. The third token is on a different line than the second token, so the `startChar` of the third token will not be altered:

```typescript
{ deltaLine: 2, deltaStartChar: 5, length: 3, tokenType: 0, tokenModifiers: 3 },
{ deltaLine: 0, deltaStartChar: 5, length: 4, tokenType: 1, tokenModifiers: 0 },
{ deltaLine: 3, deltaStartChar: 2, length: 7, tokenType: 2, tokenModifiers: 0 }
```

Finally, the last step is to inline each of the 5 fields for a token in a single array, which is a memory friendly representation:

```typescript
// 1st token,  2nd token,  3rd token
[  2,5,3,0,3,  0,5,4,1,0,  3,2,7,2,0 ]
```

Now assume that the user types a new empty line at the beginning of the file which results in the following tokens in the file:

```typescript
{ line: 3, startChar:  5, length: 3, tokenType: "property",
	tokenModifiers: ["private", "static"]
},
{ line: 3, startChar: 10, length: 4, tokenType: "type", tokenModifiers: [] },
{ line: 6, startChar:  2, length: 7, tokenType: "class", tokenModifiers: [] }
```

Running the same transformations as above will result in the following number array:

```typescript
// 1st token,  2nd token,  3rd token
[  3,5,3,0,3,  0,5,4,1,0,  3,2,7,2,0]
```

The delta is now expressed on these number arrays without any form of interpretation what these numbers mean. This is comparable to the text document edits send from the server to the client to modify the content of a file. Those are character based and don’t make any assumption about the meaning of the characters. So `[  2,5,3,0,3,  0,5,4,1,0,  3,2,7,2,0 ]` can be transformed into `[  3,5,3,0,3,  0,5,4,1,0,  3,2,7,2,0]` using the following edit description: `{ start:  0, deleteCount: 1, data: [3] }` which tells the client to simply replace the first number (e.g. `2`) in the array with `3`.

Semantic token edits behave conceptually like [text edits](#textEditArray) on documents: if an edit description consists of n edits all n edits are based on the same state Sm of the number array. They will move the number array from state Sm to Sm+1. A client applying the edits must not assume that they are sorted. An easy algorithm to apply them to the number array is to sort the edits and apply them from the back to the front of the number array. <a id="textEditArray"></a>

*Client Capability*:

The following client capabilities are defined for semantic token requests sent from the client to the server:

- property name (optional): `textDocument.semanticTokens`
- property type: [`SemanticTokensClientCapabilities`](#capabilities) defined as follows:

```typescript
interface SemanticTokensClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * \`true\` the client supports the new \`(TextDocumentRegistrationOptions &
	 * StaticRegistrationOptions)\` return value for the corresponding server
	 * capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Which requests the client supports and might send to the server
	 * depending on the server's capability. Please note that clients might not
	 * show semantic tokens or degrade some of the user experience if a range
	 * or full request is advertised by the client but not provided by the
	 * server. If for example the client capability \`requests.full\` and
	 * \`request.range\` are both set to true but the server only provides a
	 * range provider the client might not render a minimap correctly or might
	 * even decide to not show any semantic tokens at all.
	 */
	requests: {
		/**
		 * The client will send the \`textDocument/semanticTokens/range\` request
		 * if the server provides a corresponding handler.
		 */
		range?: boolean | {
		};

		/**
		 * The client will send the \`textDocument/semanticTokens/full\` request
		 * if the server provides a corresponding handler.
		 */
		full?: boolean | {
			/**
			 * The client will send the \`textDocument/semanticTokens/full/delta\`
			 * request if the server provides a corresponding handler.
			 */
			delta?: boolean;
		};
	};

	/**
	 * The token types that the client supports.
	 */
	tokenTypes: string[];

	/**
	 * The token modifiers that the client supports.
	 */
	tokenModifiers: string[];

	/**
	 * The formats the clients supports.
	 */
	formats: TokenFormat[];

	/**
	 * Whether the client supports tokens that can overlap each other.
	 */
	overlappingTokenSupport?: boolean;

	/**
	 * Whether the client supports tokens that can span multiple lines.
	 */
	multilineTokenSupport?: boolean;

	/**
	 * Whether the client allows the server to actively cancel a
	 * semantic token request, e.g. supports returning
	 * ErrorCodes.ServerCancelled. If a server does the client
	 * needs to retrigger the request.
	 *
	 * @since 3.17.0
	 */
	serverCancelSupport?: boolean;

	/**
	 * Whether the client uses semantic tokens to augment existing
	 * syntax tokens. If set to \`true\` client side created syntax
	 * tokens and semantic tokens are both used for colorization. If
	 * set to \`false\` the client only uses the returned semantic tokens
	 * for colorization.
	 *
	 * If the value is \`undefined\` then the client behavior is not
	 * specified.
	 *
	 * @since 3.17.0
	 */
	augmentsSyntaxTokens?: boolean;
}
```

*Server Capability*:

The following server capabilities are defined for semantic tokens:

- property name (optional): `semanticTokensProvider`
- property type: `SemanticTokensOptions | SemanticTokensRegistrationOptions` where [`SemanticTokensOptions`](#semantic-tokens) is defined as follows:

```typescript
export interface SemanticTokensOptions extends WorkDoneProgressOptions {
	/**
	 * The legend used by the server
	 */
	legend: SemanticTokensLegend;

	/**
	 * Server supports providing semantic tokens for a specific range
	 * of a document.
	 */
	range?: boolean | {
	};

	/**
	 * Server supports providing semantic tokens for a full document.
	 */
	full?: boolean | {
		/**
		 * The server supports deltas for full documents.
		 */
		delta?: boolean;
	};
}
```

*Registration Options*: [`SemanticTokensRegistrationOptions`](#semantic-tokens) defined as follows:

Since the registration option handles range, full and delta requests the method used to register for semantic tokens requests is `textDocument/semanticTokens` and not one of the specific methods described below.

**Requesting semantic tokens for a whole file**

*Request*:

- method: [`textDocument/semanticTokens/full`](#semantic-tokens)
- params: [`SemanticTokensParams`](#semantic-tokens) defined as follows:

```typescript
export interface SemanticTokensParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;
}
```

*Response*:

- result: `SemanticTokens | null` where [`SemanticTokens`](#semantic-tokens) is defined as follows:

```typescript
export interface SemanticTokens {
	/**
	 * An optional result id. If provided and clients support delta updating
	 * the client will include the result id in the next semantic token request.
	 * A server can then instead of computing all semantic tokens again simply
	 * send a delta.
	 */
	resultId?: string;

	/**
	 * The actual tokens.
	 */
	data: uinteger[];
}
```

- partial result: [`SemanticTokensPartialResult`](#semantic-tokens) defines as follows:

```typescript
export interface SemanticTokensPartialResult {
	data: uinteger[];
}
```

- error: code and message set in case an exception happens during the ‘textDocument/semanticTokens/full’ request

**Requesting semantic token delta for a whole file**

*Request*:

- method: [`textDocument/semanticTokens/full/delta`](#semantic-tokens)
- params: [`SemanticTokensDeltaParams`](#semantic-tokens) defined as follows:

```typescript
export interface SemanticTokensDeltaParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The result id of a previous response. The result Id can either point to
	 * a full response or a delta response depending on what was received last.
	 */
	previousResultId: string;
}
```

*Response*:

- result: `SemanticTokens | SemanticTokensDelta | null` where [`SemanticTokensDelta`](#semantic-tokens) is defined as follows:

```typescript
export interface SemanticTokensDelta {
	readonly resultId?: string;
	/**
	 * The semantic token edits to transform a previous result into a new
	 * result.
	 */
	edits: SemanticTokensEdit[];
}
```

```typescript
export interface SemanticTokensEdit {
	/**
	 * The start offset of the edit.
	 */
	start: uinteger;

	/**
	 * The count of elements to remove.
	 */
	deleteCount: uinteger;

	/**
	 * The elements to insert.
	 */
	data?: uinteger[];
}
```

- partial result: [`SemanticTokensDeltaPartialResult`](#semantic-tokens) defines as follows:

```typescript
export interface SemanticTokensDeltaPartialResult {
	edits: SemanticTokensEdit[];
}
```

- error: code and message set in case an exception happens during the ‘textDocument/semanticTokens/full/delta’ request

**Requesting semantic tokens for a range**

There are two uses cases where it can be beneficial to only compute semantic tokens for a visible range:

- for faster rendering of the tokens in the user interface when a user opens a file. In this use cases servers should also implement the [`textDocument/semanticTokens/full`](#semantic-tokens) request as well to allow for flicker free scrolling and semantic coloring of a minimap.
- if computing semantic tokens for a full document is too expensive servers can only provide a range call. In this case the client might not render a minimap correctly or might even decide to not show any semantic tokens at all.

A server is allowed to compute the semantic tokens for a broader range than requested by the client. However if the server does the semantic tokens for the broader range must be complete and correct. If a token at the beginning or end only partially overlaps with the requested range the server should include those tokens in the response.

*Request*:

- method: [`textDocument/semanticTokens/range`](#range)
- params: [`SemanticTokensRangeParams`](#range) defined as follows:

```typescript
export interface SemanticTokensRangeParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The range the semantic tokens are requested for.
	 */
	range: Range;
}
```

*Response*:

- result: `SemanticTokens | null`
- partial result: [`SemanticTokensPartialResult`](#semantic-tokens)
- error: code and message set in case an exception happens during the ‘textDocument/semanticTokens/range’ request

**Requesting a refresh of all semantic tokens**

The [`workspace/semanticTokens/refresh`](#semantic-tokens) request is sent from the server to the client. Servers can use it to ask clients to refresh the editors for which this server provides semantic tokens. As a result the client should ask the server to recompute the semantic tokens for these editors. This is useful if a server detects a project wide configuration change which requires a re-calculation of all semantic tokens. Note that the client still has the freedom to delay the re-calculation of the semantic tokens if for example an editor is currently not visible.

*Client Capability*:

- property name (optional): `workspace.semanticTokens`
- property type: [`SemanticTokensWorkspaceClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface SemanticTokensWorkspaceClientCapabilities {
	/**
	 * Whether the client implementation supports a refresh request sent from
	 * the server to the client.
	 *
	 * Note that this event is global and will force the client to refresh all
	 * semantic tokens currently shown. It should be used with absolute care
	 * and is useful for situation where a server for example detect a project
	 * wide change that requires such a calculation.
	 */
	refreshSupport?: boolean;
}
```

*Request*:

- method: [`workspace/semanticTokens/refresh`](#semantic-tokens)
- params: none

*Response*:

- result: void
- error: code and message set in case an exception happens during the ‘workspace/semanticTokens/refresh’ request

#### Inlay Hint Request

> *Since version 3.17.0*

The inlay hints request is sent from the client to the server to compute inlay hints for a given \[text document, range\] tuple that may be rendered in the editor in place with other text.

*Client Capability*:

- property name (optional): `textDocument.inlayHint`
- property type: [`InlayHintClientCapabilities`](#capabilities) defined as follows:

```typescript
/**
 * Inlay hint client capabilities.
 *
 * @since 3.17.0
 */
export interface InlayHintClientCapabilities {

	/**
	 * Whether inlay hints support dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Indicates which properties a client can resolve lazily on an inlay
	 * hint.
	 */
	resolveSupport?: {

		/**
		 * The properties that a client can resolve lazily.
		 */
		properties: string[];
	};
}
```

*Server Capability*:

- property name (optional): `inlayHintProvider`
- property type: [`InlayHintOptions`](#inlayHintOptions) defined as follows: <a id="inlayHintOptions"></a>

```typescript
/**
 * Inlay hint options used during static registration.
 *
 * @since 3.17.0
 */
export interface InlayHintOptions extends WorkDoneProgressOptions {
	/**
	 * The server provides support to resolve additional
	 * information for an inlay hint item.
	 */
	resolveProvider?: boolean;
}
```

*Registration Options*: [`InlayHintRegistrationOptions`](#inlayHintRegistrationOptions) defined as follows: <a id="inlayHintRegistrationOptions"></a>
```typescript
/**
 * Inlay hint options used during static or dynamic registration.
 *
 * @since 3.17.0
 */
export interface InlayHintRegistrationOptions extends InlayHintOptions,
	TextDocumentRegistrationOptions, StaticRegistrationOptions {
}
```

*Request*:

- method: `textDocument/inlayHint`
- params: [`InlayHintParams`](#inlayHintParams) defined as follows: <a id="inlayHintParams"></a>
```typescript
/**
 * A parameter literal used in inlay hint requests.
 *
 * @since 3.17.0
 */
export interface InlayHintParams extends WorkDoneProgressParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The visible document range for which inlay hints should be computed.
	 */
	range: Range;
}
```

*Response*:

- result: `InlayHint[]` | `null` defined as follows:

```typescript
/**
 * Inlay hint information.
 *
 * @since 3.17.0
 */
export interface InlayHint {

	/**
	 * The position of this hint.
	 *
	 * If multiple hints have the same position, they will be shown in the order
	 * they appear in the response.
	 */
	position: Position;

	/**
	 * The label of this hint. A human readable string or an array of
	 * InlayHintLabelPart label parts.
	 *
	 * *Note* that neither the string nor the label part can be empty.
	 */
	label: string | InlayHintLabelPart[];

	/**
	 * The kind of this hint. Can be omitted in which case the client
	 * should fall back to a reasonable default.
	 */
	kind?: InlayHintKind;

	/**
	 * Optional text edits that are performed when accepting this inlay hint.
	 *
	 * *Note* that edits are expected to change the document so that the inlay
	 * hint (or its nearest variant) is now part of the document and the inlay
	 * hint itself is now obsolete.
	 *
	 * Depending on the client capability \`inlayHint.resolveSupport\` clients
	 * might resolve this property late using the resolve request.
	 */
	textEdits?: TextEdit[];

	/**
	 * The tooltip text when you hover over this item.
	 *
	 * Depending on the client capability \`inlayHint.resolveSupport\` clients
	 * might resolve this property late using the resolve request.
	 */
	tooltip?: string | MarkupContent;

	/**
	 * Render padding before the hint.
	 *
	 * Note: Padding should use the editor's background color, not the
	 * background color of the hint itself. That means padding can be used
	 * to visually align/separate an inlay hint.
	 */
	paddingLeft?: boolean;

	/**
	 * Render padding after the hint.
	 *
	 * Note: Padding should use the editor's background color, not the
	 * background color of the hint itself. That means padding can be used
	 * to visually align/separate an inlay hint.
	 */
	paddingRight?: boolean;

	/**
	 * A data entry field that is preserved on an inlay hint between
	 * a \`textDocument/inlayHint\` and a \`inlayHint/resolve\` request.
	 */
	data?: LSPAny;
}
```

```typescript
/**
 * An inlay hint label part allows for interactive and composite labels
 * of inlay hints.
 *
 * @since 3.17.0
 */
export interface InlayHintLabelPart {

	/**
	 * The value of this label part.
	 */
	value: string;

	/**
	 * The tooltip text when you hover over this label part. Depending on
	 * the client capability \`inlayHint.resolveSupport\` clients might resolve
	 * this property late using the resolve request.
	 */
	tooltip?: string | MarkupContent;

	/**
	 * An optional source code location that represents this
	 * label part.
	 *
	 * The editor will use this location for the hover and for code navigation
	 * features: This part will become a clickable link that resolves to the
	 * definition of the symbol at the given location (not necessarily the
	 * location itself), it shows the hover that shows at the given location,
	 * and it shows a context menu with further code navigation commands.
	 *
	 * Depending on the client capability \`inlayHint.resolveSupport\` clients
	 * might resolve this property late using the resolve request.
	 */
	location?: Location;

	/**
	 * An optional command for this label part.
	 *
	 * Depending on the client capability \`inlayHint.resolveSupport\` clients
	 * might resolve this property late using the resolve request.
	 */
	command?: Command;
}
```

```typescript
/**
 * Inlay hint kinds.
 *
 * @since 3.17.0
 */
export namespace InlayHintKind {

	/**
	 * An inlay hint that for a type annotation.
	 */
	export const Type = 1;

	/**
	 * An inlay hint that is for a parameter.
	 */
	export const Parameter = 2;
}

export type InlayHintKind = 1 | 2;
```

- error: code and message set in case an exception happens during the inlay hint request.

#### Inlay Hint Resolve Request

> *Since version 3.17.0*

The request is sent from the client to the server to resolve additional information for a given inlay hint. This is usually used to compute the `tooltip`, `location` or `command` properties of an inlay hint’s label part to avoid its unnecessary computation during the `textDocument/inlayHint` request.

Consider the clients announces the `label.location` property as a property that can be resolved lazy using the client capability

```typescript
textDocument.inlayHint.resolveSupport = { properties: ['label.location'] };
```

then an inlay hint with a label part without a location needs to be resolved using the `inlayHint/resolve` request before it can be used.

*Client Capability*:

- property name (optional): `textDocument.inlayHint.resolveSupport`
- property type: `{ properties: string[]; }`

*Request*:

- method: `inlayHint/resolve`
- params: [`InlayHint`](#inlay-hint-request)

*Response*:

- result: [`InlayHint`](#inlay-hint-request)
- error: code and message set in case an exception happens during the completion resolve request.

#### Inlay Hint Refresh Request

> *Since version 3.17.0*

The [`workspace/inlayHint/refresh`](#workspaceinlayHintrefresh) request is sent from the server to the client. Servers can use it to ask clients to refresh the inlay hints currently shown in editors. As a result the client should ask the server to recompute the inlay hints for these editors. This is useful if a server detects a configuration change which requires a re-calculation of all inlay hints. Note that the client still has the freedom to delay the re-calculation of the inlay hints if for example an editor is currently not visible. <a id="workspaceinlayHintrefresh"></a>

*Client Capability*:

- property name (optional): `workspace.inlayHint`
- property type: [`InlayHintWorkspaceClientCapabilities`](#capabilities) defined as follows:

```typescript
/**
 * Client workspace capabilities specific to inlay hints.
 *
 * @since 3.17.0
 */
export interface InlayHintWorkspaceClientCapabilities {
	/**
	 * Whether the client implementation supports a refresh request sent from
	 * the server to the client.
	 *
	 * Note that this event is global and will force the client to refresh all
	 * inlay hints currently shown. It should be used with absolute care and
	 * is useful for situation where a server for example detects a project wide
	 * change that requires such a calculation.
	 */
	refreshSupport?: boolean;
}
```

*Request*:

- method: [`workspace/inlayHint/refresh`](#workspaceinlayHintrefresh) <a id="workspaceinlayHintrefresh"></a>
- params: none

*Response*:

- result: void
- error: code and message set in case an exception happens during the ‘workspace/inlayHint/refresh’ request

#### Inline Value Request

> *Since version 3.17.0*

The inline value request is sent from the client to the server to compute inline values for a given text document that may be rendered in the editor at the end of lines.

*Client Capability*:

- property name (optional): `textDocument.inlineValue`
- property type: [`InlineValueClientCapabilities`](#capabilities) defined as follows:

```typescript
/**
 * Client capabilities specific to inline values.
 *
 * @since 3.17.0
 */
export interface InlineValueClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration for inline
	 * value providers.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `inlineValueProvider`
- property type: [`InlineValueOptions`](#inlineValueOptions) defined as follows: <a id="inlineValueOptions"></a>

```typescript
/**
 * Inline value options used during static registration.
 *
 * @since 3.17.0
 */
export interface InlineValueOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`InlineValueRegistrationOptions`](#inlineValueRegistrationOptions) defined as follows: <a id="inlineValueRegistrationOptions"></a>
```typescript
/**
 * Inline value options used during static or dynamic registration.
 *
 * @since 3.17.0
 */
export interface InlineValueRegistrationOptions extends InlineValueOptions,
	TextDocumentRegistrationOptions, StaticRegistrationOptions {
}
```

*Request*:

- method: `textDocument/inlineValue`
- params: [`InlineValueParams`](#inlineValueParams) defined as follows: <a id="inlineValueParams"></a>
```typescript
/**
 * A parameter literal used in inline value requests.
 *
 * @since 3.17.0
 */
export interface InlineValueParams extends WorkDoneProgressParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The document range for which inline values should be computed.
	 */
	range: Range;

	/**
	 * Additional information about the context in which inline values were
	 * requested.
	 */
	context: InlineValueContext;
}
```

```typescript
/**
 * @since 3.17.0
 */
export interface InlineValueContext {
	/**
	 * The stack frame (as a DAP Id) where the execution has stopped.
	 */
	frameId: integer;

	/**
	 * The document range where execution has stopped.
	 * Typically the end position of the range denotes the line where the
	 * inline values are shown.
	 */
	stoppedLocation: Range;
}
```

*Response*:

- result: `InlineValue[]` | `null` defined as follows:

```typescript
/**
 * Provide inline value as text.
 *
 * @since 3.17.0
 */
export interface InlineValueText {
	/**
	 * The document range for which the inline value applies.
	 */
	range: Range;

	/**
	 * The text of the inline value.
	 */
	text: string;
}
```

```typescript
/**
 * Provide inline value through a variable lookup.
 *
 * If only a range is specified, the variable name will be extracted from
 * the underlying document.
 *
 * An optional variable name can be used to override the extracted name.
 *
 * @since 3.17.0
 */
export interface InlineValueVariableLookup {
	/**
	 * The document range for which the inline value applies.
	 * The range is used to extract the variable name from the underlying
	 * document.
	 */
	range: Range;

	/**
	 * If specified the name of the variable to look up.
	 */
	variableName?: string;

	/**
	 * How to perform the lookup.
	 */
	caseSensitiveLookup: boolean;
}
```

```typescript
/**
 * Provide an inline value through an expression evaluation.
 *
 * If only a range is specified, the expression will be extracted from the
 * underlying document.
 *
 * An optional expression can be used to override the extracted expression.
 *
 * @since 3.17.0
 */
export interface InlineValueEvaluatableExpression {
	/**
	 * The document range for which the inline value applies.
	 * The range is used to extract the evaluatable expression from the
	 * underlying document.
	 */
	range: Range;

	/**
	 * If specified the expression overrides the extracted expression.
	 */
	expression?: string;
}
```

```typescript
/**
 * Inline value information can be provided by different means:
 * - directly as a text value (class InlineValueText).
 * - as a name to use for a variable lookup (class InlineValueVariableLookup)
 * - as an evaluatable expression (class InlineValueEvaluatableExpression)
 * The InlineValue types combines all inline value types into one type.
 *
 * @since 3.17.0
 */
export type InlineValue = InlineValueText | InlineValueVariableLookup
	| InlineValueEvaluatableExpression;
```

- error: code and message set in case an exception happens during the inline values request.

#### Inline Value Refresh Request

> *Since version 3.17.0*

The [`workspace/inlineValue/refresh`](#workspaceinlineValuerefresh) request is sent from the server to the client. Servers can use it to ask clients to refresh the inline values currently shown in editors. As a result the client should ask the server to recompute the inline values for these editors. This is useful if a server detects a configuration change which requires a re-calculation of all inline values. Note that the client still has the freedom to delay the re-calculation of the inline values if for example an editor is currently not visible. <a id="workspaceinlineValuerefresh"></a>

*Client Capability*:

- property name (optional): `workspace.inlineValue`
- property type: [`InlineValueWorkspaceClientCapabilities`](#capabilities) defined as follows:

```typescript
/**
 * Client workspace capabilities specific to inline values.
 *
 * @since 3.17.0
 */
export interface InlineValueWorkspaceClientCapabilities {
	/**
	 * Whether the client implementation supports a refresh request sent from
	 * the server to the client.
	 *
	 * Note that this event is global and will force the client to refresh all
	 * inline values currently shown. It should be used with absolute care and
	 * is useful for situation where a server for example detect a project wide
	 * change that requires such a calculation.
	 */
	refreshSupport?: boolean;
}
```

*Request*:

- method: [`workspace/inlineValue/refresh`](#workspaceinlineValuerefresh) <a id="workspaceinlineValuerefresh"></a>
- params: none

*Response*:

- result: void
- error: code and message set in case an exception happens during the ‘workspace/inlineValue/refresh’ request

#### Monikers

> *Since version 3.16.0*

Language Server Index Format (LSIF) introduced the concept of symbol monikers to help associate symbols across different indexes. This request adds capability for LSP server implementations to provide the same symbol moniker information given a text document position. Clients can utilize this method to get the moniker at the current location in a file user is editing and do further code navigation queries in other services that rely on LSIF indexes and link symbols together.

The [`textDocument/moniker`](#textDocumentmoniker) request is sent from the client to the server to get the symbol monikers for a given text document position. An array of Moniker types is returned as response to indicate possible monikers at the given location. If no monikers can be calculated, an empty array or `null` should be returned. <a id="textDocumentmoniker"></a>

*Client Capabilities*:

- property name (optional): `textDocument.moniker`
- property type: [`MonikerClientCapabilities`](#capabilities) defined as follows:

```typescript
interface MonikerClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * \`true\` the client supports the new \`(TextDocumentRegistrationOptions &
	 * StaticRegistrationOptions)\` return value for the corresponding server
	 * capability as well.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `monikerProvider`
- property type: `boolean | MonikerOptions | MonikerRegistrationOptions` is defined as follows: <a id="monikerRegistrationOptions"></a>

```typescript
export interface MonikerOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`MonikerRegistrationOptions`](#monikerRegistrationOptions) defined as follows:

*Request*:

- method: [`textDocument/moniker`](#textDocumentmoniker) <a id="textDocumentmoniker"></a>
- params: [`MonikerParams`](#monikerParams) defined as follows: <a id="monikerParams"></a>

*Response*:

- result: `Moniker[] | null`
- partial result: `Moniker[]`
- error: code and message set in case an exception happens during the ‘textDocument/moniker’ request

[`Moniker`](#monikers) is defined as follows:

```typescript
/**
 * Moniker uniqueness level to define scope of the moniker.
 */
export enum UniquenessLevel {
	/**
	 * The moniker is only unique inside a document
	 */
	document = 'document',

	/**
	 * The moniker is unique inside a project for which a dump got created
	 */
	project = 'project',

	/**
	 * The moniker is unique inside the group to which a project belongs
	 */
	group = 'group',

	/**
	 * The moniker is unique inside the moniker scheme.
	 */
	scheme = 'scheme',

	/**
	 * The moniker is globally unique
	 */
	global = 'global'
}
```

```typescript
/**
 * The moniker kind.
 */
export enum MonikerKind {
	/**
	 * The moniker represent a symbol that is imported into a project
	 */
	import = 'import',

	/**
	 * The moniker represents a symbol that is exported from a project
	 */
	export = 'export',

	/**
	 * The moniker represents a symbol that is local to a project (e.g. a local
	 * variable of a function, a class not visible outside the project, ...)
	 */
	local = 'local'
}
```

```typescript
/**
 * Moniker definition to match LSIF 0.5 moniker definition.
 */
export interface Moniker {
	/**
	 * The scheme of the moniker. For example tsc or .Net
	 */
	scheme: string;

	/**
	 * The identifier of the moniker. The value is opaque in LSIF however
	 * schema owners are allowed to define the structure if they want.
	 */
	identifier: string;

	/**
	 * The scope in which the moniker is unique
	 */
	unique: UniquenessLevel;

	/**
	 * The moniker kind if known.
	 */
	kind?: MonikerKind;
}
```

##### Notes

Server implementations of this method should ensure that the moniker calculation matches to those used in the corresponding LSIF implementation to ensure symbols can be associated correctly across IDE sessions and LSIF indexes.

#### Completion Request

The Completion request is sent from the client to the server to compute completion items at a given cursor position. Completion items are presented in the [IntelliSense](https://code.visualstudio.com/docs/editor/intellisense) user interface. If computing full completion items is expensive, servers can additionally provide a handler for the completion item resolve request (‘completionItem/resolve’). This request is sent when a completion item is selected in the user interface. A typical use case is for example: the [`textDocument/completion`](#completion-request) request doesn’t fill in the `documentation` property for returned completion items since it is expensive to compute. When the item is selected in the user interface then a ‘completionItem/resolve’ request is sent with the selected completion item as a parameter. The returned completion item should have the documentation property filled in. By default the request can only delay the computation of the `detail` and `documentation` properties. Since 3.16.0 the client can signal that it can resolve more properties lazily. This is done using the `completionItem#resolveSupport` client capability which lists all properties that can be filled in during a ‘completionItem/resolve’ request. All other properties (usually `sortText`, `filterText`, `insertText` and `textEdit`) must be provided in the [`textDocument/completion`](#completion-request) response and must not be changed during resolve.

The language server protocol uses the following model around completions:

- to achieve consistency across languages and to honor different clients usually the client is responsible for filtering and sorting. This has also the advantage that client can experiment with different filter and sorting models. However servers can enforce different behavior by setting a `filterText` / `sortText`
- for speed clients should be able to filter an already received completion list if the user continues typing. Servers can opt out of this using a [`CompletionList`](#completionList) and mark it as `isIncomplete`. <a id="completionList"></a>

A completion item provides additional means to influence filtering and sorting. They are expressed by either creating a [`CompletionItem`](#completion-item-resolve-request) with a `insertText` or with a `textEdit`. The two modes differ as follows:

- **Completion item provides an insertText / label without a text edit**: in the model the client should filter against what the user has already typed using the word boundary rules of the language (e.g. resolving the word under the cursor position). The reason for this mode is that it makes it extremely easy for a server to implement a basic completion list and get it filtered on the client.
- **Completion Item with text edits**: in this mode the server tells the client that it actually knows what it is doing. If you create a completion item with a text edit at the current cursor position no word guessing takes place and no automatic filtering (like with an `insertText`) should happen. This mode can be combined with a sort text and filter text to customize two things. If the text edit is a replace edit then the range denotes the word used for filtering. If the replace changes the text it most likely makes sense to specify a filter text to be used.

*Client Capability*:

- property name (optional): `textDocument.completion`
- property type: [`CompletionClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface CompletionClientCapabilities {
	/**
	 * Whether completion supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports the following \`CompletionItem\` specific
	 * capabilities.
	 */
	completionItem?: {
		/**
		 * Client supports snippets as insert text.
		 *
		 * A snippet can define tab stops and placeholders with \`$1\`, \`$2\`
		 * and \`${3:foo}\`. \`$0\` defines the final tab stop, it defaults to
		 * the end of the snippet. Placeholders with equal identifiers are
		 * linked, that is typing in one will update others too.
		 */
		snippetSupport?: boolean;

		/**
		 * Client supports commit characters on a completion item.
		 */
		commitCharactersSupport?: boolean;

		/**
		 * Client supports the follow content formats for the documentation
		 * property. The order describes the preferred format of the client.
		 */
		documentationFormat?: MarkupKind[];

		/**
		 * Client supports the deprecated property on a completion item.
		 */
		deprecatedSupport?: boolean;

		/**
		 * Client supports the preselect property on a completion item.
		 */
		preselectSupport?: boolean;

		/**
		 * Client supports the tag property on a completion item. Clients
		 * supporting tags have to handle unknown tags gracefully. Clients
		 * especially need to preserve unknown tags when sending a completion
		 * item back to the server in a resolve call.
		 *
		 * @since 3.15.0
		 */
		tagSupport?: {
			/**
			 * The tags supported by the client.
			 */
			valueSet: CompletionItemTag[];
		};

		/**
		 * Client supports insert replace edit to control different behavior if
		 * a completion item is inserted in the text or should replace text.
		 *
		 * @since 3.16.0
		 */
		insertReplaceSupport?: boolean;

		/**
		 * Indicates which properties a client can resolve lazily on a
		 * completion item. Before version 3.16.0 only the predefined properties
		 * \`documentation\` and \`detail\` could be resolved lazily.
		 *
		 * @since 3.16.0
		 */
		resolveSupport?: {
			/**
			 * The properties that a client can resolve lazily.
			 */
			properties: string[];
		};

		/**
		 * The client supports the \`insertTextMode\` property on
		 * a completion item to override the whitespace handling mode
		 * as defined by the client (see \`insertTextMode\`).
		 *
		 * @since 3.16.0
		 */
		insertTextModeSupport?: {
			valueSet: InsertTextMode[];
		};

		/**
		 * The client has support for completion item label
		 * details (see also \`CompletionItemLabelDetails\`).
		 *
		 * @since 3.17.0
		 */
		labelDetailsSupport?: boolean;
	};

	completionItemKind?: {
		/**
		 * The completion item kind values the client supports. When this
		 * property exists the client also guarantees that it will
		 * handle values outside its set gracefully and falls back
		 * to a default value when unknown.
		 *
		 * If this property is not present the client only supports
		 * the completion items kinds from \`Text\` to \`Reference\` as defined in
		 * the initial version of the protocol.
		 */
		valueSet?: CompletionItemKind[];
	};

	/**
	 * The client supports to send additional context information for a
	 * \`textDocument/completion\` request.
	 */
	contextSupport?: boolean;

	/**
	 * The client's default when the completion item doesn't provide a
	 * \`insertTextMode\` property.
	 *
	 * @since 3.17.0
	 */
	insertTextMode?: InsertTextMode;

	/**
	 * The client supports the following \`CompletionList\` specific
	 * capabilities.
	 *
	 * @since 3.17.0
	 */
	completionList?: {
		/**
		 * The client supports the following itemDefaults on
		 * a completion list.
		 *
		 * The value lists the supported property names of the
		 * \`CompletionList.itemDefaults\` object. If omitted
		 * no properties are supported.
		 *
		 * @since 3.17.0
		 */
		itemDefaults?: string[];
	}
}
```

*Server Capability*:

- property name (optional): `completionProvider`
- property type: [`CompletionOptions`](#completionOptions) defined as follows: <a id="completionOptions"></a>

```typescript
/**
 * Completion options.
 */
export interface CompletionOptions extends WorkDoneProgressOptions {
	/**
	 * The additional characters, beyond the defaults provided by the client (typically
	 * [a-zA-Z]), that should automatically trigger a completion request. For example
	 * \`.\` in JavaScript represents the beginning of an object property or method and is
	 * thus a good candidate for triggering a completion request.
	 *
	 * Most tools trigger a completion request automatically without explicitly
	 * requesting it using a keyboard shortcut (e.g. Ctrl+Space). Typically they
	 * do so when the user starts to type an identifier. For example if the user
	 * types \`c\` in a JavaScript file code complete will automatically pop up
	 * present \`console\` besides others as a completion item. Characters that
	 * make up identifiers don't need to be listed here.
	 */
	triggerCharacters?: string[];

	/**
	 * The list of all possible characters that commit a completion. This field
	 * can be used if clients don't support individual commit characters per
	 * completion item. See client capability
	 * \`completion.completionItem.commitCharactersSupport\`.
	 *
	 * If a server provides both \`allCommitCharacters\` and commit characters on
	 * an individual completion item the ones on the completion item win.
	 *
	 * @since 3.2.0
	 */
	allCommitCharacters?: string[];

	/**
	 * The server provides support to resolve additional
	 * information for a completion item.
	 */
	resolveProvider?: boolean;

	/**
	 * The server supports the following \`CompletionItem\` specific
	 * capabilities.
	 *
	 * @since 3.17.0
	 */
	completionItem?: {
		/**
		 * The server has support for completion item label
		 * details (see also \`CompletionItemLabelDetails\`) when receiving
		 * a completion item in a resolve call.
		 *
		 * @since 3.17.0
		 */
		labelDetailsSupport?: boolean;
	}
}
```

*Registration Options*: [`CompletionRegistrationOptions`](#completionRegistrationOptions) options defined as follows: <a id="completionRegistrationOptions"></a>

*Request*:

- method: [`textDocument/completion`](#completion-request)
- params: [`CompletionParams`](#completionParams) defined as follows: <a id="completionParams"></a>
```typescript
export interface CompletionParams extends TextDocumentPositionParams,
	WorkDoneProgressParams, PartialResultParams {
	/**
	 * The completion context. This is only available if the client specifies
	 * to send this using the client capability
	 * \`completion.contextSupport === true\`
	 */
	context?: CompletionContext;
}
```

```typescript
/**
 * How a completion was triggered
 */
export namespace CompletionTriggerKind {
	/**
	 * Completion was triggered by typing an identifier (24x7 code
	 * complete), manual invocation (e.g Ctrl+Space) or via API.
	 */
	export const Invoked: 1 = 1;

	/**
	 * Completion was triggered by a trigger character specified by
	 * the \`triggerCharacters\` properties of the
	 * \`CompletionRegistrationOptions\`.
	 */
	export const TriggerCharacter: 2 = 2;

	/**
	 * Completion was re-triggered as the current completion list is incomplete.
	 */
	export const TriggerForIncompleteCompletions: 3 = 3;
}
export type CompletionTriggerKind = 1 | 2 | 3;
```

```typescript
/**
 * Contains additional information about the context in which a completion
 * request is triggered.
 */
export interface CompletionContext {
	/**
	 * How the completion was triggered.
	 */
	triggerKind: CompletionTriggerKind;

	/**
	 * The trigger character (a single character) that has trigger code
	 * complete. Is undefined if
	 * \`triggerKind !== CompletionTriggerKind.TriggerCharacter\`
	 */
	triggerCharacter?: string;
}
```

*Response*:

- result: `CompletionItem[]` | [`CompletionList`](#completionList) | `null`. If a `CompletionItem[]` is provided it is interpreted to be complete. So it is the same as `{ isIncomplete: false, items }` <a id="completionList"></a>
```typescript
/**
 * Represents a collection of [completion items](#CompletionItem) to be
 * presented in the editor.
 */
export interface CompletionList {
	/**
	 * This list is not complete. Further typing should result in recomputing
	 * this list.
	 *
	 * Recomputed lists have all their items replaced (not appended) in the
	 * incomplete completion sessions.
	 */
	isIncomplete: boolean;

	/**
	 * In many cases the items of an actual completion result share the same
	 * value for properties like \`commitCharacters\` or the range of a text
	 * edit. A completion list can therefore define item defaults which will
	 * be used if a completion item itself doesn't specify the value.
	 *
	 * If a completion list specifies a default value and a completion item
	 * also specifies a corresponding value the one from the item is used.
	 *
	 * Servers are only allowed to return default values if the client
	 * signals support for this via the \`completionList.itemDefaults\`
	 * capability.
	 *
	 * @since 3.17.0
	 */
	itemDefaults?: {
		/**
		 * A default commit character set.
		 *
		 * @since 3.17.0
		 */
		commitCharacters?: string[];

		/**
		 * A default edit range
		 *
		 * @since 3.17.0
		 */
		editRange?: Range | {
			insert: Range;
			replace: Range;
		};

		/**
		 * A default insert text format
		 *
		 * @since 3.17.0
		 */
		insertTextFormat?: InsertTextFormat;

		/**
		 * A default insert text mode
		 *
		 * @since 3.17.0
		 */
		insertTextMode?: InsertTextMode;

		/**
		 * A default data value.
		 *
		 * @since 3.17.0
		 */
		data?: LSPAny;
	}

	/**
	 * The completion items.
	 */
	items: CompletionItem[];
}
```

```typescript
/**
 * Defines whether the insert text in a completion item should be interpreted as
 * plain text or a snippet.
 */
export namespace InsertTextFormat {
	/**
	 * The primary text to be inserted is treated as a plain string.
	 */
	export const PlainText = 1;

	/**
	 * The primary text to be inserted is treated as a snippet.
	 *
	 * A snippet can define tab stops and placeholders with \`$1\`, \`$2\`
	 * and \`${3:foo}\`. \`$0\` defines the final tab stop, it defaults to
	 * the end of the snippet. Placeholders with equal identifiers are linked,
	 * that is typing in one will update others too.
	 */
	export const Snippet = 2;
}

export type InsertTextFormat = 1 | 2;
```

```typescript
/**
 * Completion item tags are extra annotations that tweak the rendering of a
 * completion item.
 *
 * @since 3.15.0
 */
export namespace CompletionItemTag {
	/**
	 * Render a completion as obsolete, usually using a strike-out.
	 */
	export const Deprecated = 1;
}

export type CompletionItemTag = 1;
```

```typescript
/**
 * A special text edit to provide an insert and a replace operation.
 *
 * @since 3.16.0
 */
export interface InsertReplaceEdit {
	/**
	 * The string to be inserted.
	 */
	newText: string;

	/**
	 * The range if the insert is requested
	 */
	insert: Range;

	/**
	 * The range if the replace is requested.
	 */
	replace: Range;
}
```

```typescript
/**
 * How whitespace and indentation is handled during completion
 * item insertion.
 *
 * @since 3.16.0
 */
export namespace InsertTextMode {
	/**
	 * The insertion or replace strings is taken as it is. If the
	 * value is multi line the lines below the cursor will be
	 * inserted using the indentation defined in the string value.
	 * The client will not apply any kind of adjustments to the
	 * string.
	 */
	export const asIs: 1 = 1;

	/**
	 * The editor adjusts leading whitespace of new lines so that
	 * they match the indentation up to the cursor of the line for
	 * which the item is accepted.
	 *
	 * Consider a line like this: <2tabs><cursor><3tabs>foo. Accepting a
	 * multi line completion item is indented using 2 tabs and all
	 * following lines inserted will be indented using 2 tabs as well.
	 */
	export const adjustIndentation: 2 = 2;
}

export type InsertTextMode = 1 | 2;
```

```typescript
/**
 * Additional details for a completion item label.
 *
 * @since 3.17.0
 */
export interface CompletionItemLabelDetails {

	/**
	 * An optional string which is rendered less prominently directly after
	 * {@link CompletionItem.label label}, without any spacing. Should be
	 * used for function signatures or type annotations.
	 */
	detail?: string;

	/**
	 * An optional string which is rendered less prominently after
	 * {@link CompletionItemLabelDetails.detail}. Should be used for fully qualified
	 * names or file path.
	 */
	description?: string;
}
```

```typescript
export interface CompletionItem {

	/**
	 * The label of this completion item.
	 *
	 * The label property is also by default the text that
	 * is inserted when selecting this completion.
	 *
	 * If label details are provided the label itself should
	 * be an unqualified name of the completion item.
	 */
	label: string;

	/**
	 * Additional details for the label
	 *
	 * @since 3.17.0
	 */
	labelDetails?: CompletionItemLabelDetails;

	/**
	 * The kind of this completion item. Based of the kind
	 * an icon is chosen by the editor. The standardized set
	 * of available values is defined in \`CompletionItemKind\`.
	 */
	kind?: CompletionItemKind;

	/**
	 * Tags for this completion item.
	 *
	 * @since 3.15.0
	 */
	tags?: CompletionItemTag[];

	/**
	 * A human-readable string with additional information
	 * about this item, like type or symbol information.
	 */
	detail?: string;

	/**
	 * A human-readable string that represents a doc-comment.
	 */
	documentation?: string | MarkupContent;

	/**
	 * Indicates if this item is deprecated.
	 *
	 * @deprecated Use \`tags\` instead if supported.
	 */
	deprecated?: boolean;

	/**
	 * Select this item when showing.
	 *
	 * *Note* that only one completion item can be selected and that the
	 * tool / client decides which item that is. The rule is that the *first*
	 * item of those that match best is selected.
	 */
	preselect?: boolean;

	/**
	 * A string that should be used when comparing this item
	 * with other items. When omitted the label is used
	 * as the sort text for this item.
	 */
	sortText?: string;

	/**
	 * A string that should be used when filtering a set of
	 * completion items. When omitted the label is used as the
	 * filter text for this item.
	 */
	filterText?: string;

	/**
	 * A string that should be inserted into a document when selecting
	 * this completion. When omitted the label is used as the insert text
	 * for this item.
	 *
	 * The \`insertText\` is subject to interpretation by the client side.
	 * Some tools might not take the string literally. For example
	 * VS Code when code complete is requested in this example
	 * \`con<cursor position>\` and a completion item with an \`insertText\` of
	 * \`console\` is provided it will only insert \`sole\`. Therefore it is
	 * recommended to use \`textEdit\` instead since it avoids additional client
	 * side interpretation.
	 */
	insertText?: string;

	/**
	 * The format of the insert text. The format applies to both the
	 * \`insertText\` property and the \`newText\` property of a provided
	 * \`textEdit\`. If omitted defaults to \`InsertTextFormat.PlainText\`.
	 *
	 * Please note that the insertTextFormat doesn't apply to
	 * \`additionalTextEdits\`.
	 */
	insertTextFormat?: InsertTextFormat;

	/**
	 * How whitespace and indentation is handled during completion
	 * item insertion. If not provided the client's default value depends on
	 * the \`textDocument.completion.insertTextMode\` client capability.
	 *
	 * @since 3.16.0
	 * @since 3.17.0 - support for \`textDocument.completion.insertTextMode\`
	 */
	insertTextMode?: InsertTextMode;

	/**
	 * An edit which is applied to a document when selecting this completion.
	 * When an edit is provided the value of \`insertText\` is ignored.
	 *
	 * *Note:* The range of the edit must be a single line range and it must
	 * contain the position at which completion has been requested.
	 *
	 * Most editors support two different operations when accepting a completion
	 * item. One is to insert a completion text and the other is to replace an
	 * existing text with a completion text. Since this can usually not be
	 * predetermined by a server it can report both ranges. Clients need to
	 * signal support for \`InsertReplaceEdit\`s via the
	 * \`textDocument.completion.completionItem.insertReplaceSupport\` client
	 * capability property.
	 *
	 * *Note 1:* The text edit's range as well as both ranges from an insert
	 * replace edit must be a [single line] and they must contain the position
	 * at which completion has been requested.
	 * *Note 2:* If an \`InsertReplaceEdit\` is returned the edit's insert range
	 * must be a prefix of the edit's replace range, that means it must be
	 * contained and starting at the same position.
	 *
	 * @since 3.16.0 additional type \`InsertReplaceEdit\`
	 */
	textEdit?: TextEdit | InsertReplaceEdit;

	/**
	 * The edit text used if the completion item is part of a CompletionList and
	 * CompletionList defines an item default for the text edit range.
	 *
	 * Clients will only honor this property if they opt into completion list
	 * item defaults using the capability \`completionList.itemDefaults\`.
	 *
	 * If not provided and a list's default range is provided the label
	 * property is used as a text.
	 *
	 * @since 3.17.0
	 */
	textEditText?: string;

	/**
	 * An optional array of additional text edits that are applied when
	 * selecting this completion. Edits must not overlap (including the same
	 * insert position) with the main edit nor with themselves.
	 *
	 * Additional text edits should be used to change text unrelated to the
	 * current cursor position (for example adding an import statement at the
	 * top of the file if the completion item will insert an unqualified type).
	 */
	additionalTextEdits?: TextEdit[];

	/**
	 * An optional set of characters that when pressed while this completion is
	 * active will accept it first and then type that character. *Note* that all
	 * commit characters should have \`length=1\` and that superfluous characters
	 * will be ignored.
	 */
	commitCharacters?: string[];

	/**
	 * An optional command that is executed *after* inserting this completion.
	 * *Note* that additional modifications to the current document should be
	 * described with the additionalTextEdits-property.
	 */
	command?: Command;

	/**
	 * A data entry field that is preserved on a completion item between
	 * a completion and a completion resolve request.
	 */
	data?: LSPAny;
}
```

```typescript
/**
 * The kind of a completion entry.
 */
export namespace CompletionItemKind {
	export const Text = 1;
	export const Method = 2;
	export const Function = 3;
	export const Constructor = 4;
	export const Field = 5;
	export const Variable = 6;
	export const Class = 7;
	export const Interface = 8;
	export const Module = 9;
	export const Property = 10;
	export const Unit = 11;
	export const Value = 12;
	export const Enum = 13;
	export const Keyword = 14;
	export const Snippet = 15;
	export const Color = 16;
	export const File = 17;
	export const Reference = 18;
	export const Folder = 19;
	export const EnumMember = 20;
	export const Constant = 21;
	export const Struct = 22;
	export const Event = 23;
	export const Operator = 24;
	export const TypeParameter = 25;
}

export type CompletionItemKind = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 | 24 | 25;
```

- partial result: `CompletionItem[]` or [`CompletionList`](#completionList) followed by `CompletionItem[]`. If the first provided result item is of type [`CompletionList`](#completionList) subsequent partial results of `CompletionItem[]` add to the `items` property of the [`CompletionList`](#completionList). <a id="completionList"></a>
- error: code and message set in case an exception happens during the completion request.

Completion items support snippets (see `InsertTextFormat.Snippet`). The snippet format is as follows:

##### Snippet Syntax

The `body` of a snippet can use special constructs to control cursors and the text being inserted. The following are supported features and their syntaxes:

##### Tab stops

With tab stops, you can make the editor cursor move inside a snippet. Use `$1`, `$2` to specify cursor locations. The number is the order in which tab stops will be visited, whereas `$0` denotes the final cursor position. Multiple tab stops are linked and updated in sync.

##### Placeholders

Placeholders are tab stops with values, like `${1:foo}`. The placeholder text will be inserted and selected such that it can be easily changed. Placeholders can be nested, like `${1:another ${2:placeholder}}`.

##### Choice

Placeholders can have choices as values. The syntax is a comma separated enumeration of values, enclosed with the pipe-character, for example `${1|one,two,three|}`. When the snippet is inserted and the placeholder selected, choices will prompt the user to pick one of the values.

##### Variables

With `$name` or `${name:default}` you can insert the value of a variable. When a variable isn’t set, its *default* or the empty string is inserted. When a variable is unknown (that is, its name isn’t defined) the name of the variable is inserted and it is transformed into a placeholder.

The following variables can be used:

- `TM_SELECTED_TEXT` The currently selected text or the empty string
- `TM_CURRENT_LINE` The contents of the current line
- `TM_CURRENT_WORD` The contents of the word under cursor or the empty string
- `TM_LINE_INDEX` The zero-index based line number
- `TM_LINE_NUMBER` The one-index based line number
- `TM_FILENAME` The filename of the current document
- `TM_FILENAME_BASE` The filename of the current document without its extensions
- `TM_DIRECTORY` The directory of the current document
- `TM_FILEPATH` The full file path of the current document

##### Variable Transforms

Transformations allow you to modify the value of a variable before it is inserted. The definition of a transformation consists of three parts:

1. A [regular expression](#regExp) that is matched against the value of a variable, or the empty string when the variable cannot be resolved. <a id="regExp"></a>
2. A “format string” that allows to reference matching groups from the regular expression. The format string allows for conditional inserts and simple modifications.
3. Options that are passed to the regular expression.

The following example inserts the name of the current file without its ending, so from `foo.txt` it makes `foo`.

```plaintext
${TM_FILENAME/(.*)\..+$/$1/}
  |           |         | |
  |           |         | |-> no options
  |           |         |
  |           |         |-> references the contents of the first
  |           |             capture group
  |           |
  |           |-> regex to capture everything before
  |               the final \`.suffix\`
  |
  |-> resolves to the filename
```

##### Grammar

Below is the EBNF ([extended Backus-Naur form](https://en.wikipedia.org/wiki/Extended_Backus-Naur_form)) for snippets. With `\` (backslash), you can escape `$`, `}` and `\`. Within choice elements, the backslash also escapes comma and pipe characters.

```plaintext
any         ::= tabstop | placeholder | choice | variable | text
tabstop     ::= '$' int | '${' int '}'
placeholder ::= '${' int ':' any '}'
choice      ::= '${' int '|' text (',' text)* '|}'
variable    ::= '$' var | '${' var }'
                | '${' var ':' any '}'
                | '${' var '/' regex '/' (format | text)+ '/' options '}'
format      ::= '$' int | '${' int '}'
                | '${' int ':' '/upcase' | '/downcase' | '/capitalize' '}'
                | '${' int ':+' if '}'
                | '${' int ':?' if ':' else '}'
                | '${' int ':-' else '}' | '${' int ':' else '}'
regex       ::= Regular Expression value (ctor-string)
options     ::= Regular Expression option (ctor-options)
var         ::= [_a-zA-Z] [_a-zA-Z0-9]*
int         ::= [0-9]+
text        ::= .*
if			::= text
else		::= text
```

#### Completion Item Resolve Request

The request is sent from the client to the server to resolve additional information for a given completion item.

*Request*:

- method: [`completionItem/resolve`](#completion-item-resolve-request)
- params: [`CompletionItem`](#completion-item-resolve-request)

*Response*:

- result: [`CompletionItem`](#completion-item-resolve-request)
- error: code and message set in case an exception happens during the completion resolve request.

#### PublishDiagnostics Notification

Diagnostics notifications are sent from the server to the client to signal results of validation runs.

Diagnostics are “owned” by the server so it is the server’s responsibility to clear them if necessary. The following rule is used for VS Code servers that generate diagnostics:

- if a language is single file only (for example HTML) then diagnostics are cleared by the server when the file is closed. Please note that open / close events don’t necessarily reflect what the user sees in the user interface. These events are ownership events. So with the current version of the specification it is possible that problems are not cleared although the file is not visible in the user interface since the client has not closed the file yet.
- if a language has a project system (for example C#) diagnostics are not cleared when a file closes. When a project is opened all diagnostics for all files are recomputed (or read from a cache).

When a file changes it is the server’s responsibility to re-compute diagnostics and push them to the client. If the computed set is empty it has to push the empty array to clear former diagnostics. Newly pushed diagnostics always replace previously pushed diagnostics. There is no merging that happens on the client side.

See also the [Diagnostic](#diagnostic) section.

*Client Capability*:

- property name (optional): `textDocument.publishDiagnostics`
- property type: [`PublishDiagnosticsClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface PublishDiagnosticsClientCapabilities {
	/**
	 * Whether the clients accepts diagnostics with related information.
	 */
	relatedInformation?: boolean;

	/**
	 * Client supports the tag property to provide meta data about a diagnostic.
	 * Clients supporting tags have to handle unknown tags gracefully.
	 *
	 * @since 3.15.0
	 */
	tagSupport?: {
		/**
		 * The tags supported by the client.
		 */
		valueSet: DiagnosticTag[];
	};

	/**
	 * Whether the client interprets the version property of the
	 * \`textDocument/publishDiagnostics\` notification's parameter.
	 *
	 * @since 3.15.0
	 */
	versionSupport?: boolean;

	/**
	 * Client supports a codeDescription property
	 *
	 * @since 3.16.0
	 */
	codeDescriptionSupport?: boolean;

	/**
	 * Whether code action supports the \`data\` property which is
	 * preserved between a \`textDocument/publishDiagnostics\` and
	 * \`textDocument/codeAction\` request.
	 *
	 * @since 3.16.0
	 */
	dataSupport?: boolean;
}
```

*Notification*:

- method: [`textDocument/publishDiagnostics`](#publishdiagnostics-notification)
- params: [`PublishDiagnosticsParams`](#diagnostic) defined as follows:

```typescript
interface PublishDiagnosticsParams {
	/**
	 * The URI for which diagnostic information is reported.
	 */
	uri: DocumentUri;

	/**
	 * Optional the version number of the document the diagnostics are published
	 * for.
	 *
	 * @since 3.15.0
	 */
	version?: integer;

	/**
	 * An array of diagnostic information items.
	 */
	diagnostics: Diagnostic[];
}
```

#### Pull Diagnostics

Diagnostics are currently published by the server to the client using a notification. This model has the advantage that for workspace wide diagnostics the server has the freedom to compute them at a server preferred point in time. On the other hand the approach has the disadvantage that the server can’t prioritize the computation for the file in which the user types or which are visible in the editor. Inferring the client’s UI state from the [`textDocument/didOpen`](#textDocumentdidOpen) and [`textDocument/didChange`](#textDocumentdidChange) notifications might lead to false positives since these notifications are ownership transfer notifications. <a id="textDocumentdidOpen"></a>

The specification therefore introduces the concept of diagnostic pull requests to give a client more control over the documents for which diagnostics should be computed and at which point in time.

*Client Capability*:

- property name (optional): `textDocument.diagnostic`
- property type: [`DiagnosticClientCapabilities`](#capabilities) defined as follows:

```typescript
/**
 * Client capabilities specific to diagnostic pull requests.
 *
 * @since 3.17.0
 */
export interface DiagnosticClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * \`true\` the client supports the new
	 * \`(TextDocumentRegistrationOptions & StaticRegistrationOptions)\`
	 * return value for the corresponding server capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Whether the clients supports related documents for document diagnostic
	 * pulls.
	 */
	relatedDocumentSupport?: boolean;
}
```

*Server Capability*:

- property name (optional): `diagnosticProvider`
- property type: [`DiagnosticOptions`](#diagnostic) defined as follows:

```typescript
/**
 * Diagnostic options.
 *
 * @since 3.17.0
 */
export interface DiagnosticOptions extends WorkDoneProgressOptions {
	/**
	 * An optional identifier under which the diagnostics are
	 * managed by the client.
	 */
	identifier?: string;

	/**
	 * Whether the language has inter file dependencies meaning that
	 * editing code in one file can result in a different diagnostic
	 * set in another file. Inter file dependencies are common for
	 * most programming languages and typically uncommon for linters.
	 */
	interFileDependencies: boolean;

	/**
	 * The server provides support for workspace diagnostics as well.
	 */
	workspaceDiagnostics: boolean;
}
```

*Registration Options*: [`DiagnosticRegistrationOptions`](#diagnostic) options defined as follows:

```typescript
/**
 * Diagnostic registration options.
 *
 * @since 3.17.0
 */
export interface DiagnosticRegistrationOptions extends
	TextDocumentRegistrationOptions, DiagnosticOptions,
	StaticRegistrationOptions {
}
```

##### Document Diagnostics

The text document diagnostic request is sent from the client to the server to ask the server to compute the diagnostics for a given document. As with other pull requests the server is asked to compute the diagnostics for the currently synced version of the document.

*Request*:

- method: `textDocument/diagnostic`.
- params: [`DocumentDiagnosticParams`](#diagnostic) defined as follows:

```typescript
/**
 * Parameters of the document diagnostic request.
 *
 * @since 3.17.0
 */
export interface DocumentDiagnosticParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The additional identifier  provided during registration.
	 */
	identifier?: string;

	/**
	 * The result id of a previous response if provided.
	 */
	previousResultId?: string;
}
```

*Response*:

- result: [`DocumentDiagnosticReport`](#diagnostic) defined as follows:

```typescript
/**
 * The result of a document diagnostic pull request. A report can
 * either be a full report containing all diagnostics for the
 * requested document or a unchanged report indicating that nothing
 * has changed in terms of diagnostics in comparison to the last
 * pull request.
 *
 * @since 3.17.0
 */
export type DocumentDiagnosticReport = RelatedFullDocumentDiagnosticReport
	| RelatedUnchangedDocumentDiagnosticReport;
```

```typescript
/**
 * The document diagnostic report kinds.
 *
 * @since 3.17.0
 */
export namespace DocumentDiagnosticReportKind {
	/**
	 * A diagnostic report with a full
	 * set of problems.
	 */
	export const Full = 'full';

	/**
	 * A report indicating that the last
	 * returned report is still accurate.
	 */
	export const Unchanged = 'unchanged';
}

export type DocumentDiagnosticReportKind = 'full' | 'unchanged';
```

```typescript
/**
 * A diagnostic report with a full set of problems.
 *
 * @since 3.17.0
 */
export interface FullDocumentDiagnosticReport {
	/**
	 * A full document diagnostic report.
	 */
	kind: DocumentDiagnosticReportKind.Full;

	/**
	 * An optional result id. If provided it will
	 * be sent on the next diagnostic request for the
	 * same document.
	 */
	resultId?: string;

	/**
	 * The actual items.
	 */
	items: Diagnostic[];
}
```

```typescript
/**
 * A diagnostic report indicating that the last returned
 * report is still accurate.
 *
 * @since 3.17.0
 */
export interface UnchangedDocumentDiagnosticReport {
	/**
	 * A document diagnostic report indicating
	 * no changes to the last result. A server can
	 * only return \`unchanged\` if result ids are
	 * provided.
	 */
	kind: DocumentDiagnosticReportKind.Unchanged;

	/**
	 * A result id which will be sent on the next
	 * diagnostic request for the same document.
	 */
	resultId: string;
}
```

```typescript
/**
 * A full diagnostic report with a set of related documents.
 *
 * @since 3.17.0
 */
export interface RelatedFullDocumentDiagnosticReport extends
	FullDocumentDiagnosticReport {
	/**
	 * Diagnostics of related documents. This information is useful
	 * in programming languages where code in a file A can generate
	 * diagnostics in a file B which A depends on. An example of
	 * such a language is C/C++ where macro definitions in a file
	 * a.cpp and result in errors in a header file b.hpp.
	 *
	 * @since 3.17.0
	 */
	relatedDocuments?: {
		[uri: string /** DocumentUri */]:
			FullDocumentDiagnosticReport | UnchangedDocumentDiagnosticReport;
	};
}
```

```typescript
/**
 * An unchanged diagnostic report with a set of related documents.
 *
 * @since 3.17.0
 */
export interface RelatedUnchangedDocumentDiagnosticReport extends
	UnchangedDocumentDiagnosticReport {
	/**
	 * Diagnostics of related documents. This information is useful
	 * in programming languages where code in a file A can generate
	 * diagnostics in a file B which A depends on. An example of
	 * such a language is C/C++ where macro definitions in a file
	 * a.cpp and result in errors in a header file b.hpp.
	 *
	 * @since 3.17.0
	 */
	relatedDocuments?: {
		[uri: string /** DocumentUri */]:
			FullDocumentDiagnosticReport | UnchangedDocumentDiagnosticReport;
	};
}
```

- partial result: The first literal send need to be a [`DocumentDiagnosticReport`](#diagnostic) followed by n [`DocumentDiagnosticReportPartialResult`](#diagnostic) literals defined as follows:

```typescript
/**
 * A partial result for a document diagnostic report.
 *
 * @since 3.17.0
 */
export interface DocumentDiagnosticReportPartialResult {
	relatedDocuments: {
		[uri: string /** DocumentUri */]:
			FullDocumentDiagnosticReport | UnchangedDocumentDiagnosticReport;
	};
}
```

- error: code and message set in case an exception happens during the diagnostic request. A server is also allowed to return an error with code `ServerCancelled` indicating that the server can’t compute the result right now. A server can return a [`DiagnosticServerCancellationData`](#diagnostic) data to indicate whether the client should re-trigger the request. If no data is provided it defaults to `{ retriggerRequest: true }`:

```typescript
/**
 * Cancellation data returned from a diagnostic request.
 *
 * @since 3.17.0
 */
export interface DiagnosticServerCancellationData {
	retriggerRequest: boolean;
}
```

##### Workspace Diagnostics

The workspace diagnostic request is sent from the client to the server to ask the server to compute workspace wide diagnostics which previously where pushed from the server to the client. In contrast to the document diagnostic request the workspace request can be long running and is not bound to a specific workspace or document state. If the client supports streaming for the workspace diagnostic pull it is legal to provide a document diagnostic report multiple times for the same document URI. The last one reported will win over previous reports.

If a client receives a diagnostic report for a document in a workspace diagnostic request for which the client also issues individual document diagnostic pull requests the client needs to decide which diagnostics win and should be presented. In general:

- diagnostics for a higher document version should win over those from a lower document version (e.g. note that document versions are steadily increasing)
- diagnostics from a document pull should win over diagnostics from a workspace pull.

*Request*:

- method: `workspace/diagnostic`.
- params: [`WorkspaceDiagnosticParams`](#diagnostic) defined as follows:

```typescript
/**
 * Parameters of the workspace diagnostic request.
 *
 * @since 3.17.0
 */
export interface WorkspaceDiagnosticParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The additional identifier provided during registration.
	 */
	identifier?: string;

	/**
	 * The currently known diagnostic reports with their
	 * previous result ids.
	 */
	previousResultIds: PreviousResultId[];
}
```

```typescript
/**
 * A previous result id in a workspace pull request.
 *
 * @since 3.17.0
 */
export interface PreviousResultId {
	/**
	 * The URI for which the client knows a
	 * result id.
	 */
	uri: DocumentUri;

	/**
	 * The value of the previous result id.
	 */
	value: string;
}
```

*Response*:

- result: [`WorkspaceDiagnosticReport`](#diagnostic) defined as follows:

```typescript
/**
 * A workspace diagnostic report.
 *
 * @since 3.17.0
 */
export interface WorkspaceDiagnosticReport {
	items: WorkspaceDocumentDiagnosticReport[];
}
```

```typescript
/**
 * A full document diagnostic report for a workspace diagnostic result.
 *
 * @since 3.17.0
 */
export interface WorkspaceFullDocumentDiagnosticReport extends
	FullDocumentDiagnosticReport {

	/**
	 * The URI for which diagnostic information is reported.
	 */
	uri: DocumentUri;

	/**
	 * The version number for which the diagnostics are reported.
	 * If the document is not marked as open \`null\` can be provided.
	 */
	version: integer | null;
}
```

```typescript
/**
 * An unchanged document diagnostic report for a workspace diagnostic result.
 *
 * @since 3.17.0
 */
export interface WorkspaceUnchangedDocumentDiagnosticReport extends
	UnchangedDocumentDiagnosticReport {

	/**
	 * The URI for which diagnostic information is reported.
	 */
	uri: DocumentUri;

	/**
	 * The version number for which the diagnostics are reported.
	 * If the document is not marked as open \`null\` can be provided.
	 */
	version: integer | null;
};
```

```typescript
/**
 * A workspace diagnostic document report.
 *
 * @since 3.17.0
 */
export type WorkspaceDocumentDiagnosticReport =
	WorkspaceFullDocumentDiagnosticReport
	| WorkspaceUnchangedDocumentDiagnosticReport;
```

- partial result: The first literal send need to be a [`WorkspaceDiagnosticReport`](#diagnostic) followed by n [`WorkspaceDiagnosticReportPartialResult`](#diagnostic) literals defined as follows:

```typescript
/**
 * A partial result for a workspace diagnostic report.
 *
 * @since 3.17.0
 */
export interface WorkspaceDiagnosticReportPartialResult {
	items: WorkspaceDocumentDiagnosticReport[];
}
```

- error: code and message set in case an exception happens during the diagnostic request. A server is also allowed to return and error with code `ServerCancelled` indicating that the server can’t compute the result right now. A server can return a [`DiagnosticServerCancellationData`](#diagnostic) data to indicate whether the client should re-trigger the request. If no data is provided it defaults to `{ retriggerRequest: true }`:

##### Diagnostics Refresh

The [`workspace/diagnostic/refresh`](#diagnostic) request is sent from the server to the client. Servers can use it to ask clients to refresh all needed document and workspace diagnostics. This is useful if a server detects a project wide configuration change which requires a re-calculation of all diagnostics.

*Client Capability*:

- property name (optional): `workspace.diagnostics`
- property type: [`DiagnosticWorkspaceClientCapabilities`](#capabilities) defined as follows:

```typescript
/**
 * Workspace client capabilities specific to diagnostic pull requests.
 *
 * @since 3.17.0
 */
export interface DiagnosticWorkspaceClientCapabilities {
	/**
	 * Whether the client implementation supports a refresh request sent from
	 * the server to the client.
	 *
	 * Note that this event is global and will force the client to refresh all
	 * pulled diagnostics currently shown. It should be used with absolute care
	 * and is useful for situation where a server for example detects a project
	 * wide change that requires such a calculation.
	 */
	refreshSupport?: boolean;
}
```

*Request*:

- method: [`workspace/diagnostic/refresh`](#diagnostic)
- params: none

*Response*:

- result: void
- error: code and message set in case an exception happens during the ‘workspace/diagnostic/refresh’ request

##### Implementation Considerations

Generally the language server specification doesn’t enforce any specific client implementation since those usually depend on how the client UI behaves. However since diagnostics can be provided on a document and workspace level here are some tips:

- a client should pull actively for the document the users types in.
- if the server signals inter file dependencies a client should also pull for visible documents to ensure accurate diagnostics. However the pull should happen less frequently.
- if the server signals workspace pull support a client should also pull for workspace diagnostics. It is recommended for clients to implement partial result progress for the workspace pull to allow servers to keep the request open for a long time. If a server closes a workspace diagnostic pull request the client should re-trigger the request.

#### Signature Help Request

The signature help request is sent from the client to the server to request signature information at a given cursor position.

*Client Capability*:

- property name (optional): `textDocument.signatureHelp`
- property type: [`SignatureHelpClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface SignatureHelpClientCapabilities {
	/**
	 * Whether signature help supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports the following \`SignatureInformation\`
	 * specific properties.
	 */
	signatureInformation?: {
		/**
		 * Client supports the follow content formats for the documentation
		 * property. The order describes the preferred format of the client.
		 */
		documentationFormat?: MarkupKind[];

		/**
		 * Client capabilities specific to parameter information.
		 */
		parameterInformation?: {
			/**
			 * The client supports processing label offsets instead of a
			 * simple label string.
			 *
			 * @since 3.14.0
			 */
			labelOffsetSupport?: boolean;
		};

		/**
		 * The client supports the \`activeParameter\` property on
		 * \`SignatureInformation\` literal.
		 *
		 * @since 3.16.0
		 */
		activeParameterSupport?: boolean;
	};

	/**
	 * The client supports to send additional context information for a
	 * \`textDocument/signatureHelp\` request. A client that opts into
	 * contextSupport will also support the \`retriggerCharacters\` on
	 * \`SignatureHelpOptions\`.
	 *
	 * @since 3.15.0
	 */
	contextSupport?: boolean;
}
```

*Server Capability*:

- property name (optional): `signatureHelpProvider`
- property type: [`SignatureHelpOptions`](#signatureHelpOptions) defined as follows: <a id="signatureHelpOptions"></a>

```typescript
export interface SignatureHelpOptions extends WorkDoneProgressOptions {
	/**
	 * The characters that trigger signature help
	 * automatically.
	 */
	triggerCharacters?: string[];

	/**
	 * List of characters that re-trigger signature help.
	 *
	 * These trigger characters are only active when signature help is already
	 * showing. All trigger characters are also counted as re-trigger
	 * characters.
	 *
	 * @since 3.15.0
	 */
	retriggerCharacters?: string[];
}
```

*Registration Options*: [`SignatureHelpRegistrationOptions`](#signatureHelpRegistrationOptions) defined as follows: <a id="signatureHelpRegistrationOptions"></a>

*Request*:

- method: [`textDocument/signatureHelp`](#signature-help-request)
- params: [`SignatureHelpParams`](#signatureHelpParams) defined as follows: <a id="signatureHelpParams"></a>
```typescript
export interface SignatureHelpParams extends TextDocumentPositionParams,
	WorkDoneProgressParams {
	/**
	 * The signature help context. This is only available if the client
	 * specifies to send this using the client capability
	 * \`textDocument.signatureHelp.contextSupport === true\`
	 *
	 * @since 3.15.0
	 */
	context?: SignatureHelpContext;
}
```

```typescript
/**
 * How a signature help was triggered.
 *
 * @since 3.15.0
 */
export namespace SignatureHelpTriggerKind {
	/**
	 * Signature help was invoked manually by the user or by a command.
	 */
	export const Invoked: 1 = 1;
	/**
	 * Signature help was triggered by a trigger character.
	 */
	export const TriggerCharacter: 2 = 2;
	/**
	 * Signature help was triggered by the cursor moving or by the document
	 * content changing.
	 */
	export const ContentChange: 3 = 3;
}
export type SignatureHelpTriggerKind = 1 | 2 | 3;
```

```typescript
/**
 * Additional information about the context in which a signature help request
 * was triggered.
 *
 * @since 3.15.0
 */
export interface SignatureHelpContext {
	/**
	 * Action that caused signature help to be triggered.
	 */
	triggerKind: SignatureHelpTriggerKind;

	/**
	 * Character that caused signature help to be triggered.
	 *
	 * This is undefined when triggerKind !==
	 * SignatureHelpTriggerKind.TriggerCharacter
	 */
	triggerCharacter?: string;

	/**
	 * \`true\` if signature help was already showing when it was triggered.
	 *
	 * Retriggers occur when the signature help is already active and can be
	 * caused by actions such as typing a trigger character, a cursor move, or
	 * document content changes.
	 */
	isRetrigger: boolean;

	/**
	 * The currently active \`SignatureHelp\`.
	 *
	 * The \`activeSignatureHelp\` has its \`SignatureHelp.activeSignature\` field
	 * updated based on the user navigating through available signatures.
	 */
	activeSignatureHelp?: SignatureHelp;
}
```

*Response*:

- result: [`SignatureHelp`](#signature-help-request) | `null` defined as follows:

```typescript
/**
 * Signature help represents the signature of something
 * callable. There can be multiple signature but only one
 * active and only one active parameter.
 */
export interface SignatureHelp {
	/**
	 * One or more signatures. If no signatures are available the signature help
	 * request should return \`null\`.
	 */
	signatures: SignatureInformation[];

	/**
	 * The active signature. If omitted or the value lies outside the
	 * range of \`signatures\` the value defaults to zero or is ignore if
	 * the \`SignatureHelp\` as no signatures.
	 *
	 * Whenever possible implementors should make an active decision about
	 * the active signature and shouldn't rely on a default value.
	 *
	 * In future version of the protocol this property might become
	 * mandatory to better express this.
	 */
	activeSignature?: uinteger;

	/**
	 * The active parameter of the active signature. If omitted or the value
	 * lies outside the range of \`signatures[activeSignature].parameters\`
	 * defaults to 0 if the active signature has parameters. If
	 * the active signature has no parameters it is ignored.
	 * In future version of the protocol this property might become
	 * mandatory to better express the active parameter if the
	 * active signature does have any.
	 */
	activeParameter?: uinteger;
}
```

```typescript
/**
 * Represents the signature of something callable. A signature
 * can have a label, like a function-name, a doc-comment, and
 * a set of parameters.
 */
export interface SignatureInformation {
	/**
	 * The label of this signature. Will be shown in
	 * the UI.
	 */
	label: string;

	/**
	 * The human-readable doc-comment of this signature. Will be shown
	 * in the UI but can be omitted.
	 */
	documentation?: string | MarkupContent;

	/**
	 * The parameters of this signature.
	 */
	parameters?: ParameterInformation[];

	/**
	 * The index of the active parameter.
	 *
	 * If provided, this is used in place of \`SignatureHelp.activeParameter\`.
	 *
	 * @since 3.16.0
	 */
	activeParameter?: uinteger;
}
```

```typescript
/**
 * Represents a parameter of a callable-signature. A parameter can
 * have a label and a doc-comment.
 */
export interface ParameterInformation {

	/**
	 * The label of this parameter information.
	 *
	 * Either a string or an inclusive start and exclusive end offsets within
	 * its containing signature label. (see SignatureInformation.label). The
	 * offsets are based on a UTF-16 string representation as \`Position\` and
	 * \`Range\` does.
	 *
	 * *Note*: a label of type string should be a substring of its containing
	 * signature label. Its intended use case is to highlight the parameter
	 * label part in the \`SignatureInformation.label\`.
	 */
	label: string | [uinteger, uinteger];

	/**
	 * The human-readable doc-comment of this parameter. Will be shown
	 * in the UI but can be omitted.
	 */
	documentation?: string | MarkupContent;
}
```

- error: code and message set in case an exception happens during the signature help request.

#### Code Action Request

The code action request is sent from the client to the server to compute commands for a given text document and range. These commands are typically code fixes to either fix problems or to beautify/refactor code. The result of a [`textDocument/codeAction`](#code-action-request) request is an array of [`Command`](#command) literals which are typically presented in the user interface. To ensure that a server is useful in many clients the commands specified in a code actions should be handled by the server and not by the client (see [`workspace/executeCommand`](#command) and `ServerCapabilities.executeCommandProvider`). If the client supports providing edits with a code action then that mode should be used.

*Since version 3.16.0:* a client can offer a server to delay the computation of code action properties during a ‘textDocument/codeAction’ request:

This is useful for cases where it is expensive to compute the value of a property (for example the `edit` property). Clients signal this through the `codeAction.resolveSupport` capability which lists all properties a client can resolve lazily. The server capability `codeActionProvider.resolveProvider` signals that a server will offer a [`codeAction/resolve`](#code-action-resolve-request) route. To help servers to uniquely identify a code action in the resolve request, a code action literal can optional carry a data property. This is also guarded by an additional client capability `codeAction.dataSupport`. In general, a client should offer data support if it offers resolve support. It should also be noted that servers shouldn’t alter existing attributes of a code action in a codeAction/resolve request.

> *Since version 3.8.0:* support for CodeAction literals to enable the following scenarios:

- the ability to directly return a workspace edit from the code action request. This avoids having another server roundtrip to execute an actual code action. However server providers should be aware that if the code action is expensive to compute or the edits are huge it might still be beneficial if the result is simply a command and the actual edit is only computed when needed.
- the ability to group code actions using a kind. Clients are allowed to ignore that information. However it allows them to better group code action for example into corresponding menus (e.g. all refactor code actions into a refactor menu).

Clients need to announce their support for code action literals (e.g. literals of type [`CodeAction`](#code-action-request)) and code action kinds via the corresponding client capability `codeAction.codeActionLiteralSupport`.

*Client Capability*:

- property name (optional): `textDocument.codeAction`
- property type: [`CodeActionClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface CodeActionClientCapabilities {
	/**
	 * Whether code action supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports code action literals as a valid
	 * response of the \`textDocument/codeAction\` request.
	 *
	 * @since 3.8.0
	 */
	codeActionLiteralSupport?: {
		/**
		 * The code action kind is supported with the following value
		 * set.
		 */
		codeActionKind: {

			/**
			 * The code action kind values the client supports. When this
			 * property exists the client also guarantees that it will
			 * handle values outside its set gracefully and falls back
			 * to a default value when unknown.
			 */
			valueSet: CodeActionKind[];
		};
	};

	/**
	 * Whether code action supports the \`isPreferred\` property.
	 *
	 * @since 3.15.0
	 */
	isPreferredSupport?: boolean;

	/**
	 * Whether code action supports the \`disabled\` property.
	 *
	 * @since 3.16.0
	 */
	disabledSupport?: boolean;

	/**
	 * Whether code action supports the \`data\` property which is
	 * preserved between a \`textDocument/codeAction\` and a
	 * \`codeAction/resolve\` request.
	 *
	 * @since 3.16.0
	 */
	dataSupport?: boolean;

	/**
	 * Whether the client supports resolving additional code action
	 * properties via a separate \`codeAction/resolve\` request.
	 *
	 * @since 3.16.0
	 */
	resolveSupport?: {
		/**
		 * The properties that a client can resolve lazily.
		 */
		properties: string[];
	};

	/**
	 * Whether the client honors the change annotations in
	 * text edits and resource operations returned via the
	 * \`CodeAction#edit\` property by for example presenting
	 * the workspace edit in the user interface and asking
	 * for confirmation.
	 *
	 * @since 3.16.0
	 */
	honorsChangeAnnotations?: boolean;
}
```

*Server Capability*:

- property name (optional): `codeActionProvider`
- property type: `boolean | CodeActionOptions` where [`CodeActionOptions`](#codeActionOptions) is defined as follows: <a id="codeActionOptions"></a>
```typescript
export interface CodeActionOptions extends WorkDoneProgressOptions {
	/**
	 * CodeActionKinds that this server may return.
	 *
	 * The list of kinds may be generic, such as \`CodeActionKind.Refactor\`,
	 * or the server may list out every specific kind they provide.
	 */
	codeActionKinds?: CodeActionKind[];

	/**
	 * The server provides support to resolve additional
	 * information for a code action.
	 *
	 * @since 3.16.0
	 */
	resolveProvider?: boolean;
}
```

*Registration Options*: [`CodeActionRegistrationOptions`](#codeActionRegistrationOptions) defined as follows: <a id="codeActionRegistrationOptions"></a>

*Request*:

- method: [`textDocument/codeAction`](#code-action-request)
- params: [`CodeActionParams`](#codeActionParams) defined as follows: <a id="codeActionParams"></a>
```typescript
/**
 * Params for the CodeActionRequest
 */
export interface CodeActionParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The document in which the command was invoked.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The range for which the command was invoked.
	 */
	range: Range;

	/**
	 * Context carrying additional information.
	 */
	context: CodeActionContext;
}
```

```typescript
/**
 * The kind of a code action.
 *
 * Kinds are a hierarchical list of identifiers separated by \`.\`,
 * e.g. \`"refactor.extract.function"\`.
 *
 * The set of kinds is open and client needs to announce the kinds it supports
 * to the server during initialization.
 */
export type CodeActionKind = string;

/**
 * A set of predefined code action kinds.
 */
export namespace CodeActionKind {

	/**
	 * Empty kind.
	 */
	export const Empty: CodeActionKind = '';

	/**
	 * Base kind for quickfix actions: 'quickfix'.
	 */
	export const QuickFix: CodeActionKind = 'quickfix';

	/**
	 * Base kind for refactoring actions: 'refactor'.
	 */
	export const Refactor: CodeActionKind = 'refactor';

	/**
	 * Base kind for refactoring extraction actions: 'refactor.extract'.
	 *
	 * Example extract actions:
	 *
	 * - Extract method
	 * - Extract function
	 * - Extract variable
	 * - Extract interface from class
	 * - ...
	 */
	export const RefactorExtract: CodeActionKind = 'refactor.extract';

	/**
	 * Base kind for refactoring inline actions: 'refactor.inline'.
	 *
	 * Example inline actions:
	 *
	 * - Inline function
	 * - Inline variable
	 * - Inline constant
	 * - ...
	 */
	export const RefactorInline: CodeActionKind = 'refactor.inline';

	/**
	 * Base kind for refactoring rewrite actions: 'refactor.rewrite'.
	 *
	 * Example rewrite actions:
	 *
	 * - Convert JavaScript function to class
	 * - Add or remove parameter
	 * - Encapsulate field
	 * - Make method static
	 * - Move method to base class
	 * - ...
	 */
	export const RefactorRewrite: CodeActionKind = 'refactor.rewrite';

	/**
	 * Base kind for source actions: \`source\`.
	 *
	 * Source code actions apply to the entire file.
	 */
	export const Source: CodeActionKind = 'source';

	/**
	 * Base kind for an organize imports source action:
	 * \`source.organizeImports\`.
	 */
	export const SourceOrganizeImports: CodeActionKind =
		'source.organizeImports';

	/**
	 * Base kind for a 'fix all' source action: \`source.fixAll\`.
	 *
	 * 'Fix all' actions automatically fix errors that have a clear fix that
	 * do not require user input. They should not suppress errors or perform
	 * unsafe fixes such as generating new types or classes.
	 *
	 * @since 3.17.0
	 */
	export const SourceFixAll: CodeActionKind = 'source.fixAll';
}
```

```typescript
/**
 * Contains additional diagnostic information about the context in which
 * a code action is run.
 */
export interface CodeActionContext {
	/**
	 * An array of diagnostics known on the client side overlapping the range
	 * provided to the \`textDocument/codeAction\` request. They are provided so
	 * that the server knows which errors are currently presented to the user
	 * for the given range. There is no guarantee that these accurately reflect
	 * the error state of the resource. The primary parameter
	 * to compute code actions is the provided range.
	 */
	diagnostics: Diagnostic[];

	/**
	 * Requested kind of actions to return.
	 *
	 * Actions not of this kind are filtered out by the client before being
	 * shown. So servers can omit computing them.
	 */
	only?: CodeActionKind[];

	/**
	 * The reason why code actions were requested.
	 *
	 * @since 3.17.0
	 */
	triggerKind?: CodeActionTriggerKind;
}
```

```typescript
/**
 * The reason why code actions were requested.
 *
 * @since 3.17.0
 */
export namespace CodeActionTriggerKind {
	/**
	 * Code actions were explicitly requested by the user or by an extension.
	 */
	export const Invoked: 1 = 1;

	/**
	 * Code actions were requested automatically.
	 *
	 * This typically happens when current selection in a file changes, but can
	 * also be triggered when file content changes.
	 */
	export const Automatic: 2 = 2;
}

export type CodeActionTriggerKind = 1 | 2;
```

*Response*:

- result: `(Command | CodeAction)[]` | `null` where [`CodeAction`](#code-action-request) is defined as follows:

```typescript
/**
 * A code action represents a change that can be performed in code, e.g. to fix
 * a problem or to refactor code.
 *
 * A CodeAction must set either \`edit\` and/or a \`command\`. If both are supplied,
 * the \`edit\` is applied first, then the \`command\` is executed.
 */
export interface CodeAction {

	/**
	 * A short, human-readable, title for this code action.
	 */
	title: string;

	/**
	 * The kind of the code action.
	 *
	 * Used to filter code actions.
	 */
	kind?: CodeActionKind;

	/**
	 * The diagnostics that this code action resolves.
	 */
	diagnostics?: Diagnostic[];

	/**
	 * Marks this as a preferred action. Preferred actions are used by the
	 * \`auto fix\` command and can be targeted by keybindings.
	 *
	 * A quick fix should be marked preferred if it properly addresses the
	 * underlying error. A refactoring should be marked preferred if it is the
	 * most reasonable choice of actions to take.
	 *
	 * @since 3.15.0
	 */
	isPreferred?: boolean;

	/**
	 * Marks that the code action cannot currently be applied.
	 *
	 * Clients should follow the following guidelines regarding disabled code
	 * actions:
	 *
	 * - Disabled code actions are not shown in automatic lightbulbs code
	 *   action menus.
	 *
	 * - Disabled actions are shown as faded out in the code action menu when
	 *   the user request a more specific type of code action, such as
	 *   refactorings.
	 *
	 * - If the user has a keybinding that auto applies a code action and only
	 *   a disabled code actions are returned, the client should show the user
	 *   an error message with \`reason\` in the editor.
	 *
	 * @since 3.16.0
	 */
	disabled?: {

		/**
		 * Human readable description of why the code action is currently
		 * disabled.
		 *
		 * This is displayed in the code actions UI.
		 */
		reason: string;
	};

	/**
	 * The workspace edit this code action performs.
	 */
	edit?: WorkspaceEdit;

	/**
	 * A command this code action executes. If a code action
	 * provides an edit and a command, first the edit is
	 * executed and then the command.
	 */
	command?: Command;

	/**
	 * A data entry field that is preserved on a code action between
	 * a \`textDocument/codeAction\` and a \`codeAction/resolve\` request.
	 *
	 * @since 3.16.0
	 */
	data?: LSPAny;
}
```

- partial result: `(Command | CodeAction)[]`
- error: code and message set in case an exception happens during the code action request.

#### Code Action Resolve Request

> *Since version 3.16.0*

The request is sent from the client to the server to resolve additional information for a given code action. This is usually used to compute the `edit` property of a code action to avoid its unnecessary computation during the [`textDocument/codeAction`](#code-action-request) request.

Consider the clients announces the `edit` property as a property that can be resolved lazy using the client capability

```typescript
textDocument.codeAction.resolveSupport = { properties: ['edit'] };
```

then a code action

needs to be resolved using the [`codeAction/resolve`](#code-action-resolve-request) request before it can be applied.

*Client Capability*:

- property name (optional): `textDocument.codeAction.resolveSupport`
- property type: `{ properties: string[]; }`

*Request*:

- method: [`codeAction/resolve`](#code-action-resolve-request)
- params: [`CodeAction`](#code-action-request)

*Response*:

- result: [`CodeAction`](#code-action-request)
- error: code and message set in case an exception happens during the code action resolve request.

#### Document Color Request

> *Since version 3.6.0*

The document color request is sent from the client to the server to list all color references found in a given text document. Along with the range, a color value in RGB is returned.

Clients can use the result to decorate color references in an editor. For example:

- Color boxes showing the actual color next to the reference
- Show a color picker when a color reference is edited

*Client Capability*:

- property name (optional): `textDocument.colorProvider`
- property type: [`DocumentColorClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DocumentColorClientCapabilities {
	/**
	 * Whether document color supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `colorProvider`
- property type: `boolean | DocumentColorOptions | DocumentColorRegistrationOptions` where [`DocumentColorOptions`](#documentColorOptions) is defined as follows: <a id="documentColorRegistrationOptions"></a> <a id="documentColorOptions"></a>
```typescript
export interface DocumentColorOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`DocumentColorRegistrationOptions`](#documentColorRegistrationOptions) defined as follows:

*Request*:

- method: [`textDocument/documentColor`](#document-color-request)
- params: [`DocumentColorParams`](#documentColorParams) defined as follows <a id="documentColorParams"></a>
```typescript
interface DocumentColorParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;
}
```

*Response*:

- result: `ColorInformation[]` defined as follows:

```typescript
interface ColorInformation {
	/**
	 * The range in the document where this color appears.
	 */
	range: Range;

	/**
	 * The actual color value for this color range.
	 */
	color: Color;
}
```

```typescript
/**
 * Represents a color in RGBA space.
 */
interface Color {

	/**
	 * The red component of this color in the range [0-1].
	 */
	readonly red: decimal;

	/**
	 * The green component of this color in the range [0-1].
	 */
	readonly green: decimal;

	/**
	 * The blue component of this color in the range [0-1].
	 */
	readonly blue: decimal;

	/**
	 * The alpha component of this color in the range [0-1].
	 */
	readonly alpha: decimal;
}
```

- partial result: `ColorInformation[]`
- error: code and message set in case an exception happens during the ‘textDocument/documentColor’ request

#### Color Presentation Request

> *Since version 3.6.0*

The color presentation request is sent from the client to the server to obtain a list of presentations for a color value at a given location. Clients can use the result to

- modify a color reference.
- show in a color picker and let users pick one of the presentations

This request has no special capabilities and registration options since it is send as a resolve request for the [`textDocument/documentColor`](#document-color-request) request.

*Request*:

- method: [`textDocument/colorPresentation`](#color-presentation-request)
- params: [`ColorPresentationParams`](#colorPresentationParams) defined as follows <a id="colorPresentationParams"></a>
```typescript
interface ColorPresentationParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The color information to request presentations for.
	 */
	color: Color;

	/**
	 * The range where the color would be inserted. Serves as a context.
	 */
	range: Range;
}
```

*Response*:

- result: `ColorPresentation[]` defined as follows:

```typescript
interface ColorPresentation {
	/**
	 * The label of this color presentation. It will be shown on the color
	 * picker header. By default this is also the text that is inserted when
	 * selecting this color presentation.
	 */
	label: string;
	/**
	 * An [edit](#TextEdit) which is applied to a document when selecting
	 * this presentation for the color. When omitted the
	 * [label](#ColorPresentation.label) is used.
	 */
	textEdit?: TextEdit;
	/**
	 * An optional array of additional [text edits](#TextEdit) that are applied
	 * when selecting this color presentation. Edits must not overlap with the
	 * main [edit](#ColorPresentation.textEdit) nor with themselves.
	 */
	additionalTextEdits?: TextEdit[];
}
```

- partial result: `ColorPresentation[]`
- error: code and message set in case an exception happens during the ‘textDocument/colorPresentation’ request

#### Document Formatting Request

The document formatting request is sent from the client to the server to format a whole document.

*Client Capability*:

- property name (optional): `textDocument.formatting`
- property type: [`DocumentFormattingClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DocumentFormattingClientCapabilities {
	/**
	 * Whether formatting supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `documentFormattingProvider`
- property type: `boolean | DocumentFormattingOptions` where [`DocumentFormattingOptions`](#documentFormattingOptions) is defined as follows: <a id="documentFormattingOptions"></a>
```typescript
export interface DocumentFormattingOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`DocumentFormattingRegistrationOptions`](#documentFormattingRegistrationOptions) defined as follows: <a id="documentFormattingRegistrationOptions"></a>

*Request*:

- method: [`textDocument/formatting`](#textDocumentformatting) <a id="textDocumentformatting"></a>
- params: [`DocumentFormattingParams`](#documentFormattingParams) defined as follows <a id="documentFormattingParams"></a>
```typescript
interface DocumentFormattingParams extends WorkDoneProgressParams {
	/**
	 * The document to format.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The format options.
	 */
	options: FormattingOptions;
}
```

```typescript
/**
 * Value-object describing what options formatting should use.
 */
interface FormattingOptions {
	/**
	 * Size of a tab in spaces.
	 */
	tabSize: uinteger;

	/**
	 * Prefer spaces over tabs.
	 */
	insertSpaces: boolean;

	/**
	 * Trim trailing whitespace on a line.
	 *
	 * @since 3.15.0
	 */
	trimTrailingWhitespace?: boolean;

	/**
	 * Insert a newline character at the end of the file if one does not exist.
	 *
	 * @since 3.15.0
	 */
	insertFinalNewline?: boolean;

	/**
	 * Trim all newlines after the final newline at the end of the file.
	 *
	 * @since 3.15.0
	 */
	trimFinalNewlines?: boolean;

	/**
	 * Signature for further properties.
	 */
	[key: string]: boolean | integer | string;
}
```

*Response*:

- result: [`TextEdit[]`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textEdit) | `null` describing the modification to the document to be formatted.
- error: code and message set in case an exception happens during the formatting request.

#### Document Range Formatting Request

The document range formatting request is sent from the client to the server to format a given range in a document.

*Client Capability*:

- property name (optional): `textDocument.rangeFormatting`
- property type: [`DocumentRangeFormattingClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DocumentRangeFormattingClientCapabilities {
	/**
	 * Whether formatting supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `documentRangeFormattingProvider`
- property type: `boolean | DocumentRangeFormattingOptions` where [`DocumentRangeFormattingOptions`](#range) is defined as follows:

```typescript
export interface DocumentRangeFormattingOptions extends
	WorkDoneProgressOptions {
}
```

*Registration Options*: [`DocumentFormattingRegistrationOptions`](#documentFormattingRegistrationOptions) defined as follows: <a id="documentFormattingRegistrationOptions"></a>

*Request*:

- method: [`textDocument/rangeFormatting`](#range),
- params: [`DocumentRangeFormattingParams`](#range) defined as follows:

```typescript
interface DocumentRangeFormattingParams extends WorkDoneProgressParams {
	/**
	 * The document to format.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The range to format
	 */
	range: Range;

	/**
	 * The format options
	 */
	options: FormattingOptions;
}
```

*Response*:

- result: [`TextEdit[]`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textEdit) | `null` describing the modification to the document to be formatted.
- error: code and message set in case an exception happens during the range formatting request.

#### Document on Type Formatting Request

The document on type formatting request is sent from the client to the server to format parts of the document during typing.

*Client Capability*:

- property name (optional): `textDocument.onTypeFormatting`
- property type: [`DocumentOnTypeFormattingClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DocumentOnTypeFormattingClientCapabilities {
	/**
	 * Whether on type formatting supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `documentOnTypeFormattingProvider`
- property type: [`DocumentOnTypeFormattingOptions`](#documentOnTypeFormattingOptions) defined as follows: <a id="documentOnTypeFormattingOptions"></a>

```typescript
export interface DocumentOnTypeFormattingOptions {
	/**
	 * A character on which formatting should be triggered, like \`{\`.
	 */
	firstTriggerCharacter: string;

	/**
	 * More trigger characters.
	 */
	moreTriggerCharacter?: string[];
}
```

*Registration Options*: [`DocumentOnTypeFormattingRegistrationOptions`](#documentOnTypeFormattingRegistrationOptions) defined as follows: <a id="documentOnTypeFormattingRegistrationOptions"></a>

*Request*:

- method: [`textDocument/onTypeFormatting`](#textDocumentonTypeFormatting) <a id="textDocumentonTypeFormatting"></a>
- params: [`DocumentOnTypeFormattingParams`](#documentOnTypeFormattingParams) defined as follows: <a id="documentOnTypeFormattingParams"></a>
```typescript
interface DocumentOnTypeFormattingParams {

	/**
	 * The document to format.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The position around which the on type formatting should happen.
	 * This is not necessarily the exact position where the character denoted
	 * by the property \`ch\` got typed.
	 */
	position: Position;

	/**
	 * The character that has been typed that triggered the formatting
	 * on type request. That is not necessarily the last character that
	 * got inserted into the document since the client could auto insert
	 * characters as well (e.g. like automatic brace completion).
	 */
	ch: string;

	/**
	 * The formatting options.
	 */
	options: FormattingOptions;
}
```

*Response*:

- result: [`TextEdit[]`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textEdit) | `null` describing the modification to the document.
- error: code and message set in case an exception happens during the range formatting request.

#### Rename Request

The rename request is sent from the client to the server to ask the server to compute a workspace change so that the client can perform a workspace-wide rename of a symbol.

*Client Capability*:

- property name (optional): `textDocument.rename`
- property type: [`RenameClientCapabilities`](#capabilities) defined as follows:

```typescript
export namespace PrepareSupportDefaultBehavior {
	/**
	 * The client's default behavior is to select the identifier
	 * according to the language's syntax rule.
	 */
	 export const Identifier: 1 = 1;
}

export type PrepareSupportDefaultBehavior = 1;
```

```typescript
export interface RenameClientCapabilities {
	/**
	 * Whether rename supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Client supports testing for validity of rename operations
	 * before execution.
	 *
	 * @since version 3.12.0
	 */
	prepareSupport?: boolean;

	/**
	 * Client supports the default behavior result
	 * (\`{ defaultBehavior: boolean }\`).
	 *
	 * The value indicates the default behavior used by the
	 * client.
	 *
	 * @since version 3.16.0
	 */
	prepareSupportDefaultBehavior?: PrepareSupportDefaultBehavior;

	/**
	 * Whether the client honors the change annotations in
	 * text edits and resource operations returned via the
	 * rename request's workspace edit by for example presenting
	 * the workspace edit in the user interface and asking
	 * for confirmation.
	 *
	 * @since 3.16.0
	 */
	honorsChangeAnnotations?: boolean;
}
```

*Server Capability*:

- property name (optional): `renameProvider`
- property type: `boolean | RenameOptions` where [`RenameOptions`](#renameOptions) is defined as follows: <a id="renameOptions"></a>

[`RenameOptions`](#renameOptions) may only be specified if the client states that it supports `prepareSupport` in its initial `initialize` request. <a id="renameOptions"></a>
```typescript
export interface RenameOptions extends WorkDoneProgressOptions {
	/**
	 * Renames should be checked and tested before being executed.
	 */
	prepareProvider?: boolean;
}
```

*Registration Options*: [`RenameRegistrationOptions`](#renameRegistrationOptions) defined as follows: <a id="renameRegistrationOptions"></a>

*Request*:

- method: [`textDocument/rename`](#rename-request)
- params: [`RenameParams`](#renameParams) defined as follows <a id="renameParams"></a>
```typescript
interface RenameParams extends TextDocumentPositionParams,
	WorkDoneProgressParams {
	/**
	 * The new name of the symbol. If the given name is not valid the
	 * request must return a [ResponseError](#ResponseError) with an
	 * appropriate message set.
	 */
	newName: string;
}
```

*Response*:

- result: [`WorkspaceEdit`](#workspaceedit) | `null` describing the modification to the workspace. `null` should be treated the same was as [`WorkspaceEdit`](#workspaceedit) with no changes (no change was required).
- error: code and message set in case when rename could not be performed for any reason. Examples include: there is nothing at given `position` to rename (like a space), given symbol does not support renaming by the server or the code is invalid (e.g. does not compile).

#### Prepare Rename Request

> *Since version 3.12.0*

The prepare rename request is sent from the client to the server to setup and test the validity of a rename operation at a given location.

*Request*:

- method: [`textDocument/prepareRename`](#prepare-rename-request)
- params: [`PrepareRenameParams`](#prepareRenameParams) defined as follows: <a id="prepareRenameParams"></a>

*Response*:

- result: `Range | { range: Range, placeholder: string } | { defaultBehavior: boolean } | null` describing a [`Range`](#range) of the string to rename and optionally a placeholder text of the string content to be renamed. If `{ defaultBehavior: boolean }` is returned (since 3.16) the rename position is valid and the client should use its default behavior to compute the rename range. If `null` is returned then it is deemed that a ‘textDocument/rename’ request is not valid at the given position.
- error: code and message set in case the element can’t be renamed. Clients should show the information in their user interface.

#### Linked Editing Range

> *Since version 3.16.0*

The linked editing request is sent from the client to the server to return for a given position in a document the range of the symbol at the position and all ranges that have the same content. Optionally a word pattern can be returned to describe valid contents. A rename to one of the ranges can be applied to all other ranges if the new content is valid. If no result-specific word pattern is provided, the word pattern from the client’s language configuration is used.

*Client Capabilities*:

- property name (optional): `textDocument.linkedEditingRange`
- property type: [`LinkedEditingRangeClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface LinkedEditingRangeClientCapabilities {
	/**
	 * Whether the implementation supports dynamic registration.
	 * If this is set to \`true\` the client supports the new
	 * \`(TextDocumentRegistrationOptions & StaticRegistrationOptions)\`
	 * return value for the corresponding server capability as well.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property name (optional): `linkedEditingRangeProvider`
- property type: `boolean` | [`LinkedEditingRangeOptions`](#range) | [`LinkedEditingRangeRegistrationOptions`](#range) defined as follows:

```typescript
export interface LinkedEditingRangeOptions extends WorkDoneProgressOptions {
}
```

*Registration Options*: [`LinkedEditingRangeRegistrationOptions`](#range) defined as follows:

*Request*:

- method: [`textDocument/linkedEditingRange`](#range)
- params: [`LinkedEditingRangeParams`](#range) defined as follows:

*Response*:

- result: [`LinkedEditingRanges`](#range) | `null` defined as follows:

```typescript
export interface LinkedEditingRanges {
	/**
	 * A list of ranges that can be renamed together. The ranges must have
	 * identical length and contain identical text content. The ranges cannot
	 * overlap.
	 */
	ranges: Range[];

	/**
	 * An optional word pattern (regular expression) that describes valid
	 * contents for the given ranges. If no pattern is provided, the client
	 * configuration's word pattern will be used.
	 */
	wordPattern?: string;
}
```

- error: code and message set in case an exception happens during the ‘textDocument/linkedEditingRange’ request

### Workspace Features
#### Workspace Symbols Request

The workspace symbol request is sent from the client to the server to list project-wide symbols matching the query string. Since 3.17.0 servers can also provide a handler for `workspaceSymbol/resolve` requests. This allows servers to return workspace symbols without a range for a `workspace/symbol` request. Clients then need to resolve the range when necessary using the `workspaceSymbol/resolve` request. Servers can only use this new model if clients advertise support for it via the `workspace.symbol.resolveSupport` capability.

*Client Capability*:

- property path (optional): `workspace.symbol`
- property type: [`WorkspaceSymbolClientCapabilities`](#workspace-symbols-request) defined as follows:

```typescript
interface WorkspaceSymbolClientCapabilities {
	/**
	 * Symbol request supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Specific capabilities for the \`SymbolKind\` in the \`workspace/symbol\`
	 * request.
	 */
	symbolKind?: {
		/**
		 * The symbol kind values the client supports. When this
		 * property exists the client also guarantees that it will
		 * handle values outside its set gracefully and falls back
		 * to a default value when unknown.
		 *
		 * If this property is not present the client only supports
		 * the symbol kinds from \`File\` to \`Array\` as defined in
		 * the initial version of the protocol.
		 */
		valueSet?: SymbolKind[];
	};

	/**
	 * The client supports tags on \`SymbolInformation\` and \`WorkspaceSymbol\`.
	 * Clients supporting tags have to handle unknown tags gracefully.
	 *
	 * @since 3.16.0
	 */
	tagSupport?: {
		/**
		 * The tags supported by the client.
		 */
		valueSet: SymbolTag[];
	};

	/**
	 * The client support partial workspace symbols. The client will send the
	 * request \`workspaceSymbol/resolve\` to the server to resolve additional
	 * properties.
	 *
	 * @since 3.17.0 - proposedState
	 */
	resolveSupport?: {
		/**
		 * The properties that a client can resolve lazily. Usually
		 * \`location.range\`
		 */
		properties: string[];
	};
}
```

*Server Capability*:

- property path (optional): `workspaceSymbolProvider`
- property type: `boolean | WorkspaceSymbolOptions` where [`WorkspaceSymbolOptions`](#workspaceSymbolOptions) is defined as follows: <a id="workspaceSymbolOptions"></a>
```typescript
export interface WorkspaceSymbolOptions extends WorkDoneProgressOptions {
	/**
	 * The server provides support to resolve additional
	 * information for a workspace symbol.
	 *
	 * @since 3.17.0
	 */
	resolveProvider?: boolean;
}
```

*Registration Options*: [`WorkspaceSymbolRegistrationOptions`](#workspaceSymbolRegistrationOptions) defined as follows: <a id="workspaceSymbolRegistrationOptions"></a>
```typescript
export interface WorkspaceSymbolRegistrationOptions
	extends WorkspaceSymbolOptions {
}
```

*Request*:

- method: ‘workspace/symbol’
- params: [`WorkspaceSymbolParams`](#workspaceSymbolParams) defined as follows: <a id="workspaceSymbolParams"></a>
```typescript
/**
 * The parameters of a Workspace Symbol Request.
 */
interface WorkspaceSymbolParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * A query string to filter symbols by. Clients may send an empty
	 * string here to request all symbols.
	 */
	query: string;
}
```

*Response*:

- result: `SymbolInformation[]` | `WorkspaceSymbol[]` | `null`. See above for the definition of [`SymbolInformation`](#symbolInformation). It is recommended that you use the new [`WorkspaceSymbol`](#workspace-symbols-request). However whether the workspace symbol can return a location without a range depends on the client capability `workspace.symbol.resolveSupport`. [`WorkspaceSymbol`](#workspace-symbols-request)which is defined as follows: <a id="symbolInformation"></a>

```typescript
/**
 * A special workspace symbol that supports locations without a range
 *
 * @since 3.17.0
 */
export interface WorkspaceSymbol {
	/**
	 * The name of this symbol.
	 */
	name: string;

	/**
	 * The kind of this symbol.
	 */
	kind: SymbolKind;

	/**
	 * Tags for this completion item.
	 */
	tags?: SymbolTag[];

	/**
	 * The name of the symbol containing this symbol. This information is for
	 * user interface purposes (e.g. to render a qualifier in the user interface
	 * if necessary). It can't be used to re-infer a hierarchy for the document
	 * symbols.
	 */
	containerName?: string;

	/**
	 * The location of this symbol. Whether a server is allowed to
	 * return a location without a range depends on the client
	 * capability \`workspace.symbol.resolveSupport\`.
	 *
	 * See also \`SymbolInformation.location\`.
	 */
	location: Location | { uri: DocumentUri };

	/**
	 * A data entry field that is preserved on a workspace symbol between a
	 * workspace symbol request and a workspace symbol resolve request.
	 */
	data?: LSPAny;
}
```

- partial result: `SymbolInformation[]` | `WorkspaceSymbol[]` as defined above.
- error: code and message set in case an exception happens during the workspace symbol request.

#### Workspace Symbol Resolve Request

The request is sent from the client to the server to resolve additional information for a given workspace symbol.

*Request*:

- method: ‘workspaceSymbol/resolve’
- params: [`WorkspaceSymbol`](#workspace-symbols-request)

*Response*:

- result: [`WorkspaceSymbol`](#workspace-symbols-request)
- error: code and message set in case an exception happens during the workspace symbol resolve request.

#### Configuration Request

> *Since version 3.6.0*

The `workspace/configuration` request is sent from the server to the client to fetch configuration settings from the client. The request can fetch several configuration settings in one roundtrip. The order of the returned configuration settings correspond to the order of the passed `ConfigurationItems` (e.g. the first item in the response is the result for the first configuration item in the params).

A [`ConfigurationItem`](#configurationItem) consists of the configuration section to ask for and an additional scope URI. The configuration section asked for is defined by the server and doesn’t necessarily need to correspond to the configuration store used by the client. So a server might ask for a configuration `cpp.formatterOptions` but the client stores the configuration in an XML store layout differently. It is up to the client to do the necessary conversion. If a scope URI is provided the client should return the setting scoped to the provided resource. If the client for example uses [EditorConfig](http://editorconfig.org/) to manage its settings the configuration should be returned for the passed resource URI. If the client can’t provide a configuration setting for a given scope then `null` needs to be present in the returned array.

This pull model replaces the old push model were the client signaled configuration change via an event. If the server still needs to react to configuration changes (since the server caches the result of `workspace/configuration` requests) the server should register for an empty configuration change using the following registration pattern:

```typescript
connection.client.register(DidChangeConfigurationNotification.type, undefined);
```

*Client Capability*:

- property path (optional): `workspace.configuration`
- property type: `boolean`

*Request*:

- method: ‘workspace/configuration’
- params: [`ConfigurationParams`](#configurationParams) defined as follows <a id="configurationParams"></a>
```typescript
export interface ConfigurationParams {
	items: ConfigurationItem[];
}
``` <a id="configurationItem"></a>
```typescript
export interface ConfigurationItem {
	/**
	 * The scope to get the configuration section for.
	 */
	scopeUri?: URI;

	/**
	 * The configuration section asked for.
	 */
	section?: string;
}
```

*Response*:

- result: LSPAny\[\]
- error: code and message set in case an exception happens during the ‘workspace/configuration’ request

#### DidChangeConfiguration Notification

A notification sent from the client to the server to signal the change of configuration settings.

*Client Capability*:

- property path (optional): `workspace.didChangeConfiguration`
- property type: [`DidChangeConfigurationClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DidChangeConfigurationClientCapabilities {
	/**
	 * Did change configuration notification supports dynamic registration.
	 *
	 * @since 3.6.0 to support the new pull model.
	 */
	dynamicRegistration?: boolean;
}
```

*Notification*:

- method: ‘workspace/didChangeConfiguration’,
- params: [`DidChangeConfigurationParams`](#didChangeConfigurationParams) defined as follows: <a id="didChangeConfigurationParams"></a>
```typescript
interface DidChangeConfigurationParams {
	/**
	 * The actual changed settings
	 */
	settings: LSPAny;
}
```

#### Workspace folders request

> *Since version 3.6.0*

Many tools support more than one root folder per workspace. Examples for this are VS Code’s multi-root support, Atom’s project folder support or Sublime’s project support. If a client workspace consists of multiple roots then a server typically needs to know about this. The protocol up to now assumes one root folder which is announced to the server by the `rootUri` property of the [`InitializeParams`](#initializeParams). If the client supports workspace folders and announces them via the corresponding `workspaceFolders` client capability, the [`InitializeParams`](#initializeParams) contain an additional property `workspaceFolders` with the configured workspace folders when the server starts. <a id="initializeParams"></a>

The [`workspace/workspaceFolders`](#workspaceworkspaceFolders) request is sent from the server to the client to fetch the current open list of workspace folders. Returns `null` in the response if only a single file is open in the tool. Returns an empty array if a workspace is open but no folders are configured. <a id="workspaceworkspaceFolders"></a>

*Client Capability*:

- property path (optional): `workspace.workspaceFolders`
- property type: `boolean`

*Server Capability*:

- property path (optional): `workspace.workspaceFolders`
- property type: [`WorkspaceFoldersServerCapabilities`](#capabilities) defined as follows:

```typescript
export interface WorkspaceFoldersServerCapabilities {
	/**
	 * The server has support for workspace folders
	 */
	supported?: boolean;

	/**
	 * Whether the server wants to receive workspace folder
	 * change notifications.
	 *
	 * If a string is provided, the string is treated as an ID
	 * under which the notification is registered on the client
	 * side. The ID can be used to unregister for these events
	 * using the \`client/unregisterCapability\` request.
	 */
	changeNotifications?: string | boolean;
}
```

*Request*:

- method: [`workspace/workspaceFolders`](#workspaceworkspaceFolders) <a id="workspaceworkspaceFolders"></a>
- params: none

*Response*:

- result: `WorkspaceFolder[] | null` defined as follows:

```typescript
export interface WorkspaceFolder {
	/**
	 * The associated URI for this workspace folder.
	 */
	uri: URI;

	/**
	 * The name of the workspace folder. Used to refer to this
	 * workspace folder in the user interface.
	 */
	name: string;
}
```

- error: code and message set in case an exception happens during the ‘workspace/workspaceFolders’ request

#### DidChangeWorkspaceFolders Notification

> *Since version 3.6.0*

The `workspace/didChangeWorkspaceFolders` notification is sent from the client to the server to inform the server about workspace folder configuration changes. A server can register for this notification by using either the *server capability* `workspace.workspaceFolders.changeNotifications` or by using the dynamic capability registration mechanism. To dynamically register for the `workspace/didChangeWorkspaceFolders` send a `client/registerCapability` request from the server to the client. The registration parameter must have a `registrations` item of the following form, where `id` is a unique id used to unregister the capability (the example uses a UUID):

```ts
{
	id: "28c6150c-bd7b-11e7-abc4-cec278b6b50a",
	method: "workspace/didChangeWorkspaceFolders"
}
```

*Notification*:

- method: ‘workspace/didChangeWorkspaceFolders’
- params: [`DidChangeWorkspaceFoldersParams`](#didChangeWorkspaceFoldersParams) defined as follows: <a id="didChangeWorkspaceFoldersParams"></a>
```typescript
export interface DidChangeWorkspaceFoldersParams {
	/**
	 * The actual workspace folder change event.
	 */
	event: WorkspaceFoldersChangeEvent;
}
```

```typescript
/**
 * The workspace folder change event.
 */
export interface WorkspaceFoldersChangeEvent {
	/**
	 * The array of added workspace folders
	 */
	added: WorkspaceFolder[];

	/**
	 * The array of the removed workspace folders
	 */
	removed: WorkspaceFolder[];
}
```

#### WillCreateFiles Request

The will create files request is sent from the client to the server before files are actually created as long as the creation is triggered from within the client either by a user action or by applying a workspace edit. The request can return a [`WorkspaceEdit`](#workspaceedit) which will be applied to workspace before the files are created. Hence the [`WorkspaceEdit`](#workspaceedit) can not manipulate the content of the files to be created. Please note that clients might drop results if computing the edit took too long or if a server constantly fails on this request. This is done to keep creates fast and reliable.

*Client Capability*:

- property name (optional): `workspace.fileOperations.willCreate`
- property type: `boolean`

The capability indicates that the client supports sending [`workspace/willCreateFiles`](#willcreatefiles-request) requests.

*Server Capability*:

- property name (optional): `workspace.fileOperations.willCreate`
- property type: [`FileOperationRegistrationOptions`](#fileOperationRegistrationOptions) where [`FileOperationRegistrationOptions`](#fileOperationRegistrationOptions) is defined as follows: <a id="fileOperationRegistrationOptions"></a> <a id="fileOperationRegistrationOptions"></a>
```typescript
/**
 * The options to register for file operations.
 *
 * @since 3.16.0
 */
interface FileOperationRegistrationOptions {
	/**
	 * The actual filters.
	 */
	filters: FileOperationFilter[];
}
```

```typescript
/**
 * A pattern kind describing if a glob pattern matches a file a folder or
 * both.
 *
 * @since 3.16.0
 */
export namespace FileOperationPatternKind {
	/**
	 * The pattern matches a file only.
	 */
	export const file: 'file' = 'file';

	/**
	 * The pattern matches a folder only.
	 */
	export const folder: 'folder' = 'folder';
}

export type FileOperationPatternKind = 'file' | 'folder';
```

```typescript
/**
 * Matching options for the file operation pattern.
 *
 * @since 3.16.0
 */
export interface FileOperationPatternOptions {

	/**
	 * The pattern should be matched ignoring casing.
	 */
	ignoreCase?: boolean;
}
```

```typescript
/**
 * A pattern to describe in which file operation requests or notifications
 * the server is interested in.
 *
 * @since 3.16.0
 */
interface FileOperationPattern {
	/**
	 * The glob pattern to match. Glob patterns can have the following syntax:
	 * - \`*\` to match one or more characters in a path segment
	 * - \`?\` to match on one character in a path segment
	 * - \`**\` to match any number of path segments, including none
	 * - \`{}\` to group sub patterns into an OR expression. (e.g. \`**​/*.{ts,js}\`
	 *   matches all TypeScript and JavaScript files)
	 * - \`[]\` to declare a range of characters to match in a path segment
	 *   (e.g., \`example.[0-9]\` to match on \`example.0\`, \`example.1\`, …)
	 * - \`[!...]\` to negate a range of characters to match in a path segment
	 *   (e.g., \`example.[!0-9]\` to match on \`example.a\`, \`example.b\`, but
	 *   not \`example.0\`)
	 */
	glob: string;

	/**
	 * Whether to match files or folders with this pattern.
	 *
	 * Matches both if undefined.
	 */
	matches?: FileOperationPatternKind;

	/**
	 * Additional options used during matching.
	 */
	options?: FileOperationPatternOptions;
}
```

```typescript
/**
 * A filter to describe in which file operation requests or notifications
 * the server is interested in.
 *
 * @since 3.16.0
 */
export interface FileOperationFilter {

	/**
	 * A Uri like \`file\` or \`untitled\`.
	 */
	scheme?: string;

	/**
	 * The actual file operation pattern.
	 */
	pattern: FileOperationPattern;
}
```

The capability indicates that the server is interested in receiving [`workspace/willCreateFiles`](#willcreatefiles-request) requests.

*Registration Options*: none

*Request*:

- method: ‘workspace/willCreateFiles’
- params: [`CreateFilesParams`](#createFilesParams) defined as follows: <a id="createFilesParams"></a>
```typescript
/**
 * The parameters sent in notifications/requests for user-initiated creation
 * of files.
 *
 * @since 3.16.0
 */
export interface CreateFilesParams {

	/**
	 * An array of all files/folders created in this operation.
	 */
	files: FileCreate[];
}
```

```typescript
/**
 * Represents information on a file/folder create.
 *
 * @since 3.16.0
 */
export interface FileCreate {

	/**
	 * A file:// URI for the location of the file/folder being created.
	 */
	uri: string;
}
```

*Response*:

- result:[`WorkspaceEdit`](#workspaceedit) | `null`
- error: code and message set in case an exception happens during the `willCreateFiles` request.

#### DidCreateFiles Notification

The did create files notification is sent from the client to the server when files were created from within the client.

*Client Capability*:

- property name (optional): `workspace.fileOperations.didCreate`
- property type: `boolean`

The capability indicates that the client supports sending [`workspace/didCreateFiles`](#didcreatefiles-notification) notifications.

*Server Capability*:

- property name (optional): `workspace.fileOperations.didCreate`
- property type: [`FileOperationRegistrationOptions`](#fileOperationRegistrationOptions) <a id="fileOperationRegistrationOptions"></a>

The capability indicates that the server is interested in receiving [`workspace/didCreateFiles`](#didcreatefiles-notification) notifications.

*Notification*:

- method: ‘workspace/didCreateFiles’
- params: [`CreateFilesParams`](#createFilesParams) <a id="createFilesParams"></a>

#### WillRenameFiles Request

The will rename files request is sent from the client to the server before files are actually renamed as long as the rename is triggered from within the client either by a user action or by applying a workspace edit. The request can return a WorkspaceEdit which will be applied to workspace before the files are renamed. Please note that clients might drop results if computing the edit took too long or if a server constantly fails on this request. This is done to keep renames fast and reliable.

*Client Capability*:

- property name (optional): `workspace.fileOperations.willRename`
- property type: `boolean`

The capability indicates that the client supports sending [`workspace/willRenameFiles`](#willrenamefiles-request) requests.

*Server Capability*:

- property name (optional): `workspace.fileOperations.willRename`
- property type: [`FileOperationRegistrationOptions`](#fileOperationRegistrationOptions) <a id="fileOperationRegistrationOptions"></a>

The capability indicates that the server is interested in receiving [`workspace/willRenameFiles`](#willrenamefiles-request) requests.

*Registration Options*: none

*Request*:

- method: ‘workspace/willRenameFiles’
- params: [`RenameFilesParams`](#renameFilesParams) defined as follows: <a id="renameFilesParams"></a>
```typescript
/**
 * The parameters sent in notifications/requests for user-initiated renames
 * of files.
 *
 * @since 3.16.0
 */
export interface RenameFilesParams {

	/**
	 * An array of all files/folders renamed in this operation. When a folder
	 * is renamed, only the folder will be included, and not its children.
	 */
	files: FileRename[];
}
```

```typescript
/**
 * Represents information on a file/folder rename.
 *
 * @since 3.16.0
 */
export interface FileRename {

	/**
	 * A file:// URI for the original location of the file/folder being renamed.
	 */
	oldUri: string;

	/**
	 * A file:// URI for the new location of the file/folder being renamed.
	 */
	newUri: string;
}
```

*Response*:

- result:[`WorkspaceEdit`](#workspaceedit) | `null`
- error: code and message set in case an exception happens during the [`workspace/willRenameFiles`](#willrenamefiles-request) request.

#### DidRenameFiles Notification

The did rename files notification is sent from the client to the server when files were renamed from within the client.

*Client Capability*:

- property name (optional): `workspace.fileOperations.didRename`
- property type: `boolean`

The capability indicates that the client supports sending [`workspace/didRenameFiles`](#didrenamefiles-notification) notifications.

*Server Capability*:

- property name (optional): `workspace.fileOperations.didRename`
- property type: [`FileOperationRegistrationOptions`](#fileOperationRegistrationOptions) <a id="fileOperationRegistrationOptions"></a>

The capability indicates that the server is interested in receiving [`workspace/didRenameFiles`](#didrenamefiles-notification) notifications.

*Notification*:

- method: ‘workspace/didRenameFiles’
- params: [`RenameFilesParams`](#renameFilesParams) <a id="renameFilesParams"></a>

#### WillDeleteFiles Request

The will delete files request is sent from the client to the server before files are actually deleted as long as the deletion is triggered from within the client either by a user action or by applying a workspace edit. The request can return a WorkspaceEdit which will be applied to workspace before the files are deleted. Please note that clients might drop results if computing the edit took too long or if a server constantly fails on this request. This is done to keep deletes fast and reliable.

*Client Capability*:

- property name (optional): `workspace.fileOperations.willDelete`
- property type: `boolean`

The capability indicates that the client supports sending [`workspace/willDeleteFiles`](#willdeletefiles-request) requests.

*Server Capability*:

- property name (optional): `workspace.fileOperations.willDelete`
- property type: [`FileOperationRegistrationOptions`](#fileOperationRegistrationOptions) <a id="fileOperationRegistrationOptions"></a>

The capability indicates that the server is interested in receiving [`workspace/willDeleteFiles`](#willdeletefiles-request) requests.

*Registration Options*: none

*Request*:

- method: [`workspace/willDeleteFiles`](#willdeletefiles-request)
- params: [`DeleteFilesParams`](#deleteFilesParams) defined as follows: <a id="deleteFilesParams"></a>
```typescript
/**
 * The parameters sent in notifications/requests for user-initiated deletes
 * of files.
 *
 * @since 3.16.0
 */
export interface DeleteFilesParams {

	/**
	 * An array of all files/folders deleted in this operation.
	 */
	files: FileDelete[];
}
```

```typescript
/**
 * Represents information on a file/folder delete.
 *
 * @since 3.16.0
 */
export interface FileDelete {

	/**
	 * A file:// URI for the location of the file/folder being deleted.
	 */
	uri: string;
}
```

*Response*:

- result:[`WorkspaceEdit`](#workspaceedit) | `null`
- error: code and message set in case an exception happens during the [`workspace/willDeleteFiles`](#willdeletefiles-request) request.

#### DidDeleteFiles Notification

The did delete files notification is sent from the client to the server when files were deleted from within the client.

*Client Capability*:

- property name (optional): `workspace.fileOperations.didDelete`
- property type: `boolean`

The capability indicates that the client supports sending [`workspace/didDeleteFiles`](#diddeletefiles-notification) notifications.

*Server Capability*:

- property name (optional): `workspace.fileOperations.didDelete`
- property type: [`FileOperationRegistrationOptions`](#fileOperationRegistrationOptions) <a id="fileOperationRegistrationOptions"></a>

The capability indicates that the server is interested in receiving [`workspace/didDeleteFiles`](#diddeletefiles-notification) notifications.

*Notification*:

- method: ‘workspace/didDeleteFiles’
- params: [`DeleteFilesParams`](#deleteFilesParams) <a id="deleteFilesParams"></a>

#### DidChangeWatchedFiles Notification

The watched files notification is sent from the client to the server when the client detects changes to files and folders watched by the language client (note although the name suggest that only file events are sent it is about file system events which include folders as well). It is recommended that servers register for these file system events using the registration mechanism. In former implementations clients pushed file events without the server actively asking for it.

Servers are allowed to run their own file system watching mechanism and not rely on clients to provide file system events. However this is not recommended due to the following reasons:

- to our experience getting file system watching on disk right is challenging, especially if it needs to be supported across multiple OSes.
- file system watching is not for free especially if the implementation uses some sort of polling and keeps a file system tree in memory to compare time stamps (as for example some node modules do)
- a client usually starts more than one server. If every server runs its own file system watching it can become a CPU or memory problem.
- in general there are more server than client implementations. So this problem is better solved on the client side.

*Client Capability*:

- property path (optional): `workspace.didChangeWatchedFiles`
- property type: [`DidChangeWatchedFilesClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface DidChangeWatchedFilesClientCapabilities {
	/**
	 * Did change watched files notification supports dynamic registration.
	 * Please note that the current protocol doesn't support static
	 * configuration for file changes from the server side.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Whether the client has support for relative patterns
	 * or not.
	 *
	 * @since 3.17.0
	 */
	relativePatternSupport?: boolean;
}
```

*Registration Options*: [`DidChangeWatchedFilesRegistrationOptions`](#didChangeWatchedFilesRegistrationOptions) defined as follows: <a id="didChangeWatchedFilesRegistrationOptions"></a>
```typescript
/**
 * Describe options to be used when registering for file system change events.
 */
export interface DidChangeWatchedFilesRegistrationOptions {
	/**
	 * The watchers to register.
	 */
	watchers: FileSystemWatcher[];
}
```

```typescript
/**
 * The glob pattern to watch relative to the base path. Glob patterns can have
 * the following syntax:
 * - \`*\` to match one or more characters in a path segment
 * - \`?\` to match on one character in a path segment
 * - \`**\` to match any number of path segments, including none
 * - \`{}\` to group conditions (e.g. \`**​/*.{ts,js}\` matches all TypeScript
 *   and JavaScript files)
 * - \`[]\` to declare a range of characters to match in a path segment
 *   (e.g., \`example.[0-9]\` to match on \`example.0\`, \`example.1\`, …)
 * - \`[!...]\` to negate a range of characters to match in a path segment
 *   (e.g., \`example.[!0-9]\` to match on \`example.a\`, \`example.b\`,
 *   but not \`example.0\`)
 *
 * @since 3.17.0
 */
export type Pattern = string;
```

```typescript
/**
 * A relative pattern is a helper to construct glob patterns that are matched
 * relatively to a base URI. The common value for a \`baseUri\` is a workspace
 * folder root, but it can be another absolute URI as well.
 *
 * @since 3.17.0
 */
export interface RelativePattern {
	/**
	 * A workspace folder or a base URI to which this pattern will be matched
	 * against relatively.
	 */
	baseUri: WorkspaceFolder | URI;

	/**
	 * The actual glob pattern;
	 */
	pattern: Pattern;
}
```

```typescript
/**
 * The glob pattern. Either a string pattern or a relative pattern.
 *
 * @since 3.17.0
 */
export type GlobPattern = Pattern | RelativePattern;
```

```typescript
export interface FileSystemWatcher {
	/**
	 * The glob pattern to watch. See {@link GlobPattern glob pattern}
	 * for more detail.
	 *
 	 * @since 3.17.0 support for relative patterns.
	 */
	globPattern: GlobPattern;

	/**
	 * The kind of events of interest. If omitted it defaults
	 * to WatchKind.Create | WatchKind.Change | WatchKind.Delete
	 * which is 7.
	 */
	kind?: WatchKind;
}
```

```typescript
export namespace WatchKind {
	/**
	 * Interested in create events.
	 */
	export const Create = 1;

	/**
	 * Interested in change events
	 */
	export const Change = 2;

	/**
	 * Interested in delete events
	 */
	export const Delete = 4;
}
export type WatchKind = uinteger;
```

*Notification*:

- method: ‘workspace/didChangeWatchedFiles’
- params: [`DidChangeWatchedFilesParams`](#didChangeWatchedFilesParams) defined as follows: <a id="didChangeWatchedFilesParams"></a>
```typescript
interface DidChangeWatchedFilesParams {
	/**
	 * The actual file events.
	 */
	changes: FileEvent[];
}
```

Where FileEvents are described as follows:

```typescript
/**
 * An event describing a file change.
 */
interface FileEvent {
	/**
	 * The file's URI.
	 */
	uri: DocumentUri;
	/**
	 * The change type.
	 */
	type: FileChangeType;
}
```

```typescript
/**
 * The file event type.
 */
export namespace FileChangeType {
	/**
	 * The file got created.
	 */
	export const Created = 1;
	/**
	 * The file got changed.
	 */
	export const Changed = 2;
	/**
	 * The file got deleted.
	 */
	export const Deleted = 3;
}

export type FileChangeType = 1 | 2 | 3;
```

#### Execute a command

The [`workspace/executeCommand`](#command) request is sent from the client to the server to trigger command execution on the server. In most cases the server creates a [`WorkspaceEdit`](#workspaceedit) structure and applies the changes to the workspace using the request [`workspace/applyEdit`](#workspaceapplyEdit) which is sent from the server to the client. <a id="workspaceapplyEdit"></a>

*Client Capability*:

- property path (optional): `workspace.executeCommand`
- property type: [`ExecuteCommandClientCapabilities`](#capabilities) defined as follows:

```typescript
export interface ExecuteCommandClientCapabilities {
	/**
	 * Execute command supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

*Server Capability*:

- property path (optional): `executeCommandProvider`
- property type: [`ExecuteCommandOptions`](#command) defined as follows:

```typescript
export interface ExecuteCommandOptions extends WorkDoneProgressOptions {
	/**
	 * The commands to be executed on the server
	 */
	commands: string[];
}
```

*Registration Options*: [`ExecuteCommandRegistrationOptions`](#command) defined as follows:

```typescript
/**
 * Execute command registration options.
 */
export interface ExecuteCommandRegistrationOptions
	extends ExecuteCommandOptions {
}
```

*Request*:

- method: ‘workspace/executeCommand’
- params: [`ExecuteCommandParams`](#command) defined as follows: <a id="lspAny"></a>
```typescript
export interface ExecuteCommandParams extends WorkDoneProgressParams {

	/**
	 * The identifier of the actual command handler.
	 */
	command: string;
	/**
	 * Arguments that the command should be invoked with.
	 */
	arguments?: LSPAny[];
}
```

The arguments are typically specified when a command is returned from the server to the client. Example requests that return a command are [`textDocument/codeAction`](#code-action-request) or [`textDocument/codeLens`](#code-lens-request).

*Response*:

- result: [`LSPAny`](#lspAny)
- error: code and message set in case an exception happens during the request.

#### Applies a WorkspaceEdit

The [`workspace/applyEdit`](#workspaceapplyEdit) request is sent from the server to the client to modify resource on the client side. <a id="workspaceapplyEdit"></a>

*Client Capability*:

- property path (optional): `workspace.applyEdit`
- property type: `boolean`

See also the [WorkspaceEditClientCapabilities](#workspaceeditclientcapabilities) for the supported capabilities of a workspace edit.

*Request*:

- method: ‘workspace/applyEdit’
- params: [`ApplyWorkspaceEditParams`](#applyWorkspaceEditParams) defined as follows: <a id="applyWorkspaceEditParams"></a>
```typescript
export interface ApplyWorkspaceEditParams {
	/**
	 * An optional label of the workspace edit. This label is
	 * presented in the user interface for example on an undo
	 * stack to undo the workspace edit.
	 */
	label?: string;

	/**
	 * The edits to apply.
	 */
	edit: WorkspaceEdit;
}
```

*Response*:

- result: [`ApplyWorkspaceEditResult`](#applyWorkspaceEditResult) defined as follows: <a id="applyWorkspaceEditResult"></a>
```typescript
export interface ApplyWorkspaceEditResult {
	/**
	 * Indicates whether the edit was applied or not.
	 */
	applied: boolean;

	/**
	 * An optional textual description for why the edit was not applied.
	 * This may be used by the server for diagnostic logging or to provide
	 * a suitable error for a request that triggered the edit.
	 */
	failureReason?: string;

	/**
	 * Depending on the client's failure handling strategy \`failedChange\`
	 * might contain the index of the change that failed. This property is
	 * only available if the client signals a \`failureHandling\` strategy
	 * in its client capabilities.
	 */
	failedChange?: uinteger;
}
```

- error: code and message set in case an exception happens during the request.

### Window Features
#### ShowMessage Notification

The show message notification is sent from a server to a client to ask the client to display a particular message in the user interface.

*Notification*:

- method: ‘window/showMessage’
- params: [`ShowMessageParams`](#windowshowMessage) defined as follows: <a id="windowshowMessage"></a>

```typescript
interface ShowMessageParams {
	/**
	 * The message type. See {@link MessageType}.
	 */
	type: MessageType;

	/**
	 * The actual message.
	 */
	message: string;
}
```

Where the type is defined as follows:

```typescript
export namespace MessageType {
	/**
	 * An error message.
	 */
	export const Error = 1;
	/**
	 * A warning message.
	 */
	export const Warning = 2;
	/**
	 * An information message.
	 */
	export const Info = 3;
	/**
	 * A log message.
	 */
	export const Log = 4;
	/**
	 * A debug message.
	 *
	 * @since 3.18.0
	 * @proposed
	 */
	export const Debug = 5;
}

export type MessageType = 1 | 2 | 3 | 4 | 5;
```

#### ShowMessage Request

The show message request is sent from a server to a client to ask the client to display a particular message in the user interface. In addition to the show message notification the request allows to pass actions and to wait for an answer from the client.

*Client Capability*:

- property path (optional): `window.showMessage`
- property type: [`ShowMessageRequestClientCapabilities`](#windowshowMessageRequest) defined as follows: <a id="windowshowMessageRequest"></a>

```typescript
/**
 * Show message request client capabilities
 */
export interface ShowMessageRequestClientCapabilities {
	/**
	 * Capabilities specific to the \`MessageActionItem\` type.
	 */
	messageActionItem?: {
		/**
		 * Whether the client supports additional attributes which
		 * are preserved and sent back to the server in the
		 * request's response.
		 */
		additionalPropertiesSupport?: boolean;
	};
}
```

*Request*:

- method: ‘window/showMessageRequest’
- params: [`ShowMessageRequestParams`](#showMessageRequestParams) defined as follows: <a id="showMessageRequestParams"></a>
```typescript
interface ShowMessageRequestParams {
	/**
	 * The message type. See {@link MessageType}
	 */
	type: MessageType;

	/**
	 * The actual message
	 */
	message: string;

	/**
	 * The message action items to present.
	 */
	actions?: MessageActionItem[];
}
```

Where the [`MessageActionItem`](#messageActionItem) is defined as follows: <a id="messageActionItem"></a>
```typescript
interface MessageActionItem {
	/**
	 * A short title like 'Retry', 'Open Log' etc.
	 */
	title: string;
}
```

*Response*:

- result: the selected [`MessageActionItem`](#messageActionItem) | `null` if none got selected. <a id="messageActionItem"></a>
- error: code and message set in case an exception happens during showing a message.

#### Show Document Request

> New in version 3.16.0

The show document request is sent from a server to a client to ask the client to display a particular resource referenced by a URI in the user interface.

*Client Capability*:

- property path (optional): `window.showDocument`
- property type: [`ShowDocumentClientCapabilities`](#windowshowDocument) defined as follows: <a id="windowshowDocument"></a>

```typescript
/**
 * Client capabilities for the show document request.
 *
 * @since 3.16.0
 */
export interface ShowDocumentClientCapabilities {
	/**
	 * The client has support for the show document
	 * request.
	 */
	support: boolean;
}
```

*Request*:

- method: ‘window/showDocument’
- params: [`ShowDocumentParams`](#showDocumentParams) defined as follows: <a id="showDocumentParams"></a>
```typescript
/**
 * Params to show a resource.
 *
 * @since 3.16.0
 */
export interface ShowDocumentParams {
	/**
	 * The uri to show.
	 */
	uri: URI;

	/**
	 * Indicates to show the resource in an external program.
	 * To show, for example, \`https://code.visualstudio.com/\`
	 * in the default WEB browser set \`external\` to \`true\`.
	 */
	external?: boolean;

	/**
	 * An optional property to indicate whether the editor
	 * showing the document should take focus or not.
	 * Clients might ignore this property if an external
	 * program is started.
	 */
	takeFocus?: boolean;

	/**
	 * An optional selection range if the document is a text
	 * document. Clients might ignore the property if an
	 * external program is started or the file is not a text
	 * file.
	 */
	selection?: Range;
}
```

*Response*:

- result: [`ShowDocumentResult`](#showDocumentResult) defined as follows: <a id="showDocumentResult"></a>
```typescript
/**
 * The result of an show document request.
 *
 * @since 3.16.0
 */
export interface ShowDocumentResult {
	/**
	 * A boolean indicating if the show was successful.
	 */
	success: boolean;
}
```

- error: code and message set in case an exception happens during showing a document.

#### LogMessage Notification

The log message notification is sent from the server to the client to ask the client to log a particular message.

*Notification*:

- method: ‘window/logMessage’
- params: [`LogMessageParams`](#logMessageParams) defined as follows: <a id="logMessageParams"></a>
```typescript
interface LogMessageParams {
	/**
	 * The message type. See {@link MessageType}
	 */
	type: MessageType;

	/**
	 * The actual message
	 */
	message: string;
}
```

#### Create Work Done Progress

The `window/workDoneProgress/create` request is sent from the server to the client to ask the client to create a work done progress.

*Client Capability*:

- property name (optional): `window.workDoneProgress`
- property type: `boolean`

*Request*:

- method: ‘window/workDoneProgress/create’
- params: [`WorkDoneProgressCreateParams`](#work-done-progress) defined as follows:

```typescript
export interface WorkDoneProgressCreateParams {
	/**
	 * The token to be used to report progress.
	 */
	token: ProgressToken;
}
```

*Response*:

- result: void
- error: code and message set in case an exception happens during the ‘window/workDoneProgress/create’ request. In case an error occurs a server must not send any progress notification using the token provided in the [`WorkDoneProgressCreateParams`](#work-done-progress).

#### Cancel a Work Done Progress

The `window/workDoneProgress/cancel` notification is sent from the client to the server to cancel a progress initiated on the server side using the `window/workDoneProgress/create`. The progress need not be marked as `cancellable` to be cancelled and a client may cancel a progress for any number of reasons: in case of error, reloading a workspace etc.

*Notification*:

- method: ‘window/workDoneProgress/cancel’
- params: [`WorkDoneProgressCancelParams`](#work-done-progress) defined as follows:

```typescript
export interface WorkDoneProgressCancelParams {
	/**
	 * The token to be used to report progress.
	 */
	token: ProgressToken;
}
```

#### Telemetry Notification

The telemetry notification is sent from the server to the client to ask the client to log a telemetry event. The protocol doesn’t specify the payload since no interpretation of the data happens in the protocol. Most clients even don’t handle the event directly but forward them to the extensions owing the corresponding server issuing the event.

*Notification*:

- method: ‘telemetry/event’
- params: ‘object’ | ‘array’;

#### Miscellaneous
#### Implementation Considerations

Language servers usually run in a separate process and clients communicate with them in an asynchronous fashion. Additionally clients usually allow users to interact with the source code even if request results are pending. We recommend the following implementation pattern to avoid that clients apply outdated response results:

- if a client sends a request to the server and the client state changes in a way that it invalidates the response it should do the following:
- cancel the server request and ignore the result if the result is not useful for the client anymore. If necessary the client should resend the request.
- keep the request running if the client can still make use of the result by, for example, transforming it to a new result by applying the state change to the result.
- servers should therefore not decide by themselves to cancel requests simply due to that fact that a state change notification is detected in the queue. As said the result could still be useful for the client.
- if a server detects an internal state change (for example, a project context changed) that invalidates the result of a request in execution the server can error these requests with `ContentModified`. If clients receive a `ContentModified` error, it generally should not show it in the UI for the end-user. Clients can resend the request if they know how to do so. It should be noted that for all position based requests it might be especially hard for clients to re-craft a request.
- a client should not send resolve requests for out of date objects (for example, code lenses, …). If a server receives a resolve request for an out of date object the server can error these requests with `ContentModified`.
- if a client notices that a server exits unexpectedly, it should try to restart the server. However clients should be careful not to restart a crashing server endlessly. VS Code, for example, doesn’t restart a server which has crashed 5 times in the last 180 seconds.

Servers usually support different communication channels (e.g. stdio, pipes, …). To ease the usage of servers in different clients it is highly recommended that a server implementation supports the following command line arguments to pick the communication channel:

- **stdio**: uses stdio as the communication channel.
- **pipe**: use pipes (Windows) or socket files (Linux, Mac) as the communication channel. The pipe / socket file name is passed as the next arg or with `--pipe=`.
- **socket**: uses a socket as the communication channel. The port is passed as next arg or with `--port=`.
- **node-ipc**: use node IPC communication between the client and the server. This is only supported if both client and server run under node.

To support the case that the editor starting a server crashes an editor should also pass its process id to the server. This allows the server to monitor the editor process and to shutdown itself if the editor process dies. The process id passed on the command line should be the same as the one passed in the initialize parameters. The command line argument to use is `--clientProcessId`.

#### Meta Model

Since 3.17 there is a meta model describing the LSP protocol:

- [metaModel.json](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/metaModel/metaModel.json): The actual meta model for the LSP 3.17 specification
- [metaModel.ts](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/metaModel/metaModel.ts): A TypeScript file defining the data types that make up the meta model.
- [metaModel.schema.json](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/metaModel/metaModel.schema.json): A JSON schema file defining the data types that make up the meta model. Can be used to generate code to read the meta model JSON file.

### Change Log
#### 3.17.0 (05/10/2022)

- Specify how clients will handle stale requests.
- Add support for a completion item label details.
- Add support for workspace symbol resolve request.
- Add support for label details and insert text mode on completion items.
- Add support for shared values on CompletionItemList.
- Add support for HTML tags in Markdown.
- Add support for collapsed text in folding.
- Add support for trigger kinds on code action requests.
- Add the following support to semantic tokens:
- server cancelable
- augmentation of syntax tokens
- Add support to negotiate the position encoding.
- Add support for relative patterns in file watchers.
- Add support for type hierarchies
- Add support for inline values.
- Add support for inlay hints.
- Add support for notebook documents.
- Add support for diagnostic pull model.

#### 3.16.0 (12/14/2020)

- Add support for tracing.
- Add semantic token support.
- Add call hierarchy support.
- Add client capability for resolving text edits on completion items.
- Add support for client default behavior on renames.
- Add support for insert and replace ranges on [`CompletionItem`](#completion-item-resolve-request).
- Add support for diagnostic code descriptions.
- Add support for document symbol provider label.
- Add support for tags on [`SymbolInformation`](#symbolInformation) and [`DocumentSymbol`](#document-symbols-request). <a id="symbolInformation"></a>
- Add support for moniker request method.
- Add support for code action `data` property.
- Add support for code action `disabled` property.
- Add support for code action resolve request.
- Add support for diagnostic `data` property.
- Add support for signature information `activeParameter` property.
- Add support for [`workspace/didCreateFiles`](#didcreatefiles-notification) notifications and [`workspace/willCreateFiles`](#willcreatefiles-request) requests.
- Add support for [`workspace/didRenameFiles`](#didrenamefiles-notification) notifications and [`workspace/willRenameFiles`](#willrenamefiles-request) requests.
- Add support for [`workspace/didDeleteFiles`](#diddeletefiles-notification) notifications and [`workspace/willDeleteFiles`](#willdeletefiles-request) requests.
- Add client capability to signal whether the client normalizes line endings.
- Add support to preserve additional attributes on [`MessageActionItem`](#messageActionItem). <a id="messageActionItem"></a>
- Add support to provide the clients locale in the initialize call.
- Add support for opening and showing a document in the client user interface.
- Add support for linked editing.
- Add support for change annotations in text edits as well as in create file, rename file and delete file operations.

#### 3.15.0 (01/14/2020)

- Add generic progress reporting support.
- Add specific work done progress reporting support to requests where applicable.
- Add specific partial result progress support to requests where applicable.
- Add support for [`textDocument/selectionRange`](#selection-range-request).
- Add support for server and client information.
- Add signature help context.
- Add Erlang and Elixir to the list of supported programming languages
- Add `version` on [`PublishDiagnosticsParams`](#diagnostic)
- Add `CodeAction#isPreferred` support.
- Add `CompletionItem#tag` support.
- Add `Diagnostic#tag` support.
- Add `DocumentLink#tooltip` support.
- Add `trimTrailingWhitespace`, `insertFinalNewline` and `trimFinalNewlines` to [`FormattingOptions`](#formattingOptions). <a id="formattingOptions"></a>
- Clarified `WorkspaceSymbolParams#query` parameter.

#### 3.14.0 (12/13/2018)

- Add support for signature label offsets.
- Add support for location links.
- Add support for [`textDocument/declaration`](#textDocumentdeclaration) request. <a id="textDocumentdeclaration"></a>

#### 3.13.0 (9/11/2018)

- Add support for file and folder operations (create, rename, move) to workspace edits.

#### 3.12.0 (8/23/2018)

- Add support for [`textDocument/prepareRename`](#prepare-rename-request) request.

#### 3.11.0 (8/21/2018)

- Add support for CodeActionOptions to allow a server to provide a list of code action it supports.

#### 3.10.0 (7/23/2018)

- Add support for hierarchical document symbols as a valid response to a [`textDocument/documentSymbol`](#textDocumentdocumentSymbol) request. <a id="textDocumentdocumentSymbol"></a>
- Add support for folding ranges as a valid response to a [`textDocument/foldingRange`](#folding-range-request) request.

#### 3.9.0 (7/10/2018)

- Add support for `preselect` property in [`CompletionItem`](#completion-item-resolve-request)

#### 3.8.0 (6/11/2018)

- Added support for CodeAction literals to the [`textDocument/codeAction`](#code-action-request) request.
- ColorServerCapabilities.colorProvider can also be a boolean
- Corrected ColorPresentationParams.colorInfo to color (as in the `d.ts` and in implementations)

#### 3.7.0 (4/5/2018)

- Added support for related information to Diagnostics.

#### 3.6.0 (2/22/2018)

Merge the proposed protocol for workspace folders, configuration, go to type definition, go to implementation and document color provider into the main branch of the specification. For details see:

- [Get Workspace Folders](https://microsoft.github.io/language-server-protocol/specification#workspace_workspaceFolders)
- [DidChangeWorkspaceFolders Notification](https://microsoft.github.io/language-server-protocol/specification#workspace_didChangeWorkspaceFolders)
- [Get Configuration](https://microsoft.github.io/language-server-protocol/specification#workspace_configuration)
- [Go to Type Definition](https://microsoft.github.io/language-server-protocol/specification#textDocument_typeDefinition)
- [Go to Implementation](https://microsoft.github.io/language-server-protocol/specification#textDocument_implementation)
- [Document Color](https://microsoft.github.io/language-server-protocol/specification#textDocument_documentColor)
- [Color Presentation](https://microsoft.github.io/language-server-protocol/specification#textDocument_colorPresentation)

In addition we enhanced the [`CompletionTriggerKind`](#completionTriggerKind) with a new value `TriggerForIncompleteCompletions: 3 = 3` to signal the a completion request got trigger since the last result was incomplete. <a id="completionTriggerKind"></a>

#### 3.5.0

Decided to skip this version to bring the protocol version number in sync the with npm module vscode-languageserver-protocol.

#### 3.4.0 (11/27/2017)

- [extensible completion item and symbol kinds](https://github.com/Microsoft/language-server-protocol/issues/129)

#### [3.3.0 (11/24/2017)](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/version_3_3_0)

- Added support for [`CompletionContext`](#completionContext) <a id="completionContext"></a>
- Added support for [`MarkupContent`](#markupContentInnerDefinition) <a id="markupContentInnerDefinition"></a>
- Removed old New and Updated markers.

#### [3.2.0 (09/26/2017)](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/version_3_2_0)

- Added optional `commitCharacters` property to the [`CompletionItem`](#completion-item-resolve-request)

#### [3.1.0 (02/28/2017)](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/version_3_1_0)

- Make the [`WorkspaceEdit`](#workspaceedit) changes backwards compatible.
- Updated the specification to correctly describe the breaking changes from 2.x to 3.x around [`WorkspaceEdit`](#workspaceedit)and [`TextDocumentEdit`](#textdocumentedit).

#### 3.0 Version

- add support for client feature flags to support that servers can adapt to different client capabilities. An example is the new [`textDocument/willSaveWaitUntil`](#willsavewaituntiltextdocument-request) request which not all clients might be able to support. If the feature is disabled in the client capabilities sent on the initialize request, the server can’t rely on receiving the request.
- add support to experiment with new features. The new `ClientCapabilities.experimental` section together with feature flags allow servers to provide experimental feature without the need of ALL clients to adopt them immediately.
- servers can more dynamically react to client features. Capabilities can now be registered and unregistered after the initialize request using the new `client/registerCapability` and `client/unregisterCapability`. This for example allows servers to react to settings or configuration changes without a restart.
- add support for [`textDocument/willSave`](#willsavetextdocument-notification) notification and [`textDocument/willSaveWaitUntil`](#willsavewaituntiltextdocument-request) request.
- add support for [`textDocument/documentLink`](#document-link-request) request.
- add a `rootUri` property to the initializeParams in favor of the `rootPath` property.
