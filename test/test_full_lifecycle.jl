module test_full_lifecycle

include("setup.jl")
let rootPath = normpath(FIXTURES_DIR, "TestFullLifecycle")

    withserver(; rootPath) do in, out, in_queue, out_queue, id_counter
        filepath = normpath(rootPath, "src", "TestFullLifecycle.jl")
        uri = string(JETLS.URIs2.filepath2uri(filepath))

        # open the file, and fill in the file cache
        writemsg(in,
            DidOpenTextDocumentNotification(;
                params = DidOpenTextDocumentParams(;
                    textDocument = TextDocumentItem(;
                        uri,
                        languageId = "julia",
                        version = 1,
                        text = read(filepath, String)))))
        out = take_with_timeout!(out_queue; limit=300) # wait for 5 minutes
        @test out isa PublishDiagnosticsNotification

        id = id_counter[] += 1
        writemsg(in,
            CompletionRequest(;
                id,
                params =  CompletionParams(;
                    textDocument = TextDocumentIdentifier(; uri),
                    position = Position(; line = 7, character = 4))))
        out = take_with_timeout!(out_queue)
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
                out = take_with_timeout!(out_queue)
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
end

end # test_full_lifecycle
