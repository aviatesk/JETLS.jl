module test_builtins

# Direct tests for the branches of `maybe_evaluate_builtin` (src/builtins.jl).
# Builtins that are not available on every supported Julia version are tested only where
# they exist, using the same feature detection that guards their branches in src/builtins.jl.

using JuliaInterpreter
using JuliaInterpreter: RecursiveInterpreter, isdefinedglobal, maybe_evaluate_builtin
using InteractiveUtils: subtypes
using Test

isbuiltin(name::Symbol) = isdefined(Core, name) && getfield(Core, name) isa Core.Builtin

"""
    evalbuiltin(f, args...; world=Base.get_world_counter(), expand=false)

Evaluate the call `f(args...)` with `maybe_evaluate_builtin` in a frame whose world is `world`.
Throws if `maybe_evaluate_builtin` does not handle `f`, i.e. returns the call unevaluated.
"""
function evalbuiltin(@nospecialize(f), @nospecialize(args...);
                     world::UInt=Base.get_world_counter(), expand::Bool=false)
    frame = JuliaInterpreter.enter_call(identity, nothing; world)
    call_expr = Expr(:call, QuoteNode(f), Any[QuoteNode(arg) for arg in args]...)
    ret = maybe_evaluate_builtin(RecursiveInterpreter(), frame, call_expr, expand)
    ret isa Some{Any} || error("`maybe_evaluate_builtin` does not handle `", f, "`")
    return ret.value
end

@testset "every builtin has a branch" begin
    # Calling builtins with arbitrary arguments is unsafe (e.g. `Core._call_latest()` segfaults
    # on Julia 1.10), so pass an argument whose lookup throws: a branch looks up its arguments
    # before calling the builtin, while an unhandled call is returned without looking them up.
    arg = GlobalRef(@__MODULE__, :undefined_builtin_argument)
    frame = JuliaInterpreter.enter_call(identity, nothing)
    unhandled = Any[]
    for ft in subtypes(Core.Builtin)
        ft === Core.IntrinsicFunction && continue
        f = ft.instance
        try
            maybe_evaluate_builtin(RecursiveInterpreter(), frame, Expr(:call, QuoteNode(f), arg), false)
            push!(unhandled, f)
        catch err
            err isa UndefVarError && err.var === arg.name || push!(unhandled, f => err)
        end
    end
    @test isempty(unhandled)
end

# GenericMemory (Julia 1.11+)
# ===========================

@static if isbuiltin(:memoryrefget)
@testset "GenericMemory builtins" begin
    ref = memoryref(Memory{Int}(undef, 3))
    @test evalbuiltin(Core.memoryrefset!, ref, 1, :not_atomic, true) === 1
    @test evalbuiltin(Core.memoryrefget, ref, :not_atomic, true) === 1
    @test evalbuiltin(Core.memoryrefswap!, ref, 2, :not_atomic, true) === 1
    @test evalbuiltin(Core.memoryrefmodify!, ref, +, 3, :not_atomic, true) == (2 => 5)
    @test evalbuiltin(Core.memoryrefreplace!, ref, 5, 6, :not_atomic, :not_atomic, true) == (old = 5, success = true)
    @test evalbuiltin(Core.memoryrefreplace!, ref, 5, 7, :not_atomic, :not_atomic, true) == (old = 6, success = false)
    @test ref[] === 6
    ref3 = memoryref(ref, 3)
    @test evalbuiltin(Core.memoryrefoffset, ref3) === Core.memoryrefoffset(ref3) === 3

    aref = memoryref(Memory{Any}(undef, 1))
    @test evalbuiltin(Core.memoryref_isassigned, aref, :not_atomic, true) === false
    @test evalbuiltin(Core.memoryrefsetonce!, aref, 1, :not_atomic, :not_atomic, true) === true
    @test evalbuiltin(Core.memoryrefsetonce!, aref, 2, :not_atomic, :not_atomic, true) === false
    @test evalbuiltin(Core.memoryref_isassigned, aref, :not_atomic, true) === true
    @test aref[] === 1
    @static if isbuiltin(:memoryrefunset!) # Julia 1.14+
        @test evalbuiltin(Core.memoryrefunset!, aref, :not_atomic, true) === nothing
        @test !isassigned(aref)
    end

    @static if isbuiltin(:const_memoryrefget) # Julia 1.14+
        @test evalbuiltin(Core.const_memoryrefget, ref, :not_atomic, true) === 6
    end

    # an unexpected number of arguments is forwarded to the builtin to throw
    @test_throws ArgumentError evalbuiltin(Core.memoryrefget, ref)
end
end

@static if isbuiltin(:memoryrefnew) # Julia 1.12+ (`Core.memoryref` on 1.11)
@testset "memorynew and memoryrefnew" begin
    mem = evalbuiltin(Core.memorynew, Memory{Int}, 3)
    @test mem isa Memory{Int} && length(mem) == 3
    ref = evalbuiltin(Core.memoryrefnew, mem)
    @test ref isa MemoryRef{Int} && ref.mem === mem && Core.memoryrefoffset(ref) == 1
    ref3 = evalbuiltin(Core.memoryrefnew, ref, 3, true)
    @test ref3.mem === mem && Core.memoryrefoffset(ref3) == 3
    @test_throws BoundsError evalbuiltin(Core.memoryrefnew, ref, 4, true)
end
end

# Fields and globals (Julia 1.11+)
# ================================

mutable struct OnceField
    x
    OnceField() = new()
end

@static if isbuiltin(:setfieldonce!)
@testset "setfieldonce!" begin
    obj = OnceField()
    @test evalbuiltin(setfieldonce!, obj, :x, 1) === true
    @test evalbuiltin(setfieldonce!, obj, :x, 2) === false
    @test evalbuiltin(setfieldonce!, obj, :x, 3, :not_atomic) === false
    @test evalbuiltin(setfieldonce!, obj, :x, 4, :not_atomic, :not_atomic) === false
    @test obj.x === 1
end
end

module Globals
global x::Int = 1
global once
end

@static if isbuiltin(:swapglobal!)
@testset "global access builtins" begin
    @test evalbuiltin(swapglobal!, Globals, :x, 2) === 1
    @test evalbuiltin(swapglobal!, Globals, :x, 3, :monotonic) === 2
    @test evalbuiltin(modifyglobal!, Globals, :x, +, 1) == (3 => 4)
    @test evalbuiltin(modifyglobal!, Globals, :x, +, 1, :monotonic) == (4 => 5)
    @test evalbuiltin(replaceglobal!, Globals, :x, 5, 6) == (old = 5, success = true)
    @test evalbuiltin(replaceglobal!, Globals, :x, 5, 7, :monotonic) == (old = 6, success = false)
    @test evalbuiltin(replaceglobal!, Globals, :x, 6, 7, :monotonic, :monotonic) == (old = 6, success = true)
    @test Globals.x === 7
    @test evalbuiltin(setglobalonce!, Globals, :once, 1) === true
    @test evalbuiltin(setglobalonce!, Globals, :once, 2, :monotonic) === false
    @test evalbuiltin(setglobalonce!, Globals, :once, 3, :monotonic, :monotonic) === false
    @test Globals.once === 1
    @static if isbuiltin(:isdefinedglobal) # Julia 1.12+
        @test evalbuiltin(isdefinedglobal, Globals, :x) === true
        @test evalbuiltin(isdefinedglobal, Globals, :undefined) === false
        @test evalbuiltin(isdefinedglobal, Globals, :Int, false) === false
        @test evalbuiltin(isdefinedglobal, Globals, :Int, true) === true
    end
end
end

# `module` can't be defined inside `@static if`
module Partitions
global x::Int = 1
global once
end
module PartitionsSource
const v = 1
end
module PartitionsImporter
using ..PartitionsSource: v
end

@static if isbuiltin(:getglobal_partition) # Julia 1.14+
@testset "binding partition builtins" begin
    partition(name) = Base.lookup_binding_partition(Base.get_world_counter(), GlobalRef(Partitions, name))
    bpart = partition(:x)
    @test evalbuiltin(Core.getglobal_partition, GlobalRef(Partitions, :x), bpart, :monotonic) === 1
    @test evalbuiltin(Core.isdefinedglobal_partition, bpart, :monotonic) === true
    @test evalbuiltin(Core.setglobal_partition, bpart, 2) === 2
    @test evalbuiltin(Core.setglobal_partition, bpart, 3, :monotonic) === 3
    @test evalbuiltin(Core.swapglobal_partition, bpart, 4) === 3
    @test evalbuiltin(Core.swapglobal_partition, bpart, 5, :monotonic) === 4
    @test evalbuiltin(Core.modifyglobal_partition, bpart, +, 1) == (5 => 6)
    @test evalbuiltin(Core.modifyglobal_partition, bpart, +, 1, :monotonic) == (6 => 7)
    @test evalbuiltin(Core.replaceglobal_partition, bpart, 7, 8) == (old = 7, success = true)
    @test evalbuiltin(Core.replaceglobal_partition, bpart, 7, 9, :monotonic) == (old = 8, success = false)
    @test evalbuiltin(Core.replaceglobal_partition, bpart, 8, 9, :monotonic, :monotonic) == (old = 8, success = true)
    @test evalbuiltin(Core.depwarn_partition, bpart) === nothing
    @test Partitions.x === 9

    bpart = partition(:once)
    @test evalbuiltin(Core.isdefinedglobal_partition, bpart, :monotonic) === false
    @test evalbuiltin(Core.setglobalonce_partition, bpart, 1) === true
    @test evalbuiltin(Core.setglobalonce_partition, bpart, 2, :monotonic) === false
    @test evalbuiltin(Core.setglobalonce_partition, bpart, 3, :monotonic, :monotonic) === false
    @test Partitions.once === 1
end

@testset "import partitions are followed in the frame's world" begin
    w = Base.get_world_counter()
    @eval PartitionsSource const v = 2
    access = GlobalRef(PartitionsImporter, :v)
    bpart = Base.lookup_binding_partition(Base.get_world_counter(), access)
    @test evalbuiltin(Core.getglobal_partition, access, bpart, :monotonic; world=w) === 1
    @test evalbuiltin(Core.getglobal_partition, access, bpart, :monotonic) === 2
end
end

@testset "op callbacks dispatch in the frame's world" begin
    w = Base.get_world_counter()
    op = @eval (old, x) -> old + x # not callable in `w`
    @test_throws MethodError Base.invoke_in_world(w, op, 1, 2)
    # run `maybe_evaluate_builtin` in `w`, for a frame in the latest world
    @static if isbuiltin(:memoryrefmodify!)
        ref = memoryref(Memory{Int}(undef, 1))
        ref[] = 1
        @test Base.invoke_in_world(w, evalbuiltin, Core.memoryrefmodify!, ref, op, 2, :not_atomic, true) == (1 => 3)
    end
    @static if isbuiltin(:modifyglobal!)
        setglobal!(Globals, :x, 1)
        @test Base.invoke_in_world(w, evalbuiltin, modifyglobal!, Globals, :x, op, 2) == (1 => 3)
    end
    @static if isbuiltin(:modifyglobal_partition)
        bpart = Base.lookup_binding_partition(Base.get_world_counter(), GlobalRef(Partitions, :x))
        setglobal!(Partitions, :x, 1)
        @test Base.invoke_in_world(w, evalbuiltin, Core.modifyglobal_partition, bpart, op, 2) == (1 => 3)
    end
end

# Builtins added in Julia 1.12+
# =============================

worldfunc(::Any) = :old

@static if isbuiltin(:invokelatest)
@testset "invokelatest and invoke_in_world" begin
    w = Base.get_world_counter()
    @eval worldfunc(::Int) = :new
    @test evalbuiltin(Core.invoke_in_world, w, worldfunc, 1) === :old
    @test evalbuiltin(Core.invoke_in_world, Base.get_world_counter(), worldfunc, 1) === :new
    @test evalbuiltin(Core.invokelatest, worldfunc, 1; world=w) === :new
    # when expanded, the target is interpreted in the latest world
    @test evalbuiltin(Core.invokelatest, worldfunc, 1; world=w, expand=true) === :new
end
end

@static if isbuiltin(:throw_methoderror)
@testset "throw_methoderror" begin
    err = try
        evalbuiltin(Core.throw_methoderror, sin, "x")
    catch err
        err
    end
    @test err isa MethodError && err.f === sin && err.args == ("x",)
end
end

@static if isbuiltin(:_svec_len)
@testset "_svec_len" begin
    @test evalbuiltin(Core._svec_len, Core.svec()) === 0
    @test evalbuiltin(Core._svec_len, Core.svec(1, 2, 3)) === 3
end
end

module DefaultCtors
struct S
    x::Int
    S(x::Int, ::Nothing) = new(x) # an inner constructor suppresses the default ones
end
end

# Julia 1.12 and 1.13 only: since 1.14, default constructors are defined by `Base._defaultctors`
@static if isbuiltin(:_defaultctors)
@testset "_defaultctors" begin
    @test evalbuiltin(Core._defaultctors, DefaultCtors.S, LineNumberNode(@__LINE__, Symbol(@__FILE__))) === nothing
    @test (@invokelatest DefaultCtors.S(1)).x === 1
end
end

# Builtins added in Julia 1.13+
# =============================

@static if isbuiltin(:declare_const)
@testset "declare_const and declare_global" begin
    mod = Module()
    @test evalbuiltin(Core.declare_const, mod, :c, 1) === 1
    @test @invokelatest(isconst(mod, :c)) && @invokelatest(getglobal(mod, :c)) === 1
    @test evalbuiltin(Core.declare_global, mod, :g, false) === nothing
    @test @invokelatest(isdefinedglobal(mod, :g)) === false
    @test evalbuiltin(Core.declare_global, mod, :typed, true, Int) === nothing
    @test @invokelatest(Core.get_binding_type(mod, :typed)) === Int
end
end

@static if isbuiltin(:_import)
@testset "_import and _using" begin
    mod = Module()
    evalbuiltin(Core._import, mod, Base, :mysin, :sin, true)
    @test @invokelatest(getglobal(mod, :mysin)) === sin
    evalbuiltin(Core._import, mod, Base.Iterators, :Iter)
    @test @invokelatest(getglobal(mod, :Iter)) === Base.Iterators
    evalbuiltin(Core._using, mod, Base.Iterators)
    @test @invokelatest(getglobal(mod, :take)) === Base.Iterators.take
end
end

# Builtins added in Julia 1.14+
# =============================

@static if isbuiltin(:bitsizeof)
@testset "bitsizeof" begin
    @test evalbuiltin(Core.bitsizeof, Int8) === 8
    @test evalbuiltin(Core.bitsizeof, 1.0) === 64
end
end

@static if isbuiltin(:has_free_typevars)
@testset "has_free_typevars" begin
    @test evalbuiltin(Core.has_free_typevars, Vector{Int}) === false
    @test evalbuiltin(Core.has_free_typevars, Vector) === false
    @test evalbuiltin(Core.has_free_typevars, Base.unwrap_unionall(Vector)) === true
end
end

@static if isbuiltin(:_task)
@testset "_task and task_result_type" begin
    task = evalbuiltin(Core._task, () -> 42, 0)
    @test task isa Task
    @test evalbuiltin(Core.task_result_type, task) === Core.task_result_type(task)
    task.donenotify = Base.ThreadSynchronizer() # as `Core.Task` does after `Core._task`
    schedule(task)
    @test fetch(task) === 42
end
end

@static if isbuiltin(:_new_cancel_source)
@testset "cancellation builtins" begin
    src = evalbuiltin(Core._new_cancel_source)
    @test src isa Core.CancellationTokenSource
    @test evalbuiltin(Core._new_cancel_source, src) isa Core.CancellationTokenSource
    @test evalbuiltin(Core.cancellation_point!, src) === 0x00
    @test evalbuiltin(Core.cancellation_point!, nothing) === 0x00
end
end

@static if isbuiltin(:define_method)
@testset "define_method" begin
    mod = Module()
    f = evalbuiltin(Core.define_method, mod, :newfunc)
    @test f isa Function && nameof(f) === :newfunc
    @test @invokelatest(getglobal(mod, :newfunc)) === f
    @test isempty(methods(f))
end
end

end # module test_builtins
