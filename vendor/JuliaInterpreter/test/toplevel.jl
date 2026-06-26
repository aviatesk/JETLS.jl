using JuliaInterpreter: isdefinedglobal

if !isdefinedglobal(@__MODULE__, :read_and_parse)
    include("utils.jl")
end

module JIVisible
module JIInvisible
end
end

@testset "Basics" begin
    @test JuliaInterpreter.is_doc_expr(:(@doc "string" sum))
    @test JuliaInterpreter.is_doc_expr(:(Core.@doc "string" sum))
    ex = quote
        """
        a docstring
        """
        sum
    end
    @test JuliaInterpreter.is_doc_expr(ex.args[2])
    @test !JuliaInterpreter.is_doc_expr(:(1+1))
    # https://github.com/JunoLab/Juno.jl/issues/271
    ex = quote
        """
        Special Docstring
        """
        module DocStringTest
        function foo()
            x = 4 + 5
        end
        end
    end
    modexs = collect(ExprSplitter(JIVisible, ex))
    m, ex = first(modexs)        # FIXME don't use index in tests
    @test JuliaInterpreter.is_doc_expr(ex.args[2])
    Core.eval(m, ex)
    io = IOBuffer()
    show(io, @doc(JIVisible.DocStringTest))
    @test occursin("Special", String(take!(io)))

    ex = Base.parse_input_line("""
        "docstring"
        module OuterModDocstring
            "docstring for InnerModDocstring"
            module InnerModDocstring
            end
        end
        """)
    modexs = collect(ExprSplitter(JIVisible, ex))
    @test isdefinedglobal(JIVisible, :OuterModDocstring)
    @test isdefinedglobal(JIVisible.OuterModDocstring, :InnerModDocstring)

    # issue #538
    @test !JuliaInterpreter.is_doc_expr(:(Core.@doc "string"))
    ex = quote
        @doc("no docstring")

        sum
    end
    modexs = collect(ExprSplitter(Main, ex))
    m, ex = first(modexs)       # FIXME don't use index in tests
    @test !JuliaInterpreter.is_doc_expr(ex.args[2])

    @test !isdefinedglobal(Main, :JIInvisible)
    collect(ExprSplitter(JIVisible, :(module JIInvisible f() = 1 end)))  # this looks up JIInvisible rather than create it
    @test !isdefinedglobal(Main, :JIInvisible)
    @test  isdefinedglobal(JIVisible, :JIInvisible)
    mktempdir() do path
        push!(LOAD_PATH, path)
        open(joinpath(path, "TmpPkg1.jl"), "w") do io
            println(io, """
                    module TmpPkg1
                    using TmpPkg2
                    end
                    """)
        end
        open(joinpath(path, "TmpPkg2.jl"), "w") do io
            println(io, """
                    module TmpPkg2
                    f() = 1
                    end
                    """)
        end
        @eval using TmpPkg1
        # Every package is technically parented in Main but the name may not be visible in Main
        @test @eval isdefinedglobal(@__MODULE__, :TmpPkg1)
        @test @eval !isdefinedglobal(@__MODULE__, :TmpPkg2)
        collect(ExprSplitter(@__MODULE__, quote
                module TmpPkg2
                f() = 2
                end
            end))
        @test @eval isdefinedglobal(@__MODULE__, :TmpPkg1)
        @test @eval !isdefinedglobal(@__MODULE__, :TmpPkg2)
    end

    # Revise issue #718
    ex = Base.parse_input_line("""
        module TestPkg718

        module TestModule718
            export _VARIABLE_UNASSIGNED
            global _VARIABLE_UNASSIGNED = -84.0
        end

        using .TestModule718

        end
        """)
    for (mod, ex) in ExprSplitter(JIVisible, ex)
        @test JuliaInterpreter.finish!(Frame(mod, ex), true) === nothing
    end
    @test JIVisible.TestPkg718._VARIABLE_UNASSIGNED == -84.0
end

module Toplevel end
module ToplevelDirect end

# Drive a whole `:toplevel` expression two ways: the historical `ExprSplitter` trampoline
# (still used by Revise to chunk source into top-level expressions) and direct surface
# interpretation as a single `Frame` (the default for `Frame(mod, ::Expr)`). Evaluating the
# same source through both paths into independent modules checks that the direct path
# reproduces the observable results of the established path.
function eval_via_exprsplitter!(mod::Module, ex)
    for (m, e) in ExprSplitter(mod, ex)
        # Build each frame in the latest world so framecode construction (e.g. resolving a
        # `struct`'s supertype) sees the modules/types defined by earlier statements; `Frame`
        # otherwise captures the caller's task world, which is frozen across this loop.
        frame = Frame(m, e; world=Base.get_world_counter())
        while true
            invokelatest(JuliaInterpreter.through_methoddef_or_done!, frame) === nothing && break
        end
    end
    return nothing
end

eval_via_direct_frame!(mod::Module, ex) =
    invokelatest(JuliaInterpreter.finish_and_return!, Frame(mod, ex), true)

# Pair each evaluator with the module it should populate, for parametrized dual-path testsets.
toplevel_eval_pairs(m_split::Module, m_direct::Module) =
    ((m_split, eval_via_exprsplitter!), (m_direct, eval_via_direct_frame!))

# Assertions on the bindings and methods defined by `toplevel_script.jl`, parametrized on the
# module the script was evaluated into so the same checks apply to both evaluation paths.
function check_toplevel_script(M::Module)
    @test isconst(M, :StructParent)
    @test isconst(M, :Struct)
    @test isconst(M, :MyInt8)

    s = M.Struct([2.0])

    @test M.f1(0) == 1
    @test M.f1(0.0) == 2
    @test M.f1(0.0f0) == 3
    @test M.f2("hi") == -1
    @test M.f2(UInt16(1)) == UInt16
    @test M.f2(3.2) == 0
    @test M.f2(view([1,2], 1:1)) == 2
    @test M.f2([1,2]) == 3
    @test M.f2(reshape(view([1,2], 1:2), 2, 1)) == 4
    @test M.f3(1, 1) == 1
    @test M.f3(1, :hi) == 2
    @test M.f3(UInt16(1), :hi) == Symbol
    @test M.f3(rand(2, 2), :hi, :there) == 2
    @test_throws MethodError M.f3([1.0], :hi, :there)
    @test M.f4(1, 1.0) == 1
    @test M.f4(1, 1) == M.f4(1) == 2
    @test M.f4(UInt(1), "hey", 2) == 3
    @test M.f4(rand(2,2)) == 2
    @test M.f5(Int8(1); y=22) == 22
    @test M.f5(Int16(1)) == 2
    @test M.f5(Int32(1)) == 3
    @test M.f5(Int64(1)) == 4
    @test M.f5(rand(2,2); y=7) == 2
    @test M.f6(1, "hi"; z=8) == 1
    @test M.f7(1, (1, :hi)) == 1
    @test M.f8(0) == 1
    @test M.f9(3) == 9
    @test M.f9(3.0) == 3.0
    @test s("hello") == [2.0]
    @test M.Struct{Float32}(Dict(1=>"two")) == 4
    @test M.first_two_funcs == (M.f1, M.f2)
    @test isconst(M, :first_two_funcs)
    @test M.myint isa M.MyInt8
    @test_throws UndefVarError M.ffalse(1)
    @test M.ftrue(1) == 3
    @test M.fctrue(0) == 1
    @test_throws UndefVarError M.fcfalse(0)
    # `Consts` was defined by the interpreter above, in a world later than this testset's,
    # so its binding must be resolved in the latest world to be seen (issue #617).
    @test !invokelatest(() -> M.Consts.b2)
    @test M.fb1true(0) == 1
    @test_throws UndefVarError M.fb1false(0)
    @test M.fb2false(0) == 1
    @test_throws UndefVarError M.fb2true(0)
    @test M.fstrue(0) == 1
    @test M.fouter(1) === 2
    @test M.feval1(1.0) === 1
    @test M.feval1(1.0f0) === 1
    @test_throws MethodError M.feval1(1)
    @test M.feval2(1.0, Int8(1)) == 2
    @test length(s) === nothing
    @test size(s) === nothing
    @test M.nbytes(Float32) == 4
    @test M.typestring(1.0) == "Float64"
    @test M._feval3(0) == 3
    @test M.feval_add!(0) == 1
    @test M.feval_min!(0) == 1
    @test M.paramtype(Vector{Int8}) == Int8
    @test M.paramtype(Vector) == M.NoParam
    @test M.Inner.g() == 5
    @test M.Inner.InnerInner.g() == 6
    @test isdefinedglobal(M, :Beat)
    @test invokelatest(() -> M.Beat <: M.DatesMod.Period)

    @test @interpret(M.f1(0)) == 1
    @test @interpret(M.f1(0.0)) == 2
    @test @interpret(M.f1(0.0f0)) == 3
    @test @interpret(M.f2("hi")) == -1
    @test @interpret(M.f2(UInt16(1))) == UInt16
    @test @interpret(M.f2(3.2)) == 0
    @test @interpret(M.f2(view([1,2], 1:1))) == 2
    @test @interpret(M.f2([1,2])) == 3
    @test @interpret(M.f2(reshape(view([1,2], 1:2), 2, 1))) == 4
    @test @interpret(M.f3(1, 1)) == 1
    @test @interpret(M.f3(1, :hi)) == 2
    @test @interpret(M.f3(UInt16(1), :hi)) == Symbol
    @test @interpret(M.f3(rand(2, 2), :hi, :there)) == 2
    @test_throws MethodError @interpret(M.f3([1.0], :hi, :there))
    @test @interpret(M.f4(1, 1.0)) == 1
    @test @interpret(M.f4(1, 1)) == @interpret(M.f4(1)) == 2
    @test @interpret(M.f4(UInt(1), "hey", 2)) == 3
    @test @interpret(M.f4(rand(2,2))) == 2
    @test @interpret(M.f5(Int8(1); y=22)) == 22
    @test @interpret(M.f5(Int16(1))) == 2
    @test @interpret(M.f5(Int32(1))) == 3
    @test @interpret(M.f5(Int64(1))) == 4
    @test @interpret(M.f5(rand(2,2); y=7)) == 2
    @test @interpret(M.f6(1, "hi"; z=8)) == 1
    @test @interpret(M.f7(1, (1, :hi))) == 1
    @test @interpret(M.f8(0)) == 1
    @test @interpret(M.f9(3)) == 9
    @test @interpret(M.f9(3.0)) == 3.0
    @test @interpret(s("hello")) == [2.0]
    @test @interpret(M.Struct{Float32}(Dict(1=>"two"))) == 4
    @test_throws UndefVarError @interpret(M.ffalse(1))
    @test @interpret(M.ftrue(1)) == 3
    @test @interpret(M.fctrue(0)) == 1
    @test_throws UndefVarError @interpret(M.fcfalse(0))
    @test @interpret(M.fb1true(0)) == 1
    @test_throws UndefVarError @interpret(M.fb1false(0))
    @test @interpret(M.fb2false(0)) == 1
    @test_throws UndefVarError @interpret(M.fb2true(0))
    @test @interpret(M.fstrue(0)) == 1
    @test @interpret(M.fouter(1)) === 2
    @test @interpret(M.feval1(1.0)) === 1
    @test @interpret(M.feval1(1.0f0)) === 1
    @test_throws MethodError @interpret(M.feval1(1))
    @test @interpret(M.feval2(1.0, Int8(1))) == 2
    @test @interpret(length(s)) === nothing
    @test @interpret(size(s)) === nothing
    @test @interpret(M.nbytes(Float32)) == 4
    @test @interpret(M.typestring(1.0)) == "Float64"
    @test @interpret(M._feval3(0)) == 3
    @test @interpret(M.feval_add!(0)) == 1
    @test @interpret(M.feval_min!(0)) == 1
    @test @interpret(M.paramtype(Vector{Int8})) == Int8
    @test @interpret(M.paramtype(Vector)) == M.NoParam
    @test @interpret(M.Inner.g()) == 5
    @test @interpret(M.Inner.InnerInner.g()) == 6
    # FIXME: even though they pass, these tests break Test!
    # @test @interpret(isdefinedglobal(M, :Beat))
    # @test @interpret(M.Beat <: M.DatesMod.Period)
    return nothing
end

@testset "toplevel ($(nameof(M)))" for (M, eval!) in toplevel_eval_pairs(Toplevel, ToplevelDirect)
    eval!(M, read_and_parse(joinpath(@__DIR__, "toplevel_script.jl")))
    # The script's methods/bindings are defined in a world later than this testset's frozen
    # one, so run the checks in the latest world (sampled now) to see them (issue #617).
    invokelatest(check_toplevel_script, M)

    # Check that nested expressions are handled appropriately (a `using` guarded by an `if`
    # inside a module body).
    ex = Expr(:toplevel, :(module Testing
        if true
            using JuliaInterpreter
        end
    end))
    eval!(M, ex)
    @test invokelatest(() -> M.Testing.Frame) === Frame
end

# Proper handling of namespaces
# https://github.com/timholy/Revise.jl/issues/579
module Namespace end
@testset "Namespace" begin
    frame = Frame(Namespace, :(sin(::Int) = 10))
    while true
        JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
    end
    @test Namespace.sin(0) == 10
    @test Base.sin(0) == 0
end
# When retrospectively parsing through modules to analyze code, Julia's stdlibs pose a bit
# of a namespace challenge too: we never want to redefine new modules with the same name.
@testset "Namespace stdlibs" begin
    # Get the "real" LibCURL_jll module (Julia 1.6 and higher)
    modref = nothing
    for (id, mod) in Base.loaded_modules
        if id.name == "LibCURL_jll"
            modref = mod
            break
        end
    end
    if modref !== nothing
        # Now try to find it by splitting
        exsplit = JuliaInterpreter.ExprSplitter(Base.__toplevel__, :(
            baremodule LibCURL_jll
            using Base
            Base.Experimental.@compiler_options compile=min optimize=0 infer=false
            end))
        (mod1, ex1), state1 = iterate(exsplit)
        @test mod1 === modref
    end
end

# incremental interpretation solves world-age problems
# Taken straight from Julia's test/tuple.jl
module IncTest
using Test

struct A_15703{N}
    keys::NTuple{N, Int}
end

struct B_15703
    x::A_15703
end
end

ex = quote
    @testset "issue #15703" begin
        function bug_15703(xs...)
            [x for x in xs]
        end

        function test_15703()
            s = (1,)
            a = A_15703(s)
            ss = B_15703(a).x.keys
            @test ss === s
            bug_15703(ss...)
        end

        test_15703()
    end
end
modexs = collect(ExprSplitter(IncTest, ex))
for (i, (mod, ex)) in enumerate(modexs)
    local frame = Frame(mod, ex)
    while true
        JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
    end
    if i == length(modexs)
        @test isa(JuliaInterpreter.get_return(frame), Test.DefaultTestSet)
    end
end

module EnumSplit end
module EnumDirect end
@testset "Enum ($(nameof(M)))" for (M, eval!) in toplevel_eval_pairs(EnumSplit, EnumDirect)
    eval!(M, Expr(:toplevel,
        :(@enum EnumParent begin
              EnumChild0
              EnumChild1
          end)))
    @test invokelatest(() -> isa(M.EnumChild1, M.EnumParent))
end

module LowerAnon
ret = Ref{Any}(nothing)
end
module LowerAnonDirect
ret = Ref{Any}(nothing)
end
@testset "Anonymous functions ($(nameof(M)))" for (M, eval!) in toplevel_eval_pairs(LowerAnon, LowerAnonDirect)
    eval!(M, Expr(:toplevel,
        :(f = x -> parse(Int16, x)),
        :(ret[] = map(f, AbstractString[]))))
    @test isa(M.ret[], Vector{Int16})
    M.ret[] = nothing

    eval!(M, Expr(:toplevel, :(ret[] = map(x->parse(Int16, x), AbstractString[]))))
    @test isa(M.ret[], Vector{Int16})
    M.ret[] = nothing

    eval!(M, Expr(:toplevel,
        :(const BitIntegerType = Union{map(T->Type{T}, Base.BitInteger_types)...})))
    @test isa(invokelatest(() -> M.BitIntegerType), Union)

    # The closure captures `y` by reference, so `map` sees `y == 3` even though `y` is
    # reassigned afterward.
    eval!(M, Expr(:toplevel,
        :(y = 3),
        :(z = map(x->x^2+y, [1,2,3])),
        :(y = 4)))
    @test invokelatest(() -> M.z) == [4,7,12]
end

module ApplyIterateSplit end
module ApplyIterateDirect end
@testset "_apply_iterate world age ($(nameof(M)))" for (M, eval!) in toplevel_eval_pairs(ApplyIterateSplit, ApplyIterateDirect)
    ex = Base.parse_input_line(raw"""
        for n = 1:4
            func_name = Symbol("fn$n")
            arg_names = Tuple(Symbol("child$j") for j in 1:n)
            @eval function $func_name(
                    w,
                    $((:($arg_name::Int) for arg_name in arg_names)...)
                )
                return (w, ($(arg_names...),))
            end
        end
        """)
    eval!(M, ex)
    @test invokelatest(() -> M.fn1(:w, 1)) == (:w, (1,))
    @test invokelatest(() -> M.fn4(:w, 1, 2, 3, 4)) == (:w, (1, 2, 3, 4))
end

@testset "Docstrings" begin
    ex = quote
        """
        A docstring
        """
        f(x) = 1

        g(T::Type) = 1
        g(x) = 2

        """
        Docstring 2
        """
        g(T::Type)

        module Sub
        """
        Docstring 3
        """
        f(x) = 2
        end
    end
    Core.eval(Toplevel, Expr(:toplevel, ex.args...))
    modexs = ExprSplitter(Toplevel, ex)
    nt = nsub = 0
    for (mod, ex) in modexs
        if JuliaInterpreter.is_doc_expr(ex.args[2])
            mod == Toplevel && (nt += 1)
            mod == Toplevel.Sub && (nsub += 1)
            ex = ex.args[2].args[4]
            ex isa Expr || continue
            ex.head === :call && continue
        end
        frame = Frame(mod, ex)
        while true
            JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
        end
    end
    @test nt == 2
    @test nsub == 1
    @test Toplevel.f("check") == 1
    @test Toplevel.Sub.f("check") == 2
end

@testset "Self referential" begin
    # Revise issue #304
    ex = :(mutable struct Node t :: Node end)
    frame = Frame(Toplevel, ex)
    JuliaInterpreter.finish!(frame, true)
    @test Toplevel.Node isa Type
end

@testset "Non-frames" begin
    ex = Base.parse_input_line("""
            \"\"\"
            An expr that produces an `export nffoo` that doesn't produce a Frame
            \"\"\"
            module NonFrame
            nfbar(x) = 1
            @deprecate nffoo nfbar
            global CoolStuff
            const thresh = 1.0
            export nfbar
            end
            """)
    modexs = ExprSplitter(Toplevel, ex)
    for (mod, ex) in modexs
        if ex.head === :global
            Core.eval(mod, ex)
            continue
        end
        frame = Frame(mod, ex)
        frame === nothing && continue
        JuliaInterpreter.finish!(frame, true)
    end
    Core.eval(Toplevel, :(using .NonFrame))
    @test isdefinedglobal(Toplevel, :nffoo)
end

@testset "LOAD_PATH and modules" begin
    tmpdir = joinpath(tempdir(), randstring())
    mkpath(tmpdir)
    push!(LOAD_PATH, tmpdir)
    filename = joinpath(tmpdir, "NewModule.jl")
    open(filename, "w") do io
        print(io, """
        module NewModule
        f() = 1
        end""")
    end
    str = read(filename, String)
    ex = Base.parse_input_line(str)
    modexs = ExprSplitter(Main, ex)
    @test !isempty(modexs)
    pop!(LOAD_PATH)
    rm(tmpdir, recursive=true)
end

@testset "`used` for abstract types" begin
    ex = :(abstract type AbstractType <: AbstractArray{Union{Int,Missing},2} end)
    frame = Frame(Toplevel, ex)
    JuliaInterpreter.finish!(frame, true)
    @test isabstracttype(Toplevel.AbstractType)
end

@testset "Recursive type definitions" begin
    # See https://github.com/timholy/Revise.jl/issues/417
    # See also the `Node` test above
    ex = :(struct RecursiveType x::Vector{RecursiveType} end)
    frame = Frame(Toplevel, ex)
    JuliaInterpreter.finish!(frame, true)
    @test Toplevel.RecursiveType(Vector{Toplevel.RecursiveType}()) isa Toplevel.RecursiveType
end

# https://github.com/timholy/Revise.jl/issues/420
module ToplevelParameters
Base.@kwdef struct MyStruct
   x::Array{<:Real, 1} = [.05]
end
end
@testset "Nested references in type definitions" begin
    ex = quote
        Base.@kwdef struct MyStruct
           x::Array{<:Real, 1} = [.05]
        end
    end
    frame = Frame(ToplevelParameters, ex)
    @test JuliaInterpreter.finish!(frame, true) === nothing
end

@testset "Issue #427" begin
    ex = :(begin
        local foo = 10
        sin(foo)
    end)
    for (mod, ex) in ExprSplitter(@__MODULE__, ex)
        @test JuliaInterpreter.finish_and_return!(Frame(mod, ex), true) == sin(10)
    end

    ex = :(begin
        3 + 7
        module Local
            local foo = 10
            sin(foo)
        end
    end)
    modexs = collect(ExprSplitter(@__MODULE__, ex))
    @test length(modexs) == 2   # FIXME don't use index in tests
    @test modexs[2][1] == getfield(@__MODULE__, :Local)
    for (mod, ex) in modexs
        @test JuliaInterpreter.finish!(Frame(mod, ex), true) === nothing
    end
    ex = :(begin
        3 + 7
        module Local
            local foo = 10
            sin(foo)
        end
        3 + 7
    end)
    modexs = collect(ExprSplitter(@__MODULE__, ex))
    @test length(modexs) == 3
end

@testset "toplevel scope annotation" begin
    ex = Base.parse_input_line("""
    global foo_g = 10
    sin(foo_g)
    """)
    modexs = collect(ExprSplitter(@__MODULE__, ex))
    for (mod, ex) in modexs
        @test JuliaInterpreter.finish!(Frame(mod, ex), true) === nothing
    end
    @test length(modexs) == 2    # FIXME don't use index in tests

    ex = Base.parse_input_line("""
    local foo = 10
    sin(42)
    """)
    modexs = collect(ExprSplitter(@__MODULE__, ex))
    for (mod, ex) in modexs
        @test JuliaInterpreter.finish!(Frame(mod, ex), true) === nothing
    end
    @test length(modexs) == 2     # FIXME don't use index in tests
end

@testset "External method tables" begin
    ex = quote
        external_foo() = 1
        Base.Experimental.@MethodTable method_table
    end
    frame = Frame(Toplevel, ex)
    JuliaInterpreter.finish!(frame, true)

    nmethods_in_overlay() = length(Base.MethodList(Toplevel.method_table).ms)
    @test nmethods_in_overlay() == 0

    ex = :(Base.Experimental.@overlay method_table external_foo() = 2)
    frame = Frame(Toplevel, ex)
    JuliaInterpreter.finish!(frame, true)
    @test nmethods_in_overlay() == 1

    ex = :(Base.Experimental.@overlay $(Toplevel.method_table) external_foo(x; y = 3) = 3 + y)
    frame = Frame(Toplevel, ex)
    JuliaInterpreter.finish!(frame, true)
    @test nmethods_in_overlay() == 3 # `external_foo(x)` and `kwcall` methods were added

    ex = :(Base.Experimental.@overlay getproperty(@__MODULE__, :method_table) external_foo(x::Int) = 4)
    frame = Frame(Toplevel, ex)
    JuliaInterpreter.finish!(frame, true)
    @test nmethods_in_overlay() == 4
end

# Need to wrap rhs of `:const` expression
let ex = :(const ___symbol___ = :___symbol___)
    @test JuliaInterpreter.finish_and_return!(Frame(@__MODULE__, ex), true) === :___symbol___
end

module UsingTest end
module ImportTest end
let ex = quote using Test end
    JuliaInterpreter.finish_and_return!(Frame(UsingTest, ex), true)
    @test @invokelatest JuliaInterpreter.isdefinedglobal(UsingTest, :Test)
end
let ex = quote import Test end
    JuliaInterpreter.finish_and_return!(Frame(ImportTest, ex), true)
    @test @invokelatest JuliaInterpreter.isdefinedglobal(ImportTest, :Test)
end

function toplevel_eval(m, x)
    modexs = ExprSplitter(m, x)
    for (mod, ex) in modexs
        frame = Frame(mod, ex)
        while true
            JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
        end
    end
end

module BareModuleTest end
module ModuleFormsTest end

@testset "Module forms" begin
    let ex = :(baremodule BareModule
            using Base
            function foo(x::Cint)
                @ccall jl_(x::Cint)::Cvoid
            end
        end)
        toplevel_eval(BareModuleTest, ex)
        @test @invokelatest(isdefinedglobal(BareModuleTest, :BareModule))
        @test @invokelatest(isdefinedglobal(@invokelatest(BareModuleTest.BareModule), :foo))
    end
    let body = Expr(:block, LineNumberNode(1, :none), :(f() = 42))
        # 3-arg form: Expr(:module, std_imports::Bool, name::Symbol, body::Expr)
        toplevel_eval(ModuleFormsTest, Expr(:toplevel, Expr(:module, true, :ThreeArgModule, body)))
        @test @invokelatest(isdefinedglobal(ModuleFormsTest, :ThreeArgModule))
        @test @invokelatest(@invokelatest(ModuleFormsTest.ThreeArgModule).f()) == 42

        if VERSION ≥ v"1.14-DEV.1836"
            # 4-arg form: Expr(:module, syntax_ver::VersionNumber, std_imports::Bool, name::Symbol, body::Expr)
            toplevel_eval(ModuleFormsTest, Expr(:toplevel, Expr(:module, v"1.14", true, :FourArgModule, body)))
            @test @invokelatest(isdefinedglobal(ModuleFormsTest, :FourArgModule))
            @test @invokelatest(@invokelatest(ModuleFormsTest.FourArgModule).f()) == 42
        end
    end
    if VERSION ≥ v"1.14-DEV.1836"
        # 4-arg :module form (with syntax version) should also work with docstrings
        ex = Base.parse_input_line("""
            "docstring"
            module OuterModDocstring4
                "docstring for InnerModDocstring4"
                module InnerModDocstring4
                end
            end
            """; mod=Main)
        # The parser should have given us the 4-arg :module form
        mod_ex = ex.args[2].args[4]
        @test mod_ex.head === :module && length(mod_ex.args) == 4
        modexs = collect(ExprSplitter(JIVisible, ex))
        @test isdefinedglobal(JIVisible, :OuterModDocstring4)
        @test isdefinedglobal(JIVisible.OuterModDocstring4, :InnerModDocstring4)
    end
end

module DirectMulti end
module DirectNest end
module DirectLocal end
module DirectKwdef end

@testset "Direct toplevel interpretation" begin
    # A whole multi-definition "file" interpreted as a single `Frame` (no `ExprSplitter`):
    # struct, multiple dispatch, parametric method, `const`, and a module-level binding that
    # calls a function defined earlier in the same frame.
    src = """
        struct Pt; x::Int; y::Int; end
        area(p::Pt) = p.x * p.y
        typ(::T) where {T} = T
        const K = 7
        v = area(Pt(3, 4))
        """
    frame = Frame(DirectMulti, Base.parse_input_line(src))
    @test frame isa Frame
    @test JuliaInterpreter.finish_and_return!(frame, true) == 12
    @test @invokelatest(isdefinedglobal(DirectMulti, :Pt))
    @test @invokelatest(DirectMulti.v) == 12
    @test @invokelatest(DirectMulti.area(DirectMulti.Pt(2, 5))) == 10
    @test @invokelatest(DirectMulti.typ(1.0)) === Float64
    @test @invokelatest(DirectMulti.K) == 7

    # Nested modules interpreted as a single `Frame`.
    srcn = """
        module Inner
            inner_f() = 10
            module Deep
                deep_v = 99
            end
        end
        outer = Inner.inner_f() + Inner.Deep.deep_v
        """
    JuliaInterpreter.finish_and_return!(Frame(DirectNest, Base.parse_input_line(srcn)), true)
    @test @invokelatest(isdefinedglobal(DirectNest, :Inner))
    @test @invokelatest(isdefinedglobal(DirectNest.Inner, :Deep))
    @test @invokelatest(DirectNest.outer) == 109

    # Issue #427: a `local` in a toplevel block must not leak to module scope.
    JuliaInterpreter.finish_and_return!(Frame(DirectLocal, Expr(:toplevel, :(local foo = 10; bar = sin(foo)))), true)
    @test !@invokelatest(isdefinedglobal(DirectLocal, :foo))
    @test @invokelatest(DirectLocal.bar) == sin(10)

    # A macrocall expanding to multiple definitions (constructors + keyword defaults).
    srck = """
        Base.@kwdef struct KW; a::Int = 1; b::Int = 2; end
        p = KW(); q = KW(a = 10)
        """
    JuliaInterpreter.finish_and_return!(Frame(DirectKwdef, Base.parse_input_line(srck)), true)
    @test @invokelatest(DirectKwdef.p) == @invokelatest(DirectKwdef.KW(1, 2))
    @test @invokelatest(DirectKwdef.q) == @invokelatest(DirectKwdef.KW(10, 2))
end

# Targeted coverage of the direct surface-interpretation path (`step_toplevel!` /
# `interpret_toplevel_stmt!` / `find_or_create_module`) for cases the dual-path testsets
# above do not reach: error propagation, module reopening, and bare import/export/public/
# literal statements fed as surface `:toplevel` expressions.
module DirectSurface end
@testset "Direct toplevel surface paths" begin
    # A runtime error in a surface statement propagates through `step_toplevel!`'s handler.
    @test_throws "boom" JuliaInterpreter.finish_and_return!(
        Frame(DirectSurface, Expr(:toplevel, :(error("boom")))), true)

    # A statement that lowering rejects surfaces as an `ArgumentError`.
    @test_throws "lowering returned an error" JuliaInterpreter.finish_and_return!(
        Frame(DirectSurface, Expr(:toplevel, :(1 = 2))), true)

    # A bare literal statement is evaluated and returned.
    @test JuliaInterpreter.finish_and_return!(
        Frame(DirectSurface, Expr(:toplevel, 42)), true) == 42

    # Reopening a module: the second `:module` declaration reuses the existing module rather
    # than creating a new one, so bindings from both declarations coexist.
    JuliaInterpreter.finish_and_return!(
        Frame(DirectSurface, Expr(:toplevel, :(module Reopened; a = 1; end))), true)
    mod1 = invokelatest(getglobal, DirectSurface, :Reopened)
    JuliaInterpreter.finish_and_return!(
        Frame(DirectSurface, Expr(:toplevel, :(module Reopened; b = 2; end))), true)
    @test invokelatest(getglobal, DirectSurface, :Reopened) === mod1
    @test invokelatest(() -> mod1.a) == 1
    @test invokelatest(() -> mod1.b) == 2

    # `import`/`export`/`public` are handled directly as surface statements.
    JuliaInterpreter.finish_and_return!(
        Frame(DirectSurface, Expr(:toplevel, :(import Base.Iterators))), true)
    @test invokelatest(isdefinedglobal, DirectSurface, :Iterators)
    @test JuliaInterpreter.finish_and_return!(
        Frame(DirectSurface, Expr(:toplevel, :(export some_unbound_sym))), true) === nothing
    @static if VERSION >= v"1.11"
        @test JuliaInterpreter.finish_and_return!(
            Frame(DirectSurface, Expr(:toplevel, Expr(:public, :pubsym))), true) === nothing
    end

    # `whereis` on a toplevel-surface frame reads the surface `LineNumberNode`s directly.
    fr = JuliaInterpreter.toplevel_frame(DirectSurface, Any[LineNumberNode(7, :somefile), :(x = 1)])
    @test JuliaInterpreter.whereis(fr, 2) == ("somefile", 7)
end
