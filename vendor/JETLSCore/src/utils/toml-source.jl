"""
    source_range(bytes::Vector{UInt8}, span::TOMLSource.Span, encoding) -> Range

Return the LSP range of `span` in the TOML source whose bytes are `bytes`.
"""
source_range(
    bytes::Vector{UInt8}, span::TS.Span, encoding::PositionEncodingKind.Ty
) = Range(; start = _offset_to_xy(bytes, span.first, encoding),
            var"end" = _offset_to_xy(bytes, span.past_last, encoding))

"""
    source_text_edit(bytes::Vector{UInt8}, edit::TOMLSource.SourceEdit, encoding)
        -> TextEdit

Return `edit` of the TOML source whose bytes are `bytes` as an LSP text edit.
"""
source_text_edit(
    bytes::Vector{UInt8}, edit::TS.SourceEdit, encoding::PositionEncodingKind.Ty
) = TextEdit(; range = source_range(bytes, edit.span, encoding), newText = edit.text)

"""
    toml_text_and_version(document, uri::URI)
        -> Union{Nothing,Tuple{String,Union{Int,Null}}}

Return the text of the TOML file at `uri` and its version: those of the live buffer
`document` if the file is open, or else its saved content and `null`.
"""
function toml_text_and_version(
        document::Union{Nothing,ConfigDocumentInfo}, uri::URI
    )
    document === nothing || return document.text, document.version
    path = @something uri2filepath(uri) return nothing
    isfile(path) || return nothing
    return read(path, String), null
end
