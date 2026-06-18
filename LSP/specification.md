# Language Server Protocol Specification - 3.18

This document describes the current 3.18.x version of the language server protocol and is under development. An implementation for node of the 3.18.x version of the protocol can be found [here](https://github.com/Microsoft/vscode-languageserver-node).

**Note:** edits to this specification can be made via a pull request against this markdown [document](https://github.com/Microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.18/specification.md).

## What's new in 3.18

All new 3.18 features are tagged with a corresponding since version 3.18 text or in JSDoc using `@since 3.18.0` annotation.

A detailed list of the changes can be found in the [change log](#3180-06042026)

The version of the specification is used to group features into a new specification release and to refer to their first appearance. Features in the spec are kept compatible using so called capability flags which are exchanged between the client and the server during initialization.

## Base Protocol

The base protocol consists of a header and a content part (comparable to HTTP). The header and content part are
separated by a '\r\n'.

### Header Part

The header part consists of header fields. Each header field is comprised of a name and a value, separated by ': ' (a colon and a space). The structure of header fields conforms to the [HTTP semantic](https://tools.ietf.org/html/rfc7230#section-3.2). Each header field is terminated by '\r\n'. Considering the last header field and the overall header itself are each terminated with '\r\n', and that at least one header is mandatory, this means that two '\r\n' sequences always immediately precede the content part of a message.

Currently the following header fields are supported:

| Header Field Name | Value Type | Description |
| :------------------ | :------------ | :------------ |
| Content-Length | number | The length of the content part in bytes. This header is required. |
| Content-Type | string | The mime type of the content part. Defaults to application/vscode-jsonrpc; charset=utf-8 |

The header part is encoded using the 'ascii' encoding. This includes the '\r\n' separating the header and content part.

### Content Part

Contains the actual content of the message. The content part of a message uses [JSON-RPC 2.0](https://www.jsonrpc.org/specification) to describe requests, responses and notifications. The content part is encoded using the charset provided in the Content-Type field. It defaults to `utf-8`, which is the only encoding supported right now. If a server or client receives a header with a different encoding than `utf-8` it should respond with an error.

(Prior versions of the protocol used the string constant `utf8` which is not a correct encoding constant according to [specification](https://www.iana.org/assignments/character-sets/character-sets.xhtml).) For backwards compatibility it is highly recommended that a client and a server treat the string `utf8` as `utf-8`.

### Example:

```
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

The protocol uses request, response, and notification objects as specified in the [JSON-RPC protocol](https://www.jsonrpc.org/specification). The protocol currently does not support JSON-RPC batch messages; protocol clients and servers must not send JSON-RPC requests.

The following TypeScript definitions describe the base JSON-RPC protocol:

#### Base Types

The protocol uses the following definitions for integers, unsigned integers, decimal numbers, objects and arrays:

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
 * rare in the language server specification, we denote the
 * exact range with every decimal using the mathematics
 * interval notation (e.g., [0, 1] denotes all decimals d with
 * 0 <= d <= 1.)
 */
export type decimal = number;
```

```typescript
/**
 * The LSP any type.
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

A general message as defined by JSON-RPC. The language server protocol always uses "2.0" as the `jsonrpc` version.

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

A Response Message sent as a result of a request. If a request doesn't provide a result value the receiver of a request still needs to return a response message to conform to the JSON-RPC specification. The result property of the ResponseMessage should be set to `null` in this case to signal a successful request.

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
	 * compatibility the `ServerNotInitialized` and the `UnknownErrorCode`
	 * are left in the range.
	 *
	 * @since 3.16.0
	 */
	export const jsonrpcReservedErrorRangeStart: integer = -32099;
	/** @deprecated use jsonrpcReservedErrorRangeStart */
	export const serverErrorStart: integer = jsonrpcReservedErrorRangeStart;

	/**
	 * Error code indicating that a server received a notification or
	 * request before the server received the `initialize` request.
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
	 * in its unprocessed messages. The result even computed
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

Notifications and requests whose methods start with '\$/' are messages which are protocol implementation dependent and might not be implementable in all clients or servers. For example if the server implementation uses a single threaded synchronous programming language then there is little a server can do to react to a `$/cancelRequest` notification. If a server or client receives notifications starting with '\$/' it is free to ignore the notification. If a server or client receives a request starting with '\$/' it must error the request with error code `MethodNotFound` (e.g. `-32601`).

#### Cancellation Support

The base protocol offers support for request cancellation. To cancel a request, a notification message with the following properties is sent:

_Notification_:
- method: '$/cancelRequest'
- params: `CancelParams` defined as follows:

```typescript
interface CancelParams {
	/**
	 * The request id to cancel.
	 */
	id: integer | string;
}
```

A request that got canceled still needs to return from the server and send a response back. It can not be left open / hanging. This is in line with the JSON-RPC protocol that requires that every request sends a response back. In addition, it allows for returning partial results on cancel. If the request returns an error response on cancellation it is advised to set the error code to `ErrorCodes.RequestCancelled`.

#### Progress Support

> *Since version 3.15.0*

The base protocol also offers support to report progress in a generic fashion. This mechanism can be used to report any kind of progress including [work done progress](#work-done-progress) (usually used to report progress in the user interface using a progress bar) and partial result progress to support streaming of results.

A progress notification has the following properties:

_Notification_:
- method: '$/progress'
- params: `ProgressParams` defined as follows:

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

The language server protocol defines a set of JSON-RPC request, response and notification messages which are exchanged using the above base protocol. This section starts describing the basic JSON structures used in the protocol. The document uses TypeScript interfaces in strict mode to describe these. This means, for example, that a `null` value has to be explicitly listed and that a mandatory property must be listed even if a falsy value might exist. Based on the basic JSON structures, the actual requests with their responses and the notifications are described.

An example would be a request sent from the client to the server to request a hover value for a symbol at a certain position in a text document. The request's method would be `textDocument/hover` with a parameter like this:

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

Please also note that a response return value of `null` indicates no result. It doesn't tell the client to resend the request.

In general, the language server protocol supports JSON-RPC messages, however the base protocol defined here uses a convention such that the parameters passed to request/notification messages should be of `object` type (if passed at all). However, this does not disallow using `Array` parameter types in custom messages.

The protocol currently assumes that one server serves one tool. There is currently no support in the protocol to share one server between different tools. Such sharing would require additional protocol e.g. to lock a document to support concurrent editing.

### Capabilities

Not every language server can support all features defined by the protocol. LSP therefore provides ‘capabilities’. A capability groups a set of language features. A development tool and the language server announce their supported features using capabilities. As an example, a server announces that it can handle the `textDocument/hover` request, but it might not handle the `workspace/symbol` request. Similarly, a development tool announces its ability to provide `about to save` notifications before a document is saved, so that a server can compute textual edits to format the edited document before it is saved.

The set of capabilities is exchanged between the client and server during the [initialize](#initialize-request) request.

### Request, Notification and Response Ordering

Responses to requests should be sent in roughly the same order as the requests appear on the server or client side. So, for example, if a server receives a `textDocument/completion` request and then a `textDocument/signatureHelp` request it will usually first return the response for the `textDocument/completion` and then the response for `textDocument/signatureHelp`.

However, the server may decide to use a parallel execution strategy and may wish to return responses in a different order than the requests were received. The server may do so as long as this reordering doesn't affect the correctness of the responses. For example, reordering the result of `textDocument/completion` and `textDocument/signatureHelp` is allowed, as each of these requests usually won't affect the output of the other. On the other hand, the server most likely should not reorder `textDocument/definition` and `textDocument/rename` requests, since executing the latter may affect the result of the former.

### Message Documentation

As said, LSP defines a set of requests, responses and notifications. Each of those are documented using the following format:

- a header describing the request
- an optional _Client Capability_ section describing the client capability of the request. This includes the client capabilities property path and JSON structure.
- an optional _Server Capability_ section describing the server capability of the request. This includes the server capabilities property path and JSON structure. Clients should ignore server capabilities they don't understand (e.g. the initialize request shouldn't fail in this case).
- an optional _Registration Options_ section describing the registration option if the request or notification supports dynamic capability registration. See the [register](#register-capability) and [unregister](#unregister-capability) request for how this works in detail.
- a _Request_ section describing the format of the request sent. The method is a string identifying the request, the params are documented using a TypeScript interface. It is also documented whether the request supports work done progress and partial result progress.
- a _Response_ section describing the format of the response. The result item describes the returned data in case of a success. The optional partial result item describes the returned data of a partial result notification. The error.data describes the returned data in case of an error. Please remember that in case of a failure the response already contains an error.code and an error.message field. These fields are only specified if the protocol forces the use of certain error codes or messages. In cases where the server can decide on these values freely they aren't listed here.

### Basic JSON Structures

There are quite some JSON structures that are shared between different requests and notifications. Their structure and capabilities are documented in this section.

#### URI

URI's are transferred as strings. The URI's format is defined in [https://tools.ietf.org/html/rfc3986](https://tools.ietf.org/html/rfc3986)

```
  foo://example.com:8042/over/there?name=ferret#nose
  \_/   \______________/\_________/ \_________/ \__/
   |           |            |            |        |
scheme     authority       path        query   fragment
   |   _____________________|__
  / \ /                        \
  urn:example:animal:ferret:nose
```

We also maintain a node module to parse a string into `scheme`, `authority`, `path`, `query`, and `fragment` URI components. The GitHub repository is [https://github.com/Microsoft/vscode-uri](https://github.com/Microsoft/vscode-uri), and the npm module is [https://www.npmjs.com/package/vscode-uri](https://www.npmjs.com/package/vscode-uri).

Many of the interfaces contain fields that correspond to the URI of a document. For clarity, the type of such a field is declared as a `DocumentUri`. Over the wire, it will still be transferred as a string, but this guarantees that the contents of that string can be parsed as a valid URI.

Care should be taken to handle encoding in URIs. For example, some clients (such as VS Code) may encode colons in drive letters while others do not. The URIs below are both valid, but clients and servers should be consistent with the form they use themselves to ensure the other party doesn't interpret them as distinct URIs. Clients and servers should not assume that each other are encoding the same way (for example a client encoding colons in drive letters cannot assume server responses will have encoded colons). The same applies to casing of drive letters - one party should not assume the other party will return paths with drive letters cased the same as itself.

```
file:///c:/project/readme.md
file:///C%3A/project/readme.md
```

```typescript
type DocumentUri = string;
```

There is also a tagging interface for normal non document URIs. It maps to a `string` as well.

```typescript
type URI = string;
```

#### Regular Expressions

Regular expression are a powerful tool and there are actual use cases for them in the language server protocol. However, the downside with them is that almost every programming language has its own set of regular expression features, so the specification cannot simply refer to them as a regular expression. For this reason, the LSP uses a two step approach to support regular expressions:

- The client will announce which regular expression engine it will use. This will allow servers that are written for a very specific client to make full use of the regular expression capabilities of that client.
- The specification will define a set of regular expression features that should be supported by a client. Instead of writing a new specification LSP will refer to the [ECMAScript Regular Expression specification](https://tc39.es/ecma262/#sec-regexp-regular-expression-objects) and remove features from it that are not necessary in the context of LSP or are hard to implement for other clients.

_Client Capability_:

The following client capability is used to announce a client's regular expression engine

- property path (optional): `general.regularExpressions`
- property type: `RegularExpressionsClientCapabilities` defined as follows:

```typescript
/**
 * Regular Expression Engines
 *
 * @since 3.18.0
 */
export namespace RegularExpressionEngineKind {
	export const ES2020 = 'ES2020' as const;
}
export type RegularExpressionEngineKind = string;

/**
 * Client capabilities specific to regular expressions.
 */
export interface RegularExpressionsClientCapabilities {
	/**
	 * The engine's name.
	 */
	engine: RegularExpressionEngineKind;

	/**
	 * The engine's version.
	 */
	version?: string;
}
```

The following table lists the well known engine values. Please note that the table should be driven by the community which integrates the LSP into existing clients. It is not the goal of the spec to list all available regular expression engines.

| Engine | Version | Documentation |
| ------- | ------- | ------------- |
| ECMAScript | `ES2020` | [ECMAScript 2020](https://tc39.es/ecma262/#sec-regexp-regular-expression-objects) & [MDN](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Regular_Expressions) |

_Regular Expression Subset_:

The following features from the [ECMAScript 2020](https://tc39.es/ecma262/#sec-regexp-regular-expression-objects) regular expression specification are NOT mandatory for a client:

- *Assertions*: lookahead assertion, negative lookahead assertion, lookbehind assertion, negative lookbehind assertion.
- *Character classes*: matching control characters using caret notation (e.g. `\cX`) and matching UTF-16 code units (e.g. `\uhhhh`).
- *Group and ranges*: named capturing groups.
- *Unicode property escapes*: none of the features need to be supported.

The only regular expression flag that a client needs to support is `i` to specify a case insensitive search.

#### Enumerations

The protocol supports two kind of enumerations: (a) integer based enumerations and (b) string based enumerations. Integer based enumerations usually start with `1`. The ones that don't are historical and they were kept to stay backwards compatible. If appropriate, the value set of an enumeration is announced by the defining side (e.g. client or server) and transmitted to the other side during the initialize handshake. An example is the `CompletionItemKind` enumeration. It is announced by the client using the `textDocument.completion.completionItemKind` client property.

To support the evolution of enumerations the using side of an enumeration shouldn't fail on an enumeration value it doesn't know. It should simply ignore it as a value it can use and try to do its best to preserve the value on round trips. Lets look at the `CompletionItemKind` enumeration as an example again: if in a future version of the specification an additional completion item kind with the value `n` gets added and announced by a client an (older) server not knowing about the value should not fail but simply ignore the value as a usable item kind.

#### Text Documents

The current protocol is tailored for textual documents whose content can be represented as a string. There is currently no support for binary documents. A position inside a document (see Position definition below) is expressed as a zero-based line and character offset.

##### New in 3.17

Prior to 3.17 the offsets were always based on a UTF-16 string representation. So in a string of the form `a𐐀b` the character offset of the character `a` is 0, the character offset of `𐐀` is 1 and the character offset of b is 3 since `𐐀` is represented using two code units in UTF-16. Since 3.17 clients and servers can agree on a different string encoding representation (e.g. UTF-8). The client announces its supported encoding via the client capability `general.positionEncodings`. The value is an array of position encodings the client supports, with decreasing preference (e.g. the encoding at index `0` is the most preferred one). To stay backwards compatible the only mandatory encoding is UTF-16 represented via the string `utf-16`. The server can pick one of the encodings offered by the client and signals that encoding back to the client via the initialize result's property `capabilities.positionEncoding`. If the string value `utf-16` is missing from the client's capability `general.positionEncodings` servers can safely assume that the client supports UTF-16. If the server omits the position encoding in its initialize result the encoding defaults to the string value `utf-16`. Implementation considerations: since the conversion from one encoding into another requires the content of the file / line the conversion is best done where the file is read which is usually on the server side.

To ensure that both client and server split the string into the same line representation the protocol specifies the following end-of-line sequences: '\n', '\r\n' and '\r'. Positions are line end character agnostic, so you cannot specify a position that denotes `\r|\n` or `\n|` where `|` represents the character offset.

```typescript
export const EOL: string[] = ['\n', '\r\n', '\r'];
```

#### Position

Position in a text document expressed as zero-based line and zero-based character offset. A position is between two characters like an 'insert' cursor in an editor. Special values, like `-1` to denote the end of a line, are not supported.

```typescript
interface Position {
	/**
	 * Line position in a document (zero-based).
	 */
	line: uinteger;

	/**
	 * Character offset on a line in a document (zero-based). The meaning of this
	 * offset is determined by the negotiated `PositionEncodingKind`.
	 *
	 * If the character value is greater than the line length it defaults back
	 * to the line length.
	 */
	character: uinteger;
}
```

When describing positions, the protocol needs to specify how offsets (specifically character offsets) should be interpreted.
The corresponding `PositionEncodingKind` is negotiated between the client and the server during initialization.

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
	 * Character offsets count UTF-8 code units (i.e. bytes).
	 */
	export const UTF8: PositionEncodingKind = 'utf-8';

	/**
	 * Character offsets count UTF-16 code units.
	 *
	 * This is the default and must always be supported
	 * by servers.
	 */
	export const UTF16: PositionEncodingKind = 'utf-16';

	/**
	 * Character offsets count UTF-32 code units.
	 *
	 * Implementation note: these are the same as Unicode code points,
	 * so this `PositionEncodingKind` may also be used for an
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
| -------- | ---------- |
| ABAP | `abap` |
| Windows Bat | `bat` |
| BibTeX | `bibtex` |
| Clojure | `clojure` |
| Coffeescript | `coffeescript` |
| C | `c` |
| C++ | `cpp` |
| C# | `csharp` |
| CSS | `css` |
| D | `d` (@since 3.18.0) |
| Delphi | `pascal` (@since 3.18.0) |
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
| Haskell | `haskell` |
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
| Pascal | `pascal` (@since 3.18.0) |
| Perl | `perl` |
| Perl 6 | `perl6` |
| PHP | `php` |
| Plaintext | `plaintext` |
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
| Text (plain) | `plaintext` |
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
	 * before) the server can send `null` to indicate that the version is
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

A parameter literal used in requests to pass a text document and a position inside that document. It is up to the client to decide how a selection is converted into a position when issuing a request for a text document. The client can, for example, honor or ignore the selection direction to make LSP request consistent with features implemented internally.

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

#### Patterns

Pattern definitions used in file watchers and document filters.

```typescript
/**
 * The pattern to watch relative to the base path. Glob patterns can have
 * the following syntax:
 * - `*` to match zero or more characters in a path segment
 * - `?` to match on one character in a path segment
 * - `**` to match any number of path segments, including none
 * - `{}` to group conditions (e.g. `**​/*.{ts,js}` matches all TypeScript
 *   and JavaScript files)
 * - `[]` to declare a range of characters to match in a path segment
 *   (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
 * - `[!...]` to negate a range of characters to match in a path segment
 *   (e.g., `example.[!0-9]` to match on `example.a`, `example.b`,
 *   but not `example.0`)
 *
 * @since 3.17.0
 */
export type Pattern = string;
```

```typescript
/**
 * A relative pattern is a helper to construct glob patterns that are matched
 * relatively to a base URI. The common value for a `baseUri` is a workspace
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
	 * The actual pattern;
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

#### DocumentFilter

A document filter denotes a document through properties like `language`, `scheme` or `pattern`. An example is a filter that applies to TypeScript files on disk. Another example is a filter that applies to JSON files with name `package.json`:

```typescript
{ language: 'typescript', scheme: 'file' }
{ language: 'json', pattern: '**/package.json' }
```

```typescript
/**
 * A document filter where `language` is required field.
 */
export type TextDocumentFilterLanguage = {
	/**
	 * A language id, like `typescript`.
	 */
	language: string;

	/**
	 * A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	 */
	scheme?: string;

	/**
	 * A glob pattern, like **​/*.{ts,js}. See TextDocumentFilter for examples.
	 *
	 * @since 3.18.0 - support for relative patterns. Whether clients support
	 * relative patterns depends on the client capability
	 * `textDocuments.filters.relativePatternSupport`.
	 */
	pattern?: GlobPattern;
};

/**
 * A document filter where `scheme` is required field.
 */
export type TextDocumentFilterScheme = {
	/**
	 * A language id, like `typescript`.
	 */
	language?: string;

	/**
	 * A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	 */
	scheme: string;

	/**
	 * A glob pattern, like **​/*.{ts,js}. See TextDocumentFilter for examples.
	 *
	 * @since 3.18.0 - support for relative patterns. Whether clients support
	 * relative patterns depends on the client capability
	 * `textDocuments.filters.relativePatternSupport`.
	 */
	pattern?: GlobPattern;
};

/**
 * A document filter where `pattern` is required field.
 */
export type TextDocumentFilterPattern = {
	/**
	 * A language id, like `typescript`.
	 */
	language?: string;

	/**
	 * A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	 */
	scheme?: string;

	/**
	 * A glob pattern, like **​/*.{ts,js}. See TextDocumentFilter for examples.
	 *
	 * @since 3.18.0 - support for relative patterns. Whether clients support
	 * relative patterns depends on the client capability
	 * `textDocuments.filters.relativePatternSupport`.
	 */
	pattern: GlobPattern;
};

/**
 * A document filter denotes a document by different properties like
 * the {@link TextDocument.languageId language}, the {@link Uri.scheme scheme}
 * of its resource, or a glob-pattern that is applied to
 * the {@link TextDocument.fileName path}.
 *
 * Glob patterns can have the following syntax:
 * - `*` to match zero or more characters in a path segment
 * - `?` to match on one character in a path segment
 * - `**` to match any number of path segments, including none
 * - `{}` to group sub patterns into an OR expression. (e.g. `**​/*.{ts,js}`
 *   matches all TypeScript and JavaScript files)
 * - `[]` to declare a range of characters to match in a path segment
 *   (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
 * - `[!...]` to negate a range of characters to match in a path segment
 *   (e.g., `example.[!0-9]` to match on `example.a`, `example.b`,
 *   but not `example.0`)
 *
 * @sample A language filter that applies to typescript files on disk:
 *   `{ language: 'typescript', scheme: 'file' }`
 * @sample A language filter that applies to all package.json paths:
 *   `{ language: 'json', pattern: '**package.json' }`
 */
export type TextDocumentFilter = TextDocumentFilterLanguage |
	TextDocumentFilterScheme | TextDocumentFilterPattern;

/**
 * A document filter describes a top level text document or
 * a notebook cell document.
 *
 * @since 3.17.0 - support for NotebookCellTextDocumentFilter.
 */
export type DocumentFilter = TextDocumentFilter | NotebookCellTextDocumentFilter;
```

A document selector is the combination of one or more document filters.

```typescript
export type DocumentSelector = DocumentFilter[];
```

#### String Value

Template strings for inserting text and controlling the editor cursor upon insertion.

```typescript
/**
 * A string value used as a snippet is a template which allows to insert text
 * and to control the editor cursor when insertion happens.
 *
 * A snippet can define tab stops and placeholders with `$1`, `$2`
 * and `${3:foo}`. `$0` defines the final tab stop, it defaults to
 * the end of the snippet. Variables are defined with `$name` and
 * `${name:default value}`.
 *
 * @since 3.18.0
 */
export interface StringValue {
	/**
	 * The kind of string value.
	 */
	kind: 'snippet';

	/**
	 * The snippet string.
	 */
	value: string;
}
```

#### TextEdit, AnnotatedTextEdit & SnippetTextEdit

- New in version 3.16: Support for `AnnotatedTextEdit`.
- New in version 3.18: Support for `SnippetTextEdit`.

A textual edit applicable to a text document.

```typescript
interface TextEdit {
	/**
	 * The range of the text document to be manipulated. To insert
	 * text into a document, create a range where start === end.
	 */
	range: Range;

	/**
	 * The string to be inserted. For delete operations, use an
	 * empty string.
	 */
	newText: string;
}
```
Since 3.16.0 there is also the concept of an annotated text edit which supports adding an annotation to a text edit. The annotation can add information describing the change to the text edit.

```typescript
/**
 * Additional information that describes document changes.
 *
 * @since 3.16.0
 */
export interface ChangeAnnotation {
	/**
	 * A human-readable string describing the actual change. The string
	 * is rendered prominently in the user interface.
	 */
	label: string;

	/**
	 * A flag which indicates that user confirmation is needed
	 * before applying the change.
	 */
	needsConfirmation?: boolean;

	/**
	 * A human-readable string which is rendered less prominently in
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
```

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

Since 3.18.0, there is also the concept of a snippet text edit, which supports inserting a snippet instead of plain text.

Some important remarks:
- interactive snippets are only applied to the file opened in the active editor. This avoids unwanted focus switches or editor reveals.
- For the active file, only one snippet can specify a cursor position. In case there are multiple snippets defining a cursor position for a given URI, it is up to the client to decide the end position of the cursor.
- In case the snippet text edit corresponds to a file that is not currently open in the active editor, the client should downgrade the snippet to a non-interactive normal text edit and apply it to the file. This ensures that a workspace edit doesn't open arbitrary files.

```typescript
/**
 * An interactive text edit.
 *
 * @since 3.18.0
 */
export interface SnippetTextEdit {
	/**
	 * The range of the text document to be manipulated.
	 */
	range: Range;

	/**
	 * The snippet to be inserted.
	 */
	snippet: StringValue;

	/**
	 * The actual identifier of the snippet edit.
	 */
	annotationId?: ChangeAnnotationIdentifier;
}
```

#### TextEdit[]

Complex text manipulations are described with an array of `TextEdit`'s or `AnnotatedTextEdit`'s, representing a single change to the document.

All text edits ranges refer to positions in the document they are computed on. They therefore move a document from state S1 to S2 without describing any intermediate state. Text edits ranges must never overlap, that means no part of the original document must be manipulated by more than one edit. However, it is possible that multiple edits have the same start position: multiple inserts, or any number of inserts followed by a single remove or replace edit. If multiple inserts have the same position, the order in the array defines the order in which the inserted strings appear in the resulting text.

#### TextDocumentEdit

- New in version 3.16: support for `AnnotatedTextEdit`. The support is guarded by the client capability `workspace.workspaceEdit.changeAnnotationSupport`. If a client doesn't signal the capability, servers shouldn't send `AnnotatedTextEdit` literals back to the client.

- New in version 3.18: support for `SnippetTextEdit`. The support is guarded by the client capability `workspace.workspaceEdit.snippetEditSupport`. If a client doesn't signal the capability, servers shouldn't send `SnippetTextEdit` snippets back to the client.

Describes textual changes on a single text document. The text document is referred to as an `OptionalVersionedTextDocumentIdentifier` to allow clients to check the text document version before an edit is applied. A `TextDocumentEdit` describes all changes on a version Si and after they are applied move the document to version Si+1. So, the creator of a `TextDocumentEdit` doesn't need to sort the array of edits or do any kind of ordering. However, the edits must be non overlapping.

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
	 * client capability `workspace.workspaceEdit.changeAnnotationSupport`
	 *
	 * @since 3.18.0 - support for SnippetTextEdit. This is guarded by the
	 * client capability `workspace.workspaceEdit.snippetEditSupport`
	 */
	edits: (TextEdit | AnnotatedTextEdit | SnippetTextEdit)[];
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

```typescript
/**
 * Location with only uri and does not include range.
 */
export type LocationUriOnly = {
	uri: DocumentUri;
};
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
	 * The full target range of this link. If the target is, for example, a
	 * symbol, then the target range is the range enclosing this symbol not
	 * including leading/trailing whitespace but everything else like comments.
	 * This information is typically used to highlight the range in the editor.
	 */
	targetRange: Range;

	/**
	 * The range that should be selected and revealed when this link is being
	 * followed, e.g., the name of a function. Must be contained by the
	 * `targetRange`. See also `DocumentSymbol#range`
	 */
	targetSelectionRange: Range;
}
```

#### Diagnostic

- New in version 3.18: support for markup content in diagnostic messages. The support is guarded by the
client capability `textDocument.diagnostic.markupMessageSupport`. If a client doesn't signal the capability,
servers shouldn't send `MarkupContent` diagnostic messages back to the client.

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
	 *
	 * @since 3.18.0 - support for MarkupContent. This is guarded by the client
	 * capability `textDocument.diagnostic.markupMessageSupport`.
	 */
	message: string | MarkupContent;

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
	 * `textDocument/publishDiagnostics` notification and
	 * `textDocument/codeAction` request.
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
	 * Reports information.
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
	 * Clients are allowed to render diagnostics with this tag strike through.
	 */
	export const Deprecated: 2 = 2;
}

export type DiagnosticTag = 1 | 2;
```

`DiagnosticRelatedInformation` is defined as follows:

```typescript
/**
 * Represents a related message and source code location for a diagnostic.
 * This should be used to point to code locations that cause or are related to
 * a diagnostic, e.g. when duplicating a symbol in a scope.
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

`CodeDescription` is defined as follows:

```typescript
/**
 * Structure to capture a description for an error code.
 *
 * @since 3.16.0
 */
export interface CodeDescription {
	/**
	 * A URI to open with more information about the diagnostic error.
	 */
	href: URI;
}
```

#### Command

Represents a reference to a command. Provides a title which will be used to represent a command in the UI. Commands are identified by a string identifier. The recommended way to handle commands is to implement their execution on the server side if the client and server provide the corresponding capabilities. Alternatively, the tool extension code could handle the command. The protocol currently doesn't specify a set of well-known commands.

```typescript
interface Command {
	/**
	 * Title of the command, like `save`.
	 */
	title: string;

	/**
	 * An optional tooltip.
	 *
	 * @since 3.18.0
	 */
	tooltip?: string;

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

 A `MarkupContent` literal represents a string value whose content can be represented in different formats. Currently `plaintext` and `markdown` are supported formats. A `MarkupContent` is usually used in documentation properties of result literals like `CompletionItem` or `SignatureInformation`. If the format is `markdown` the content should follow the [GitHub Flavored Markdown Specification](https://github.github.com/gfm/).

```typescript
/**
 * Describes the content type that a client supports in various
 * result literals like `Hover`, `ParameterInfo` or `CompletionItem`.
 *
 * Please note that `MarkupKinds` must not start with a `$`. These kinds
 * are reserved for internal usage.
 */
export namespace MarkupKind {
	/**
	 * Plain text is supported as a content format.
	 */
	export const PlainText: 'plaintext' = 'plaintext';

	/**
	 * Markdown is supported as a content format.
	 */
	export const Markdown: 'markdown' = 'markdown';
}
export type MarkupKind = 'plaintext' | 'markdown';
```

```typescript
/**
 * A `MarkupContent` literal represents a string value whose content is
 * interpreted based on its kind flag. Currently, the protocol supports
 * `plaintext` and `markdown` as markup kinds.
 *
 * If the kind is `markdown` then the value can contain fenced code blocks like
 * in GitHub issues.
 *
 * Here is an example how such a string can be constructed using
 * JavaScript / TypeScript:
 * ```typescript
 * let markdown: MarkdownContent = {
 * 	kind: MarkupKind.Markdown,
 * 	value: [
 * 		'# Header',
 * 		'Some text',
 * 		'```typescript',
 * 		'someCode();',
 * 		'```'
 * 	].join('\n')
 * };
 * ```
 *
 * *Please Note* that clients might sanitize the returned markdown. A client
 * could decide to remove HTML from the markdown to avoid script execution.
 */
export interface MarkupContent {
	/**
	 * The type of the Markup.
	 */
	kind: MarkupKind;

	/**
	 * The content itself.
	 */
	value: string;
}
```

In addition, clients should signal the markdown parser they are using via the client capability `general.markdown` introduced in version 3.16.0 defined as follows:

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
| --------------- | ------- | ------------- |
| marked | 1.1.0 | [Marked Documentation](https://marked.js.org/) |
| Python-Markdown | 3.2.2 | [Python-Markdown Documentation](https://python-markdown.github.io) |

### File Resource changes

> New in version 3.13. Since version 3.16 file resource changes can carry an additional property `changeAnnotation` to describe the actual change in more detail. Whether a client has support for change annotations is guarded by the client capability `workspace.workspaceEdit.changeAnnotationSupport`.

File resource changes allow servers to create, rename and delete files and folders via the client. Note that the names talk about files but the operations are supposed to work on files and folders. This is in line with other naming in the Language Server Protocol (see file watchers which can watch files and folders). The corresponding change literals look as follows:

```typescript
/**
 * Options to create a file.
 */
export interface CreateFileOptions {
	/**
	 * Overwrite existing file. Overwrite wins over `ignoreIfExists`.
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
	 * This is a create operation.
	 */
	kind: 'create';

	/**
	 * The resource to create.
	 */
	uri: DocumentUri;

	/**
	 * Additional options.
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
	 * Overwrite target if existing. Overwrite wins over `ignoreIfExists`.
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
	 * This is a rename operation.
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
	 * This is a delete operation.
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

 Since version 3.13.0, a workspace edit can contain resource operations (create, delete or rename files and folders) as well. If resource operations are present, clients need to execute the operations in the order in which they are provided. So a workspace edit, for example, can consist of the following two changes: (1) create file a.txt and (2) a text document edit which insert text into file a.txt. An invalid sequence (e.g. (1) delete file a.txt and (2) insert text into file a.txt) will cause failure of the operation. How the client recovers from the failure is described by the client capability: `workspace.workspaceEdit.failureHandling`

```typescript
export interface WorkspaceEdit {
	/**
	 * Holds changes to existing resources.
	 */
	changes?: { [uri: DocumentUri]: TextEdit[]; };

	/**
	 * Depending on the client capability
	 * `workspace.workspaceEdit.resourceOperations` document changes are either
	 * an array of `TextDocumentEdit`s to express changes to n different text
	 * documents where each text document edit addresses a specific version of
	 * a text document. Or it can contain above `TextDocumentEdit`s mixed with
	 * create, rename and delete file / folder operations.
	 *
	 * Whether a client supports versioned document edits is expressed via
	 * `workspace.workspaceEdit.documentChanges` client capability.
	 *
	 * If a client neither supports `documentChanges` nor
	 * `workspace.workspaceEdit.resourceOperations` then only plain `TextEdit`s
	 * using the `changes` property are supported.
	 */
	documentChanges?: (
		TextDocumentEdit[] |
		(TextDocumentEdit | CreateFile | RenameFile | DeleteFile)[]
	);

	/**
	 * A map of change annotations that can be referenced in
	 * `AnnotatedTextEdit`s or create, rename and delete file / folder
	 * operations.
	 *
	 * Whether clients honor this property depends on the client capability
	 * `workspace.changeAnnotationSupport`.
	 *
	 * @since 3.16.0
	 */
	changeAnnotations?: {
		[id: string /* ChangeAnnotationIdentifier */]: ChangeAnnotation;
	};
}
```

##### WorkspaceEditClientCapabilities

> New in version 3.13: `ResourceOperationKind` and `FailureHandlingKind` and the client capability `workspace.workspaceEdit.resourceOperations` as well as `workspace.workspaceEdit.failureHandling`.

The capabilities of a workspace edit has evolved over the time. Clients can describe their support using the following client capability:

_Client Capability_:
- property path (optional): `workspace.workspaceEdit`
- property type: `WorkspaceEditClientCapabilities` defined as follows:

```typescript
export interface WorkspaceEditClientCapabilities {
	/**
	 * The client supports versioned document changes in `WorkspaceEdit`s.
	 */
	documentChanges?: boolean;

	/**
	 * The resource operations the client supports. Clients should at least
	 * support 'create', 'rename', and 'delete' for files and folders.
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
	 * If set to `true`, the client will normalize line ending characters
	 * in a workspace edit to the client specific new line character(s).
	 *
	 * @since 3.16.0
	 */
	normalizesLineEndings?: boolean;

	/**
	 * Whether the client in general supports change annotations on text edits,
	 * create file, rename file, and delete file changes.
	 *
	 * @since 3.16.0
	 */
	changeAnnotationSupport?: ChangeAnnotationsSupportOptions;

	/**
	 * Whether the client supports `WorkspaceEditMetadata` in `WorkspaceEdit`s.
	 *
	 * @since 3.18.0
	 */
	metadataSupport?: boolean;

	/**
	 * Whether the client supports snippets as text edits.
	 *
	 * @since 3.18.0
	 */
	snippetEditSupport?: boolean;
}
```

```typescript
export type ChangeAnnotationsSupportOptions = {
	/**
	 * Whether the client groups edits with equal labels into tree nodes,
	 * for instance all edits labelled with "Changes in Strings" would
	 * be a tree node.
	 */
	groupsOnLabel?: boolean;
};
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
	 * All operations are executed transactionally. That means they either all
	 * succeed or no changes at all are applied to the workspace.
	 */
	export const Transactional: FailureHandlingKind = 'transactional';


	/**
	 * If the workspace edit contains only textual file changes they are
	 * executed transactionally. If resource changes (create, rename or delete
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

Work done progress is reported using the generic [`$/progress`](#progress-support) notification. The value payload of a work done progress notification can be of three different forms.

##### Work Done Progress Begin

To start progress reporting a `$/progress` notification with the following payload must be sent:

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
	 * Controls if a cancel button should be shown to allow the user to cancel
	 * the long running operation. Clients that don't support cancellation are
	 * allowed to ignore the setting.
	 */
	cancellable?: boolean;

	/**
	 * Optional, more detailed associated progress message. Contains
	 * complementary information to the `title`.
	 *
	 * Examples: "3/25 files", "project/src/module2", "node_modules/some_dep".
	 * If unset, the previous progress message (if any) is still valid.
	 */
	message?: string;

	/**
	 * Optional progress percentage to display (value 100 is considered 100%).
	 * If not provided infinite progress is assumed and clients are allowed
	 * to ignore the `percentage` value in subsequent report notifications.
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
	 * if a cancel button got requested in the `WorkDoneProgressBegin` payload.
	 *
	 * Clients that don't support cancellation or don't support controlling the
	 * button's enablement state are allowed to ignore the setting.
	 */
	cancellable?: boolean;

	/**
	 * Optional, more detailed associated progress message. Contains
	 * complementary information to the `title`.
	 *
	 * Examples: "3/25 files", "project/src/module2", "node_modules/some_dep".
	 * If unset, the previous progress message (if any) is still valid.
	 */
	message?: string;

	/**
	 * Optional progress percentage to display (value 100 is considered 100%).
	 * If not provided infinite progress is assumed and clients are allowed
	 * to ignore the `percentage` value in subsequent report notifications.
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
	 * Optional, a final message indicating, for example,
     * the outcome of the operation.
	 */
	message?: string;
}
```

##### Initiating Work Done Progress

Work Done progress can be initiated in two different ways:

1. by the sender of a request (mostly clients) using the predefined `workDoneToken` property in the requests parameter literal. The specification will refer to this kind of progress as client initiated progress.
1. by a server using the request `window/workDoneProgress/create`. The specification will refer to this kind of progress as server initiated progress.

###### Client Initiated Progress

Consider a client sending a `textDocument/reference` request to a server and the client accepts work done progress reporting on that request. To signal this to the server, the client would add a `workDoneToken` property to the reference request parameters. This might look like this:

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

A server uses the `workDoneToken` to report progress for the specific `textDocument/reference`. For the above request, the `$/progress` notification params look like this:

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

The token received via the `workDoneToken` property in a request's param literal is only valid as long as the request has not sent a response back. Canceling work done progress is done by simply
canceling the corresponding request.

There is no specific client capability signaling whether a client will send a progress token per request. The reason for this is that this is in many clients not a static aspect and might even change for every request instance for the same request type. Thus, the capability is signaled on every request instance by the presence of a `workDoneToken` property.

To avoid that clients set up a progress monitor user interface before sending a request but the server doesn't actually report any progress, a server needs to signal general work done progress reporting support in the corresponding server capability. For the above "find references" example, a server would signal such support by setting the `referencesProvider` property in the server capabilities as follows:

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

Servers can also initiate progress reporting using the `window/workDoneProgress/create` request. This is useful if the server needs to report progress outside of a request (for example, if the server needs to re-index a database). The token can then be used to report progress using the same notifications used as for client initiated progress. The token provided in the create request should only be used once (e.g. only one begin, many report and one end notification should be sent to it).

To keep the protocol backwards compatible, servers are only allowed to use the `window/workDoneProgress/create` request if the client signals corresponding support using the client capability `window.workDoneProgress` which is defined as follows:

```typescript
	/**
	 * Window specific client capabilities.
	 */
	window?: {
		/**
		 * Whether client supports server initiated progress using the
		 * `window/workDoneProgress/create` request.
		 */
		workDoneProgress?: boolean;
	};
```

#### Partial Result Progress

> *Since version 3.15.0*

Partial results are also reported using the generic [`$/progress`](#progress-support) notification. The value payload of a partial result progress notification is in most cases the same as the final result. For example, the `workspace/symbol` request has `SymbolInformation[]` \| `WorkspaceSymbol[]` as the result type. Partial result is therefore also of type `SymbolInformation[]` \| `WorkspaceSymbol[]`. Whether a client accepts partial result notifications for a request is signaled by adding a `partialResultToken` to the request parameter. For example, a `textDocument/reference` request that supports both work done and partial result progress might look like this:

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

If a server reports partial result via a corresponding `$/progress`, the whole result must be reported using `$/progress` notifications, each of which appends items to the result. The final response has to be empty in terms of result values. This avoids confusion about how the final result should be interpreted, e.g. as another partial result or as a replacing result.

If the response errors, the provided partial results should be treated as follows:

- if the `code` equals `RequestCancelled`: the client is free to use the provided results but should make clear that the request got canceled and may be incomplete.
- in all other cases, the provided partial results shouldn't be used.

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

A `TraceValue` represents the level of verbosity with which the server systematically reports its execution trace using [$/logTrace](#logtrace-notification) notifications.
The initial trace value is set by the client at initialization and can be modified later using the [$/setTrace](#settrace-notification) notification.

```typescript
export type TraceValue = 'off' | 'messages' | 'verbose';
```

### Server lifecycle

The current protocol specification defines that the lifecycle of a server is managed by the client (e.g. a tool like VS Code or Emacs). It is up to the client to decide when to start (process-wise) and when to shutdown a server.

#### Initialize Request

The initialize request is sent as the first request from the client to the server. If the server receives a request or notification before the `initialize` request, it should act as follows:

- For a request, the response should be an error with `code: -32002`. The message can be picked by the server.
- Notifications should be dropped, except for the exit notification. This will allow the exit of a server without an initialize request.

Until the server has responded to the `initialize` request with an `InitializeResult`, the client must not send any additional requests or notifications to the server. In addition the server is not allowed to send any requests or notifications to the client until it has responded with an `InitializeResult`, with the exception that during the `initialize` request the server is allowed to send the notifications `window/showMessage`, `window/logMessage` and `telemetry/event` as well as the `window/showMessageRequest` request to the client. In case the client sets up a progress token in the initialize params (e.g. property `workDoneToken`) the server is also allowed to use that token (and only that token) using the `$/progress` notification sent from the server to the client.

The `initialize` request may only be sent once.

_Request_:
- method: 'initialize'
- params: `InitializeParams` defined as follows:

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
	clientInfo?: ClientInfo;

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
	 * @deprecated in favour of `rootUri`.
	 */
	rootPath?: string | null;

	/**
	 * The rootUri of the workspace. Is null if no
	 * folder is open. If both `rootPath` and `rootUri` are set
	 * `rootUri` wins.
	 *
	 * @deprecated in favour of `workspaceFolders`
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
	 * It can be `null` if the client supports workspace folders but none are
	 * configured.
	 *
	 * @since 3.6.0
	 */
	workspaceFolders?: WorkspaceFolder[] | null;
}
```

```typescript
/**
 * Information about the client
 *
 * @since 3.15.0
 */
export type ClientInfo = {
	/**
	 * The name of the client as defined by the client.
	 */
	name: string;

	/**
	 * The client's version as defined by the client.
	 */
	version?: string;
};
```

Where `ClientCapabilities` and `TextDocumentClientCapabilities` are defined as follows:

##### TextDocumentClientCapabilities

`TextDocumentClientCapabilities` define capabilities the editor / tool provides on text documents.

```typescript
/**
 * Text document specific client capabilities.
 */
export interface TextDocumentClientCapabilities {

	/**
	 * Defines which synchronization capabilities the client supports.
	 */
	synchronization?: TextDocumentSyncClientCapabilities;

	/**
	 * Defines which filters the client supports.
	 *
	 * @since 3.18.0
	 */
	filters?: TextDocumentFilterClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/completion` request.
	 */
	completion?: CompletionClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/hover` request.
	 */
	hover?: HoverClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/signatureHelp` request.
	 */
	signatureHelp?: SignatureHelpClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/declaration` request.
	 *
	 * @since 3.14.0
	 */
	declaration?: DeclarationClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/definition` request.
	 */
	definition?: DefinitionClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/typeDefinition` request.
	 *
	 * @since 3.6.0
	 */
	typeDefinition?: TypeDefinitionClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/implementation` request.
	 *
	 * @since 3.6.0
	 */
	implementation?: ImplementationClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/references` request.
	 */
	references?: ReferenceClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/documentHighlight` request.
	 */
	documentHighlight?: DocumentHighlightClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/documentSymbol` request.
	 */
	documentSymbol?: DocumentSymbolClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/codeAction` request.
	 */
	codeAction?: CodeActionClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/codeLens` request.
	 */
	codeLens?: CodeLensClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/documentLink` request.
	 */
	documentLink?: DocumentLinkClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/documentColor` and the
	 * `textDocument/colorPresentation` request.
	 *
	 * @since 3.6.0
	 */
	colorProvider?: DocumentColorClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/formatting` request.
	 */
	formatting?: DocumentFormattingClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/rangeFormatting` and
	 * `textDocument/rangesFormatting requests.
	 */
	rangeFormatting?: DocumentRangeFormattingClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/onTypeFormatting` request.
	 */
	onTypeFormatting?: DocumentOnTypeFormattingClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/rename` request.
	 */
	rename?: RenameClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/publishDiagnostics`
	 * notification.
	 */
	publishDiagnostics?: PublishDiagnosticsClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/foldingRange` request.
	 *
	 * @since 3.10.0
	 */
	foldingRange?: FoldingRangeClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/selectionRange` request.
	 *
	 * @since 3.15.0
	 */
	selectionRange?: SelectionRangeClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/linkedEditingRange` request.
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
	 * Capabilities specific to the `textDocument/moniker` request.
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
	 * Capabilities specific to the `textDocument/inlineValue` request.
	 *
	 * @since 3.17.0
	 */
	inlineValue?: InlineValueClientCapabilities;

	/**
	 * Capabilities specific to the `textDocument/inlayHint` request.
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

	/**
	 * Capabilities specific to the `textDocument/inlineCompletion` request.
	 *
	 * @since 3.18.0
	 */
	inlineCompletion?: InlineCompletionClientCapabilities;
}

export interface TextDocumentFilterClientCapabilities {

	/**
	 * The client supports Relative Patterns.
	 *
	 * @since 3.18.0
	 */
	relativePatternSupport?: boolean;
}
```

##### NotebookDocumentClientCapabilities

`NotebookDocumentClientCapabilities` define capabilities the editor / tool provides on notebook documents.

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

`ClientCapabilities` define capabilities for dynamic registration, workspace and text document features the client supports. The `experimental` can be used to pass experimental capabilities under development. For future compatibility a `ClientCapabilities` object literal can have more properties set than currently defined. Servers receiving a `ClientCapabilities` object literal with unknown properties should ignore these properties. A missing property should be interpreted as an absence of the capability. If a missing property normally defines sub properties, all missing sub properties should be interpreted as an absence of the corresponding capability.

Client capabilities got introduced with version 3.0 of the protocol. They therefore only describe capabilities that got introduced in 3.x or later. Capabilities that existed in the 2.x version of the protocol are still mandatory for clients. Clients cannot opt out of providing them. So even if a client omits the `ClientCapabilities.textDocument.synchronization` it is still required that the client provides text document synchronization (e.g. open, changed and close notifications).

```typescript
interface ClientCapabilities {
	/**
	 * Workspace specific client capabilities.
	 */
	workspace?: WorkspaceClientCapabilities;

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
	window?: WindowClientCapabilities;

	/**
	 * General client capabilities.
	 *
	 * @since 3.16.0
	 */
	general?: GeneralClientCapabilities;

	/**
	 * Experimental client capabilities.
	 */
	experimental?: LSPAny;
}
```

```typescript
export type WorkspaceClientCapabilities = {
	/**
	 * The client supports applying batch edits
	 * to the workspace by supporting the request
	 * 'workspace/applyEdit'
	 */
	applyEdit?: boolean;

	/**
	 * Capabilities specific to `WorkspaceEdit`s
	 */
	workspaceEdit?: WorkspaceEditClientCapabilities;

	/**
	 * Capabilities specific to the `workspace/didChangeConfiguration`
	 * notification.
	 */
	didChangeConfiguration?: DidChangeConfigurationClientCapabilities;

	/**
	 * Capabilities specific to the `workspace/didChangeWatchedFiles`
	 * notification.
	 */
	didChangeWatchedFiles?: DidChangeWatchedFilesClientCapabilities;

	/**
	 * Capabilities specific to the `workspace/symbol` request.
	 */
	symbol?: WorkspaceSymbolClientCapabilities;

	/**
	 * Capabilities specific to the `workspace/executeCommand` request.
	 */
	executeCommand?: ExecuteCommandClientCapabilities;

	/**
	 * The client has support for workspace folders.
	 *
	 * @since 3.6.0
	 */
	workspaceFolders?: boolean;

	/**
	 * The client supports `workspace/configuration` requests.
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
	fileOperations?: FileOperationClientCapabilities;

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

	/**
	 * Capabilities specific to the folding range requests
	 * scoped to the workspace.
	 *
	 * @since 3.18.0
	 */
	foldingRange?: FoldingRangeWorkspaceClientCapabilities;

	/**
	 * Capabilities specific to the `workspace/textDocumentContent`
	 * request.
	 *
	 * @since 3.18.0
	 */
	textDocumentContent?: TextDocumentContentClientCapabilities;
}
```

```typescript
/**
 * Capabilities relating to events from file operations by the user in the client.
 *
 * These events do not come from the file system, they come from user operations
 * like renaming a file in the UI.
 *
 * @since 3.16.0
 */
export interface FileOperationClientCapabilities {

	/**
	 * Whether the client supports dynamic registration for
	 * file requests/notifications.
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
}
```

```typescript
export interface WindowClientCapabilities {
	/**
	 * It indicates whether the client supports server initiated
	 * progress using the `window/workDoneProgress/create` request.
	 *
	 * The capability also controls Whether client supports handling
	 * of progress notifications. If set servers are allowed to report a
	 * `workDoneProgress` property in the request specific server
	 * capabilities.
	 *
	 * @since 3.15.0
	 */
	workDoneProgress?: boolean;

	/**
	 * Capabilities specific to the showMessage request.
	 *
	 * @since 3.16.0
	 */
	showMessage?: ShowMessageRequestClientCapabilities;

	/**
	 * Capabilities specific to the showDocument request.
	 *
	 * @since 3.16.0
	 */
	showDocument?: ShowDocumentClientCapabilities;
}
```

```typescript
/**
 * General client capabilities.
 *
 * @since 3.16.0
 */
export interface GeneralClientCapabilities {
	/**
	 * Client capability that signals how the client
	 * handles stale requests (e.g. a request
	 * for which the client will not process the response
	 * anymore since the information is outdated).
	 *
	 * @since 3.17.0
	 */
	staleRequestSupport?: StaleRequestSupportOptions;

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
	 * sides.
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
}
```

```typescript
export type StaleRequestSupportOptions = {
	/**
	 * The client will actively cancel the request.
	 */
	cancel: boolean;

	/**
	 * The list of requests for which the client
	 * will retry the request if it receives a
	 * response with error code `ContentModified`
	 */
	retryOnContentModified: string[];
};
```

_Response_:
- result: `InitializeResult` defined as follows:

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
	serverInfo?: ServerInfo;
}
```

```typescript
/**
 * Information about the server
 *
 * @since 3.15.0
 */
export type ServerInfo = {
	/**
	 * The name of the server as defined by the server.
	 */
	name: string;

	/**
	 * The server's version as defined by the server.
	 */
	version?: string;
};
```
- error.code:

```typescript
/**
 * Known error codes for an `InitializeErrorCodes`;
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
	 * by the client via the client capability `general.positionEncodings`.
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
	 * `TextDocumentSyncKind.None`.
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
	 * The server provides code actions. The `CodeActionOptions` return type is
	 * only valid if the client signals code action literal support via the
	 * property `textDocument.codeAction.codeActionLiteralSupport`.
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
	 * `prepareSupport` in its initial `initialize` request.
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
	 * The server provides inline completions.
	 *
	 * @since 3.18.0
	 */
	inlineCompletionProvider?: boolean | InlineCompletionOptions;

	/**
	 * Workspace specific server capabilities
	 */
	workspace?: WorkspaceOptions;

	/**
	 * Experimental server capabilities.
	 */
	experimental?: LSPAny;
}
```

```typescript
/**
 * Defines workspace specific capabilities of the server.
 */
export type WorkspaceOptions = {
	/**
	 * The server supports workspace folder.
	 *
	 * @since 3.6.0
	 */
	workspaceFolders?: WorkspaceFoldersServerCapabilities;

	/**
	 * The server is interested in notifications/requests for operations on files.
	 *
	 * @since 3.16.0
	 */
	fileOperations?: FileOperationOptions;

	/**
	 * The server supports the `workspace/textDocumentContent` request.
	 *
	 * @since 3.18.0
	 */
	textDocumentContent?: TextDocumentContentOptions
		| TextDocumentContentRegistrationOptions;
};
```

```typescript
/**
 * Options for notifications/requests for user operations on files.
 *
 * @since 3.16.0
 */
export interface FileOperationOptions {

	/**
	* The server is interested in receiving didCreateFiles notifications.
	*/
	didCreate?: FileOperationRegistrationOptions;

	/**
	* The server is interested in receiving willCreateFiles requests.
	*/
	willCreate?: FileOperationRegistrationOptions;

	/**
	* The server is interested in receiving didRenameFiles notifications.
	*/
	didRename?: FileOperationRegistrationOptions;

	/**
	* The server is interested in receiving willRenameFiles requests.
	*/
	willRename?: FileOperationRegistrationOptions;

	/**
	* The server is interested in receiving didDeleteFiles file notifications.
	*/
	didDelete?: FileOperationRegistrationOptions;

	/**
	* The server is interested in receiving willDeleteFiles file requests.
	*/
	willDelete?: FileOperationRegistrationOptions;
}
```

#### Initialized Notification

The initialized notification is sent from the client to the server after the client received the result of the `initialize` request, but before the client is sending any other request or notification to the server. The server can use the `initialized` notification, for example, to dynamically register capabilities. The `initialized` notification may only be sent once.

_Notification_:
- method: 'initialized'
- params: `InitializedParams` defined as follows:

```typescript
interface InitializedParams {
}
```

#### Register Capability

The `client/registerCapability` request is sent from the server to the client to register for a new capability on the client side. Not all clients need to support dynamic capability registration. A client opts in via the `dynamicRegistration` property on the specific client capabilities. A client can even provide dynamic registration for capability A but not for capability B (see `TextDocumentClientCapabilities` as an example).

The server must not register the same capability both statically through the initialize result and dynamically for the same document selector. If a server wants to support both static and dynamic registration, it needs to check the client capability in the initialize request and only register the capability statically if the client doesn't support dynamic registration for that capability.

_Request_:
- method: 'client/registerCapability'
- params: `RegistrationParams`

Where `RegistrationParams` are defined as follows:

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
```

```typescript
export interface RegistrationParams {
	registrations: Registration[];
}
```

Since most of the registration options require to specify a document selector there is a base interface that can be used. See `TextDocumentRegistrationOptions`.

An example JSON-RPC message to register dynamically for the `textDocument/willSaveWaitUntil` feature on the client side is as follows (only details shown):

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

This message is sent from the server to the client and after the client has successfully executed the request, further `textDocument/willSaveWaitUntil` requests for JavaScript text documents are sent from the client to the server.

_Response_:
- result: void.
- error: code and message set in case an exception happens during the request.

`StaticRegistrationOptions` can be used to register a feature in the initialize result with a given server control ID to be able to un-register the feature later on.

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

`TextDocumentRegistrationOptions` can be used to dynamically register for requests for a set of text documents.

```typescript
/**
 * General text document registration options.
 */
export interface TextDocumentRegistrationOptions {
	/**
	 * A document selector to identify the scope of the registration. If set to
	 * null, the document selector provided on the client side will be used.
	 */
	documentSelector: DocumentSelector | null;
}
```

#### Unregister Capability

The `client/unregisterCapability` request is sent from the server to the client to unregister a previously registered capability.

_Request_:
- method: 'client/unregisterCapability'
- params: `UnregistrationParams`

Where `UnregistrationParams` are defined as follows:

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
```

```typescript
export interface UnregistrationParams {
	// This should correctly be named `unregistrations`. However, changing this
	// is a breaking change and needs to wait until we deliver a 4.x version
	// of the specification.
	unregisterations: Unregistration[];
}
```

An example JSON-RPC message to unregister the above registered `textDocument/willSaveWaitUntil` feature looks like this:

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
_Response_:
- result: void.
- error: code and message set in case an exception happens during the request.

#### SetTrace Notification

A notification that should be used by the client to modify the trace setting of the server.

_Notification_:
- method: '$/setTrace'
- params: `SetTraceParams` defined as follows:

```typescript
interface SetTraceParams {
	/**
	 * The new value that should be assigned to the trace setting.
	 */
	value: TraceValue;
}
```

#### LogTrace Notification

A notification to log the trace of the server's execution.
The amount and content of these notifications depends on the current `trace` configuration.
If `trace` is `'off'`, the server should not send any `logTrace` notification.
If `trace` is `'messages'`, the server should not add the `'verbose'` field in the `LogTraceParams`.

`$/logTrace` should be used for systematic trace reporting. For single debugging messages, the server should send [`window/logMessage`](#logmessage-notification) notifications.

_Notification_:
- method: '$/logTrace'
- params: `LogTraceParams` defined as follows:

```typescript
interface LogTraceParams {
	/**
	 * The message to be logged.
	 */
	message: string;
	/**
	 * Additional information that can be computed if the `trace` configuration
	 * is set to `'verbose'`.
	 */
	verbose?: string;
}
```

#### Shutdown Request

The shutdown request is sent from the client to the server. It asks the server to shut down, but to not exit (otherwise the response might not be delivered correctly to the client). There is a separate exit notification that asks the server to exit. Clients must not send any requests or notifications other than `exit` to a server to which they have sent a shutdown request. Clients should also wait with sending the `exit` notification until they have received a response from the `shutdown` request.

If a server receives requests after a shutdown request those requests should error with `InvalidRequest`.

_Request_:
- method: 'shutdown'
- params: none

_Response_:
- result: null
- error: code and message set in case an exception happens during shutdown request.

#### Exit Notification

A notification to ask the server to exit its process.
The server should exit with `success` code 0 if the shutdown request has been received before; otherwise with `error` code 1.

_Notification_:
- method: 'exit'
- params: none

### Text Document Synchronization

Client support for `textDocument/didOpen`, `textDocument/didChange` and `textDocument/didClose` notifications is mandatory in the protocol and clients can not opt out supporting them. This includes both full and incremental synchronization in the `textDocument/didChange` notification. In addition a server must either implement all three of them or none. Their capabilities are therefore controlled via a combined client and server capability. Opting out of text document synchronization makes only sense if the documents shown by the client are read only. Otherwise the server might receive request for documents, for which the content is managed in the client (e.g. they might have changed).

_Client Capability_:
- property path (optional): `textDocument.synchronization.dynamicRegistration`
- property type: `boolean`

Controls whether text document synchronization supports dynamic registration.

_Server Capability_:
- property path (optional): `textDocumentSync`
- property type: `TextDocumentSyncKind | TextDocumentSyncOptions`. The below definition of the `TextDocumentSyncOptions` only covers the properties specific to the open, change and close notifications. A complete definition covering all properties can be found [here](#didclosetextdocument-notification):

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
```

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

The document open notification is sent from the client to the server to signal newly opened text documents. The document's content is now managed by the client and the server must not try to read the document's content using the document's Uri. Open in this sense means it is managed by the client. It doesn't necessarily mean that its content is presented in an editor. An open notification must not be sent more than once without a corresponding close notification send before. This means open and close notification must be balanced and the max open count for a particular textDocument is one. Note that a server's ability to fulfill requests is independent of whether a text document is open or closed.

The `DidOpenTextDocumentParams` contain the language id the document is associated with. If the language id of a document changes, the client needs to send a `textDocument/didClose` to the server followed by a `textDocument/didOpen` with the new language id if the server handles the new language id as well.

_Client Capability_:
See general synchronization client capabilities.

_Server Capability_:
See general synchronization server capabilities.

_Registration Options_: `TextDocumentRegistrationOptions`

_Notification_:
- method: 'textDocument/didOpen'
- params: `DidOpenTextDocumentParams` defined as follows:

```typescript
interface DidOpenTextDocumentParams {
	/**
	 * The document that was opened.
	 */
	textDocument: TextDocumentItem;
}
```

#### DidChangeTextDocument Notification

The document change notification is sent from the client to the server to signal changes to a text document. Before a client can change a text document it must claim ownership of its content using the `textDocument/didOpen` notification. In 2.0 the shape of the params has changed to include proper version numbers.

Before requesting information from the server (e.g., `textDocument/completion` or `textDocument/signatureHelp`), the client must ensure that the document's state is synchronized with the server to guarantee reliable results.

The following example shows how the client should synchronize the state when the user has continuous input, assuming user input triggered `textDocument/completion`:

| Document Version | User Input | Client Behavior | Request |
| ---------------- | ------------------- | ----------------------------------------------- | ------------------------- |
| 5 | document change one | sync document `v5` to the server | `textDocument/didChange` |
| 5 | - | request from the server, based on document `v5` | `textDocument/completion` |
| 6 | document change two | sync document `v6` to the server | `textDocument/didChange` |

_Client Capability_:
See general synchronization client capabilities.

_Server Capability_:
See general synchronization server capabilities.

_Registration Options_: `TextDocumentChangeRegistrationOptions` defined as follows:

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

_Notification_:
- method: `textDocument/didChange`
- params: `DidChangeTextDocumentParams` defined as follows:

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
	 * - apply the `TextDocumentContentChangeEvent`s in a single notification
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
export type TextDocumentContentChangeEvent = TextDocumentContentChangePartial |
	TextDocumentContentChangeWholeDocument;
```

```typescript
export type TextDocumentContentChangePartial = {
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
};
```

```typescript
export type TextDocumentContentChangeWholeDocument = {
	/**
	 * The new text of the whole document.
	 */
	text: string;
};
```

#### WillSaveTextDocument Notification

The document will save notification is sent from the client to the server before the document is actually saved. If a server has registered for open / close events clients should ensure that the document is open before a `willSave` notification is sent since clients can't change the content of a file without ownership transferal.

_Client Capability_:
- property name (optional): `textDocument.synchronization.willSave`
- property type: `boolean`

The capability indicates that the client supports `textDocument/willSave` notifications.

_Server Capability_:
- property name (optional): `textDocumentSync.willSave`
- property type: `boolean`

The capability indicates that the server is interested in `textDocument/willSave` notifications.

_Registration Options_: `TextDocumentRegistrationOptions`

_Notification_:
- method: 'textDocument/willSave'
- params: `WillSaveTextDocumentParams` defined as follows:

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

The document will save request is sent from the client to the server before the document is actually saved. The request can return an array of TextEdits which will be applied to the text document before it is saved. Please note that clients might drop results if computing the text edits took too long or if a server constantly fails on this request. This is done to keep the save fast and reliable.  If a server has registered for open / close events clients should ensure that the document is open before a `willSaveWaitUntil` notification is sent since clients can't change the content of a file without ownership transferal.

_Client Capability_:
- property name (optional): `textDocument.synchronization.willSaveWaitUntil`
- property type: `boolean`

The capability indicates that the client supports `textDocument/willSaveWaitUntil` requests.

_Server Capability_:
- property name (optional): `textDocumentSync.willSaveWaitUntil`
- property type: `boolean`

The capability indicates that the server is interested in `textDocument/willSaveWaitUntil` requests.

_Registration Options_: `TextDocumentRegistrationOptions`

_Request_:
- method: `textDocument/willSaveWaitUntil`
- params: `WillSaveTextDocumentParams`

_Response_:
- result: [`TextEdit[]`](#textEdit) \| `null`
- error: code and message set in case an exception happens during the `textDocument/willSaveWaitUntil` request.

#### DidSaveTextDocument Notification

The document save notification is sent from the client to the server when the document was saved in the client.

_Client Capability_:
- property name (optional): `textDocument.synchronization.didSave`
- property type: `boolean`

The capability indicates that the client supports `textDocument/didSave` notifications.

_Server Capability_:
- property name (optional): `textDocumentSync.save`
- property type: `boolean | SaveOptions` where `SaveOptions` is defined as follows:

```typescript
export interface SaveOptions {
	/**
	 * The client is supposed to include the content on save.
	 */
	includeText?: boolean;
}
```

The capability indicates that the server is interested in `textDocument/didSave` notifications.

_Registration Options_: `TextDocumentSaveRegistrationOptions` defined as follows:

```typescript
export interface TextDocumentSaveRegistrationOptions
	extends TextDocumentRegistrationOptions {
	/**
	 * The client is supposed to include the content on save.
	 */
	includeText?: boolean;
}
```

_Notification_:
- method: `textDocument/didSave`
- params: `DidSaveTextDocumentParams` defined as follows:

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

The document close notification is sent from the client to the server when the document got closed in the client. The document's master now exists where the document's Uri points to (e.g. if the document's Uri is a file Uri the master now exists on disk). As with the open notification the close notification is about managing the document's content. Receiving a close notification doesn't mean that the document was open in an editor before. A close notification requires a previous open notification to be sent. Note that a server's ability to fulfill requests is independent of whether a text document is open or closed.

_Client Capability_:
See general synchronization client capabilities.

_Server Capability_:
See general synchronization server capabilities.

_Registration Options_: `TextDocumentRegistrationOptions`

_Notification_:
- method: `textDocument/didClose`
- params: `DidCloseTextDocumentParams` defined as follows:

```typescript
interface DidCloseTextDocumentParams {
	/**
	 * The document that was closed.
	 */
	textDocument: TextDocumentIdentifier;
}
```

#### Renaming a document

Document renames should be signaled to a server sending a document close notification with the document's old name followed by an open notification using the document's new name. Major reason is that besides the name other attributes can change as well like the language that is associated with the document. In addition the new document could not be of interest for the server anymore.

Servers can participate in a document rename by subscribing for the [`workspace/didRenameFiles`](#didrenamefiles-notification) notification or the [`workspace/willRenameFiles`](#willrenamefiles-request) request.

The final structure of the `TextDocumentSyncClientCapabilities` and the `TextDocumentSyncOptions` server options look like this

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
```

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

Notebooks are becoming more and more popular. Adding support for them to the language server protocol allows notebook editors to reuse language smarts provided by the server inside a notebook or a notebook cell, respectively. To reuse protocol parts and therefore server implementations, notebooks are modeled in the following way in LSP:

- *notebook document*: a collection of notebook cells typically stored in a file on disk. A notebook document has a type and can be uniquely identified using a resource URI.
- *notebook cell*: holds the actual text content. Cells have a kind (either code or markdown). The actual text content of the cell is stored in a text document which can be synced to the server like all other text documents. Cell text documents have a URI, but servers should not rely on any format for this URI, since it is up to the client on how it will create these URIs. The URIs must be unique across ALL notebook cells and can therefore be used to uniquely identify a notebook cell or the cell's text document.

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
	 * The cell's kind.
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
	 * A markup-cell is a formatted source that is used for display.
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
	 * A strictly monotonically increasing value
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

Syncing the text content of a cell is relatively easy since clients should model them as text documents. However, since the URI of a notebook cell's text document should be opaque, servers cannot know its scheme nor its path. What is known is the notebook document itself. We therefore introduce a special filter for notebook cell documents:

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
	 * value is provided, it matches against the
	 * notebook type. '*' matches every notebook.
	 */
	notebook: string | NotebookDocumentFilter;

	/**
	 * A language ID like `python`.
	 *
	 * Will be matched against the language ID of the
	 * notebook cell document. '*' matches every language.
	 */
	language?: string;
}
```

```typescript
/**
 * A notebook document filter where `notebookType` is required field.
 *
 * @since 3.18.0
 */
export type NotebookDocumentFilterNotebookType = {
	/**
	 * The type of the enclosing notebook.
	 */
	notebookType: string;

	/**
	 * A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	 */
	scheme?: string;

	/**
	 * A glob pattern.
	 */
	pattern?: GlobPattern;
};

/**
 * A notebook document filter where `scheme` is required field.
 *
 * @since 3.18.0
 */
export type NotebookDocumentFilterScheme = {
	/**
	 * The type of the enclosing notebook.
	 */
	notebookType?: string;

	/**
	 * A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	 */
	scheme: string;

	/**
	 * A glob pattern.
	 */
	pattern?: GlobPattern;
};

/**
 * A notebook document filter where `pattern` is required field.
 *
 * @since 3.18.0
 */
export type NotebookDocumentFilterPattern = {
	/**
	 * The type of the enclosing notebook.
	 */
	notebookType?: string;

	/**
	 * A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	 */
	scheme?: string;

	/**
	 * A glob pattern.
	 */
	pattern: GlobPattern;
};

/**
 * A notebook document filter denotes a notebook document by
 * different properties. The properties will be match
 * against the notebook's URI (same as with documents)
 *
 * @since 3.17.0
 */
export type NotebookDocumentFilter = NotebookDocumentFilterNotebookType |
	NotebookDocumentFilterScheme | NotebookDocumentFilterPattern;
```

Given these structures, a Python cell document in a Jupyter notebook stored on disk in a folder having `books1` in its path can be identified as follows:

```typescript
{
	notebook: {
		scheme: 'file',
		pattern: '**/books1/**',
		notebookType: 'jupyter-notebook'
	},
	language: 'python'
}
```

A `NotebookCellTextDocumentFilter` can be used to register providers for certain requests like code complete or hover. If such a provider is registered, the client will send the corresponding `textDocument/*` requests to the server using the cell text document's URI as the document URI.

There are cases where only knowing about a cell's text content is not enough for a server to reason about the cells content and to provide good language smarts. Sometimes it is necessary to know all cells of a notebook document, including the notebook document itself. Consider a notebook that has two JavaScript cells with the following content

Cell one:

```javascript
function add(a, b) {
	return a + b;
}
```

Cell two:

```javascript
add/*<cursor>*/;
```
Requesting code assist in cell two at the marked cursor position should propose the function `add` which is only possible if the server knows about cell one and cell two and knows that they belong to the same notebook document.

The protocol will therefore support two modes when it comes to synchronizing cell text content:

- _cellContent_: in this mode, only the cell text content is synchronized to the server using the standard `textDocument/did*` notification. No notebook document and no cell structure is synchronized. This mode allows for easy adoption of notebooks since servers can reuse most of their implementation logic.
- _notebook_: in this mode the notebook document, the notebook cells and the notebook cell text content is synchronized to the server. To allow servers to create a consistent picture of a notebook document, the cell text content is NOT synchronized using the standard `textDocument/did*` notifications. It is instead synchronized using special `notebookDocument/did*` notifications. This ensures that the cell and its text content arrive on the server using one open, change or close event.

In both modes, notebook cell text documents are treated as regular text documents. They are always synchronized using incremental sync.

To request the cell content, only a normal document selector can be used. For example, the selector `[{ language: 'python' }]` will synchronize Python notebook document cells to the server. However, since this might synchronize unwanted documents as well, a document filter can also be a `NotebookCellTextDocumentFilter`. So `{ notebook: { scheme: 'file', notebookType: 'jupyter-notebook' }, language: 'python' }` synchronizes all Python cells in a Jupyter notebook stored on disk.

To synchronize the whole notebook document, a server provides a `notebookDocumentSync` in its server capabilities. For example:

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

_Client Capability_:

The following client capabilities are defined for notebook documents:

- property name (optional): `notebookDocument.synchronization`
- property type: `NotebookDocumentSyncClientCapabilities` defined as follows

```typescript
/**
 * Notebook specific client capabilities.
 *
 * @since 3.17.0
 */
export interface NotebookDocumentSyncClientCapabilities {

	/**
	 * Whether implementation supports dynamic registration. If this is
	 * set to `true`, the client supports the new
	 * `(NotebookDocumentSyncRegistrationOptions & NotebookDocumentSyncOptions)`
	 * return value for the corresponding server capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports sending execution summary data per cell.
	 */
	executionSummarySupport?: boolean;
}
```

_Server Capability_:

The following server capabilities are defined for notebook documents:

- property name (optional): `notebookDocumentSync`
- property type: `NotebookDocumentSyncOptions | NotebookDocumentSyncRegistrationOptions` where `NotebookDocumentOptions` is defined as follows:

```typescript
/**
 * Options specific to a notebook plus its cells
 * to be synced to the server.
 *
 * If a selector provides a notebook document
 * filter but no cell selector, all cells of a
 * matching notebook document will be synced.
 *
 * If a selector provides no notebook document
 * filter but only a cell selector, all notebook
 * documents that contain at least one matching
 * cell will be synced.
 *
 * @since 3.17.0
 */
export interface NotebookDocumentSyncOptions {
	/**
	 * The notebooks to be synced
	 */
	notebookSelector: (NotebookDocumentFilterWithNotebook | NotebookDocumentFilterWithCells)[];

	/**
	 * Whether save notifications should be forwarded to
	 * the server. Will only be honored if mode === `notebook`.
	 */
	save?: boolean;
}
```

```typescript
export type NotebookDocumentFilterWithNotebook = {
	/**
	 * The notebook to be synced. If a string
	 * value is provided, it matches against the
	 * notebook type. '*' matches every notebook.
	 */
	notebook: string | NotebookDocumentFilter;

	/**
	 * The cells of the matching notebook to be synced.
	 */
	cells?: NotebookCellLanguage[];
};
```

```typescript
export type NotebookDocumentFilterWithCells = {
	/**
	 * The notebook to be synced. If a string
	 * value is provided, it matches against the
	 * notebook type. '*' matches every notebook.
	 */
	notebook?: string | NotebookDocumentFilter;

	/**
	 * The cells of the matching notebook to be synced.
	 */
	cells: NotebookCellLanguage[];
};
```

```typescript
export type NotebookCellLanguage = {
	language: string;
};
```

_Registration Options_: `notebookDocumentSyncRegistrationOptions` defined as follows:

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

Since the registration option handles open, change, save and close notifications, the method name used to register for notebook document synchronization is `notebookDocument/sync` and not one of the specific methods described below.

#### DidOpenNotebookDocument Notification

The open notification is sent from the client to the server when a notebook document is opened. It is only sent by a client if the server requested the synchronization mode `notebook` in its `notebookDocumentSync` capability.

_Notification_:

- method: `notebookDocument/didOpen`
- params: `DidOpenNotebookDocumentParams` defined as follows:

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

_Notification_:

- method: `notebookDocument/didChange`
- params: `DidChangeNotebookDocumentParams` defined as follows:

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
	 * The change describes a single state change to the notebook document,
	 * so it moves a notebook document, its cells and its cell text document
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
	 * Changes to cells.
	 */
	cells?: NotebookDocumentCellChanges;
}
```

```typescript
/**
 * Cell changes to a notebook document.
 */
export type NotebookDocumentCellChanges = {
	/**
	 * Changes to the cell structure to add or
	 * remove cells.
	 */
	structure?: NotebookDocumentCellChangeStructure;

	/**
	 * Changes to notebook cells properties like its
	 * kind, execution summary or metadata.
	 */
	data?: NotebookCell[];

	/**
	 * Changes to the text content of notebook cells.
	 */
	textContent?: NotebookDocumentCellContentChanges[];
};
```

```typescript
/**
 * Structural changes to cells in a notebook document.
 */
export type NotebookDocumentCellChangeStructure = {
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
```

```typescript
/**
 * Content changes to a cell in a notebook document.
 */
export type NotebookDocumentCellContentChanges = {
	document: VersionedTextDocumentIdentifier;
	changes: TextDocumentContentChangeEvent[];
};
```

```typescript
/**
 * A change describing how to move a `NotebookCell`
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
	 * The number of deleted cells.
	 */
	deleteCount: uinteger;

	/**
	 * The new cells, if any.
	 */
	cells?: NotebookCell[];
}
```

#### DidSaveNotebookDocument Notification

The save notification is sent from the client to the server when a notebook document is saved. It is only sent by a client if the server requested the synchronization mode `notebook` in its `notebookDocumentSync` capability.

_Notification_:

- method: `notebookDocument/didSave`
- params: `DidSaveNotebookDocumentParams` defined as follows:

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

_Notification_:

- method: `notebookDocument/didClose`
- params: `DidCloseNotebookDocumentParams` defined as follows:

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

Language Features provide the actual smarts in the language server protocol. They are usually executed on a [text document, position] tuple. The main language feature categories are:

- code comprehension features like Hover or Goto Definition.
- coding features like diagnostics, code complete or code actions.

The language features should be computed on the [synchronized state](#text-document-synchronization) of the document.

#### Go to Declaration Request

> *Since version 3.14.0*

The go to declaration request is sent from the client to the server to resolve the declaration location of a symbol at a given text document position.

The result type [`LocationLink`](#locationlink)[] got introduced with version 3.14.0 and depends on the corresponding client capability `textDocument.declaration.linkSupport`.

_Client Capability_:
- property name (optional): `textDocument.declaration`
- property type: `DeclarationClientCapabilities` defined as follows:

```typescript
export interface DeclarationClientCapabilities {
	/**
	 * Whether declaration supports dynamic registration. If this is set to
	 * `true`, the client supports the new `DeclarationRegistrationOptions`
	 * return value for the corresponding server capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports additional metadata in the form of declaration links.
	 */
	linkSupport?: boolean;
}
```

_Server Capability_:
- property name (optional): `declarationProvider`
- property type: `boolean | DeclarationOptions | DeclarationRegistrationOptions` where `DeclarationOptions` is defined as follows:

```typescript
export interface DeclarationOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `DeclarationRegistrationOptions` defined as follows:

```typescript
export interface DeclarationRegistrationOptions extends DeclarationOptions,
	TextDocumentRegistrationOptions, StaticRegistrationOptions {
}
```

_Request_:
- method: `textDocument/declaration`
- params: `DeclarationParams` defined as follows:

```typescript
export interface DeclarationParams extends TextDocumentPositionParams,
	WorkDoneProgressParams, PartialResultParams {
}
```

_Response_:
- result: [`Location`](#location) \| [`Location`](#location)[] \| [`LocationLink`](#locationlink)[] \|`null`
- partial result: [`Location`](#location)[] \| [`LocationLink`](#locationlink)[]
- error: code and message set in case an exception happens during the declaration request.

#### Go to Definition Request

The go to definition request is sent from the client to the server to resolve the definition location of a symbol at a given text document position.

The result type [`LocationLink`](#locationlink)[] got introduced with version 3.14.0 and depends on the corresponding client capability `textDocument.definition.linkSupport`.

_Client Capability_:
- property name (optional): `textDocument.definition`
- property type: `DefinitionClientCapabilities` defined as follows:

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

_Server Capability_:
- property name (optional): `definitionProvider`
- property type: `boolean | DefinitionOptions` where `DefinitionOptions` is defined as follows:

```typescript
export interface DefinitionOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `DefinitionRegistrationOptions` defined as follows:

```typescript
export interface DefinitionRegistrationOptions extends
	TextDocumentRegistrationOptions, DefinitionOptions {
}
```

_Request_:
- method: `textDocument/definition`
- params: `DefinitionParams` defined as follows:

```typescript
export interface DefinitionParams extends TextDocumentPositionParams,
	WorkDoneProgressParams, PartialResultParams {
}
```

_Response_:
- result: [`Location`](#location) \| [`Location`](#location)[] \| [`LocationLink`](#locationlink)[] \| `null`
- partial result: [`Location`](#location)[] \| [`LocationLink`](#locationlink)[]
- error: code and message set in case an exception happens during the definition request.

#### Go to Type Definition Request

> *Since version 3.6.0*

The go to type definition request is sent from the client to the server to resolve the type definition location of a symbol at a given text document position.

The result type [`LocationLink`](#locationlink)[] got introduced with version 3.14.0 and depends on the corresponding client capability `textDocument.typeDefinition.linkSupport`.

_Client Capability_:
- property name (optional): `textDocument.typeDefinition`
- property type: `TypeDefinitionClientCapabilities` defined as follows:

```typescript
export interface TypeDefinitionClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * `true`, the client supports the new `TypeDefinitionRegistrationOptions`
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

_Server Capability_:
- property name (optional): `typeDefinitionProvider`
- property type: `boolean | TypeDefinitionOptions | TypeDefinitionRegistrationOptions` where `TypeDefinitionOptions` is defined as follows:

```typescript
export interface TypeDefinitionOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `TypeDefinitionRegistrationOptions` defined as follows:

```typescript
export interface TypeDefinitionRegistrationOptions extends
	TextDocumentRegistrationOptions, TypeDefinitionOptions,
	StaticRegistrationOptions {
}
```

_Request_:
- method: `textDocument/typeDefinition`
- params: `TypeDefinitionParams` defined as follows:

```typescript
export interface TypeDefinitionParams extends TextDocumentPositionParams,
	WorkDoneProgressParams, PartialResultParams {
}
```

_Response_:
- result: [`Location`](#location) \| [`Location`](#location)[] \| [`LocationLink`](#locationlink)[] \| `null`
- partial result: [`Location`](#location)[] \| [`LocationLink`](#locationlink)[]
- error: code and message set in case an exception happens during the definition request.

#### Go to Implementation Request

> *Since version 3.6.0*

The go to implementation request is sent from the client to the server to resolve the implementation location of a symbol at a given text document position.

The result type [`LocationLink`](#locationlink)[] got introduced with version 3.14.0 and depends on the corresponding client capability `textDocument.implementation.linkSupport`.

_Client Capability_:
- property name (optional): `textDocument.implementation`
- property type: `ImplementationClientCapabilities` defined as follows:

```typescript
export interface ImplementationClientCapabilities {
	/**
	 * Whether the implementation supports dynamic registration. If this is set to
	 * `true`, the client supports the new `ImplementationRegistrationOptions`
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

_Server Capability_:
- property name (optional): `implementationProvider`
- property type: `boolean | ImplementationOptions | ImplementationRegistrationOptions` where `ImplementationOptions` is defined as follows:

```typescript
export interface ImplementationOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `ImplementationRegistrationOptions` defined as follows:

```typescript
export interface ImplementationRegistrationOptions extends
	TextDocumentRegistrationOptions, ImplementationOptions,
	StaticRegistrationOptions {
}
```

_Request_:
- method: `textDocument/implementation`
- params: `ImplementationParams` defined as follows:

```typescript
export interface ImplementationParams extends TextDocumentPositionParams,
	WorkDoneProgressParams, PartialResultParams {
}
```

_Response_:
- result: [`Location`](#location) \| [`Location`](#location)[] \| [`LocationLink`](#locationlink)[] \| `null`
- partial result: [`Location`](#location)[] \| [`LocationLink`](#locationlink)[]
- error: code and message set in case an exception happens during the definition request.

#### Find References Request

The references request is sent from the client to the server to resolve project-wide references for the symbol denoted by the given text document position.

_Client Capability_:
- property name (optional): `textDocument.references`
- property type: `ReferenceClientCapabilities` defined as follows:

```typescript
export interface ReferenceClientCapabilities {
	/**
	 * Whether references supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:
- property name (optional): `referencesProvider`
- property type: `boolean | ReferenceOptions` where `ReferenceOptions` is defined as follows:

```typescript
export interface ReferenceOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `ReferenceRegistrationOptions` defined as follows:

```typescript
export interface ReferenceRegistrationOptions extends
	TextDocumentRegistrationOptions, ReferenceOptions {
}
```

_Request_:
- method: `textDocument/references`
- params: `ReferenceParams` defined as follows:

```typescript
export interface ReferenceParams extends TextDocumentPositionParams,
	WorkDoneProgressParams, PartialResultParams {
	context: ReferenceContext;
}
```

```typescript
export interface ReferenceContext {
	/**
	 * Include the declaration of the current symbol.
	 */
	includeDeclaration: boolean;
}
```
_Response_:
- result: [`Location`](#location)[] \| `null`
- partial result: [`Location`](#location)[]
- error: code and message set in case an exception happens during the reference request.

#### Prepare Call Hierarchy Request

> *Since version 3.16.0*

The call hierarchy request is sent from the client to the server to return a call hierarchy for the language element of the given text document positions. The call hierarchy requests are executed in two steps:

  1. first a call hierarchy item is resolved for the given text document position
  1. for a call hierarchy item, the incoming or outgoing call hierarchy items are resolved.

_Client Capability_:

- property name (optional): `textDocument.callHierarchy`
- property type: `CallHierarchyClientCapabilities` defined as follows:

```typescript
interface CallHierarchyClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * `true` the client supports the new `(TextDocumentRegistrationOptions &
	 * StaticRegistrationOptions)` return value for the corresponding server
	 * capability as well.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:

- property name (optional): `callHierarchyProvider`
- property type: `boolean | CallHierarchyOptions | CallHierarchyRegistrationOptions` where `CallHierarchyOptions` is defined as follows:

```typescript
export interface CallHierarchyOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `CallHierarchyRegistrationOptions` defined as follows:

```typescript
export interface CallHierarchyRegistrationOptions extends
	TextDocumentRegistrationOptions, CallHierarchyOptions,
	StaticRegistrationOptions {
}
```

_Request_:

- method: `textDocument/prepareCallHierarchy`
- params: `CallHierarchyPrepareParams` defined as follows:

```typescript
export interface CallHierarchyPrepareParams extends TextDocumentPositionParams,
	WorkDoneProgressParams {
}
```

_Response_:

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
	 * `range`.
	 */
	selectionRange: Range;

	/**
	 * A data entry field that is preserved between a call hierarchy prepare and
	 * incoming calls or outgoing calls requests.
	 */
	data?: LSPAny;
}
```

- error: code and message set in case an exception happens during the 'textDocument/prepareCallHierarchy' request

#### Call Hierarchy Incoming Calls

> *Since version 3.16.0*

The request is sent from the client to the server to resolve incoming calls for a given call hierarchy item. The request doesn't define its own client and server capabilities. It is only issued if a server registers for the [`textDocument/prepareCallHierarchy` request](#prepare-call-hierarchy-request).

_Request_:

- method: `callHierarchy/incomingCalls`
- params: `CallHierarchyIncomingCallsParams` defined as follows:

```typescript
export interface CallHierarchyIncomingCallsParams extends
	WorkDoneProgressParams, PartialResultParams {
	item: CallHierarchyItem;
}
```

_Response_:

- result: `CallHierarchyIncomingCall[] | null` defined as follows:

```typescript
export interface CallHierarchyIncomingCall {

	/**
	 * The item that makes the call.
	 */
	from: CallHierarchyItem;

	/**
	 * The ranges at which the calls appear. This is relative to the caller
	 * denoted by `this.from`.
	 */
	fromRanges: Range[];
}
```

- partial result: `CallHierarchyIncomingCall[]`
- error: code and message set in case an exception happens during the 'callHierarchy/incomingCalls' request

#### Call Hierarchy Outgoing Calls

> *Since version 3.16.0*

The request is sent from the client to the server to resolve outgoing calls for a given call hierarchy item. The request doesn't define its own client and server capabilities. It is only issued if a server registers for the [`textDocument/prepareCallHierarchy` request](#prepare-call-hierarchy-request).

_Request_:

- method: `callHierarchy/outgoingCalls`
- params: `CallHierarchyOutgoingCallsParams` defined as follows:

```typescript
export interface CallHierarchyOutgoingCallsParams extends
	WorkDoneProgressParams, PartialResultParams {
	item: CallHierarchyItem;
}
```

_Response_:

- result: `CallHierarchyOutgoingCall[] | null` defined as follows:

```typescript
export interface CallHierarchyOutgoingCall {

	/**
	 * The item that is called.
	 */
	to: CallHierarchyItem;

	/**
	 * The range at which this item is called. This is the range relative to
	 * the caller, e.g., the item passed to `callHierarchy/outgoingCalls` request.
	 */
	fromRanges: Range[];
}
```

- partial result: `CallHierarchyOutgoingCall[]`
- error: code and message set in case an exception happens during the 'callHierarchy/outgoingCalls' request

#### Prepare Type Hierarchy Request

> *Since version 3.17.0*

The type hierarchy request is sent from the client to the server to return a type hierarchy for the language element of given text document positions. Will return `null` if the server couldn't infer a valid type from the position. The type hierarchy requests are executed in two steps:

  1. first a type hierarchy item is prepared for the given text document position.
  1. for a type hierarchy item, the supertype or subtype type hierarchy items are resolved.

_Client Capability_:

- property name (optional): `textDocument.typeHierarchy`
- property type: `TypeHierarchyClientCapabilities` defined as follows:

```typescript
type TypeHierarchyClientCapabilities = {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * `true` the client supports the new `(TextDocumentRegistrationOptions &
	 * StaticRegistrationOptions)` return value for the corresponding server
	 * capability as well.
	 */
	dynamicRegistration?: boolean;
};
```

_Server Capability_:

- property name (optional): `typeHierarchyProvider`
- property type: `boolean | TypeHierarchyOptions | TypeHierarchyRegistrationOptions` where `TypeHierarchyOptions` is defined as follows:

```typescript
export interface TypeHierarchyOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `TypeHierarchyRegistrationOptions` defined as follows:

```typescript
export interface TypeHierarchyRegistrationOptions extends
	TextDocumentRegistrationOptions, TypeHierarchyOptions,
	StaticRegistrationOptions {
}
```

_Request_:

- method: 'textDocument/prepareTypeHierarchy'
- params: `TypeHierarchyPrepareParams` defined as follows:

```typescript
export interface TypeHierarchyPrepareParams extends TextDocumentPositionParams,
	WorkDoneProgressParams {
}
```

_Response_:

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
	 * `range`.
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

- error: code and message set in case an exception happens during the 'textDocument/prepareTypeHierarchy' request

#### Type Hierarchy Supertypes

> *Since version 3.17.0*

The request is sent from the client to the server to resolve the supertypes for a given type hierarchy item. Will return `null` if the server couldn't infer a valid type from `item` in the params. The request doesn't define its own client and server capabilities. It is only issued if a server registers for the [`textDocument/prepareTypeHierarchy` request](#prepare-type-hierarchy-request).

_Request_:

- method: 'typeHierarchy/supertypes'
- params: `TypeHierarchySupertypesParams` defined as follows:

```typescript
export interface TypeHierarchySupertypesParams extends
	WorkDoneProgressParams, PartialResultParams {
	item: TypeHierarchyItem;
}
```
_Response_:

- result: `TypeHierarchyItem[] | null`
- partial result: `TypeHierarchyItem[]`
- error: code and message set in case an exception happens during the 'typeHierarchy/supertypes' request

#### Type Hierarchy Subtypes

> *Since version 3.17.0*

The request is sent from the client to the server to resolve the subtypes for a given type hierarchy item. Will return `null` if the server couldn't infer a valid type from `item` in the params. The request doesn't define its own client and server capabilities. It is only issued if a server registers for the [`textDocument/prepareTypeHierarchy` request](#prepare-type-hierarchy-request).

_Request_:

- method: 'typeHierarchy/subtypes'
- params: `TypeHierarchySubtypesParams` defined as follows:

```typescript
export interface TypeHierarchySubtypesParams extends
	WorkDoneProgressParams, PartialResultParams {
	item: TypeHierarchyItem;
}
```
_Response_:

- result: `TypeHierarchyItem[] | null`
- partial result: `TypeHierarchyItem[]`
- error: code and message set in case an exception happens during the 'typeHierarchy/subtypes' request

#### Document Highlights Request

The document highlight request is sent from the client to the server to resolve document highlights for a given text document position.
For programming languages, this usually highlights all references to the symbol scoped to this file. However, we kept 'textDocument/documentHighlight'
and 'textDocument/references' separate requests since the first one is allowed to be more fuzzy. Symbol matches usually have a `DocumentHighlightKind`
of `Read` or `Write` whereas fuzzy or textual matches use `Text` as the kind.

_Client Capability_:
- property name (optional): `textDocument.documentHighlight`
- property type: `DocumentHighlightClientCapabilities` defined as follows:

```typescript
export interface DocumentHighlightClientCapabilities {
	/**
	 * Whether document highlight supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:
- property name (optional): `documentHighlightProvider`
- property type: `boolean | DocumentHighlightOptions` where `DocumentHighlightOptions` is defined as follows:

```typescript
export interface DocumentHighlightOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `DocumentHighlightRegistrationOptions` defined as follows:

```typescript
export interface DocumentHighlightRegistrationOptions extends
	TextDocumentRegistrationOptions, DocumentHighlightOptions {
}
```

_Request_:
- method: `textDocument/documentHighlight`
- params: `DocumentHighlightParams` defined as follows:

```typescript
export interface DocumentHighlightParams extends TextDocumentPositionParams,
	WorkDoneProgressParams, PartialResultParams {
}
```

_Response_:
- result: `DocumentHighlight[]` \| `null` defined as follows:

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

_Client Capability_:
- property name (optional): `textDocument.documentLink`
- property type: `DocumentLinkClientCapabilities` defined as follows:

```typescript
export interface DocumentLinkClientCapabilities {
	/**
	 * Whether document link supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Whether the client supports the `tooltip` property on `DocumentLink`.
	 *
	 * @since 3.15.0
	 */
	tooltipSupport?: boolean;
}
```

_Server Capability_:
- property name (optional): `documentLinkProvider`
- property type: `DocumentLinkOptions` defined as follows:

```typescript
export interface DocumentLinkOptions extends WorkDoneProgressOptions {
	/**
	 * Document links have a resolve provider as well.
	 */
	resolveProvider?: boolean;
}
```

_Registration Options_: `DocumentLinkRegistrationOptions` defined as follows:

```typescript
export interface DocumentLinkRegistrationOptions extends
	TextDocumentRegistrationOptions, DocumentLinkOptions {
}
```

_Request_:
- method: `textDocument/documentLink`
- params: `DocumentLinkParams` defined as follows:

```typescript
interface DocumentLinkParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The document to provide document links for.
	 */
	textDocument: TextDocumentIdentifier;
}
```

_Response_:
- result: `DocumentLink[]` \| `null`.

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
	 * The URI this link points to. If missing, a resolve request is sent later.
	 */
	target?: URI;

	/**
	 * The tooltip text when you hover over this link.
	 *
	 * If a tooltip is provided, it will be displayed in a string that includes
	 * instructions on how to trigger the link, such as `{0} (ctrl + click)`.
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

_Request_:
- method: `documentLink/resolve`
- params: `DocumentLink`

_Response_:
- result: `DocumentLink`
- error: code and message set in case an exception happens during the document link resolve request.

#### Hover Request

The hover request is sent from the client to the server to request hover information at a given text document position.

When the client sends a hover request, the position typically refers to the position immediately to the left of the character being hovered over. For example, when a user hovers over a character `c` at offset `n`, the client typically sends position `n` (the position before the character). However, how servers interpret this position and what hover information they return is language and implementation specific.

_Client Capability_:
- property name (optional): `textDocument.hover`
- property type: `HoverClientCapabilities` defined as follows:

```typescript
export interface HoverClientCapabilities {
	/**
	 * Whether hover supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Client supports the following content formats if the content
	 * property refers to a `literal of type MarkupContent`.
	 * The order describes the preferred format of the client.
	 */
	contentFormat?: MarkupKind[];
}
```

_Server Capability_:
- property name (optional): `hoverProvider`
- property type: `boolean | HoverOptions` where `HoverOptions` is defined as follows:

```typescript
export interface HoverOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `HoverRegistrationOptions` defined as follows:

```typescript
export interface HoverRegistrationOptions
	extends TextDocumentRegistrationOptions, HoverOptions {
}
```

_Request_:
- method: `textDocument/hover`
- params: `HoverParams` defined as follows:

```typescript
export interface HoverParams extends TextDocumentPositionParams,
	WorkDoneProgressParams {
}
```

_Response_:
- result: `Hover` \| `null` defined as follows:

```typescript
/**
 * The result of a hover request.
 */
export interface Hover {
	/**
	 * The hover's content.
	 */
	contents: MarkedString | MarkedString[] | MarkupContent;

	/**
	 * An optional range is a range inside a text document
	 * that is used to visualize a hover, e.g. by changing the background color.
	 */
	range?: Range;
}
```

Where `MarkedString` is defined as follows:

```typescript
/**
 * MarkedString can be used to render human readable text. It is either a
 * markdown string or a code-block that provides a language and a code snippet.
 * The language identifier is semantically equal to the optional language
 * identifier in fenced code blocks in GitHub issues.
 *
 * The pair of a language and a value is an equivalent to markdown:
 * ```${language}
 * ${value}
 * ```
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

_Client Capability_:
- property name (optional): `textDocument.codeLens`
- property type: `CodeLensClientCapabilities` defined as follows:

```typescript
export interface CodeLensClientCapabilities {
	/**
	 * Whether code lens supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Whether the client supports resolving additional code lens
	 * properties via a separate `codeLens/resolve` request.
	 *
	 * @since 3.18.0
	 */
	resolveSupport?: ClientCodeLensResolveOptions;
}

/**
 * @since 3.18.0
 */
export type ClientCodeLensResolveOptions = {
	/**
	 * The properties that a client can resolve lazily.
	 */
	properties: string[];
};
```

_Server Capability_:
- property name (optional): `codeLensProvider`
- property type: `CodeLensOptions` defined as follows:

```typescript
export interface CodeLensOptions extends WorkDoneProgressOptions {
	/**
	 * Code lens has a resolve provider as well.
	 */
	resolveProvider?: boolean;
}
```

_Registration Options_: `CodeLensRegistrationOptions` defined as follows:

```typescript
export interface CodeLensRegistrationOptions extends
	TextDocumentRegistrationOptions, CodeLensOptions {
}
```

_Request_:
- method: `textDocument/codeLens`
- params: `CodeLensParams` defined as follows:

```typescript
interface CodeLensParams extends WorkDoneProgressParams, PartialResultParams {
	/**
	 * The document to request code lens for.
	 */
	textDocument: TextDocumentIdentifier;
}
```

_Response_:
- result: `CodeLens[]` \| `null` defined as follows:

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

_Client Capability_:
- property name (optional): `textDocument.codeLens.resolveSupport`
- property type: `ClientCodeLensResolveOptions`

_Request_:
- method: `codeLens/resolve`
- params: `CodeLens`

_Response_:
- result: `CodeLens`
- error: code and message set in case an exception happens during the code lens resolve request.

#### Code Lens Refresh Request

> *Since version 3.16.0*

The `workspace/codeLens/refresh` request is sent from the server to the client. Servers can use it to ask clients to refresh the code lenses currently shown in editors. As a result the client should ask the server to recompute the code lenses for these editors. This is useful if a server detects a configuration change which requires a re-calculation of all code lenses. Note that the client still has the freedom to delay the re-calculation of the code lenses if, for example, an editor is currently not visible.

_Client Capability_:

- property name (optional): `workspace.codeLens`
- property type: `CodeLensWorkspaceClientCapabilities` defined as follows:

```typescript
export interface CodeLensWorkspaceClientCapabilities {
	/**
	 * Whether the client implementation supports a refresh request sent from the
	 * server to the client.
	 *
	 * Note that this event is global and will force the client to refresh all
	 * code lenses currently shown. It should be used with absolute care and is
	 * useful for situation where a server, for example, detects a project wide
	 * change that requires such a calculation.
	 */
	refreshSupport?: boolean;
}
```

_Request_:

- method: `workspace/codeLens/refresh`
- params: none

_Response_:

- result: void
- error: code and message set in case an exception happens during the 'workspace/codeLens/refresh' request

#### Folding Range Request

> *Since version 3.10.0*

The folding range request is sent from the client to the server to return all folding ranges found in a given text document.

_Client Capability_:
- property name (optional): `textDocument.foldingRange`
- property type: `FoldingRangeClientCapabilities` defined as follows:

```typescript
export interface FoldingRangeClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration for folding range
	 * providers. If this is set to `true` the client supports the new
	 * `FoldingRangeRegistrationOptions` return value for the corresponding
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
	 * If set, client will ignore specified `startCharacter` and `endCharacter`
	 * properties in a FoldingRange.
	 */
	lineFoldingOnly?: boolean;

	/**
	 * Specific options for the folding range kind.
	 *
	 * @since 3.17.0
	 */
	foldingRangeKind?: ClientFoldingRangeKindOptions;

	/**
	 * Specific options for the folding range.
	 *
	 * @since 3.17.0
	 */
	foldingRange?: ClientFoldingRangeOptions;
}
```

```typescript
export type ClientFoldingRangeKindOptions = {
	/**
	 * The folding range kind values the client supports. When this
	 * property exists the client also guarantees that it will
	 * handle values outside its set gracefully and falls back
	 * to a default value when unknown.
	 */
	valueSet?: FoldingRangeKind[];
};
```

```typescript
export type ClientFoldingRangeOptions = {
	/**
	 * If set, the client signals that it supports setting collapsedText on
	 * folding ranges to display custom labels instead of the default text.
	 *
	 * @since 3.17.0
	 */
	collapsedText?: boolean;
};
```

_Server Capability_:
- property name (optional): `foldingRangeProvider`
- property type: `boolean | FoldingRangeOptions | FoldingRangeRegistrationOptions` where `FoldingRangeOptions` is defined as follows:

```typescript
export interface FoldingRangeOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `FoldingRangeRegistrationOptions` defined as follows:

```typescript
export interface FoldingRangeRegistrationOptions extends
	TextDocumentRegistrationOptions, FoldingRangeOptions,
	StaticRegistrationOptions {
}
```

_Request_:

- method: `textDocument/foldingRange`
- params: `FoldingRangeParams` defined as follows

```typescript
export interface FoldingRangeParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;
}
```

_Response_:
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
	 * Folding range for a region (e.g. `#region`)
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
	 * Describes the kind of the folding range such as `comment` or `region`.
	 * The kind is used to categorize folding ranges and used by commands like
	 * 'Fold all comments'. See FoldingRangeKind for an
	 * enumeration of standardized kinds.
	 */
	kind?: FoldingRangeKind;

	/**
	 * The text that the client should show when the specified range is
	 * collapsed. If not defined or not supported by the client, a default
	 * will be chosen by the client.
	 *
	 * @since 3.17.0
	 */
	collapsedText?: string;
}
```

- partial result: `FoldingRange[]`
- error: code and message set in case an exception happens during the 'textDocument/foldingRange' request

#### Folding Range Refresh Request

> *Since version 3.18.0*

The `workspace/foldingRange/refresh` request is sent from the server to the client. Servers can use it to ask clients to refresh the folding ranges currently shown in editors. As a result, the client should ask the server to recompute the folding ranges for these editors. This is useful if a server detects a configuration change which requires a re-calculation of all folding ranges. Note that the client still has the freedom to delay the re-calculation of the folding ranges if, for example, an editor is currently not visible.

_Client Capability_:

- property name (optional): `workspace.foldingRange`
- property type: `FoldingRangeWorkspaceClientCapabilities` defined as follows:

```typescript
export interface FoldingRangeWorkspaceClientCapabilities {
	/**
	 * Whether the client implementation supports a refresh request sent from the
	 * server to the client.
	 *
	 * Note that this event is global and will force the client to refresh all
	 * folding ranges currently shown. It should be used with absolute care and is
	 * useful for situation where a server, for example, detects a project wide
	 * change that requires such a calculation.
	 *
	 * @since 3.18.0
	 * @proposed
	 */
	refreshSupport?: boolean;
}
```

_Request_:

- method: `workspace/foldingRange/refresh`
- params: none

_Response_:

- result: void
- error: code and message set in case an exception happens during the 'workspace/foldingRange/refresh' request

#### Selection Range Request

> *Since version 3.15.0*

The selection range request is sent from the client to the server to return suggested selection ranges at an array of given positions. A selection range is a range around the cursor position which the user might be interested in selecting.

A selection range in the return array is for the position in the provided parameters at the same index. Therefore, positions[i] must be contained in result[i].range. To allow for results where some positions have selection ranges and others do not, result[i].range is allowed to be the empty range at positions[i].

Typically, but not necessary, selection ranges correspond to the nodes of the syntax tree.

_Client Capability_:
- property name (optional): `textDocument.selectionRange`
- property type: `SelectionRangeClientCapabilities` defined as follows:

```typescript
export interface SelectionRangeClientCapabilities {
	/**
	 * Whether the implementation supports dynamic registration for selection range
	 * providers. If this is set to `true`, the client supports the new
	 * `SelectionRangeRegistrationOptions` return value for the corresponding
	 * server capability as well.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:
- property name (optional): `selectionRangeProvider`
- property type: `boolean | SelectionRangeOptions | SelectionRangeRegistrationOptions` where `SelectionRangeOptions` is defined as follows:

```typescript
export interface SelectionRangeOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `SelectionRangeRegistrationOptions` defined as follows:

```typescript
export interface SelectionRangeRegistrationOptions extends
	SelectionRangeOptions, TextDocumentRegistrationOptions,
	StaticRegistrationOptions {
}
```

_Request_:

- method: `textDocument/selectionRange`
- params: `SelectionRangeParams` defined as follows:

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

_Response_:

- result: `SelectionRange[] | null` defined as follows:

```typescript
export interface SelectionRange {
	/**
	 * The range of this selection range.
	 */
	range: Range;
	/**
	 * The parent selection range containing this range.
	 * Therefore, `parent.range` must contain `this.range`.
	 */
	parent?: SelectionRange;
}
```

- partial result: `SelectionRange[]`
- error: code and message set in case an exception happens during the 'textDocument/selectionRange' request

#### Document Symbols Request

The document symbol request is sent from the client to the server. The returned result is either

- `SymbolInformation[]` which is a flat list of all symbols found in a given text document. Then neither the symbol's location range nor the symbol's container name should be used to infer a hierarchy.
- `DocumentSymbol[]` which is a hierarchy of symbols found in a given text document.

Servers should whenever possible return `DocumentSymbol` since it is the richer data structure.

_Client Capability_:
- property name (optional): `textDocument.documentSymbol`
- property type: `DocumentSymbolClientCapabilities` defined as follows:

```typescript
export interface DocumentSymbolClientCapabilities {
	/**
	 * Whether document symbol supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Specific capabilities for the `SymbolKind` in the
	 * `textDocument/documentSymbol` request.
	 */
	symbolKind?: ClientSymbolKindOptions;

	/**
	 * The client supports hierarchical document symbols.
	 */
	hierarchicalDocumentSymbolSupport?: boolean;

	/**
	 * The client supports tags on `SymbolInformation`. Tags are supported on
	 * `DocumentSymbol` if `hierarchicalDocumentSymbolSupport` is set to true.
	 * Clients supporting tags have to handle unknown tags gracefully.
	 *
	 * @since 3.16.0
	 */
	tagSupport?: ClientSymbolTagOptions;

	/**
	 * The client supports an additional label presented in the UI when
	 * registering a document symbol provider.
	 *
	 * @since 3.16.0
	 */
	labelSupport?: boolean;
}
```

```typescript
export type ClientSymbolKindOptions = {
	/**
	 * The symbol kind values the client supports. When this
	 * property exists the client also guarantees that it will
	 * handle values outside its set gracefully and falls back
	 * to a default value when unknown.
	 *
	 * If this property is not present the client only supports
	 * the symbol kinds from `File` to `Array` as defined in
	 * the initial version of the protocol.
	 */
	valueSet?: SymbolKind[];
};
```

```typescript
export type ClientSymbolTagOptions = {
	/**
	 * The tags supported by the client.
	 */
	valueSet: SymbolTag[];
};
```

_Server Capability_:
- property name (optional): `documentSymbolProvider`
- property type: `boolean | DocumentSymbolOptions` where `DocumentSymbolOptions` is defined as follows:

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

_Registration Options_: `DocumentSymbolRegistrationOptions` defined as follows:

```typescript
export interface DocumentSymbolRegistrationOptions extends
	TextDocumentRegistrationOptions, DocumentSymbolOptions {
}
```

_Request_:
- method: `textDocument/documentSymbol`
- params: `DocumentSymbolParams` defined as follows:

```typescript
export interface DocumentSymbolParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;
}
```

_Response_:
- result: `DocumentSymbol[]` \| `SymbolInformation[]` \| `null` defined as follows:

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

export type SymbolKind = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 |
	14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 | 24 | 25 | 26;
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
 * have two ranges: one that encloses their definition and one that points to
 * their most interesting range, e.g. the range of an identifier.
 */
export interface DocumentSymbol {

	/**
	 * The name of this symbol. Will be displayed in the user interface and
	 * therefore must not be an empty string or a string only consisting of
	 * white spaces.
	 */
	name: string;

	/**
	 * More detail for this symbol, e.g. the signature of a function.
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
	 * but everything else, like comments. This information is typically used to
	 * determine if the client's cursor is inside the symbol to reveal the
	 * symbol in the UI.
	 */
	range: Range;

	/**
	 * The range that should be selected and revealed when this symbol is being
	 * picked, e.g. the name of a function. Must be contained by the `range`.
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

- partial result: `DocumentSymbol[]` \| `SymbolInformation[]`. `DocumentSymbol[]` and `SymbolInformation[]` can not be mixed. That means the first chunk defines the type of all the other chunks.
- error: code and message set in case an exception happens during the document symbol request.

#### Semantic Tokens

> *Since version 3.16.0*

The request is sent from the client to the server to resolve semantic tokens for a given file. Semantic tokens are used to add additional color information to a file that depends on language specific symbol information. A semantic token request usually produces a large result. The protocol therefore supports encoding tokens with numbers. In addition, optional support for deltas is available.

_General Concepts_

Tokens are represented using one token type combined with token modifiers. A token type is something like `class` or `function` and token modifiers are like `static` or `async`. The protocol defines a set of token types and modifiers but clients are allowed to extend these and announce the values they support in the corresponding client capability. The predefined values are:

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
	decorator = 'decorator',
	/**
	 * @since 3.18.0
	 */
	label = 'label'
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

The protocol defines an additional token format capability to allow future extensions of the format. The only format that is currently specified is `relative`, expressing that the tokens are described using relative positions (see Integer Encoding for Tokens below).

```typescript
export namespace TokenFormat {
	export const Relative: 'relative' = 'relative';
}

export type TokenFormat = 'relative';
```

_Integer Encoding for Tokens_

On the capability level, types and modifiers are defined using strings. However, the real encoding happens using integers. The server therefore needs to let the client know which numbers it is using for which types and modifiers. They do so using a legend, which is defined as follows:

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

Token types are looked up by index, so a `tokenType` value of `1` means `tokenTypes[1]`. Since a token type can have multiple modifiers, those token modifiers can be set by using bit flags,
so a `tokenModifier` value of `3` is first viewed as binary `0b00000011`, which means `[tokenModifiers[0], tokenModifiers[1]]` because bits 0 and 1 are set.

There are two different ways how the position of a token can be expressed in a file: Absolute positions or relative positions. The protocol for the token format `relative` uses relative positions, because most tokens remain stable relative to each other when edits are made in a file. This simplifies the computation of a delta if a server supports it. Each token is represented using 5 integers. A specific token `i` in the file consists of the following array indices:

- at index `5*i`   - `deltaLine`: token line number, relative to the start of the previous token.
- at index `5*i+1` - `deltaStart`: token start character, relative to the start of the previous token (relative to 0 or the previous token's start if they are on the same line).
- at index `5*i+2` - `length`: the length of the token.
- at index `5*i+3` - `tokenType`: will be looked up in `SemanticTokensLegend.tokenTypes`. We currently ask that `tokenType` < 65536.
- at index `5*i+4` - `tokenModifiers`: each set bit will be looked up in `SemanticTokensLegend.tokenModifiers`.

The `deltaStart` and the `length` values must be encoded using the encoding the client and server agrees on during the `initialize` request (see also [TextDocuments](#text-documents)).
Whether a token can span multiple lines is defined by the client capability `multilineTokenSupport`. If multiline tokens are not supported and a tokens length takes it past the end of the line, it should be treated as if the token ends at the end of the line and will not wrap onto the next line.

The client capability `overlappingTokenSupport` defines whether tokens can overlap each other.

Let's look at a concrete example which uses single line tokens without overlaps for encoding a file with 3 tokens in a number array. We start with absolute positions to demonstrate how they can easily be transformed into relative positions:

```typescript
{ line: 2, startChar:  5, length: 3, tokenType: "property",
	tokenModifiers: ["private", "static"]
},
{ line: 2, startChar: 10, length: 4, tokenType: "type", tokenModifiers: [] },
{ line: 5, startChar:  2, length: 7, tokenType: "class", tokenModifiers: [] }
```

First of all, a legend must be devised. This legend must be provided up-front on registration and capture all possible token types and modifiers. For the example, we use this legend:

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

The delta is now expressed on these number arrays without any form of interpretation what these numbers mean. This is comparable to the text document edits sent from the server to the client to modify the content of a file. Those are character based and don't make any assumption about the meaning of the characters. So, `[  2,5,3,0,3,  0,5,4,1,0,  3,2,7,2,0 ]` can be transformed into `[  3,5,3,0,3,  0,5,4,1,0,  3,2,7,2,0]` using the following edit description: `{ start:  0, deleteCount: 1, data: [3] }` which tells the client to simply replace the first number (e.g. `2`) in the array with `3`.

Semantic token edits behave conceptually like [text edits](#textedit) on documents: if an edit description consists of n edits, all n edits are based on the same state Sm of the number array. They will move the number array from state Sm to Sm+1. A client applying the edits must not assume that they are sorted. An easy algorithm to apply them to the number array is to sort the edits and apply them from the back to the front of the number array.

_Client Capability_:

The following client capabilities are defined for semantic token requests sent from the client to the server:

- property name (optional): `textDocument.semanticTokens`
- property type: `SemanticTokensClientCapabilities` defined as follows:

```typescript
interface SemanticTokensClientCapabilities {
	/**
	 * Whether the implementation supports dynamic registration. If this is set to
	 * `true`, the client supports the new `(TextDocumentRegistrationOptions &
	 * StaticRegistrationOptions)` return value for the corresponding server
	 * capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Which requests the client supports and might send to the server
	 * depending on the server's capability. Please note that clients might not
	 * show semantic tokens or degrade some of the user experience if a range
	 * or full request is advertised by the client but not provided by the
	 * server. If, for example, the client capability `requests.full` and
	 * `request.range` are both set to true but the server only provides a
	 * range provider, the client might not render a minimap correctly or might
	 * even decide to not show any semantic tokens at all.
	 */
	requests: ClientSemanticTokensRequestOptions;

	/**
	 * The token types that the client supports.
	 */
	tokenTypes: string[];

	/**
	 * The token modifiers that the client supports.
	 */
	tokenModifiers: string[];

	/**
	 * The formats the client supports.
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
	 * ErrorCodes.ServerCancelled. If a server does so, the client
	 * needs to retrigger the request.
	 *
	 * @since 3.17.0
	 */
	serverCancelSupport?: boolean;

	/**
	 * Whether the client uses semantic tokens to augment existing
	 * syntax tokens. If set to `true`, client side created syntax
	 * tokens and semantic tokens are both used for colorization. If
	 * set to `false`, the client only uses the returned semantic tokens
	 * for colorization.
	 *
	 * If the value is `undefined` then the client behavior is not
	 * specified.
	 *
	 * @since 3.17.0
	 */
	augmentsSyntaxTokens?: boolean;
}
```

```typescript
export type ClientSemanticTokensRequestOptions = {
	/**
	 * The client will send the `textDocument/semanticTokens/range` request if
	 * the server provides a corresponding handler.
	 */
	range?: boolean | {
	};

	/**
	 * The client will send the `textDocument/semanticTokens/full` request if
	 * the server provides a corresponding handler.
	 */
	full?: boolean | ClientSemanticTokensRequestFullDelta;
};
```

```typescript
export type ClientSemanticTokensRequestFullDelta = {
	/**
	 * The client will send the `textDocument/semanticTokens/full/delta` request if
	 * the server provides a corresponding handler.
	 */
	delta?: boolean;
};
```

_Server Capability_:

The following server capabilities are defined for semantic tokens:

- property name (optional): `semanticTokensProvider`
- property type: `SemanticTokensOptions | SemanticTokensRegistrationOptions` where `SemanticTokensOptions` is defined as follows:

```typescript
export interface SemanticTokensOptions extends WorkDoneProgressOptions {
	/**
	 * The legend used by the server.
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
	full?: boolean | SemanticTokensFullDelta;
}
```

```typescript
/**
 * Semantic tokens options to support deltas for full documents
 */
export type SemanticTokensFullDelta = {
	/**
	 * The server supports deltas for full documents.
	 */
	delta?: boolean;
};
```

_Registration Options_: `SemanticTokensRegistrationOptions` defined as follows:

```typescript
export interface SemanticTokensRegistrationOptions extends
	TextDocumentRegistrationOptions, SemanticTokensOptions,
	StaticRegistrationOptions {
}
```

Since the registration option handles range, full and delta requests, the method used to register for semantic tokens requests is `textDocument/semanticTokens` and not one of the specific methods described below.

**Requesting semantic tokens for a whole file**

_Request_:

- method: `textDocument/semanticTokens/full`
- params: `SemanticTokensParams` defined as follows:

```typescript
export interface SemanticTokensParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;
}
```

_Response_:

- result: `SemanticTokens | null` where `SemanticTokens` is defined as follows:

```typescript
export interface SemanticTokens {
	/**
	 * An optional result ID. If provided and clients support delta updating,
	 * the client will include the result ID in the next semantic token request.
	 * A server can then, instead of computing all semantic tokens again, simply
	 * send a delta.
	 */
	resultId?: string;

	/**
	 * The actual tokens.
	 */
	data: uinteger[];
}
```

- partial result: `SemanticTokensPartialResult` defines as follows:

```typescript
export interface SemanticTokensPartialResult {
	data: uinteger[];
}
```

- error: code and message set in case an exception happens during the 'textDocument/semanticTokens/full' request

**Requesting semantic token delta for a whole file**

_Request_:

- method: `textDocument/semanticTokens/full/delta`
- params: `SemanticTokensDeltaParams` defined as follows:

```typescript
export interface SemanticTokensDeltaParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The result ID of a previous response. The result ID can either point to
	 * a full response or a delta response, depending on what was received last.
	 */
	previousResultId: string;
}
```

_Response_:

- result: `SemanticTokens | SemanticTokensDelta | null` where `SemanticTokensDelta` is defined as follows:

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

- partial result: `SemanticTokensDeltaPartialResult` defines as follows:

```typescript
export interface SemanticTokensDeltaPartialResult {
	edits: SemanticTokensEdit[];
}
```

- error: code and message set in case an exception happens during the 'textDocument/semanticTokens/full/delta' request

**Requesting semantic tokens for a range**

There are two uses cases where it can be beneficial to only compute semantic tokens for a visible range:

- for faster rendering of the tokens in the user interface when a user opens a file. In this use case, servers should also implement the `textDocument/semanticTokens/full` request as well to allow for flicker free scrolling and semantic coloring of a minimap.
- if computing semantic tokens for a full document is too expensive, servers can only provide a range call. In this case, the client might not render a minimap correctly or might even decide to not show any semantic tokens at all.

A server is allowed to compute the semantic tokens for a broader range than requested by the client. However, if the server does so, the semantic tokens for the broader range must be complete and correct. If a token at the beginning or end only partially overlaps with the requested range the server should include those tokens in the response.

_Request_:

- method: `textDocument/semanticTokens/range`
- params: `SemanticTokensRangeParams` defined as follows:

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

_Response_:

- result: `SemanticTokens | null`
- partial result: `SemanticTokensPartialResult`
- error: code and message set in case an exception happens during the 'textDocument/semanticTokens/range' request

**Requesting a refresh of all semantic tokens**

The `workspace/semanticTokens/refresh` request is sent from the server to the client. Servers can use it to ask clients to refresh the editors for which this server provides semantic tokens. As a result, the client should ask the server to recompute the semantic tokens for these editors. This is useful if a server detects a project wide configuration change which requires a re-calculation of all semantic tokens. Note that the client still has the freedom to delay the re-calculation of the semantic tokens if, for example, an editor is currently not visible.

_Client Capability_:

- property name (optional): `workspace.semanticTokens`
- property type: `SemanticTokensWorkspaceClientCapabilities` defined as follows:

```typescript
export interface SemanticTokensWorkspaceClientCapabilities {
	/**
	 * Whether the client implementation supports a refresh request sent from
	 * the server to the client.
	 *
	 * Note that this event is global and will force the client to refresh all
	 * semantic tokens currently shown. It should be used with absolute care
	 * and is useful for situation where a server, for example, detects a project
	 * wide change that requires such a calculation.
	 */
	refreshSupport?: boolean;
}
```

_Request_:

- method: `workspace/semanticTokens/refresh`
- params: none

_Response_:

- result: void
- error: code and message set in case an exception happens during the 'workspace/semanticTokens/refresh' request

#### Inlay Hint Request

> *Since version 3.17.0*

The inlay hints request is sent from the client to the server to compute inlay hints for a given [text document, range] tuple that may be rendered in the editor in place with other text.

_Client Capability_:
- property name (optional): `textDocument.inlayHint`
- property type: `InlayHintClientCapabilities` defined as follows:

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
	resolveSupport?: ClientInlayHintResolveOptions;
}
```

```typescript
export type ClientInlayHintResolveOptions = {
	/**
	 * The properties that a client can resolve lazily.
	 */
	properties: string[];
};
```

_Server Capability_:
- property name (optional): `inlayHintProvider`
- property type: `InlayHintOptions` defined as follows:

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

_Registration Options_: `InlayHintRegistrationOptions` defined as follows:

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

_Request_:
- method: `textDocument/inlayHint`
- params: `InlayHintParams` defined as follows:

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

_Response_:
- result: `InlayHint[]` \| `null` defined as follows:

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
	 * Depending on the client capability `inlayHint.resolveSupport`,
	 * clients might resolve this property late using the resolve request.
	 */
	textEdits?: TextEdit[];

	/**
	 * The tooltip text when you hover over this item.
	 *
	 * Depending on the client capability `inlayHint.resolveSupport` clients
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
	 * a `textDocument/inlayHint` and an `inlayHint/resolve` request.
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
	 * the client capability `inlayHint.resolveSupport`, clients might resolve
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
	 * Depending on the client capability `inlayHint.resolveSupport` clients
	 * might resolve this property late using the resolve request.
	 */
	location?: Location;

	/**
	 * An optional command for this label part.
	 *
	 * Depending on the client capability `inlayHint.resolveSupport`, clients
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
	 * An inlay hint that is for a type annotation.
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

The request is sent from the client to the server to resolve additional information for a given inlay hint. This is usually used to compute
the `tooltip`, `location` or `command` properties of an inlay hint's label part to avoid its unnecessary computation during the `textDocument/inlayHint` request.

Consider the client announcing the `label.location` property as a property that can be resolved lazily using the client capability

```typescript
textDocument.inlayHint.resolveSupport = { properties: ['label.location'] };
```

then an inlay hint with a label part without a location needs to be resolved using the `inlayHint/resolve` request before it can be used.

_Client Capability_:
- property name (optional): `textDocument.inlayHint.resolveSupport`
- property type: `{ properties: string[]; }`

_Request_:
- method: `inlayHint/resolve`
- params: `InlayHint`

_Response_:
- result: `InlayHint`
- error: code and message set in case an exception happens during the completion resolve request.

#### Inlay Hint Refresh Request

> *Since version 3.17.0*

The `workspace/inlayHint/refresh` request is sent from the server to the client. Servers can use it to ask clients to refresh the inlay hints currently shown in editors. As a result, the client should ask the server to recompute the inlay hints for these editors. This is useful if a server detects a configuration change which requires a re-calculation of all inlay hints. Note that the client still has the freedom to delay the re-calculation of the inlay hints if, for example, an editor is currently not visible.

_Client Capability_:

- property name (optional): `workspace.inlayHint`
- property type: `InlayHintWorkspaceClientCapabilities` defined as follows:

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
	 * is useful for situations where a server, for example, detects a project wide
	 * change that requires such a calculation.
	 */
	refreshSupport?: boolean;
}
```

_Request_:
- method: `workspace/inlayHint/refresh`
- params: none

_Response_:

- result: void
- error: code and message set in case an exception happens during the 'workspace/inlayHint/refresh' request

#### Inline Value Request

> *Since version 3.17.0*

The request is sent from the client to the server to return entries in a given document range for which inline values may be computed and rendered in the editor at the end of lines.
For programming languages, the editor usually uses a debugger to get the value of an entry.

_Client Capability_:
- property name (optional): `textDocument.inlineValue`
- property type: `InlineValueClientCapabilities` defined as follows:

```typescript
/**
 * Client capabilities specific to inline values.
 *
 * @since 3.17.0
 */
export interface InlineValueClientCapabilities {
	/**
	 * Whether the implementation supports dynamic registration for inline
	 * value providers.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:
- property name (optional): `inlineValueProvider`
- property type: `InlineValueOptions` defined as follows:

```typescript
/**
 * Inline value options used during static registration.
 *
 * @since 3.17.0
 */
export interface InlineValueOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `InlineValueRegistrationOptions` defined as follows:

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

_Request_:
- method: `textDocument/inlineValue`
- params: `InlineValueParams` defined as follows:

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
	 * The document range for which inline values information will be returned.
	 */
	range: Range;

	/**
	 * Additional information about the context in which inline values information was
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
	 * The stack frame (as a DAP ID) where the execution has stopped.
	 */
	frameId: integer;

	/**
	 * The document range where execution has stopped.
	 * Typically, the end position of the range denotes the line where the
	 * inline values are shown.
	 */
	stoppedLocation: Range;
}
```

_Response_:
- result: `InlineValue[]` \| `null` defined as follows:

```typescript
/**
 * Returns inline value information as the complete text to be shown.
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
 * To compute inline value through a variable lookup.
 *
 * If only a range is specified, the variable name should be extracted from
 * the underlying document.
 *
 * An optional variable name could be used to lookup instead of the extracted name.
 *
 * @since 3.17.0
 */
export interface InlineValueVariableLookup {
	/**
	 * The document range for which the inline value applies.
	 * The range could be used to extract the variable name from the underlying
	 * document.
	 */
	range: Range;

	/**
	 * If specified, the name of the variable to look up.
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
 * To compute an inline value through an expression evaluation.
 *
 * If only a range is specified, the expression should be extracted from the
 * underlying document.
 *
 * An optional expression could be evaluated instead of the extracted expression.
 *
 * @since 3.17.0
 */
export interface InlineValueEvaluatableExpression {
	/**
	 * The document range for which the inline value applies.
	 * The range could be used to extract the evaluatable expression from the
	 * underlying document.
	 */
	range: Range;

	/**
	 * If specified the expression could be evaluated instead.
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

The `workspace/inlineValue/refresh` request is sent from the server to the client. Servers can use it to ask clients to refresh the inline values currently shown in editors. As a result, the client should ask the server to recompute the inline values for these editors. This is useful if a server detects a configuration change which requires a re-calculation of all inline values. Note that the client still has the freedom to delay the re-calculation of the inline values if, for example, an editor is currently not visible.

_Client Capability_:

- property name (optional): `workspace.inlineValue`
- property type: `InlineValueWorkspaceClientCapabilities` defined as follows:

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
	 * is useful for situations where a server, for example, detects a project
	 * wide change that requires such a calculation.
	 */
	refreshSupport?: boolean;
}
```
_Request_:
- method: `workspace/inlineValue/refresh`
- params: none

_Response_:

- result: void
- error: code and message set in case an exception happens during the 'workspace/inlineValue/refresh' request

#### Monikers

> *Since version 3.16.0*

Language Server Index Format (LSIF) introduced the concept of symbol monikers to help associate symbols across different indexes. This request adds the capability for LSP server implementations to provide the same symbol moniker information given a text document position. Clients can utilize this method to get the moniker at the current location in a file the user is editing and do further code navigation queries in other services that rely on LSIF indexes and link symbols together.

The `textDocument/moniker` request is sent from the client to the server to get the symbol monikers for a given text document position. An array of Moniker types is returned as response to indicate possible monikers at the given location. If no monikers can be calculated, an empty array or `null` should be returned.

_Client Capabilities_:

- property name (optional): `textDocument.moniker`
- property type: `MonikerClientCapabilities` defined as follows:

```typescript
interface MonikerClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * `true`, the client supports the new `(TextDocumentRegistrationOptions &
	 * StaticRegistrationOptions)` return value for the corresponding server
	 * capability as well.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:

- property name (optional): `monikerProvider`
- property type: `boolean | MonikerOptions | MonikerRegistrationOptions` is defined as follows:

```typescript
export interface MonikerOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `MonikerRegistrationOptions` defined as follows:

```typescript
export interface MonikerRegistrationOptions extends
	TextDocumentRegistrationOptions, MonikerOptions {
}
```

_Request_:

- method: `textDocument/moniker`
- params: `MonikerParams` defined as follows:

```typescript
export interface MonikerParams extends TextDocumentPositionParams,
	WorkDoneProgressParams, PartialResultParams {
}
```

_Response_:

- result: `Moniker[] | null`
- partial result: `Moniker[]`
- error: code and message set in case an exception happens during the 'textDocument/moniker' request

`Moniker` is defined as follows:

```typescript
/**
 * Moniker uniqueness level to define scope of the moniker.
 */
export enum UniquenessLevel {
	/**
	 * The moniker is only unique inside a document.
	 */
	document = 'document',

	/**
	 * The moniker is unique inside a project for which a dump got created.
	 */
	project = 'project',

	/**
	 * The moniker is unique inside the group to which a project belongs.
	 */
	group = 'group',

	/**
	 * The moniker is unique inside the moniker scheme.
	 */
	scheme = 'scheme',

	/**
	 * The moniker is globally unique.
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
	 * The moniker represent a symbol that is imported into a project.
	 */
	import = 'import',

	/**
	 * The moniker represents a symbol that is exported from a project.
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
	 * The scheme of the moniker. For example, `tsc` or `.NET`.
	 */
	scheme: string;

	/**
	 * The identifier of the moniker. The value is opaque in LSIF, however
	 * schema owners are allowed to define the structure if they want.
	 */
	identifier: string;

	/**
	 * The scope in which the moniker is unique.
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

The Completion request is sent from the client to the server to compute completion items at a given cursor position. Completion items are presented in the [IntelliSense](https://code.visualstudio.com/docs/editor/intellisense) user interface. If computing full completion items is expensive, servers can additionally provide a handler for the completion item resolve request ('completionItem/resolve'). This request is sent when a completion item is selected in the user interface. A typical use case for this would be the `textDocument/completion` request, which doesn't fill in the `documentation` property for returned completion items since it is expensive to compute. When the item is selected in the user interface, a 'completionItem/resolve' request is sent with the selected completion item as a parameter. The returned completion item should have the documentation property filled in. By default, the request can only delay the computation of the `detail` and `documentation` properties. Since 3.16.0, the client
can signal that it can resolve more properties lazily. This is done using the `completionItem#resolveSupport` client capability which lists all properties that can be filled in during a 'completionItem/resolve' request. All other properties (usually `sortText`, `filterText`, `insertText` and `textEdit`) must be provided in the `textDocument/completion` response and must not be changed during resolve.

The language server protocol uses the following model around completions:

- to achieve consistency across languages and to honor different clients, usually the client is responsible for filtering and sorting. This also has the advantage that clients can experiment with different filter and sorting models. However, servers can enforce different behavior by setting a `filterText` / `sortText`.
- for speed, clients should be able to filter an already received completion list if the user continues typing. Servers can opt out of this using a `CompletionList` and mark it as `isIncomplete`.

A completion item provides additional means to influence filtering and sorting. They are expressed by either creating a `CompletionItem` with an `insertText` or with a `textEdit`. The two modes differ as follows:

- **Completion item provides an insertText / label without a text edit**: in the model the client should filter against what the user has already typed using the word boundary rules of the language (e.g. resolving the word under the cursor position). The reason for this mode is that it makes it extremely easy for a server to implement a basic completion list and get it filtered on the client.

- **Completion Item with text edits**: in this mode the server tells the client that it actually knows what it is doing. If you create a completion item with a text edit at the current cursor position no word guessing takes place and no automatic filtering (like with an `insertText`) should happen. This mode can be combined with a sort text and filter text to customize two things. If the text edit is a replace edit then the range denotes the word used for filtering. If the replace changes the text it most likely makes sense to specify a filter text to be used.

_Client Capability_:
- property name (optional): `textDocument.completion`
- property type: `CompletionClientCapabilities` defined as follows:

```typescript
export interface CompletionClientCapabilities {
	/**
	 * Whether completion supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports the following `CompletionItem` specific
	 * capabilities.
	 */
	completionItem?: ClientCompletionItemOptions;

	/**
	 * The client supports the following completion item kinds.
	 */
	completionItemKind?: ClientCompletionItemOptionsKind;

	/**
	 * The client supports sending additional context information for a
	 * `textDocument/completion` request.
	 */
	contextSupport?: boolean;

	/**
	 * The client's default when the completion item doesn't provide an
	 * `insertTextMode` property.
	 *
	 * @since 3.17.0
	 */
	insertTextMode?: InsertTextMode;

	/**
	 * The client supports the following `CompletionList` specific
	 * capabilities.
	 *
	 * @since 3.17.0
	 */
	completionList?: CompletionListCapabilities;
}
```

```typescript
export type ClientCompletionItemOptions = {
	/**
	 * Client supports snippets as insert text.
	 *
	 * A snippet can define tab stops and placeholders with `$1`, `$2`
	 * and `${3:foo}`. `$0` defines the final tab stop, it defaults to
	 * the end of the snippet. Placeholders with equal identifiers are linked,
	 * that is typing in one will update others too.
	 */
	snippetSupport?: boolean;

	/**
	 * Client supports commit characters on a completion item.
	 */
	commitCharactersSupport?: boolean;

	/**
	 * Client supports the following content formats for the documentation
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
	 * Client supports the tag property on a completion item. Clients supporting
	 * tags have to handle unknown tags gracefully. Clients especially need to
	 * preserve unknown tags when sending a completion item back to the server in
	 * a resolve call.
	 *
	 * @since 3.15.0
	 */
	tagSupport?: CompletionItemTagOptions;

	/**
	 * Client support insert replace edit to control different behavior if a
	 * completion item is inserted in the text or should replace text.
	 *
	 * @since 3.16.0
	 */
	insertReplaceSupport?: boolean;

	/**
	 * Indicates which properties a client can resolve lazily on a completion
	 * item. Before version 3.16.0 only the predefined properties `documentation`
	 * and `details` could be resolved lazily.
	 *
	 * @since 3.16.0
	 */
	resolveSupport?: ClientCompletionItemResolveOptions;

	/**
	 * The client supports the `insertTextMode` property on
	 * a completion item to override the whitespace handling mode
	 * as defined by the client (see `insertTextMode`).
	 *
	 * @since 3.16.0
	 */
	insertTextModeSupport?: ClientCompletionItemInsertTextModeOptions;

	/**
	 * The client has support for completion item label
	 * details (see also `CompletionItemLabelDetails`).
	 *
	 * @since 3.17.0
	 */
	labelDetailsSupport?: boolean;
};
```

```typescript
export type CompletionItemTagOptions = {
	/**
	 * The tags supported by the client.
	 */
	valueSet: CompletionItemTag[];
};
```

```typescript
export type ClientCompletionItemResolveOptions = {
	/**
	 * The properties that a client can resolve lazily.
	 */
	properties: string[];
};
```

```typescript
export type ClientCompletionItemInsertTextModeOptions = {
	valueSet: InsertTextMode[];
};
```

```typescript
export type ClientCompletionItemOptionsKind = {
	/**
	 * The completion item kind values the client supports. When this
	 * property exists the client also guarantees that it will
	 * handle values outside its set gracefully and falls back
	 * to a default value when unknown.
	 *
	 * If this property is not present the client only supports
	 * the completion items kinds from `Text` to `Reference` as defined in
	 * the initial version of the protocol.
	 */
	valueSet?: CompletionItemKind[];
};
```

```typescript
/**
 * The client supports the following `CompletionList` specific
 * capabilities.
 *
 * @since 3.17.0
 */
export interface CompletionListCapabilities {
	/**
	 * The client supports the following itemDefaults on
	 * a completion list.
	 *
	 * The value lists the supported property names of the
	 * `CompletionList.itemDefaults` object. If omitted
	 * no properties are supported.
	 *
	 * @since 3.17.0
	 */
	itemDefaults?: string[];

	/**
	 * Specifies whether the client supports `CompletionList.applyKind` to
	 * indicate how supported values from `completionList.itemDefaults`
	 * and `completion` will be combined.
	 *
	 * If a client supports `applyKind` it must support it for all fields
	 * that it supports that are listed in `CompletionList.applyKind`. This
	 * means when clients add support for new/future fields in completion
	 * items the MUST also support merge for them if those fields are
	 * defined in `CompletionList.applyKind`.
	 *
	 * @since 3.18.0
	 */
	applyKindSupport?: boolean;
}
```

_Server Capability_:
- property name (optional): `completionProvider`
- property type: `CompletionOptions` defined as follows:

```typescript
/**
 * Completion options.
 */
export interface CompletionOptions extends WorkDoneProgressOptions {
	/**
	 * Most tools trigger completion request automatically without explicitly
	 * requesting it using a keyboard shortcut (e.g., Ctrl+Space). Typically they
	 * do so when the user starts to type an identifier. For example, if the user
	 * types `c` in a JavaScript file, code complete will automatically pop up and
	 * present `console` besides others as a completion item. Characters that
	 * make up identifiers don't need to be listed here.
	 *
	 * If code complete should automatically be triggered on characters not being
	 * valid inside an identifier (for example, `.` in JavaScript), list them in
	 * `triggerCharacters`.
	 */
	triggerCharacters?: string[];

	/**
	 * The list of all possible characters that commit a completion. This field
	 * can be used if clients don't support individual commit characters per
	 * completion item. See client capability
	 * `completion.completionItem.commitCharactersSupport`.
	 *
	 * If a server provides both `allCommitCharacters` and commit characters on
	 * an individual completion item, the ones on the completion item win.
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
	 * The server supports the following `CompletionItem` specific
	 * capabilities.
	 *
	 * @since 3.17.0
	 */
	completionItem?: ServerCompletionItemOptions;
}
```

```typescript
export type ServerCompletionItemOptions = {
	/**
	 * The server has support for completion item label
	 * details (see also `CompletionItemLabelDetails`) when
	 * receiving a completion item in a resolve call.
	 *
	 * @since 3.17.0
	 */
	labelDetailsSupport?: boolean;
};
```

_Registration Options_: `CompletionRegistrationOptions` options defined as follows:

```typescript
export interface CompletionRegistrationOptions
	extends TextDocumentRegistrationOptions, CompletionOptions {
}
```

_Request_:
- method: `textDocument/completion`
- params: `CompletionParams` defined as follows:

```typescript
export interface CompletionParams extends TextDocumentPositionParams,
	WorkDoneProgressParams, PartialResultParams {
	/**
	 * The completion context. This is only available if the client specifies
	 * to send this using the client capability
	 * `completion.contextSupport === true`
	 */
	context?: CompletionContext;
}
```

```typescript
/**
 * How a completion was triggered.
 */
export namespace CompletionTriggerKind {
	/**
	 * Completion was triggered by typing an identifier (automatic code
	 * complete), manual invocation (e.g. Ctrl+Space) or via API.
	 */
	export const Invoked: 1 = 1;

	/**
	 * Completion was triggered by a trigger character specified by
	 * the `triggerCharacters` properties of the
	 * `CompletionRegistrationOptions`.
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
	 * The trigger character (a single character) that
	 * has triggered code complete. Is undefined if
	 * `triggerKind !== CompletionTriggerKind.TriggerCharacter`
	 */
	triggerCharacter?: string;
}
```

_Response_:
- result: `CompletionItem[]` \| `CompletionList` \| `null`. If a `CompletionItem[]` is provided, it is interpreted to be complete, so it is the same as `{ isIncomplete: false, items }`

```typescript
/**
 * Edit range variant that includes ranges for insert and replace operations.
 */
export type EditRangeWithInsertReplace = {
	insert: Range;
	replace: Range;
};
```

```typescript
/**
 * Represents a collection of completion items to be
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
	 * In many cases, the items of an actual completion result share the same
	 * value for properties like `commitCharacters` or the range of a text
	 * edit. A completion list can therefore define item defaults which will
	 * be used if a completion item itself doesn't specify the value.
	 *
	 * If a completion list specifies a default value and a completion item
	 * also specifies a corresponding value, the rules for combining these are
	 * defined by `applyKinds` (if the client supports it), defaulting to
	 * ApplyKind.Replace.
	 *
	 * Servers are only allowed to return default values if the client
	 * signals support for this via the `completionList.itemDefaults`
	 * capability.
	 *
	 * @since 3.17.0
	 */
	itemDefaults?: CompletionItemDefaults

	/**
	 * Specifies how fields from a completion item should be combined with those
	 * from `completionList.itemDefaults`.
	 *
	 * If unspecified, all fields will be treated as ApplyKind.Replace.
	 *
	 * If a field's value is ApplyKind.Replace, the value from a completion item
	 * (if provided and not `null`) will always be used instead of the value
	 * from `completionItem.itemDefaults`.
	 *
	 * If a field's value is ApplyKind.Merge, the values will be merged using
	 * the rules defined against each field below.
	 *
	 * Servers are only allowed to return `applyKind` if the client
	 * signals support for this via the `completionList.applyKindSupport`
	 * capability.
	 *
	 * @since 3.18.0
	 */
	applyKind?: CompletionItemApplyKinds;

	/**
	 * The completion items.
	 */
	items: CompletionItem[];
}
```

```typescript
/**
 * In many cases the items of an actual completion result share the same
 * value for properties like `commitCharacters` or the range of a text
 * edit. A completion list can therefore define item defaults which will
 * be used if a completion item itself doesn't specify the value.
 *
 * If a completion list specifies a default value and a completion item
 * also specifies a corresponding value, the rules for combining these are
 * defined by `applyKinds` (if the client supports it), defaulting to
 * ApplyKind.Replace.
 *
 * Servers are only allowed to return default values if the client
 * signals support for this via the `completionList.itemDefaults`
 * capability.
 *
 * @since 3.17.0
 */
export interface CompletionItemDefaults {
	/**
	 * A default commit character set.
	 *
	 * @since 3.17.0
	 */
	commitCharacters?: string[];

	/**
	 * A default edit range.
	 *
	 * @since 3.17.0
	 */
	editRange?: Range | EditRangeWithInsertReplace;

	/**
	 * A default insert text format.
	 *
	 * @since 3.17.0
	 */
	insertTextFormat?: InsertTextFormat;

	/**
	 * A default insert text mode.
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
```

```typescript
/**
 * Specifies how fields from a completion item should be combined with those
 * from `completionList.itemDefaults`.
 *
 * If unspecified, all fields will be treated as ApplyKind.Replace.
 *
 * If a field's value is ApplyKind.Replace, the value from a completion item (if
 * provided and not `null`) will always be used instead of the value from
 * `completionItem.itemDefaults`.
 *
 * If a field's value is ApplyKind.Merge, the values will be merged using the rules
 * defined against each field below.
 *
 * Servers are only allowed to return `applyKind` if the client
 * signals support for this via the `completionList.applyKindSupport`
 * capability.
 *
 * @since 3.18.0
 */
export interface CompletionItemApplyKinds {
	/**
	 * Specifies whether commitCharacters on a completion will replace or be
	 * merged with those in `completionList.itemDefaults.commitCharacters`.
	 *
	 * If ApplyKind.Replace, the commit characters from the completion item will
	 * always be used unless not provided, in which case those from
	 * `completionList.itemDefaults.commitCharacters` will be used. An
	 * empty list can be used if a completion item does not have any commit
	 * characters and also should not use those from
	 * `completionList.itemDefaults.commitCharacters`.
	 *
	 * If ApplyKind.Merge the commitCharacters for the completion will be the
	 * union of all values in both `completionList.itemDefaults.commitCharacters`
	 * and the completion's own `commitCharacters`.
	 *
	 * @since 3.18.0
	 */
	commitCharacters?: ApplyKind;

	/**
	 * Specifies whether the `data` field on a completion will replace or
	 * be merged with data from `completionList.itemDefaults.data`.
	 *
	 * If ApplyKind.Replace, the data from the completion item will be used if
	 * provided (and not `null`), otherwise
	 * `completionList.itemDefaults.data` will be used. An empty object can
	 * be used if a completion item does not have any data but also should
	 * not use the value from `completionList.itemDefaults.data`.
	 *
	 * If ApplyKind.Merge, a shallow merge will be performed between
	 * `completionList.itemDefaults.data` and the completion's own data
	 * using the following rules:
	 *
	 * - If a completion's `data` field is not provided (or `null`), the
	 *   entire `data` field from `completionList.itemDefaults.data` will be
	 *   used as-is.
	 * - If a completion's `data` field is provided, each field will
	 *   overwrite the field of the same name in
	 *   `completionList.itemDefaults.data` but no merging of nested fields
	 *   within that value will occur.
	 *
	 * @since 3.18.0
	 */
	data?: ApplyKind;
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
	 * A snippet can define tab stops and placeholders with `$1`, `$2`
	 * and `${3:foo}`. `$0` defines the final tab stop, it defaults to
	 * the end of the snippet. Placeholders with equal identifiers are linked,
	 * that is, typing in one will update others too.
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
	 * The range if the insert is requested.
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
	 * The insertion or replace strings are taken as-is. If the
	 * value is multiline, the lines below the cursor will be
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
	 * names or file paths.
	 */
	description?: string;
}
```

```typescript
/**
 * Defines how values from a set of defaults and an individual item will be
 * merged.
 *
 * @since 3.18.0
 */
export namespace ApplyKind {
	/**
	 * The value from the individual item (if provided and not `null`) will be
	 * used instead of the default.
	 */
	export const Replace: 1 = 1;

	/**
	 * The value from the item will be merged with the default.
	 *
	 * The specific rules for merging values are defined against each field
	 * that supports merging.
	 */
	export const Merge: 2 = 2;
}

/**
 * Defines how values from a set of defaults and an individual item will be
 * merged.
 *
 * @since 3.18.0
 */
export type ApplyKind = 1 | 2;
```

```typescript
export interface CompletionItem {

	/**
	 * The label of this completion item.
	 *
	 * The label property is also by default the text that
	 * is inserted when selecting this completion.
	 *
	 * If label details are provided, the label itself should
	 * be an unqualified name of the completion item.
	 */
	label: string;

	/**
	 * Additional details for the label.
	 *
	 * @since 3.17.0
	 */
	labelDetails?: CompletionItemLabelDetails;

	/**
	 * The kind of this completion item. Based on the kind,
	 * an icon is chosen by the editor. The standardized set
	 * of available values is defined in `CompletionItemKind`.
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
	 * @deprecated Use `tags` instead if supported.
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
	 * with other items. When omitted, the label is used
	 * as the sort text for this item.
	 */
	sortText?: string;

	/**
	 * A string that should be used when filtering a set of
	 * completion items. When omitted, the label is used as the
	 * filter text for this item.
	 */
	filterText?: string;

	/**
	 * A string that should be inserted into a document when selecting
	 * this completion. When omitted, the label is used as the insert text
	 * for this item.
	 *
	 * The `insertText` is subject to interpretation by the client side.
	 * Some tools might not take the string literally. For example,
	 * when code complete is requested for `con<cursor position>`
	 * and a completion item with an `insertText` of `console` is provided,
	 * VSCode will only insert `sole`. Therefore, it is
	 * recommended to use `textEdit` instead since it avoids additional client
	 * side interpretation.
	 */
	insertText?: string;

	/**
	 * The format of the insert text. The format applies to both the
	 * `insertText` property and the `newText` property of a provided
	 * `textEdit`. If omitted, defaults to `InsertTextFormat.PlainText`.
	 *
	 * Please note that the insertTextFormat doesn't apply to
	 * `additionalTextEdits`.
	 */
	insertTextFormat?: InsertTextFormat;

	/**
	 * How whitespace and indentation is handled during completion
	 * item insertion. If not provided, the client's default value depends on
	 * the `textDocument.completion.insertTextMode` client capability.
	 *
	 * @since 3.16.0
	 * @since 3.17.0 - support for `textDocument.completion.insertTextMode`
	 */
	insertTextMode?: InsertTextMode;

	/**
	 * An edit which is applied to a document when selecting this completion.
	 * When an edit is provided, the value of `insertText` is ignored.
	 *
	 * *Note:* The range of the edit must be a single line range and it must
	 * contain the position at which completion has been requested. Despite this
	 * limitation, your edit can write multiple lines.
	 *
	 * Most editors support two different operations when accepting a completion
	 * item. One is to insert a completion text and the other is to replace an
	 * existing text with a completion text. Since this can usually not be
	 * predetermined by a server it can report both ranges. Clients need to
	 * signal support for `InsertReplaceEdit`s via the
	 * `textDocument.completion.completionItem.insertReplaceSupport` client
	 * capability property.
	 *
	 * *Note 1:* The text edit's range as well as both ranges from an insert
	 * replace edit must be a single line and they must contain the position
	 * at which completion has been requested. In both cases, the new text can
	 * consist of multiple lines.
	 * *Note 2:* If an `InsertReplaceEdit` is returned, the edit's insert range
	 * must be a prefix of the edit's replace range, meaning it must be
	 * contained in and starting at the same position.
	 *
	 * @since 3.16.0 additional type `InsertReplaceEdit`
	 */
	textEdit?: TextEdit | InsertReplaceEdit;

	/**
	 * The edit text used if the completion item is part of a CompletionList and
	 * CompletionList defines an item default for the text edit range.
	 *
	 * Clients will only honor this property if they opt into completion list
	 * item defaults using the capability `completionList.itemDefaults`.
	 *
	 * If not provided and a list's default range is provided, the label
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
	 * An optional set of characters that, when pressed while this completion is
	 * active, will accept it first and then type that character. *Note* that all
	 * commit characters should have `length=1` and that superfluous characters
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
- partial result: `CompletionItem[]` or `CompletionList` followed by `CompletionItem[]`. If the first provided result item is of type `CompletionList`, subsequent partial results of `CompletionItem[]` add to the `items` property of the `CompletionList`.
- error: code and message set in case an exception happens during the completion request.

Completion items support snippets (see `InsertTextFormat.Snippet`). The snippet format is as follows:

##### Snippet Syntax

The `body` of a snippet can use special constructs to control cursors and the text being inserted. The following are supported features and their syntaxes:

##### Tab stops

With tab stops, you can make the editor cursor move inside a snippet. Use `$1`, `$2`, and so on to specify cursor locations. The number is the order in which tab stops will be visited. Multiple tab stops are linked and updated in sync.

##### Placeholders

Placeholders are tab stops with values, like `${1:foo}`. The placeholder text will be inserted and selected such that it can be easily changed. Placeholders can be nested, like `${1:another ${2:placeholder}}`.

##### Choice

Placeholders can have choices as values. The syntax is a comma separated enumeration of values, enclosed with the pipe-character, for example `${1|one,two,three|}`. When the snippet is inserted and the placeholder selected, choices will prompt the user to pick one of the values.

##### Variables

With `$name` or `${name:default}` you can insert the value of a variable. When a variable isn’t set, its *default* or the empty string is inserted. When a variable is unknown (that is, its name isn’t defined) the name of the variable is inserted and it is transformed into a placeholder.

The following variables can be used:

- `TM_SELECTED_TEXT` The currently selected text or the empty string
- `TM_CURRENT_LINE` The contents of the current line
- `TM_CURRENT_WORD` The contents of the word under the cursor or the empty string
- `TM_LINE_INDEX` The zero-index based line number
- `TM_LINE_NUMBER` The one-index based line number
- `TM_FILENAME` The filename of the current document
- `TM_FILENAME_BASE` The filename of the current document without its extensions
- `TM_DIRECTORY` The directory of the current document
- `TM_FILEPATH` The full file path of the current document

##### Variable Transforms

Transformations allow you to modify the value of a variable before it is inserted. The definition of a transformation consists of three parts:

1. A [regular expression](#regular-expressions) that is matched against the value of a variable, or the empty string when the variable cannot be resolved.
2. A "format string" that allows referencing matching groups from the regular expression. The format string allows for conditional inserts and simple modifications.
3. Options that are passed to the regular expression.

The following example inserts the name of the current file without its ending, so it transforms `foo.txt` to `foo`.

```
${TM_FILENAME/(.*)\..+$/$1/}
  |           |         | |
  |           |         | |-> no options
  |           |         |
  |           |         |-> references the contents of the first
  |           |             capture group
  |           |
  |           |-> regex to capture everything before
  |               the final `.suffix`
  |
  |-> resolves to the filename
```

##### Grammar

Below is the grammar for snippets in EBNF ([extended Backus-Naur form, XML variant](https://www.w3.org/TR/xml/#sec-notation)). With `\` (backslash), you can escape `$`, `}` and `\`. Within choice elements, the backslash also escapes comma and pipe characters. Only the characters required to be escaped can be escaped, so `$` should not be escaped within these constructs and neither `$` nor `}` should be escaped inside choice constructs.

```
any         ::= tabstop | placeholder | choice | variable | text
tabstop     ::= '$' int | '${' int '}'
placeholder ::= '${' int ':' any '}'
choice      ::= '${' int '|' choicetext (',' choicetext)* '|}'
variable    ::= '$' var | '${' var }'
                | '${' var ':' any '}'
                | '${' var '/' regex '/' (format | formattext)* '/' options '}'
format      ::= '$' int | '${' int '}'
                /* Transforms the text to be uppercase, lowercase, or capitalized, respectively. */
                | '${' int ':' ('/upcase' | '/downcase' | '/capitalize') '}'
                /* Inserts the 'ifOnly' text if the match is non-empty. */
                | '${' int ':+' ifOnly '}'
                /* Inserts the 'if' text if the match is non-empty,
                   otherwise the 'else' text will be inserted. */
                | '${' int ':?' if ':' else '}'
                /* Inserts the 'else' text if the match is empty. */
                | '${' int ':-' else '}' | '${' int ':' else '}'
regex       ::= Regular Expression value (ctor-string)
options     ::= Regular Expression option (ctor-options)
var         ::= [_a-zA-Z] [_a-zA-Z0-9]*
int         ::= [0-9]+
text        ::= ([^$}\] | '\$' | '\}' | '\\')*
choicetext  ::= ([^,|\] | '\,' | '\|' | '\\')*
formattext  ::= ([^$/\] | '\$' | '\/' | '\\')*
ifOnly      ::= text
if          ::= ([^:\] | '\:' | '\\')*
else        ::= text
```

#### Completion Item Resolve Request

The request is sent from the client to the server to resolve additional information for a given completion item.

_Request_:
- method: `completionItem/resolve`
- params: `CompletionItem`

_Response_:
- result: `CompletionItem`
- error: code and message set in case an exception happens during the completion resolve request.

#### PublishDiagnostics Notification

Diagnostics notifications are sent from the server to the client to signal results of validation runs.

Diagnostics are "owned" by the server, so it is the server's responsibility to clear them if necessary. The following rule is used for VS Code servers that generate diagnostics:

- if a language is single file only (for example HTML), diagnostics are cleared by the server when the file is closed. Please note that open / close events don't necessarily reflect what the user sees in the user interface. These events are ownership events. So with the current version of the specification, it is possible that problems are not cleared although the file is not visible in the user interface since the client has not closed the file yet.
- if a language has a project system (for example C#), diagnostics are not cleared when a file closes. When a project is opened, all diagnostics for all files are recomputed (or read from a cache).

When a file changes, it is the server's responsibility to re-compute diagnostics and push them to the client. If the computed set is empty, the server has to push the empty array to clear former diagnostics. Newly pushed diagnostics always replace previously pushed diagnostics. There is no merging that happens on the client side.

See also the [Diagnostic](#diagnostic) section.

_Client Capability_:
- property name (optional): `textDocument.publishDiagnostics`
- property type: `PublishDiagnosticsClientCapabilities` defined as follows:

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
	tagSupport?: ClientDiagnosticsTagOptions;

	/**
	 * Whether the client interprets the version property of the
	 * `textDocument/publishDiagnostics` notification's parameter.
	 *
	 * @since 3.15.0
	 */
	versionSupport?: boolean;

	/**
	 * Client supports a codeDescription property.
	 *
	 * @since 3.16.0
	 */
	codeDescriptionSupport?: boolean;

	/**
	 * Whether code action supports the `data` property which is
	 * preserved between a `textDocument/publishDiagnostics` and
	 * `textDocument/codeAction` request.
	 *
	 * @since 3.16.0
	 */
	dataSupport?: boolean;
}
```

```typescript
export type ClientDiagnosticsTagOptions = {
	/**
	 * The tags supported by the client.
	 */
	valueSet: DiagnosticTag[];
};
```

_Notification_:
- method: `textDocument/publishDiagnostics`
- params: `PublishDiagnosticsParams` defined as follows:

```typescript
interface PublishDiagnosticsParams {
	/**
	 * The URI for which diagnostic information is reported.
	 */
	uri: DocumentUri;

	/**
	 * Optionally, the version number of the document the diagnostics are
	 * published for.
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

Diagnostics are currently published by the server to the client using a notification. This model has the advantage that for workspace wide diagnostics, the server has the freedom to compute them at a server preferred point in time. On the other hand, the approach has the disadvantage that the server can't prioritize the computation for the file in which the user types or which are visible in the editor. Inferring the client's UI state from the `textDocument/didOpen` and `textDocument/didChange` notifications might lead to false positives since these notifications are ownership transfer notifications.

The specification therefore introduces the concept of diagnostic pull requests to give a client more control over the documents for which diagnostics should be computed and at which point in time.

_Client Capability_:
- property name (optional): `textDocument.diagnostic`
- property type: `DiagnosticClientCapabilities` defined as follows:

```typescript
export type ClientDiagnosticsTagOptions = {
	/**
	 * The tags supported by the client.
	 */
	valueSet: DiagnosticTag[];
};

/**
 * Client capabilities specific to diagnostic pull requests.
 *
 * @since 3.17.0
 */
export interface DiagnosticClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration. If this is set to
	 * `true`, the client supports the new
	 * `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
	 * return value for the corresponding server capability as well.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Whether the clients supports related documents for document diagnostic
	 * pulls.
	 */
	relatedDocumentSupport?: boolean;

	/**
	 * Whether the clients accepts diagnostics with related information.
	 */
	relatedInformation?: boolean;

	/**
	 * Client supports the tag property to provide meta data about a diagnostic.
	 * Clients supporting tags have to handle unknown tags gracefully.
	 */
	tagSupport?: ClientDiagnosticsTagOptions;

	/**
	 * Client supports a codeDescription property
	 */
	codeDescriptionSupport?: boolean;

	/**
	 * Whether the client supports `MarkupContent` in diagnostic messages.
	 *
	 * @since 3.18.0
	 * @proposed
	 */
	markupMessageSupport?: boolean;

	/**
	 * Whether code action supports the `data` property which is
	 * preserved between a `textDocument/publishDiagnostics` and
	 * `textDocument/codeAction` request.
	 */
	dataSupport?: boolean;
}
```

_Server Capability_:
- property name (optional): `diagnosticProvider`
- property type: `DiagnosticOptions` defined as follows:

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
	 * Whether the language has inter file dependencies, meaning that
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

_Registration Options_: `DiagnosticRegistrationOptions` options defined as follows:

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

The text document diagnostic request is sent from the client to the server to ask the server to compute the diagnostics for a given document. As with other pull requests, the server is asked to compute the diagnostics for the currently synced version of the document.

_Request_:
- method: 'textDocument/diagnostic'.
- params: `DocumentDiagnosticParams` defined as follows:

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
	 * The result ID of a previous response, if provided.
	 */
	previousResultId?: string;
}
```

_Response_:
- result: `DocumentDiagnosticReport` defined as follows:

```typescript
/**
 * The result of a document diagnostic pull request. A report can
 * either be a full report, containing all diagnostics for the
 * requested document, or an unchanged report, indicating that nothing
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
	 * An optional result ID. If provided, it will
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
	 * only return `unchanged` if result IDs are
	 * provided.
	 */
	kind: DocumentDiagnosticReportKind.Unchanged;

	/**
	 * A result ID which will be sent on the next
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
	 * such a language is C/C++, where macro definitions in a file
	 * a.cpp can result in errors in a header file b.hpp.
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
	 * such a language is C/C++, where macro definitions in a file
	 * a.cpp can result in errors in a header file b.hpp.
	 *
	 * @since 3.17.0
	 */
	relatedDocuments?: {
		[uri: string /** DocumentUri */]:
			FullDocumentDiagnosticReport | UnchangedDocumentDiagnosticReport;
	};
}
```
- partial result: The first literal send need to be a `DocumentDiagnosticReport` followed by n `DocumentDiagnosticReportPartialResult` literals defined as follows:

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
- error: code and message set in case an exception happens during the diagnostic request. A server is also allowed to return an error with code `ServerCancelled` indicating that the server can't compute the result right now. A server can return a `DiagnosticServerCancellationData` to indicate whether the client should re-trigger the request. If no data is provided, it defaults to `{ retriggerRequest: true }`:

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

The workspace diagnostic request is sent from the client to the server to ask the server to compute workspace wide diagnostics which previously were pushed from the server to the client. In contrast to the document diagnostic request, the workspace request can be long running and is not bound to a specific workspace or document state. If the client supports streaming for the workspace diagnostic pull, it is legal to provide a document diagnostic report multiple times for the same document URI. The last one reported will win over previous reports.

If a client receives a diagnostic report for a document in a workspace diagnostic request for which the client also issues individual document diagnostic pull requests, the client needs to decide which diagnostics win and should be presented. In general:

- diagnostics for a higher document version should win over those from a lower document version (e.g. note that document versions are steadily increasing)
- diagnostics from a document pull should win over diagnostics from a workspace pull.

_Request_:
- method: 'workspace/diagnostic'.
- params: `WorkspaceDiagnosticParams` defined as follows:

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
	 * previous result IDs.
	 */
	previousResultIds: PreviousResultId[];
}
```

```typescript
/**
 * A previous result ID in a workspace pull request.
 *
 * @since 3.17.0
 */
export interface PreviousResultId {
	/**
	 * The URI for which the client knows a
	 * result ID.
	 */
	uri: DocumentUri;

	/**
	 * The value of the previous result ID.
	 */
	value: string;
}
```

_Response_:
- result: `WorkspaceDiagnosticReport` defined as follows:

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
	 * If the document is not marked as open, `null` can be provided.
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
	 * If the document is not marked as open, `null` can be provided.
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

- partial result: The first literal sent needs to be a `WorkspaceDiagnosticReport` followed by n `WorkspaceDiagnosticReportPartialResult` literals defined as follows:

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

- error: code and message set in case an exception happens during the diagnostic request. A server is also allowed to return and error with code `ServerCancelled` indicating that the server can't compute the result right now. A server can return a `DiagnosticServerCancellationData` to indicate whether the client should re-trigger the request. If no data is provided, it defaults to `{ retriggerRequest: true }`:

##### Diagnostics Refresh

The `workspace/diagnostic/refresh` request is sent from the server to the client. Servers can use it to ask clients to refresh all needed document and workspace diagnostics. This is useful if a server detects a project wide configuration change which requires a re-calculation of all diagnostics.

_Client Capability_:

- property name (optional): `workspace.diagnostics`
- property type: `DiagnosticWorkspaceClientCapabilities` defined as follows:

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
	 * and is useful for situation where a server, for example, detects a project
	 * wide change that requires such a calculation.
	 */
	refreshSupport?: boolean;
}
```

_Request_:
- method: `workspace/diagnostic/refresh`
- params: none

_Response_:

- result: void
- error: code and message set in case an exception happens during the 'workspace/diagnostic/refresh' request

##### Implementation Considerations

Generally the language server specification doesn't enforce any specific client implementation since those usually depend on how the client UI behaves. However, since diagnostics can be provided on a document and workspace level, here are some tips:

- a client should pull actively for the document the users types in.
- if the server signals inter file dependencies, a client should also pull for visible documents to ensure accurate diagnostics. However, the pull should happen less frequently.
- if the server signals workspace pull support, a client should also pull for workspace diagnostics. It is recommended for clients to implement partial result progress for the workspace pull to allow servers to keep the request open for a long time. If a server closes a workspace diagnostic pull request the client should re-trigger the request.

#### Signature Help Request

The signature help request is sent from the client to the server to request signature information at a given cursor position.

_Client Capability_:
- property name (optional): `textDocument.signatureHelp`
- property type: `SignatureHelpClientCapabilities` defined as follows:

```typescript
export interface SignatureHelpClientCapabilities {
	/**
	 * Whether signature help supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports the following `SignatureInformation`
	 * specific properties.
	 */
	signatureInformation?: ClientSignatureInformationOptions;

	/**
	 * The client supports sending additional context information for a
	 * `textDocument/signatureHelp` request. A client that opts into
	 * contextSupport will also support the `retriggerCharacters` on
	 * `SignatureHelpOptions`.
	 *
	 * @since 3.15.0
	 */
	contextSupport?: boolean;
}
```

```typescript
export type ClientSignatureInformationOptions = {
	/**
	 * Client supports the following content formats for the documentation
	 * property. The order describes the preferred format of the client.
	 */
	documentationFormat?: MarkupKind[];

	/**
	 * Client capabilities specific to parameter information.
	 */
	parameterInformation?: ClientSignatureParameterInformationOptions;

	/**
	 * The client supports the `activeParameter` property on
	 * `SignatureInformation` literal.
	 *
	 * @since 3.16.0
	 */
	activeParameterSupport?: boolean;

	/**
	 * The client supports the `activeParameter` property on
	 * `SignatureHelp`/`SignatureInformation` being set to `null` to
	 * indicate that no parameter should be active.
	 *
	 * @since 3.18.0
	 */
	noActiveParameterSupport?: boolean;
};
```

```typescript
export type ClientSignatureParameterInformationOptions = {
	/**
	 * The client supports processing label offsets instead of a
	 * simple label string.
	 *
	 * @since 3.14.0
	 */
	labelOffsetSupport?: boolean;
};
```

_Server Capability_:
- property name (optional): `signatureHelpProvider`
- property type: `SignatureHelpOptions` defined as follows:

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

_Registration Options_: `SignatureHelpRegistrationOptions` defined as follows:

```typescript
export interface SignatureHelpRegistrationOptions
	extends TextDocumentRegistrationOptions, SignatureHelpOptions {
}
```

_Request_:
- method: `textDocument/signatureHelp`
- params: `SignatureHelpParams` defined as follows:

```typescript
export interface SignatureHelpParams extends TextDocumentPositionParams,
	WorkDoneProgressParams {
	/**
	 * The signature help context. This is only available if the client
	 * specifies to send this using the client capability
	 * `textDocument.signatureHelp.contextSupport === true`
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
	 * `true` if signature help was already showing when it was triggered.
	 *
	 * Retriggers occur when the signature help is already active and can be
	 * caused by actions such as typing a trigger character, a cursor move, or
	 * document content changes.
	 */
	isRetrigger: boolean;

	/**
	 * The currently active `SignatureHelp`.
	 *
	 * The `activeSignatureHelp` has its `SignatureHelp.activeSignature` field
	 * updated based on the user navigating through available signatures.
	 */
	activeSignatureHelp?: SignatureHelp;
}
```

_Response_:
- result: `SignatureHelp` \| `null` defined as follows:

```typescript
/**
 * Signature help represents the signature of something
 * callable. There can be multiple signatures,
 * but only one active one and only one active parameter.
 */
export interface SignatureHelp {
	/**
	 * One or more signatures. If no signatures are available,
	 * the signature help request should return `null`.
	 */
	signatures: SignatureInformation[];

	/**
	 * The active signature. If omitted or the value lies outside the
	 * range of `signatures`, the value defaults to zero or is ignored if
	 * the `SignatureHelp` has no signatures.
	 *
	 * Whenever possible, implementers should make an active decision about
	 * the active signature and shouldn't rely on a default value.
	 *
	 * In future versions of the protocol, this property might become
	 * mandatory to better express this.
	 */
	activeSignature?: uinteger;

	/**
	 * The active parameter of the active signature.
	 *
	 * If `null`, no parameter of the signature is active (for example, a named
	 * argument that does not match any declared parameters). This is only valid
	 * since 3.18.0 and if the client specifies the client capability
	 * `textDocument.signatureHelp.noActiveParameterSupport === true`.
	 *
	 * If omitted or the value lies outside the range of
	 * `signatures[activeSignature].parameters`, it defaults to 0 if the active
	 * signature has parameters.
	 *
	 * If the active signature has no parameters, it is ignored.
	 *
	 * Since version 3.16.0 the `SignatureInformation` itself provides a
	 * `activeParameter` property and it should be used instead of this one.
	 */
	activeParameter?: uinteger | null;
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
	 * The label of this signature. Will be shown in the UI.
	 */
	label: string;

	/**
	 * The human-readable doc-comment of this signature.
     * Will be shown in the UI but can be omitted.
	 */
	documentation?: string | MarkupContent;

	/**
	 * The parameters of this signature.
	 */
	parameters?: ParameterInformation[];

	/**
	 * The index of the active parameter.
	 *
	 * If `null`, no parameter of the signature is active (for example, a named
	 * argument that does not match any declared parameters). This is only valid
	 * since 3.18.0 and if the client specifies the client capability
	 * `textDocument.signatureHelp.noActiveParameterSupport === true`.
	 *
	 * If provided (or `null`), this is used in place of
	 * `SignatureHelp.activeParameter`.
	 *
	 * @since 3.16.0
	 */
	activeParameter?: uinteger | null;
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
	 * Either a string or an inclusive start and exclusive end offset within
	 * its containing signature label (see SignatureInformation.label). The
	 * offsets are based on a UTF-16 string representation, as `Position` and
	 * `Range` do.
	 *
	 * To avoid ambiguities, a server should use the [start, end] offset value
	 * instead of using a substring. Whether a client support this is
	 * controlled via `labelOffsetSupport` client capability.
	 *
	 * *Note*: a label of type string should be a substring of its containing
	 * signature label. Its intended use case is to highlight the parameter
	 * label part in the `SignatureInformation.label`.
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

The code action request is sent from the client to the server to compute relevant commands for a given text document and range. These commands are typically code fixes to either fix problems or to beautify/refactor code. The result of a `textDocument/codeAction` request is an array of `Command` literals which are typically presented in the user interface. Servers should only return relevant commands and avoid returning large lists of code actions, which can overwhelm the user and make it more difficult for them to find the code action they are after.

To ensure that a server is useful in many clients, the commands specified in code actions should be handled by the server and not by the client (see `workspace/executeCommand` and `ServerCapabilities.executeCommandProvider`). If the client supports providing edits with a code action then that mode should be used.

*Since version 3.16.0:* a client can offer a server to delay the computation of code action properties during a 'textDocument/codeAction' request:

This is useful for cases where it is expensive to compute the value of a property (for example, the `edit` property). Clients signal this through the `codeAction.resolveSupport` capability which lists all properties a client can resolve lazily. The server capability `codeActionProvider.resolveProvider` signals that a server will offer a `codeAction/resolve` route. To help servers to uniquely identify a code action in the resolve request, a code action literal can optionally carry a data property. This is also guarded by an additional client capability `codeAction.dataSupport`. In general, a client should offer data support if it offers resolve support. It should also be noted that servers shouldn't alter existing attributes of a code action in a codeAction/resolve request.

> *Since version 3.8.0:* support for CodeAction literals to enable the following scenarios:

- the ability to directly return a workspace edit from the code action request. This avoids having another server roundtrip to execute an actual code action. However, server providers should be aware that if the code action is expensive to compute or the edits are huge, it might still be beneficial if the result is simply a command and the actual edit is only computed when needed.
- the ability to group code actions using a kind. Clients are allowed to ignore that information. However, it allows them to better group code actions, for example, into corresponding menus (e.g. all refactor code actions into a refactor menu).

In version 1.0 of the protocol, there weren't any source or refactoring code actions. Code actions were solely used to (quick) fix code, not to write / rewrite code. So if a client asks for code actions without any kind, the standard quick fix code actions should be returned.

Clients need to announce their support for code action literals (e.g. literals of type `CodeAction`) and code action kinds via the corresponding client capability `codeAction.codeActionLiteralSupport`.

_Client Capability_:
- property name (optional): `textDocument.codeAction`
- property type: `CodeActionClientCapabilities` defined as follows:

```typescript
export interface CodeActionClientCapabilities {
	/**
	 * Whether code action supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * The client supports code action literals as a valid
	 * response of the `textDocument/codeAction` request.
	 *
	 * @since 3.8.0
	 */
	codeActionLiteralSupport?: ClientCodeActionLiteralOptions;

	/**
	 * Whether code action supports the `isPreferred` property.
	 *
	 * @since 3.15.0
	 */
	isPreferredSupport?: boolean;

	/**
	 * Whether code action supports the `disabled` property.
	 *
	 * @since 3.16.0
	 */
	disabledSupport?: boolean;

	/**
	 * Whether code action supports the `data` property which is
	 * preserved between a `textDocument/codeAction` and a
	 * `codeAction/resolve` request.
	 *
	 * @since 3.16.0
	 */
	dataSupport?: boolean;

	/**
	 * Whether the client supports resolving additional code action
	 * properties via a separate `codeAction/resolve` request.
	 *
	 * @since 3.16.0
	 */
	resolveSupport?: ClientCodeActionResolveOptions;

	/**
	 * Whether the client honors the change annotations in
	 * text edits and resource operations returned via the
	 * `CodeAction#edit` property by, for example, presenting
	 * the workspace edit in the user interface and asking
	 * for confirmation.
	 *
	 * @since 3.16.0
	 */
	honorsChangeAnnotations?: boolean;

	/**
	 * Whether the client supports documentation for a class of code actions.
	 *
	 * @since 3.18.0
	 */
	 documentationSupport?: boolean;

	/**
	 * Client supports the tag property on a code action. Clients
	 * supporting tags have to handle unknown tags gracefully.
	 *
	 * @since 3.18.0
	 */
	tagSupport?: CodeActionTagOptions;
}
```

```typescript
export type ClientCodeActionLiteralOptions = {
	/**
	 * The code action kind is supported with the following value
	 * set.
	 */
	codeActionKind: ClientCodeActionKindOptions;
};
```

```typescript
export type ClientCodeActionKindOptions = {
	/**
	 * The code action kind values the client supports. When this
	 * property exists the client also guarantees that it will
	 * handle values outside its set gracefully and falls back
	 * to a default value when unknown.
	 */
	valueSet: CodeActionKind[];
};
```

```typescript
export type ClientCodeActionResolveOptions = {
	/**
	 * The properties that a client can resolve lazily.
	 */
	properties: string[];
};
```

```typescript
export type CodeActionTagOptions = {
	/**
	 * The tags supported by the client.
	 */
	valueSet: CodeActionTag[];
};
```

_Server Capability_:
- property name (optional): `codeActionProvider`
- property type: `boolean | CodeActionOptions` where `CodeActionOptions` is defined as follows:

```typescript
/**
 * Documentation for a class of code actions.
 *
 * @since 3.18.0
 */
export interface CodeActionKindDocumentation {
	/**
	 * The kind of the code action being documented.
	 *
	 * If the kind is generic, such as `CodeActionKind.Refactor`, the
	 * documentation will be shown whenever any refactorings are returned. If
	 * the kind is more specific, such as `CodeActionKind.RefactorExtract`, the
	 * documentation will only be shown when extract refactoring code actions
	 * are returned.
	 */
	kind: CodeActionKind;

	/**
	 * Command that is used to display the documentation to the user.
	 *
	 * The title of this documentation code action is taken
	 * from {@linkcode Command.title}
	 */
	command: Command;
}

export interface CodeActionOptions extends WorkDoneProgressOptions {
	/**
	 * CodeActionKinds that this server may return.
	 *
	 * The list of kinds may be generic, such as `CodeActionKind.Refactor`,
	 * or the server may list out every specific kind they provide.
	 */
	codeActionKinds?: CodeActionKind[];

	/**
	 * Static documentation for a class of code actions.
	 *
	 * Documentation from the provider should be shown in the code actions
	 * menu if either:
	 *
	 * - Code actions of `kind` are requested by the editor. In this case,
	 *   the editor will show the documentation that most closely matches the
	 *   requested code action kind. For example, if a provider has
	 *   documentation for both `Refactor` and `RefactorExtract`, when the
	 *   user requests code actions for `RefactorExtract`, the editor will use
	 *   the documentation for `RefactorExtract` instead of the documentation
	 *   for `Refactor`.
	 *
	 * - Any code actions of `kind` are returned by the provider.
	 *
	 * At most one documentation entry should be shown per provider.
	 *
	 * @since 3.18.0
	 */
	documentation?: CodeActionKindDocumentation[];

	/**
	 * The server provides support to resolve additional
	 * information for a code action.
	 *
	 * @since 3.16.0
	 */
	resolveProvider?: boolean;
}
```

_Registration Options_: `CodeActionRegistrationOptions` defined as follows:

```typescript
export interface CodeActionRegistrationOptions extends
	TextDocumentRegistrationOptions, CodeActionOptions {
}
```

_Request_:
- method: `textDocument/codeAction`
- params: `CodeActionParams` defined as follows:

```typescript
/**
 * Params for the CodeActionRequest.
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
 * Kinds are a hierarchical list of identifiers separated by `.`,
 * e.g. `"refactor.extract.function"`.
 *
 * The set of kinds is open and the client needs to announce
 * the kinds it supports to the server during initialization.
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
	 * Base kind for refactoring move actions: 'refactor.move'
	 *
	 * Example move actions:
	 *
	 * - Move a function to a new file
	 * - Move a property between classes
	 * - Move method to base class
	 * - ...
	 *
	 * @since 3.18.0
	 */
	export const RefactorMove: CodeActionKind = 'refactor.move';

	/**
	 * Base kind for refactoring rewrite actions: 'refactor.rewrite'.
	 *
	 * Example rewrite actions:
	 *
	 * - Convert JavaScript function to class
	 * - Add or remove parameter
	 * - Encapsulate field
	 * - Make method static
	 * - ...
	 */
	export const RefactorRewrite: CodeActionKind = 'refactor.rewrite';

	/**
	 * Base kind for source actions: `source`.
	 *
	 * Source code actions apply to the entire file.
	 */
	export const Source: CodeActionKind = 'source';

	/**
	 * Base kind for an organize imports source action:
	 * `source.organizeImports`.
	 */
	export const SourceOrganizeImports: CodeActionKind =
		'source.organizeImports';

	/**
	 * Base kind for a 'fix all' source action: `source.fixAll`.
	 *
	 * 'Fix all' actions automatically fix errors that have a clear fix that
	 * do not require user input. They should not suppress errors or perform
	 * unsafe fixes such as generating new types or classes.
	 *
	 * @since 3.17.0
	 */
	export const SourceFixAll: CodeActionKind = 'source.fixAll';

	/**
	 * Base kind for all code actions applying to the entire notebook's scope. CodeActionKinds using
	 * this should always begin with `notebook.`
	 *
	 * @since 3.18.0
	 */
	export const Notebook: CodeActionKind = 'notebook';
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
	 * provided to the `textDocument/codeAction` request. They are provided so
	 * that the server knows which errors are currently presented to the user
	 * for the given range. There is no guarantee that these accurately reflect
	 * the error state of the resource. The primary parameter
	 * to compute code actions is the provided range.
	 *
	 * Note that the client should check the `textDocument.diagnostic.markupMessageSupport`
	 * server capability before sending diagnostics with markup messages to a server.
	 * Diagnostics with markup messages should be excluded for servers that don't support
	 * them.
	 */
	diagnostics: Diagnostic[];

	/**
	 * Requested kind of actions to return.
	 *
	 * Actions not of this kind are filtered out by the client before being
	 * shown, so servers can omit computing them.
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
	 * This typically happens when the current selection in a file changes,
	 * but can also be triggered when file content changes.
	 */
	export const Automatic: 2 = 2;
}

export type CodeActionTriggerKind = 1 | 2;
```

```typescript
/**
 * Code action tags are extra annotations that tweak the behavior of a code action.
 *
 * @since 3.18.0
 */
export namespace CodeActionTag {
	/**
	 * Marks the code action as LLM-generated.
	 */
	export const LLMGenerated = 1;
}
export type CodeActionTag = 1;
```

_Response_:
- result: `(Command | CodeAction)[]` \| `null` where `CodeAction` is defined as follows:

```typescript
/**
 * Captures why the code action is currently disabled.
 *
 * @since 3.18.0
 */
export interface CodeActionDisabled {
	/**
	 * Human readable description of why the code action is currently disabled.
	 *
	 * This is displayed in the code actions UI.
	 */
	reason: string;
}
```

```typescript
/**
 * A code action represents a change that can be performed in code, e.g. to fix
 * a problem or to refactor code.
 *
 * A CodeAction must set either `edit` and/or a `command`. If both are supplied,
 * the `edit` is applied first, then the `command` is executed.
 */
export interface CodeAction {

	/**
	 * A short, human-readable title for this code action.
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
	 * `auto fix` command and can be targeted by keybindings.
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
	 *   an error message with `reason` in the editor.
	 *
	 * @since 3.16.0
	 */
	disabled?: CodeActionDisabled;

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
	 * a `textDocument/codeAction` and a `codeAction/resolve` request.
	 *
	 * @since 3.16.0
	 */
	data?: LSPAny;

	/**
 	 * Tags for this code action.
	 *
	 * @since 3.18.0
	 */
	tags?: CodeActionTag[];
}
```
- partial result: `(Command | CodeAction)[]`
- error: code and message set in case an exception happens during the code action request.

#### Code Action Resolve Request

> *Since version 3.16.0*

The request is sent from the client to the server to resolve additional information for a given code action. This is usually used to compute
the `edit` property of a code action to avoid its unnecessary computation during the `textDocument/codeAction` request.

Consider the client announcing the `edit` property as a property that can be resolved lazily using the client capability

```typescript
textDocument.codeAction.resolveSupport = { properties: ['edit'] };
```

then a code action

```typescript
{
    "title": "Do Foo"
}
```

needs to be resolved using the `codeAction/resolve` request before it can be applied.

_Client Capability_:
- property name (optional): `textDocument.codeAction.resolveSupport`
- property type: `{ properties: string[]; }`

_Request_:
- method: `codeAction/resolve`
- params: `CodeAction`

_Response_:
- result: `CodeAction`
- error: code and message set in case an exception happens during the code action resolve request.

#### Document Color Request

> *Since version 3.6.0*

The document color request is sent from the client to the server to list all color references found in a given text document. Along with the range, a color value in RGB is returned.

Clients can use the result to decorate color references in an editor. For example:
- Color boxes showing the actual color next to the reference
- Show a color picker when a color reference is edited

_Client Capability_:
- property name (optional): `textDocument.colorProvider`
- property type: `DocumentColorClientCapabilities` defined as follows:

```typescript
export interface DocumentColorClientCapabilities {
	/**
	 * Whether document color supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:
- property name (optional): `colorProvider`
- property type: `boolean | DocumentColorOptions | DocumentColorRegistrationOptions` where `DocumentColorOptions` is defined as follows:

```typescript
export interface DocumentColorOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `DocumentColorRegistrationOptions` defined as follows:

```typescript
export interface DocumentColorRegistrationOptions extends
	TextDocumentRegistrationOptions, StaticRegistrationOptions,
	DocumentColorOptions {
}
```

_Request_:

- method: `textDocument/documentColor`
- params: `DocumentColorParams` defined as follows

```typescript
interface DocumentColorParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * The text document.
	 */
	textDocument: TextDocumentIdentifier;
}
```

_Response_:
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
- error: code and message set in case an exception happens during the 'textDocument/documentColor' request

#### Color Presentation Request

> *Since version 3.6.0*

The color presentation request is sent from the client to the server to obtain a list of presentations for a color value at a given location. Clients can use the result to
- modify a color reference.
- show a color picker and let users pick one of the presentations.

This request has no special capabilities and registration options since it is sent as a resolve request for the `textDocument/documentColor` request.

_Request_:

- method: `textDocument/colorPresentation`
- params: `ColorPresentationParams` defined as follows

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

_Response_:
- result: `ColorPresentation[]` defined as follows:

```typescript
interface ColorPresentation {
	/**
	 * The label of this color presentation. It will be shown on the color
	 * picker header. By default, this is also the text that is inserted when
	 * selecting this color presentation.
	 */
	label: string;
	/**
	 * An edit which is applied to a document when selecting
	 * this presentation for the color. When omitted, the
	 * label is used.
	 */
	textEdit?: TextEdit;
	/**
	 * An optional array of additional text edits that are applied
	 * when selecting this color presentation. Edits must not overlap with the
	 * main edit nor with themselves.
	 */
	additionalTextEdits?: TextEdit[];
}
```

- partial result: `ColorPresentation[]`
- error: code and message set in case an exception happens during the 'textDocument/colorPresentation' request

#### Document Formatting Request

The document formatting request is sent from the client to the server to format a whole document.

_Client Capability_:
- property name (optional): `textDocument.formatting`
- property type: `DocumentFormattingClientCapabilities` defined as follows:

```typescript
export interface DocumentFormattingClientCapabilities {
	/**
	 * Whether formatting supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:
- property name (optional): `documentFormattingProvider`
- property type: `boolean | DocumentFormattingOptions` where `DocumentFormattingOptions` is defined as follows:

```typescript
export interface DocumentFormattingOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `DocumentFormattingRegistrationOptions` defined as follows:

```typescript
export interface DocumentFormattingRegistrationOptions extends
	TextDocumentRegistrationOptions, DocumentFormattingOptions {
}
```

_Request_:
- method: `textDocument/formatting`
- params: `DocumentFormattingParams` defined as follows

```typescript
interface DocumentFormattingParams extends WorkDoneProgressParams {
	/**
	 * The document to format.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The formatting options.
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

_Response_:
- result: [`TextEdit[]`](#textEdit) \| `null` describing the modification to the document to be formatted.
- error: code and message set in case an exception happens during the formatting request.

#### Document Range Formatting Request

The document range formatting request is sent from the client to the server to format a given range in a document.

> *Since version 3.18.0*

If supported, the client may send multiple ranges at once for formatting via the `textDocument/rangesFormatting` method.

_Client Capability_:
- property name (optional): `textDocument.rangeFormatting`
- property type: `DocumentRangeFormattingClientCapabilities` defined as follows:

```typescript
export interface DocumentRangeFormattingClientCapabilities {
	/**
	 * Whether formatting supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Whether the client supports formatting multiple ranges at once.
	 *
	 * @since 3.18.0
	 */
	rangesSupport?: boolean;
}
```

_Server Capability_:
- property name (optional): `documentRangeFormattingProvider`
- property type: `boolean | DocumentRangeFormattingOptions` where `DocumentRangeFormattingOptions` is defined as follows:

```typescript
export interface DocumentRangeFormattingOptions extends
	WorkDoneProgressOptions {
	/**
	 * Whether the server supports formatting multiple ranges at once.
	 *
	 * @since 3.18.0
	 */
	rangesSupport?: boolean;
}
```

_Registration Options_: `DocumentFormattingRegistrationOptions` defined as follows:

```typescript
export interface DocumentRangeFormattingRegistrationOptions extends
	TextDocumentRegistrationOptions, DocumentRangeFormattingOptions {
}
```

_Request_:
- method: `textDocument/rangeFormatting`,
- params: `DocumentRangeFormattingParams` defined as follows:

```typescript
interface DocumentRangeFormattingParams extends WorkDoneProgressParams {
	/**
	 * The document to format.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The range to format.
	 */
	range: Range;

	/**
	 * The formatting options.
	 */
	options: FormattingOptions;
}
```

_Response_:
- result: [`TextEdit[]`](#textEdit) \| `null` describing the modification to the document to be formatted.
- error: code and message set in case an exception happens during the range formatting request.

> *Since version 3.18.0*

_Request_:
- method: `textDocument/rangesFormatting`,
- params: `DocumentRangesFormattingParams` defined as follows:

```typescript
interface DocumentRangesFormattingParams extends WorkDoneProgressParams {
	/**
	 * The document to format.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The ranges to format.
	 */
	ranges: Range[];

	/**
	 * The format options.
	 */
	options: FormattingOptions;
}
```

_Response_:
- result: [`TextEdit[]`](#textEdit) \| `null` describing the modification to the document to be formatted.
- error: code and message set in case an exception happens during the ranges formatting request.

#### Document on Type Formatting Request

The document on type formatting request is sent from the client to the server to format parts of the document during typing.

_Client Capability_:
- property name (optional): `textDocument.onTypeFormatting`
- property type: `DocumentOnTypeFormattingClientCapabilities` defined as follows:

```typescript
export interface DocumentOnTypeFormattingClientCapabilities {
	/**
	 * Whether on type formatting supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:
- property name (optional): `documentOnTypeFormattingProvider`
- property type: `DocumentOnTypeFormattingOptions` defined as follows:

```typescript
export interface DocumentOnTypeFormattingOptions {
	/**
	 * A character on which formatting should be triggered, like `{`.
	 */
	firstTriggerCharacter: string;

	/**
	 * More trigger characters.
	 */
	moreTriggerCharacter?: string[];
}
```

_Registration Options_: `DocumentOnTypeFormattingRegistrationOptions` defined as follows:

```typescript
export interface DocumentOnTypeFormattingRegistrationOptions extends
	TextDocumentRegistrationOptions, DocumentOnTypeFormattingOptions {
}
```

_Request_:
- method: `textDocument/onTypeFormatting`
- params: `DocumentOnTypeFormattingParams` defined as follows:

```typescript
interface DocumentOnTypeFormattingParams {

	/**
	 * The document to format.
	 */
	textDocument: TextDocumentIdentifier;

	/**
	 * The position around which the on type formatting should happen.
	 * This is not necessarily the exact position where the character denoted
	 * by the property `ch` got typed.
	 */
	position: Position;

	/**
	 * The character that has been typed that triggered the formatting
	 * on type request. That is not necessarily the last character that
	 * got inserted into the document since the client could auto insert
	 * characters as well (e.g. automatic brace completion).
	 */
	ch: string;

	/**
	 * The formatting options.
	 */
	options: FormattingOptions;
}
```

_Response_:
- result: [`TextEdit[]`](#textEdit) \| `null` describing the modification to the document.
- error: code and message set in case an exception happens during the range formatting request.

#### Rename Request

The rename request is sent from the client to the server to ask the server to compute a workspace change so that the client can perform a workspace-wide rename of a symbol.

_Client Capability_:
- property name (optional): `textDocument.rename`
- property type: `RenameClientCapabilities` defined as follows:

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
	 * (`{ defaultBehavior: boolean }`).
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
	 * rename request's workspace edit by, for example, presenting
	 * the workspace edit in the user interface and asking
	 * for confirmation.
	 *
	 * @since 3.16.0
	 */
	honorsChangeAnnotations?: boolean;
}
```

_Server Capability_:
- property name (optional): `renameProvider`
- property type: `boolean | RenameOptions` where `RenameOptions` is defined as follows:

`RenameOptions` may only be specified if the client states that it supports `prepareSupport` in its initial `initialize` request.

```typescript
export interface RenameOptions extends WorkDoneProgressOptions {
	/**
	 * Renames should be checked and tested before being executed.
	 */
	prepareProvider?: boolean;
}
```

_Registration Options_: `RenameRegistrationOptions` defined as follows:

```typescript
export interface RenameRegistrationOptions extends
	TextDocumentRegistrationOptions, RenameOptions {
}
```

_Request_:
- method: `textDocument/rename`
- params: `RenameParams` defined as follows

```typescript
interface RenameParams extends TextDocumentPositionParams,
	WorkDoneProgressParams {
	/**
	 * The new name of the symbol. If the given name is not valid, the
	 * request must return a ResponseError with an
	 * appropriate message set.
	 */
	newName: string;
}
```

_Response_:
- result: `WorkspaceEdit` \| `null` describing the modification to the workspace. `null` should be treated the same as `WorkspaceEdit` with no changes (no change was required).
- error: code and message set in case when rename could not be performed for any reason. Examples include: there is nothing at given `position` to rename (like a space), given symbol does not support renaming by the server or the code is invalid (e.g. does not compile).

#### Prepare Rename Request

> *Since version 3.12.0*

The prepare rename request is sent from the client to the server to setup and test the validity of a rename operation at a given location.

_Request_:
- method: `textDocument/prepareRename`
- params: `PrepareRenameParams` defined as follows:

```typescript
export interface PrepareRenameParams extends
	TextDocumentPositionParams, WorkDoneProgressParams {
}
```

```typescript
export type PrepareRenamePlaceholder = {
	range: Range;
	placeholder: string;
};
```

```typescript
export type PrepareRenameDefaultBehavior = {
	defaultBehavior: boolean;
};
```

```typescript
export type PrepareRenameResult = Range |
	PrepareRenamePlaceholder | PrepareRenameDefaultBehavior;
```

_Response_:
- result: `PrepareRenameResult | null` describing a [`Range`](#range) of the string to rename and optionally a placeholder text of the string content to be renamed. If `PrepareRenameDefaultBehavior` is returned (since 3.16), the rename position is valid and the client should use its default behavior to compute the rename range. If `null` is returned then it is deemed that a 'textDocument/rename' request is not valid at the given position.
- error: code and message set in case the element can't be renamed. Clients should show the information in their user interface.

#### Linked Editing Range

> *Since version 3.16.0*

The linked editing request is sent from the client to the server to return for a given position in a document the range of the symbol at the position and all ranges that have the same content. Optionally a word pattern can be returned to describe valid contents. A rename to one of the ranges can be applied to all other ranges if the new content is valid. If no result-specific word pattern is provided, the word pattern from the client's language configuration is used.

_Client Capabilities_:

- property name (optional): `textDocument.linkedEditingRange`
- property type: `LinkedEditingRangeClientCapabilities` defined as follows:

```typescript
export interface LinkedEditingRangeClientCapabilities {
	/**
	 * Whether the implementation supports dynamic registration.
	 * If this is set to `true` the client supports the new
	 * `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
	 * return value for the corresponding server capability as well.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:

- property name (optional): `linkedEditingRangeProvider`
- property type: `boolean` \| `LinkedEditingRangeOptions` \| `LinkedEditingRangeRegistrationOptions` defined as follows:

```typescript
export interface LinkedEditingRangeOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `LinkedEditingRangeRegistrationOptions` defined as follows:

```typescript
export interface LinkedEditingRangeRegistrationOptions extends
	TextDocumentRegistrationOptions, LinkedEditingRangeOptions,
	StaticRegistrationOptions {
}
```

_Request_:

- method: `textDocument/linkedEditingRange`
- params: `LinkedEditingRangeParams` defined as follows:

```typescript
export interface LinkedEditingRangeParams extends TextDocumentPositionParams,
	WorkDoneProgressParams {
}
```

_Response_:

- result: `LinkedEditingRanges` \| `null` defined as follows:

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
- error: code and message set in case an exception happens during the 'textDocument/linkedEditingRange' request

#### Inline Completion Request

> *Since version 3.18.0*

The inline completion request is sent from the client to the server to compute inline completions for a given text document either explicitly by a user gesture or implicitly when typing.

Inline completion items usually complete bigger portions of text (e.g., whole methods) and in contrast to completions, items can complete code that might be syntactically or semantically incorrect.

Due to this, inline completion items are usually not suited to be presented in normal code completion widgets like a list of items. One possible approach can be to present the information inline in the editor with lower contrast.

When multiple inline completion items are returned, the client may decide whether the user can cycle through them or if they, along with their `filterText`, are merely for filtering if the user continues to type without yet accepting the inline completion item.

Clients may choose to send information about the user's current completion selection via context if completions are visible at the same time. In this case, returned inline completions should extend the text of the provided completion.

_Client Capability_:
- property name (optional): `textDocument.inlineCompletion`
- property type: `InlineCompletionClientCapabilities` defined as follows:

```typescript
/**
 * Client capabilities specific to inline completions.
 *
 * @since 3.18.0
 */
export interface InlineCompletionClientCapabilities {
	/**
	 * Whether implementation supports dynamic registration for inline
	 * completion providers.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:
- property name (optional): `inlineCompletionProvider`
- property type: `InlineCompletionOptions` defined as follows:

```typescript
/**
 * Inline completion options used during static registration.
 *
 * @since 3.18.0
 */
export interface InlineCompletionOptions extends WorkDoneProgressOptions {
}
```

_Registration Options_: `InlineCompletionRegistrationOptions` defined as follows:

```typescript
/**
 * Inline completion options used during static or dynamic registration.
 *
 * @since 3.18.0
 */
export interface InlineCompletionRegistrationOptions extends
	InlineCompletionOptions, TextDocumentRegistrationOptions,
	StaticRegistrationOptions {
}
```

_Request_:
- method: `textDocument/inlineCompletion`
- params: `InlineCompletionParams` defined as follows:

```typescript
/**
 * A parameter literal used in inline completion requests.
 *
 * @since 3.18.0
 */
export interface InlineCompletionParams extends TextDocumentPositionParams,
	WorkDoneProgressParams {
	/**
	 * Additional information about the context in which inline completions
	 * were requested.
	 */
	context: InlineCompletionContext;
}
```

```typescript
/**
 * Provides information about the context in which an inline completion was
 * requested.
 *
 * @since 3.18.0
 */
export interface InlineCompletionContext {
	/**
	 * Describes how the inline completion was triggered.
	 */
	triggerKind: InlineCompletionTriggerKind;

	/**
	 * Provides information about the currently selected item in the
	 * autocomplete widget if it is visible.
	 *
	 * If set, provided inline completions must extend the text of the
	 * selected item and use the same range, otherwise they are not shown as
	 * preview.
	 * As an example, if the document text is `console.` and the selected item
	 * is `.log` replacing the `.` in the document, the inline completion must
	 * also replace `.` and start with `.log`, for example `.log()`.
	 *
	 * Inline completion providers are requested again whenever the selected
	 * item changes.
	 */
	selectedCompletionInfo?: SelectedCompletionInfo;
}
```

```typescript
/**
 * Describes how an {@link InlineCompletionItemProvider inline completion
 * provider} was triggered.
 *
 * @since 3.18.0
 */
export namespace InlineCompletionTriggerKind {
	/**
	 * Completion was triggered explicitly by a user gesture.
	 * Return multiple completion items to enable cycling through them.
	 */
	export const Invoked: 1 = 1;

	/**
	 * Completion was triggered automatically while editing.
	 * It is sufficient to return a single completion item in this case.
	 */
	export const Automatic: 2 = 2;
}

export type InlineCompletionTriggerKind = 1 | 2;
```

```typescript
/**
 * Describes the currently selected completion item.
 *
 * @since 3.18.0
 */
export interface SelectedCompletionInfo {
	/**
	 * The range that will be replaced if this completion item is accepted.
	 */
	range: Range;

	/**
	 * The text the range will be replaced with if this completion is
	 * accepted.
	 */
	text: string;
}
```

_Response_:
- result: `InlineCompletionItem[]` \| `InlineCompletionList` \| `null` defined as follows:

```typescript
/**
 * Represents a collection of {@link InlineCompletionItem inline completion
 * items} to be presented in the editor.
 *
 * @since 3.18.0
 */
export interface InlineCompletionList {
	/**
	 * The inline completion items.
	 */
	items: InlineCompletionItem[];
}
```

```typescript
/**
 * An inline completion item represents a text snippet that is proposed inline
 * to complete text that is being typed.
 *
 * @since 3.18.0
 */
export interface InlineCompletionItem {
	/**
	 * The text to replace the range with. Must be set.
	 * Is used both for the preview and the accept operation.
	 */
	insertText: string | StringValue;

	/**
	 * A text that is used to decide if this inline completion should be
	 * shown. When `falsy`, the {@link InlineCompletionItem.insertText} is
	 * used.
	 *
	 * An inline completion is shown if the text to replace is a prefix of the
	 * filter text.
	 */
	filterText?: string;

	/**
	 * The range to replace.
	 * Must begin and end on the same line.
	 *
	 * Prefer replacements over insertions to provide a better experience when
	 * the user deletes typed text.
	 */
	range?: Range;

	/**
	 * An optional {@link Command} that is executed *after* inserting this
	 * completion.
	 */
	command?: Command;
}
```

- error: code and message set in case an exception happens during the inline completions request.

### Workspace Features

#### Workspace Symbols Request

The workspace symbol request is sent from the client to the server to list project-wide symbols matching the query string. Since 3.17.0, servers can also provide a handler for `workspaceSymbol/resolve` requests. This allows servers to return workspace symbols without a range for a `workspace/symbol` request. Clients then need to resolve the range when necessary using the `workspaceSymbol/resolve` request. Servers can only use this new model if clients advertise support for it via the `workspace.symbol.resolveSupport` capability.

_Client Capability_:
- property path (optional): `workspace.symbol`
- property type: `WorkspaceSymbolClientCapabilities` defined as follows:

```typescript
interface WorkspaceSymbolClientCapabilities {
	/**
	 * Symbol request supports dynamic registration.
	 */
	dynamicRegistration?: boolean;

	/**
	 * Specific capabilities for the `SymbolKind` in the `workspace/symbol`
	 * request.
	 */
	symbolKind?: ClientSymbolKindOptions;

	/**
	 * The client supports tags on `SymbolInformation` and `WorkspaceSymbol`.
	 * Clients supporting tags have to handle unknown tags gracefully.
	 *
	 * @since 3.16.0
	 */
	tagSupport?: ClientSymbolTagOptions;

	/**
	 * The client supports partial workspace symbols. The client will send the
	 * request `workspaceSymbol/resolve` to the server to resolve additional
	 * properties.
	 *
	 * @since 3.17.0
	 */
	resolveSupport?: ClientSymbolResolveOptions;
}
```

```typescript
export type ClientSymbolResolveOptions = {
	/**
	 * The properties that a client can resolve lazily. Usually
	 * `location.range`
	 */
	properties: string[];
};
```

_Server Capability_:
- property path (optional): `workspaceSymbolProvider`
- property type: `boolean | WorkspaceSymbolOptions` where `WorkspaceSymbolOptions` is defined as follows:

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

_Registration Options_: `WorkspaceSymbolRegistrationOptions` defined as follows:

```typescript
export interface WorkspaceSymbolRegistrationOptions
	extends WorkspaceSymbolOptions {
}
```

_Request_:
- method: 'workspace/symbol'
- params: `WorkspaceSymbolParams` defined as follows:

```typescript
/**
 * The parameters of a Workspace Symbol Request.
 */
interface WorkspaceSymbolParams extends WorkDoneProgressParams,
	PartialResultParams {
	/**
	 * A query string to filter symbols by. Clients may send an empty
	 * string here to request all symbols.
	 *
	 * The `query`-parameter should be interpreted in a *relaxed way* as editors
	 * will apply their own highlighting and scoring on the results. A good rule
	 * of thumb is to match case-insensitive and to simply check that the
	 * characters of *query* appear in their order in a candidate symbol.
	 * Servers shouldn't use prefix, substring, or similar strict matching.
	 */
	query: string;
}
```

_Response_:
- result: `SymbolInformation[]` \| `WorkspaceSymbol[]` \| `null`. See above for the definition of `SymbolInformation`. It is recommended that you use the new `WorkspaceSymbol`. However, whether the workspace symbol can return a location without a range depends on the client capability `workspace.symbol.resolveSupport`. `WorkspaceSymbol` is defined as follows:

```typescript
/**
 * A special workspace symbol that supports locations without a range.
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
	 * capability `workspace.symbol.resolveSupport`.
	 *
	 * See also `SymbolInformation.location`.
	 */
	location: Location | LocationUriOnly;

	/**
	 * A data entry field that is preserved on a workspace symbol between a
	 * workspace symbol request and a workspace symbol resolve request.
	 */
	data?: LSPAny;
}
```
- partial result: `SymbolInformation[]` \| `WorkspaceSymbol[]` as defined above.
- error: code and message set in case an exception happens during the workspace symbol request.

#### Workspace Symbol Resolve Request

The request is sent from the client to the server to resolve additional information for a given workspace symbol.

_Request_:
- method: 'workspaceSymbol/resolve'
- params: `WorkspaceSymbol`

_Response_:
- result: `WorkspaceSymbol`
- error: code and message set in case an exception happens during the workspace symbol resolve request.

#### Configuration Request

> *Since version 3.6.0*

The `workspace/configuration` request is sent from the server to the client to fetch configuration settings from the client. The request can fetch several configuration settings in one roundtrip. The order of the returned configuration settings correspond to the order of the passed `ConfigurationItems` (e.g. the first item in the response is the result for the first configuration item in the params).

A `ConfigurationItem` consists of the configuration section to ask for and an additional scope URI. The configuration section asked for is defined by the server and doesn't necessarily need to correspond to the configuration store used by the client. So, a server might ask for a configuration `cpp.formatterOptions` but the client stores the configuration in an XML store layout differently. It is up to the client to do the necessary conversion. If a scope URI is provided, the client should return the setting scoped to the provided resource. If the client, for example, uses [EditorConfig](https://editorconfig.org/) to manage its settings the configuration should be returned for the passed resource URI. If the client can't provide a configuration setting for a given scope, then `null` needs to be present in the returned array.

This pull model replaces the old push model where the client signaled a configuration change via an event. If the server still needs to react to configuration changes (since the server caches the result of `workspace/configuration` requests), the server should register for an empty configuration change using the following registration pattern:

```typescript
connection.client.register(DidChangeConfigurationNotification.type, undefined);
```

_Client Capability_:
- property path (optional): `workspace.configuration`
- property type: `boolean`

_Request_:
- method: 'workspace/configuration'
- params: `ConfigurationParams` defined as follows

```typescript
export interface ConfigurationParams {
	items: ConfigurationItem[];
}
```

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

_Response_:
- result: LSPAny[]
- error: code and message set in case an exception happens during the 'workspace/configuration' request

#### DidChangeConfiguration Notification

A notification sent from the client to the server to signal the change of configuration settings.

_Client Capability_:
- property path (optional): `workspace.didChangeConfiguration`
- property type: `DidChangeConfigurationClientCapabilities` defined as follows:

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

_Notification_:
- method: 'workspace/didChangeConfiguration',
- params: `DidChangeConfigurationParams` defined as follows:

```typescript
interface DidChangeConfigurationParams {
	/**
	 * The actual changed settings.
	 */
	settings: LSPAny;
}
```

#### Workspace folders request

> *Since version 3.6.0*

Many tools support more than one root folder per workspace. Examples for this are VS Code's multi-root support, Atom's project folder support or Sublime's project support. If a client workspace consists of multiple roots, then a server typically needs to know about this. The protocol up to now assumes one root folder which is announced to the server by the `rootUri` property of the `InitializeParams`. If the client supports workspace folders and announces them via the corresponding `workspaceFolders` client capability, the `InitializeParams` contain an additional property `workspaceFolders` with the configured workspace folders when the server starts.

The `workspace/workspaceFolders` request is sent from the server to the client to fetch the current open list of workspace folders. Returns `null` in the response if only a single file is open in the tool. Returns an empty array if a workspace is open but no folders are configured.

_Client Capability_:
- property path (optional): `workspace.workspaceFolders`
- property type: `boolean`

_Server Capability_:
- property path (optional): `workspace.workspaceFolders`
- property type: `WorkspaceFoldersServerCapabilities` defined as follows:

```typescript
export interface WorkspaceFoldersServerCapabilities {
	/**
	 * The server has support for workspace folders.
	 */
	supported?: boolean;

	/**
	 * Whether the server wants to receive workspace folder
	 * change notifications.
	 *
	 * If a string is provided, the string is treated as an ID
	 * under which the notification is registered on the client
	 * side. The ID can be used to unregister for these events
	 * using the `client/unregisterCapability` request.
	 */
	changeNotifications?: string | boolean;
}
```

_Request_:
- method: `workspace/workspaceFolders`
- params: none

_Response_:
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
- error: code and message set in case an exception happens during the 'workspace/workspaceFolders' request

#### DidChangeWorkspaceFolders Notification

> *Since version 3.6.0*

The `workspace/didChangeWorkspaceFolders` notification is sent from the client to the server to inform the server about workspace folder configuration changes. A server can register for this notification by using either the _server capability_ `workspace.workspaceFolders.changeNotifications` or by using the dynamic capability registration mechanism. To dynamically register for the `workspace/didChangeWorkspaceFolders`, send a `client/registerCapability` request from the server to the client. The registration parameter must have a `registrations` item of the following form, where `id` is a unique ID used to unregister the capability (the example uses a UUID):

```ts
{
	id: "28c6150c-bd7b-11e7-abc4-cec278b6b50a",
	method: "workspace/didChangeWorkspaceFolders"
}
```

_Notification_:
- method: 'workspace/didChangeWorkspaceFolders'
- params: `DidChangeWorkspaceFoldersParams` defined as follows:

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
	 * The array of added workspace folders.
	 */
	added: WorkspaceFolder[];

	/**
	 * The array of removed workspace folders.
	 */
	removed: WorkspaceFolder[];
}
```

#### WillCreateFiles Request

The will create files request is sent from the client to the server before files are actually created as long as the creation is triggered from within the client either by a user action or by applying a workspace edit. The request can return a `WorkspaceEdit` which will be applied to the workspace before the files are created. Hence, the `WorkspaceEdit` cannot manipulate the content of the files to be created. Please note that clients might drop results if computing the edit took too long or if a server constantly fails on this request. This is done to keep creates fast and reliable.

_Client Capability_:
- property name (optional): `workspace.fileOperations.willCreate`
- property type: `boolean`

The capability indicates that the client supports sending `workspace/willCreateFiles` requests.

_Server Capability_:
- property name (optional): `workspace.fileOperations.willCreate`
- property type: `FileOperationRegistrationOptions` where `FileOperationRegistrationOptions` is defined as follows:

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
 * A pattern kind describing if a glob pattern matches a file,
 * a folder, or both.
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
	 * - `*` to match zero or more characters in a path segment
	 * - `?` to match on one character in a path segment
	 * - `**` to match any number of path segments, including none
	 * - `{}` to group sub patterns into an OR expression. (e.g. `**​/*.{ts,js}`
	 *   matches all TypeScript and JavaScript files)
	 * - `[]` to declare a range of characters to match in a path segment
	 *   (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
	 * - `[!...]` to negate a range of characters to match in a path segment
	 *   (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but
	 *   not `example.0`)
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
	 * A URI scheme, like `file` or `untitled`.
	 */
	scheme?: string;

	/**
	 * The actual file operation pattern.
	 */
	pattern: FileOperationPattern;
}
```

The capability indicates that the server is interested in receiving `workspace/willCreateFiles` requests.

_Registration Options_: none

_Request_:
- method: 'workspace/willCreateFiles'
- params: `CreateFilesParams` defined as follows:

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

_Response_:
- result: `WorkspaceEdit` \| `null`
- error: code and message set in case an exception happens during the `willCreateFiles` request.

#### DidCreateFiles Notification

The did create files notification is sent from the client to the server when files were created from within the client.

_Client Capability_:
- property name (optional): `workspace.fileOperations.didCreate`
- property type: `boolean`

The capability indicates that the client supports sending `workspace/didCreateFiles` notifications.

_Server Capability_:
- property name (optional): `workspace.fileOperations.didCreate`
- property type: `FileOperationRegistrationOptions`

The capability indicates that the server is interested in receiving `workspace/didCreateFiles` notifications.

_Notification_:
- method: 'workspace/didCreateFiles'
- params: `CreateFilesParams`

#### WillRenameFiles Request

The will rename files request is sent from the client to the server before files are actually renamed as long as the rename is triggered from within the client either by a user action or by applying a workspace edit. The request can return a WorkspaceEdit which will be applied to the workspace before the files are renamed. Please note that clients might drop results if computing the edit took too long or if a server constantly fails on this request. This is done to keep renames fast and reliable.

_Client Capability_:
- property name (optional): `workspace.fileOperations.willRename`
- property type: `boolean`

The capability indicates that the client supports sending `workspace/willRenameFiles` requests.

_Server Capability_:
- property name (optional): `workspace.fileOperations.willRename`
- property type: `FileOperationRegistrationOptions`

The capability indicates that the server is interested in receiving `workspace/willRenameFiles` requests.

_Registration Options_: none

_Request_:
- method: 'workspace/willRenameFiles'
- params: `RenameFilesParams` defined as follows:

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

_Response_:
- result: `WorkspaceEdit` \| `null`
- error: code and message set in case an exception happens during the `workspace/willRenameFiles` request.

#### DidRenameFiles Notification

The did rename files notification is sent from the client to the server when files were renamed from within the client.

_Client Capability_:
- property name (optional): `workspace.fileOperations.didRename`
- property type: `boolean`

The capability indicates that the client supports sending `workspace/didRenameFiles` notifications.

_Server Capability_:
- property name (optional): `workspace.fileOperations.didRename`
- property type: `FileOperationRegistrationOptions`

The capability indicates that the server is interested in receiving `workspace/didRenameFiles` notifications.

_Notification_:
- method: 'workspace/didRenameFiles'
- params: `RenameFilesParams`

#### WillDeleteFiles Request

The will delete files request is sent from the client to the server before files are actually deleted as long as the deletion is triggered from within the client either by a user action or by applying a workspace edit. The request can return a WorkspaceEdit which will be applied to the workspace before the files are deleted. Please note that clients might drop results if computing the edit took too long or if a server constantly fails on this request. This is done to keep deletes fast and reliable.

_Client Capability_:
- property name (optional): `workspace.fileOperations.willDelete`
- property type: `boolean`

The capability indicates that the client supports sending `workspace/willDeleteFiles` requests.

_Server Capability_:
- property name (optional): `workspace.fileOperations.willDelete`
- property type: `FileOperationRegistrationOptions`

The capability indicates that the server is interested in receiving `workspace/willDeleteFiles` requests.

_Registration Options_: none

_Request_:
- method: `workspace/willDeleteFiles`
- params: `DeleteFilesParams` defined as follows:

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

_Response_:
- result: `WorkspaceEdit` \| `null`
- error: code and message set in case an exception happens during the `workspace/willDeleteFiles` request.

#### DidDeleteFiles Notification

The did delete files notification is sent from the client to the server when files were deleted from within the client.

_Client Capability_:
- property name (optional): `workspace.fileOperations.didDelete`
- property type: `boolean`

The capability indicates that the client supports sending `workspace/didDeleteFiles` notifications.

_Server Capability_:
- property name (optional): `workspace.fileOperations.didDelete`
- property type: `FileOperationRegistrationOptions`

The capability indicates that the server is interested in receiving `workspace/didDeleteFiles` notifications.

_Notification_:
- method: 'workspace/didDeleteFiles'
- params: `DeleteFilesParams`

#### DidChangeWatchedFiles Notification

The watched files notification is sent from the client to the server when the client detects changes to files and folders watched by the language client (note although the name suggest that only file events are sent, it is about file system events which include folders as well). It is recommended that servers register for these file system events using the registration mechanism. In former implementations, clients pushed file events without the server actively asking for it.

Servers are allowed to run their own file system watching mechanism and not rely on clients to provide file system events. However, this is not recommended due to the following reasons:

- in our experience, getting file system watching on disk right is challenging, especially if it needs to be supported across multiple OSes.
- file system watching is not done for free, especially if the implementation uses some sort of polling and keeps a file system tree in memory to compare time stamps (as for example some node modules do)
- a client usually starts more than one server. If every server runs its own file system watching, it can become a CPU or memory problem.
- in general there are more server than client implementations. So, this problem is better solved on the client side.

_Client Capability_:
- property path (optional): `workspace.didChangeWatchedFiles`
- property type: `DidChangeWatchedFilesClientCapabilities` defined as follows:

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

_Registration Options_: `DidChangeWatchedFilesRegistrationOptions` defined as follows:

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
export interface FileSystemWatcher {
	/**
	 * The glob pattern to watch. See {@link GlobPattern glob pattern}
	 * for more detail.
	 *
 	 * @since 3.17.0 support for relative patterns.
	 */
	globPattern: GlobPattern;

	/**
	 * The kind of events of interest. If omitted, it defaults
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
	 * Interested in change events.
	 */
	export const Change = 2;

	/**
	 * Interested in delete events.
	 */
	export const Delete = 4;
}
export type WatchKind = uinteger;
```

_Notification_:
- method: 'workspace/didChangeWatchedFiles'
- params: `DidChangeWatchedFilesParams` defined as follows:

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

The `workspace/executeCommand` request is sent from the client to the server to trigger command execution on the server. In most cases, the server creates a `WorkspaceEdit` structure and applies the changes to the workspace using the request `workspace/applyEdit`, which is sent from the server to the client.

_Client Capability_:
- property path (optional): `workspace.executeCommand`
- property type: `ExecuteCommandClientCapabilities` defined as follows:

```typescript
export interface ExecuteCommandClientCapabilities {
	/**
	 * Execute command supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
}
```

_Server Capability_:
- property path (optional): `executeCommandProvider`
- property type: `ExecuteCommandOptions` defined as follows:

```typescript
export interface ExecuteCommandOptions extends WorkDoneProgressOptions {
	/**
	 * The commands to be executed on the server.
	 */
	commands: string[];
}
```

_Registration Options_: `ExecuteCommandRegistrationOptions` defined as follows:

```typescript
/**
 * Execute command registration options.
 */
export interface ExecuteCommandRegistrationOptions
	extends ExecuteCommandOptions {
}
```

_Request_:
- method: 'workspace/executeCommand'
- params: `ExecuteCommandParams` defined as follows:

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

The arguments are typically specified when a command is returned from the server to the client. Example requests that return a command are `textDocument/codeAction` or `textDocument/codeLens`.

_Response_:
- result: `LSPAny`
- error: code and message set in case an exception happens during the request.

#### Applies a WorkspaceEdit

The `workspace/applyEdit` request is sent from the server to the client to modify resource on the client side.

_Client Capability_:
- property path (optional): `workspace.applyEdit`
- property type: `boolean`

See also the [WorkspaceEditClientCapabilities](#workspaceeditclientcapabilities) for the supported capabilities of a workspace edit.

_Request_:
- method: 'workspace/applyEdit'
- params: `ApplyWorkspaceEditParams` defined as follows:

```typescript
export interface ApplyWorkspaceEditParams {
	/**
	 * An optional label of the workspace edit. This label is
	 * presented in the user interface, for example, on an undo
	 * stack to undo the workspace edit.
	 */
	label?: string;

	/**
	 * The edits to apply.
	 */
	edit: WorkspaceEdit;

	/**
	 * Additional data about the edit.
	 *
	 * @since 3.18.0
	 */
	metadata?: WorkspaceEditMetadata;
}
```

```typescript
/**
 * Additional data about a workspace edit.
 *
 * @since 3.18.0
 */
export interface WorkspaceEditMetadata {
	/**
	 * Signal to the editor that this edit is a refactoring.
	 */
	isRefactoring?: boolean;
}
```

_Response_:
- result: `ApplyWorkspaceEditResult` defined as follows:

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
	 * Depending on the client's failure handling strategy, `failedChange`
	 * might contain the index of the change that failed. This property is
	 * only available if the client signals a `failureHandling` strategy
	 * in its client capabilities.
	 */
	failedChange?: uinteger;
}
```
- error: code and message set in case an exception happens during the request.

#### Text Document Content Request

The `workspace/textDocumentContent` request is sent from the client to the server to dynamically fetch the content of a text document. Clients should treat the content returned from this requests as readonly.

_Client Capability_:
- property path (optional): `workspace.textDocumentContent`
- property type: `TextDocumentContentClientCapabilities` defined as follows:

```typescript
/**
 * Client capabilities for a text document content provider.
 *
 * @since 3.18.0
 */
export type TextDocumentContentClientCapabilities = {
	/**
	 * Text document content provider supports dynamic registration.
	 */
	dynamicRegistration?: boolean;
};
```

_Server Capability_:
- property path (optional): `workspace.textDocumentContent`
- property type: `TextDocumentContentOptions` where `TextDocumentContentOptions` is defined as follows:

```typescript
/**
 * Text document content provider options.
 *
 * @since 3.18.0
 */
export type TextDocumentContentOptions = {
	/**
	 * The schemes for which the server provides content.
	 */
	schemes: string[];
};
```

_Registration Options_: `TextDocumentContentRegistrationOptions` defined as follows:

```typescript
/**
 * Text document content provider registration options.
 *
 * @since 3.18.0
 */
export type TextDocumentContentRegistrationOptions = TextDocumentContentOptions &
	StaticRegistrationOptions;
```

_Request_:
- method: 'workspace/textDocumentContent'
- params: `TextDocumentContentParams` defined as follows:

```typescript
/**
 * Parameters for the `workspace/textDocumentContent` request.
 *
 * @since 3.18.0
 */
export interface TextDocumentContentParams {
	/**
	 * The uri of the text document.
	 */
	uri: DocumentUri;
}
```

_Response_:
- result: `TextDocumentContentResult` defined as follows:

```typescript
/**
 * Result of the `workspace/textDocumentContent` request.
 *
 * @since 3.18.0
 */
export interface TextDocumentContentResult {
	/**
	 * The text content of the text document. Please note, that the content of
	 * any subsequent open notifications for the text document might differ
	 * from the returned content due to whitespace and line ending
	 * normalizations done on the client
	 */
	text: string;
}
```

 The content of the text document. .
- error: code and message set in case an exception happens during the text document content request.

#### Text Document Content Refresh Request

The `workspace/textDocumentContent/refresh`request is sent from the server to the client to refresh the content of a specific text document.

_Request_:
- method: 'workspace/textDocumentContent/refresh'
- params: `TextDocumentContentRefreshParams` defined as follows:

```typescript
/**
 * Parameters for the `workspace/textDocumentContent/refresh` request.
 *
 * @since 3.18.0
 */
export interface TextDocumentContentRefreshParams {
	/**
	 * The uri of the text document to refresh.
	 */
	uri: DocumentUri;
}
```

_Response_:
- result: `void`
- error: code and message set in case an exception happens during the workspace symbol resolve request.

### Window Features

#### ShowMessage Notification

The show message notification is sent from a server to a client to ask the client to display a particular message in the user interface.

_Notification_:
- method: 'window/showMessage'
- params: `ShowMessageParams` defined as follows:

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
	 */
	export const Debug = 5;
}

export type MessageType = 1 | 2 | 3 | 4 | 5;
```

#### ShowMessage Request

The show message request is sent from a server to a client to ask the client to display a particular message in the user interface. In addition to the show message notification, the request allows to pass actions and to wait for an answer from the client.

_Client Capability_:
- property path (optional): `window.showMessage`
- property type: `ShowMessageRequestClientCapabilities` defined as follows:

```typescript
/**
 * Show message request client capabilities
 */
export interface ShowMessageRequestClientCapabilities {
	/**
	 * Capabilities specific to the `MessageActionItem` type.
	 */
	messageActionItem?: ClientShowMessageActionItemOptions;
}
```

```typescript
export type ClientShowMessageActionItemOptions = {
	/**
	 * Whether the client supports additional attributes which
	 * are preserved and send back to the server in the
	 * request's response.
	 */
	additionalPropertiesSupport?: boolean;
};
```

_Request_:
- method: 'window/showMessageRequest'
- params: `ShowMessageRequestParams` defined as follows:

```typescript
interface ShowMessageRequestParams {
	/**
	 * The message type. See {@link MessageType}.
	 */
	type: MessageType;

	/**
	 * The actual message.
	 */
	message: string;

	/**
	 * The message action items to present.
	 */
	actions?: MessageActionItem[];
}
```

Where the `MessageActionItem` is defined as follows:

```typescript
interface MessageActionItem {
	/**
	 * A short title like 'Retry', 'Open Log' etc.
	 */
	title: string;

	/**
	 * Additional attributes that the client preserves and
	 * sends back to the server. This depends on the client
	 * capability window.messageActionItem.additionalPropertiesSupport.
	 */
	[key: string]: string | boolean | integer | object;
}
```

_Response_:
- result: the selected `MessageActionItem` \| `null` if none got selected.
- error: code and message set in case an exception happens during showing a message.

#### Show Document Request

> New in version 3.16.0

The show document request is sent from a server to a client to ask the client to display a particular resource referenced by a URI in the user interface.

_Client Capability_:
- property path (optional): `window.showDocument`
- property type: `ShowDocumentClientCapabilities` defined as follows:

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

_Request_:
- method: 'window/showDocument'
- params: `ShowDocumentParams` defined as follows:

```typescript
/**
 * Params to show a resource.
 *
 * @since 3.16.0
 */
export interface ShowDocumentParams {
	/**
	 * The URI to show.
	 */
	uri: URI;

	/**
	 * Indicates to show the resource in an external program.
	 * To show, for example, `https://code.visualstudio.com/`
	 * in the default web browser, set `external` to `true`.
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
	 * document. Clients might ignore this property if an
	 * external program is started or the file is not a text
	 * file.
	 */
	selection?: Range;
}
```

_Response_:

- result: `ShowDocumentResult` defined as follows:

```typescript
/**
 * The result of a show document request.
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

_Notification_:
- method: 'window/logMessage'
- params: `LogMessageParams` defined as follows:

```typescript
interface LogMessageParams {
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

#### Create Work Done Progress

The `window/workDoneProgress/create` request is sent from the server to the client to ask the client to create a work done progress.

_Client Capability_:
- property name (optional): `window.workDoneProgress`
- property type: `boolean`

_Request_:

- method: 'window/workDoneProgress/create'
- params: `WorkDoneProgressCreateParams` defined as follows:

```typescript
export interface WorkDoneProgressCreateParams {
	/**
	 * The token to be used to report progress.
	 */
	token: ProgressToken;
}
```

_Response_:

- result: void
- error: code and message set in case an exception happens during the 'window/workDoneProgress/create' request. In case an error occurs, a server must not send any progress notification using the token provided in the `WorkDoneProgressCreateParams`.

#### Cancel a Work Done Progress

The `window/workDoneProgress/cancel` notification is sent from the client to the server to cancel a progress initiated on the server side using `window/workDoneProgress/create`. The progress need not be marked as `cancellable` to be cancelled and a client may cancel a progress for any number of reasons: in case of error, reloading a workspace etc.

_Notification_:

- method: 'window/workDoneProgress/cancel'
- params: `WorkDoneProgressCancelParams` defined as follows:

```typescript
export interface WorkDoneProgressCancelParams {
	/**
	 * The token to be used to report progress.
	 */
	token: ProgressToken;
}
```

#### Telemetry Notification

The telemetry notification is sent from the server to the client to ask the client to log a telemetry event. The protocol doesn't specify the payload since no interpretation of the data happens in the protocol. Most clients don't even handle the event directly but forward them to the extensions owing the corresponding server issuing the event.

_Notification_:
- method: 'telemetry/event'
- params: 'object' \| 'array';

#### Miscellaneous

#### Implementation Considerations

Language servers usually run in a separate process and clients communicate with them in an asynchronous fashion. Additionally, clients usually allow users to interact with the source code even if request results are pending. We recommend the following implementation pattern to avoid that clients apply outdated response results:

- if a client sends a request to the server and the client state changes in a way that invalidates the response, the client should do the following:
  - cancel the server request and ignore the result if the result is not useful for the client anymore. If necessary, the client should resend the request.
  - keep the request running if the client can still make use of the result by, for example, transforming it to a new result by applying the state change to the result.
- servers should therefore not decide by themselves to cancel requests simply due to that fact that a state change notification is detected in the queue. As said, the result could still be useful for the client.
- if a server detects an internal state change (for example, a project context changed) that invalidates the result of a request in execution, the server can error these requests with `ContentModified`. If clients receive a `ContentModified` error, they generally should not show it in the UI for the end-user. Clients can resend the request if they know how to do so. It should be noted that for all position based requests it might be especially hard for clients to re-craft a request.
- a client should not send resolve requests for out of date objects (for example, code lenses). If a server receives a resolve request for an out of date object, the server can error these requests with `ContentModified`.
- if a client notices that a server exits unexpectedly, it should try to restart the server. However, clients should be careful not to restart a crashing server endlessly. VS Code, for example, doesn't restart a server which has crashed 5 times in the last 180 seconds.

Servers usually support different communication channels (e.g. stdio, pipes, ...). To ease the usage of servers in different clients, it is highly recommended that a server implementation supports the following command line arguments to pick the communication channel:

- **stdio**: use stdio as the communication channel.
- **pipe**: use pipes (Windows) or socket files (Linux, Mac) as the communication channel. The pipe / socket file name is passed as the next arg or with `--pipe=`.
- **socket**: use a socket as the communication channel. The port is passed as the next arg or with `--port=`.
- **node-ipc**: use node IPC communication between the client and the server. This is only supported if both client and server run under node.

To support the case that the editor starting a server crashes, an editor should also pass its process ID to the server. This allows the server to monitor the editor process and to shut itself down if the editor process dies. The process ID passed on the command line should be the same as the one passed in the initialize parameters. The command line argument to use is `--clientProcessId`.

#### Meta Model

Since 3.17 there is a meta model describing the LSP protocol:

- [metaModel.json](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/metaModel/metaModel.json): The actual meta model for the LSP 3.18 specification
- [metaModel.ts](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/metaModel/metaModel.ts): A TypeScript file defining the data types that make up the meta model.
- [metaModel.schema.json](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/metaModel/metaModel.schema.json): A JSON schema file defining the data types that make up the meta model. Can be used to generate code to read the meta model JSON file.

### Change Log

#### 3.18.0 (06/04/2026)

- Added inline completions support.
- Added dynamic text document content support.
- Added refresh support for folding ranges.
- Support to format multiple ranges at once.
- Support for snippets in workspace edits.
- Relative Pattern support for document filters and notebook document filters.
- Support for code action kind documentation.
- Add support for `activeParameter` on `SignatureHelp` and `SignatureInformation` being `null`.
- Support tooltips for `Command`.
- Support for meta data information on workspace edits.
- Support for snippets in text document edits.
- Support for debug message kind.
- Client capability to enumerate properties that can be resolved for code lenses.
- Added support for `completionList.applyKind` to determine how values from `completionList.itemDefaults` and `completion` are combined.

#### 3.17.0 (05/10/2022)

- Specify how clients will handle stale requests.
- Added support for a completion item label details.
- Added support for workspace symbol resolve request.
- Added support for label details and insert text mode on completion items.
- Added support for shared values on CompletionItemList.
- Added support for HTML tags in Markdown.
- Added support for collapsed text in folding.
- Added support for trigger kinds on code action requests.
- Added the following support to semantic tokens:
  - server cancelable
  - augmentation of syntax tokens
- Added support to negotiate the position encoding.
- Added support for relative patterns in file watchers.
- Added support for type hierarchies
- Added support for inline values.
- Added support for inlay hints.
- Added support for notebook documents.
- Added support for diagnostic pull model.

#### 3.16.0 (12/14/2020)

- Added support for tracing.
- Added semantic token support.
- Added call hierarchy support.
- Added client capability for resolving text edits on completion items.
- Added support for client default behavior on renames.
- Added support for insert and replace ranges on `CompletionItem`.
- Added support for diagnostic code descriptions.
- Added support for document symbol provider label.
- Added support for tags on `SymbolInformation` and `DocumentSymbol`.
- Added support for moniker request method.
- Added support for code action `data` property.
- Added support for code action `disabled` property.
- Added support for code action resolve request.
- Added support for diagnostic `data` property.
- Added support for signature information `activeParameter` property.
- Added support for `workspace/didCreateFiles` notifications and `workspace/willCreateFiles` requests.
- Added support for `workspace/didRenameFiles` notifications and `workspace/willRenameFiles` requests.
- Added support for `workspace/didDeleteFiles` notifications and `workspace/willDeleteFiles` requests.
- Added client capability to signal whether the client normalizes line endings.
- Added support to preserve additional attributes on `MessageActionItem`.
- Added support to provide the clients locale in the initialize call.
- Added support for opening and showing a document in the client user interface.
- Added support for linked editing.
- Added support for change annotations in text edits as well as in create file, rename file and delete file operations.

#### 3.15.0 (01/14/2020)

- Added generic progress reporting support.
- Added specific work done progress reporting support to requests where applicable.
- Added specific partial result progress support to requests where applicable.
- Added support for `textDocument/selectionRange`.
- Added support for server and client information.
- Added signature help context.
- Added Erlang and Elixir to the list of supported programming languages
- Added `version` on `PublishDiagnosticsParams`
- Added `CodeAction#isPreferred` support.
- Added `CompletionItem#tag` support.
- Added `Diagnostic#tag` support.
- Added `DocumentLink#tooltip` support.
- Added `trimTrailingWhitespace`, `insertFinalNewline` and `trimFinalNewlines` to `FormattingOptions`.
- Clarified `WorkspaceSymbolParams#query` parameter.

#### 3.14.0 (12/13/2018)

- Added support for signature label offsets.
- Added support for location links.
- Added support for `textDocument/declaration` request.

#### 3.13.0 (9/11/2018)

- Added support for file and folder operations (create, rename, move) to workspace edits.

#### 3.12.0 (8/23/2018)

- Added support for `textDocument/prepareRename` request.

#### 3.11.0 (8/21/2018)

- Added support for CodeActionOptions to allow a server to provide a list of code action it supports.

#### 3.10.0 (7/23/2018)

- Added support for hierarchical document symbols as a valid response to a `textDocument/documentSymbol` request.
- Added support for folding ranges as a valid response to a `textDocument/foldingRange` request.

#### 3.9.0 (7/10/2018)

- Added support for `preselect` property in `CompletionItem`

#### 3.8.0 (6/11/2018)

- Added support for CodeAction literals to the `textDocument/codeAction` request.
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

In addition we enhanced the `CompletionTriggerKind` with a new value `TriggerForIncompleteCompletions: 3 = 3` to signal the a completion request got trigger since the last result was incomplete.

#### 3.5.0

Decided to skip this version to bring the protocol version number in sync the with npm module vscode-languageserver-protocol.

#### 3.4.0 (11/27/2017)

- [extensible completion item and symbol kinds](https://github.com/Microsoft/language-server-protocol/issues/129)

#### 3.3.0 (11/24/2017)

- Added support for `CompletionContext`
- Added support for `MarkupContent`
- Removed old New and Updated markers.

#### 3.2.0 (09/26/2017)

- Added optional `commitCharacters` property to the `CompletionItem`

#### 3.1.0 (02/28/2017)

- Make the `WorkspaceEdit` changes backwards compatible.
- Updated the specification to correctly describe the breaking changes from 2.x to 3.x around `WorkspaceEdit`and `TextDocumentEdit`.

#### 3.0 Version

- Added support for client feature flags to support that servers can adapt to different client capabilities. An example is the new `textDocument/willSaveWaitUntil` request which not all clients might be able to support. If the feature is disabled in the client capabilities sent on the initialize request, the server can't rely on receiving the request.
- Added support to experiment with new features. The new `ClientCapabilities.experimental` section together with feature flags allow servers to provide experimental feature without the need of ALL clients to adopt them immediately.
- servers can more dynamically react to client features. Capabilities can now be registered and unregistered after the initialize request using the new `client/registerCapability` and `client/unregisterCapability`. This, for example, allows servers to react to settings or configuration changes without a restart.
- Added support for `textDocument/willSave` notification and `textDocument/willSaveWaitUntil` request.
- Added support for `textDocument/documentLink` request.
- Added a `rootUri` property to the initializeParams in favor of the `rootPath` property.
