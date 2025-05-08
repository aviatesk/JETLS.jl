"""
Text document specific client capabilities.
"""
@interface TextDocumentClientCapabilities begin
	# synchronization::Union{TextDocumentSyncClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/completion` request.
	# """
	# completion::Union{CompletionClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/hover` request.
	# """
	# hover::Union{HoverClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/signatureHelp` request.
	# """
	# signatureHelp::Union{SignatureHelpClientCapabilities, Nothing} = nothing

	# """
	# Capabilities:sUnion{ecific to the `textDocument/declaration` request

        # # Tags
	# - since - 3.14.0
	# """
	# declaration::Union{DeclarationClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/definition` request.
	# """
	# definition::Union{DefinitionClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/typeDefinition` request.

        # # Tags
	# - since - 3.6.0
	# """
	# typeDefinition::Union{TypeDefinitionClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/implementation` request.

        # # Tags
	# - since - 3.6.0
	# """
	# implementation::Union{ImplementationClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/references` request.
	# """
	# references::Union{ReferenceClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/documentHighlight` request.
	# """
	# documentHighlight::Union{DocumentHighlightClientCapabilities, Nothing} = nothing

	"""
	Capabilities specific to the `textDocument/documentSymbol` request.
	"""
	documentSymbol::Union{DocumentSymbolClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/codeAction` request.
	# """
	# codeAction::Union{CodeActionClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/codeLens` request.
	# """
	# codeLens::Union{CodeLensClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/documentLink` request.
	# """
	# documentLink::Union{DocumentLinkClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/documentColor` and the
	# `textDocument/colorPresentation` request.

        # # Tags
	# - since - 3.6.0
	# """
	# colorProvider::Union{DocumentColorClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/formatting` request.
	# """
	# formatting::Union{DocumentFormattingClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/rangeFormatting` request.
	# """
	# rangeFormatting::Union{DocumentRangeFormattingClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/onTypeFormatting` request.
	# """
	# onTypeFormatting::Union{DocumentOnTypeFormattingClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/rename` request.
	# """
	# rename::Union{RenameClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/publishDiagnostics`
	# notification.
	# """
	# publishDiagnostics::Union{PublishDiagnosticsClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/foldingRange` request.

        # # Tags
	# - since - 3.10.0
	# """
	# foldingRange::Union{FoldingRangeClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/selectionRange` request.

        # # Tags
	# - since - 3.15.0
	# """
	# selectionRange::Union{SelectionRangeClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/linkedEditingRange` request.

        # # Tags
	# - since - 3.16.0
	# """
	# linkedEditingRange::Union{LinkedEditingRangeClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the various call hierarchy requests.

        # # Tags
	# - since - 3.16.0
	# """
	# callHierarchy::Union{CallHierarchyClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the various semantic token requests.

        # # Tags
	# - since - 3.16.0
	# """
	# semanticTokens::Union{SemanticTokensClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/moniker` request.

        # # Tags
	# - since - 3.16.0
	# """
	# moniker::Union{MonikerClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the various type hierarchy requests.

        # # Tags
	# - since - 3.17.0
	# """
	# typeHierarchy::Union{TypeHierarchyClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/inlineValue` request.

        # # Tags
	# - since - 3.17.0
	# """
	# inlineValue::Union{InlineValueClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the `textDocument/inlayHint` request.

        # # Tags
	# - since - 3.17.0
	# """
	# inlayHint::Union{InlayHintClientCapabilities, Nothing} = nothing

	# """
	# Capabilities specific to the diagnostic pull model.

        # # Tags
	# - since - 3.17.0
	# """
	# diagnostic::Union{DiagnosticClientCapabilities, Nothing} = nothing
end
