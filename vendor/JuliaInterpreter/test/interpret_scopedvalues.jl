module test_interpret_scopedvalues

using Test, JuliaInterpreter
using Base.ScopedValues

const sval1 = ScopedValue(1)
const sval2 = ScopedValue(1)
@test 1 == @interpret getindex(sval1)

# current_scope support for interpretation
sval1_func1() = @with sval1 => 2 begin
    return sval1[]
end
@test 2 == @interpret sval1_func1()
sval12_func1() = @with sval1 => 2 begin
    @with sval2 => 3 begin
        return sval1[], sval2[]
    end
end
@test (2, 3) == @interpret sval12_func1()

# current_scope support for compiled calls
_sval1_func2() = sval1[]
sval1_func2() = @with sval1 => 2 begin
    return _sval1_func2()
end
let m = only(methods(_sval1_func2))
    push!(JuliaInterpreter.compiled_methods, m)
    try
        @test 2 == @interpret sval1_func2()
    finally
        delete!(JuliaInterpreter.compiled_methods, m)
    end
end
let frame = JuliaInterpreter.enter_call(sval1_func2)
    @test 2 == JuliaInterpreter.finish_and_return!(NonRecursiveInterpreter(), frame)
end

# preset `current_scope` support
@test 2 == @with sval1 => 2 begin
    @interpret getindex(sval1)
end
@test (2, 3) == @with sval1 => 2 sval2 => 3 begin
    @interpret(getindex(sval1)), @interpret(getindex(sval2))
end
@test (2, 3) == @with sval1 => 2 begin @with sval2 => 3 begin
    @interpret(getindex(sval1)), @interpret(getindex(sval2))
end end
let frame = JuliaInterpreter.enter_call() do
        sval1[], sval2[]
    end
    @test (2, 3) == @with sval1 => 2 sval2 => 3 JuliaInterpreter.finish_and_return!(frame)
end

# A compiled call made from interpreted code sees a scope that was already active when the
# interpreter was entered (it inherits it from the task; nothing needs to be re-installed)
_sval1_caller() = _sval1_func2()
let m = only(methods(_sval1_func2))
    push!(JuliaInterpreter.compiled_methods, m)
    try
        @test 3 == @with sval1 => 3 @interpret _sval1_caller()
        @test (3, 4) == @with sval1 => 3 begin
            @with sval2 => 4 (@interpret(_sval1_caller()), @interpret(getindex(sval2)))
        end
    finally
        delete!(JuliaInterpreter.compiled_methods, m)
    end
end

# Under a dynamic scope entered by interpreted code, a native call is run via `Core.eval` of a
# scope-installing expression. Its arguments must be spliced as literal values: an
# AST-significant argument such as the `Symbol` in `string(:abcsym)` would otherwise be
# re-evaluated as a variable reference and throw `UndefVarError(:abcsym)`.
symarg_func() = @with sval1 => 2 string(:abcsym, sval1[])
let frame = JuliaInterpreter.enter_call(symarg_func)
    @test "abcsym2" == JuliaInterpreter.finish_and_return!(NonRecursiveInterpreter(), frame)
end

# ScopedValue state must not leak when an exception unwinds out of an @with block
const sval_leak = ScopedValue(1)
sval_leak_f() = try
    @with sval_leak => 2 begin
        error("boom")
    end
catch
    sval_leak[]
end
@test sval_leak_f() == 1
@test 1 == @interpret sval_leak_f()

end # module test_interpret_scopedvalues
