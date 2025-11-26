module Signatures

using LoweredCodeUtils
using InteractiveUtils
using CodeTracking: MethodInfoKey
using JuliaInterpreter
using Core: CodeInfo
using Base.Meta: isexpr
using Test

module Lowering
using Parameters
struct Caller end
struct Gen{T} end
end

# Stuff for https://github.com/timholy/Revise.jl/issues/422
module Lowering422
const LVec{N, T} = NTuple{N, Base.VecElement{T}}
const LT{T} = Union{LVec{<:Any, T}, T}
const FloatingTypes = Union{Float32, Float64}
end

bodymethtest0(x) = 0
function bodymethtest0(x)
    y = 2x
    y + x
end
bodymethtest1(x, y=1; z="hello") = 1
bodymethtest2(x, y=Dict(1=>2); z="hello") = 2
bodymethtest3(x::T, y=Dict(1=>2); z="hello") where T<:AbstractFloat = 3
# No kw but has optional args
bodymethtest4(x, y=1) = 4
bodymethtest5(x, y=Dict(1=>2)) = 5

@testset "Signatures" begin
    signatures = MethodInfoKey[]
    newcode = CodeInfo[]
    for ex in (:(f(x::Int8; y=0) = y),
               :(f(x::Int16; y::Int=0) = 2),
               :(f(x::Int32; y="hello", z::Int=0) = 3),
               :(f(x::Int64;) = 4),
               :(f(x::Array{Float64,K}; y::Int=0) where K = K),
               # Keyword-arg functions that have an anonymous function inside
               :(fanon(list; sorted::Bool=true,) = sorted ? sort!(list, by=x->abs(x)) : list),
               # Keyword & default positional args
               :(g(x, y="hello"; z::Int=0) = 1),
               # Return type annotations
               :(annot(x, y; z::Bool=false,)::Nothing = nothing),
               # Generated methods
               quote
                   @generated function h(x)
                       if x <: Integer
                           return :(x ^ 2)
                       else
                           return :(x)
                       end
                   end
               end,
               quote
                   function h(x::Int, y)
                       if @generated
                           return y <: Integer ? :(x*y) : :(x+y)
                       else
                           return 2x+3y
                       end
                   end
               end,
               :(@generated genkw(; b=2) = nothing),  # https://github.com/timholy/Revise.jl/issues/290
               # Generated constructors
               quote
                   function Gen{T}(x) where T
                       if @generated
                           return T <: Integer ? :(x^2) : :(2x)
                       else
                           return 7x
                       end
                   end
               end,
               # Conditional methods
               quote
                   if 0.8 > 0.2
                       fctrue(x) = 1
                   else
                       fcfalse(x) = 1
                   end
               end,
               # Call methods
               :((::Caller)(x::String) = length(x)),
               )
        Core.eval(Lowering, ex)
        frame = Frame(Lowering, ex)
        rename_framemethods!(frame)
        pc = methoddefs!(signatures, frame; define=false)
        push!(newcode, frame.framecode.src)
    end

    # Manually add the signature for the Caller constructor, since that was defined
    # outside of manual lowering
    push!(signatures, MethodInfoKey(nothing, Tuple{Type{Lowering.Caller}}))

    nms = names(Lowering; all=true)
    modeval, modinclude = getfield(Lowering, :eval), getfield(Lowering, :include)
    failed = []
    for fsym in nms
        f = getfield(Lowering, fsym)
        isa(f, Base.Callable) || continue
        (f === modeval || f === modinclude) && continue
        for m in methods(f)
            if MethodInfoKey(nothing, m.sig) ∉ signatures
                push!(failed, m.sig)
            end
        end
    end
    @test isempty(failed)
    # Ensure that all names are properly resolved
    for code in newcode
        Core.eval(Lowering, code)
    end
    nms2 = names(Lowering; all=true)
    @test nms2 == nms
    @test Lowering.f(Int8(0)) == 0
    @test Lowering.f(Int8(0); y="LCU") == "LCU"
    @test Lowering.f(Int16(0)) == Lowering.f(Int16(0), y=7) == 2
    @test Lowering.f(Int32(0)) == Lowering.f(Int32(0); y=22) == Lowering.f(Int32(0); y=:cat, z=5) == 3
    @test Lowering.f(Int64(0)) == 4
    @test Lowering.f(rand(3,3)) == Lowering.f(rand(3,3); y=5) == 2
    @test Lowering.fanon([1,3,-2]) == [1,-2,3]
    @test Lowering.g(0) == Lowering.g(0,"LCU") == Lowering.g(0; z=5) == Lowering.g(0,"LCU"; z=5) == 1
    @test Lowering.annot(0,0) === nothing
    @test Lowering.h(2) == 4
    @test Lowering.h(2.0) == 2.0
    @test Lowering.h(2, 3) == 6
    @test Lowering.h(2, 3.0) == 5.0
    @test Lowering.fctrue(0) == 1
    @test_throws UndefVarError Lowering.fcfalse(0)
    @test (Lowering.Caller())("Hello, world") == 12
    g = Lowering.Gen{Float64}
    @test g(3) == 6

    # Don't be deceived by inner methods
    signatures = MethodInfoKey[]
    ex = quote
        function fouter(x)
            finner(::Float16) = 2x
            return finner(Float16(1))
        end
    end
    Core.eval(Lowering, ex)
    frame = Frame(Lowering, ex)
    rename_framemethods!(frame)
    methoddefs!(signatures, frame; define=false)
    @test length(signatures) == 1
    mt, sig = first(signatures)
    @test LoweredCodeUtils.whichtt(sig, mt) == first(methods(Lowering.fouter))

    # Check output of methoddef!
    frame = Frame(Lowering, :(function nomethod end))
    ret = methoddef!(empty!(signatures), frame; define=true)
    @test isempty(signatures)
    @test ret === nothing
    frame = Frame(Lowering, :(function amethod() nothing end))
    ret = methoddef!(empty!(signatures), frame; define=true)
    @test !isempty(signatures)
    @test isa(ret, NTuple{2,Int})

    # Anonymous functions in method signatures
    ex = :(max_values(T::Union{map(X -> Type{X}, Base.BitIntegerSmall_types)...}) = 1 << (8*sizeof(T)))  # base/abstractset.jl
    frame = Frame(Base, ex)
    rename_framemethods!(frame)
    signatures = MethodInfoKey[]
    methoddef!(signatures, frame; define=false)
    @test length(signatures) == 1
    mt, sig = first(signatures)
    @test sig == which(Base.max_values, Tuple{Type{Int16}}).sig

    # define
    ex = :(fdefine(x) = 1)
    frame = Frame(Lowering, ex)
    empty!(signatures)
    methoddefs!(signatures, frame; define=false)
    @test_throws MethodError Lowering.fdefine(0)
    frame = Frame(Lowering, ex)
    empty!(signatures)
    methoddefs!(signatures, frame; define=true)
    @test Lowering.fdefine(0) == 1

    # define with correct_name!
    ex = quote
        @generated function generated1(A::AbstractArray{T,N}, val) where {T,N}
            ex = Expr(:tuple)
            for i = 1:N
                push!(ex.args, :val)
            end
            return ex
        end
    end
    frame = Frame(Lowering, ex)
    rename_framemethods!(frame)
    empty!(signatures)
    methoddefs!(signatures, frame; define=true)
    @test length(signatures) == 2
    @test Lowering.generated1(rand(2,2), 3.2) == (3.2, 3.2)
    ex = quote
        another_kwdef(x, y=1; z="hello") = 333
    end
    frame = Frame(Lowering, ex)
    rename_framemethods!(frame)
    empty!(signatures)
    methoddefs!(signatures, frame; define=true)
    @test length(signatures) == 5
    @test Lowering.another_kwdef(0) == 333
    ex = :(@generated genkw2(; b=2) = nothing)  # https://github.com/timholy/Revise.jl/issues/290
    frame = Frame(Lowering, ex)
    # rename_framemethods!(frame)
    empty!(signatures)
    methoddefs!(signatures, frame; define=true)
    @test length(signatures) == 4
    @test Lowering.genkw2() === nothing

    # Test for correct exit (example from base/namedtuples.jl)
    ex = quote
        function merge(a::NamedTuple{an}, b::NamedTuple{bn}) where {an, bn}
            if @generated
                names = merge_names(an, bn)
                types = merge_types(names, a, b)
                vals = Any[ :(getfield($(sym_in(n, bn) ? :b : :a), $(QuoteNode(n)))) for n in names ]
                :( NamedTuple{$names,$types}(($(vals...),)) )
            else
                names = merge_names(an, bn)
                types = merge_types(names, typeof(a), typeof(b))
                NamedTuple{names,types}(map(n->getfield(sym_in(n, bn) ? b : a, n), names))
            end
        end
    end
    frame = Frame(Base, ex)
    rename_framemethods!(frame)
    empty!(signatures)
    stmt = JuliaInterpreter.pc_expr(frame)
    if !LoweredCodeUtils.ismethod(stmt)
        pc = JuliaInterpreter.next_until!(LoweredCodeUtils.ismethod, frame, true)
    end
    pc, _ = methoddef!(signatures, frame; define=false)  # this tests that the return isn't `nothing`
    pc, _ = methoddef!(signatures, frame; define=false)
    @test length(signatures) == 2  # both the GeneratedFunctionStub and the main method

    # With anonymous functions in signatures
    ex = :(const BitIntegerType = Union{map(T->Type{T}, Base.BitInteger_types)...})
    frame = Frame(Lowering, ex)
    rename_framemethods!(frame)
    empty!(signatures)
    methoddefs!(signatures, frame; define=false)
    @test !isempty(signatures)

    for m in methods(bodymethtest0)
        @test bodymethod(m) === m
    end
    @test startswith(String(bodymethod(first(methods(bodymethtest1))).name), "#")
    @test startswith(String(bodymethod(first(methods(bodymethtest2))).name), "#")
    @test startswith(String(bodymethod(first(methods(bodymethtest3))).name), "#")
    @test bodymethod(first(methods(bodymethtest4))).nargs == 3  # one extra for #self#
    @test bodymethod(first(methods(bodymethtest5))).nargs == 3
    m = @which sum([1]; dims=1)
    # Issue in https://github.com/timholy/CodeTracking.jl/pull/48
    mbody = bodymethod(m)
    @test mbody != m && mbody.file != :none
    # varargs keyword methods
    m = which(Base.print_shell_escaped, (IO, AbstractString))
    mbody = bodymethod(m)
    @test isa(mbody, Method) && mbody != m

    ex = quote
        function print_shell_escaped(io::IO, cmd::AbstractString, args::AbstractString...;
                                     special::AbstractString="")
            print_shell_word(io, cmd, special)
            for arg in args
                print(io, ' ')
                print_shell_word(io, arg, special)
            end
        end
    end
    frame = Frame(Base, ex)
    rename_framemethods!(frame)
    empty!(signatures)
    methoddefs!(signatures, frame; define=false)
    @test length(signatures) >= 2

    ex = :(typedsig(x) = 1)
    frame = Frame(Lowering, ex)
    methoddefs!(signatures, frame; define=true)
    ex = :(typedsig(x::Int) = 2)
    frame = Frame(Lowering, ex)
    JuliaInterpreter.next_until!(LoweredCodeUtils.ismethod3, frame, true)
    empty!(signatures)
    methoddefs!(signatures, frame; define=true)
    mt, sig = first(signatures)
    @test sig.parameters[end] == Int

    # Multiple keyword arg methods per frame
    # (Revise issue #363)
    ex = quote
        keywrd1(x; kwarg=false) = 1
        keywrd2(x; kwarg="hello") = 2
        keywrd3(x; kwarg=:stuff) = 3
    end
    Core.eval(Lowering, ex)
    frame = Frame(Lowering, ex)
    rename_framemethods!(frame)
    empty!(signatures)
    pc, _ = methoddef!(signatures, frame; define=false)
    @test pc < length(frame.framecode.src.code)
    kw2sig = Tuple{typeof(Lowering.keywrd2), Any}
    @test MethodInfoKey(nothing, kw2sig) ∉ signatures
    pc = methoddefs!(signatures, frame; define=false)
    @test pc === nothing
    @test MethodInfoKey(nothing, kw2sig) ∈ signatures

    # Module-scoping
    ex = :(Base.@irrational π        3.14159265358979323846  pi)
    frame = Frame(Base.MathConstants, ex)
    rename_framemethods!(frame)
    empty!(signatures)
    methoddefs!(signatures, frame; define=false)
    @test !isempty(signatures)

    # Inner methods in structs. Comes up in, e.g., CC.Params.
    # The body of CustomMS is an SSAValue.
    ex = quote
        struct MyStructWithMeth
            x::Int
            global function CustomMS(;x=1)
                return new(x)
            end
            MyStructWithMeth(x) = new(x)
        end
    end
    Core.eval(Lowering, ex)
    frame = Frame(Lowering, ex)
    rename_framemethods!(frame)
    empty!(signatures)
    methoddefs!(signatures, frame; define=false)
    @test MethodInfoKey(nothing, Tuple{typeof(Lowering.CustomMS)}) ∈ signatures

    # https://github.com/timholy/Revise.jl/issues/398
    ex = quote
        @with_kw struct Items
            n::Int
            items::Vector{Int} = [i for i=1:n]
        end
    end
    Core.eval(Lowering, ex)
    frame = Frame(Lowering, ex)
    dct = rename_framemethods!(frame)
    ks = collect(filter(k->startswith(String(k.name), "#Items#"), keys(dct)))
    @test length(ks) == 2
    @test dct[ks[1]] == dct[ks[2]]
    @test ks[1].mod === ks[2].mod === Lowering
    @test isdefined(Lowering, ks[1].name) || isdefined(Lowering, ks[2].name)

    # https://github.com/timholy/Revise.jl/issues/422
    ex = :(@generated function fneg(x::T) where T<:LT{<:FloatingTypes}
         s = """
         %2 = fneg $(llvm_type(T)) %0
         ret $(llvm_type(T)) %2
         """
         return :(
             $(Expr(:meta, :inline));
             Base.llvmcall($s, T, Tuple{T}, x)
         )
     end)
    empty!(signatures)
    Core.eval(Lowering422, ex)
    frame = Frame(Lowering422, ex)
    rename_framemethods!(frame)
    pc = methoddefs!(signatures, frame; define=false)
    @test typeof(Lowering422.fneg) ∈ Set(Base.unwrap_unionall(sig).parameters[1] for (_, sig) in signatures)

    # Scoped names (https://github.com/timholy/Revise.jl/issues/568)
    ex = :(f568() = -1)
    Core.eval(Lowering, ex)
    @test Lowering.f568() == -1
    empty!(signatures)
    ex = :(f568() = -2)
    frame = Frame(Lowering, ex)
    pcstop = findfirst(LoweredCodeUtils.ismethod3, frame.framecode.src.code)
    pc = 1
    while pc < pcstop
        pc = JuliaInterpreter.step_expr!(frame, true)
    end
    pc = methoddef!(signatures, frame, pc; define=true)
    @test MethodInfoKey(nothing, Tuple{typeof(Lowering.f568)}) ∈ signatures
    @test Lowering.f568() == -2

    # Undefined names
    # This comes from FileWatching; WindowsRawSocket is only defined on Windows
    ex = quote
        if Sys.iswindows()
            using Base: WindowsRawSocket
            function wait(socket::WindowsRawSocket; readable=false, writable=false)
                fdw = _FDWatcher(socket, readable, writable)
                try
                    return wait(fdw, readable=readable, writable=writable)
                finally
                    close(fdw, readable, writable)
                end
            end
        end
    end
    frame = Frame(Lowering, ex)
    rename_framemethods!(frame)

    # https://github.com/timholy/Revise.jl/issues/550
    using Pkg
    oldenv = Pkg.project().path
    try
        # we test with the old version of CBinding, let's do it in an isolated environment
        Pkg.activate(; temp=true, io=devnull)

        @info "Adding CBinding to the environment for test purposes"
        Pkg.add(; name="CBinding", version="0.9.4", io=devnull) # `@cstruct` isn't defined for v1.0 and above

        m = Module()
        Core.eval(m, :(using CBinding))

        ex = :(@cstruct S {
            val::Int8
        })
        empty!(signatures)
        Core.eval(m, ex)
        frame = Frame(m, ex)
        rename_framemethods!(frame)
        pc = methoddefs!(signatures, frame; define=false)
        @test !isempty(signatures)   # really we just need to know that `methoddefs!` completed without getting stuck
    finally
        Pkg.activate(oldenv; io=devnull) # back to the original environment
    end
end

# https://github.com/timholy/Revise.jl/issues/643
module Revise643

using LoweredCodeUtils, JuliaInterpreter, Test

# make sure to not define `foogr` before macro expansion,
# otherwise it will be resolved as `QuoteNode`
macro deffoogr()
    gr = GlobalRef(__module__, :foogr) # will be lowered to `GlobalRef`
    quote
        $gr(args...) = length(args)
    end
end
let
    ex = quote
        @deffoogr
        @show foogr(1,2,3)
    end
    methranges = rename_framemethods!(Frame(@__MODULE__, ex))
    @test haskey(methranges, GlobalRef(@__MODULE__, :foogr))
end

function fooqn end
macro deffooqn()
    sig = :($(GlobalRef(__module__, :fooqn))(args...)) # will be lowered to `QuoteNode`
    return Expr(:function, sig, Expr(:block, __source__, :(length(args))))
end
let
    ex = quote
        @deffooqn
        @show fooqn(1,2,3)
    end
    methranges = rename_framemethods!(Frame(@__MODULE__, ex))
    @test haskey(methranges, GlobalRef(@__MODULE__, :fooqn))
end

# define methods in other module
module sandboxgr end
macro deffoogr_sandbox()
    gr = GlobalRef(sandboxgr, :foogr_sandbox) # will be lowered to `GlobalRef`
    quote
        $gr(args...) = length(args)
    end
end
let ex = quote
        @deffoogr_sandbox
        @show sandboxgr.foogr_sandbox(1,2,3)
    end
    methranges = rename_framemethods!(Frame(@__MODULE__, ex))
    @test haskey(methranges, GlobalRef(sandboxgr, :foogr_sandbox))
end

module sandboxqn; function fooqn_sandbox end; end
macro deffooqn_sandbox()
    sig = :($(GlobalRef(sandboxqn, :fooqn_sandbox))(args...)) # will be lowered to `QuoteNode`
    return Expr(:function, sig, Expr(:block, __source__, :(length(args))))
end
let
    ex = quote
        @deffooqn_sandbox
        @show sandboxqn.fooqn_sandbox(1,2,3)
    end
    methranges = rename_framemethods!(Frame(@__MODULE__, ex))
    @test haskey(methranges, GlobalRef(sandboxqn, :fooqn_sandbox))
end

end

module ExternalMT
    Base.Experimental.@MethodTable method_table
    macro overlay(ex) esc(:(Base.Experimental.@overlay $method_table $ex)) end
end

@testset "Support for external method tables" begin
    signatures = MethodInfoKey[]

    ex = :(foo(x) = "foo")
    Core.eval(ExternalMT, ex)
    frame = Frame(ExternalMT, ex)
    methoddefs!(signatures, frame; define = false)
    @test length(signatures) == 1
    (mt, sig) = pop!(signatures)
    @test (mt, sig) === (nothing, Tuple{typeof(ExternalMT.foo), Any})

    ex = :(Base.Experimental.@overlay method_table foo(x) = "overlayed foo")
    Core.eval(ExternalMT, ex)
    frame = Frame(ExternalMT, ex)
    methoddefs!(signatures, frame; define = false)
    @test length(signatures) == 1
    (mt, sig) = pop!(signatures)
    @test (mt, sig) === (ExternalMT.method_table, Tuple{typeof(ExternalMT.foo), Any})

    ex = :(@overlay foo(x::Int64) = "overlayed foo, second edition")
    Core.eval(ExternalMT, ex)
    frame = Frame(ExternalMT, ex)
    methoddefs!(signatures, frame; define = false)
    @test length(signatures) == 1
    (mt, sig) = pop!(signatures)
    @test (mt, sig) === (ExternalMT.method_table, Tuple{typeof(ExternalMT.foo), Int64})
    LoweredCodeUtils.identify_framemethod_calls(frame) # make sure this does not throw
end

end # module signatures
