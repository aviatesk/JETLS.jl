module test_cfg_analysis

using Test
using JETLS
using JETLS: JL, JS

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

module lowering_module end

function get_undef_status(text::AbstractString; mod::Module=lowering_module, allow_noreturn_optimization::Vector{Symbol}=Symbol[])
    st0 = jlparse(text; rule=:statement, filename=@__FILE__)
    (; ctx3, st3) = JETLS.jl_lower_for_scope_resolution(mod, st0; trim_error_nodes=false, recover_from_macro_errors=false)
    (; undef_info) = JETLS.analyze_all_lambdas(ctx3, st3; allow_noreturn_optimization)
    result = Dict{String, Union{Nothing,Bool}}()
    for (binfo, info) in undef_info
        if !binfo.is_internal && binfo.kind == :local
            if !haskey(result, binfo.name)
                undef_uses = info.undef_uses
                result[binfo.name] =
                    isempty(undef_uses) ? false : any(first, undef_uses) ? true : nothing
            end
        end
    end
    return result
end

@testset "undef analysis" begin

@testset "sequential assignment then use" begin
    # Variable is assigned before use - definitely defined
    status = get_undef_status("""
    function f()
        y = 1
        println(y)
    end
    """)
    @test status["y"] === false
end

@testset "use before assignment" begin
    # Variable is used before any assignment - definitely undefined
    status = get_undef_status("""
    function f()
        println(y)
        y = 1
    end
    """)
    @test status["y"] === true
end

@testset "if-else both branches assign" begin
    # All branches assign - definitely defined at use
    status = get_undef_status("""
    function f()
        if rand() > 0.5
            y = 1
        else
            y = 2
        end
        println(y)
    end
    """)
    @test status["y"] === false
end

@testset "if-else one branch assigns" begin
    # Only one branch assigns - may be undefined
    status = get_undef_status("""
    function f()
        if rand() > 0.5
            y = 1
        else
            nothing
        end
        println(y)
    end
    """)
    @test status["y"] === nothing
end

@testset "nested if-else all paths assign" begin
    # All nested paths assign - definitely defined
    status = get_undef_status("""
    function f()
        if rand() > 0.5
            if rand() > 0.5
                y = 1
            else
                y = 2
            end
        else
            y = 3
        end
        println(y)
    end
    """)
    @test status["y"] === false
end

@testset "while loop" begin
    # Loop may not execute - may be undefined
    status = get_undef_status("""
    function f()
        local y
        while rand() > 0.5
            y = 1
        end
        println(y)
    end
    """)
    @test status["y"] === nothing
end

@testset "for loop" begin
    # Loop may not execute (empty range) - may be undefined
    status = get_undef_status("""
    function f()
        local y
        for i in 1:10
            y = i
        end
        println(y)
    end
    """)
    @test status["y"] === nothing
end

@testset "try-catch both assign" begin
    # Both try and catch blocks assign y, so y is always defined at use
    status = get_undef_status("""
    function f()
        local y
        try
            y = 1
        catch
            y = 2
        end
        println(y)
    end
    """)
    @test status["y"] === false
end

@testset "multiple variables" begin
    # Test multiple variables in same function
    status = get_undef_status("""
    function f()
        x = 1
        println(x)
        if rand() > 0.5
            y = 2
        end
        println(y)
        println(z)
        z = 3
    end
    """)
    @test status["x"] === false    # assigned before use
    @test status["y"] === nothing  # may not be assigned (branch)
    @test status["z"] === true     # used before assigned (straight-line)
end

@testset "assignment in both if branches with nested control flow" begin
    status = get_undef_status("""
    function f()
        if rand() > 0.5
            while rand() > 0.5
                nothing
            end
            y = 1
        else
            for i in 1:10
                nothing
            end
            y = 2
        end
        println(y)
    end
    """)
    @test status["y"] === false  # both branches assign at end
end

@testset "argument is always defined" begin
    status = get_undef_status("""
    function f(x)
        println(x)
    end
    """)
    # Arguments don't appear in our result (kind == :argument, not :local)
    @test !haskey(status, "x")
end

@testset "variable only assigned, never used" begin
    # If never used, "defined at all uses" is vacuously true
    status = get_undef_status("""
    function f()
        y = 1
    end
    """)
    @test status["y"] === false
end

@testset "correlated conditions" begin
    # Simple variable condition: `if x` assigns y, later `if x` uses y
    let status = get_undef_status("""
        function func(x::Bool)
            if x
                y = 42
            end
            if x
                println(y)
            end
        end
        """)
        @test status["y"] === false
    end

    # Compound condition: not handled (only simple BindingId conditions)
    let status = get_undef_status("""
        function func(x)
            if x > 0
                y = 42
            end
            if x > 0
                return sin(y)
            end
        end
        """)
        @test status["y"] === nothing
    end

    # Condition variable reassigned between the two ifs invalidates
    let status = get_undef_status("""
        function func()
            x = rand(Bool)
            if x
                y = 42
            end
            x = rand(Bool)
            if x
                println(y)
            end
        end
        """)
        @test status["y"] === nothing
    end

    # Assignment inside nested if within the first branch: conservative
    let status = get_undef_status("""
        function func(x, z)
            if x
                if z
                    y = 42
                end
            end
            if x
                println(y)
            end
        end
        """)
        @test status["y"] === nothing
    end

    # Multiple variables assigned in the first branch
    let status = get_undef_status("""
        function func(x::Bool)
            if x
                y = 42
                z = 10
            end
            if x
                println(y + z)
            end
        end
        """)
        @test status["y"] === false
        @test status["z"] === false
    end

    # First if inside a conditional: implication scoped to that branch
    let status = get_undef_status("""
        function func(x, z)
            if z
                if x
                    y = 42
                end
            end
            if x
                println(y)
            end
        end
        """)
        @test status["y"] === nothing
    end

    # Both ifs nested in the same branch: implication is valid
    let status = get_undef_status("""
        function func(x, z)
            if z
                if x
                    y = 42
                end
                if x
                    println(y)
                end
            end
        end
        """)
        @test status["y"] === false
    end

    # Condition variable reassigned in one branch, used after
    let status = get_undef_status("""
        function func()
            x = rand(Bool)
            if x
                y = 42
            end
            if rand(Bool)
                x = false
            end
            if x
                println(y)
            end
        end
        """)
        @test status["y"] === nothing
    end

    # && chain lookup: `if x` records, `if x && z` looks up x
    let status = get_undef_status("""
        function func(x, z)
            if x
                y = 42
            end
            if x && z
                println(y)
            end
        end
        """)
        @test status["y"] === false
    end

    # && chain lookup: operand order doesn't matter
    let status = get_undef_status("""
        function func(x, z)
            if x
                y = 42
            end
            if z && x
                println(y)
            end
        end
        """)
        @test status["y"] === false
    end

    # && chain: compound recording and lookup
    let status = get_undef_status("""
        function func(x, z)
            if x && z
                y = 42
            end
            if x && z
                println(y)
            end
        end
        """)
        @test status["y"] === false
    end

    # && compound: subset lookup (superset condition)
    let status = get_undef_status("""
        function func(x, z, w)
            if x && z
                y = 42
            end
            if x && z && w
                println(y)
            end
        end
        """)
        @test status["y"] === false
    end

    # && compound: individual operand does NOT satisfy compound
    let status = get_undef_status("""
        function func(x, z)
            if x && z
                y = 42
            end
            if x
                println(y)
            end
        end
        """)
        @test status["y"] === nothing
    end

    # && compound: condition var reassigned invalidates compound
    let status = get_undef_status("""
        function func()
            x = rand(Bool)
            z = rand(Bool)
            if x && z
                y = 42
            end
            x = rand(Bool)
            if x && z
                println(y)
            end
        end
        """)
        @test status["y"] === nothing
    end

    # && chain with nested &&
    let status = get_undef_status("""
        function func(x, y, z)
            if x
                w = 42
            end
            if y
                v = 10
            end
            if x && y && z
                println(w + v)
            end
        end
        """)
        @test status["w"] === false
        @test status["v"] === false
    end

    # Nested ifs lifted to compound condition
    let status = get_undef_status("""
        function func(a::Bool, b::Bool)
            if a
                if b
                    y = 42
                end
            end
            if a && b
                println(y)
            end
        end
        """)
        @test status["y"] === false
    end

    # Deeper nesting: three levels lifted
    let status = get_undef_status("""
        function func(a::Bool, b::Bool, c::Bool)
            if a
                if b
                    if c
                        y = 42
                    end
                end
            end
            if a && b && c
                println(y)
            end
        end
        """)
        @test status["y"] === false
    end

    # Nested if with condition var reassigned after: invalidates lifted implication
    let status = get_undef_status("""
        function func()
            a = rand(Bool)
            b = rand(Bool)
            if a
                if b
                    y = 42
                end
            end
            a = rand(Bool)
            if a && b
                println(y)
            end
        end
        """)
        @test status["y"] === nothing
    end

    # Nested if with non-BindingId outer: no lifting
    let status = get_undef_status("""
        function func(x, b)
            if x > 0
                if b
                    y = 42
                end
            end
            if b
                println(y)
            end
        end
        """)
        @test status["y"] === nothing
    end

    # Nested ifs on both sides (no &&): active stack provides combined lookup
    let status = get_undef_status("""
        function func(a::Bool, b::Bool)
            if a
                if b
                    y = 42
                end
            end
            if a
                if b
                    println(y)
                end
            end
        end
        """)
        @test status["y"] === false
    end

    # Delta lifting: existing implication extended inside branch
    let status = get_undef_status("""
        function func(a::Bool, b::Bool)
            if b
                y = 42
            end
            if a
                if b
                    z = 10
                end
            end
            if a && b
                println(y + z)
            end
        end
        """)
        @test status["y"] === false
        @test status["z"] === false
    end

    # Lift when outer condition is already in key (lift_with ⊆ key)
    let status = get_undef_status("""
        function func(a::Bool, b::Bool)
            if a
                if a && b
                    y = 42
                end
            end
            if a && b
                println(y)
            end
        end
        """)
        @test status["y"] === false
    end

    # function_decl in correlated condition
    let status = get_undef_status("""
        function func(x::Bool)
            if x
                function y()
                    1
                end
            end
            if x
                y()
            end
        end
        """)
        @test status["y"] === false
    end

    # function_decl in correlated condition with && lookup
    let status = get_undef_status("""
        function func(x::Bool, z::Bool)
            if x
                function y()
                    1
                end
            end
            if x && z
                y()
            end
        end
        """)
        @test status["y"] === false
    end

    # elseif preserves implication from the original condition
    let status = get_undef_status("""
        function func(x::Bool)
            if x
                y = 1
            end
            if rand(Bool)
            elseif x
                println(y)
            end
        end
        """)
        @test status["y"] === false
    end

    # invalidation then re-establishment of the same condition
    let status = get_undef_status("""
        function func(x::Bool)
            if x
                y = 1
            end
            x = true
            if x
                y = 2
            end
            if x
                println(y)
            end
        end
        """)
        @test status["y"] === false
    end

    # non-direct assign (e.g. `+=`) should not be recorded as implication
    let status = get_undef_status("""
        function func(x::Bool)
            y = 0
            if x
                y += 1
            end
            if x
                println(y)
            end
        end
        """)
        # `y += 1` is not a direct assign, so the correlated condition
        # analysis should not suppress the warning for `y` — but `y` is
        # always defined here anyway because of the initial `y = 0`.
        @test status["y"] === false
    end

    # `y += 1` lowers to `y = y + 1`, which is a direct assign and
    # creates an implication.  The use of `y` inside `y += 1` is still
    # potentially undefined, but the second `if x` branch is suppressed.
    let status = get_undef_status("""
        function func(x::Bool)
            if x
                y += 1
            end
            if x
                println(y)
            end
        end
        """)
        @test status["y"] === nothing
    end
end

@testset "closure capture" begin
    # Variables assigned before closure and captured - definitely defined
    status = get_undef_status("""
    function f()
        x = 1
        y = 2
        map([1,2,3]) do i
            x + y + i
        end
    end
    """)
    @test status["x"] === false
    @test status["y"] === false
end

@testset "if @isdefined(y) - use inside true branch" begin
    # Variable is guarded by @isdefined in condition
    let status = get_undef_status("""
        function f(x)
            if x > 0
                y = 42
            end
            if @isdefined(y)
                return sin(y)
            end
        end
        """)
        @test status["y"] === false
    end
    let status = get_undef_status("""
        function f(x)
            if x > 0
                y = 42
            end
            if x == 0
                return 0.0
            elseif @isdefined(y)
                return sin(y)
            end
        end
        """)
        @test status["y"] === false
    end
end

@testset "if cond && @isdefined(y) - use inside true branch" begin
    let status = get_undef_status("""
        function f(x)
            if x > 0
                y = 42
            end
            if x > 0 && @isdefined(y)
                return sin(y)
            end
        end
        """)
        @test status["y"] === false
    end
    # Nested && chain
    let status = get_undef_status("""
        function f(x, z)
            if x > 0
                y = 42
            end
            if x > 0 && z && @isdefined(y)
                return sin(y)
            end
        end
        """)
        @test status["y"] === false
    end
end

@testset "nested closures" begin
    # Variable assigned before outer closure, captured by inner closure
    status = get_undef_status("""
    function f()
        x = 1
        map([1,2,3]) do i
            map([4,5,6]) do j
                x + i + j
            end
        end
    end
    """)
    @test status["x"] === false
end

@testset "nested closures - may be undefined" begin
    # Variable conditionally assigned, captured by nested closure
    status = get_undef_status("""
    function f(cond)
        if cond
            y = 42
        end
        map([1,2,3]) do i
            map([4,5,6]) do j
                y + i + j
            end
        end
    end
    """)
    @test status["y"] === nothing
end

@testset "generator expression" begin
    # Variable assigned before generator
    status = get_undef_status("""
    function f()
        x = 10
        (x + i for i in 1:10)
    end
    """)
    @test status["x"] === false
end

@testset "generator - may be undefined" begin
    # Variable conditionally assigned, used in generator
    status = get_undef_status("""
    function f(cond)
        if cond
            y = 42
        end
        (y + i for i in 1:10)
    end
    """)
    @test status["y"] === nothing
end

@testset "break in loop" begin
    # Assignment after break is unreachable, but loop may not execute
    status = get_undef_status("""
    function f()
        local y
        for i in 1:10
            if i > 5
                break
            end
            y = i
        end
        println(y)
    end
    """)
    @test status["y"] === nothing
end

@testset "continue in loop" begin
    # Continue skips assignment sometimes
    status = get_undef_status("""
    function f()
        local y
        for i in 1:10
            if i > 5
                continue
            end
            y = i
        end
        println(y)
    end
    """)
    @test status["y"] === nothing
end

@testset "closure assigns to captured variable" begin
    # When a closure assigns to a captured variable, we can't know when/if
    # the closure is called, so report "may be undefined" instead of
    # "must be undefined"
    status = get_undef_status("""
    function func(a)
        local x
        function inner(y)
            x = y
        end
        f = inner
        f(a)
        return x
    end
    """)
    @test status["x"] === nothing  # may be undefined (not must be undefined)
end

@testset "noreturn optimization" begin
    noreturn_syms = Symbol[:throw, :error, :rethrow, :exit]

    # @assert @isdefined(y) acts as a hint when noreturn optimization is enabled
    # Because if y is not defined, throw() is called and code after is unreachable
    status = get_undef_status("""
    function f(x)
        if x > 0
            y = x
        end
        if x > 0
            @assert @isdefined(y) "hint"
            return sin(y)
        end
    end
    """; allow_noreturn_optimization=noreturn_syms)
    @test status["y"] === false

    # Without noreturn optimization, the same code reports may-be-undefined
    # (compound condition `x > 0` is not handled by correlated condition analysis)
    status_no_opt = get_undef_status("""
    function f(x)
        if x > 0
            y = x
        end
        if x > 0
            @assert @isdefined(y) "hint"
            return sin(y)
        end
    end
    """)
    @test status_no_opt["y"] === nothing

    # Direct throw() call also works as noreturn hint
    status = get_undef_status("""
    function f(x)
        if x > 0
            y = x
        else
            throw(ArgumentError("x must be positive"))
        end
        return sin(y)
    end
    """; allow_noreturn_optimization=noreturn_syms)
    @test status["y"] === false

    # error() also works as noreturn hint
    status = get_undef_status("""
    function f(x)
        if x > 0
            y = x
        else
            error("x must be positive")
        end
        return sin(y)
    end
    """; allow_noreturn_optimization=noreturn_syms)
    @test status["y"] === false

    # exit() also works as noreturn hint
    status = get_undef_status("""
    function f(x)
        if x > 0
            y = x
        else
            exit(1)
        end
        return sin(y)
    end
    """; allow_noreturn_optimization=noreturn_syms)
    @test status["y"] === false

    # rethrow() in catch block works as noreturn hint
    status = get_undef_status("""
    function f(x)
        local y
        try
            y = parse(Int, x)
        catch
            rethrow()
        end
        return y
    end
    """; allow_noreturn_optimization=noreturn_syms)
    @test status["y"] === false

    # nested noreturn call in argument position
    status = get_undef_status("""
    function f(x)
        if x > 0
            y = x
        else
            println(error("x must be positive"))
        end
        return sin(y)
    end
    """; allow_noreturn_optimization=noreturn_syms)
    @test status["y"] === false
end

@testset "top-level block without function" begin
    # Variable declared with let but never assigned - definitely undefined
    status = get_undef_status("""
    let x
        println(x)
    end
    """)
    @test status["x"] === true
end

@testset "@label / @goto control flow" begin
    # Forward goto skips over the unconditional assignment, leaving the label
    # body's `return x` reachable on a path where `x` is undefined.
    let status = get_undef_status("""
        function f(cond)
            local x
            if cond
                @goto skip
            end
            x = 1
            @label skip
            return x
        end
        """)
        @test status["x"] === nothing
    end

    # Both branches of a forward `if/@goto … @label` join cleanly assigning `x`,
    # so `x` is definitely defined at the label body's `return`.
    let status = get_undef_status("""
        function f(cond)
            local x
            if cond
                x = 1
                @goto done
            end
            x = 2
            @label done
            return x
        end
        """)
        @test status["x"] === false
    end

    # Backward goto (loop pattern): label first, then goto. The label is
    # reachable both via fallthrough and the back-edge from goto.
    let status = get_undef_status("""
        function f()
            local x
            x = 1
            @label loop
            x = x + 1
            x < 10 && @goto loop
            return x
        end
        """)
        @test status["x"] === false
    end
end

@testset "tryfinally with terminating try body" begin
    # When the try body always terminates (e.g. `return`), post-try is
    # unreachable: any use of a local there should NOT be flagged as
    # potentially undefined, since that use never executes. Without the
    # `current_known_unreachable` flag tracking in `K"tryfinally"`, the
    # use would be reachable via the gotoifnot bypass through finally,
    # making the post-try use look reachable from the entry on a path
    # that misses the try-body assignment, and `x` would surface as
    # `nothing` (potentially undef) — a false positive.
    let status = get_undef_status("""
        function f()
            local x
            try
                x = 1
                return 1
            finally
                cleanup()
            end
            return x
        end
        """)
        @test status["x"] === false
    end

    # Same shape but with finally also assigning to the variable: still
    # not flagged, for the same reason — the post-try use is unreachable.
    let status = get_undef_status("""
        function f()
            local x
            try
                return 1
            finally
                x = 2
            end
            return x
        end
        """)
        @test status["x"] === false
    end

    # Sanity check that the regular tryfinally case (try body doesn't
    # terminate) still tracks definedness through the gotoifnot bypass:
    # if the only assignment is in the try body, the use post-try might
    # not have executed when control reached finally via the exception
    # path, so x stays `nothing` (potentially undef).
    let status = get_undef_status("""
        function f()
            local x
            try
                x = compute()
            finally
                cleanup()
            end
            return x
        end
        """)
        @test status["x"] === nothing
    end
end

@testset "@something short-circuit control flow" begin
    # `@something(a, b)` only evaluates `b` when `a` is `nothing`. An
    # assignment that lives inside a later argument is therefore conditional,
    # so `v` may be undefined at the trailing `return`. If the macro stub
    # collapsed to a flat `something(a, b)` call, both args would be
    # evaluated unconditionally and `v` would be definitely defined.
    let status = get_undef_status("""
        function f(x)
            local v
            @something(x, (v = 1; nothing))
            return v
        end
        """)
        @test status["v"] === nothing
    end

    # Dual case: `v` is assigned in the first argument (always evaluated),
    # so it is definitely defined regardless of what later args do.
    let status = get_undef_status("""
        function f()
            local v
            @something((v = 1; nothing), other)
            return v
        end
        """)
        @test status["v"] === false
    end
end

end # @testset "undef analysis" begin

# --- Dead store (unused assignment) analysis ---

function get_dead_stores(text::AbstractString;
        mod::Module=lowering_module,
        allow_noreturn_optimization::Vector{Symbol}=Symbol[])
    st0 = jlparse(text; rule=:statement, filename=@__FILE__)
    (; ctx3, st3) = JETLS.jl_lower_for_scope_resolution(mod, st0;
        trim_error_nodes=false, recover_from_macro_errors=false)
    (; dead_store_info) = JETLS.analyze_all_lambdas(ctx3, st3;
        allow_noreturn_optimization)
    result = Dict{String,Int}()
    for (binfo, dsinfo) in dead_store_info
        if !binfo.is_internal && binfo.kind == :local
            result[binfo.name] = length(dsinfo.dead_defs)
        end
    end
    return result
end

@testset "dead store analysis" begin

@testset "simple use, no dead stores" begin
    ds = get_dead_stores("""
    function f()
        y = 1
        println(y)
    end
    """)
    @test !haskey(ds, "y")
end

@testset "assignment at end of function" begin
    ds = get_dead_stores("""
    function foo(x::Bool)
        if x
            z = "Hi"
            println(z)
        end
        if x
            z = "Hey"
        end
    end
    """)
    @test ds["z"] == 1
end

@testset "unconditional overwrite" begin
    ds = get_dead_stores("""
    function f()
        z = "initial"
        z = "overwrite"
        println(z)
    end
    """)
    @test ds["z"] == 1
end

@testset "conditional overwrite, both live" begin
    ds = get_dead_stores("""
    function f(x::Bool)
        z = "initial"
        if x
            z = "updated"
        end
        println(z)
    end
    """)
    @test !haskey(ds, "z")
end

@testset "if-else both assign then use" begin
    ds = get_dead_stores("""
    function f(x::Bool)
        if x
            z = 1
        else
            z = 2
        end
        println(z)
    end
    """)
    @test !haskey(ds, "z")
end

@testset "multiple dead stores" begin
    ds = get_dead_stores("""
    function f()
        z = 1
        z = 2
        z = 3
        println(z)
    end
    """)
    @test ds["z"] == 2
end

@testset "no uses, skip (unused-binding handles this)" begin
    ds = get_dead_stores("""
    function f()
        z = 1
    end
    """)
    @test !haskey(ds, "z")
end

@testset "loop assignment is live" begin
    ds = get_dead_stores("""
    function f()
        local z
        for i in 1:10
            z = i
        end
        println(z)
    end
    """)
    @test !haskey(ds, "z")
end

@testset "assignment before loop, loop may not execute" begin
    ds = get_dead_stores("""
    function f()
        z = 0
        for i in 1:10
            z = i
        end
        println(z)
    end
    """)
    @test !haskey(ds, "z")
end

@testset "closure read only, dead store still detected" begin
    ds = get_dead_stores("""
    function f()
        x = 1
        x = 2
        map([1,2,3]) do i
            x + i
        end
    end
    """)
    @test !haskey(ds, "x")  # x is captured → skipped
end

@testset "closure write, skip variable" begin
    ds = get_dead_stores("""
    function f()
        local z
        g = () -> (z = 1)
        z = 2
        g()
        println(z)
    end
    """)
    @test !haskey(ds, "z")
end

@testset "dead store after last use" begin
    ds = get_dead_stores("""
    function f()
        z = 1
        println(z)
        z = 2
        return
    end
    """)
    @test ds["z"] == 1
end

@testset "return in branch, both assignments live" begin
    ds = get_dead_stores("""
    function f(x::Bool)
        z = 1
        if x
            return z
        end
        z = 2
        return z
    end
    """)
    @test !haskey(ds, "z")
end

@testset "try-catch both assign then use" begin
    ds = get_dead_stores("""
    function f()
        local z
        try
            z = 1
        catch
            z = 2
        end
        println(z)
    end
    """)
    @test !haskey(ds, "z")
end

@testset "multiple variables, mixed" begin
    ds = get_dead_stores("""
    function f(x::Bool)
        a = 1
        a = 2
        println(a)
        b = 3
        if x
            b = 4
        end
        println(b)
    end
    """)
    @test ds["a"] == 1
    @test !haskey(ds, "b")
end

@testset "use before assignment is also dead" begin
    ds = get_dead_stores("""
    function f()
        println(y)
        y = 1
    end
    """)
    @test ds["y"] == 1
end

@testset "while loop with continue (iterate pattern)" begin
    # `r = iterate(itr, state)` is used by the `while r !== nothing` condition
    # on the next iteration via `continue` back-edge
    ds = get_dead_stores("""
    function issue(itr)
        r = iterate(itr)
        local child
        while r !== nothing
            (child, state) = r
            r = iterate(itr, state)
            child isa Bool || continue
            child && break
            return true
        end
    end
    """)
    @test !haskey(ds, "r")
end

@testset "while loop with continue (simple)" begin
    # `r = xs[i]` is used by `r == 0` in the same iteration, so NOT dead.
    # `r = 0` before the loop is dead (always overwritten before any use).
    ds = get_dead_stores("""
    function f(xs)
        r = 0
        i = 1
        while i <= length(xs)
            r = xs[i]
            i += 1
            r == 0 && continue
            println(r)
        end
    end
    """)
    @test ds["r"] == 1
end

@testset "nested while loops with break/continue" begin
    ds = get_dead_stores("""
    function f(matrix)
        local result
        i = 1
        while i <= length(matrix)
            j = 1
            row = matrix[i]
            while j <= length(row)
                result = row[j]
                j += 1
                result === nothing && continue
                result == 0 && break
            end
            i += 1
        end
        return result
    end
    """)
    @test !haskey(ds, "result")
end

@testset "@label / @goto control flow" begin
    # Regression test for the pattern in `full-analysis.jl:841`: a value
    # assigned right before `@goto label` and read after `@label label` was
    # incorrectly reported as a dead store, because `K"symbolicgoto"` /
    # standalone `K"symboliclabel"` were not modeled in the CFG.
    let ds = get_dead_stores("""
        function f(cond)
            local reports
            if cond
                reports = "from cond"
                @goto done
            end
            reports = "default"
            @label done
            return reports
        end
        """)
        @test !haskey(ds, "reports")
    end

    # Bare `@label` with no matching `@goto` should not introduce phantom edges
    # that mask real dead stores.
    let ds = get_dead_stores("""
        function f()
            x = 1
            x = 2
            @label here
            return x
        end
        """)
        @test ds["x"] == 1
    end

    # Conversely, when the `@label` sits before an unconditional reassignment,
    # the value assigned right before `@goto` IS dead — the goto lands on the
    # label and the next statement clobbers it. The fix shouldn't suppress
    # this legitimate dead store.
    let ds = get_dead_stores("""
        function f(cond)
            local reports
            if cond
                reports = "from cond"
                @goto done
            end
            @label done
            reports = "default"
            return reports
        end
        """)
        @test ds["reports"] == 1
    end
end

end # @testset "dead store analysis" begin

end # module test_cfg_analysis
