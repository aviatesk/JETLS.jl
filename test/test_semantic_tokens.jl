module test_semantic_tokens

using Test
using JETLS
using JETLS.LSP

const TYPE_PARAMETER       = JETLS.SEMANTIC_TOKEN_TYPE_PARAMETER
const TYPE_TYPE_PARAMETER  = JETLS.SEMANTIC_TOKEN_TYPE_TYPE_PARAMETER
const TYPE_VARIABLE        = JETLS.SEMANTIC_TOKEN_TYPE_VARIABLE
const TYPE_UNSPECIFIED     = JETLS.SEMANTIC_TOKEN_TYPE_UNSPECIFIED

const MOD_DECLARATION      = JETLS.SEMANTIC_TOKEN_MODIFIER_DECLARATION
const MOD_DEFINITION       = JETLS.SEMANTIC_TOKEN_MODIFIER_DEFINITION

function decode_semantic_tokens(data::Vector{UInt})
    @assert length(data) % 5 == 0
    decoded = NamedTuple{(:line,:char,:len,:type,:mod),NTuple{5,UInt}}[]
    line = char = UInt(0)
    for i in 1:5:length(data)
        delta_line  = data[i]
        delta_start = data[i+1]
        len         = data[i+2]
        ttype       = data[i+3]
        tmod        = data[i+4]
        line += delta_line
        char = delta_line == 0 ? char + delta_start : delta_start
        push!(decoded, (; line, char, len, type=ttype, mod=tmod))
    end
    return decoded
end

function tokens_for(code::AbstractString; range::Union{Nothing,Range} = nothing)
    fi = JETLS.FileInfo(1, code, @__FILE__, PositionEncodingKind.UTF16)
    decoded = decode_semantic_tokens(JETLS.semantic_tokens(fi; range))
    # LSP delta encoding requires tokens to be sorted by (line, char).
    @test issorted(decoded; by = t -> (t.line, t.char))
    # No legitimate identifier should span more than ~100 bytes. Occurrences
    # without a precise source byte range would otherwise emit a token with
    # `typemax(Int32)` length (via the `line_range` fallback in
    # `jsobj_to_range`), corrupting the LSP delta encoding downstream.
    @test all(t -> t.len < 100, decoded)
    return decoded
end

@testset "compute_semantic_tokens" begin
    @testset "function arguments and locals" begin
        code = """
        function foo(x, y)
            z = x + y
            return z
        end
        """
        tokens = tokens_for(code)
        param_defs = filter(t -> t.type == TYPE_PARAMETER && (t.mod & MOD_DEFINITION) != 0, tokens)
        @test length(param_defs) == 2
        @test any(t -> t.line == 0 && t.char == 13 && t.len == 1, param_defs) # x
        @test any(t -> t.line == 0 && t.char == 16 && t.len == 1, param_defs) # y

        param_uses = filter(t -> t.type == TYPE_PARAMETER && t.mod == 0, tokens)
        @test length(param_uses) == 2
        @test any(t -> t.line == 1 && t.char == 8 && t.len == 1, param_uses) # x
        @test any(t -> t.line == 1 && t.char == 12 && t.len == 1, param_uses) # y

        # `z = ...` carries both `:decl` (implicit local) and `:def` (assignment),
        # which are merged into a single token with both modifier bits set.
        var_defs = filter(t -> t.type == TYPE_VARIABLE && (t.mod & MOD_DEFINITION) != 0, tokens)
        @test length(var_defs) == 1
        @test var_defs[1].line == 1 && var_defs[1].char == 4 && var_defs[1].len == 1 # z

        var_uses = filter(t -> t.type == TYPE_VARIABLE && t.mod == 0, tokens)
        @test length(var_uses) == 1
        @test var_uses[1].line == 2 && var_uses[1].char == 11 && var_uses[1].len == 1 # z
    end

    @testset "type parameter" begin
        code = """
        foo(::T) where T<:Number = zero(T)
        """
        tokens = tokens_for(code)
        type_params = filter(t -> t.type == TYPE_TYPE_PARAMETER, tokens)
        # Three Ts: in `::T`, in `where T`, in `zero(T)`
        @test length(type_params) == 3
        # `T` in `::T` (use)
        @test any(t -> t.line == 0 && t.char == 6  && t.len == 1 && t.mod == 0, type_params)
        # `T` in `where T` carries both `:def` and `:decl`
        @test any(t -> t.line == 0 && t.char == 15 && t.len == 1 &&
                       t.mod == (MOD_DEFINITION | MOD_DECLARATION), type_params)
        # `T` in `zero(T)` (use)
        @test any(t -> t.line == 0 && t.char == 32 && t.len == 1 && t.mod == 0, type_params)
    end

    @testset "global use is emitted as `unspecified`" begin
        code = """
        println("hello")
        """
        tokens = tokens_for(code)
        # `println` is a `:global :use`; emitted as `unspecified` so themes
        # can keep their own coloring while still receiving any modifiers.
        @test length(tokens) == 1
        @test tokens[1].type == TYPE_UNSPECIFIED
        @test tokens[1].mod == 0
        @test tokens[1].line == 0 && tokens[1].char == 0 && tokens[1].len == 7
    end

    @testset "global decl/def is emitted with modifiers" begin
        code = """
        function foo() end
        using Base: bar
        global server::Server
        """
        tokens = tokens_for(code)
        # `foo` is a `:global` with both `:def` and `:decl` recorded at the
        # same source location; the two modifiers are merged into one token.
        foo_tok = only(filter(t -> t.line == 0 && t.char == 9, tokens))
        @test foo_tok.type == TYPE_UNSPECIFIED
        @test foo_tok.len == 3
        @test foo_tok.mod == (MOD_DEFINITION | MOD_DECLARATION)

        # `bar` is the local alias introduced by `using Base: bar`,
        # recorded as `:global :decl`.
        bar_tok = only(filter(t -> t.line == 1 && t.char == 12, tokens))
        @test bar_tok.type == TYPE_UNSPECIFIED
        @test bar_tok.len == 3
        @test bar_tok.mod == MOD_DECLARATION

        # `server` is `:global :decl` only (no assignment, so no `:def`).
        server_tok = only(filter(t -> t.line == 2 && t.char == 7, tokens))
        @test server_tok.type == TYPE_UNSPECIFIED
        @test server_tok.len == 6
        @test server_tok.mod == MOD_DECLARATION

        # `Server` is referenced as a type annotation: `:global :use`.
        Server_tok = only(filter(t -> t.line == 2 && t.char == 15, tokens))
        @test Server_tok.type == TYPE_UNSPECIFIED
        @test Server_tok.len == 6
        @test Server_tok.mod == 0
    end

    @testset "occurrences without precise byte range are dropped" begin
        # Nested macro lowering (`@lock @something ... @warn`) drags `@warn`'s
        # internal locals (`group`, `level`, `msg`, `logger`, `file`, `line`,
        # `kwargs`, ...) and synthetic global uses (`Base`, `Warn`, `nothing`,
        # `===`, `>=`, `!`, `invokelatest`, `throw`, `String`, `AssertionError`)
        # into the surrounding lowered tree, all carrying `binding_ex`s with
        # `fb == lb == 0`. Without filtering, `jsobj_to_range` would fall back
        # to `line_range`, emitting line-spanning tokens with `typemax(Int32)`
        # length and corrupting the LSP delta encoding. Verify that
        # `tokens_for` (which asserts `t.len < 100` for every token) succeeds.
        code = """
        function f(l, name)
            pkgenv = @lock l @something call(name) begin
                @warn "msg" name
                return nothing
            end
        end
        """
        tokens = tokens_for(code)
        # `f` (def), `l` (def), `name` (def), `pkgenv` (decl|def), `@lock`,
        # `l` (use), `@something`, `call`, `name` (use), `@warn`, `name` (use),
        # `nothing`. The exact set may shift slightly with JL changes; the
        # important guarantees are the `t.len < 100` invariant inside
        # `tokens_for` and that we still emit the user-visible identifiers.
        @test !isempty(tokens)
        @test any(t -> t.line == 0 && t.char == 9 && t.type == TYPE_UNSPECIFIED, tokens) # f
        @test any(t -> t.line == 0 && t.char == 11 && t.type == TYPE_PARAMETER, tokens)  # l def
        @test any(t -> t.line == 0 && t.char == 14 && t.type == TYPE_PARAMETER, tokens)  # name def
        @test any(t -> t.line == 1 && t.char == 4 && t.type == TYPE_VARIABLE, tokens)    # pkgenv
    end

    @testset "macro expansion synthetic bindings are filtered" begin
        # `@something` lowering introduces synthetic locals (`val_1`, `val_2`) and synthetic
        # global uses (`isnothing`, `something`) whose `binding_ex` spans the entire macro
        # call. They must be dropped so they don't emit bogus highlights.
        code = "f(x) = @something g(x) return nothing\n"
        tokens = tokens_for(code)
        # Exactly the 6 user-written identifiers: `f`, `x` (def), `@something`, `g`, `x` (use), `nothing`.
        @test length(tokens) == 6
        # The longest legitimate token is `@something` (10 bytes); a leaked
        # synthetic binding would emit a token spanning the whole macro call.
        @test maximum(t -> t.len, tokens) == 10
        @test any(t -> t.line == 0 && t.char == 0  && t.len == 1  && t.type == TYPE_UNSPECIFIED, tokens) # f
        @test any(t -> t.line == 0 && t.char == 2  && t.len == 1  && t.type == TYPE_PARAMETER,   tokens) # x def
        @test any(t -> t.line == 0 && t.char == 7  && t.len == 10 && t.type == TYPE_UNSPECIFIED, tokens) # @something
        @test any(t -> t.line == 0 && t.char == 18 && t.len == 1  && t.type == TYPE_UNSPECIFIED, tokens) # g
        @test any(t -> t.line == 0 && t.char == 20 && t.len == 1  && t.type == TYPE_PARAMETER,   tokens) # x use
        @test any(t -> t.line == 0 && t.char == 30 && t.len == 7  && t.type == TYPE_UNSPECIFIED, tokens) # nothing
    end

    @testset "range filtering" begin
        # Two top-level functions; restrict the range to the second one.
        code = """
        function foo(x)
            return x
        end
        function bar(y)
            return y
        end
        """
        full = tokens_for(code)
        # foo (unspecified, def), x (parameter, def), x (parameter, use),
        # bar (unspecified, def), y (parameter, def), y (parameter, use)
        @test length(full) == 6

        # Range = second function body lines only (lines 3..5)
        range = Range(;
            start = Position(; line = 3, character = 0),
            var"end" = Position(; line = 6, character = 0))
        ranged = tokens_for(code; range)
        # `bar` (unspecified, def, line 3), `y` (parameter, def, line 3),
        # `y` (parameter, use, line 4)
        @test length(ranged) == 3
        @test any(t -> t.type == TYPE_UNSPECIFIED && t.line == 3 && t.char == 9, ranged) # bar
        @test any(t -> t.type == TYPE_PARAMETER && t.line == 3 && t.char == 13, ranged) # y def
        @test any(t -> t.type == TYPE_PARAMETER && t.line == 4 && t.char == 11, ranged) # y use

        # Range that excludes everything returns empty
        empty_range = Range(;
            start = Position(; line = 100, character = 0),
            var"end" = Position(; line = 101, character = 0))
        @test isempty(tokens_for(code; range = empty_range))
    end
end

end # module test_semantic_tokens
