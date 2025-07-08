module test_ast

using Test
using JETLS
using JETLS: JL, JS

include(normpath(pkgdir(JETLS), "test", "jsjl_utils.jl"))

function test_string_positions(s)
    v = Vector{UInt8}(s)
    for b in eachindex(s)
        pos = JETLS.offset_to_xy(v, b)
        b2 =  JETLS.xy_to_offset(v, pos)
        @test b === b2
    end
    # One past the last byte is a valid position in an editor
    b = length(v) + 1
    pos = JETLS.offset_to_xy(v, b)
    b2 =  JETLS.xy_to_offset(v, pos)
    @test b === b2
end

@testset "Cursor file position <-> byte" begin
    fake_files = [
        "",
        "1",
        "\n\n\n",
        """
        aaa
        b
        ccc
        Αα,Ββ,Γγ,Δδ,Εε,Ζζ,Ηη,Θθ,Ιι,Κκ,Λλ,Μμ,Νν,Ξξ,Οο,Ππ,Ρρ,Σσς,Ττ,Υυ,Φφ,Χχ,Ψψ,Ωω
        """
    ]
    for i in eachindex(fake_files)
        @testset "fake_files[$i]" begin
            test_string_positions(fake_files[i])
        end
    end
end

@testset "Guard against invalid positions" begin
    let code = """
        sin
        @nospecialize
        cos(
        """ |> Vector{UInt8}
        ok = true
        for i = 0:10, j = 0:10
            ok &= JETLS.xy_to_offset(code, JETLS.Position(i, j)) isa Int
        end
        @test ok
    end
end

@testset "noparen_macrocall" begin
    @test JETLS.noparen_macrocall(jlparse("@test true"; rule=:statement))
    @test JETLS.noparen_macrocall(jlparse("@interface AAA begin end"; rule=:statement))
    @test !JETLS.noparen_macrocall(jlparse("@test(true)"; rule=:statement))
    @test !JETLS.noparen_macrocall(jlparse("r\"xxx\""; rule=:statement))
end

get_target_node(::Type{JL.SyntaxTree}, code::AbstractString, pos::Int) = JETLS.select_target_node(jlparse(code), pos)
get_target_node(::Type{JS.SyntaxNode}, code::AbstractString, pos::Int) = JETLS.select_target_node(jsparse(code), pos)
function get_target_node(::Type{T}, code::AbstractString, matcher::Regex=r"│") where T
    clean_code, positions = JETLS.get_text_and_positions(code, matcher)
    @assert length(positions) == 1
    return get_target_node(T, clean_code, JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[1]))
end

@testset "`select_target_node` / `get_source_range`" begin
    @testset "with $T" for T in (JL.SyntaxTree, JS.SyntaxNode)
        let code = """
            test_│func(5)
            """
            node = get_target_node(T, code)
            @test (node !== nothing) && (JS.kind(node) === JS.K"Identifier")
            @test JS.sourcetext(node) == "test_func"
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("test_func")
            end
        end

        let code = """
            obj.│property = 42
            """
            node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"."
            @test length(JS.children(node)) == 2
            @test JS.sourcetext(JS.children(node)[1]) == "obj"
            @test JS.sourcetext(JS.children(node)[2]) == "property"
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("obj.property")
            end
        end

        let code = """
            Core.Compiler.tme│et(x)
            """
            node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"."
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Core.Compiler.tmeet")
            end
        end

        let code = """
            Core.Compi│ler.tmeet(x)
            """
            node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"."
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Core.Compiler")
            end
        end

        let code = """
            Cor│e.Compiler.tmeet(x)
            """
            node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"Identifier"
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Core")
            end
        end

        let code = """
            @inline│ callsin(x) = sin(x)
            """
            node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"MacroName"
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0 # include at mark
                @test range.var"end".line == 0 && range.var"end".character == sizeof("@inline")
            end
        end

        let code = """
            Base.@inline│ callsin(x) = sin(x)
            """
            node = get_target_node(T, code)
            @test node !== nothing
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Base.@inline")
            end
        end

        let code = """
            text│"sin"
            """
            node = get_target_node(T, code)
            @test node !== nothing
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("text")
            end
        end

        let code = """
            function test_func(x)
                return x │ + 1
            end
            """
            node = get_target_node(T, code)
            @test node === nothing
        end

        let code = """
            │
            """
            node = get_target_node(T, code)
            @test node === nothing
        end
    end
end

get_dotprefix_node(code::AbstractString, pos::Int) = JETLS.select_dotprefix_node(jlparse(code), pos)
function get_dotprefix_node(code::AbstractString, matcher::Regex=r"│")
    clean_code, positions = JETLS.get_text_and_positions(code, matcher)
    @assert length(positions) == 1
    return get_dotprefix_node(clean_code, JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[1]))
end
@testset "`select_dotprefix_node`" begin
    @test isnothing(get_dotprefix_node("isnothing│"))
    let node = get_dotprefix_node("Base.Sys.│")
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base.Sys"
    end
    let node = get_dotprefix_node("Base.Sys.CPU│")
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base.Sys"
    end
    let node = get_dotprefix_node("Base.Sy│s")
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base"
    end
    let node = get_dotprefix_node("""
        function foo(x)
            Core.│
        end
        """)
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Core"
    end
    let node = get_dotprefix_node("""
        function foo(x = Base.│)
        end
        """)
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base"
    end
end

end # module test_ast
