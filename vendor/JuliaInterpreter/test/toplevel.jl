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

@testset "toplevel" begin
    modexs = ExprSplitter(Toplevel, read_and_parse(joinpath(@__DIR__, "toplevel_script.jl")))
    for (mod, ex) in modexs
        frame = Frame(mod, ex)
        while true
            invokelatest(JuliaInterpreter.through_methoddef_or_done!, frame) === nothing && break
        end
    end

    @test isconst(Toplevel, :StructParent)
    @test isconst(Toplevel, :Struct)
    @test isconst(Toplevel, :MyInt8)

    s = Toplevel.Struct([2.0])

    @test Toplevel.f1(0) == 1
    @test Toplevel.f1(0.0) == 2
    @test Toplevel.f1(0.0f0) == 3
    @test Toplevel.f2("hi") == -1
    @test Toplevel.f2(UInt16(1)) == UInt16
    @test Toplevel.f2(3.2) == 0
    @test Toplevel.f2(view([1,2], 1:1)) == 2
    @test Toplevel.f2([1,2]) == 3
    @test Toplevel.f2(reshape(view([1,2], 1:2), 2, 1)) == 4
    @test Toplevel.f3(1, 1) == 1
    @test Toplevel.f3(1, :hi) == 2
    @test Toplevel.f3(UInt16(1), :hi) == Symbol
    @test Toplevel.f3(rand(2, 2), :hi, :there) == 2
    @test_throws MethodError Toplevel.f3([1.0], :hi, :there)
    @test Toplevel.f4(1, 1.0) == 1
    @test Toplevel.f4(1, 1) == Toplevel.f4(1) == 2
    @test Toplevel.f4(UInt(1), "hey", 2) == 3
    @test Toplevel.f4(rand(2,2)) == 2
    @test Toplevel.f5(Int8(1); y=22) == 22
    @test Toplevel.f5(Int16(1)) == 2
    @test Toplevel.f5(Int32(1)) == 3
    @test Toplevel.f5(Int64(1)) == 4
    @test Toplevel.f5(rand(2,2); y=7) == 2
    @test Toplevel.f6(1, "hi"; z=8) == 1
    @test Toplevel.f7(1, (1, :hi)) == 1
    @test Toplevel.f8(0) == 1
    @test Toplevel.f9(3) == 9
    @test Toplevel.f9(3.0) == 3.0
    @test s("hello") == [2.0]
    @test Toplevel.Struct{Float32}(Dict(1=>"two")) == 4
    @test Toplevel.first_two_funcs == (Toplevel.f1, Toplevel.f2)
    @test isconst(Toplevel, :first_two_funcs)
    @test Toplevel.myint isa Toplevel.MyInt8
    @test_throws UndefVarError Toplevel.ffalse(1)
    @test Toplevel.ftrue(1) == 3
    @test Toplevel.fctrue(0) == 1
    @test_throws UndefVarError Toplevel.fcfalse(0)
    @test !Toplevel.Consts.b2
    @test Toplevel.fb1true(0) == 1
    @test_throws UndefVarError Toplevel.fb1false(0)
    @test Toplevel.fb2false(0) == 1
    @test_throws UndefVarError Toplevel.fb2true(0)
    @test Toplevel.fstrue(0) == 1
    @test Toplevel.fouter(1) === 2
    @test Toplevel.feval1(1.0) === 1
    @test Toplevel.feval1(1.0f0) === 1
    @test_throws MethodError Toplevel.feval1(1)
    @test Toplevel.feval2(1.0, Int8(1)) == 2
    @test length(s) === nothing
    @test size(s) === nothing
    @test Toplevel.nbytes(Float32) == 4
    @test Toplevel.typestring(1.0) == "Float64"
    @test Toplevel._feval3(0) == 3
    @test Toplevel.feval_add!(0) == 1
    @test Toplevel.feval_min!(0) == 1
    @test Toplevel.paramtype(Vector{Int8}) == Int8
    @test Toplevel.paramtype(Vector) == Toplevel.NoParam
    @test Toplevel.Inner.g() == 5
    @test Toplevel.Inner.InnerInner.g() == 6
    @test isdefinedglobal(Toplevel, :Beat)
    @test Toplevel.Beat <: Toplevel.DatesMod.Period

    @test @interpret(Toplevel.f1(0)) == 1
    @test @interpret(Toplevel.f1(0.0)) == 2
    @test @interpret(Toplevel.f1(0.0f0)) == 3
    @test @interpret(Toplevel.f2("hi")) == -1
    @test @interpret(Toplevel.f2(UInt16(1))) == UInt16
    @test @interpret(Toplevel.f2(3.2)) == 0
    @test @interpret(Toplevel.f2(view([1,2], 1:1))) == 2
    @test @interpret(Toplevel.f2([1,2])) == 3
    @test @interpret(Toplevel.f2(reshape(view([1,2], 1:2), 2, 1))) == 4
    @test @interpret(Toplevel.f3(1, 1)) == 1
    @test @interpret(Toplevel.f3(1, :hi)) == 2
    @test @interpret(Toplevel.f3(UInt16(1), :hi)) == Symbol
    @test @interpret(Toplevel.f3(rand(2, 2), :hi, :there)) == 2
    @test_throws MethodError @interpret(Toplevel.f3([1.0], :hi, :there))
    @test @interpret(Toplevel.f4(1, 1.0)) == 1
    @test @interpret(Toplevel.f4(1, 1)) == @interpret(Toplevel.f4(1)) == 2
    @test @interpret(Toplevel.f4(UInt(1), "hey", 2)) == 3
    @test @interpret(Toplevel.f4(rand(2,2))) == 2
    @test @interpret(Toplevel.f5(Int8(1); y=22)) == 22
    @test @interpret(Toplevel.f5(Int16(1))) == 2
    @test @interpret(Toplevel.f5(Int32(1))) == 3
    @test @interpret(Toplevel.f5(Int64(1))) == 4
    @test @interpret(Toplevel.f5(rand(2,2); y=7)) == 2
    @test @interpret(Toplevel.f6(1, "hi"; z=8)) == 1
    @test @interpret(Toplevel.f7(1, (1, :hi))) == 1
    @test @interpret(Toplevel.f8(0)) == 1
    @test @interpret(Toplevel.f9(3)) == 9
    @test @interpret(Toplevel.f9(3.0)) == 3.0
    @test @interpret(s("hello")) == [2.0]
    @test @interpret(Toplevel.Struct{Float32}(Dict(1=>"two"))) == 4
    @test_throws UndefVarError @interpret(Toplevel.ffalse(1))
    @test @interpret(Toplevel.ftrue(1)) == 3
    @test @interpret(Toplevel.fctrue(0)) == 1
    @test_throws UndefVarError @interpret(Toplevel.fcfalse(0))
    @test @interpret(Toplevel.fb1true(0)) == 1
    @test_throws UndefVarError @interpret(Toplevel.fb1false(0))
    @test @interpret(Toplevel.fb2false(0)) == 1
    @test_throws UndefVarError @interpret(Toplevel.fb2true(0))
    @test @interpret(Toplevel.fstrue(0)) == 1
    @test @interpret(Toplevel.fouter(1)) === 2
    @test @interpret(Toplevel.feval1(1.0)) === 1
    @test @interpret(Toplevel.feval1(1.0f0)) === 1
    @test_throws MethodError @interpret(Toplevel.feval1(1))
    @test @interpret(Toplevel.feval2(1.0, Int8(1))) == 2
    @test @interpret(length(s)) === nothing
    @test @interpret(size(s)) === nothing
    @test @interpret(Toplevel.nbytes(Float32)) == 4
    @test @interpret(Toplevel.typestring(1.0)) == "Float64"
    @test @interpret(Toplevel._feval3(0)) == 3
    @test @interpret(Toplevel.feval_add!(0)) == 1
    @test @interpret(Toplevel.feval_min!(0)) == 1
    @test @interpret(Toplevel.paramtype(Vector{Int8})) == Int8
    @test @interpret(Toplevel.paramtype(Vector)) == Toplevel.NoParam
    @test @interpret(Toplevel.Inner.g()) == 5
    @test @interpret(Toplevel.Inner.InnerInner.g()) == 6
    # FIXME: even though they pass, these tests break Test!
    # @test @interpret(isdefinedglobal(Toplevel, :Beat))
    # @test @interpret(Toplevel.Beat <: Toplevel.DatesMod.Period)

    # Check that nested expressions are handled appropriately (module-in-block, internal `using`)
    ex = quote
       module Testing
       if true
           using JuliaInterpreter
       end
       end
   end
   modexs = ExprSplitter(Toplevel, ex)
   for (mod, ex) in modexs
       frame = Frame(mod, ex)
       while true
           JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
       end
   end
   @test Toplevel.Testing.Frame === Frame
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

@testset "Enum" begin
    ex = Expr(:toplevel,
        :(@enum EnumParent begin
              EnumChild0
              EnumChild1
          end))
    modexs = ExprSplitter(Toplevel, ex)
    for (mod, ex) in modexs
        frame = Frame(mod, ex)
        while true
            JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
        end
    end
    @test isa(Toplevel.EnumChild1, Toplevel.EnumParent)
end

module LowerAnon
ret = Ref{Any}(nothing)
end

@testset "Anonymous functions" begin
    ex1 = quote
        f = x -> parse(Int16, x)
        ret[] = map(f, AbstractString[])
    end
    ex2 = quote
        ret[] = map(x->parse(Int16, x), AbstractString[])
    end
    modexs = ExprSplitter(LowerAnon, ex1)
    for (mod, ex) in modexs
        frame = Frame(mod, ex)
        while true
            JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
        end
    end
    @test isa(LowerAnon.ret[], Vector{Int16})
    LowerAnon.ret[] = nothing
    modexs = ExprSplitter(LowerAnon, ex2)
    for (mod, ex) in modexs
        frame = Frame(mod, ex)
        while true
            JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
        end
    end
    @test isa(LowerAnon.ret[], Vector{Int16})
    LowerAnon.ret[] = nothing

    ex3 = quote
        const BitIntegerType = Union{map(T->Type{T}, Base.BitInteger_types)...}
    end
    modexs = ExprSplitter(LowerAnon, ex3)
    for (mod, ex) in modexs
        frame = Frame(mod, ex)
        while true
            JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
        end
    end
    @test isa(LowerAnon.BitIntegerType, Union)

    ex4 = quote
        y = 3
        z = map(x->x^2+y, [1,2,3])
        y = 4
    end
    modexs = ExprSplitter(LowerAnon, ex4)
    for (mod, ex) in modexs
        frame = Frame(mod, ex)
        while true
            JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
        end
    end
    @test LowerAnon.z == [4,7,12]
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

module BareModuleTest end
function toplevel_eval(m, x)
    modexs = ExprSplitter(m, x)
    for (mod, ex) in modexs
        frame = Frame(mod, ex)
        while true
            JuliaInterpreter.through_methoddef_or_done!(frame) === nothing && break
        end
    end
end
let ex = :(baremodule BareModule
        using Base
        function foo(x::Cint)
            @ccall jl_(x::Cint)::Cvoid
        end
    end)
    toplevel_eval(BareModuleTest, ex)
    @test @invokelatest(JuliaInterpreter.isdefinedglobal(BareModuleTest, :BareModule)) &&
        @invokelatest(JuliaInterpreter.isdefinedglobal(@invokelatest(BareModuleTest.BareModule), :foo))
end
