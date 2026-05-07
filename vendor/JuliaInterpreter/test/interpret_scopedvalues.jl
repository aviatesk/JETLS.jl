module interpret_scopedvalues

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

end # module interpret_scopedvalues
