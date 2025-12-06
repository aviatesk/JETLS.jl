module test_resolver

using JETLS: JET, JETLS, JS, JL
using JETLS.URIs2

function analyze_and_resolve(s::AbstractString; kwargs...)
    text, positions = JETLS.get_text_and_positions(s; kwargs...)
    length(positions) == 1 || error("Multiple positions are found")
    position = only(positions)
    server = JETLS.Server()
    state = server.state
    mktemp() do filename, _
        uri = filename2uri(filename)
        fileinfo = JETLS.cache_file_info!(server, uri, 1, text)
        JETLS.cache_saved_file_info!(state, uri, text)
        JETLS.start_analysis_workers!(server)
        JETLS.request_analysis!(server, uri, #=onsave=#false; wait=true, notify_diagnostics=false)

        (; mod, analyzer) = JETLS.get_context_info(state, uri, position)

        st_top = JS.build_tree(JL.SyntaxTree, fileinfo.parsed_stream; filename)
        byte = JETLS.xy_to_offset(fileinfo, position)

        # TODO use a proper utility to find "resolvable" node
        # `byte-1` here for allowing `sin│()` to be resolved
        nodes = JETLS.byte_ancestors(st_top, byte-1)
        i = @something findlast(n -> JS.kind(n) in JS.KSet"Identifier .", nodes) error("No resolvable node found")
        node = nodes[i]

        JETLS.resolve_type(analyzer, mod, node)
    end
end

using Test
using Core: Const

# test basic analysis abilities of `resolve_type`
@testset "resolve_type" begin
    @test analyze_and_resolve("sin│") === Const(sin)
    @test analyze_and_resolve("sin│(42)") === Const(sin)
    @test analyze_and_resolve("""
    function myfunc(x)
        return sin(x)
    end
    myfunc│
    """) isa Const
    @test analyze_and_resolve("""
    function myfunc(x)
        return sin│(x)
    end
    """) === Const(sin)
    @test analyze_and_resolve("""
    const myfunc = sin
    myfunc│
    """) === Const(sin)
    @test analyze_and_resolve("""
    const myfunc = sin
    myfunc│(42)
    """) === Const(sin)
    @test analyze_and_resolve("""
    module MyModule
    const myfunc = sin
    end # module MyModule
    MyModule.myfunc│
    """) === Const(sin)
    @test analyze_and_resolve("""
    module MyModule
    const myfunc = sin
    end # module MyModule
    (println("Hello, world"); MyModule).myfunc│
    """) === Const(sin)
end

end # module test_resolver
