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

@testset "notebook end to end" begin
    old_env = Pkg.project().path
    mktempdir() do tempdir; try
        Pkg.activate(tempdir; io=devnull)
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
    finally
        Pkg.activate(old_env; io=devnull)
    end; end
end

@testset "notebook formatting" begin
    mktempdir() do tempdir
        notebook_uri = filepath2uri(normpath(tempdir, "test.ipynb"))

        # Use `cat` as a test formatter (just echoes input)
        settings = Dict{String,Any}(
            "formatter" => Dict{String,Any}(
                "custom" => Dict{String,Any}(
                    "executable" => "cat"
                )
            )
        )

        withserver(; settings) do (; server, writemsg, writereadmsg, id_counter)
            cell1_uri = make_cell_uri(tempdir, 1)
            cell2_uri = make_cell_uri(tempdir, 2)

            # Open notebook with two cells and wait for diagnostics
            # read=2: PublishDiagnosticsNotification for each cell
            let cell1_text = "x = 1"
                cell2_text = "y = 2\nz = 3"
                cells = NotebookCell[
                    NotebookCell(; kind = NotebookCellKind.Code, document = cell1_uri),
                    NotebookCell(; kind = NotebookCellKind.Code, document = cell2_uri),
                ]
                cell_texts = Dict{URI,String}(cell1_uri => cell1_text, cell2_uri => cell2_text)
                writereadmsg(make_DidOpenNotebookDocumentNotification(notebook_uri, cells, cell_texts); read=2)
            end

            # Request formatting for cell 1 only
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(make_DocumentFormattingRequest(id, cell1_uri))
                @test raw_res isa DocumentFormattingResponse
                edits = raw_res.result
                @test edits !== nothing
                @test length(edits) == 1
                edit = edits[1]
                # Verify the range is cell-local (covers just "x = 1")
                @test edit.range.start.line == 0
                @test edit.range.start.character == 0
                @test edit.range.var"end".line == 0
                @test edit.range.var"end".character == 5
                # Verify the formatted text (cat just echoes input)
                @test edit.newText == "x = 1"
            end

            # Verify cell 2 is independent - request formatting for cell 2
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(make_DocumentFormattingRequest(id, cell2_uri))
                @test raw_res isa DocumentFormattingResponse
                edits = raw_res.result
                @test edits !== nothing
                @test length(edits) == 1
                edit = edits[1]
                # Verify the range is cell-local (covers "y = 2\nz = 3")
                @test edit.range.start.line == 0
                @test edit.range.start.character == 0
                @test edit.range.var"end".line == 1
                @test edit.range.var"end".character == 5
                # Verify the formatted text (cat just echoes input)
                @test edit.newText == "y = 2\nz = 3"
            end
        end
    end
end

end # module test_notebook
