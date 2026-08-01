# Guard against inference-visible runtime dispatch in JuliaInterpreter's own code.
#
# Values flowing through interpreted frames are deliberately untyped (`Any` /
# `Some{Any}` slots), so the interpreter cannot be "type stable" about the values it
# manipulates. What it can do — and what this test enforces — is shield its own
# machinery from that dynamism: unwrapped values must only flow into `@nospecialize`d
# single-method functions (statically resolvable) or into builtins like
# `Core._call_in_world`/`Core._apply_iterate` (dynamic by design, with no dispatch for
# inference to lose). With that discipline, the interpreter loop itself compiles to
# static calls, which JET's optimization analysis can verify.
#
# This file is not part of the standard test suite: JET depends on JuliaInterpreter,
# so making it a test dependency would tie every CI run to JET's compat bounds.
# It runs in its own environment via .github/workflows/TypeStability.yml, or locally:
#
#     julia --project=<env with JET + this JuliaInterpreter> test/typestability.jl

using JuliaInterpreter, JET, Test
using JuliaInterpreter: RecursiveInterpreter, NonRecursiveInterpreter, Frame, FrameCode,
    finish_and_return!, step_expr!, get_call_framecode, prepare_frame_caller,
    maybe_evaluate_builtin, lookup, do_assignment!, shouldbreak, debug_command

# Entry points that together cover the interpreter engine (statement stepping, call
# dispatch, builtins, frame setup) and the debugger command layer.
const DISPATCH_TARGETS = Any[
    (finish_and_return!, (RecursiveInterpreter, Frame, Bool)),
    (finish_and_return!, (NonRecursiveInterpreter, Frame, Bool)),
    (step_expr!, (RecursiveInterpreter, Frame, Any, Bool)),
    (get_call_framecode, (Vector{Any}, FrameCode, Int)),
    (prepare_frame_caller, (Frame, FrameCode, Vector{Any}, Core.SimpleVector)),
    (maybe_evaluate_builtin, (RecursiveInterpreter, Frame, Expr, Bool)),
    (lookup, (RecursiveInterpreter, Frame, Any)),
    (do_assignment!, (Frame, Any, Any)),
    (shouldbreak, (Frame, Int)),
    (debug_command, (RecursiveInterpreter, Frame, Symbol, Bool)),
]

@testset "no runtime dispatch in JuliaInterpreter internals" begin
    for (f, argtypes) in DISPATCH_TARGETS
        @testset "$f($(join(argtypes, ", ")))" begin
            test_opt(f, argtypes; target_modules=(JuliaInterpreter,))
        end
    end
end
