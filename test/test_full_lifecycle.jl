module test_full_lifecycle

include("setup.jl")

using Pkg
function with_package(test_func, pkgname::AbstractString,
                      pkgcode::AbstractString;
                      pkg_setup=function ()
                          Pkg.precompile(; io=devnull)
                      end,
                      env_setup=function () end)
    old = Pkg.project().path
    mktempdir() do tempdir
        try
            pkgpath = normpath(tempdir, pkgname)
            Pkg.generate(pkgpath; io=devnull)
            Pkg.activate(pkgpath; io=devnull)
            pkgfile = normpath(pkgpath, "src", "$pkgname.jl")
            write(pkgfile, string(pkgcode))
            pkg_setup()

            Pkg.activate(; temp=true, io=devnull)
            env_setup()

            test_func(pkgpath)
        finally
            Pkg.activate(old; io=devnull)
        end
    end
end

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

    with_package("TestFullLifecycle", pkgcode) do pkgpath
        rootPath = pkgpath
        filepath = normpath(rootPath, "src", "TestFullLifecycle.jl")
        uri = string(JETLS.URIs2.filepath2uri(filepath))
        withserver(; rootPath) do in, _, _, sent_queue, id_counter
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
    end
end

end # test_full_lifecycle
