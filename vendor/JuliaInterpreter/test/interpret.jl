using JuliaInterpreter
using Test, InteractiveUtils, CodeTracking
using Mmap
using LinearAlgebra
using JuliaInterpreter: isdefinedglobal

if !isdefinedglobal(@__MODULE__, :runframe)
    include("utils.jl")
end

module Isolated end

function summer(A)
    s = zero(eltype(A))
    for a in A
        s += a
    end
    return s
end

A = [0.12, -.99]
frame = JuliaInterpreter.enter_call(summer, A)
frame2 = JuliaInterpreter.enter_call(summer, A)
@test summer(A) == something(runframe(frame)) == something(runstack(frame2))

A = rand(1000)
@test @interpret(sum(A)) ≈ sum(A)  # note: the compiler can leave things in registers to increase accuracy, doesn't happen with interpreted
fapply() = (Core.apply_type)(Base.NamedTuple, (), Tuple{})
@test @interpret(fapply()) == fapply()
function fbc()
    bc = Broadcast.broadcasted(CartesianIndex, 6, [1, 2, 3])
    copy(bc)
end
@test @interpret(fbc()) == fbc()
@test @interpret(repr("hi")) == repr("hi")  # this tests kwargs and @generated functions

fkw(x::Int8; y=0, z="hello") = y
@test @interpret(fkw(Int8(1); y=22, z="world")) == fkw(Int8(1); y=22, z="world")

# generators that throw before returning the body expression
@test_throws ArgumentError("input tuple of length 3, requested 2") @interpret Base.fill_to_length((1,2,3), -1, Val(2))

# Throwing exceptions across frames
function f_exc_inner()
    error("inner")
end

f_exc_inner2() = f_exc_inner()

const caught = Ref(false)
function f_exc_outer1()
    try
        f_exc_inner()
    catch err    # with an explicit err capture
        caught[] = true
        rethrow(err)
    end
end

function f_exc_outer2()
    try
        f_exc_inner()
    catch        # implicit err capture
        caught[] = true
        rethrow()
    end
end

function f_exc_outer3(f)
    try
        f()
    catch err
        return err
    end
end

@test !caught[]
ret = @interpret f_exc_outer3(f_exc_outer1)
@test ret == ErrorException("inner")
@test caught[]

caught[] = false
ret = @interpret f_exc_outer3(f_exc_outer2)
@test ret == ErrorException("inner")
@test caught[]

caught[] = false
ret = @interpret f_exc_outer3(f_exc_inner2)
@test ret == ErrorException("inner")
@test !caught[]


stc = try f_exc_outer1() catch
    stacktrace(catch_backtrace())
end
sti = try @interpret(f_exc_outer1()) catch
    stacktrace(catch_backtrace())
end
@test_broken stc == sti

# issue #3
@test @interpret(joinpath("/home/julia/base", "sysimg.jl")) == joinpath("/home/julia/base", "sysimg.jl")
@test @interpret(10.0^4) == 10.0^4
# issue #6
@test @interpret(Array.body.body.name) === Array.body.body.name
if Vararg isa UnionAll
    @test @interpret(Vararg.body.body.name) === Vararg.body.body.name
else
    @test @interpret(Vararg{Int}.T) === Vararg{Int}.T
    @test @interpret(Vararg{Any,3}.N) === Vararg{Any,3}.N
end
@test !JuliaInterpreter.is_vararg_type(Union{})
if Vararg isa UnionAll
    frame = Frame(Main, :(Vararg.body.body.name))
    @test JuliaInterpreter.finish_and_return!(frame, true) === Vararg.body.body.name
else
    frame = Frame(Main, :(Vararg{Int}.T))
    @test JuliaInterpreter.finish_and_return!(frame, true) === Vararg{Int}.T
    frame = Frame(Main, :(Vararg{Any,3}.N))
    @test JuliaInterpreter.finish_and_return!(frame, true) === Vararg{Any,3}.N
end
frame = Frame(Base, :(Union{AbstractChar,Tuple{Vararg{AbstractChar}},AbstractVector{<:AbstractChar},Set{<:AbstractChar}}))
@test JuliaInterpreter.finish_and_return!(frame, true) isa Union

# issue #8
ex = quote
    if sizeof(JLOptions) === ccall(:jl_sizeof_jl_options, Int, ())
    else
        ccall(:jl_throw, Cvoid, (Any,), "Option structure mismatch")
    end
end
frame = Frame(Base, ex)
JuliaInterpreter.finish_and_return!(frame, true)

# ccall with two Symbols
ex = quote
    @testset "Some tests" begin
       @test 2 > 1
    end
end
frame = Frame(Main, ex)
JuliaInterpreter.finish_and_return!(frame, true)

@test @interpret Base.Math.DoubleFloat64(-0.5707963267948967, 4.9789962508669555e-17).hi ≈ -0.5707963267948967

# ccall with cfunction
fcfun(x::Int, y::Int) = 1
ex = quote   # in lowered code, cf is a Symbol
    cf = @eval @cfunction(fcfun, Int, (Int, Int))
    ccall(cf, Int, (Int, Int), 1, 2)
end
frame = Frame(Main, ex)
@test JuliaInterpreter.finish_and_return!(frame, true) == 1
ex = quote
    let   # in lowered code, cf is a SlotNumber
        cf = @eval @cfunction(fcfun, Int, (Int, Int))
        ccall(cf, Int, (Int, Int), 1, 2)
    end
end
frame = Frame(Main, ex)
@test JuliaInterpreter.finish_and_return!(frame, true) == 1
function cfcfun()
    cf = @cfunction(fcfun, Int, (Int, Int))
    ccall(cf, Int, (Int, Int), 1, 2)
end
@test @interpret(cfcfun()) == 1

# From Julia's test/ambiguous.jl. This tests whether we renumber :enter statements correctly.
ambig(x, y) = 1
ambig(x::Integer, y) = 2
ambig(x, y::Integer) = 3
ambig(x::Int, y::Int) = 4
ambig(x::Number, y) = 5
ex = quote
    let
        cf = @eval @cfunction(ambig, Int, (UInt8, Int))
        @test_throws(MethodError, ccall(cf, Int, (UInt8, Int), 1, 2))
    end
end
frame = Frame(Main, ex)
JuliaInterpreter.finish_and_return!(frame, true)

# Core.Compiler
ex = quote
    length(code_typed(fcfun, (Int, Int)))
end
frame = Frame(Main, ex)
@test JuliaInterpreter.finish_and_return!(frame, true) == 1

# copyast
ex = quote
    struct CodegenParams
        cached::Cint

        track_allocations::Cint
        code_coverage::Cint
        static_alloc::Cint
        prefer_specsig::Cint

        module_setup::Any
        module_activation::Any
        raise_exception::Any
        emit_function::Any
        emitted_function::Any

        CodegenParams(;cached::Bool=true,
                       track_allocations::Bool=true, code_coverage::Bool=true,
                       static_alloc::Bool=true, prefer_specsig::Bool=false,
                       module_setup=nothing, module_activation=nothing, raise_exception=nothing,
                       emit_function=nothing, emitted_function=nothing) =
            new(Cint(cached),
                Cint(track_allocations), Cint(code_coverage),
                Cint(static_alloc), Cint(prefer_specsig),
                module_setup, module_activation, raise_exception,
                emit_function, emitted_function)
    end
end
frame = Frame(Isolated, ex)
JuliaInterpreter.finish_and_return!(frame, true)
@test Isolated.CodegenParams(cached=false).cached === Cint(false)

# cglobal
val = @interpret(BigInt())
@test isa(val, BigInt) && val == 0
@test isa(@interpret(Base.GMP.version()), VersionNumber)

# Issue #455
using PyCall
let np = pyimport("numpy")
    @test @interpret(PyCall.pystring_query(np.zeros)) === Union{}
end
# Issue #354
using HTTP
headers = Dict("User-Agent" => "Debugger.jl")
@test @interpret(HTTP.request("GET", "https://httpbingo.julialang.org", headers)) isa HTTP.Messages.Response

# "correct" line numbers
defline = @__LINE__() + 1
function f(x)
    x = 2x
    # comment
    # comment
    x = 2x
    # comment
    return x*x
end
frame = JuliaInterpreter.enter_call(f, 3)
@test whereis(frame, 1)[2] == defline + 1
@test whereis(frame, (length(frame.framecode.src.code) + 1) ÷ 2)[2] == defline + 4
@test whereis(frame, length(frame.framecode.src.code) - 1)[2] == defline + 6
m = which(iterate, Tuple{Dict}) # this method has `nothing` as its first statement and codeloc == 0
framecode = JuliaInterpreter.get_framecode(m)
@test JuliaInterpreter.linenumber(framecode, 1) == m.line + CodeTracking.line_is_decl

# issue #28
let a = ['0'], b = ['a']
    @test @interpret(vcat(a, b)) == vcat(a, b)
end

# llvmcall
function add1234(x::Tuple{Int32,Int32,Int32,Int32})
    Core.Intrinsics.llvmcall("""%3 = extractvalue [4 x i32] %0, 0
      %4 = extractvalue [4 x i32] %0, 1
      %5 = extractvalue [4 x i32] %0, 2
      %6 = extractvalue [4 x i32] %0, 3
      %7 = extractvalue [4 x i32] %1, 0
      %8 = extractvalue [4 x i32] %1, 1
      %9 = extractvalue [4 x i32] %1, 2
      %10 = extractvalue [4 x i32] %1, 3
      %11 = add i32 %3, %7
      %12 = add i32 %4, %8
      %13 = add i32 %5, %9
      %14 = add i32 %6, %10
      %15 = insertvalue [4 x i32] undef, i32 %11, 0
      %16 = insertvalue [4 x i32] %15, i32 %12, 1
      %17 = insertvalue [4 x i32] %16, i32 %13, 2
      %18 = insertvalue [4 x i32] %17, i32 %14, 3
      ret [4 x i32] %18""",Tuple{Int32,Int32,Int32,Int32},
      Tuple{Tuple{Int32,Int32,Int32,Int32},Tuple{Int32,Int32,Int32,Int32}},
        (Int32(1),Int32(2),Int32(3),Int32(4)),
        x)
end
@test @interpret(add1234(map(Int32,(2,3,4,5)))) === map(Int32,(3,5,7,9))

# issue #74
let A = [1]
    wkd = WeakKeyDict()
    @interpret setindex!(wkd, 2, A)
    @test wkd[A] == 2
end

# issue #76
let TT = Union{UInt8, Int8}
    a = TT[0x0, 0x1]
    pa = Ptr{UInt8}(pointer(a))
    GC.@preserve a begin
        @interpret unsafe_store!(pa, 0x2, 2)
    end
    @test a == TT[0x0, 0x2]
end

# issue #92
let x = Core.SlotNumber(1)
    f(x) = objectid(x)
    @test isa(@interpret(f(x)), UInt)
end

# issue #98
x98 = 5
function f98()
    global x98
    x98 = 7
    return nothing
end
@interpret f98()
@test x98 == 7

# issue #106
function f106()
    n = tempname()
    w = open(n, "a")
    write(w, "A")
    flush(w)
    return true
end
@test @interpret(f106()) == 1
f106b() = rand()
f106c() = disable_sigint(f106b)
function f106d()
    disable_sigint() do
        reenable_sigint(f106b)
    end
end
@interpret f106c()
@interpret f106d()

# issue #113
f113(;x) = x
@test @interpret(f113(;x=[1,2,3])) == f113(;x=[1,2,3])

# Some expressions can appear nontrivial but lower to nothing
# @test isa(Frame(Main, :(@static if ccall(:jl_get_UNAME, Any, ()) === :NoOS 1+1 end)), Nothing)
# @test isa(Frame(Main, :(Base.BaseDocs.@kw_str "using")), Nothing)

@testset "locals" begin
    f_locals(x::Int64, y::T, z::Vararg{Symbol}) where {T} = x
    frame = JuliaInterpreter.enter_call(f_locals, Int64(1), 2.0, :a, :b)
    locals = JuliaInterpreter.locals(frame)
    @test JuliaInterpreter.Variable(Int64(1), :x, false) in locals
    @test JuliaInterpreter.Variable(2.0, :y, false) in locals
    @test JuliaInterpreter.Variable((:a, :b), :z, false) in locals
    @test JuliaInterpreter.Variable(Float64, :T, true) in locals

    function f_multi(x)
        c = x
        x = 2
        x = 3
        x = 4
        return x
    end
    frame = JuliaInterpreter.enter_call(f_multi, 1)
    nlocals = length(frame.framedata.locals)
    @test_throws UndefVarError JuliaInterpreter.lookup_var(frame, JuliaInterpreter.SlotNumber(nlocals))
    locals = JuliaInterpreter.locals(frame)
    @test length(locals) == 2
    @test JuliaInterpreter.Variable(1, :x, false) in locals
    JuliaInterpreter.step_expr!(frame)
    JuliaInterpreter.step_expr!(frame)
    @static if VERSION >= v"1.11-"
        locals = JuliaInterpreter.locals(frame)
        @test length(locals) == 2
        JuliaInterpreter.step_expr!(frame)
    end
    locals = JuliaInterpreter.locals(frame)
    @test length(locals) == 3
    @test JuliaInterpreter.Variable(1, :c, false) in locals
    JuliaInterpreter.step_expr!(frame)
    locals = JuliaInterpreter.locals(frame)
    @test length(locals) == 3
    @test JuliaInterpreter.Variable(2, :x, false) in locals
    JuliaInterpreter.step_expr!(frame)
    locals = JuliaInterpreter.locals(frame)
    @test length(locals) == 3
    @test JuliaInterpreter.Variable(3, :x, false) in locals

    # Issue #404
    function aaa(F::Array{T,1}, Z::Array{T,1}) where {T}
        M = length(Z)

        J = [1:M;]
        z = T[]
        f = T[]
        w = T[]

        A = rand(10, 10)
        G = svd(A[J, :])
        w = G.V[:, m]

        r = zz -> rhandle(zz, z, f, w)
    end

    function rhandle(zz, z, f, w)
        nothing
    end

    fr = JuliaInterpreter.enter_call(aaa, rand(5), rand(5))
    fr, bp = JuliaInterpreter.debug_command(fr, :n)
    locs = JuliaInterpreter.locals(fr)
    @test !any(x -> x.name === :w, locs)
end

@testset "getfield replacements" begin
    f_gf(x) = false ? some_undef_var_zzzzzzz : x
    @test @interpret f_gf(2) == 2

    gvar = gensym()
    @eval function g_gf()
        @eval $gvar = 2
        return $gvar
    end
    if VERSION ≥ v"1.12-"
        @test_throws "`$gvar` not defined" @interpret(g_gf() == 2)
    else
        @test @interpret(g_gf() == 2)
    end

    global q_gf = 0
    function h_gf()
        eval(:(q_gf = 2))
        return q_gf
    end
    @test @interpret h_gf() == 2

    # https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/267
    function test_never_different(x)
        if x < 5
            for g in never_defined
                print(g)
            end
        end
    end
    @test @interpret(test_never_different(10)) === nothing

end

# https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/130
@testset "vararg handling" begin
    method_c1(x::Float64, s::AbstractString...) = true
    buf = IOBuffer()
    me = Base.MethodError(method_c1,(1, 1, ""))
    @test (@interpret Base.show_method_candidates(buf, me)) == nothing

    varargidentity(x) = x
    x = Union{Array{UInt8,N},Array{Int8,N}} where N
    @test isa(JuliaInterpreter.prepare_call(varargidentity, [varargidentity, x])[1], JuliaInterpreter.FrameCode)
end

# https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/141
@test @interpret get(ENV, "THIS_IS_NOT_DEFINED_1234", "24") == "24"

# Test return value of whereis
fnone() = nothing
fr = JuliaInterpreter.enter_call(fnone)
file, line = JuliaInterpreter.whereis(fr)
@test file == @__FILE__
@test line == (@__LINE__() - 4)

# Test path to files in stdlib
fr = JuliaInterpreter.enter_call(rand)
file, line = JuliaInterpreter.whereis(fr)
@test isfile(file)
@static if VERSION < v"1.12.0-DEV.173"
@test isfile(JuliaInterpreter.getfile(fr.framecode.src.linetable[1]))
end
@test occursin(joinpath(contractuser(Sys.STDLIB), "Random"), repr(fr))

# Test undef sparam (https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/165)
function foo(x::T) where {T <: AbstractString, S <: AbstractString}
    return S
end
e = try
        @interpret foo("")
    catch err
        err
    end
@test e isa UndefVarError
@test e.var === :S
# https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/200
locs = JuliaInterpreter.locals(JuliaInterpreter.enter_call(foo, ""))
@test length(locs) == 3 # #self# + 2 variables
@test JuliaInterpreter.Variable("", :x, false) in locs
@test JuliaInterpreter.Variable(String, :T, true) in locs

# Test interpreting subtypes finishes in a reasonable time
@test @interpret subtypes(Integer) == subtypes(Integer)
@test @interpret subtypes(Main, Integer) == subtypes(Main, Integer)
@test (@elapsed @interpret subtypes(Integer)) < 30
@test (@elapsed @interpret subtypes(Main, Integer)) < 30

# Test showing stacktraces from frames
g_1(x) = g_2(x)
g_2(x) = g_3(x)
g_3(x) = error("foo")
line_g = @__LINE__

_contractuser = Base.contractuser

try
    break_on(:error)
    local frame, bp = @interpret g_1(2.0)
    stacktrace_lines = split(sprint(Base.display_error, bp.err, leaf(frame)), '\n')
    @test occursin(string("ERROR: ", sprint(showerror, ErrorException("foo"))), stacktrace_lines[1])
    @test occursin("[1] error(s::String)", stacktrace_lines[3])
    @test occursin("[2] g_3(x::Float64)", stacktrace_lines[5])
    thefile = _contractuser(@__FILE__)
    @test occursin("$thefile:$(line_g - 1)", stacktrace_lines[6])
    @test occursin("[3] g_2(x::Float64)", stacktrace_lines[7])
    @test occursin("$thefile:$(line_g - 2)", stacktrace_lines[8])
    @test occursin("[4] g_1(x::Float64)", stacktrace_lines[9])
    @test occursin("$thefile:$(line_g - 3)", stacktrace_lines[10])
finally
    break_off(:error)
end

try
    break_on(:error)
    exs = collect(ExprSplitter(Main, quote
            g_1(2.0)
        end))
    line2_g = @__LINE__
    local frame = Frame(exs[1]...)
    frame, bp = JuliaInterpreter.debug_command(frame, :c, true)
    stacktrace_lines = split(sprint(Base.display_error, bp.err, leaf(frame)), '\n')
    @test occursin(string("ERROR: ", sprint(showerror, ErrorException("foo"))), stacktrace_lines[1])
    @test occursin("[1] error(s::String)", stacktrace_lines[3])
    thefile = _contractuser(@__FILE__)
    @test occursin("[2] g_3(x::Float64)", stacktrace_lines[5])
    @test occursin("$thefile:$(line_g - 1)", stacktrace_lines[6])
    @test occursin("[3] g_2(x::Float64)", stacktrace_lines[7])
    @test occursin("$thefile:$(line_g - 2)", stacktrace_lines[8])
    @test occursin("[4] g_1(x::Float64)", stacktrace_lines[9])
    @test occursin("$thefile:$(line_g - 3)", stacktrace_lines[10])
    @test occursin("[5] top-level scope", stacktrace_lines[11])
    @test occursin("$thefile:$(line2_g - 2)", stacktrace_lines[12])
finally
    break_off(:error)
end

f_562(x::Union{Vector{T}, Nothing}) where {T} = x + 1
try
    break_on(:error)
    local frame, bp = @interpret f_562(nothing)

    stacktrace_lines = split(sprint(Base.display_error, bp.err, leaf(frame)), '\n')
    @test stacktrace_lines[1] == "ERROR: MethodError: no method matching +(::Nothing, ::$Int)"
finally
    break_off(:error)
end

# https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/154
q = QuoteNode([1])
qcopy = @interpret deepcopy(q)
@test isa(qcopy, QuoteNode) && qcopy.value == q.value

# Check #args for builtins (#217)
f217() = <:(Float64, Float32, Float16)
@test_throws ArgumentError @interpret(f217())

# issue #220
function hash220(x::Tuple{Ptr{UInt8},Int}, h::UInt)
    h += Base.memhash_seed
    ccall(Base.memhash, UInt, (Ptr{UInt8}, Csize_t, UInt32), x[1], x[2], h % UInt32) + h
end
@test @interpret(hash220((Ptr{UInt8}(0),0), UInt(1))) == hash220((Ptr{UInt8}(0),0), UInt(1))

# ccall with type parameters
@static if VERSION < v"1.11-"
    # TODO: in v1.11+ this function does not have a ccall
    @test (@interpret Base.unsafe_convert(Ptr{Int}, [1,2])) isa Ptr{Int}
end

# ccall with call to get the pointer
cf = [@cfunction(fcfun, Int, (Int, Int))]
function call_cf()
    ccall(cf[1], Int, (Int, Int), 1, 2)
end
@test (@interpret call_cf()) == call_cf()
let mt = JuliaInterpreter.enter_call(call_cf).framecode.methodtables
    @test any(1:length(mt)) do i
        isassigned(mt, i) && mt[i] === Compiled()
    end
end

# ccall with integer static parameter
f_N() =  Array{Float64, 4}(undef, 1, 3, 2, 1)
@test (@interpret f_N()) isa Array{Float64, 4}

f_clock() = ccall((:clock, "libc"), Int32, ())
# See that the method gets compiled
try @interpret f_clock()
catch
end
let mt = JuliaInterpreter.enter_call(f_clock).framecode.methodtables
    @test any(1:length(mt)) do i
        isassigned(mt, i) && mt[i] === Compiled()
    end
end

# https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/194
f_parse() =  Meta.lower(Main, Meta.parse("(a=1,0)"))
@test @interpret f_parse() == f_parse()

# Test for vararg ccalls (used by mmap)
function f_mmap()
    tmp = tempname()
    local b_mmap
    try
        x = rand(10)
        write(tmp, x)
        b_mmap = Mmap.mmap(tmp, Vector{Float64})
        @test b_mmap == x
    finally
        finalize(b_mmap)
        Threads.@spawn begin
            sleep(5)
            rm(tmp)
        end
    end
end
@interpret f_mmap()

# parametric llvmcall (issues #112 and #288)
module VecTest
    const Vec{N,T} = NTuple{N,VecElement{T}}
    # The following test mimic SIMD.jl
    const _llvmtypes = Dict{DataType, String}(
        Float64 => "double",
        Float32 => "float",
        Int32 => "i32",
        Int64 => "i64"
    )
    @generated function vecadd(x::Vec{N, T}, y::Vec{N, T}) where {N, T}
        llvmT = _llvmtypes[T]
        func = T <: AbstractFloat ? "fadd" : "add"
        exp = """
        %3 = $(func) <$(N) x $(llvmT)> %0, %1
        ret <$(N) x $(llvmT)> %3
        """
        return quote
            Base.@_inline_meta
            Core.getfield(Base, :llvmcall)($exp, Vec{$N, $T}, Tuple{Vec{$N, $T}, Vec{$N, $T}}, x, y)
        end
    end
    f(a) = vecadd(a, a)
end
let
    # NOTE we need to make sure this code block is compiled, since vecadd is generated function,
    # but currently `@interpret` doesn't handle a call to generated functions very well
    Base.Experimental.@force_compile
    a = (VecElement{Float64}(1.0), VecElement{Float64}(2.0))
    @test @interpret(VecTest.vecadd(a, a)) == VecTest.vecadd(a, a)
    @test @interpret(VecTest.f(a)) == VecTest.f(a)
end

# Test exception type for undefined variables
f_undefvar() = s = s + 1
@test_throws UndefVarError @interpret f_undefvar()

# Handling of SSAValues
function f_ssaval()
    z = [Core.SSAValue(5),]
    repr(z[1])
end
@test @interpret f_ssaval() == f_ssaval()

# Test JuliaInterpreter version of #265
f(x) = x
g(x) = f(x)
@test (@interpret g(5)) == g(5)
f(x) = x*x
@test (@interpret g(5)) == g(5)

# Regression test https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/328
module DataFramesTest
    using Test
    using JuliaInterpreter
    using DataFrames
    function df_debug1()
        df = DataFrame(A=1:3, B=4:6)
        df1 = hcat(df[!,[:A]], df[!,[:B]])
    end
    @test @interpret(df_debug1()) == df_debug1()
end

# issue #330
@test @interpret(Base.PipeEndpoint()) isa Base.PipeEndpoint

# issue #345
@noinline f_345() = 1
frame = JuliaInterpreter.enter_call(f_345)
@test JuliaInterpreter.whereis(frame) == (@__FILE__(), @__LINE__() - 2)

# issue #285
using LinearAlgebra, SparseArrays, Random
@testset "issue 285" begin
    function solveit(A,b)
        return A\b .+ det(A)
    end

    Random.seed!(123456)
    n = 5
    A = sprand(n,n,0.5)
    A = A'*A
    b = rand(n)
    @test @interpret(solveit(A, b)) == solveit(A, b)
end

@testset "issue 351" begin
    f() = map(x -> 2x, 1:10)
    @test @interpret(f()) == f()
end

@testset "invoke" begin
    # Example provided by jmert in #352
    f(d::Diagonal{T}) where {T} = invoke(f, Tuple{AbstractMatrix}, d)
    f(m::AbstractMatrix{T}) where {T} = T
    D = Diagonal([1.0, 2.0])
    @test @interpret(f(D)) === f(D)

    # issue #441 & #535
    f_log1() = @info "logging macros"
    @test (@test_logs (:info, "logging macros") (@interpret f_log1())) === nothing
    f_log2() = @error "this error is ok"
    let frame = JuliaInterpreter.enter_call(f_log2)
        @test (@test_logs (:error, "this error is ok") debug_command(frame, :c)) === nothing
    end
end

struct A396
    a::Int
end
@testset "constructor locals" begin
    frame = JuliaInterpreter.enter_call(A396, 3)
    @test length(JuliaInterpreter.locals(frame)) > 0
end

@static if Sys.islinux()
    @testset "@ccall" begin
        f(s) = @ccall strlen(s::Cstring)::Csize_t
        @test @interpret(f("asd")) == 3
    end
end

@testset "#466 parametric_type_to_expr" begin
    @test JuliaInterpreter.parametric_type_to_expr(Array) == :(Core.Array{T, N})
end

@testset "#476 isdefined QuoteNode" begin
    @eval function issue476()
        return $(Expr(:isdefined, QuoteNode(Float64)))
    end
    @test (true === @interpret issue476())
end

@noinline foobar() = (GC.safepoint(); 42)
function run_foobar()
    @eval foobar() = "nope"
    return @interpret(foobar()), foobar()
end
@testset "unreachable worlds" begin
    interpret, compiled = run_foobar()
    @test_broken interpret == compiled == 42
end

@testset "issue #479" begin
    function f()
        ptr = @cfunction(+, Int, (Int, Int))
        ccall(ptr::Ptr{Cvoid}, Int, (Int, Int), 1, 2)
    end
    @test @interpret(f()) === 3
end

@testset "https://github.com/JuliaLang/julia/pull/41018" begin
    m = Module()
    @eval m begin
        struct Foo
            foo::Int
            bar
        end
    end
    # this shouldn't throw "type DataType has no field hasfreetypevars"
    # even after https://github.com/JuliaLang/julia/pull/41018
    @test Int === @interpret Core.Compiler.getfield_tfunc(Core.Compiler.fallback_lattice, m.Foo, Core.Compiler.Const(:foo))
end

@testset "https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/488" begin
    m = Module()
    ex = :(foo() = return)
    JuliaInterpreter.finish_and_return!(Frame(m, ex), true)
    @test isdefined(m, :foo)
end

# Related to fixing https://github.com/timholy/Revise.jl/issues/625
module ForInclude end
@testset "include" begin
    ex = :(include("dummy_file.jl"))
    @test JuliaInterpreter.finish_and_return!(Frame(ForInclude, ex), true) == 55
end

@testset "issue #432" begin
    function f()
        t = @ccall time(C_NULL::Ptr{Cvoid})::Cint
    end
    @test @interpret(f()) !== 0
    @test @interpret(f()) !== 0
end

@testset "issue #385" begin
    using FunctionWrappers: FunctionWrapper
    fw = @interpret FunctionWrapper{Int,Tuple{}}(()->42)
    @test 42 === @interpret fw()
end

@testset "issue #550" begin
    using FunctionWrappers: FunctionWrapper
    f    = (obs) -> (obs[1] = obs[3] * obs[4]; obs)
    Tout = Vector{Int}
    Tin  = Tuple{Vector{Int}}
    fw   = FunctionWrapper{Tout, Tin}(f)

    obs = [0,2,3,4]
    @test @interpret(fw(obs)) == fw(obs)
end

@testset "TypedSlots" begin
    function foo(x, y)
        z = x + y
        if z < 4
            z += 1
        end
        u = (x -> x + z)(x)
        v = Ref{Union{Int, Missing}}(x)[] + y
        return u + v
    end

    ci = code_typed(foo, NTuple{2, Int}; optimize=false)[][1]
    mi = Base.method_instances(foo, NTuple{2, Int}, Base.get_world_counter())[]

    frameargs = Any[foo, 1, 2]
    framecode = JuliaInterpreter.FrameCode(mi.def, ci)
    frame = JuliaInterpreter.prepare_frame(framecode, frameargs, mi.sparam_vals)
    @test JuliaInterpreter.finish_and_return!(frame) === 8
end

@testset "interpretation of unoptimized frame" begin
    let # should be able to interprete nested calls within `:foreigncall` expressions
        M = Module()
        lwr = Meta.@lower M begin
            global foo = @ccall strlen("foo"::Cstring)::Csize_t
            foo == 3
        end
        src = lwr.args[1]::Core.CodeInfo
        frame = Frame(M, src; optimize=false)
        @test length(frame.framecode.src.code) == length(src.code)
        @test JuliaInterpreter.finish_and_return!(frame, true)

        M = Module()
        lwr = Meta.@lower M begin
            strp = Ref{Ptr{Cchar}}(0)
            fmt = "hi+%hhd-%hhd-%hhd-%hhd-%hhd-%hhd-%hhd-%hhd-%hhd-%hhd-%hhd-%hhd-%hhd-%hhd-%hhd-%.1f-%.1f-%.1f-%.1f-%.1f-%.1f-%.1f-%.1f-%.1f\n"
            len = @ccall asprintf(
                strp::Ptr{Ptr{Cchar}},
                fmt::Cstring,
                ; # begin varargs
                0x1::UInt8, 0x2::UInt8, 0x3::UInt8, 0x4::UInt8, 0x5::UInt8, 0x6::UInt8, 0x7::UInt8, 0x8::UInt8, 0x9::UInt8, 0xa::UInt8, 0xb::UInt8, 0xc::UInt8, 0xd::UInt8, 0xe::UInt8, 0xf::UInt8,
                1.1::Cfloat, 2.2::Cfloat, 3.3::Cfloat, 4.4::Cfloat, 5.5::Cfloat, 6.6::Cfloat, 7.7::Cfloat, 8.8::Cfloat, 9.9::Cfloat,
            )::Cint
            str = unsafe_string(strp[], len)
            @ccall free(strp[]::Cstring)::Cvoid
            str == "hi+1-2-3-4-5-6-7-8-9-10-11-12-13-14-15-1.1-2.2-3.3-4.4-5.5-6.6-7.7-8.8-9.9\n"
        end
        src = lwr.args[1]::Core.CodeInfo
        frame = Frame(M, src; optimize=false)
        @test length(frame.framecode.src.code) == length(src.code)
        @test JuliaInterpreter.finish_and_return!(frame, true)
    end

    iscallexpr(ex::Expr) = ex.head === :call
    @test (@interpret iscallexpr(:(sin(3.14))))
end

f_fma() = Base.have_fma(Float64)
@testset "fma" begin
    @test (@interpret f_fma()) == f_fma()
    a, b, c = (1.0585073227945125, -0.00040303348596386557, 1.5051263504758005e-16)
    @test (@interpret muladd(a, b, c)) === muladd(a,b,c)
    a = 1.0883740903666346; b = 2/3
    @test (@interpret a^b) === a^b
end

# issue 536
function foo_536(y::T) where {T}
    x = "A"
    return ccall(:memcmp, Cint, (Ptr{UInt8}, Ref{T}, Csize_t),
            pointer(x), Ref(y), 1) == 0
end
@test !@interpret foo_536(0x00)
@test @interpret foo_536(UInt8('A'))

@testset "opaque closures" begin
    g(x) = 3x
    f = Base.Experimental.@opaque x -> g(x)
    @test @interpret(f(4)) == 12

    # test stepping into opaque closures
    @breakpoint g(1)
    fr = JuliaInterpreter.enter_call_expr(Expr(:call, f, 4))
    @test JuliaInterpreter.finish_and_return!(fr) isa JuliaInterpreter.BreakpointRef
end

# CassetteOverlay, issue #552
using CassetteOverlay
function cassette_overlay_func()
    x = IdDict()
    x[:foo] = 1
end
@MethodTable SinTable;
@testset "CassetteOverlay" begin
    pass = @overlaypass SinTable;
    @test (@interpret pass(cassette_overlay_func)) == 1
end

using LoopVectorization

@testset "interpolated llvmcall" begin
    function f_lv!(A)
        m, n = size(A)
        k = 1
        @turbo for j in (k + 1):n
            for i in (k + 1):m
                A[i, j] -= A[i, k] * A[k, j]
            end
        end
        return A
    end
    A = rand(5,5)
    B = copy(A)
    @interpret f_lv!(A)
    f_lv!(B)
    @test A ≈ B
end

@testset "nargs foreigncall #560" begin
    @test (@interpret string("", "pcre_h.jl")) == string("", "pcre_h.jl")
    @test (@interpret Base.strcat("", "build_h.jl")) ==  Base.strcat("", "build_h.jl")
end

# test for using generic functions that were previously builtin
func_arrayref(a, i) = Core.arrayref(true, a, i)
@test 2 == @interpret func_arrayref([1,2,3], 2)

@static if isdefinedglobal(Base, :ScopedValues)
@testset "interpret_scopedvalues.jl" include("interpret_scopedvalues.jl")
end

@testset "changing interpreter for @interpret" begin
    @test sin(42) == @interpret sin(42)
    @test sin(42) == @interpret interp=RecursiveInterpreter() sin(42)
    @test sin(42) == @interpret interp=NonRecursiveInterpreter() sin(42)
    @test ((@allocated @interpret interp=RecursiveInterpreter() sin(42)) ≠ (@allocated @interpret interp=NonRecursiveInterpreter() sin(42)))
    let interp1 = RecursiveInterpreter(),
        interp2 = NonRecursiveInterpreter()
        @test sin(42) == @interpret interp=interp1 sin(42)
        @test sin(42) == @interpret interp=interp2 sin(42)
    end
    @test_throws "Invalid @interpret call" macroexpand(@__MODULE__, :(@interpret interp sin(42)))
    @test_throws "Invalid @interpret call" macroexpand(@__MODULE__, :(@interpret _interp_=RecursiveInterpreter() sin(42)))
end

function func_overlay end
func_overlay(x) = sin(x)
call_func_overlay(x) = func_overlay(x)
Base.Experimental.@MethodTable ex_method_table
Base.Experimental.@overlay ex_method_table func_overlay(x) = cos(x)
struct OverlayInterpreter <: Interpreter end
JuliaInterpreter.method_table(::OverlayInterpreter) = ex_method_table

@testset "Interpret overlay method" begin
    let frame = JuliaInterpreter.Frame(@__MODULE__, :(func_overlay(42.0)))
        @test JuliaInterpreter.finish_and_return!(frame, true) == sin(42.0)
    end
    @test sin(42.0) == @interpret call_func_overlay(42.0)
    let frame = JuliaInterpreter.Frame(@__MODULE__, :(func_overlay(42.0)))
        @test JuliaInterpreter.finish_and_return!(OverlayInterpreter(), frame, true) == cos(42.0)
    end
    let frame = JuliaInterpreter.enter_call(func_overlay, 42.0; method_table=ex_method_table)
        @test JuliaInterpreter.finish_and_return!(OverlayInterpreter(), frame) == cos(42.0)
    end
    @test cos(42.0) == @interpret interp=OverlayInterpreter() call_func_overlay(42.0)
end
