module test_notebook

include("setup.jl")

using Test
using JETLS
using JETLS.LSP
using JETLS.URIs2

function make_cell_uri(tempdir::AbstractString, cell_id::Union{Int,AbstractString})
    return filepath2uri(normpath(tempdir, "cell_$cell_id"))
end

function make_DidOpenNotebookDocumentNotification(
        notebook_uri::URI,
        cells::Vector{NotebookCell},
        cell_texts::Dict{URI,String};
        version::Int = 1,
        notebookType::String = "jupyter-notebook"
    )
    cellTextDocuments = TextDocumentItem[
        TextDocumentItem(;
            uri = cell.document,
            languageId = "julia",
            version = 1,
            text = get(cell_texts, cell.document, ""))
        for cell in cells if cell.kind == NotebookCellKind.Code]
    return DidOpenNotebookDocumentNotification(;
        params = DidOpenNotebookDocumentParams(;
            notebookDocument = NotebookDocument(;
                uri = notebook_uri,
                notebookType,
                version,
                cells),
            cellTextDocuments))
end

function make_DidChangeNotebookDocumentNotification(
        notebook_uri::URI,
        change::NotebookDocumentChangeEvent;
        version::Int
    )
    return DidChangeNotebookDocumentNotification(;
        params = DidChangeNotebookDocumentParams(;
            notebookDocument = VersionedNotebookDocumentIdentifier(; uri = notebook_uri, version),
            change))
end

function make_DidSaveNotebookDocumentNotification(notebook_uri::URI)
    return DidSaveNotebookDocumentNotification(;
        params = DidSaveNotebookDocumentParams(;
            notebookDocument = NotebookDocumentIdentifier(; uri = notebook_uri)))
end

function make_DocumentDiagnosticRequest(id::Int, uri::URI)
    return DocumentDiagnosticRequest(;
        id,
        params = DocumentDiagnosticParams(;
            textDocument = TextDocumentIdentifier(; uri)))
end

function make_DocumentFormattingRequest(id::Int, uri::URI)
    return DocumentFormattingRequest(;
        id,
        params = DocumentFormattingParams(;
            textDocument = TextDocumentIdentifier(; uri),
            options = FormattingOptions(; tabSize = 4, insertSpaces = true)))
end

function make_DocumentSymbolRequest(id::Int, uri::URI)
    return DocumentSymbolRequest(;
        id,
        params = DocumentSymbolParams(;
            textDocument = TextDocumentIdentifier(; uri)))
end

function make_CodeLensRequest(id::Int, uri::URI)
    return CodeLensRequest(;
        id,
        params = CodeLensParams(;
            textDocument = TextDocumentIdentifier(; uri)))
end

function make_InlayHintRequest(id::Int, uri::URI, range::Range)
    return InlayHintRequest(;
        id,
        params = InlayHintParams(;
            textDocument = TextDocumentIdentifier(; uri),
            range))
end

@testset "notebook end to end" begin
    mktempdir() do tempdir; Pkg.activate(tempdir) do
        Pkg.add("Example"; io=devnull)

        notebook_uri = filepath2uri(normpath(tempdir, "test.ipynb"))

        withserver() do (; server, writemsg, writereadmsg, id_counter)
            cell1_uri = make_cell_uri(tempdir, 1)
            cell2_uri = make_cell_uri(tempdir, 2)

            # 1. Open notebook with one empty cell and wait for PublishDiagnosticsNotification
            let cells = NotebookCell[
                    NotebookCell(; kind = NotebookCellKind.Code, document = cell1_uri),
                ]
                cell_texts = Dict{URI,String}(cell1_uri => "")
                (; raw_res) = writereadmsg(
                    make_DidOpenNotebookDocumentNotification(notebook_uri, cells, cell_texts))
                @test raw_res isa PublishDiagnosticsNotification
            end

            # Verify state after step 1: empty cell should result in empty concat
            let notebook_info = JETLS.get_notebook_info(server.state, notebook_uri)
                @test notebook_info !== nothing
                @test length(notebook_info.cells) == 1
                @test notebook_info.cells[1].uri == cell1_uri
                @test notebook_info.cells[1].text == ""
                @test notebook_info.concat.source == ""
                @test isempty(notebook_info.concat.cell_ranges)
            end

            # 2. Add cell 2 with code that has unused argument
            let cell1_text = "using Example"
                cell2_text = "func(x, y) = identity(x)"
                change = NotebookDocumentChangeEvent(;
                    cells = NotebookDocumentChangeEventCells(;
                        structure = NotebookDocumentChangeEventCellsStructure(;
                            array = NotebookCellArrayChange(;
                                start = UInt(1), deleteCount = UInt(0),
                                cells = [NotebookCell(; kind = NotebookCellKind.Code, document = cell2_uri)]),
                            didOpen = [TextDocumentItem(; uri = cell2_uri, languageId = "julia", version = 1, text = cell2_text)]),
                        textContent = [NotebookDocumentChangeEventCellsTextContentItem(;
                            document = VersionedTextDocumentIdentifier(; uri = cell1_uri, version = 2),
                            changes = [TextDocumentContentChangeEvent(; text = cell1_text)])]))
                writemsg(make_DidChangeNotebookDocumentNotification(notebook_uri, change; version = 2))
            end
            wait_for_file_cache_version(server.state, notebook_uri, 2)

            # 3. Send textDocument/diagnostic for cell 2 -> verify unused `y` diagnostic
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(make_DocumentDiagnosticRequest(id, cell2_uri))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                diagnostics = raw_res.result.items
                found_unused_y = any(diagnostics) do diag
                    diag.code == JETLS.LOWERING_UNUSED_ARGUMENT_CODE &&
                    occursin("y", diag.message)
                end
                @test found_unused_y
            end

            # Verify state after step 2: two cells with correct line offsets
            let notebook_info = JETLS.get_notebook_info(server.state, notebook_uri)
                @test notebook_info !== nothing
                @test length(notebook_info.cells) == 2
                @test notebook_info.cells[1].text == "using Example"
                @test notebook_info.cells[2].text == "func(x, y) = identity(x)"
                @test notebook_info.concat.source == "using Example\nfunc(x, y) = identity(x)\n"
                @test length(notebook_info.concat.cell_ranges) == 2
                @test notebook_info.concat.cell_ranges[1].line_offset == 0
                @test notebook_info.concat.cell_ranges[2].line_offset == 1
            end

            # 4. Update cell 2 to remove unused argument
            let new_text = "func(x) = identity(x)"
                change = NotebookDocumentChangeEvent(;
                    cells = NotebookDocumentChangeEventCells(;
                        textContent = [NotebookDocumentChangeEventCellsTextContentItem(;
                            document = VersionedTextDocumentIdentifier(; uri = cell2_uri, version = 2),
                            changes = [TextDocumentContentChangeEvent(; text = new_text)])]))
                writemsg(make_DidChangeNotebookDocumentNotification(notebook_uri, change; version = 3))
            end
            wait_for_file_cache_version(server.state, notebook_uri, 3)

            # 5. Verify diagnostics no longer have unused `y`
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(make_DocumentDiagnosticRequest(id, cell2_uri))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                diagnostics = raw_res.result.items
                has_unused_y = any(diagnostics) do diag
                    diag.code == JETLS.LOWERING_UNUSED_ARGUMENT_CODE &&
                    occursin("y", diag.message)
                end
                @test !has_unused_y
            end

            # Verify state after step 4: cell 2 text updated
            let notebook_info = JETLS.get_notebook_info(server.state, notebook_uri)
                @test notebook_info !== nothing
                @test notebook_info.cells[2].text == "func(x) = identity(x)"
                @test notebook_info.concat.source == "using Example\nfunc(x) = identity(x)\n"
            end

            # 6. Add markdown cell (should be ignored for diagnostics)
            markdown_uri = make_cell_uri(tempdir, "markdown")
            let new_cells = NotebookCell[
                    NotebookCell(; kind = NotebookCellKind.Markup, document = markdown_uri),
                ]
                change = NotebookDocumentChangeEvent(;
                    cells = NotebookDocumentChangeEventCells(;
                        structure = NotebookDocumentChangeEventCellsStructure(;
                            array = NotebookCellArrayChange(; start = UInt(2), deleteCount = UInt(0), cells = new_cells))))
                writemsg(make_DidChangeNotebookDocumentNotification(notebook_uri, change; version = 4))
            end

            # 7. Add code cell 3 with undefined function call
            cell3_uri = make_cell_uri(tempdir, 3)
            let cell3_text = "undefhello(func(\"world\"))"
                new_cells = NotebookCell[
                    NotebookCell(; kind = NotebookCellKind.Code, document = cell3_uri),
                ]
                cell_texts = [
                    TextDocumentItem(; uri = cell3_uri, languageId = "julia", version = 1, text = cell3_text),
                ]
                change = NotebookDocumentChangeEvent(;
                    cells = NotebookDocumentChangeEventCells(;
                        structure = NotebookDocumentChangeEventCellsStructure(;
                            array = NotebookCellArrayChange(; start = UInt(3), deleteCount = UInt(0), cells = new_cells),
                            didOpen = cell_texts)))
                writemsg(make_DidChangeNotebookDocumentNotification(notebook_uri, change; version = 5))
            end

            # 8. Send DidSave and wait for PublishDiagnosticsNotification with `undefhello` error
            # read=3: PublishDiagnosticsNotification is sent for all 3 code cells (markdown ignored)
            let (; raw_res) = writereadmsg(make_DidSaveNotebookDocumentNotification(notebook_uri); read = 3)
                @test all(msg -> msg isa PublishDiagnosticsNotification, raw_res)
                cell3_notification = nothing
                for msg in raw_res
                    if msg.params.uri == cell3_uri
                        cell3_notification = msg
                        break
                    end
                end
                @test cell3_notification !== nothing
                @test any(cell3_notification.params.diagnostics) do diag
                    diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
                    occursin("undefhello", diag.message)
                end
            end

            # Verify state after steps 6 and 7: 4 cells total, but only 3 code cells in concat
            let notebook_info = JETLS.get_notebook_info(server.state, notebook_uri)
                @test notebook_info !== nothing
                @test length(notebook_info.cells) == 4
                @test notebook_info.cells[1].kind == NotebookCellKind.Code
                @test notebook_info.cells[2].kind == NotebookCellKind.Code
                @test notebook_info.cells[3].kind == NotebookCellKind.Markup
                @test notebook_info.cells[4].kind == NotebookCellKind.Code
                # Markdown cell should be skipped in concatenation
                @test length(notebook_info.concat.cell_ranges) == 3
                @test notebook_info.concat.cell_ranges[1].cell_uri == cell1_uri
                @test notebook_info.concat.cell_ranges[1].line_offset == 0
                @test notebook_info.concat.cell_ranges[2].cell_uri == cell2_uri
                @test notebook_info.concat.cell_ranges[2].line_offset == 1
                @test notebook_info.concat.cell_ranges[3].cell_uri == cell3_uri
                @test notebook_info.concat.cell_ranges[3].line_offset == 2
            end
        end
    end; end # mktempdir() do tempdir; Pkg.activate(tempdir) do
end

@testset "notebook per-cell features" begin
    mktempdir() do tempdir
        notebook_uri = filepath2uri(normpath(tempdir, "test.ipynb"))

        settings = Dict{String,Any}(
            # `code_lens.references` defaults to false, enable it for this test
            "code_lens" => Dict{String,Any}(
                "references" => true,
            ),
            # Lower the block-end threshold so the small test cells emit
            # hints, and disable type inlay hints to avoid noise from
            # inferred types.
            "inlay_hint" => Dict{String,Any}(
                "block_end_min_lines" => 0,
            ),
            # Use `cat` as a test formatter (just echoes input)
            "formatter" => Dict{String,Any}(
                "custom" => Dict{String,Any}(
                    "executable" => "cat"
                )
            ),
        )

        withserver(; settings) do (; writereadmsg, id_counter)
            cell1_uri = make_cell_uri(tempdir, 1)
            cell2_uri = make_cell_uri(tempdir, 2)

            # cell 1: only `x = 1`. cell 2: defines `myfunc` (line 0) and uses
            # it (line 3) — without cell-local conversion, both would appear
            # at notebook-global lines 1 and 4.
            let cell1_text = "let x = 1\nprintln(sin(x))\nend"
                cell2_text = "function myfunc(y)\n    y + 1\nend\nresult = myfunc(42)"
                cells = NotebookCell[
                    NotebookCell(; kind = NotebookCellKind.Code, document = cell1_uri),
                    NotebookCell(; kind = NotebookCellKind.Code, document = cell2_uri),
                ]
                cell_texts = Dict{URI,String}(cell1_uri => cell1_text, cell2_uri => cell2_text)
                writereadmsg(
                    make_DidOpenNotebookDocumentNotification(notebook_uri, cells, cell_texts);
                    read=2)
            end

            # documentSymbol for cell 1 should only return cell 1's `x`
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(make_DocumentSymbolRequest(id, cell1_uri))
                @test raw_res isa DocumentSymbolResponse
                syms = raw_res.result
                @test syms isa Vector{DocumentSymbol}
                @test length(syms) == 1
                @test syms[1].name == " " # let block
                @test syms[1].selectionRange.start.line == 0
                @test length(syms[1].children) == 1 && syms[1].children[1].name == "x"
            end

            # documentSymbol for cell 2 should return cell 2's `myfunc` and
            # `result`, both with cell-local line numbers
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(make_DocumentSymbolRequest(id, cell2_uri))
                @test raw_res isa DocumentSymbolResponse
                syms = raw_res.result
                @test syms isa Vector{DocumentSymbol}
                names = [s.name for s in syms]
                @test "myfunc" in names && "result" in names
                @test !(" " in names)
                myfunc_sym = syms[findfirst(s -> s.name == "myfunc", syms)]
                @test myfunc_sym.selectionRange.start.line == 0
                result_sym = syms[findfirst(s -> s.name == "result", syms)]
                @test result_sym.selectionRange.start.line == 3
            end

            # codeLens for cell 1: no eligible symbols (just an assignment)
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(make_CodeLensRequest(id, cell1_uri))
                @test raw_res isa CodeLensResponse
                @test raw_res.result isa LSP.Null ||
                    (raw_res.result isa Vector && isempty(raw_res.result))
            end

            # codeLens for cell 2: one lens for `myfunc` at cell-local line 0
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(make_CodeLensRequest(id, cell2_uri))
                @test raw_res isa CodeLensResponse
                lenses = raw_res.result
                @test lenses isa Vector{CodeLens}
                @test length(lenses) == 1
                lens = lenses[1]
                @test lens.range.start.line == 0
                data = lens.data
                @test data isa JETLS.ReferencesCodeLensData
                @test data.uri == cell2_uri
                @test data.line == 0
            end

            # inlayHint for cell 1 — viewport spans the whole cell. The single
            # `let` block-end hint should land at cell-local line 2 and its
            # textEdit range must also be cell-local.
            let id = id_counter[] += 1
                viewport = Range(;
                    start = Position(; line = 0, character = 0),
                    var"end" = Position(; line = 3, character = 0))
                (; raw_res) = writereadmsg(make_InlayHintRequest(id, cell1_uri, viewport))
                @test raw_res isa InlayHintResponse
                hints = raw_res.result
                @test hints isa Vector{InlayHint}
                @test length(hints) == 1
                hint = hints[1]
                @test hint.position.line == 2
                @test hint.label == "let x = 1"
                textEdits = hint.textEdits
                @test textEdits isa Vector{TextEdit} && length(textEdits) == 1
                @test textEdits[1].range.start.line == 2
                @test textEdits[1].range.var"end".line == 2
            end

            # inlayHint for cell 2 — viewport spans the whole cell. The
            # `function` hint must appear at cell-local line 2 (not the
            # notebook-global line 5) and only cell 2's hint comes back
            # (`result = …` is a one-liner, no block-end hint).
            let id = id_counter[] += 1
                viewport = Range(;
                    start = Position(; line = 0, character = 0),
                    var"end" = Position(; line = 4, character = 0))
                (; raw_res) = writereadmsg(make_InlayHintRequest(id, cell2_uri, viewport))
                @test raw_res isa InlayHintResponse
                hints = raw_res.result
                @test hints isa Vector{InlayHint}
                @test length(hints) == 1
                hint = hints[1]
                @test hint.position.line == 2
                @test hint.label == "function myfunc"
                textEdits = hint.textEdits
                @test textEdits isa Vector{TextEdit} && length(textEdits) == 1
                @test textEdits[1].range.start.line == 2
                @test textEdits[1].range.var"end".line == 2
            end

            # A viewport that doesn't cover the block end should produce no
            # hints — verifies the cell-local viewport is honored, not silently
            # promoted to the whole notebook.
            let id = id_counter[] += 1
                viewport = Range(;
                    start = Position(; line = 0, character = 0),
                    var"end" = Position(; line = 1, character = 0))
                (; raw_res) = writereadmsg(make_InlayHintRequest(id, cell2_uri, viewport))
                @test raw_res isa InlayHintResponse
                @test raw_res.result isa LSP.Null ||
                    (raw_res.result isa Vector && isempty(raw_res.result))
            end

            # formatting for cell 1 — `cat` echoes input. The edit range must
            # be cell-local: cell 1 ends at line 2 (`end`, length 3).
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(make_DocumentFormattingRequest(id, cell1_uri))
                @test raw_res isa DocumentFormattingResponse
                edits = raw_res.result
                @test edits !== nothing
                @test length(edits) == 1
                edit = edits[1]
                @test edit.range.start.line == 0
                @test edit.range.start.character == 0
                @test edit.range.var"end".line == 2
                @test edit.range.var"end".character == 3
                @test edit.newText == "let x = 1\nprintln(sin(x))\nend"
            end

            # formatting for cell 2 — independent of cell 1. The edit range
            # must end at cell-local line 3 (`result = myfunc(42)`, length 19),
            # not the notebook-global line 6.
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(make_DocumentFormattingRequest(id, cell2_uri))
                @test raw_res isa DocumentFormattingResponse
                edits = raw_res.result
                @test edits !== nothing
                @test length(edits) == 1
                edit = edits[1]
                @test edit.range.start.line == 0
                @test edit.range.start.character == 0
                @test edit.range.var"end".line == 3
                @test edit.range.var"end".character == 19
                @test edit.newText == "function myfunc(y)\n    y + 1\nend\nresult = myfunc(42)"
            end
        end
    end
end

end # module test_notebook
