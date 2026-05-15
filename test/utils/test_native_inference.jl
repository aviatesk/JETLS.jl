module test_native_inference

using Test
using JETLS
using JETLS: CC

const world = Base.get_world_counter()

@testset "infer_match! / infer_method_instance!" begin
    # Concrete dispatch: `length(::String)` infers to `Int`.
    tt = Tuple{typeof(length), String}
    matches = Base._methods_by_ftype(tt, -1, world)
    @test matches isa Vector
    @test length(matches) == 1
    match = only(matches)

    let (_, result) = JETLS.infer_match!(world, match)
        @test CC.widenconst(result.result) === Int
    end
    let mi = CC.specialize_method(match)
        _, result2 = JETLS.infer_method_instance!(world, mi)
        @test CC.widenconst(result2.result) === Int
    end
end

@testset "abstract_call_const" begin
    # Single concrete type → method dispatch matches the default
    # `propertynames`; inference's const-prop turns `fieldnames(typeof(x))`
    # into a `Core.Const` tuple.
    rt = JETLS.abstract_call_const(propertynames, Any[Regex], world)
    @test rt isa Core.Const
    @test rt.val isa Tuple{Vararg{Symbol}}
    @test :pattern in rt.val

    # `Core.Const` second arg flows through to `getproperty`'s body so the
    # specific field's type comes back, not just `Any`.
    rt = JETLS.abstract_call_const(getproperty, Any[Regex, Core.Const(:pattern)], world)
    @test rt !== nothing
    @test CC.widenconst(rt) === String

    # `Nothing` has no fields: inference of `getproperty(::Nothing, ::Symbol)`
    # widens to `Union{}` (the call would throw).
    rt = JETLS.abstract_call_const(getproperty, Any[Nothing, Core.Const(:anything)], world)
    @test rt !== nothing
    @test CC.widenconst(rt) === Union{}

    # `Union` argument: `_methods_by_ftype` returns the generic method via
    # subtyping, so the call still succeeds and returns a (widened) result.
    # Callers that need per-component precision should split the union
    # themselves before calling.
    rt = JETLS.abstract_call_const(propertynames, Any[Union{Regex, Nothing}], world)
    @test rt !== nothing
end

end # module test_native_inference
