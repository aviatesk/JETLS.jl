module test_signature_help

using Test
using JETLS
using JETLS: JL, JS
using JETLS.URIs2

# siginfos(context_module, code) -> siginfos
# nsigs(context_module, code) -> n

function siginfos(
        context_module::Module, code::AbstractString;
        no_active_parameter_support::Bool=false,
        kwargs...
    )
    clean_code, positions = JETLS.get_text_and_positions(code; kwargs...)
    @assert length(positions) == 1 "siginfos requires exactly one cursor marker"
    position = only(positions)
    fi = JETLS.FileInfo(0, clean_code, @__FILE__)
    b = JETLS.xy_to_offset(fi, position)
    return JETLS.cursor_siginfos(fi, b, context_module; no_active_parameter_support)
end

n_si(args...) = length(siginfos(args...))

module M_sanity
i_exist(a,b,c) = 0
struct StrctExist1; s; end # just 1 construct (w/o the conversion method)
struct StrctExist2; s::String; end # just 1 construct (w/o the conversion method)
struct StrctExist3
    s
    StrctExist3(@nospecialize s) = new(s)
end
end
@testset "sanity" begin
    @test 1 == n_si(M_sanity, "i_exist(│)")
    @test 1 == n_si(M_sanity, "i_exist(1,2,3│)")
    @test 1 == n_si(M_sanity, "i_exist(│1,2,3)")
    @test 0 == n_si(M_sanity, "i_do_not_exist(│)")
    @test 0 == n_si(M_sanity, "│")
    @test 0 == n_si(M_sanity, "(│)")
    @test 0 == n_si(M_sanity, "()│")
    @test 1 == n_si(M_sanity, "StrctExist1(│)")
    @test 0 == n_si(M_sanity, "StrctExist1(1,2│)")
    @test 2 == n_si(M_sanity, "StrctExist2(│)")
    @test 0 == n_si(M_sanity, "StrctExist2(1,2│)")
    @test 1 == n_si(M_sanity, "StrctExist3(│)")
    @test 0 == n_si(M_sanity, "StrctExist3(1,2│)")
end

module M_macros
macro m(x, y=1); x; end
macro v(x...); x; end
end
@testset "simple macros" begin
    @test 2 == n_si(M_macros, "@m(│)")
    @test 2 == n_si(M_macros, "@m│")
    @test 2 == n_si(M_macros, "@m │")
    @test 2 == n_si(M_macros, "begin\n    @m │\nend")
    @test 0 == n_si(M_macros, "begin\n    @m 1\n│end")
    @test 0 == n_si(M_macros, "begin\n    @m 1\n│\nend")
    @test 2 == n_si(M_macros, "@m(1,│)")
    @test 2 == n_si(M_macros, "@m 1│")
    @test 1 == n_si(M_macros, "@m(1,2,│)")
    @test 1 == n_si(M_macros, "@m 1 2│")
    @test 0 == n_si(M_macros, "@m(1,2,3,│)")
    @test 0 == n_si(M_macros, "@m 1 2 3│")
    @test 1 == n_si(M_macros, "@v│")
    @test 1 == n_si(M_macros, "@v 1 2 3 4│")
end

module M_dotcall
f(x) = 0
end
@testset "dotcall" begin
    @test 1 == n_si(M_dotcall, "f.(│)")
    @test 1 == n_si(M_dotcall, "f.(x│)")
end

module M_edgecases
kwname(var"end") = var"end"
end
@testset "Edge cases" begin
    @test 1 == n_si(M_edgecases, "kwname(│)")
    let si = only(siginfos(M_edgecases, "kwname(│)"))
        @test si.label == "kwname(var\"end\")"
    end
end

module M_noshow_def
f(x) = x
g(x) = x
macro m(x); x; end
end
@testset "don't show help in method definitions" begin
    snippets = [
        "function f(│); end",
        "function f(│) where T; end",
        "function f(│) where T where T; end",
        "f(│) = 1",
        "f(│) where T = 1",
        "│f(x) = g(x)",
        "f(x│) = g(x)",
        "f(x)│ = g(x)",
        "f(x::T│) where T = g(x)",
    ]
    for s in snippets
        @test 0 == n_si(M_noshow_def, s)
    end
    @test 1 == n_si(M_noshow_def, "f(x) = g(│)")
    @test 1 == n_si(M_noshow_def, "f(x) = g(x │)")
    @test 1 == n_si(M_noshow_def, "f(x) where T where U = g(x│)")
    @test 1 == n_si(M_noshow_def, "f(x) where T where U = @m(x│)")
end

module M_filterp
f4() = 0
f4(a) = 0
f4(a,b) = 0
f4(a,b,c) = 0
f4(a,b,c,d) = 0

f1v() = 0
f1v(a) = 0
f1v(a, args...) = 0
end
@testset "filter by number of positional args" begin
    @test 5 == n_si(M_filterp, "f4(│)")
    @test 4 == n_si(M_filterp, "f4(1│)")
    @test 4 == n_si(M_filterp, "f4(1,│)")
    @test 4 == n_si(M_filterp, "f4(1, │)")
    @test 3 == n_si(M_filterp, "f4(1,2│)")
    @test 2 == n_si(M_filterp, "f4(1,2,3│)")
    @test 1 == n_si(M_filterp, "f4(1,2,3,4,│)")

    @test 1 == n_si(M_filterp, "f4(│1,2,3,4,)")
    @test 1 == n_si(M_filterp, "f4(1,2,3,4; │)")

    # splat should be assumed empty for filtering purposes
    @test 1 == n_si(M_filterp, "f4(1,2,3,4,x...│)")
    @test 1 == n_si(M_filterp, "f4(x...,1,2,3,4,│)")

    @test 3 == n_si(M_filterp, "f1v(│)")
    @test 2 == n_si(M_filterp, "f1v(1,│)")
    @test 1 == n_si(M_filterp, "f1v(1,2│)")
    @test 1 == n_si(M_filterp, "f1v(1,2,3│)")
    @test 1 == n_si(M_filterp, "f1v(1,2,3,foo...│)")
end

module M_filterk
f(;kw1, kw2=2, kw3::Int=3) = 0
f(x; kw2, kw3, kw4, kw5, kw6) = 0
end
@testset "filter by names of kwargs" begin
    @test 2 == n_si(M_filterk, "f(│)")

    # pre-semicolon
    @test 0 == n_si(M_filterk, "f(1, kw1│)") # positional until we type "="
    @test 1 == n_si(M_filterk, "f(kw1=1│)")

    # post-semicolon
    @test 1 == n_si(M_filterk, "f(│;kw1)")
    @test 1 == n_si(M_filterk, "f(;kw1,│)")
    @test 1 == n_si(M_filterk, "f(;kw1=│)")
    @test 1 == n_si(M_filterk, "f(;kw1=1│)")

    # mix
    @test 1 == n_si(M_filterk, "f(kw2=2,kw3=3;│)")
    @test 1 == n_si(M_filterk, "f(kw2=2; kw3=3│)")
    @test 0 == n_si(M_filterk, "f(kw2=2; kw6=6│)")

    # When nothing before semicolon, filter methods with required positional args
    # (regardless of whether cursor is editing a kwarg name)
    @test 1 == n_si(M_filterk, "f(;kw1│)")
    @test 1 == n_si(M_filterk, "f(;kw1│=1)")
    @test 1 == n_si(M_filterk, "f(;kw│1)")
    @test 1 == n_si(M_filterk, "f(;│kw1)")
    @test 1 == n_si(M_filterk, "f(;kw1=1, kw1│)")
end

module M_pos_vs_kw
f(a::Int, b::Int) = 0
f(; a, b) = 0
g(x::Int, y::Int) = 0
g(x::Int; kw=nothing) = 0
h(; kw) = 0
h(x::Int; kw) = 0
i(x, y) = 0
i(; kw) = 0
end
@testset "filter positional-only methods when semicolon is present" begin
    # Without semicolon, both methods are shown
    @test 2 == n_si(M_pos_vs_kw, "f(│)")

    # With semicolon but no kwarg yet, only keyword-accepting methods should match
    @test 1 == n_si(M_pos_vs_kw, "f(;│)")
    @test 1 == n_si(M_pos_vs_kw, "g(42;│)") # Should exclude `g(::Int, ::Int)`

    # With semicolon and kwarg, only keyword-accepting methods should match
    @test 1 == n_si(M_pos_vs_kw, "f(;a,│)")
    @test 1 == n_si(M_pos_vs_kw, "f(;a=1│)")

    # Filter out methods with required positional args when semicolon is present
    @test 2 == n_si(M_pos_vs_kw, "h(│)")     # Without semicolon, both shown
    @test 1 == n_si(M_pos_vs_kw, "h(;│)")    # h(x::Int; kw) has required pos arg, filtered
    @test 1 == n_si(M_pos_vs_kw, "h(;kw│)")  # Same filtering applies

    # Splat args should not filter out methods with required positional args
    # because splat could expand to enough args
    @test 2 == n_si(M_pos_vs_kw, "i(│)")
    @test 1 == n_si(M_pos_vs_kw, "i(;│)")           # Without splat, i(x, y) is filtered
    @test 2 == n_si(M_pos_vs_kw, "i(args...;│)")   # With splat, i(x, y) should match
    @test 1 == n_si(M_pos_vs_kw, "i(a, b...;│)")   # i(; kw) filtered (already has pos arg)
end

module M_highlight
f(a0, a1, a2, va3...; kw4=0, kw5=0, kws6...) = 0
f1(x, xs...) = 0
kwfunc(; kw0, kw1, kws2...) = nothing
noargs() = nothing
fixedkw(; kw0, kw1) = nothing
end
function active_parameter(context_module::Module, code::AbstractString; kwargs...)
    si = siginfos(context_module, code; kwargs...)
    activeParameter = @something only(si).activeParameter return nothing
    activeParameter isa JETLS.LSP.Null && return activeParameter
    return Int(activeParameter)
end
@testset "Active param highlighting" begin
    @test 0 == active_parameter(M_highlight, "f(│)")
    @test 0 == active_parameter(M_highlight, "f(0│)")
    @test 1 == active_parameter(M_highlight, "f(0,│)")
    @test 1 == active_parameter(M_highlight, "f(0, │)")

    # in vararg
    @test 3 == active_parameter(M_highlight, "f(0, 1, 2, 3│)")
    @test 3 == active_parameter(M_highlight, "f(0, 1, 2, 3, 3│)")
    @test 3 == active_parameter(M_highlight, "f(0, 1, 2, 3, x...│)")
    @test 3 == active_parameter(M_highlight, "f(0, 1, 2, x...│)")

    @test 1 == active_parameter(M_highlight, "f1(0,│)")
    @test 1 == active_parameter(M_highlight, "f1(0, 1│)")
    @test 1 == active_parameter(M_highlight, "f1(0, 1,│)")
    @test 1 == active_parameter(M_highlight, "f1(0, 1, 2│)")
    @test 1 == active_parameter(M_highlight, "f1(0, 1, 2,│)")
    @test 1 == active_parameter(M_highlight, "f1(0, 1, 2, 3│)")
    @test 1 == active_parameter(M_highlight, "f1(0, 1, 2, 3,│)")

    @test 0 == active_parameter(M_highlight, "kwfunc(; │)")
    @test 1 == active_parameter(M_highlight, "kwfunc(; kw0,│)")
    @test 1 == active_parameter(M_highlight, "kwfunc(; kw0=0,│)")
    @test 2 == active_parameter(M_highlight, "kwfunc(; kw0=0,kw1,│)")
    @test 2 == active_parameter(M_highlight, "kwfunc(; kw0=0,kw1=1,│)")
    @test 2 == active_parameter(M_highlight, "kwfunc(; kw0=0,kw1=1,kw2,│)")
    @test 2 == active_parameter(M_highlight, "kwfunc(; kw0=0,kw1=1,kw2=2,│)")
    @test 2 == active_parameter(M_highlight, "kwfunc(; kw0=0,kw1=1,kws2...,│)")

    # splat contains 0 or more args; use what we know
    @test nothing === active_parameter(M_highlight, "f(x...│, 0, 1, 2, 3, x...)")
    @test nothing === active_parameter(M_highlight, "f(x..., 0, 1, 2│, 3, x...)")
    @test 3       ==  active_parameter(M_highlight, "f(x..., 0, 1, 2, 3│, x...)")
    @test 3       ==  active_parameter(M_highlight, "f(x..., 0, 1, 2, 3, x...│)")
    @test 3       ==  active_parameter(M_highlight, "f(x..., 0, 1, 2, │x...)")

    # various kwarg
    @test 4 == active_parameter(M_highlight, "f(0, 1, 2, 3; kw4│)")
    @test 4 == active_parameter(M_highlight, "f(0, 1, 2, 3; kw4=0│)")
    @test 4 == active_parameter(M_highlight, "f(│kw4=0, 0, 1, 2, 3)")
    @test 0 == active_parameter(M_highlight, "f(kw4=0, 0│, 1, 2, 3)")
    # # any old kwarg can go in `kws6...`
    @test 6 == active_parameter(M_highlight, "f(0, 1, 2, 3; kwfake│)")
    @test 6 == active_parameter(M_highlight, "f(0, 1, 2, 3; kwfake=1│)")
    @test 6 == active_parameter(M_highlight, "f(kwfake=1│, 0, 1, 2, 3)")
    # # splat after semicolon
    @test 6 == active_parameter(M_highlight, "f(0, 1, 2, 3; kwfake...│)")

    # unrecognized kwarg forms should not crash and return something
    @test siginfos(M_highlight, "f(0, 1, 2; a.b=1│)") isa Vector

    @test nothing === active_parameter(M_highlight, "noargs(│)")
    @test JETLS.LSP.null === active_parameter(M_highlight, "noargs(│)"; no_active_parameter_support=true)
    @test 0 == active_parameter(M_highlight, "fixedkw(; kw0=nothing│, kw1=missing, )")
    @test 1 == active_parameter(M_highlight, "fixedkw(; kw0=nothing, kw1=missing│, )")
    @test nothing === active_parameter(M_highlight, "fixedkw(; kw0, kw1, │)")
    @test JETLS.LSP.null === active_parameter(M_highlight, "fixedkw(; kw0, kw1, │)"; no_active_parameter_support=true)
    @test JETLS.LSP.null === active_parameter(M_highlight, "fixedkw(; fake│)"; no_active_parameter_support=true)
end

module M_nested
inner(args...) = 0
outer(args...) = 0
end
@testset "nested" begin
    active_si(code) = only(siginfos(M_nested, code)).label

    @test startswith(active_si("outer(0,1,inner(│))"), "inner")
    @test startswith(active_si("outer(0,1,inner()│)"), "outer")
    @test startswith(active_si("outer(0,1,│inner())"), "inner") # either is fine really
    @test startswith(active_si("outer(0,1│,inner())"), "outer")
    @test startswith(active_si("outer(0,1,inner(),│)"), "outer")
    @test startswith(active_si("function outer(); inner(│); end"), "inner")

    # see through infix and postfix ops, which are parsed as calls
    @test startswith(active_si("outer(0,1,2+3│)"), "outer")
    @test startswith(active_si("outer(0,1,│2+3)"), "outer")
    @test startswith(active_si("outer(0,1,2:│3)"), "outer")
    @test startswith(active_si("outer(0,1,3│')"), "outer")
end

# This depends somewhat on what JuliaSyntax does using `ignore_errors=true`,
# which I don't think is specified, but it would be good to know if these common
# cases break.
module M_invalid
f1(a; k=1) = 0
macro m(x); x; end
end
@testset "tolerate extra whitespace and invalid syntax" begin
    # unclosed paren: ignore whitespace
    @test 1 == n_si(M_invalid, "f1(│")
    @test 1 == n_si(M_invalid, "f1( #=comment=# │")
    @test 1 == n_si(M_invalid, "f1( \n │")
    @test 1 == n_si(M_invalid, "@m(│")
    @test 1 == n_si(M_invalid, "@m( #=comment=# │")
    @test 1 == n_si(M_invalid, "@m( \n │")
    # don't ignore whitespace with closed call
    @test 0 == n_si(M_invalid, "f1( \n ) │")
    @test 0 == n_si(M_invalid, "@m( \n ) │")
    # ignore space but not newlines with no-paren macro
    @test 1 == n_si(M_invalid, "@m   │")
    @test 0 == n_si(M_invalid, "@m\n│")
    @test 0 == n_si(M_invalid, "@m \n │")
    # no-paren macro signature support should not be triggered after closed string macrocall
    @test 0 == n_si(M_invalid, "r\"xxx\"│")
    # no-paren macro signature support should not be triggered when the scope surrounding the cursor is a block
    @test 0 == n_si(M_invalid, """@m begin
        │
    end""")
    @test 1 == n_si(M_invalid, """@m begin
        f1(│)
    end""")
    # signature help should not be triggered when the scope surrounding the cursor is a do block
    @test 0 == n_si(M_invalid, """identity() do x
        │
    end""")
    @test 1 == n_si(M_invalid, """identity() do x
        f1(│)
    end""")

    @test 1 == n_si(M_invalid, "f1(,,,,,,,,,│)")
    @test 1 == n_si(M_invalid, "f1(a b c│)")
    @test 1 == n_si(M_invalid, "f1(k=│)")
    @test 1 == n_si(M_invalid, "f1(k= \n │)")
    @test 0 == n_si(M_invalid, "f1(fake= \n │)")
end

module M_argtype_filtering
const gx1 = 42
const gx2 = 43
func(x::Int) = x
func(x::Int, y::Int) = x + y
func(x::Float64) = x
func(x::Float64, y::Float64) = x + y

kwfunc(x::Int, y::Int; kw1=nothing, kw2=nothing) = x, kw1
kwfunc(x::Float64, y::Float64; kw1=nothing, kw2=nothing) = x, kw1
end
@testset "Argument type based filtering" begin
    @test 2 == n_si(M_argtype_filtering, "func(1,│)")
    @test 1 == n_si(M_argtype_filtering, "func(1,2,│)")
    @test 2 == n_si(M_argtype_filtering, "func(gx1,│)")
    @test 1 == n_si(M_argtype_filtering, "func(gx1,gx2,│)")
    @test 1 == n_si(M_argtype_filtering, "kwfunc(1,│)")
    @test 1 == n_si(M_argtype_filtering, "kwfunc(1,2,│)")
    @test 1 == n_si(M_argtype_filtering, "kwfunc(1,kw1=nothing,│)")
    @test 1 == n_si(M_argtype_filtering, "kwfunc(1,kw1=nothing,2,│)")
    @test 1 == n_si(M_argtype_filtering, "kwfunc(1,2;│)")
    @test 1 == n_si(M_argtype_filtering, "kwfunc(1,2; kw1=nothing,│)")
    @test 2 == n_si(M_argtype_filtering, "let x = 1; func(x,│); end")
end

# Method filtering uses both local-binding types (`x :: String` from a
# `let`-bound `x`) and literal arg types (`Core.Const(1)`) simultaneously.
# Each alone narrows to two methods; only their intersection picks one.
module M_context_aware_filtering
baz(::Int, ::String) = 1
baz(::Int, ::Int) = 2
baz(::String, ::String) = 3
baz(::String, ::Int) = 4
end
@testset "Context-aware filtering combines local and literal args" begin
    @test 1 == n_si(M_context_aware_filtering, "let x = \"a\"; baz(1, x│); end")
    @test 1 == n_si(M_context_aware_filtering, "let x = 1; baz(x, \"a\"│); end")
end

@testset "Tolerate invalid calls with `Union{}`-inferred call argument types" begin
    @test 0 == n_si(@__MODULE__, "sin(throw(),│)")
end

include("setup.jl")

module M_snapshot
snapshot_pair(a, b) = nothing
snapshot_single(x) = nothing
end

function make_signature_help_request(id::Int, uri::URI, pos::Position)
    return SignatureHelpRequest(;
        id,
        params = SignatureHelpParams(;
            textDocument = TextDocumentIdentifier(; uri),
            position = pos))
end

@testset "signature help snapshot ordering" begin
    @testset "prior and later didChange" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            JETLS.cache_out_of_scope!(server.state.analysis_manager, uri, JETLS.OutOfScope(M_snapshot))
            JETLS.cache_file_info!(server, uri, 1, "snapshot_single(0)")
            pos = Position(; line = 0, character = 16)
            request = make_signature_help_request(1, uri, pos)
            next_request = make_signature_help_request(2, uri, pos)
            @test JETLS.is_sequential_msg(request)
            prepared = queued_snapshot_requests(server, [
                make_DidChangeTextDocumentNotification(uri, "snapshot_pair(1,)", 2), request,
                make_DidChangeTextDocumentNotification(uri, "snapshot_single()", 3), next_request])
            @test length(prepared) == 2
            @test prepared[1] isa JETLS.SnapshotRequestMessage
            @test prepared[1].msg isa SignatureHelpRequest
            @test prepared[1].msg === request
            @test prepared[2].msg === next_request
            @test prepared[1].snapshot.fi.version == 2
            @test prepared[1].msg.params.position == pos
            @test JETLS.adjust_position(prepared[1].snapshot, uri, prepared[1].msg.params.position) == pos
            @test prepared[1].snapshot.cache_uri == uri
            @test prepared[1].snapshot.notebook === nothing
            @test prepared[2].snapshot.fi.version == 3
            @test JETLS.get_file_info(server.state, uri) === prepared[2].snapshot.fi
            @test prepared[1].snapshot.fi !== prepared[2].snapshot.fi

            for (item, (label, parameter)) in zip(prepared, [("snapshot_pair(a, b)", 1), ("snapshot_single(x)", 0)])
                response = dispatch_snapshot_request(server, recorder, item)
                @test response isa SignatureHelpResponse
                @test response.error === nothing
                signature = only(response.result.signatures)
                @test signature.label == label
                @test signature.activeParameter == parameter
            end
        end
    end

    @testset "cancellation before prepared dispatch" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            JETLS.cache_file_info!(server, uri, 1, "snapshot_pair(1,)")
            request = make_signature_help_request(1, uri, Position(; line = 0, character = 16))
            prepared = only(queued_snapshot_requests(server, [request]))
            @test prepared.snapshot !== nothing
            JETLS.handler_concurrent_message(server, CancelRequestNotification(; params = CancelParams(; id = request.id)))
            @test JETLS.is_cancelled(server.state.currently_handled[request.id])
            response = dispatch_snapshot_request(server, recorder, prepared)
            @test response isa ResponseMessage
            @test response.result === nothing
            @test response.error isa ResponseError
            @test response.error.code == ErrorCodes.RequestCancelled
        end
    end

    @testset "missing cache is not retried" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            pos = Position(; line = 0, character = 16)
            request = make_signature_help_request(1, uri, pos)
            prepared = only(queued_snapshot_requests(server, [request]))
            @test prepared.snapshot === nothing
            @test JETLS.get_file_info(server.state, uri) === nothing
            JETLS.cache_file_info!(server, uri, 1, "snapshot_pair(1,)")
            JETLS.cache_out_of_scope!(server.state.analysis_manager, uri, JETLS.OutOfScope(M_snapshot))
            current = only(queued_snapshot_requests(server, [make_signature_help_request(2, uri, pos)]))
            @test current.snapshot !== nothing
            response = dispatch_snapshot_request(server, recorder, prepared)
            @test response isa ResponseMessage
            @test response.error === nothing
            @test response.result === null
            response = dispatch_snapshot_request(server, recorder, current)
            @test response.error === nothing
            signature = only(response.result.signatures)
            @test signature.label == "snapshot_pair(a, b)"
            @test signature.activeParameter == 1
        end
    end

    @testset "notebook $change_kind" for change_kind in (:preceding_lines, :remove_requested)
        with_manual_dispatch_server() do server, recorder
            state = server.state
            notebook_uri = URI("file:///signature-snapshot.ipynb")
            cell1 = URI("vscode-notebook-cell:/signature-snapshot.ipynb#1")
            cell2 = URI("vscode-notebook-cell:/signature-snapshot.ipynb#2")
            pos = Position(; line = 0, character = 16)
            cells = [
                JETLS.NotebookCellInfo(cell1, NotebookCellKind.Code, 1, "prefix = 1\nprefix"),
                JETLS.NotebookCellInfo(cell2, NotebookCellKind.Code, 1, "snapshot_pair(1,)")]
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
            change = if change_kind === :preceding_lines
                NotebookDocumentChangeEventCells(;
                    textContent = [NotebookDocumentChangeEventCellsTextContentItem(;
                        document = VersionedTextDocumentIdentifier(; uri = cell1, version = 2),
                        changes = [TextDocumentContentChangeEvent(; text = "prefix = 1")])])
            else
                NotebookDocumentChangeEventCells(;
                    structure = NotebookDocumentChangeEventCellsStructure(;
                        array = NotebookCellArrayChange(;
                            start = UInt(1), deleteCount = UInt(1)),
                        didClose = [TextDocumentIdentifier(; uri = cell2)]))
            end
            request = make_signature_help_request(1, cell2, pos)
            prepared = only(queued_snapshot_requests(server, [
                request,
                DidChangeNotebookDocumentNotification(;
                    params = DidChangeNotebookDocumentParams(;
                        notebookDocument = VersionedNotebookDocumentIdentifier(;
                            uri = notebook_uri, version = 2),
                        change = NotebookDocumentChangeEvent(; cells = change)))]))
            snapshot = prepared.snapshot
            @test snapshot.fi === fi
            @test snapshot.fi.version == 1
            @test snapshot.cache_uri == notebook_uri
            @test snapshot.notebook === concat
            @test prepared.msg === request
            @test prepared.msg.params.position == pos
            global_pos = JETLS.adjust_position(snapshot, cell2, prepared.msg.params.position)
            @test global_pos == Position(; line = 2, character = pos.character)
            @test JETLS.get_file_info(state, notebook_uri).version == 2
            if change_kind === :remove_requested
                @test !JETLS.is_notebook_cell_uri(state, cell2)
                @test JETLS.snapshot_request_message(state, request, cell2).snapshot === nothing
            else
                current = JETLS.snapshot_request_message(state, request, cell2)
                @test JETLS.adjust_position(current.snapshot, cell2, current.msg.params.position) != global_pos
            end

            # Analysis is not snapshotted; dispatch must use the captured notebook URI.
            JETLS.cache_out_of_scope!(state.analysis_manager, notebook_uri, JETLS.OutOfScope(M_snapshot))
            @test JETLS.get_context_info(state, snapshot.cache_uri, global_pos).context_module === M_snapshot
            if change_kind === :remove_requested
                @test JETLS.get_context_info(state, cell2, pos).context_module !== M_snapshot
            end
            response = dispatch_snapshot_request(server, recorder, prepared)
            @test response isa SignatureHelpResponse
            @test response.error === nothing
            signature = only(response.result.signatures)
            @test signature.label == "snapshot_pair(a, b)"
            @test signature.activeParameter == 1
        end
    end

    @testset "mixed completion and signature requests" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            JETLS.cache_out_of_scope!(server.state.analysis_manager, uri, JETLS.OutOfScope(M_snapshot))
            JETLS.cache_file_info!(server, uri, 1, "\\alpha")
            completion = CompletionRequest(;
                id = 1,
                params = CompletionParams(;
                    textDocument = TextDocumentIdentifier(; uri),
                    position = Position(; line = 0, character = 6)))
            signature = make_signature_help_request(2, uri, Position(; line = 0, character = 16))
            @test JETLS.is_sequential_msg(completion)
            @test JETLS.is_sequential_msg(signature)
            prepared = queued_snapshot_requests(server, [
                completion, make_DidChangeTextDocumentNotification(uri, "snapshot_pair(1,)", 2),
                signature, make_DidChangeTextDocumentNotification(uri, "\\beta", 3)])
            @test length(prepared) == 2
            @test prepared[1] isa JETLS.SnapshotRequestMessage
            @test prepared[2] isa JETLS.SnapshotRequestMessage
            @test prepared[1].msg isa CompletionRequest
            @test prepared[2].msg isa SignatureHelpRequest
            @test prepared[1].msg === completion
            @test prepared[2].msg === signature
            @test prepared[1].snapshot.fi.version == 1
            @test prepared[2].snapshot.fi.version == 2
            @test JETLS.get_file_info(server.state, uri).version == 3
            response = dispatch_snapshot_request(server, recorder, prepared[1])
            @test response isa CompletionResponse
            @test response.error === nothing
            item = only(filter(item -> item.label == "\\alpha", response.result.items))
            @test item.textEdit.newText == "α"
            response = dispatch_snapshot_request(server, recorder, prepared[2])
            @test response isa SignatureHelpResponse
            @test response.error === nothing
            siginfo = only(response.result.signatures)
            @test siginfo.label == "snapshot_pair(a, b)"
            @test siginfo.activeParameter == 1
        end
    end
end

function with_signature_help_request(tester, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)

    return withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # run the full analysis first
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, clean_code))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri
            cnt = 0
            for (i, pos) in enumerate(positions)
                (; raw_res) = writereadmsg(SignatureHelpRequest(;
                        id = id_counter[] += 1,
                        params = SignatureHelpParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            position = pos)))
                cnt += tester(i, raw_res.result, uri, script_path)
            end
            return cnt
        end
    end
end

@testset "signature help request/response cycle" begin
    let text = """
        foo(xxx) = :xxx
        foo(xxx, yyy) = :xxx_yyy
        foo(nothing,│)
        """
        @test with_signature_help_request(text) do _, result, uri, _
            canonical_script_path = uri2filename(uri)
            @test length(result.signatures) == 2
            @test any(result.signatures) do siginfo
                siginfo.label == "foo(xxx)" &&
                # this also tests that JETLS doesn't show the nonsensical `var"..."`
                # string caused by JET's internal details
                occursin("@ `Main` [$canonical_script_path:1]($uri#L1)",
                    (siginfo.documentation::MarkupContent).value)
            end
            @test any(result.signatures) do siginfo
                siginfo.label == "foo(xxx, yyy)" &&
                # this also tests that JETLS doesn't show the nonsensical `var"..."`
                # string caused by JET's internal details
                occursin("@ `Main` [$canonical_script_path:2]($uri#L2)",
                    (siginfo.documentation::MarkupContent).value)
            end
            return true
        end == 1
    end

    # Test with DidChangeTextDocumentNotification
    let script_code = """
        foo(xxx) = :xxx
        foo(xxx, yyy) = :xxx_yyy
        """
        withscript(script_code) do script_path
            uri = filepath2uri(script_path)
            withserver() do (; writereadmsg, id_counter)
                # run the full analysis first
                (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, script_code))
                @test raw_res isa PublishDiagnosticsNotification
                @test raw_res.params.uri == uri

                edited_code = """
                foo(xxx) = :xxx
                foo(xxx, yyy) = :xxx_yyy
                foo(nothing,) # <- cursor set at `,`
                """
                writereadmsg(
                    make_DidChangeTextDocumentNotification(uri, edited_code, #=version=#2);
                    read = 0)


                let id = id_counter[] += 1
                    (; raw_res) = writereadmsg(SignatureHelpRequest(;
                        id,
                        params = SignatureHelpParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            position = Position(; line=2, character=12))))
                    @test raw_res isa SignatureHelpResponse
                    canonical_script_path = uri2filename(uri)
                    @test length(raw_res.result.signatures) == 2
                    @test any(raw_res.result.signatures) do siginfo
                        siginfo.label == "foo(xxx)" &&
                        # this also tests that JETLS doesn't show the nonsensical `var"..."`
                        # string caused by JET's internal details
                        occursin("@ `Main` [$canonical_script_path:1]($uri#L1)",
                            (siginfo.documentation::MarkupContent).value)
                    end
                    @test any(raw_res.result.signatures) do siginfo
                        siginfo.label == "foo(xxx, yyy)" &&
                        # this also tests that JETLS doesn't show the nonsensical `var"..."`
                        # string caused by JET's internal details
                        occursin("@ `Main` [$canonical_script_path:2]($uri#L2)",
                            (siginfo.documentation::MarkupContent).value)
                    end
                end
            end
        end
    end
end

@testset "operator-like methods" begin
    # `<:` and `>:` signatures parse as their own syntax kind (not K"call"),
    # which previously caused `flatten_args` to error.
    @test siginfos(Main, "<:(│)") isa Vector
    @test siginfos(Main, ">:(│)") isa Vector
end

end # module test_signature_help
