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

# Issue #455: a `cglobal` whose first argument is an inline `(symbol, library)`
# tuple lowers to `cglobal(Core.tuple(sym, lib), T)`, so the first argument is an
# expression rather than a literal symbol. Interleaved with `GotoIfNot` branches, this is
# the structure of `PyCall.pystring_query`, the original trigger; reproduce it
# self-containedly against openlibm (a permissively-licensed library bundled with
# Julia) so the check no longer depends on PyCall or a Python install. Spell the
# library both as a string literal and as `Base.Math.libm`: on Julia ≥ 1.11 the
# latter lowers to a nested `getproperty` chain inside the `cglobal` tuple, which the
# interpreter must resolve when looking up that argument.
function cglobal_query_str(x)
    p1 = cglobal((:sin, "libopenlibm"), Ptr{Cvoid})
    if p1 == C_NULL
        return AbstractString
    end
    p2 = cglobal((:cos, "libopenlibm"), Ptr{Cvoid})
    if p2 == C_NULL
        return Integer
    end
    return Union{}
end
function cglobal_query_chain(x)
    p1 = cglobal((:sin, Base.Math.libm), Ptr{Cvoid})
    if p1 == C_NULL
        return AbstractString
    end
    p2 = cglobal((:cos, Base.Math.libm), Ptr{Cvoid})
    if p2 == C_NULL
        return Integer
    end
    return Union{}
end
@test @interpret(cglobal_query_str(0)) === cglobal_query_str(0) === Union{}
@test @interpret(cglobal_query_chain(0)) === cglobal_query_chain(0) === Union{}
# On Julia ≥ 1.14, `cglobal` name lookups lower to `Expr(:foreignglobal, spec)`
# (JuliaLang/julia#61709), which the interpreter must evaluate itself (issue #734).
cglobal_foreignglobal() = cglobal(:jl_options)
@test @interpret(cglobal_foreignglobal()) == cglobal_foreignglobal() != C_NULL
# The argument may also be a runtime value rather than a (quoted)
# symbol/string/tuple literal, in which case it must already be a pointer:
# `cglobal(p)` is then a typechecked cast to `Ptr{Cvoid}`, and a non-pointer
# argument is a `TypeError`, matching the compiled semantics.
cglobal_ptr_passthrough(p) = cglobal(p)
let p = cglobal(:jl_options)
    @test @interpret(cglobal_ptr_passthrough(p)) === cglobal_ptr_passthrough(p) === p
    @test_throws TypeError @interpret(cglobal_ptr_passthrough(1))
end
@test @interpret(Base.JLOptions()) == Base.JLOptions()
# Issue #354: an `llvmcall` argument computed from a function argument cannot be
# interpreted directly. `build_compiled_llvmcall!` runs a mini-interpreter (with
# no arguments) over the statements feeding the call's type parameters; here the
# inline `Tuple{Int64}` type argument lowers ahead of the argument-dependent
# `x + 1`, so that sweep reaches `x + 1` and has no argument to evaluate it with.
# Such methods are instead routed to compiled execution via `compiled_methods`.
# `Base.load_state_acquire` (an atomic load via `llvmcall`) was the original
# trigger; it was removed from Base in 1.12, so this reproduces the same
# structural case portably, without pointers.
function llvmcall_354(x::Int64)
    Base.llvmcall("ret i64 %0", Int64, Tuple{Int64}, x + 1)
end
push!(JuliaInterpreter.compiled_methods, which(llvmcall_354, Tuple{Int64}))
# `Int64(10)`, not `10`: a bare literal is `Int32` on 32-bit platforms and would
# not match the `Int64` signature.
@test @interpret(llvmcall_354(Int64(10))) === Int64(11)

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

# Support Core.Argument in lowered code (needed for Julia PR #61036 _defaultctors)
@testset "Core.Argument support" begin
    # replace_coretypes_list! converts Core.Argument to SlotNumber
    code_list = Any[Core.Compiler.Argument(1), Core.Compiler.Argument(3)]
    JuliaInterpreter.replace_coretypes_list!(code_list)
    @test code_list[1] == JuliaInterpreter.SlotNumber(1)
    @test code_list[2] == JuliaInterpreter.SlotNumber(3)

    # Core.Argument nested inside Expr is also converted
    code_list2 = Any[Expr(:new, Core.Compiler.Argument(1), Core.Compiler.Argument(2))]
    JuliaInterpreter.replace_coretypes_list!(code_list2)
    @test code_list2[1].args[1] == JuliaInterpreter.SlotNumber(1)
    @test code_list2[1].args[2] == JuliaInterpreter.SlotNumber(2)

    # lookup_var with Core.Compiler.Argument works on a real frame
    f_arg(x, y) = x + y
    frame = JuliaInterpreter.enter_call(f_arg, 10, 20)
    @test JuliaInterpreter.lookup_var(frame, Core.Compiler.Argument(1)) == f_arg
    @test JuliaInterpreter.lookup_var(frame, Core.Compiler.Argument(2)) == 10
    @test JuliaInterpreter.lookup_var(frame, Core.Compiler.Argument(3)) == 20
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

# Subtyping envout markers from newer Julia versions must not leak into
# interpreted static-parameter values.
function envout_marker_optional_sparam(::Type{<:Tuple{Vararg{E}}}) where E
    return E
end
function envout_marker_required_sparam(::Type{<:Tuple{E}}) where E
    return E
end
let m = first(methods(envout_marker_optional_sparam)),
    argtypes = (Tuple{typeof(envout_marker_optional_sparam), Type{Tuple{Vararg{Int,N}}}} where N),
    ret = JuliaInterpreter.prepare_framecode(m, argtypes)

    if ret isa Tuple
        framecode, lenv = ret
        if lenv[1] isa Core.SimpleVector
            @test lenv[1][2] === false
            frame = JuliaInterpreter.prepare_frame(framecode,
                Any[envout_marker_optional_sparam, Tuple{Vararg{Int}}], lenv)
            err = try
                JuliaInterpreter.finish_and_return!(frame, true)
            catch err
                err
            end
            @test err isa UndefVarError
            @test err.var === :E
        end
    end
end
let m = first(methods(envout_marker_required_sparam)),
    argtypes = Tuple{typeof(envout_marker_required_sparam), Type{Tuple{Int}}},
    ret = JuliaInterpreter.prepare_framecode(m, argtypes)

    if ret isa Tuple
        framecode, lenv = ret
        if lenv[1] isa Core.SimpleVector
            @test lenv[1][2] === true
            frame = JuliaInterpreter.prepare_frame(framecode,
                Any[envout_marker_required_sparam, Tuple{Int}], lenv)
            @test JuliaInterpreter.finish_and_return!(frame, true) === Int
        end
    end
end

# A failed generator must use native dispatch rather than return its call result as frame metadata.
@generated function unavailable_generated_code(::Val{T}) where T
    error("generated code unavailable")
end
let args = Any[unavailable_generated_code, Val(:test)],
    ret = JuliaInterpreter.prepare_call(unavailable_generated_code, args)

    @test ret[1] isa JuliaInterpreter.Compiled
    @test_throws ErrorException unavailable_generated_code(Val(:test))
end

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

# On 1.14-DEV, method selection currently picks `error(s...)` over
# `error(s::AbstractString)` for a `String` argument, so the innermost frame shows the
# packed vararg tuple. Accept both until upstream method specificity settles.
is_error_frame(line) = occursin(r"\[1\] error\(s::(String|Tuple\{String\})\)", line)

try
    break_on(:error)
    local frame, bp = @interpret g_1(2.0)
    stacktrace_lines = split(sprint(Base.display_error, bp.err, leaf(frame)), '\n')
    @test occursin(string("ERROR: ", sprint(showerror, ErrorException("foo"))), stacktrace_lines[1])
    @test is_error_frame(stacktrace_lines[3])
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
    @test is_error_frame(stacktrace_lines[3])
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

# issue #220: a `ccall` whose target is a runtime function-pointer value reached through a
# binding (the original report used `Base.memhash`, removed in 1.13; see issue #696).
add_one_220(x::Cint)::Cint = x + Cint(1)
const PTR_220 = @cfunction(add_one_220, Cint, (Cint,))
call220(x) = ccall(PTR_220, Cint, (Cint,), x)
@test @interpret(call220(Cint(41))) == call220(Cint(41)) == Cint(42)

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

# Building a `StackFrame` must not throw when a statement has no recoverable line
# information (the cause of `getfile(::Nothing)` in Revise#931). `getfile`/`linenumber`
# return `nothing` and the frame is reported at the `none:0` sentinel.
@testset "StackFrame with missing line info" begin
    lwr = Meta.lower(@__MODULE__, :(f_missing_lineinfo(x) = x + does_not_exist(x)))
    frame = JuliaInterpreter.Frame(@__MODULE__, lwr.args[1])
    for pc in 1:length(frame.framecode.src.code)
        frame.pc = pc
        @test Base.StackTraces.StackFrame(frame) isa Base.StackTraces.StackFrame
    end
    @test JuliaInterpreter.getfirstline(frame) isa Integer
end

# issue #228: nested `@interpret` must not recursively interpret the interpreter itself
# (the frame pools are global state shared between the meta and object levels; the inner
# interpreter runs compiled via `compiled_modules`).
@testset "nested @interpret" begin
    f_228() = @interpret(1 + 1)
    @test @interpret(f_228()) == 2
    g_228() = f_228() + @interpret(2 + 2)
    @test @interpret(g_228()) == 6
end

# issue #573: a frame's recorded argument values may not match the method signature
# (e.g. while displaying a MethodError); building a `StackFrame` must not throw on
# the resulting empty type intersection.
@testset "StackFrame with mismatched argument types" begin
    f_573(x::Int) = x
    frame = JuliaInterpreter.enter_call(f_573, 1)
    frame.framedata.locals[2] = Some{Any}("not an Int")
    sf = Base.StackTraces.StackFrame(frame)
    @test sf isa Base.StackTraces.StackFrame
    @test sf.linfo isa Method
    io = IOBuffer()
    Base.show_backtrace(io, frame)
    @test !isempty(take!(io))
end

@testset "issue #701 LineNumberNode with `nothing` file" begin
    # Macros such as MacroTools' `@q`/`@qq` can emit `LineNumberNode`s whose file is
    # `nothing`; building the framecode must not choke when collecting source files.
    ex = Expr(:function, Expr(:call, :f_nothing_file),
              Expr(:block, LineNumberNode(0, nothing), :(return 701)))
    Core.eval(@__MODULE__, ex)
    @test @interpret(f_nothing_file()) == 701
end

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

# A method redefined inside the running function is not visible to the function's own
# fixed world age. Interpretation must use that same task-local world (issue #617), so the
# interpreted call sees the original `foobar`, exactly as the compiled call does.
@noinline foobar() = (GC.safepoint(); 42)
function run_foobar()
    @eval foobar() = "nope"
    return @interpret(foobar()), foobar()
end
@testset "unreachable worlds" begin
    interpret, compiled = run_foobar()
    @test interpret == compiled == 42
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

@testset "clear_caches" begin
    # `clear_caches` is not called automatically on entry to the interpreter; this test keeps it
    # exercised so it stays usable for debugging and development.
    cleared_caches(x) = x + 1
    @interpret cleared_caches(1)
    @test haskey(JuliaInterpreter.framedict, only(methods(cleared_caches)))

    bp = @breakpoint cleared_caches(1)
    @interpret cleared_caches(1)
    @test !isempty(bp.instances)

    JuliaInterpreter.clear_caches()
    @test isempty(JuliaInterpreter.framedict)
    @test isempty(JuliaInterpreter.genframedict)
    @test isempty(JuliaInterpreter.junk_framedata)
    @test isempty(JuliaInterpreter.junk_frames)
    @test isempty(bp.instances)
    remove(bp)
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
    # The local dispatch cache is keyed by method table: alternating interpreters must each
    # re-resolve `func_overlay` through their own table rather than reuse the other's cached entry.
    @test sin(42.0) == @interpret call_func_overlay(42.0)
    @test cos(42.0) == @interpret interp=OverlayInterpreter() call_func_overlay(42.0)
end

module DispatchWorldTest
    inner(::Number) = 1
    helper() = inner(1)
end

module InvokeLatestWorldTest
    const REBOUND = 1
    gen(::Any) = 1
end

@testset "invokelatest runs in the latest world" begin
    # `invokelatest`/`_call_latest` must execute their target in the latest world even when the
    # interpreter expands them. The world is raised uniformly, not keyed to the target: a builtin
    # is evaluated inline, an ordinary function in a child frame, but both see methods/bindings
    # defined since the frame's world. Each call is pinned to `world` (before the new definitions),
    # as toplevel interpretation does; the old world would yield the stale result.
    world = Base.get_world_counter()
    finish(f) = Base.invoke_in_world(world, JuliaInterpreter.finish_and_return!,
                                     JuliaInterpreter.RecursiveInterpreter(),
                                     JuliaInterpreter.enter_call(f))

    # Ordinary-function target: a more-specific method added mid-run must be dispatched to.
    # `gen` exists before `world`, so reading the binding is fine; only dispatch depends on the world.
    function dispatch_reader()
        Core.eval(InvokeLatestWorldTest, :(gen(::Int) = 2))
        return Base.invokelatest(InvokeLatestWorldTest.gen, 5)
    end
    @test finish(dispatch_reader) == 2   # the old world would dispatch to `gen(::Any) == 1`

    # Builtin target: `Base.Docs.meta` relies on this to read back a `##meta##` const it has just
    # created. A rebound const keeps its old value in the old world (Julia 1.12 partitions const
    # bindings by world), so the world of the read is observable; earlier versions reject the
    # rebinding and do not partition bindings, so the distinction does not exist there.
    if VERSION >= v"1.12"
        function binding_reader()
            Core.eval(InvokeLatestWorldTest, :(const REBOUND = 2))
            return Base.invokelatest(getglobal, InvokeLatestWorldTest, :REBOUND)
        end
        @test finish(binding_reader) == 2   # the old world would read `REBOUND == 1`
    end
end

@testset "local dispatch cache world-age invalidation" begin
    # Within a single interpretation run, defining a more-specific method must invalidate the
    # local method-table cache so a later call to the same helper dispatches to the new method.
    # This is observable when the world advances mid-run, as in toplevel/module interpretation:
    # the cached `DispatchableMethod` is stamped with its resolution world, and a higher frame
    # world forces re-resolution.
    stmts = Any[
        :(x = helper()),
        :(inner(::Int) = 2),   # advances the world age with a more-specific method
        :(y = helper()),       # must re-dispatch to `inner(::Int)`
        :(z = helper()),       # hits the refreshed cache entry at the now-current world
    ]
    frame = JuliaInterpreter.Frame(DispatchWorldTest, Expr(:toplevel, stmts...))
    JuliaInterpreter.debug_command(JuliaInterpreter.RecursiveInterpreter(), frame, :c, true)
    @test invokelatest(getproperty, DispatchWorldTest, :x) == 1
    @test invokelatest(getproperty, DispatchWorldTest, :y) == 2   # stale cache would yield 1
    @test invokelatest(getproperty, DispatchWorldTest, :z) == 2
end

module GenCacheTest
    @generated gfun(x) = :(x + 1)
    gcaller(x) = gfun(x)
end

@testset "dispatch cache keeps generator and body entries distinct" begin
    # For a `@generated` method, the same call site can be resolved in two flavors: the
    # specialized body (`enter_generated=false`) and the generator (`enter_generated=true`).
    # Both must coexist in the `DispatchableMethod` chain; if the refresh-in-place store keyed
    # on the signature alone, alternating flavors would overwrite a single entry and every
    # alternation would re-dispatch.
    m = only(methods(GenCacheTest.gcaller))
    w = Base.get_world_counter()
    fc, _ = JuliaInterpreter.prepare_framecode(m, Tuple{typeof(GenCacheTest.gcaller), Int}; world=w)
    idx = findfirst(JuliaInterpreter.is_call, fc.src.code)   # the `gfun(x)` call, the only call
    @test idx !== nothing
    chainlength(idx) = begin
        d = fc.methodtables[idx]
        n = 0
        while d !== nothing
            n += 1
            d = d.next
        end
        n
    end
    JuliaInterpreter.get_call_framecode(Any[GenCacheTest.gfun, 1], fc, idx; enter_generated=false, world=w)
    @test chainlength(idx) == 1
    JuliaInterpreter.get_call_framecode(Any[GenCacheTest.gfun, 1], fc, idx; enter_generated=true, world=w)
    @test chainlength(idx) == 2
    JuliaInterpreter.get_call_framecode(Any[GenCacheTest.gfun, 1], fc, idx; enter_generated=false, world=w)
    @test chainlength(idx) == 2   # body entry still present: pure cache hit, no third entry
    flavors = let d = fc.methodtables[idx], fl = Bool[]
        while d !== nothing
            fi = d.frameinstance
            push!(fl, fi isa JuliaInterpreter.FrameInstance && fi.enter_generated)
            d = d.next
        end
        fl
    end
    @test sort(flavors) == [false, true]
end

module WrapperDepTest
    const MYLIB = Base.Math.libm
    powf_constlib(a, b) = ccall(("powf", MYLIB), Float32, (Float32, Float32), a, b)
    powf_chainlib(a, b) = ccall(("powf", Base.Math.libm), Float32, (Float32, Float32), a, b)
    # `Int32`/`i32` keeps the signature exact on both 32- and 64-bit platforms
    # (`llvmcall` does not convert its arguments).
    const IR = """
        %3 = add i32 %0, %1
        ret i32 %3
        """
    llvmadd(x, y) = Base.llvmcall(IR, Int32, Tuple{Int32, Int32}, x, y)
end

@testset "world-bound compiled ccall/llvmcall wrappers" begin
    # Library names and llvmcall ingredients are resolved at framecode-build time and baked into
    # compiled wrappers (see `build_compiled_foreigncall!`/`build_compiled_llvmcall!`).
    @test @interpret(WrapperDepTest.powf_constlib(2f0, 3f0)) == 8f0
    @test @interpret(WrapperDepTest.powf_chainlib(2f0, 3f0)) == 8f0
    @test @interpret(WrapperDepTest.llvmadd(Int32(30), Int32(12))) == 42

    @static if JuliaInterpreter.isbindingresolved_deprecated
        # On Julia 1.12+ a `const` may be redefined, so every binding resolved at build time is
        # recorded in `FrameCode.world_deps`; redefining one must invalidate the cached framecode.
        w = Base.get_world_counter()
        mlib = only(methods(WrapperDepTest.powf_constlib))
        fc, _ = JuliaInterpreter.prepare_framecode(mlib, Tuple{typeof(WrapperDepTest.powf_constlib), Float32, Float32}; world=w)
        @test !isempty(fc.world_deps)   # the `(name, lib)` tuple resolution
        @test JuliaInterpreter.framecode_valid_world(fc, w)
        mchain = only(methods(WrapperDepTest.powf_chainlib))
        fcchain, _ = JuliaInterpreter.prepare_framecode(mchain, Tuple{typeof(WrapperDepTest.powf_chainlib), Float32, Float32}; world=w)
        @test !isempty(fcchain.world_deps)   # the `Base.Math.libm` getproperty-chain resolution

        # Rebinding the library const (e.g. after dlclosing one library and dlopening another)
        # invalidates the framecode; the rebuild resolves the new value, so the call fails on the
        # bogus path instead of silently calling into the stale library.
        Core.eval(WrapperDepTest, :(const MYLIB = "/nonexistent_library_path"))
        w2 = Base.get_world_counter()
        @test !JuliaInterpreter.framecode_valid_world(fc, w2)
        fc2, _ = JuliaInterpreter.prepare_framecode(mlib, Tuple{typeof(WrapperDepTest.powf_constlib), Float32, Float32}; world=w2)
        @test fc2 !== fc
        @test_throws "nonexistent_library_path" @interpret(WrapperDepTest.powf_constlib(2f0, 3f0))
        # An unrelated rebinding must not invalidate the chain-library framecode.
        @test JuliaInterpreter.framecode_valid_world(fcchain, w2)

        # The llvmcall IR string is likewise baked into its compiled wrapper.
        mll = only(methods(WrapperDepTest.llvmadd))
        fcll, _ = JuliaInterpreter.prepare_framecode(mll, Tuple{typeof(WrapperDepTest.llvmadd), Int32, Int32}; world=w2)
        @test !isempty(fcll.world_deps)
        Core.eval(WrapperDepTest, :(const IR = """
            %3 = sub i32 %0, %1
            ret i32 %3
            """))
        w3 = Base.get_world_counter()
        @test !JuliaInterpreter.framecode_valid_world(fcll, w3)
        # `IR` was rebound later than this testset's world; interpreting in `w3` rebuilds the
        # framecode there, so the compiled wrapper bakes in the new `sub` IR (issue #617).
        @test (@interpret world=w3 WrapperDepTest.llvmadd(Int32(30), Int32(12))) == 18
    end
end

@testset "Empty varargs are visible to locals" begin
    empty_vararg(x...) = x
    fr = JuliaInterpreter.enter_call(empty_vararg)
    @test only(filter(v -> v.name === :x, JuliaInterpreter.locals(fr))).value === ()
end

@testset "Variable equality is total" begin
    v = JuliaInterpreter.Variable(missing, :x)
    @test isequal(v, v) === true
    @test hash(v) isa UInt
    @test isequal(hash(v), hash(JuliaInterpreter.Variable(missing, :x)))
end

@testset "determine_method_for_expr does not mutate the caller's AST" begin
    kwfunc_ast(x; y=2) = x + y
    ex = Expr(:call, kwfunc_ast, Expr(:parameters, Expr(:kw, :y, 2)), 1)
    before = deepcopy(ex)
    JuliaInterpreter.determine_method_for_expr(ex)
    @test ex == before
end

@testset "Foreigncall values that look like ASTs are passed as data" begin
    astval = :(1 + 2)
    frame = Frame(Main, :(ccall(:jl_typeof, Any, (Any,), $(QuoteNode(astval)))))
    @test finish_and_return!(frame, true) === Expr
end

@static if VERSION >= v"1.12-"
@testset "invoke(f, ::Method, args...)" begin
    invoke_by_method(x::Real) = x + 1
    m = only(methods(invoke_by_method))
    invoke_by_method_wrap(f, m, x) = invoke(f, m, x)
    @test (@interpret invoke_by_method_wrap(invoke_by_method, m, 1)) == 2
end
end

@testset "NewvarNode undefines a reused slot" begin
    function newvar_reuse(flags)
        out = Bool[]
        for flag in flags
            flag && (x = 1)
            push!(out, @isdefined(x))
        end
        out
    end
    fr = JuliaInterpreter.enter_call(newvar_reuse, [true, false])
    @test finish_and_return!(fr) == newvar_reuse([true, false]) == [true, false]
end

@testset "Nested OpaqueClosure calls" begin
    oc = Base.Experimental.@opaque (x, y) -> x + y
    oc_wrapper(f, x, y) = f(x, y)
    @test (@interpret oc_wrapper(oc, 1, 2)) == 3
    @test (@interpret interp=NonRecursiveInterpreter() oc_wrapper(oc, 1, 2)) == 3
end

@static if VERSION >= v"1.12-"
@testset "Calling convention is part of the compiled-ccall wrapper key" begin
    ccall_plain() = @ccall jl_gc_safepoint()::Cvoid
    ccall_gcsafe() = @ccall gc_safe=true jl_gc_safepoint()::Cvoid
    @interpret ccall_plain()
    @interpret ccall_gcsafe()
    ccs = [k for k in keys(JuliaInterpreter.compiled_calls) if occursin("jl_gc_safepoint", string(k[1]))]
    # the two ccalls differ only in the calling-convention field and must not share a wrapper
    @test length(unique(last.(ccs))) >= 2
end
end

@testset "rethrow() from a callee of a catch block" begin
    rethrow_callee() = rethrow()
    rethrow_caller() = try; error("boom"); catch; rethrow_callee(); end
    @test_throws ErrorException("boom") finish_and_return!(JuliaInterpreter.enter_call(rethrow_caller))
end

@testset "applicable respects the frame world" begin
    @eval module ApplicableWorld
    function target end
    probe() = applicable(target, 1)
    end
    w = Base.get_world_counter()
    @eval ApplicableWorld target(::Int) = 1
    @test Base.invoke_in_world(w, ApplicableWorld.probe) == false
    @test finish_and_return!(JuliaInterpreter.enter_call(ApplicableWorld.probe; world=w)) == false
end

@testset "@interpret compiled fallback stays in the caller's world" begin
    @eval world_fallback(::Any) = 1
    m_fb = which(world_fallback, Tuple{Any})
    push!(JuliaInterpreter.compiled_methods, m_fb)
    try
        function world_fallback_root()
            @eval world_fallback(::Int) = 2
            (@interpret(world_fallback(1)), world_fallback(1))
        end
        a, b = world_fallback_root()
        @test a == b
    finally
        delete!(JuliaInterpreter.compiled_methods, m_fb)
    end
end

@testset "invoke selects its method in the frame world" begin
    @eval module InvokeWorld
    function target end
    probe(x) = invoke(target, Tuple{Real}, x)
    end
    w = Base.get_world_counter()
    @eval InvokeWorld target(::Real) = :too_new
    @test_throws MethodError Base.invoke_in_world(w, InvokeWorld.probe, 1)
    @test_throws MethodError finish_and_return!(JuliaInterpreter.enter_call(InvokeWorld.probe, 1; world=w))
    # the resolved form still works at the current world
    @test finish_and_return!(JuliaInterpreter.enter_call(InvokeWorld.probe, 1)) === :too_new
end

@testset "pop_exception restores the active-exception stack" begin
    function nested_rethrow()
        try
            error("outer")
        catch
            try
                error("inner")
            catch
            end
            rethrow()
        end
    end
    native = try nested_rethrow() catch err; err.msg end
    interp = try finish_and_return!(JuliaInterpreter.enter_call(nested_rethrow)) catch err; (err::ErrorException).msg end
    @test native == interp == "outer"

    # rethrow() from a callee, after an inner catch completed first
    popexc_callee() = rethrow()
    function popexc_caller()
        try
            error("outer")
        catch
            try error("inner") catch end
            popexc_callee()
        end
    end
    @test_throws ErrorException("outer") finish_and_return!(JuliaInterpreter.enter_call(popexc_caller))
end

@testset "invoke builtin dispatches in the frame's world" begin
    w_before = Base.get_world_counter()
    @eval invoke_wtarget(::Real) = :ok
    @eval invoke_wprobe(x) = invoke(invoke_wtarget, Tuple{Real}, x)
    fr = JuliaInterpreter.enter_call(invoke_wprobe, 1)
    # The task runs in a world predating the target method; the builtin must
    # nevertheless dispatch `invoke` in the frame's (newer) world.
    res = Base.invoke_in_world(w_before, JuliaInterpreter.finish_and_return!, NonRecursiveInterpreter(), fr)
    @test res === :ok
end

@testset "UndefVarError carries the scope for unbound sparams and locals" begin
    unbound_sp_g(x::T, y::T) where {S,T>:S} = T
    expected_sp = VERSION >= v"1.11" ? UndefVarError(:T, :static_parameter) : UndefVarError(:T)
    @test_throws expected_sp @interpret unbound_sp_g(1, 1)
    function undef_local_f(c)
        c && (x = 1)
        return x
    end
    expected_local = VERSION >= v"1.11" ? UndefVarError(:x, :local) : UndefVarError(:x)
    @test_throws expected_local @interpret undef_local_f(false)
end

@testset "current_exceptions sees interpreted handlers" begin
    function curexc_f()
        try
            error("boom")
        catch
            Base.current_exceptions()
        end
    end
    stack = @interpret curexc_f()
    @test length(stack) == 1
    @test stack[end].exception == ErrorException("boom")
    function curexc_nested()
        try
            error("outer")
        catch
            try
                error("inner")
            catch
                length(Base.current_exceptions())
            end
        end
    end
    @test (@interpret curexc_nested()) == curexc_nested() == 2
    curexc_callee() = length(Base.current_exceptions())
    curexc_caller() = try; error("x"); catch; curexc_callee(); end
    @test (@interpret curexc_caller()) == curexc_caller() == 1
    @test isempty(@interpret (() -> Base.current_exceptions())())
end

@static if hasfield(Core.CodeInfo, :nargs)
@testset "generated function returning another method's CodeInfo" begin
    overdubbee54341(a, b) = a + b
    overdubbee_ci = code_lowered(overdubbee54341, Tuple{Any,Any})[1]
    overdub_gen54341(world::UInt, source::Method, selftype, fargtypes) = copy(overdubbee_ci)
    @eval function overdub54341(args...)
        $(Expr(:meta, :generated, overdub_gen54341))
        $(Expr(:meta, :generated_only))
    end
    # the returned CodeInfo's nargs/isva (2 args, not vararg) differ from the
    # generated method's signature; the frame must follow the CodeInfo
    @test (@interpret overdub54341(1, 2)) == 3
end
end

@testset "cglobal loaded through getproperty" begin
    # Core.io_pointer fetches the cglobal intrinsic via getproperty, so the call's
    # function position is an SSA reference rather than a literal
    @test (@interpret Core.io_pointer(Core.stdout)) == Core.io_pointer(Core.stdout)
    buf = IOBuffer()
    @test sprint(io -> (@interpret Base.println(io, "x"))) == "x\n"
end

@testset "callback-taking builtins dispatch op in the frame's world" begin
    w_before = Base.get_world_counter()
    @eval cbworld_swap(a, b) = b
    @eval function cbworld_ptrmodify()
        r = Ref{Int}(1)
        GC.@preserve r begin
            p = Base.unsafe_convert(Ptr{Int}, r)
            Core.Intrinsics.atomic_pointermodify(p, cbworld_swap, 42, :sequentially_consistent)
        end
    end
    fr = JuliaInterpreter.enter_call(cbworld_ptrmodify)
    res = Base.invoke_in_world(w_before, JuliaInterpreter.finish_and_return!, NonRecursiveInterpreter(), fr)
    @test res == (1 => 42)
    @eval cbworld_op(a, b) = a + b
    @eval mutable struct CBWorldMF; @atomic x::Int; end
    @eval cbworld_mf(m) = modifyfield!(m, :x, cbworld_op, 5, :sequentially_consistent)
    fr = JuliaInterpreter.enter_call(Main.cbworld_mf, Main.CBWorldMF(2))
    res = Base.invoke_in_world(w_before, JuliaInterpreter.finish_and_return!, NonRecursiveInterpreter(), fr)
    @test res == (2 => 7)
end

@testset "ccall with a library referenced through a global" begin
    # `libjulia` (not `libjulia-internal`): Windows' GetProcAddress does not search a
    # module's dependencies, so the symbol must be exported by the named library itself
    @eval const resolvefc_lib = "libjulia"
    @eval resolvefc_f() = ccall((:jl_ver_major, resolvefc_lib), Cint, ())
    # the (name, lib) tuple lowers with the tuple constructor as a GlobalRef
    @test (@interpret Main.resolvefc_f()) == Main.resolvefc_f()
end

@testset "rethrow does not duplicate active-exception entries" begin
    function fin_count()
        local a, b
        try
            try
                error("A")
            finally
                a = length(Base.current_exceptions())
            end
        catch
            b = length(Base.current_exceptions())
        end
        (a, b)
    end
    @test (@interpret fin_count()) == fin_count() == (1, 1)
    function throw_same()  # a fresh `throw` of the same object does push
        try
            try
                error("A")
            catch err
                throw(err)
            end
        catch
            length(Base.current_exceptions())
        end
    end
    @test (@interpret throw_same()) == throw_same() == 2
    function rethrow_other()  # `rethrow(exc)` replaces the current exception
        try
            try
                error("A")
            catch
                rethrow(ErrorException("B"))
            end
        catch exc
            (exc, Base.current_exceptions()[end].exception)
        end
    end
    @test (@interpret rethrow_other()) == rethrow_other() ==
          (ErrorException("B"), ErrorException("B"))
end

@testset "is_global_ref_egal tolerates bindings newer than the world" begin
    w_before = Base.get_world_counter()
    @eval module GREgalTest end
    @eval GREgalTest using Base: llvmcall
    g = GlobalRef(GREgalTest, :llvmcall)
    @test JuliaInterpreter.is_global_ref_egal(g, :llvmcall, Base.llvmcall, Base.get_world_counter())
    # probing in a world predating the import must not throw; only world-partitioned
    # bindings (1.12+) can also see that the binding did not exist back then
    @static if VERSION >= v"1.12-"
        @test !JuliaInterpreter.is_global_ref_egal(g, :llvmcall, Base.llvmcall, w_before)
    else
        @test JuliaInterpreter.is_global_ref_egal(g, :llvmcall, Base.llvmcall, w_before)
    end
end

@testset "opaque closure creation in interpreted code" begin
    oc_maker(x) = Base.Experimental.@opaque (y) -> x + y
    oc = @interpret oc_maker(2)
    @test oc isa Core.OpaqueClosure
    @test oc(3) == 5
    @test (@interpret (f -> f(3))(oc)) == 5
    oc2 = @interpret (() -> Base.Experimental.@opaque (a, b) -> a * b)()
    @test oc2(6, 7) == 42
    # the raw Expr form with an unevaluated :opaque_closure_method (opaque_closure.jl style);
    # the `allow_partial` boolean operand only exists on 1.12+
    ci = code_lowered(() -> 1)[1]
    ocm = Expr(:opaque_closure_method, nothing, 0, false, LineNumberNode(1, :none), ci)
    ocex = VERSION >= v"1.12-" ? Expr(:new_opaque_closure, Tuple{}, Union{}, Any, true, ocm) :
                                 Expr(:new_opaque_closure, Tuple{}, Union{}, Any, ocm)
    @eval oc_from_raw_expr() = $ocex
    @test (@interpret Main.oc_from_raw_expr())() == 1
end
