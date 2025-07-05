module test_hover

using Test
using JETLS
using JETLS.LSP

include("setup.jl")

@testset "'Hover' request/responce (pkg)" begin
    pkg_code = """
    module HoverTest

    \"\"\"
        documented_binding

    Documented binding.
    \"\"\"
    global documented_binding = 42

    global undocumented_binding = 42

    \"\"\"
        func(x::Int) -> Int

    Documented method.
    \"\"\"
    func(x::Int) = x

    module M_Doc
    \"\"\"
        func(x::Int) -> Int

    Documented method.
    \"\"\"
    func(x::Int) = x
    end # M_Doc

    documented_binding│
    undocumented_binding│
    func│(42)
    M_Doc.func│(42)

    using Base: Base as B
    B│.sin(42)

    nothing│

    end # module HoverTest
    """

    testers = [
        # documented_binding│
        (; pat="Documented binding.")

        # udocumented_binding│
        (; pat="No documentation found")

        # func│(42)
        (; pat="Documented method.")

        # M_doc.func│(42)
        (; pat="Documented method.")

        # B│.sin(42)
        (; pat=JETLS.lsrender(@doc Base))

        # nothing│
        (; pat=JETLS.lsrender(@doc nothing))
    ]

    clean_code, positions = JETLS.get_text_and_positions(pkg_code)
    @assert length(positions) == length(testers)

    withpackage("HoverTest", clean_code) do pkg_path
        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "HoverTest.jl")
        uri = filepath2uri(src_path)
        withserver() do (; writereadmsg, id_counter)
            # run the full analysis first
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(src_path, String)))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            for (i, (position, tester)) in enumerate(zip(positions, testers))
                @testset let id = id_counter[] += 1,
                             i = i
                    (; raw_res) = writereadmsg(HoverRequest(;
                        id,
                        params = HoverParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            position)))
                    result = raw_res.result
                    brokens = get(tester, :brokens, ())
                    if haskey(tester, :pat)
                        pat = tester[:pat]
                        @test result !== null broken=1∈brokens
                        @test let contents = result.contents
                            contents isa MarkupContent &&
                            contents.kind === MarkupKind.Markdown &&
                            occursin(pat, result.contents.value)
                        end broken=2∈brokens
                    else
                        @test result === null broken=1∈brokens
                    end
                end
            end
        end
    end
end

@testset "'Hover' request/responce (script)" begin
    script_code = """
    \"\"\"
        documented_binding

    Documented binding.
    \"\"\"
    global documented_binding = 42

    global undocumented_binding = 42

    \"\"\"
        func(x::Int) -> Int

    Documented method.
    \"\"\"
    func(x::Int) = x

    module M_Doc
    \"\"\"
        func(x::Int) -> Int

    Documented method.
    \"\"\"
    func(x::Int) = x
    end # M_Doc

    documented_binding│
    undocumented_binding│
    unexisting_binding│
    func│(42)
    M_Doc.func│(42)
    sinx = @inline│ sin(42)
    sinx = Base.@inline│ sin(42)
    rx = r│"foo"

    let xs = collect(1:10)
        Any[Core.Const(x│)
            for x in xs]
    end
    """

    testers = [
        # documented_binding│
        (; pat="Documented binding.")

        # udocumented_binding│
        (; pat="No documentation found")

        # unexisting_binding│
        (; pat="No documentation found")

        # func│(42)
        (; pat="Documented method.")

        # M_doc.func│(42)
        (; pat="Documented method.")

        # sinx = @inline│ sin(42)
        (; pat=JETLS.lsrender(@doc @inline))

        # sinx = Base.@inline│ sin(42)
        (; pat=JETLS.lsrender(@doc @inline))

        # rx = r│"foo"
        (; pat=JETLS.lsrender(@doc r""))

        # Any[Core.Const(x│)
        (; pat="for x in xs") # local source location
    ]

    clean_code, positions = JETLS.get_text_and_positions(script_code)
    @assert length(positions) == length(testers)

    withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # run the full analysis first
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(script_path, String)))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            for (i, (position, tester)) in enumerate(zip(positions, testers))
                @testset let id = id_counter[] += 1,
                             i = i
                    (; raw_res) = writereadmsg(HoverRequest(;
                        id,
                        params = HoverParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            position)))
                    result = raw_res.result
                    brokens = get(tester, :brokens, ())
                    if haskey(tester, :pat)
                        pat = tester[:pat]
                        @test result !== null broken=1∈brokens
                        @test let contents = result.contents
                            contents isa MarkupContent &&
                            contents.kind === MarkupKind.Markdown &&
                            occursin(pat, result.contents.value)
                        end broken=2∈brokens
                    else
                        @test result === null broken=1∈brokens
                    end
                end
            end
        end
    end
end

end # module test_hover
