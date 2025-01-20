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
export type LSPAny = LSPObject | LSPArray | string | integer | uinteger |
	decimal | boolean | null;

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

export interface SaveOptions {
	/**
	 * The client is supposed to include the content on save.
	 */
	includeText?: boolean;
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
 * General text document registration options.
 */
export interface TextDocumentRegistrationOptions {
	/**
	 * A document selector to identify the scope of the registration. If set to
	 * null the document selector provided on the client side will be used.
	 */
	documentSelector: DocumentSelector | null;
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

	// /**
	//  * Workspace specific server capabilities
	//  */
	// workspace?: {
	// 	/**
	// 	 * The server supports workspace folder.
	// 	 *
	// 	 * @since 3.6.0
	// 	 */
	// 	workspaceFolders?: WorkspaceFoldersServerCapabilities;

	// 	/**
	// 	 * The server is interested in file notifications/requests.
	// 	 *
	// 	 * @since 3.16.0
	// 	 */
	// 	fileOperations?: {
	// 		/**
	// 		 * The server is interested in receiving didCreateFiles
	// 		 * notifications.
	// 		 */
	// 		didCreate?: FileOperationRegistrationOptions;

	// 		/**
	// 		 * The server is interested in receiving willCreateFiles requests.
	// 		 */
	// 		willCreate?: FileOperationRegistrationOptions;

	// 		/**
	// 		 * The server is interested in receiving didRenameFiles
	// 		 * notifications.
	// 		 */
	// 		didRename?: FileOperationRegistrationOptions;

	// 		/**
	// 		 * The server is interested in receiving willRenameFiles requests.
	// 		 */
	// 		willRename?: FileOperationRegistrationOptions;

	// 		/**
	// 		 * The server is interested in receiving didDeleteFiles file
	// 		 * notifications.
	// 		 */
	// 		didDelete?: FileOperationRegistrationOptions;

	// 		/**
	// 		 * The server is interested in receiving willDeleteFiles file
	// 		 * requests.
	// 		 */
	// 		willDelete?: FileOperationRegistrationOptions;
	// 	};
	// };

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
