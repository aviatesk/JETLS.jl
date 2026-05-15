# `CC.NativeInterpreter`-based abstract-call helpers, used by LSP features that need
# a one-shot inference query (method signature completion, property completion, ...).

const NATIVE_INFERENCE_WORLD = Ref{UInt}(typemax(UInt))
push_init_hook!() do
    NATIVE_INFERENCE_WORLD[] = Base.get_world_counter()
end

"""
    infer_match!(world::UInt, match::Core.MethodMatch)
        -> (interp::CC.NativeInterpreter, result::CC.InferenceResult)
    infer_match!(interp::CC.NativeInterpreter, match::Core.MethodMatch)
        -> (interp::CC.NativeInterpreter, result::CC.InferenceResult)

Specialize `match` to a `MethodInstance` and run [`infer_method_instance!`](@ref).
"""
infer_match!(world::UInt, match::Core.MethodMatch) = infer_match!(CC.NativeInterpreter(world), match)
infer_match!(interp::CC.NativeInterpreter, match::Core.MethodMatch) =
    infer_method_instance!(interp, CC.specialize_method(match))

"""
    infer_method_instance!(world::UInt, mi::Core.MethodInstance)
        -> (interp::CC.NativeInterpreter, result::CC.InferenceResult)
    infer_method_instance!(interp::CC.NativeInterpreter, mi::Core.MethodInstance)
        -> (interp::CC.NativeInterpreter, result::CC.InferenceResult)

Run uncached inference on `mi` under `interp` and return `(interp, result)`.
When `CC.InferenceState` can't be constructed for `mi`, returns the
unprocessed `result` (whose `result.result` will hold whatever default
the `InferenceResult` was created with).
"""
infer_method_instance!(world::UInt, mi::Core.MethodInstance) = infer_method_instance!(CC.NativeInterpreter(world), mi)
function infer_method_instance!(interp::CC.NativeInterpreter, mi::Core.MethodInstance)
    result = CC.InferenceResult(mi)
    frame = CC.InferenceState(result, #=cache_mode=#:no, interp)
    isnothing(frame) && return interp, result
    return infer_frame!(interp, frame)
end

function infer_frame!(interp::CC.NativeInterpreter, frame::CC.InferenceState)
    Base.invoke_in_world(NATIVE_INFERENCE_WORLD[], CC.typeinf, interp, frame)
    return interp, frame.result
end

"""
    abstract_call_const(f, argtypes::Vector{Any}, world::UInt) -> result | nothing

Abstract-call `f(argtypes...)` through `CC.NativeInterpreter` at `world` and return the
inferred extended lattice element. `argtypes` may contain `Core.Const` entries;
method dispatch uses the widened types while inference sees the lattice values,
so const-prop fires through them.

Returns `nothing` when `_methods_by_ftype` doesn't find a unique matching method,
or when `InferenceState` can't be constructed for it.
"""
function abstract_call_const(@nospecialize(f), argtypes::Vector{Any}, world::UInt)
    widened = Any[CC.widenconst(a) for a in argtypes]
    tt = Tuple{Core.Typeof(f), widened...}
    matches = Base._methods_by_ftype(tt, -1, world)
    matches isa Vector || return nothing
    length(matches) == 1 || return nothing
    match = first(matches)::Core.MethodMatch
    interp = CC.NativeInterpreter(world)
    mi = CC.specialize_method(match)
    result = CC.InferenceResult(mi)
    empty!(result.argtypes)
    push!(result.argtypes, Core.Const(f))
    append!(result.argtypes, argtypes)
    frame = CC.InferenceState(result, #=cache_mode=#:no, interp)
    frame === nothing && return result.result
    Base.invoke_in_world(NATIVE_INFERENCE_WORLD[], CC.typeinf, interp, frame)
    return result.result
end
