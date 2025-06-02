module test_signature_help

using Test
using JETLS
using JETLS: JL, JS
using JETLS: cursor_siginfos

# siginfos(mod, code, cursor="|") -> siginfos
# nsigs(mod, code, cursor="|")

function siginfos(mod::Module, code::String, cursor::String="|")
    b = findfirst(cursor, code).start
    ps = JS.ParseStream(replace(code, cursor=>"", count=1)); JS.parse!(ps)
    return cursor_siginfos(mod, ps, b)
end

n_si(args...) = let si = siginfos(args...)
    length(si)
end

module M_sanity
i_exist(a,b,c) = 0
end
@testset "sanity" begin

    @test 1 === n_si(M_sanity, "i_exist(|)")
    @test 1 === n_si(M_sanity, "i_exist(1,2,3|)")
    @test 1 === n_si(M_sanity, "i_exist(|1,2,3)")
    @test 0 === n_si(M_sanity, "i_do_not_exist(|)")
    @test 0 === n_si(M_sanity, "|")
    @test 0 === n_si(M_sanity, "(|)")
    @test 0 === n_si(M_sanity, "()|")
end


@testset "don't show help in method definitions" begin
    snippets = [
        "function f(|); end",
        "function f(|) where T; end",
        "function f(|) where T where T; end",
        "f(|) = 1",
        "f(|) where T = 1",
    ]
    for s in snippets
        @test 0 === n_si(Main, s)
    end
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
    @test 1 === n_si(M_filterk, "f(;kw1|)")
    @test 1 === n_si(M_filterk, "f(;kw1=|)")
    @test 1 === n_si(M_filterk, "f(;kw1=1|)")

    # mix
    @test 2 === n_si(M_filterk, "f(kw2=2,kw3=3;|)")
    @test 2 === n_si(M_filterk, "f(kw2=2; kw3=3|)")
    @test 2 === n_si(M_filterk, "f(kw2=2; kw3|)")
    @test 1 === n_si(M_filterk, "f(kw2=2; kw6|)")
end

module M_highlight
f(a0, a1, a2, va3...; kw4=0, kw5=0, kws6...) = 0
end
@testset "param highlighting" begin
    function ap(mod::Module, code::String, cursor::String="|")
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
    # splat contains 0 or more args; use what we know
    @test nothing === ap(M_highlight, "f(x...|, 0, 1, 2, 3, x...)")
    @test nothing === ap(M_highlight, "f(x..., 0, 1, 2|, 3, x...)")
    @test 3       === ap(M_highlight, "f(x..., 0, 1, 2, 3|, x...)")
    @test 3       === ap(M_highlight, "f(x..., 0, 1, 2, 3, x...|)")

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
    @test startswith(active_si("outer(0,1,inner()|)"), "inner")
    @test startswith(active_si("outer(0,1,|inner())"), "outer") # either is fine really
    @test startswith(active_si("outer(0,1|,inner())"), "outer")
    @test startswith(active_si("outer(0,1,inner(),|)"), "outer")
    @test startswith(active_si("function outer(); inner(|); end"), "inner")
end

# This depends somewhat on what JuliaSyntax does using `ignore_errors=true`,
# which I don't think is specified, but it would be good to know if these common
# cases break.
module M_invalid
f1(a; k=1) = 0
end
@testset "tolerate invalid syntax" begin
    @test 1 === n_si(M_invalid, "f1(|")
    @test 1 === n_si(M_invalid, "f1(,,,,,,,,,|)")
    @test 1 === n_si(M_invalid, "f1(a b c|)")
    @test 1 === n_si(M_invalid, "f1(k=|)")

end
end
