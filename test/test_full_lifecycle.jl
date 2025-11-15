module test_full_lifecycle

include("setup.jl")

let (pkgcode, positions) = JETLS.get_text_and_positions("""
    module TestFullLifecycle

    \"\"\"greetings\"\"\"
    function hello(x)
        "hello, \$x"
    end

    function targetfunc(x)
        │
    end

    end # module TestFullLifecycle
    """)
    @test length(positions) == 1
    pos1 = only(positions)

    withpackage("TestFullLifecycle", pkgcode) do pkgpath
        filepath = normpath(pkgpath, "src", "TestFullLifecycle.jl")
        uri = string(JETLS.URIs2.filepath2uri(filepath))

        test_full_cycle = function ((; server, writereadmsg, id_counter),)
            # open the file, and fill in the file cache
            let (; raw_res) = writereadmsg(
                    DidOpenTextDocumentNotification(;
                            params = DidOpenTextDocumentParams(;
                            textDocument = TextDocumentItem(;
                                uri,
                                languageId = "julia",
                                version = 1,
                                text = read(filepath, String)))))
                @test raw_res isa PublishDiagnosticsNotification
            end

            result = let id = id_counter[] += 1
                (; raw_res) = writereadmsg(
                    CompletionRequest(;
                        id,
                        params = CompletionParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            position = pos1)))
                @test raw_res isa CompletionResponse
                @test raw_res.id == id
                result = raw_res.result
            end
            @test result isa CompletionList
            idx = findfirst(x -> x.label == "hello", result.items)
            @test !isnothing(idx)
            if idx !== nothing
                item = result.items[idx]
                data = item.data
                @test data isa CompletionData
                @test isnothing(item.documentation)

                let id = id_counter[] += 1, raw_res, result
                    (; raw_res) = writereadmsg(
                        CompletionResolveRequest(;
                            id,
                            params =  item))
                    @test raw_res isa CompletionResolveResponse
                    @test raw_res.id == id
                    result = raw_res.result
                    @test result isa CompletionItem
                    documentation = result.documentation
                    @test documentation isa MarkupContent &&
                        documentation.kind == "markdown" &&
                        occursin("greetings", documentation.value)
                end
            end

            # Test basic cancellation handling functionality
            let id = id_counter[] += 1
                writereadmsg(
                    CancelRequestNotification(;
                        params = CancelParams(;
                            id));
                    read = 0)
                (; raw_res) = writereadmsg(
                    CompletionRequest(;
                        id,
                        params = CompletionParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            position = pos1)))
                @test raw_res isa ResponseMessage
                @test raw_res.id == id
                @test isnothing(raw_res.result)
                @test raw_res.error isa ResponseError
                @test raw_res.error.code == ErrorCodes.RequestCancelled
            end
            @test length(server.state.currently_handled) == 0

            # Test dead cancellation request handling (cancelling already completed request)
            let completed_id = id_counter[] += 1
                # First, make a normal request that completes successfully
                (; raw_res) = writereadmsg(
                    CompletionRequest(;
                        id = completed_id,
                        params = CompletionParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            position = pos1)))
                @test raw_res isa CompletionResponse
                @test raw_res.id == completed_id
                @test raw_res.result isa CompletionList

                # The request is now completed and its ID should be in handled_history
                @test completed_id in server.state.handled_history
                @test length(server.state.currently_handled) == 0

                # Now send a cancellation for the already completed request
                # This should be ignored and not create a dead entry in currently_handled
                writereadmsg(
                    CancelRequestNotification(;
                        params = CancelParams(;
                            id = completed_id));
                    read = 0)

                # Verify no dead entry was created
                @test length(server.state.currently_handled) == 0
                @test completed_id in server.state.handled_history

                # Make another request to ensure server is still functioning normally
                let new_id = id_counter[] += 1
                    (; raw_res) = writereadmsg(
                        CompletionRequest(;
                            id = new_id,
                            params = CompletionParams(;
                                textDocument = TextDocumentIdentifier(; uri),
                                position = pos1)))
                    @test raw_res isa CompletionResponse
                    @test raw_res.id == new_id
                    @test raw_res.result isa CompletionList
                end
            end
            @test length(server.state.currently_handled) == 0
        end

        rootUri = JETLS.URIs2.filepath2uri(pkgpath)

        # test clients that give workspaceFolders
        let workspaceFolders = [WorkspaceFolder(; uri=rootUri, name="TestFullLifecycle")]
            withserver(test_full_cycle; workspaceFolders)
        end

        # test clients that give rootUri
        withserver(test_full_cycle; rootUri)

        # also test cases when external script is open
        withserver(test_full_cycle)
    end
end

end # test_full_lifecycle
