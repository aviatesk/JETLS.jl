# Note: some of CodeTracking's functionality can only be tested by Revise

using CodeTracking
using Test, InteractiveUtils, REPL, LinearAlgebra, SparseArrays
# Note: ColorTypes needs to be installed, but note the intentional absence of `using ColorTypes`

using CodeTracking: line_is_decl, MethodInfoKey

if !isempty(ARGS) && "revise" ∈ ARGS
    # For running tests with and without Revise
    using Revise
end

isdefined(Main, :Revise) ? Main.Revise.includet("script.jl") : include("script.jl")

@testset "CodeTracking.jl" begin
    m = first(methods(f1))
    file, line = whereis(m)
    scriptpath = normpath(joinpath(@__DIR__, "script.jl"))
    @test file == scriptpath
    @test line == (line_is_decl ? 2 : 4)
    trace = try
        call_throws()
    catch
        stacktrace(catch_backtrace())
    end
    @test whereis(trace[2]) == (scriptpath, 9)

    src, line = definition(String, m)
    @test src == chomp("""
    function f1(x, y)
        # A comment
        return x + y
    end
    """)
    @test line == 2
    @test code_string(f1, Tuple{Any,Any}) == src
    @test @code_string(f1(1, 2)) == src

    m = first(methods(f2))
    src, line = definition(String, m)
    @test src == "f2(x, y) = x + y"
    @test line == 14

    m = first(methods(throws))
    src, line = definition(String, m)
    @test startswith(src, "@noinline")
    @test line == 7

    m = first(methods(multilinesig))
    src, line = definition(String, m)
    @test startswith(src, "@inline")
    @test line == 16
    @test @code_string(multilinesig(1, "hi")) == src
    if Base.VERSION < v"1.11.0-0"
        @test_throws ErrorException("no unique matching method found for the specified argument types") @code_string(multilinesig(1, 2))
    else
        @test_throws "but no method is defined for this combination of argument types" @code_string(multilinesig(1, 2))
    end

    m = first(methods(f50))
    src, line = definition(String, m)
    @test occursin("100x", src)
    @test line == 22

    # Issue #81
    m = which(hasrettype, (Int,))
    src, line = definition(String, m)
    @test occursin("Float32", src)
    @test line == 43

    info = CodeTracking.PkgFiles(Base.PkgId(CodeTracking), nothing)
    @test isempty(CodeTracking.basedir(info))

    info = CodeTracking.PkgFiles(Base.PkgId(CodeTracking), String[])
    @test length(CodeTracking.srcfiles(info)) == 0

    info = CodeTracking.PkgFiles(Base.PkgId(CodeTracking))
    @test Base.PkgId(info) === info.id
    @test CodeTracking.basedir(info) == dirname(@__DIR__)

    io = PipeBuffer()
    show(io, info)
    str = read(io, String)
    @test startswith(str, "PkgFiles(CodeTracking [da1fd8a2-8d9e-5ec2-8556-3022fb5608a2]):\n  basedir:") ||
          startswith(str, "PkgFiles(Base.PkgId(Base.UUID(\"da1fd8a2-8d9e-5ec2-8556-3022fb5608a2\"), \"CodeTracking\")):\n  basedir:")
    ioctx = IOContext(io, :compact=>true)
    show(ioctx, info)
    str = read(io, String)
    @test match(r"PkgFiles\(CodeTracking, .*CodeTracking(\.jl)?, String\[\]\)", str) !== nothing

    @test pkgfiles("ColorTypes") === nothing
    @test_throws ErrorException pkgfiles("NotAPkg")

    # PartialStruct parametric constructors
    m = @which LikeNamedTuple{(:a,)}((1,))
    _, line = whereis(m)
    def, linedef = definition(String, m)
    @test line == linedef
    @test occursin("LikeNamedTuple{names}", def)

    # Test a method marked as missing
    m = @which sum(1:5)
    CodeTracking.method_info[MethodInfoKey(nothing, m.sig)] = missing
    @test whereis(m) == (CodeTracking.maybe_fix_path(String(m.file)), m.line)
    @test definition(m) === nothing

    # Test that definitions at the REPL work with `whereis`
    ex = Base.parse_input_line("replfunc(x) = 1"; filename="REPL[1]")
    eval(ex)
    m = first(methods(replfunc))
    @test whereis(m) == ("REPL[1]", 1)
    # Test with broken lookup
    oldlookup = CodeTracking.method_lookup_callback[]
    CodeTracking.method_lookup_callback[] = m -> error("oops")
    @test whereis(m) == ("REPL[1]", 1)
    CodeTracking.method_lookup_callback[] = oldlookup

    # Method definitions ending in semicolon
    @test code_string(has_semicolon1, (Int, Int)) == "has_semicolon1(x, y) = x + y"

    # Test implicit replacement of `BUILDBOT_STDLIB_PATH`
    m = first(methods(Test.eval))
    @test isfile(whereis(m)[1])

    # https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/150
    function f150()
        x = 1 + 1
        @info "hello"
    end
    m = first(methods(f150))
    scopes = CodeTracking.linetable_scopes(m)
    idx = findfirst(sc -> all(lin -> String(lin.file) == @__FILE__, sc), scopes)
    lin = first(scopes[idx])
    file, line = whereis(lin, m)
    @test endswith(file, String(lin.file))
    idx = findfirst(sc -> !all(lin -> String(lin.file) == @__FILE__, sc), scopes)
    lin = first(scopes[idx])
    file, line = whereis(lin, m)
    if !Sys.iswindows()
        @test endswith(file, String(lin.file))
    end

    # Issues raised in #48
    m = @which(sum([1]; dims=1))
    def = definition(String, m)
    @test isa(def[1], AbstractString)
    if !isdefined(Main, :Revise)
        def = definition(Expr, m)
        @test def === nothing || isa(def, Expr)
    else
        def = definition(Expr, m)
        @test isa(def, Expr)
    end

    # Issue #64
    B = Hermitian(hcat([one(BigFloat) + im]))
    m = @which cholesky(B)
    @test startswith(definition(String, m)[1], "cholesky")

    # Ensure that we don't error on difficult cases
    m = which(+, (AbstractSparseVector, AbstractSparseVector))  # defined inside an `@eval`
    d = definition(String, m)
    @test d === nothing || isa(d[1], AbstractString)

    # Check for existence of file
    id = Base.PkgId("__PackagePrecompilationStatementModule")   # not all Julia versions have this
    mod = try Base.root_module(id) catch nothing end
    if isa(mod, Module)
        m = first(methods(getfield(mod, :eval)))
        @test definition(String, m) === nothing
    end

    # Related to issue [#51](https://github.com/timholy/CodeTracking.jl/issues/51)
    # and https://github.com/JuliaDocs/Documenter.jl/issues/1779
    ex = :(f_no_linenum(::Int) = 1)
    deleteat!(ex.args[2].args, 1)    # delete the file & line number info
    eval(ex)
    @test code_string(f_no_linenum, (Int,)) === nothing

    # Issue #80
    m = only(methods(f80))
    src, line = definition(String, m)
    @test occursin("x^3", src)
    @test line == 52
    m = only(methods(f80_2))
    src, line = definition(String, m)
    @test occursin("x*y", src)
    @test line == 53

    # Issue #103
    if isdefined(Base, Symbol("@assume_effects"))
        m = only(methods(pow103))
        src, line = definition(String, m)
        @test occursin("res *= x", src)
        @test line == 58
    end

    # @eval-ed methods
    m = which(mysin, (Real,))
    src, line = definition(String, m)
    @test occursin("xf", src)
    @test line == 85
    m = only(methods(Base.bodyfunction(m)))
    src, line = definition(String, m)
    @test occursin("xf", src)
    @test line == 85
    m = @which mysin(0.5; return_zero=true)
    src, line = definition(String, m)
    @test occursin("xf", src)
    @test line == 85
    m = which(dollaratan, (Real, Real))
    src, line = definition(String, m)
    @test occursin("atan(y, x)", src)
    @test line == 93
    m = which(hasthreeargs, (Real, Real, Bool))
    src, line = definition(String, m)
    @test occursin("x + y + z", src)
    @test line == 94
    src, line = definition(String, only(methods(c470)))
    @test occursin("\$argnames", src)
    @test line == 137

    # unnamed arguments
    m = which(unnamedarg, (Type{String}, Any))
    src, line = definition(String, m)
    @test occursin("string(x)", src)
    @test line == 97
    m = which(mypush!, (Nowhere, Any))
    src, line = definition(String, m)
    @test occursin("::Nowhere", src)
    @test line == 112

    # global annotations
    m = which(inlet, (Any,))
    src, line = definition(String, m)
    @test occursin("inlet(x)", src)
    @test line == 116

    # Callables
    gg = Gaussian(1.0)
    m = @which gg(2)
    src, line = definition(String, m)
    @test occursin("::Gaussian)(x)", src)
    @test line == 123
    invt = Invert()
    m = @which invt([false, true])
    src, line = definition(String, m)
    @test occursin("::Invert)(v", src)
    @test line == 125

    # Constructor with `where`
    m = @which Invert((false, true))
    src, line = definition(String, m)
    @test occursin("(::Type{T})(itr) where {T<:Invert}", src)
    @test line == 126
    m = @which MyArray1{Float64, 1}(undef, 5)
    src, line = definition(String, m)
    @test occursin("(self::Type{MyArray1{T,1}})(::UndefInitializer", src)
    m = @which MyArray2{Float64, 1}(undef, 5)
    src, line = definition(String, m)
    @test occursin("(::Type{MyArray2{T,1}})(::UndefInitializer", src)

    # Invalidation-insulating methods used by Revise and perhaps others
    d = IdDict{Union{String,Symbol},Union{Function,Vector{Function}}}()
    CodeTracking.invoked_setindex!(d, sin, "sin")
    @test CodeTracking.invoked_get!(Vector{Function}, d, :cos) isa Vector{Function}

    # Issue 115, Cthulhu issue 404
    m = @which (Vector)(Int[])
    src, line = definition(String, m)
    @test occursin(filter(!isspace, "(Array{T,N} where T)(x::AbstractArray{S,N}) where {S,N}"), filter(!isspace, src))
    @test line == m.line

    # Issue 115, Cthulhu issue 474
    m = @which MyNamedTuple{(),Tuple{}}(())
    src, line = definition(String, m)
    @test occursin("MyNamedTuple{names, T}(args::T) where {names, T <: Tuple}", src)
    @test line == m.line

    # Parsed result gives a symbol instead of expression
    m = @which symbol_function(1)
    @test_nowarn definition(String, m)

    # #124
    if !isdefined(Main, :Revise)
        @test definition(String, only(methods(wrongline))) === nothing
    end

    # Nested `where`s
    m = @which Parametric{2}(5)
    src, line = definition(String, m)
    @test occursin("::Type{P}", src)
    @test line == 148

    # Graceful handling of `kwcall` definition lookup failure
    m = @which Core.kwcall(NamedTuple(), Union{})
    @test_throws "could not identify method name in `Core.kwcall`" definition(String, m)
    @test_throws "signature: Tuple{typeof(Core.kwcall), Any, Type{Union{}}, Vararg{Any}}" definition(String, m)
end

@testset "With Revise" begin
    if isdefined(Main, :Revise)
        m = @which gcd(10, 20)
        mt_sigs = signatures_at(Base.find_source_file(String(m.file)), m.line)
        @test !isempty(mt_sigs)
        ex = @code_expr(gcd(10, 20))
        @test ex isa Expr
        body = ex.args[2]
        idx = findfirst(x -> isa(x, LineNumberNode), body.args)
        @test occursin(String(m.file), String(body.args[idx].file))
        @test ex == code_expr(gcd, Tuple{Int,Int})

        if Base.VERSION < v"1.11.0-0"
            m = first(methods(edit))
            mt_sigs = signatures_at(String(m.file), m.line)
            @test !isempty(mt_sigs)
            mt_sigs = signatures_at(Base.find_source_file(String(m.file)), m.line)
            @test !isempty(mt_sigs)
        end

        # issue #23
        @test !isempty(signatures_at("script.jl", 9))

        @test_throws ArgumentError signatures_at("nofile.jl", 1)

        if isdefined(Revise, :add_revise_deps)
            Revise.add_revise_deps()
            mt_sigs = signatures_at(CodeTracking, "src/utils.jl", 5)
            @test length(mt_sigs) == 1       # only isn't available on julia 1.0
            (mt, sig) = first(mt_sigs)
            @test sig == Tuple{typeof(CodeTracking.checkname), Expr, Any}
            @test pkgfiles(CodeTracking).id == Base.PkgId(CodeTracking)
        end

        # REPL (test copied from Revise)
        if isdefined(Base, :active_repl)
            hp = Base.active_repl.interface.modes[1].hist
            fstr = "__fREPL__(x::Int16) = 0"
            histidx = length(hp.history) + 1 - hp.start_idx
            ex = Base.parse_input_line(fstr; filename="REPL[$histidx]")
            f = Core.eval(Main, ex)
            if ex.head === :toplevel
                ex = ex.args[end]
            end
            push!(hp.history, fstr)
            m = first(methods(f))
            @test definition(String, m) == (fstr, 1)
            @test !isempty(signatures_at(String(m.file), m.line))

            histidx += 1
            fstr = "has_semicolon2(x, y) = x + y;"
            ex = Base.parse_input_line(fstr; filename="REPL[$histidx]")
            f = Core.eval(Main, ex)
            push!(hp.history, fstr)
            @test code_string(has_semicolon2, (Int, Int)) == "has_semicolon2(x, y) = x + y"

            pop!(hp.history)
            pop!(hp.history)
        elseif haskey(ENV, "CI")
            error("CI Revise tests must be run with -i")
        end
    end
end

(a_34)(x::T, y::T) where {T<:Integer} = no_op_err("&", T)
(b_34)(x::T, y::T) where {T<:Integer} = no_op_err("|", T)
c_34(x::T, y::T) where {T<:Integer} = no_op_err("xor", T)

(d_34)(x::T, y::T) where {T<:Number} = x === y
(e_34)(x::T, y::T) where {T<:Real} = no_op_err("<" , T)
(f_34)(x::T, y::T) where {T<:Real} = no_op_err("<=", T)
l = @__LINE__
@testset "#34 last character" begin
    def, line = definition(String, @which d_34(1, 2))
    @test line == l - 3
    @test def == "(d_34)(x::T, y::T) where {T<:Number} = x === y"
end

function g()
    Base.@_inline_meta
    print("hello")
end
@testset "inline macros" begin
    def, line = CodeTracking.definition(String, @which g())
    @test def == """
    function g()
        Base.@_inline_meta
        print("hello")
    end"""
end

@testset "kwargs methods" begin
    mdirect = only(methods(func_2nd_kwarg))
    fbody = Base.bodyfunction(mdirect)
    body, loc = CodeTracking.definition(String, first(methods(fbody)))
    @test loc == 28
    @test body == "func_2nd_kwarg(a, b; kw=2) = true"
end

@testset "method extensions" begin
    body, _ = CodeTracking.definition(String, @which Foo.Bar.fit(1))
    @test body == """
    function Foo.Bar.fit(m)
        return m
    end"""
    body, _ = CodeTracking.definition(String, @which Foo.Bar.fit(1, 2))
    if Base.VERSION < v"1.10"
        @test body == "Foo.Bar.fit(a, b) = a + b"
    end
end

struct CallOverload
    z
end
(f::CallOverload)(arg) = f.z + arg
struct Functor end
(::Functor)(x, y) = x+y
@testset "call syntax" begin
    body, _ = CodeTracking.definition(String, @which CallOverload(1)(1))
    @test body == "(f::CallOverload)(arg) = f.z + arg"

    body, _ = CodeTracking.definition(String, @which Functor()(1,2))
    @test body == "(::Functor)(x, y) = x+y"
end

@testset "kwfuncs" begin
    body, _ = CodeTracking.definition(String, @which fkw(; x=1))
    @test startswith(body, """
    function fkw(; x=1)
        x
    end""")
end

@testset "Decorated args" begin
    body, _ = CodeTracking.definition(String, which(nospec, (Any,)))
    @test body == "nospec(@nospecialize(x)) = 2x"
    body, _ = CodeTracking.definition(String, which(nospec2, (Vector,)))
    @test body == "nospec2(@nospecialize(x::AbstractVecOrMat)) = first(x)"
    body, _ = CodeTracking.definition(String, which(nospec3, (Symbol,)))
    @test body == "nospec3(name::Symbol, @nospecialize(arg=nothing)) = name"
    body, _ = CodeTracking.definition(String, which(nospec3, (Symbol, String)))
    @test body == "nospec3(name::Symbol, @nospecialize(arg=nothing)) = name"
    body, _ = CodeTracking.definition(String, which(withva, (Char,)))
    @test body == "withva(a...) = length(a)"
    body, _ = CodeTracking.definition(String, which(hasdefault, (Int,)))
    @test body == "hasdefault(xd, yd=2) = xd + yd"
    body, _ = CodeTracking.definition(String, which(hasdefault, (Int, Float32)))
    @test body == "hasdefault(xd, yd=2) = xd + yd"
    body, _ = CodeTracking.definition(String, which(hasdefaulttypearg, (Type{Float32},)))
    @test startswith(body, "hasdefaulttypearg(::Type{T}=Rational{Int}) where T = zero(T)")
end

@testset "tuple-destructured args" begin
    body, _ = CodeTracking.definition(String, which(diffminmax, (Any,)))
    @test startswith(body, "diffminmax((min, max)) = max - min")
end

@testset "strip_gensym with unicode" begin
    @test CodeTracking.strip_gensym("#𝓔′#90") == :𝓔′
    @test CodeTracking.strip_gensym("𝓔′##kw") == :𝓔′
end

@testset "External method tables" begin
    mod = @eval module $(gensym(:ExternalMT))
        Base.Experimental.@MethodTable method_table
    end
    ex = :(Base.Experimental.@overlay method_table +(x::String, y::String) = x * y)
    if VERSION ≥ v"1.13-"
        method = Core.eval(mod, ex)
    else
        Core.eval(mod, ex)
        method = only(Base.MethodList(mod.method_table).ms)
    end
    lnn = LineNumberNode(Int(method.line), method.file)
    @test CodeTracking.definition(Expr, method) === nothing
    CodeTracking.method_info[MethodInfoKey(method)] = [(lnn, ex)]
    @test CodeTracking.definition(Expr, method) == ex
end
