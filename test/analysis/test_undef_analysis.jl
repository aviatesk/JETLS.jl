module test_undef_analysis

using Test
using JETLS
using JETLS: JL, JS

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

module lowering_module end

function get_undef_status(text::AbstractString; mod::Module=lowering_module, allow_throw_optimization::Bool=false)
    st0 = jlparse(text; rule=:statement, filename=@__FILE__)
    (; ctx3, st3) = JETLS.jl_lower_for_scope_resolution(mod, st0; trim_error_nodes=false, recover_from_macro_errors=false)
    undef_info = JETLS.analyze_undef_all_lambdas(ctx3, st3; allow_throw_optimization)
    result = Dict{String, Union{Nothing,Bool}}()
    for (binfo, info) in undef_info
        if !binfo.is_internal && binfo.kind == :local
            if !haskey(result, binfo.name)
                result[binfo.name] = info.undef
            end
        end
    end
    return result
end

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
    # Same condition in two if statements - CFG path exists but is infeasible
    status = get_undef_status("""
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
    status = get_undef_status("""
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

@testset "throw optimization" begin
    # @assert @isdefined(y) acts as a hint when allow_throw_optimization=true
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
    """; allow_throw_optimization=true)
    @test status["y"] === false

    # Without allow_throw_optimization, the same code reports may-be-undefined
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
    """; allow_throw_optimization=false)
    @test status_no_opt["y"] === nothing

    # Direct throw() call also works as noreturn hint
    # (if/else ensures all paths to sin(y) go through assignment)
    status = get_undef_status("""
    function f(x)
        if x > 0
            y = x
        else
            throw(ArgumentError("x must be positive"))
        end
        return sin(y)
    end
    """; allow_throw_optimization=true)
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

end # module test_undef_analysis
