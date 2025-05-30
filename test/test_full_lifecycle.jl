module test_full_lifecycle

include("setup.jl")

let (pkgcode, positions) = get_text_and_positions("""
    module TestFullLifecycle

    \"\"\"greetings\"\"\"
    function hello(x)
        "hello, \$x"
    end

    function targetfunc(x)
        #=cursor=#
    end

    end # module TestFullLifecycle
    """)
    @test length(positions) == 1
    pos1 = only(positions)

    withpackage("TestFullLifecycle", pkgcode) do pkgpath
        filepath = normpath(pkgpath, "src", "TestFullLifecycle.jl")
        uri = string(JETLS.URIs2.filepath2uri(filepath))

        test_full_cycle = function (in, _, _, sent_queue, id_counter)
            # open the file, and fill in the file cache
            writemsg(in,
                DidOpenTextDocumentNotification(;
                    params = DidOpenTextDocumentParams(;
                        textDocument = TextDocumentItem(;
                            uri,
                            languageId = "julia",
                            version = 1,
                            text = read(filepath, String)))))
            out = take_with_timeout!(sent_queue; limit=300) # wait for 5 minutes
            @test out isa PublishDiagnosticsNotification

            id = id_counter[] += 1
            writemsg(in,
                CompletionRequest(;
                    id,
                    params = CompletionParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        position = pos1)))
            out = take_with_timeout!(sent_queue)
            @test out isa ResponseMessage
            @test out.id == id
            result = out.result
            @test result isa CompletionList
            idx = findfirst(x -> x.label == "hello", result.items)
            @test !isnothing(idx)
            if idx !== nothing
                item = result.items[idx]
                data = item.data
                @test data isa CompletionData && data.needs_resolve
                @test isnothing(item.documentation)

                let id = id_counter[] += 1, out, result
                    writemsg(in,
                        CompletionResolveRequest(;
                            id,
                            params =  item))
                    out = take_with_timeout!(sent_queue)
                    @test out isa ResponseMessage
                    @test out.id == id
                    result = out.result
                    @test result isa CompletionItem
                    documentation = result.documentation
                    @test documentation isa MarkupContent &&
                        documentation.kind == "markdown" &&
                        occursin("greetings", documentation.value)
                end
            end
        end

        rootUri = string(JETLS.URIs2.filepath2uri(pkgpath))

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
