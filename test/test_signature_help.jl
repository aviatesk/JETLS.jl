module test_signature_help

using Test
using JETLS
using JETLS: JL, JS
using JETLS.URIs2
using JETLS.Analyzer: LSAnalyzer
using JETLS: cursor_siginfos

# siginfos(mod, code, cursor="|") -> siginfos
# nsigs(mod, code, cursor="|")

function siginfos(mod::Module, code::AbstractString, cursor::AbstractString="|")
    b = findfirst(cursor, code).start
    ps = JS.ParseStream(replace(code, cursor=>"", count=1)); JS.parse!(ps)
    return cursor_siginfos(mod, ps, b, LSAnalyzer())
end

n_si(args...) = length(siginfos(args...))

module M_sanity
i_exist(a,b,c) = 0
struct SExist1; s; end # just 1 construct (w/o the conversion method)
struct SExist2; s::String; end # just 1 construct (w/o the conversion method)
struct SExist3
    s
    SExist3(@nospecialize s) = new(s)
end
macro m_exist(x); x; end
end
@testset "sanity" begin
    @test 1 == n_si(M_sanity, "i_exist(|)")
    @test 1 == n_si(M_sanity, "i_exist(1,2,3|)")
    @test 1 == n_si(M_sanity, "i_exist(|1,2,3)")
    @test 0 == n_si(M_sanity, "i_do_not_exist(|)")
    @test 0 == n_si(M_sanity, "|")
    @test 0 == n_si(M_sanity, "(|)")
    @test 0 == n_si(M_sanity, "()|")
    @test 1 == n_si(M_sanity, "SExist1(|)")
    @test 0 == n_si(M_sanity, "SExist1(1,2|)")
    @test 2 == n_si(M_sanity, "SExist2(|)")
    @test 0 == n_si(M_sanity, "SExist2(1,2|)")
    @test 1 == n_si(M_sanity, "SExist3(|)")
    @test 0 == n_si(M_sanity, "SExist3(1,2|)")
end

module M_macros
macro m(x, y=1); x; end
macro v(x...); x; end
end
@testset "simple macros" begin
    @test 2 == n_si(M_macros, "@m(|)")
    @test 2 == n_si(M_macros, "@m|")
    @test 2 == n_si(M_macros, "@m |")
    @test 2 == n_si(M_macros, "@m(1,|)")
    @test 2 == n_si(M_macros, "@m 1|")
    @test 1 == n_si(M_macros, "@m(1,2,|)")
    @test 1 == n_si(M_macros, "@m 1 2|")
    @test 0 == n_si(M_macros, "@m(1,2,3,|)")
    @test 0 == n_si(M_macros, "@m 1 2 3|")
    @test 1 == n_si(M_macros, "@v|")
    @test 1 == n_si(M_macros, "@v 1 2 3 4|")
end

module M_dotcall
f(x) = 0
end
@testset "dotcall" begin
    @test 1 == n_si(M_dotcall, "f.(|)")
    @test 1 == n_si(M_dotcall, "f.(x|)")
end

module M_noshow_def
f(x) = x
g(x) = x
macro m(x); x; end
end
@testset "don't show help in method definitions" begin
    snippets = [
        "function f(|); end",
        "function f(|) where T; end",
        "function f(|) where T where T; end",
        "f(|) = 1",
        "f(|) where T = 1",
        "|f(x) = g(x)",
        "f(x|) = g(x)",
        "f(x)| = g(x)",
        "f(x::T|) where T = g(x)",
    ]
    for s in snippets
        @test 0 === n_si(M_noshow_def, s)
    end
    @test 1 === n_si(M_noshow_def, "f(x) = g(|)")
    @test 1 === n_si(M_noshow_def, "f(x) = g(x |)")
    @test 1 === n_si(M_noshow_def, "f(x) where T where U = g(x|)")
    @test 1 === n_si(M_noshow_def, "f(x) where T where U = @m(x|)")
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
    @test 5 === n_si(M_filterp, "f4(|)")
    @test 4 === n_si(M_filterp, "f4(1|)")
    @test 4 === n_si(M_filterp, "f4(1,|)")
    @test 4 === n_si(M_filterp, "f4(1, |)")
    @test 3 === n_si(M_filterp, "f4(1,2|)")
    @test 2 === n_si(M_filterp, "f4(1,2,3|)")
    @test 1 === n_si(M_filterp, "f4(1,2,3,4,|)")

    @test 1 === n_si(M_filterp, "f4(|1,2,3,4,)")
    @test 1 === n_si(M_filterp, "f4(1,2,3,4; |)")

    # splat should be assumed empty for filtering purposes
    @test 1 === n_si(M_filterp, "f4(1,2,3,4,x...|)")
    @test 1 === n_si(M_filterp, "f4(x...,1,2,3,4,|)")

    @test 3 === n_si(M_filterp, "f1v(|)")
    @test 2 === n_si(M_filterp, "f1v(1,|)")
    @test 1 === n_si(M_filterp, "f1v(1,2|)")
    @test 1 === n_si(M_filterp, "f1v(1,2,3|)")
    @test 1 === n_si(M_filterp, "f1v(1,2,3,foo...|)")
end

module M_filterk
f(;kw1, kw2=2, kw3::Int=3) = 0
f(x; kw2, kw3, kw4, kw5, kw6) = 0
end
@testset "filter by names of kwargs" begin
    @test 2 === n_si(M_filterk, "f(|)")

    # pre-semicolon
    @test 0 === n_si(M_filterk, "f(1, kw1|)") # positional until we type "="
    @test 1 === n_si(M_filterk, "f(kw1=1|)")

    # post-semicolon
    @test 1 === n_si(M_filterk, "f(|;kw1)")
    @test 1 === n_si(M_filterk, "f(;kw1,|)")
    @test 1 === n_si(M_filterk, "f(;kw1=|)")
    @test 1 === n_si(M_filterk, "f(;kw1=1|)")

    # mix
    @test 2 === n_si(M_filterk, "f(kw2=2,kw3=3;|)")
    @test 2 === n_si(M_filterk, "f(kw2=2; kw3=3|)")
    @test 1 === n_si(M_filterk, "f(kw2=2; kw6=6|)")

    # don't filter on a kw if the cursor could be editing it
    @test 2 === n_si(M_filterk, "f(;kw1|)")
    @test 2 === n_si(M_filterk, "f(;kw1|=1)")
    @test 2 === n_si(M_filterk, "f(;kw|1)")
    @test 2 === n_si(M_filterk, "f(;|kw1)")
    @test 1 === n_si(M_filterk, "f(;kw1=1, kw1|)")
end

module M_highlight
f(a0, a1, a2, va3...; kw4=0, kw5=0, kws6...) = 0
end
@testset "param highlighting" begin
    function ap(mod::Module, code::AbstractString, cursor::AbstractString="|")
        si = siginfos(mod, code, cursor)
        p = only(si).activeParameter
        isnothing(p) ? nothing : Int(p)
    end
    @test 0 === ap(M_highlight, "f(|)")
    @test 0 === ap(M_highlight, "f(0|)")
    @test 1 === ap(M_highlight, "f(0,|)")
    @test 1 === ap(M_highlight, "f(0, |)")

    # in vararg
    @test 3 === ap(M_highlight, "f(0, 1, 2, 3|)")
    @test 3 === ap(M_highlight, "f(0, 1, 2, 3, 3|)")
    @test 3 === ap(M_highlight, "f(0, 1, 2, 3, x...|)")
    @test 3 === ap(M_highlight, "f(0, 1, 2, x...|)")
    # splat contains 0 or more args; use what we know
    @test nothing === ap(M_highlight, "f(x...|, 0, 1, 2, 3, x...)")
    @test nothing === ap(M_highlight, "f(x..., 0, 1, 2|, 3, x...)")
    @test 3       === ap(M_highlight, "f(x..., 0, 1, 2, 3|, x...)")
    @test 3       === ap(M_highlight, "f(x..., 0, 1, 2, 3, x...|)")
    @test 3       === ap(M_highlight, "f(x..., 0, 1, 2, |x...)")

    # various kwarg
    @test 4 === ap(M_highlight, "f(0, 1, 2, 3; kw4|)")
    @test 4 === ap(M_highlight, "f(0, 1, 2, 3; kw4=0|)")
    @test 4 === ap(M_highlight, "f(|kw4=0, 0, 1, 2, 3)")
    @test 0 === ap(M_highlight, "f(kw4=0, 0|, 1, 2, 3)")
    # any old kwarg can go in `kws6...`
    @test 6 === ap(M_highlight, "f(0, 1, 2, 3; kwfake|)")
    @test 6 === ap(M_highlight, "f(0, 1, 2, 3; kwfake=1|)")
    @test 6 === ap(M_highlight, "f(kwfake=1|, 0, 1, 2, 3)")
    # splat after semicolon
    @test 6 === ap(M_highlight, "f(0, 1, 2, 3; kwfake...|)")
end

module M_nested
inner(args...) = 0
outer(args...) = 0
end
@testset "nested" begin
    active_si(code) = only(siginfos(M_nested, code)).label

    @test startswith(active_si("outer(0,1,inner(|))"), "inner")
    @test startswith(active_si("outer(0,1,inner()|)"), "outer")
    @test startswith(active_si("outer(0,1,|inner())"), "inner") # either is fine really
    @test startswith(active_si("outer(0,1|,inner())"), "outer")
    @test startswith(active_si("outer(0,1,inner(),|)"), "outer")
    @test startswith(active_si("function outer(); inner(|); end"), "inner")

    # see through infix and postfix ops, which are parsed as calls
    @test startswith(active_si("outer(0,1,2+3|)"), "outer")
    @test startswith(active_si("outer(0,1,|2+3)"), "outer")
    @test startswith(active_si("outer(0,1,2:|3)"), "outer")
    @test startswith(active_si("outer(0,1,3|')"), "outer")
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
    @test 1 === n_si(M_invalid, "f1(|")
    @test 1 === n_si(M_invalid, "f1( #=comment=# |")
    @test 1 === n_si(M_invalid, "f1( \n |")
    @test 1 === n_si(M_invalid, "@m(|")
    @test 1 === n_si(M_invalid, "@m( #=comment=# |")
    @test 1 === n_si(M_invalid, "@m( \n |")
    # don't ignore whitespace with closed call
    @test 0 === n_si(M_invalid, "f1( \n ) |")
    @test 0 === n_si(M_invalid, "@m( \n ) |")
    # ignore space but not newlines with no-paren macro
    @test 1 === n_si(M_invalid, "@m   |")
    @test 0 === n_si(M_invalid, "@m\n|")
    @test 0 === n_si(M_invalid, "@m \n |")

    @test 1 === n_si(M_invalid, "f1(,,,,,,,,,|)")
    @test 1 === n_si(M_invalid, "f1(a b c|)")
    @test 1 === n_si(M_invalid, "f1(k=|)")
    @test 1 === n_si(M_invalid, "f1(k= \n |)")
    @test 0 === n_si(M_invalid, "f1(fake= \n |)")
end

include("setup.jl")

@testset "signature help request/response cycle" begin
    let script_code = """
        foo(xxx) = :xxx
        foo(xxx, yyy) = :xxx_yyy
        foo(nothing,) # <- cursor set at `,`
        """
        withscript(script_code) do script_path
            uri = filepath2uri(script_path)
            withserver() do (; writereadmsg, id_counter)
                # run the full analysis first
                (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, script_code))
                @test raw_res isa PublishDiagnosticsNotification
                @test raw_res.params.uri == uri

                let id = id_counter[] += 1
                    (; raw_res) = writereadmsg(SignatureHelpRequest(;
                        id,
                        params = SignatureHelpParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            position = Position(; line=2, character=12))))
                    @test raw_res isa SignatureHelpResponse
                    @test length(raw_res.result.signatures) == 2
                    @test any(raw_res.result.signatures) do siginfo
                        siginfo.label == "foo(xxx)" &&
                        # this also tests that JETLS doesn't show the nonsensical `var"..."`
                        # string caused by JET's internal details
                        occursin("@ `Main` [$(script_path):1]($(filepath2uri(script_path))#L1)",
                            (siginfo.documentation::MarkupContent).value)
                    end
                    @test any(raw_res.result.signatures) do siginfo
                        siginfo.label == "foo(xxx, yyy)" &&
                        # this also tests that JETLS doesn't show the nonsensical `var"..."`
                        # string caused by JET's internal details
                        occursin("@ `Main` [$(script_path):2]($(filepath2uri(script_path))#L2)",
                            (siginfo.documentation::MarkupContent).value)
                    end
                end
            end
        end
    end

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

                # TODO Comment in the following
                #      The following line doesn't work becuase `get_context_module` isn't synced
                #      with `DidChangeTextDocumentNotification`
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
                    @test_broken length(raw_res.result.signatures) == 2
                    @test_broken any(raw_res.result.signatures) do siginfo
                        siginfo.label == "foo(xxx)" &&
                        # this also tests that JETLS doesn't show the nonsensical `var"..."`
                        # string caused by JET's internal details
                        occursin("@ `Main` [$(script_path):1]($(filepath2uri(script_path))#L1)",
                            (siginfo.documentation::MarkupContent).value)
                    end
                    @test_broken any(raw_res.result.signatures) do siginfo
                        siginfo.label == "foo(xxx, yyy)" &&
                        # this also tests that JETLS doesn't show the nonsensical `var"..."`
                        # string caused by JET's internal details
                        occursin("@ `Main` [$(script_path):2]($(filepath2uri(script_path))#L2)",
                            (siginfo.documentation::MarkupContent).value)
                    end
                end
            end
        end
    end
end

end # module test_signature_help
