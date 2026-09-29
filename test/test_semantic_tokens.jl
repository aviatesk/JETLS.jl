module test_semantic_tokens

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))

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
        # `T` in `where T` is a definition
        @test any(t -> t.line == 0 && t.char == 15 && t.len == 1 &&
                       t.mod == MOD_DEFINITION, type_params)
        # `T` in `zero(T)` (use)
        @test any(t -> t.line == 0 && t.char == 32 && t.len == 1 && t.mod == 0, type_params)
    end

    @testset "struct type parameter" begin
        # Plain `struct A{T}; ... end` doesn't introduce any `:static_parameter`;
        # we recover `T` by walking the type header.
        let code = """
            struct A{T}
                x::T
            end
            """
            tokens = tokens_for(code)
            type_params = filter(t -> t.type == TYPE_TYPE_PARAMETER, tokens)
            @test length(type_params) == 2
            @test any(t -> t.line == 0 && t.char == 9 && t.len == 1, type_params) # struct A{T}
            @test any(t -> t.line == 1 && t.char == 7 && t.len == 1 && t.mod == 0, type_params) # x::T
        end

        # Constrained type params and multiple params; `Number` must stay as a regular
        # type reference, not be lifted to `typeParameter`.
        let code = """
            struct B{T<:Number, S}
                x::T
                y::S
            end
            """
            tokens = tokens_for(code)
            type_params = filter(t -> t.type == TYPE_TYPE_PARAMETER, tokens)
            @test any(t -> t.line == 0 && t.char == 9  && t.len == 1, type_params) # T in `B{T<:...,`
            @test any(t -> t.line == 0 && t.char == 20 && t.len == 1, type_params) # S
            @test any(t -> t.line == 1 && t.char == 7  && t.len == 1, type_params) # x::T
            @test any(t -> t.line == 2 && t.char == 7  && t.len == 1, type_params) # y::S
            @test !any(t -> t.line == 0 && t.char == 12 && t.type == TYPE_TYPE_PARAMETER, tokens) # Number
        end

        # `abstract type C{T} end`
        let code = "abstract type C{T} end\n"
            tokens = tokens_for(code)
            type_params = filter(t -> t.type == TYPE_TYPE_PARAMETER, tokens)
            @test any(t -> t.line == 0 && t.char == 16 && t.len == 1, type_params)
        end

        # Parametric inner ctor: every `T` should be `typeParameter`,
        # including the ones reachable only through the `:local` alias
        # (`struct A{T}` header and `x::T`, which the inner ctor's
        # `:static_parameter` scope doesn't cover).
        let code = """
            struct A{T}
                x::T
                A{T}(x) where T = new{T}(convert(T, x))
            end
            """
            tokens = tokens_for(code)
            type_params = filter(t -> t.type == TYPE_TYPE_PARAMETER, tokens)
            @test length(type_params) == 6
            @test any(t -> t.line == 0 && t.char == 9  && t.len == 1 &&
                           t.mod == (MOD_DEFINITION | MOD_DECLARATION), type_params)             # struct A{T}
            @test any(t -> t.line == 1 && t.char == 7  && t.len == 1 && t.mod == 0, type_params) # x::T
            @test any(t -> t.line == 2 && t.char == 6  && t.len == 1 && t.mod == 0, type_params) # A{T}(x)
            @test any(t -> t.line == 2 && t.char == 18 && t.len == 1 &&
                           t.mod == MOD_DEFINITION, type_params)                                 # where T
            @test any(t -> t.line == 2 && t.char == 26 && t.len == 1 && t.mod == 0, type_params) # new{T}
            @test any(t -> t.line == 2 && t.char == 37 && t.len == 1 && t.mod == 0, type_params) # convert(T, x)
        end
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

function make_semantic_tokens_request(id::Int, uri::URI; range::Union{Nothing,Range} = nothing)
    textDocument = TextDocumentIdentifier(; uri)
    if range === nothing
        return SemanticTokensFullRequest(;
            id, params = SemanticTokensParams(; textDocument))
    end
    return SemanticTokensRangeRequest(;
        id, params = SemanticTokensRangeParams(; textDocument, range))
end

function dispatch_semantic_tokens(
        server::JETLS.Server, recorder::JETLS.ServerMessageRecorder,
        prepared::JETLS.SnapshotRequestMessage
    )
    response = dispatch_snapshot_request(server, recorder, prepared)
    response_type = prepared.msg isa SemanticTokensFullRequest ?
        SemanticTokensFullResponse : SemanticTokensRangeResponse
    @test response isa response_type
    @test response.error === nothing
    return decode_semantic_tokens((response.result::SemanticTokens).data)
end

@testset "semantic tokens snapshot ordering" begin
    captured = "let captured = 1\n    captured\nend"
    later = "let later = 2\n    later + later\nend"
    line_range = Range(;
        start = Position(; line = 1, character = 0),
        var"end" = Position(; line = 2, character = 0))

    @testset "$(range === nothing ? "full" : "range")" for range in (nothing, line_range)
        expected_captured = tokens_for(captured; range)
        expected_later = tokens_for(later; range)
        @test !isempty(expected_captured)
        @test expected_captured != expected_later

        @testset "prior and later didChange" begin
            with_manual_dispatch_server() do server, recorder
                uri = filepath2uri(@__FILE__)
                JETLS.cache_file_info!(server, uri, 1, "let initial = 0\n    initial\nend")
                request = make_semantic_tokens_request(1, uri; range)
                @test JETLS.is_snapshot_msg(request)
                prepared = queued_snapshot_requests(server, [
                    make_DidChangeTextDocumentNotification(uri, captured, 2), request,
                    make_DidChangeTextDocumentNotification(uri, later, 3),
                    make_semantic_tokens_request(2, uri; range)])
                @test length(prepared) == 2
                @test prepared[1].snapshot.fi.version == 2
                @test prepared[2].snapshot.fi.version == 3
                @test JETLS.get_file_info(server.state, uri) === prepared[2].snapshot.fi
                @test dispatch_semantic_tokens(server, recorder, prepared[1]) == expected_captured
                @test dispatch_semantic_tokens(server, recorder, prepared[2]) == expected_later
            end
        end

        @testset "missing capture is not retried" begin
            with_manual_dispatch_server() do server, recorder
                uri = filepath2uri(@__FILE__)
                prepared = only(queued_snapshot_requests(server, [
                    make_semantic_tokens_request(1, uri; range)]))
                @test prepared.snapshot === nothing
                JETLS.cache_file_info!(server, uri, 1, captured)
                response = dispatch_snapshot_request(server, recorder, prepared)
                @test response.error === nothing
                @test response.result === null
                current = only(queued_snapshot_requests(server, [
                    make_semantic_tokens_request(2, uri; range)]))
                @test dispatch_semantic_tokens(server, recorder, current) == expected_captured
            end
        end

        @testset "close and reopen at the same version" begin
            with_manual_dispatch_server() do server, recorder
                uri = filepath2uri(@__FILE__)
                JETLS.cache_file_info!(server, uri, 1, captured)
                prepared = only(queued_snapshot_requests(server, [
                    make_semantic_tokens_request(1, uri; range),
                    make_DidCloseTextDocumentNotification(uri)]))
                @test JETLS.get_file_info(server.state, uri) === nothing
                while isready(recorder.sent_queue)
                    @test take!(recorder.sent_queue) isa PublishDiagnosticsNotification
                end
                current = only(queued_snapshot_requests(server, [
                    make_DidOpenTextDocumentNotification(uri, later; version = 1),
                    make_semantic_tokens_request(2, uri; range)]))
                @test current.snapshot.fi.version == prepared.snapshot.fi.version == 1
                @test current.snapshot.fi.identity != prepared.snapshot.fi.identity
                # Populate the shared occurrence cache with the reopened document first.
                @test dispatch_semantic_tokens(server, recorder, current) == expected_later
                @test dispatch_semantic_tokens(server, recorder, prepared) == expected_captured
            end
        end

        @testset "cancellation before prepared dispatch" begin
            with_manual_dispatch_server() do server, recorder
                uri = filepath2uri(@__FILE__)
                JETLS.cache_file_info!(server, uri, 1, captured)
                request = make_semantic_tokens_request(1, uri; range)
                prepared = only(queued_snapshot_requests(server, [request]))
                JETLS.handler_concurrent_message(server, CancelRequestNotification(;
                    params = CancelParams(; id = request.id)))
                response = dispatch_snapshot_request(server, recorder, prepared)
                @test response.result === nothing
                @test response.error isa ResponseError
                @test response.error.code == ErrorCodes.RequestCancelled
            end
        end
    end
end

module M_snapshot
    global x = 1
end

@testset "notebook semantic tokens snapshot ordering" begin
    @testset "$change_kind" for change_kind in (
            :preceding_lines, :remove_preceding, :remove_requested, :close)
        with_manual_dispatch_server() do server, recorder
            state = server.state
            notebook_uri = URI("file:///semantic-tokens-snapshot.ipynb")
            cell1 = URI("vscode-notebook-cell:/semantic-tokens-snapshot.ipynb#1")
            cell2 = URI("vscode-notebook-cell:/semantic-tokens-snapshot.ipynb#2")
            text = "while true\n    x = 2\n    println(x)\nend\nx"
            cells = [
                JETLS.NotebookCellInfo(cell1, NotebookCellKind.Code, 1, "prefix = 1\nprefix"),
                JETLS.NotebookCellInfo(cell2, NotebookCellKind.Code, 1, text)]
            concat = JETLS.concatenate_cells(cells)
            notebook = JETLS.NotebookInfo(1, "jupyter-notebook", state.encoding, cells, concat)
            JETLS.store!(state.notebook_cache) do cache
                Base.PersistentDict(cache, notebook_uri => notebook), nothing
            end
            JETLS.store!(state.cell_to_notebook) do cache
                for cell in cells
                    cache = Base.PersistentDict(cache, cell.uri => notebook_uri)
                end
                cache, nothing
            end
            fi = JETLS.cache_notebook_file_info!(server, notebook_uri, notebook)
            notification = if change_kind === :close
                DidCloseNotebookDocumentNotification(;
                    params = DidCloseNotebookDocumentParams(;
                        notebookDocument = NotebookDocumentIdentifier(; uri = notebook_uri),
                        cellTextDocuments = [TextDocumentIdentifier(; uri = cell.uri) for cell in cells]))
            else
                change = if change_kind === :preceding_lines
                    NotebookDocumentChangeEventCells(;
                        textContent = [NotebookDocumentChangeEventCellsTextContentItem(;
                            document = VersionedTextDocumentIdentifier(; uri = cell1, version = 2),
                            changes = [TextDocumentContentChangeEvent(; text = "prefix = 1")])])
                else
                    removed_uri = change_kind === :remove_preceding ? cell1 : cell2
                    NotebookDocumentChangeEventCells(;
                        structure = NotebookDocumentChangeEventCellsStructure(;
                            array = NotebookCellArrayChange(;
                                start = UInt(change_kind === :remove_preceding ? 0 : 1),
                                deleteCount = UInt(1)),
                            didClose = [TextDocumentIdentifier(; uri = removed_uri)]))
                end
                DidChangeNotebookDocumentNotification(;
                    params = DidChangeNotebookDocumentParams(;
                        notebookDocument = VersionedNotebookDocumentIdentifier(;
                            uri = notebook_uri, version = 2),
                        change = NotebookDocumentChangeEvent(; cells = change)))
            end
            line_range = Range(;
                start = Position(; line = 2, character = 0),
                var"end" = Position(; line = 3, character = 0))
            partial_range = Range(;
                start = Position(; line = 2, character = 12),
                var"end" = Position(; line = 2, character = 13))
            prepared = queued_snapshot_requests(server, [
                make_semantic_tokens_request(1, cell2),
                make_semantic_tokens_request(2, cell2; range = line_range),
                make_semantic_tokens_request(3, cell2; range = partial_range),
                notification])
            @test length(prepared) == 3
            @test prepared[1].snapshot.fi === fi
            @test prepared[1].snapshot.cache_uri == notebook_uri
            @test prepared[1].snapshot.notebook === concat
            if change_kind in (:remove_requested, :close)
                @test !JETLS.is_notebook_cell_uri(state, cell2)
            end
            while isready(recorder.sent_queue)
                @test take!(recorder.sent_queue) isa PublishDiagnosticsNotification
            end

            # Only the canonical URI supplies the existing global needed by soft scope.
            JETLS.cache_out_of_scope!(state.analysis_manager, notebook_uri, JETLS.OutOfScope(M_snapshot))
            full = dispatch_semantic_tokens(server, recorder, prepared[1])
            @test [(t.line, t.char, t.len, t.type) for t in full] == [
                (1, 4, 1, TYPE_UNSPECIFIED),
                (2, 4, 7, TYPE_UNSPECIFIED),
                (2, 12, 1, TYPE_UNSPECIFIED),
                (4, 0, 1, TYPE_UNSPECIFIED)]
            @test (full[1].mod & MOD_DEFINITION) != 0
            @test all(t -> t.mod == 0, full[2:4])
            @test dispatch_semantic_tokens(server, recorder, prepared[2]) == full[2:3]
            @test dispatch_semantic_tokens(server, recorder, prepared[3]) == full[3:3]
        end
    end
end

end # module test_semantic_tokens
