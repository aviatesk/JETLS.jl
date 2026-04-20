module test_full_lifecycle

include("setup.jl")

@testset "full completion cycle" begin

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
        uri = LSP.URIs2.filepath2uri(filepath)

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
                raw_res.result
            end
            @test result isa CompletionList
            idx = findfirst(x -> x.label == "hello", result.items)
            @test !isnothing(idx)
            if idx !== nothing
                item = result.items[idx]
                data = item.data
                @test data isa GlobalCompletionData
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

        rootUri = LSP.URIs2.filepath2uri(pkgpath)

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

end # @testset "full completion cycle" begin

# Regression test: `textDocument/references` previously returned stale
# results after script-mode reanalysis because the cached occurrences kept
# `binfo.mod` from the previous virtual module while the new target binding
# resolved in the freshly gensym'd virtual module of the new analysis run.
@testset "occurrence cache invalidation across script-mode reanalysis" begin
    script_code = """
    func│(x) = sin(x)

    function main(args::Vector{String})::Cint
        println(func(@something tryparse(Int, first(args)) return 1))
        return 0
    end
    """
    clean_code, positions = JETLS.get_text_and_positions(script_code)
    @test length(positions) == 1
    refpos = only(positions)

    withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # Open the file; the response publishes diagnostics only once the
            # initial full analysis completes.
            let (; raw_res) = writereadmsg(
                    make_DidOpenTextDocumentNotification(uri, clean_code))
                @test raw_res isa PublishDiagnosticsNotification
                @test raw_res.params.uri == uri
            end

            refparams = ReferenceParams(;
                textDocument = TextDocumentIdentifier(; uri),
                position = refpos,
                context = ReferenceContext(; includeDeclaration = true))

            # First request populates `binding_occurrences_cache` with
            # entries keyed against the first analysis run's virtual module.
            refs_first = let id = id_counter[] += 1
                (; raw_res) = writereadmsg(
                    ReferencesRequest(; id, params = refparams))
                @test raw_res isa ReferencesResponse && raw_res.id == id
                raw_res.result
            end
            @test refs_first isa Vector{Location}
            @test length(refs_first) == 2

            # Trigger reanalysis: script mode mints a new gensym'd virtual
            # module, so the cached occurrences become stale unless
            # `update_analysis_cache!` invalidates them.
            let (; raw_res) = writereadmsg(
                    DidSaveTextDocumentNotification(;
                        params = DidSaveTextDocumentParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            text = clean_code)))
                @test raw_res isa PublishDiagnosticsNotification
                @test raw_res.params.uri == uri
            end

            # Without the invalidation, the stale cache would fail to match
            # the target binding's new virtual module and references would
            # drop to 0 or 1 here.
            refs_second = let id = id_counter[] += 1
                (; raw_res) = writereadmsg(
                    ReferencesRequest(; id, params = refparams))
                @test raw_res isa ReferencesResponse && raw_res.id == id
                raw_res.result
            end
            @test refs_second isa Vector{Location}
            @test length(refs_second) == 2

            # Reanalyze once more to exercise the virtual-module -> virtual-module
            # transition: the previous reanalysis populated the cache with
            # entries keyed against its virtual module, and this run produces yet
            # another gensym'd virtual module.
            let (; raw_res) = writereadmsg(
                    DidSaveTextDocumentNotification(;
                        params = DidSaveTextDocumentParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            text = clean_code)))
                @test raw_res isa PublishDiagnosticsNotification
                @test raw_res.params.uri == uri
            end

            refs_third = let id = id_counter[] += 1
                (; raw_res) = writereadmsg(
                    ReferencesRequest(; id, params = refparams))
                @test raw_res isa ReferencesResponse && raw_res.id == id
                raw_res.result
            end
            @test refs_third isa Vector{Location}
            @test length(refs_third) == 2
        end
    end
end

end # test_full_lifecycle
