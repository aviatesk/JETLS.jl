/**
 * Defines an integer number in the range of -2^31 to 2^31 - 1.
 */
export type integer = number;

/**
 * Defines an unsigned integer number in the range of 0 to 2^31 - 1.
 */
export type uinteger = number;

/**
 * Defines a decimal number. Since decimal numbers are very
 * rare in the language server specification we denote the
 * exact range with every decimal using the mathematics
 * interval notation (e.g. [0, 1] denotes all decimals d with
 * 0 <= d <= 1.
 */
export type decimal = number;

/**
 * The LSP any type
 *
 * @since 3.17.0
 */
export type LSPAny = any;

/**
 * LSP object definition.
 *
 * @since 3.17.0
 */
export type LSPObject = { [key: string]: LSPAny };

/**
 * LSP arrays.
 *
 * @since 3.17.0
 */
export type LSPArray = LSPAny[];

export type array = LSPArray;

/**
 * A general message as defined by JSON-RPC. The language server protocol always uses “2.0” as the jsonrpc version.
 */
interface Message {
	jsonrpc: '2.0';
}

/**
 * A request message to describe a request between the client and the server. Every processed request must send a response back to the sender of the request.
 */
interface RequestMessage extends Message {

	/**
	 * The request id.
	 */
	id: integer;

	/**
	 * The method to be invoked.
	 */
	method: string;

	/**
	 * The method's params.
	 */
	params?: LSPAny;
}

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

/**
 * A Response Message sent as a result of a request. If a request doesn’t provide a result value the receiver of a request still needs to return a response message to conform to the JSON-RPC specification. The result property of the ResponseMessage should be set to null in this case to signal a successful request.
 */
interface ResponseMessage extends Message {
	/**
	 * The request id.
	 */
	id: integer | null;

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
	 * request before the server has received the `initialize` request.
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

/**
 * A notification message. A processed notification message must not send a response back. They work like events.
 */
interface NotificationMessage extends Message {
	/**
	 * The method to be invoked.
	 */
	method: string;

	/**
	 * The notification's params.
	 */
	params?: LSPAny;
}

type DocumentUri = string;

type URI = string;

/**
 * Position in a text document expressed as zero-based line and zero-based character offset.
 * A position is between two characters like an ‘insert’ cursor in an editor.
 * Special values like for example -1 to denote the end of a line are not supported.
 */
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

/**
 * The base protocol offers also support to report progress in a generic fashion. This mechanism can be used to report any kind of progress including work done progress (usually used to report progress in the user interface using a progress bar) and partial result progress to support streaming of results.
 *
 * A progress notification has the following properties:
 * Notification:
 * - method: ‘$/progress’
 * - params: ProgressParams defined as follows:
 */
type ProgressToken = integer | string;
// interface ProgressParams<T> {
// 	/**
// 	 * The progress token provided by the client or server.
// 	 */
// 	token: ProgressToken;

// 	/**
// 	 * The progress data.
// 	 */
// 	value: T;
// }

export interface WorkDoneProgressParams {
	/**
	 * An optional token that a server can use to report work done progress.
	 */
	workDoneToken?: ProgressToken;
}


export interface PartialResultParams {
	/**
	 * An optional token that a server can use to report partial results (e.g.
	 * streaming) to the client.
	 */
	partialResultToken?: ProgressToken;
}

/**
 * A TraceValue represents the level of verbosity with which the server systematically reports its execution trace using $/logTrace notifications. The initial trace value is set by the client at initialization and can be modified later using the $/setTrace notification.
 */
export type TraceValue = 'off' | 'messages' | 'verbose';

// Lifecycle Messages
// ==================

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

// 		/**
// 		 * Capabilities specific to `WorkspaceEdit`s
// 		 */
// 		workspaceEdit?: WorkspaceEditClientCapabilities;

// 		/**
// 		 * Capabilities specific to the `workspace/didChangeConfiguration`
// 		 * notification.
// 		 */
// 		didChangeConfiguration?: DidChangeConfigurationClientCapabilities;

// 		/**
// 		 * Capabilities specific to the `workspace/didChangeWatchedFiles`
// 		 * notification.
// 		 */
// 		didChangeWatchedFiles?: DidChangeWatchedFilesClientCapabilities;

// 		/**
// 		 * Capabilities specific to the `workspace/symbol` request.
// 		 */
// 		symbol?: WorkspaceSymbolClientCapabilities;

// 		/**
// 		 * Capabilities specific to the `workspace/executeCommand` request.
// 		 */
// 		executeCommand?: ExecuteCommandClientCapabilities;

		/**
		 * The client has support for workspace folders.
		 *
		 * @since 3.6.0
		 */
		workspaceFolders?: boolean;

// 		/**
// 		 * The client supports `workspace/configuration` requests.
// 		 *
// 		 * @since 3.6.0
// 		 */
// 		configuration?: boolean;

// 		/**
// 		 * Capabilities specific to the semantic token requests scoped to the
// 		 * workspace.
// 		 *
// 		 * @since 3.16.0
// 		 */
// 		 semanticTokens?: SemanticTokensWorkspaceClientCapabilities;

// 		/**
// 		 * Capabilities specific to the code lens requests scoped to the
// 		 * workspace.
// 		 *
// 		 * @since 3.16.0
// 		 */
// 		codeLens?: CodeLensWorkspaceClientCapabilities;

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

// 		/**
// 		 * Client workspace capabilities specific to inline values.
// 		 *
// 		 * @since 3.17.0
// 		 */
// 		inlineValue?: InlineValueWorkspaceClientCapabilities;

// 		/**
// 		 * Client workspace capabilities specific to inlay hints.
// 		 *
// 		 * @since 3.17.0
// 		 */
// 		inlayHint?: InlayHintWorkspaceClientCapabilities;

// 		/**
// 		 * Client workspace capabilities specific to diagnostics.
// 		 *
// 		 * @since 3.17.0.
// 		 */
// 		diagnostics?: DiagnosticWorkspaceClientCapabilities;
	};

// 	/**
// 	 * Text document specific client capabilities.
// 	 */
// 	textDocument?: TextDocumentClientCapabilities;

// 	/**
// 	 * Capabilities specific to the notebook document support.
// 	 *
// 	 * @since 3.17.0
// 	 */
// 	notebookDocument?: NotebookDocumentClientCapabilities;

// 	/**
// 	 * Window specific client capabilities.
// 	 */
// 	window?: {
// 		/**
// 		 * It indicates whether the client supports server initiated
// 		 * progress using the `window/workDoneProgress/create` request.
// 		 *
// 		 * The capability also controls Whether client supports handling
// 		 * of progress notifications. If set servers are allowed to report a
// 		 * `workDoneProgress` property in the request specific server
// 		 * capabilities.
// 		 *
// 		 * @since 3.15.0
// 		 */
// 		workDoneProgress?: boolean;

// 		/**
// 		 * Capabilities specific to the showMessage request
// 		 *
// 		 * @since 3.16.0
// 		 */
// 		showMessage?: ShowMessageRequestClientCapabilities;

// 		/**
// 		 * Client capabilities for the show document request.
// 		 *
// 		 * @since 3.16.0
// 		 */
// 		showDocument?: ShowDocumentClientCapabilities;
// 	};

// 	/**
// 	 * General client capabilities.
// 	 *
// 	 * @since 3.16.0
// 	 */
// 	general?: {
// 		/**
// 		 * Client capability that signals how the client
// 		 * handles stale requests (e.g. a request
// 		 * for which the client will not process the response
// 		 * anymore since the information is outdated).
// 		 *
// 		 * @since 3.17.0
// 		 */
// 		staleRequestSupport?: {
// 			/**
// 			 * The client will actively cancel the request.
// 			 */
// 			cancel: boolean;

// 			/**
// 			 * The list of requests for which the client
// 			 * will retry the request if it receives a
// 			 * response with error code `ContentModified``
// 			 */
// 			 retryOnContentModified: string[];
// 		}

// 		/**
// 		 * Client capabilities specific to regular expressions.
// 		 *
// 		 * @since 3.16.0
// 		 */
// 		regularExpressions?: RegularExpressionsClientCapabilities;

// 		/**
// 		 * Client capabilities specific to the client's markdown parser.
// 		 *
// 		 * @since 3.16.0
// 		 */
// 		markdown?: MarkdownClientCapabilities;

// 		/**
// 		 * The position encodings supported by the client. Client and server
// 		 * have to agree on the same position encoding to ensure that offsets
// 		 * (e.g. character position in a line) are interpreted the same on both
// 		 * side.
// 		 *
// 		 * To keep the protocol backwards compatible the following applies: if
// 		 * the value 'utf-16' is missing from the array of position encodings
// 		 * servers can assume that the client supports UTF-16. UTF-16 is
// 		 * therefore a mandatory encoding.
// 		 *
// 		 * If omitted it defaults to ['utf-16'].
// 		 *
// 		 * Implementation considerations: since the conversion from one encoding
// 		 * into another requires the content of the file / line the conversion
// 		 * is best done where the file is read which is usually on the server
// 		 * side.
// 		 *
// 		 * @since 3.17.0
// 		 */
// 		positionEncodings?: PositionEncodingKind[];
// 	};

	/**
	 * Experimental client capabilities.
	 */
	experimental?: LSPAny;
}

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

/**
 * A pattern to describe in which file operation requests or notifications
 * the server is interested in.
 *
 * @since 3.16.0
 */
interface FileOperationPattern {
	/**
	 * The glob pattern to match. Glob patterns can have the following syntax:
	 * - `*` to match one or more characters in a path segment
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

/**
 * A filter to describe in which file operation requests or notifications
 * the server is interested in.
 *
 * @since 3.16.0
 */
export interface FileOperationFilter {

	/**
	 * A Uri like `file` or `untitled`.
	 */
	scheme?: string;

	/**
	 * The actual file operation pattern.
	 */
	pattern: FileOperationPattern;
}

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

/**
 * The initialize request is sent as the first request from the client to the server. If the server receives a request or notification before the initialize request it should act as follows:
 * - For a request the response should be an error with code: -32002. The message can be picked by the server.
 * - Notifications should be dropped, except for the exit notification. This will allow the exit of a server without an initialize request.
 * Until the server has responded to the initialize request with an InitializeResult, the client must not send any additional requests or notifications to the server. In addition the server is not allowed to send any requests or notifications to the client until it has responded with an InitializeResult, with the exception that during the initialize request the server is allowed to send the notifications window/showMessage, window/logMessage and telemetry/event as well as the window/showMessageRequest request to the client. In case the client sets up a progress token in the initialize params (e.g. property workDoneToken) the server is also allowed to use that token (and only that token) using the $/progress notification sent from the server to the client.
 * The initialize request may only be sent once.
 */
interface InitializeRequest extends RequestMessage {
	method: 'initialize';
	params: InitializeParams;
}

/**
 *  The initialized notification is sent from the client to the server after the client received the result of the initialize request but before the client is sending any other request or notification to the server. The server can use the initialized notification, for example, to dynamically register capabilities. The initialized notification may only be sent once.
 */
interface InitializedNotification extends NotificationMessage {
	method: 'initialized';
}

interface ShutdownRequest extends RequestMessage {
	method: 'shutdown';
}

interface ExitNotification extends NotificationMessage {
	method: 'exit';
}

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
	 * so this `PositionEncodingKind` may also be used for an
	 * encoding-agnostic representation of character offsets.
	 */
	export const UTF32: PositionEncodingKind = 'utf-32';
}

/**
 * A range in a text document expressed as (zero-based) start and end positions. A range is comparable to a selection in an editor. Therefore, the end position is exclusive. If you want to specify a range that contains a line including the line ending character(s) then use an end position denoting the start of the next line. For example:
 * ```json
 * {
 * 	   start: { line: 5, character: 23 },
 * 		 end : { line: 6, character: 0 }
 * }
 * ```
 */
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

/**
 * An item to transfer a text document from the client to the server.
 */
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


/**
 * Text documents are identified using a URI. On the protocol level, URIs are passed as strings. The corresponding JSON structure looks like this:
 */
interface TextDocumentIdentifier {
	/**
	 * The text document's URI.
	 */
	uri: DocumentUri;
}

/**
 * An identifier to denote a specific version of a text document. This information usually flows from the client to the server.
 */
interface VersionedTextDocumentIdentifier extends TextDocumentIdentifier {
	/**
	 * The version number of this document.
	 *
	 * The version number of a document will increase after each change,
	 * including undo/redo. The number doesn't need to be consecutive.
	 */
	version: integer;
}

/**
 * An identifier which optionally denotes a specific version of a text document. This information usually flows from the server to the client.
 */
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

/**
 * A document filter denotes a document through properties like language, scheme or pattern. An example is a filter that applies to TypeScript files on disk. Another example is a filter that applies to JSON files with name package.json:
 * ```json
 * { language: 'typescript', scheme: 'file' }
 * { language: 'json', pattern: '**\/package.json' }
 * ```
 *
 * Please note that for a document filter to be valid at least one of the properties for language, scheme, or pattern must be set. To keep the type definition simple all properties are marked as optional.
 */
export interface DocumentFilter {
	/**
	 * A language id, like `typescript`.
	 */
	language?: string;

	/**
	 * A Uri scheme, like `file` or `untitled`.
	 */
	scheme?: string;

	/**
	 * A glob pattern, like `*.{ts,js}`.
	 *
	 * Glob patterns can have the following syntax:
	 * - `*` to match one or more characters in a path segment
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
	pattern?: string;
}

/**
 * A document selector is the combination of one or more document filters.
 */
export type DocumentSelector = DocumentFilter[];

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

interface DidOpenTextDocumentParams {
	/**
	 * The document that was opened.
	 */
	textDocument: TextDocumentItem;
}

/**
 * The document open notification is sent from the client to the server to signal newly opened text documents. The document’s content is now managed by the client and the server must not try to read the document’s content using the document’s Uri. Open in this sense means it is managed by the client. It doesn’t necessarily mean that its content is presented in an editor. An open notification must not be sent more than once without a corresponding close notification send before. This means open and close notification must be balanced and the max open count for a particular textDocument is one. Note that a server’s ability to fulfill requests is independent of whether a text document is open or closed.
 *
 * The DidOpenTextDocumentParams contain the language id the document is associated with. If the language id of a document changes, the client needs to send a textDocument/didClose to the server followed by a textDocument/didOpen with the new language id if the server handles the new language id as well.
 */
interface DidOpenTextDocumentNotification extends NotificationMessage {
	method: 'textDocument/didOpen';
	params: DidOpenTextDocumentParams;
}

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

/**
 * An event describing a change to a text document. If only a text is provided
 * it is considered to be the full content of the document.
 */
export interface TextDocumentContentChangeEvent {
	/**
	 * The range of the document that changed.
	 */
	range?: Range;

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

/**
 * The document change notification is sent from the client to the server to signal changes to a text document. Before a client can change a text document it must claim ownership of its content using the textDocument/didOpen notification. In 2.0 the shape of the params has changed to include proper version numbers.
 */
interface DidChangeTextDocumentNotification extends NotificationMessage {
	method: 'textDocument/didChange';
	params: DidChangeTextDocumentParams;
}

interface DidCloseTextDocumentParams {
	/**
	 * The document that was closed.
	 */
	textDocument: TextDocumentIdentifier;
}

/**
 * The document close notification is sent from the client to the server when the document got closed in the client. The document’s master now exists where the document’s Uri points to (e.g. if the document’s Uri is a file Uri the master now exists on disk). As with the open notification the close notification is about managing the document’s content. Receiving a close notification doesn’t mean that the document was open in an editor before. A close notification requires a previous open notification to be sent. Note that a server’s ability to fulfill requests is independent of whether a text document is open or closed.
 */
interface DidCloseTextDocumentNotification extends NotificationMessage {
	method: 'textDocument/didClose';
	params: DidCloseTextDocumentParams;
}

export interface SaveOptions {
	/**
	 * The client is supposed to include the content on save.
	 */
	includeText?: boolean;
}

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

interface DidSaveTextDocumentNotification extends NotificationMessage {
	method: 'textDocument/didSave';
	params: DidSaveTextDocumentParams;
}

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

export interface WorkDoneProgressOptions {
	workDoneProgress?: boolean;
}

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

/**
 * Since version 3.6.0
 *
 * Many tools support more than one root folder per workspace. Examples for this are VS Code’s multi-root support, Atom’s project folder support or Sublime’s project support. If a client workspace consists of multiple roots then a server typically needs to know about this. The protocol up to now assumes one root folder which is announced to the server by the rootUri property of the InitializeParams. If the client supports workspace folders and announces them via the corresponding workspaceFolders client capability, the InitializeParams contain an additional property workspaceFolders with the configured workspace folders when the server starts.
 *
 * The workspace/workspaceFolders request is sent from the server to the client to fetch the current open list of workspace folders. Returns null in the response if only a single file is open in the tool. Returns an empty array if a workspace is open but no folders are configured.
 */
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
	 * using the `client/unregisterCapability` request.
	 */
	changeNotifications?: string | boolean;
}

/**
 * Diagnostic registration options.
 *
 * @since 3.17.0
 */
export interface DiagnosticRegistrationOptions extends
	TextDocumentRegistrationOptions, DiagnosticOptions,
	StaticRegistrationOptions {
}

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

	// /**
	//  * Defines how notebook documents are synced.
	//  *
	//  * @since 3.17.0
	//  */
	// notebookDocumentSync?: NotebookDocumentSyncOptions
	// 	| NotebookDocumentSyncRegistrationOptions;

	// /**
	//  * The server provides completion support.
	//  */
	// completionProvider?: CompletionOptions;

	// /**
	//  * The server provides hover support.
	//  */
	// hoverProvider?: boolean | HoverOptions;

	// /**
	//  * The server provides signature help support.
	//  */
	// signatureHelpProvider?: SignatureHelpOptions;

	// /**
	//  * The server provides go to declaration support.
	//  *
	//  * @since 3.14.0
	//  */
	// declarationProvider?: boolean | DeclarationOptions
	// 	| DeclarationRegistrationOptions;

	// /**
	//  * The server provides goto definition support.
	//  */
	// definitionProvider?: boolean | DefinitionOptions;

	// /**
	//  * The server provides goto type definition support.
	//  *
	//  * @since 3.6.0
	//  */
	// typeDefinitionProvider?: boolean | TypeDefinitionOptions
	// 	| TypeDefinitionRegistrationOptions;

	// /**
	//  * The server provides goto implementation support.
	//  *
	//  * @since 3.6.0
	//  */
	// implementationProvider?: boolean | ImplementationOptions
	// 	| ImplementationRegistrationOptions;

	// /**
	//  * The server provides find references support.
	//  */
	// referencesProvider?: boolean | ReferenceOptions;

	// /**
	//  * The server provides document highlight support.
	//  */
	// documentHighlightProvider?: boolean | DocumentHighlightOptions;

	// /**
	//  * The server provides document symbol support.
	//  */
	// documentSymbolProvider?: boolean | DocumentSymbolOptions;

	// /**
	//  * The server provides code actions. The `CodeActionOptions` return type is
	//  * only valid if the client signals code action literal support via the
	//  * property `textDocument.codeAction.codeActionLiteralSupport`.
	//  */
	// codeActionProvider?: boolean | CodeActionOptions;

	// /**
	//  * The server provides code lens.
	//  */
	// codeLensProvider?: CodeLensOptions;

	// /**
	//  * The server provides document link support.
	//  */
	// documentLinkProvider?: DocumentLinkOptions;

	// /**
	//  * The server provides color provider support.
	//  *
	//  * @since 3.6.0
	//  */
	// colorProvider?: boolean | DocumentColorOptions
	// 	| DocumentColorRegistrationOptions;

	// /**
	//  * The server provides document formatting.
	//  */
	// documentFormattingProvider?: boolean | DocumentFormattingOptions;

	// /**
	//  * The server provides document range formatting.
	//  */
	// documentRangeFormattingProvider?: boolean | DocumentRangeFormattingOptions;

	// /**
	//  * The server provides document formatting on typing.
	//  */
	// documentOnTypeFormattingProvider?: DocumentOnTypeFormattingOptions;

	// /**
	//  * The server provides rename support. RenameOptions may only be
	//  * specified if the client states that it supports
	//  * `prepareSupport` in its initial `initialize` request.
	//  */
	// renameProvider?: boolean | RenameOptions;

	// /**
	//  * The server provides folding provider support.
	//  *
	//  * @since 3.10.0
	//  */
	// foldingRangeProvider?: boolean | FoldingRangeOptions
	// 	| FoldingRangeRegistrationOptions;

	// /**
	//  * The server provides execute command support.
	//  */
	// executeCommandProvider?: ExecuteCommandOptions;

	// /**
	//  * The server provides selection range support.
	//  *
	//  * @since 3.15.0
	//  */
	// selectionRangeProvider?: boolean | SelectionRangeOptions
	// 	| SelectionRangeRegistrationOptions;

	// /**
	//  * The server provides linked editing range support.
	//  *
	//  * @since 3.16.0
	//  */
	// linkedEditingRangeProvider?: boolean | LinkedEditingRangeOptions
	// 	| LinkedEditingRangeRegistrationOptions;

	// /**
	//  * The server provides call hierarchy support.
	//  *
	//  * @since 3.16.0
	//  */
	// callHierarchyProvider?: boolean | CallHierarchyOptions
	// 	| CallHierarchyRegistrationOptions;

	// /**
	//  * The server provides semantic tokens support.
	//  *
	//  * @since 3.16.0
	//  */
	// semanticTokensProvider?: SemanticTokensOptions
	// 	| SemanticTokensRegistrationOptions;

	// /**
	//  * Whether server provides moniker support.
	//  *
	//  * @since 3.16.0
	//  */
	// monikerProvider?: boolean | MonikerOptions | MonikerRegistrationOptions;

	// /**
	//  * The server provides type hierarchy support.
	//  *
	//  * @since 3.17.0
	//  */
	// typeHierarchyProvider?: boolean | TypeHierarchyOptions
	// 	 | TypeHierarchyRegistrationOptions;

	// /**
	//  * The server provides inline values.
	//  *
	//  * @since 3.17.0
	//  */
	// inlineValueProvider?: boolean | InlineValueOptions
	// 	 | InlineValueRegistrationOptions;

	// /**
	//  * The server provides inlay hints.
	//  *
	//  * @since 3.17.0
	//  */
	// inlayHintProvider?: boolean | InlayHintOptions
	// 	 | InlayHintRegistrationOptions;

	/**
	 * The server has support for pull model diagnostics.
	 *
	 * @since 3.17.0
	 */
	diagnosticProvider?: DiagnosticOptions | DiagnosticRegistrationOptions;

	// /**
	//  * The server provides workspace symbol support.
	//  */
	// workspaceSymbolProvider?: boolean | WorkspaceSymbolOptions;

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

	// /**
	//  * Experimental server capabilities.
	//  */
	// experimental?: LSPAny;
}

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

interface InitializeError {
	/**
	 * Indicates whether the client execute the following retry logic:
	 * (1) show the message provided by the ResponseError to the user
	 * (2) user selects retry or cancel
	 * (3) if user selected retry the initialize method is sent again.
	 */
	retry: boolean;
}

interface InitializeResponseError extends ResponseError {
	code: // @ts-ignore
		InitializeErrorCodes.unknownProtocolVersion;
	data: InitializeError;
}

interface InitializeResponse extends ResponseMessage {
	result?: InitializeResult;
	error?: InitializeResponseError;
}

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

/**
 * Represents a location inside a resource, such as a line inside a text file.
 */
interface Location {
	uri: DocumentUri;
	range: Range;
}

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
	 * `textDocument/publishDiagnostics` notification and
	 * `textDocument/codeAction` request.
	 *
	 * @since 3.16.0
	 */
	data?: LSPAny;
}

/**
 * A diagnostic report with a full set of problems.
 *
 * @since 3.17.0
 */
export interface FullDocumentDiagnosticReport {
	/**
	 * A full document diagnostic report.
	 */
	kind: /* @ts-expect-error */
		DocumentDiagnosticReportKind.Full;

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
	 * only return `unchanged` if result ids are
	 * provided.
	 */
	kind: /* @ts-expect-error */
		DocumentDiagnosticReportKind.Unchanged;

	/**
	 * A result id which will be sent on the next
	 * diagnostic request for the same document.
	 */
	resultId: string;
}

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
	 * If the document is not marked as open `null` can be provided.
	 */
	version: integer | null;
}

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
	 * If the document is not marked as open `null` can be provided.
	 */
	version: integer | null;
};

/**
 * A workspace diagnostic document report.
 *
 * @since 3.17.0
 */
export type WorkspaceDocumentDiagnosticReport =
	WorkspaceFullDocumentDiagnosticReport
	| WorkspaceUnchangedDocumentDiagnosticReport;

/**
 * A workspace diagnostic report.
 *
 * @since 3.17.0
 */
export interface WorkspaceDiagnosticReport {
	items: WorkspaceDocumentDiagnosticReport[];
}

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

export interface WorkspaceDiagnosticRequest extends RequestMessage {
	method: 'workspace/diagnostic';
	params: WorkspaceDiagnosticParams;
}
