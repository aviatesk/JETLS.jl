# Document synchronization
# ========================

get_notebook_info(state::ServerState, uri::URI) =
    get(load(state.notebook_cache), uri, nothing)

get_notebook_uri_for_cell(state::ServerState, cell_uri::URI) =
    get(load(state.cell_to_notebook), cell_uri, nothing)

function concatenate_cells(cells::Vector{NotebookCellInfo})
    source = ""
    cell_ranges = CellRange[]
    current_line = 0
    for cell in cells
        cell.kind == NotebookCellKind.Code || continue
        isempty(cell.text) && continue
        source *= cell.text * "\n"
        push!(cell_ranges, CellRange(cell.uri, current_line))
        current_line += count(==('\n'), cell.text) + 1
    end
    return ConcatenatedNotebook(source, cell_ranges)
end

function cache_notebook_file_info!(server::Server, notebook_uri::URI, notebook_info::NotebookInfo)
    state = server.state
    parsed_stream = ParseStream!(notebook_info.concat.source)
    fi = FileInfo(notebook_info.version, parsed_stream, notebook_uri, notebook_info.encoding)
    return store!(state.file_cache) do cache
        Base.PersistentDict(cache, notebook_uri => fi), fi
    end
end

function cache_notebook_saved_file_info!(server::Server, notebook_uri::URI, notebook_info::NotebookInfo)
    state = server.state
    parsed_stream = ParseStream!(notebook_info.concat.source)
    sfi = SavedFileInfo(parsed_stream, notebook_uri)
    return store!(state.saved_file_cache) do cache
        Base.PersistentDict(cache, notebook_uri => sfi), sfi
    end
end

cells_from_lsp(cells::Vector{NotebookCell}) =
    NotebookCellInfo[NotebookCellInfo(cell.document, cell.kind, "") for cell in cells]

function apply_cell_structure_change!(
        cells::Vector{NotebookCellInfo},
        cell_texts::Dict{URI,String},
        structure::NotebookDocumentChangeEventCellsStructure
    )
    array_change = structure.array
    start_idx = array_change.start + 1
    delete_count = array_change.deleteCount
    if delete_count > 0
        deleteat!(cells, start_idx:start_idx+delete_count-1)
    end
    new_cells = array_change.cells
    if new_cells !== nothing
        splice!(cells, start_idx:start_idx-1, cells_from_lsp(new_cells))
    end
    did_open = structure.didOpen
    if did_open !== nothing
        for doc in did_open
            cell_texts[doc.uri] = doc.text
        end
    end
    did_close = structure.didClose
    if did_close !== nothing
        for doc in did_close
            delete!(cell_texts, doc.uri)
        end
    end
end

function apply_cell_data_change!(cells::Vector{NotebookCellInfo}, data::Vector{NotebookCell})
    for updated_cell in data
        for (i, cell) in enumerate(cells)
            if cell.uri == updated_cell.document
                cells[i] = NotebookCellInfo(updated_cell.document, updated_cell.kind, cell.text)
                break
            end
        end
    end
end

# NOTE: This function implements incremental text change application because VS Code's
# notebook client sends incremental changes by default. Unlike regular text documents where
# servers can specify `TextDocumentSyncKind.Full` to receive full content on each change,
# `NotebookDocumentSyncOptions` does not provide an equivalent option for cell text content.
function apply_cell_text_change!(
        cell_texts::Dict{URI,String},
        text_content::Vector{NotebookDocumentChangeEventCellsTextContentItem},
        encoding::PositionEncodingKind.Ty
    )
    for content_change in text_content
        doc_uri = content_change.document.uri
        current_text = get(cell_texts, doc_uri, "")
        for change_event in content_change.changes
            if change_event.range === nothing
                current_text = change_event.text
            else
                current_text = apply_text_change(
                    current_text, change_event.range, change_event.text, encoding)
            end
        end
        cell_texts[doc_uri] = current_text
    end
end

function handle_DidOpenNotebookDocumentNotification(
        server::Server, msg::DidOpenNotebookDocumentNotification
    )
    state = server.state
    notebook_doc = msg.params.notebookDocument
    notebook_uri = notebook_doc.uri
    cell_texts = Dict{URI,String}(doc.uri => doc.text for doc in msg.params.cellTextDocuments)
    cells = NotebookCellInfo[
        NotebookCellInfo(cell.document, cell.kind, get(cell_texts, cell.document, ""))
        for cell in notebook_doc.cells]
    concat = concatenate_cells(cells)
    notebook_info = NotebookInfo(
        notebook_doc.version, notebook_doc.notebookType, state.encoding, cells, concat)
    store!(state.notebook_cache) do cache::Base.PersistentDict{URI,NotebookInfo}
        Base.PersistentDict(cache, notebook_uri => notebook_info), nothing
    end
    store!(state.cell_to_notebook) do mapping::Base.PersistentDict{URI,URI}
        for cell in cells
            mapping = Base.PersistentDict(mapping, cell.uri => notebook_uri)
        end
        mapping, nothing
    end
    cache_notebook_file_info!(server, notebook_uri, notebook_info)
    cache_notebook_saved_file_info!(server, notebook_uri, notebook_info)
    request_analysis!(server, notebook_uri, #=onsave=#false)
    nothing
end

function handle_DidChangeNotebookDocumentNotification(
        server::Server, msg::DidChangeNotebookDocumentNotification
    )
    state = server.state
    notebook_uri = msg.params.notebookDocument.uri
    cells_change = msg.params.change.cells
    next_notebook_info = store!(state.notebook_cache) do cache::Base.PersistentDict{URI,NotebookInfo}
        notebook_info = get(cache, notebook_uri, nothing)
        if notebook_info === nothing
            JETLS_DEV_MODE && @warn "Received notebookDocument/didChange for unknown notebook" notebook_uri
            return cache, nothing
        end
        cells = copy(notebook_info.cells)
        cell_texts = Dict{URI,String}(cell.uri => cell.text for cell in cells)
        if cells_change !== nothing
            structure = cells_change.structure
            structure !== nothing && apply_cell_structure_change!(cells, cell_texts, structure)
            data = cells_change.data
            data !== nothing && apply_cell_data_change!(cells, data)
            text_content = cells_change.textContent
            text_content !== nothing && apply_cell_text_change!(cell_texts, text_content, notebook_info.encoding)
        end
        updated_cells = NotebookCellInfo[
            NotebookCellInfo(cell.uri, cell.kind, get(cell_texts, cell.uri, cell.text))
            for cell in cells]
        concat = concatenate_cells(updated_cells)
        new_notebook_info = NotebookInfo(notebook_info;
            version = msg.params.notebookDocument.version,
            cells = updated_cells,
            concat)
        Base.PersistentDict(cache, notebook_uri => new_notebook_info), new_notebook_info
    end
    next_notebook_info === nothing && return nothing
    store!(state.cell_to_notebook) do mapping::Base.PersistentDict{URI,URI}
        structure = cells_change === nothing ? nothing : cells_change.structure
        if structure !== nothing
            did_close = structure.didClose
            if did_close !== nothing
                for doc in did_close
                    mapping = Base.delete(mapping, doc.uri)
                end
            end
        end
        for cell in next_notebook_info.cells
            mapping = Base.PersistentDict(mapping, cell.uri => notebook_uri)
        end
        mapping, nothing
    end
    cache_notebook_file_info!(server, notebook_uri, next_notebook_info)
    nothing
end

function handle_DidSaveNotebookDocumentNotification(
        server::Server, msg::DidSaveNotebookDocumentNotification
    )
    notebook_uri = msg.params.notebookDocument.uri
    notebook_info = @something get_notebook_info(server.state, notebook_uri) begin
        JETLS_DEV_MODE && @warn "Received notebookDocument/didSave for unknown notebook" notebook_uri
        return nothing
    end
    cache_notebook_saved_file_info!(server, notebook_uri, notebook_info)
    request_analysis!(server, notebook_uri, #=onsave=#true)
    nothing
end

function handle_DidCloseNotebookDocumentNotification(
        server::Server, msg::DidCloseNotebookDocumentNotification
    )
    state = server.state
    notebook_uri = msg.params.notebookDocument.uri
    store!(state.notebook_cache) do cache::Base.PersistentDict{URI,NotebookInfo}
        Base.delete(cache, notebook_uri), nothing
    end
    store!(state.cell_to_notebook) do mapping::Base.PersistentDict{URI,URI}
        for (; uri) in msg.params.cellTextDocuments
            mapping = Base.delete(mapping, uri)
        end
        mapping, nothing
    end
    store!(state.file_cache) do cache
        Base.delete(cache, notebook_uri), nothing
    end
    store!(state.saved_file_cache) do cache
        Base.delete(cache, notebook_uri), nothing
    end
    nothing
end

# Diagnostic
# ==========

is_notebook_uri(state::ServerState, uri::URI) = haskey(load(state.notebook_cache), uri)

function map_notebook_diagnostics!(uri2diagnostics::URI2Diagnostics, state::ServerState)
    notebook_uris_to_delete = URI[]
    for uri in keys(uri2diagnostics)
        is_notebook_uri(state, uri) || continue
        notebook_uri = uri
        notebook_info = @something get_notebook_info(state, notebook_uri) continue
        cell_diagnostics = map_notebook_diagnostics_for_uri(state, uri2diagnostics, notebook_uri)
        for cell in notebook_info.cells
            cell.kind == NotebookCellKind.Code || continue
            diagnostics = get!(Vector{Diagnostic}, uri2diagnostics, cell.uri)
            cell_diags = get(Vector{Diagnostic}, cell_diagnostics, cell.uri)
            append!(diagnostics, cell_diags)
        end
        push!(notebook_uris_to_delete, notebook_uri)
    end
    for notebook_uri in notebook_uris_to_delete
        delete!(uri2diagnostics, notebook_uri)
    end
end

function localize_diagnostic(diag::Diagnostic, cell_range::CellRange)
    local_start_line = diag.range.start.line - cell_range.line_offset
    local_end_line = diag.range.var"end".line - cell_range.line_offset
    return Diagnostic(diag; range = Range(;
        start = Position(; line = local_start_line, character = diag.range.start.character),
        var"end" = Position(; line = local_end_line, character = diag.range.var"end".character)))
end

function map_notebook_diagnostics_for_uri(
        state::ServerState, uri2diagnostics::URI2Diagnostics, notebook_uri::URI
    )
    cell_diagnostics = Dict{URI,Vector{Diagnostic}}()
    notebook_info = @something get_notebook_info(state, notebook_uri) return cell_diagnostics
    isempty(notebook_info.concat.cell_ranges) && return cell_diagnostics
    for diag in uri2diagnostics[notebook_uri]
        cell_range = @something find_cell_for_line(notebook_info.concat, diag.range.start.line) continue
        cell_diag = localize_diagnostic(diag, cell_range)
        push!(get!(Vector{Diagnostic}, cell_diagnostics, cell_range.cell_uri), cell_diag)
    end
    return cell_diagnostics
end

function map_cell_diagnostics(
        state::ServerState, notebook_uri::URI, cell_uri::URI, diagnostics::Vector{Diagnostic}
    )
    notebook_info = @something get_notebook_info(state, notebook_uri) return Diagnostic[]
    cell_range = @something find_cell_range_by_uri(notebook_info.concat, cell_uri) return Diagnostic[]
    result = Diagnostic[]
    for diag in diagnostics
        found_range = @something find_cell_for_line(notebook_info.concat, diag.range.start.line) continue
        found_range.cell_uri == cell_uri || continue
        cell_diag = localize_diagnostic(diag, cell_range)
        push!(result, cell_diag)
    end
    return result
end

# Position
# ========

function find_cell_range_by_uri(concat::ConcatenatedNotebook, cell_uri::URI)
    for range in concat.cell_ranges
        if range.cell_uri == cell_uri
            return range
        end
    end
    return nothing
end

function cell_to_global_position(concat::ConcatenatedNotebook, cell_uri::URI, cell_pos::Position)
    cell_range = @something find_cell_range_by_uri(concat, cell_uri) return nothing
    line = cell_pos.line + cell_range.line_offset
    character = cell_pos.character
    return Position(; line, character)
end

function find_cell_for_line(concat::ConcatenatedNotebook, notebook_line::UInt)
    for (i, range) in enumerate(concat.cell_ranges)
        next_line_offset = i < length(concat.cell_ranges) ?
            concat.cell_ranges[i+1].line_offset : typemax(Int)
        if range.line_offset <= notebook_line < next_line_offset
            return range
        end
    end
    return nothing
end

function global_to_cell_position(concat::ConcatenatedNotebook, notebook_pos::Position)
    cell_range = @something find_cell_for_line(concat, notebook_pos.line) return nothing
    line = notebook_pos.line - cell_range.line_offset
    character = notebook_pos.character
    return Position(; line, character), cell_range.cell_uri
end

"""
    adjust_position(state::ServerState, uri::URI, pos::Position)

Adjust a cell-local position to a global position in the concatenated notebook source.
If the URI is not a notebook cell, returns the position unchanged.
"""
function adjust_position(state::ServerState, uri::URI, pos::Position)
    notebook_uri = @something get_notebook_uri_for_cell(state, uri) return pos
    notebook_info = @something get_notebook_info(state, notebook_uri) return pos
    return @something cell_to_global_position(notebook_info.concat, uri, pos) return pos
end

"""
    unadjust_position(state::ServerState, uri::URI, pos::Position) -> (Position, URI)

Convert a global position in the concatenated notebook source back to a cell-local position.
Returns a tuple of (position, cell_uri) where cell_uri is the URI of the cell containing the position.
If the URI is not a notebook cell, returns the position and URI unchanged.
"""
function unadjust_position(state::ServerState, uri::URI, pos::Position)
    notebook_uri = @something get_notebook_uri_for_cell(state, uri) return (pos, uri)
    notebook_info = @something get_notebook_info(state, notebook_uri) return (pos, uri)
    return @something global_to_cell_position(notebook_info.concat, pos) return (pos, uri)
end

"""
    unadjust_range(state::ServerState, uri::URI, range::Range) -> (Range, URI)

Convert a global range in the concatenated notebook source back to a cell-local range.
Returns a tuple of (range, cell_uri). Note: start and end positions are assumed to be in the same cell.
If the URI is not a notebook cell, returns the range and URI unchanged.
"""
function unadjust_range(state::ServerState, uri::URI, range::Range)
    start_pos, start_uri = unadjust_position(state, uri, range.start)
    end_pos, _ = unadjust_position(state, uri, range.var"end")
    return Range(; start = start_pos, var"end" = end_pos), start_uri
end

function unadjust_location(state::ServerState, cell_uri::URI, loc::Location)
    notebook_uri = @something get_notebook_uri_for_cell(state, cell_uri) return loc
    loc.uri == notebook_uri || return loc
    range, uri = unadjust_range(state, cell_uri, loc.range)
    return Location(; uri, range)
end
