using CodeTracking, JuliaInterpreter, Test
using JuliaInterpreter: enter_call, enter_call_expr, get_return
using Base.Meta: isexpr
include("utils.jl")

const ALL_COMMANDS = (:n, :s, :c, :finish, :nc, :se, :si, :until)

function step_through_command(fr::Frame, cmd::Symbol)
    while true
        ret = JuliaInterpreter.debug_command(fr, cmd)
        ret == nothing && break
        fr, pc = ret
    end
    @test fr.callee === nothing
    @test fr.caller === nothing
    return get_return(fr)
end

function step_through_frame(frame_creator)
    rets = []
    for cmd in ALL_COMMANDS
        frame = frame_creator()
        ret = step_through_command(frame, cmd)
        push!(rets, ret)
    end
    @test all(ret -> ret == rets[1], rets)
    return rets[1]
end
step_through(f, args...; kwargs...) = step_through_frame(() -> enter_call(f, args...; kwargs...))
step_through(expr::Expr) = step_through_frame(() -> enter_call_expr(expr))

@generated function generatedfoo(T)
    :(return $T)
end
callgenerated() = generatedfoo(1)
@generated function generatedparams(a::Array{T,N}) where {T,N}
    :(return ($T,$N))
end
callgeneratedparams() = generatedparams([1 2; 3 4])

macro insert_some_calls()
    esc(quote
        x = sin(b)
        y = asin(x)
        z = sin(y)
    end)
end

trivial(x) = x

struct B{T} end

# Putting this into a @testset introduces a closure that breaks the kwprep detection
function complicated_keyword_stuff(a, b=-1; x=1, y=2)
    a == a
    (a, b, :x=>x, :y=>y)
end
function complicated_keyword_stuff_splatargs(args...; x=1, y=2)
    args[1] == args[1]
    (args..., :x=>x, :y=>y)
end
function complicated_keyword_stuff_splatkws(a, b=-1; kw...)
    a == a
    (a, b, kw...)
end
function complicated_keyword_stuff_splat2(args...; kw...)
    args[1] == args[1]
    (args..., kw...)
end

# @testset "Debug" begin
    @testset "Basics" begin
        frame = enter_call(map, x->2x, 1:10)
        @test debug_command(frame, :finish) === nothing
        @test frame.caller === frame.callee === nothing
        @test get_return(frame) == map(x->2x, 1:10)

        for func in (complicated_keyword_stuff, complicated_keyword_stuff_splatargs,
                     complicated_keyword_stuff_splatkws, complicated_keyword_stuff_splat2)
            for (args, kwargs) in (((1,), ()), ((1, 2), (x=7, y=33)))
                oframe = frame = enter_call(func, args...; kwargs...)
                frame = JuliaInterpreter.maybe_step_through_kwprep!(frame, false)
                frame = JuliaInterpreter.maybe_step_through_wrapper!(frame)
                @test JuliaInterpreter.hasarg(JuliaInterpreter.isidentical(QuoteNode(==)), frame.framecode.src.code) || JuliaInterpreter.hasarg(JuliaInterpreter.isidentical(GlobalRef(@__MODULE__, :(==))), frame.framecode.src.code)
                f, pc = debug_command(frame, :n)
                @test f === frame
                @test isa(pc, Int)
                @test oframe.callee !== nothing
                @test debug_command(frame, :finish) === nothing
                @test oframe.caller === oframe.callee === nothing
                @test get_return(oframe) == func(args...; kwargs...)

                @test @interpret(complicated_keyword_stuff(args...; kwargs...)) == complicated_keyword_stuff(args...; kwargs...)
            end
        end

        let f22() = string(:(a+b))
            @test step_through(f22) == "a + b"
        end
        let f22() = string(QuoteNode(:a))
            @test step_through(f22) == ":a"
        end

        frame = enter_call(trivial, 2)
        @test debug_command(frame, :s) === nothing
        @test get_return(frame) == 2

        @test step_through(trivial, 2) == 2
        @test step_through(:($(+)(1,2.5))) == 3.5
        @test step_through(:($(sin)(1))) == sin(1)
        @test step_through(:($(gcd)(10,20))) == gcd(10, 20)
    end

    @testset "until" begin
        function f_with_lines(s)
            sin(2.0)
            cos(2.0)
            for i in 1:100
                s += i
            end
            sin(2.0)
        end
        meth_def = @__LINE__() - 8

        frame = enter_call(f_with_lines, 0)
        @test whereis(frame)[2] == meth_def + 1
        debug_command(frame, :until)
        @test whereis(frame)[2] == meth_def + 2
        debug_command(frame, :until; line=(meth_def + 4))
        @test whereis(frame)[2] == meth_def + 4
        debug_command(frame, :until; line=(meth_def + 6))
        @test whereis(frame)[2] == meth_def + 6
    end

    @testset "generated" begin
        let frame = enter_call_expr(:($(callgenerated)()))
            cframe, pc = debug_command(frame, :s)
            @test isa(pc, BreakpointRef)
            @test JuliaInterpreter.scopeof(cframe).name === :generatedfoo
            @test debug_command(cframe, :c) === nothing
            @test cframe.callee === nothing
            @test get_return(cframe) === Int
        end
        # This time, step into the generated function itself
        let frame = enter_call_expr(:($(callgenerated)()))
            cframe, pc = debug_command(frame, :sg)
            # Aside: generators can have `Expr(:line, ...)` in their line tables, test that this is OK
            lt = JuliaInterpreter.linetable(cframe, 2)
            @test isexpr(lt, :line) || isa(lt, Core.LineInfoNode) || isa(lt, Base.IRShow.LineInfoNode)
            @test isa(pc, BreakpointRef)
            @test JuliaInterpreter.scopeof(cframe).name === :generatedfoo
            cframe, pc = debug_command(cframe, :finish)
            @test JuliaInterpreter.scopeof(cframe).name === :callgenerated
            # Now finish the regular function
            @test debug_command(cframe, :finish) === nothing
            @test cframe.callee === nothing
            @test get_return(cframe) === 1
        end

        # Parametric generated function (see #157)
        let frame = fr = JuliaInterpreter.enter_call(callgeneratedparams)
            while fr.pc < JuliaInterpreter.nstatements(fr.framecode) - 1
                fr, pc = debug_command(fr, :se)
            end
            fr, pc = debug_command(fr, :sg)
            @test JuliaInterpreter.scopeof(fr).name === :generatedparams
            fr, pc = debug_command(fr, :finish)
            @test debug_command(fr, :finish) === nothing
            @test JuliaInterpreter.get_return(fr) == (Int, 2)
        end
    end

    @testset "Optional arguments" begin
        function optional(n = sin(1))
            x = asin(n)
            cos(x)
        end
        frame = JuliaInterpreter.enter_call_expr(:($(optional)()))
        # Step through the wrapper
        f = JuliaInterpreter.maybe_step_through_wrapper!(frame)
        @test frame !== f
        # asin(n)
        f, pc = debug_command(f, :n)
        # cos(1.0)
        f, pc = debug_command(f, :n)
        # return
        @test debug_command(f, :n) === nothing
    end

    @testset "Keyword arguments" begin
        f(x; b = 1) = x+b
        g() = f(1; b = 2)
        frame = JuliaInterpreter.enter_call_expr(:($(g)()));
        fr, pc = debug_command(frame, :nc)
        fr, pc = debug_command(fr, :nc)
        fr, pc = debug_command(fr, :nc)
        fr, pc = debug_command(fr, :s)
        fr, pc = debug_command(fr, :finish)
        @test debug_command(fr, :finish) === nothing
        @test frame.callee === nothing
        @test get_return(frame) == 3

        frame = JuliaInterpreter.enter_call(f, 2; b = 4)
        fr = JuliaInterpreter.maybe_step_through_wrapper!(frame)
        fr, pc = debug_command(fr, :nc)
        if !isa(pc_expr(fr, pc), Core.ReturnNode)   # Julia 1.12 has an extra step for global lookup
            fr, pc = debug_command(fr, :nc)
        end
        debug_command(fr, :nc)
        @test get_return(frame) == 6
    end

    @testset "Optional + keyword wrappers" begin
        opkw(a, b=1; c=2, d=3) = 1
        callopkw1() = opkw(0)
        callopkw2() = opkw(0, -1)
        callopkw3() = opkw(0; c=-2)
        callopkw4() = opkw(0, -1; c=-2)
        callopkw5() = opkw(0; c=-2, d=-3)
        callopkw6() = opkw(0, -1; c=-2, d=-3)
        scopes = Method[]
        for f in (callopkw1, callopkw2, callopkw3, callopkw4, callopkw5, callopkw6)
            frame = fr = JuliaInterpreter.enter_call(f)
            pc = fr.pc
            while pc <= JuliaInterpreter.nstatements(fr.framecode) - 2
                fr, pc = debug_command(fr, :se)
            end
            fr, pc = debug_command(frame, :si)
            @test stacklength(frame) == 2
            frame = fr = JuliaInterpreter.enter_call(f)
            pc = fr.pc
            while pc <= JuliaInterpreter.nstatements(fr.framecode) - 2
                fr, pc = debug_command(fr, :se)
            end
            fr, pc = debug_command(frame, :s)
            @test stacklength(frame) > 2
            push!(scopes, JuliaInterpreter.scopeof(fr))
        end
        @test length(unique(scopes)) == 1  # all get to the body method
    end

    @testset "Macros" begin
        # Work around the fact that we can't detect macro expansions if the macro
        # is defined in the same file
        include_string(Main, """
        function test_macro()
            a = sin(5)
            b = asin(a)
            @insert_some_calls
            z
        end
        ""","file.jl")
        frame = JuliaInterpreter.enter_call_expr(:($(test_macro)()))
        f, pc = debug_command(frame, :n)        # a is set
        f, pc = debug_command(f, :n)            # b is set
        f, pc = debug_command(f, :n)            # x is set
        f, pc = debug_command(f, :n)            # y is set
        f, pc = debug_command(f, :n)            # z is set
        @test debug_command(f, :n) === nothing  # return
    end

    @testset "Quoting" begin
        # Test that symbols don't get an extra QuoteNode
        f_symbol() = :limit => true
        frame = JuliaInterpreter.enter_call(f_symbol)
        fr, pc = debug_command(frame, :s)
        fr, pc = debug_command(fr, :finish)
        @test debug_command(fr, :finish) === nothing
        @test get_return(frame) == f_symbol()
    end

    @testset "Varargs" begin
        f_va_inner(x) = x + 1
        f_va_outer(args...) = f_va_inner(args...)
        frame = fr = JuliaInterpreter.enter_call(f_va_outer, 1)
        # depending on whether this is in or out of a @testset, the first statement may differ
        stmt1 = fr.framecode.src.code[1]
        if isexpr(stmt1, :call) && JuliaInterpreter.lookup(frame, stmt1.args[1]) === getfield
            fr, pc = debug_command(fr, :se)
        end
        fr, pc = debug_command(fr, :s)
        fr, pc = debug_command(fr, :n)
        @test root(fr) !== fr
        fr, pc = debug_command(fr, :finish)
        @test debug_command(fr, :finish) === nothing
        @test get_return(frame) === 2
    end

    @testset "ASTI#17" begin
        function (::B)(y)
            x = 42*y
            return x + y
        end
        B_inst = B{Int}()
        step_through(B_inst, 10) == B_inst(10)
    end

    @testset "Exceptions" begin
        # Don't break on caught exceptions
        err_caught = Any[nothing]
        function f_exc_outer()
            try
                f_exc_inner()
            catch err;
                err_caught[1] = err
            end
            x = 1 + 1
            return x
        end
        f_exc_inner() = error()
        fr = JuliaInterpreter.enter_call(f_exc_outer)
        fr, pc = debug_command(fr, :s)
        fr, pc = debug_command(fr, :n)
        fr, pc = debug_command(fr, :n)
        debug_command(fr, :finish)
        @test get_return(fr) == 2
        @test first(err_caught) isa ErrorException
        @test stacklength(fr) == 1

        err_caught = Any[nothing]
        fr = JuliaInterpreter.enter_call(f_exc_outer)
        fr, pc = debug_command(fr, :s)
        debug_command(fr, :c)
        @test get_return(root(fr)) == 2
        @test first(err_caught) isa ErrorException
        @test stacklength(root(fr)) == 1

        # Rethrow on uncaught exceptions
        f_outer() = g_inner()
        g_inner() = error()
        fr = JuliaInterpreter.enter_call(f_outer)
        @test_throws ErrorException debug_command(fr, :finish)
        @test stacklength(fr) == 3

        # Break on error
        try
            break_on(:error)
            fr = JuliaInterpreter.enter_call(f_outer)
            fr, pc = debug_command(fr, :finish)
            @test fr.framecode.scope.name === :error

            fundef() = undef_func()
            frame = JuliaInterpreter.enter_call(fundef)
            fr, pc = debug_command(frame, :s)
            @test isa(pc, BreakpointRef)
            @test pc.err isa UndefVarError
        finally
            break_off(:error)
        end
    end

    @testset "breakpoints" begin
        # In source breakpoints
        function f_bp(x)
            #=1=#    i = 1
            #=2=#    @label foo
            #=3=#    @bp
            #=4=#    repr("foo")
            #=5=#    i += 1
            #=6=#    i > 3 && return x
            #=7=#    @goto foo
        end
        ln = @__LINE__
        method_start = ln - 9
        fr = enter_call(f_bp, 2)
        @test JuliaInterpreter.linenumber(fr) == method_start + 1
        fr, pc =  JuliaInterpreter.debug_command(fr, :c)
        # Hit the breakpoint x1
        @test JuliaInterpreter.linenumber(fr) == method_start + 3
        @test pc isa BreakpointRef
        fr, pc =  JuliaInterpreter.debug_command(fr, :n)
        @test JuliaInterpreter.linenumber(fr) == method_start + 4
        fr, pc =  JuliaInterpreter.debug_command(fr, :c)
        # Hit the breakpoint again x2
        @test pc isa BreakpointRef
        @test JuliaInterpreter.linenumber(fr) == method_start + 3
        fr, pc =  JuliaInterpreter.debug_command(fr, :c)
        # Hit the breakpoint for the last time x3
        @test pc isa BreakpointRef
        @test JuliaInterpreter.linenumber(fr) == method_start + 3
        JuliaInterpreter.debug_command(fr, :c)
        @test get_return(fr) == 2
    end

    f_inv(x::Real) = x^2;
    f_inv(x::Integer) = 1 + invoke(f_inv, Tuple{Real}, x)
    @testset "invoke" begin
        fr = JuliaInterpreter.enter_call(f_inv, 2)
        fr, pc = JuliaInterpreter.debug_command(fr, :s) # apply_type
        frame, pc = JuliaInterpreter.debug_command(fr, :s) # step into invoke
        @test frame.framecode.scope.sig == Tuple{typeof(f_inv),Real}
        JuliaInterpreter.debug_command(frame, :c)
        frame = root(frame)
        @test get_return(frame) == f_inv(2)
    end

    f_inv_latest(x::Real) = 1 + Core._call_latest(f_inv, x)
    @testset "invokelatest" begin
        fr = JuliaInterpreter.enter_call(f_inv_latest, 2.0)
        fr, pc = JuliaInterpreter.debug_command(fr, :nc)
        while is_getproperty(pc_expr(fr, pc).args[1])    # Julia 1.12 has more steps for global lookup
            fr, pc = JuliaInterpreter.debug_command(fr, :nc)
        end
        frame, pc = JuliaInterpreter.debug_command(fr, :s) # step into invokelatest
        @test frame.framecode.scope.sig == Tuple{typeof(f_inv),Real}
        JuliaInterpreter.debug_command(frame, :c)
        frame = root(frame)
        @test get_return(frame) == f_inv_latest(2.0)
    end

    @testset "Issue #178" begin
        remove()
        a = [1, 2, 3, 4]
        @breakpoint length(LinearIndices(a))
        frame, bp = @interpret sum(a)
        @test debug_command(frame, :c) === nothing
        @test get_return(frame) == sum(a)
    end

    @testset "Stepping over kwfunc preparation" begin
        stepkw! = JuliaInterpreter.maybe_step_through_kwprep! # for brevity
        a = [4, 1, 3, 2]
        reversesort(x) = sort(x; rev=true)
        frame = JuliaInterpreter.enter_call(reversesort, a)
        frame = stepkw!(frame)
        @test frame.pc == JuliaInterpreter.nstatements(frame.framecode) - 1

        scopedreversesort(x) = Base.sort(x, rev=true)  # https://github.com/JuliaDebug/Debugger.jl/issues/141
        frame = JuliaInterpreter.enter_call(scopedreversesort, a)
        frame = stepkw!(frame)
        @test frame.pc == JuliaInterpreter.nstatements(frame.framecode) - 1

        frame = JuliaInterpreter.enter_call(sort, a)
        frame = stepkw!(frame)
        @test frame.pc == JuliaInterpreter.nstatements(frame.framecode) - 1

        frame, pc = debug_command(frame, :s)
        frame, pc = debug_command(frame, :se)  # get past copymutable
        if JuliaInterpreter.isbindingresolved_deprecated
            frame, pc = debug_command(frame, :se)  # there's an extra line for the GlobalRef
        end
        frame = stepkw!(frame)
        @test frame.pc > 4

        frame = JuliaInterpreter.enter_call(sort, a; rev=true)
        frame, pc = debug_command(frame, :se)
        frame, pc = debug_command(frame, :s)
        frame, pc = debug_command(frame, :se)  # get past copymutable
        if JuliaInterpreter.isbindingresolved_deprecated
            frame, pc = debug_command(frame, :se)  # there's an extra line for the GlobalRef
        end
        frame = stepkw!(frame)
        @test frame.pc == JuliaInterpreter.nstatements(frame.framecode) - 1
    end

    function f(x, y)
        sin(2.0)
        g(x; y = 3)
    end
    g(x; y) = x + y
    @testset "interaction of :n with kw functions" begin
        frame = JuliaInterpreter.enter_call(f, 2, 3) # at sin
        frame, pc = debug_command(frame, :n)
        # Check that we are at the kw call to g
        @test Core.kwfunc(g) == JuliaInterpreter.lookup(frame, JuliaInterpreter.pc_expr(frame).args[1])
        # Step into the inner g
        frame, pc = debug_command(frame, :s)
        # Finish the frame and make sure we step out of the wrapper
        frame, pc = debug_command(frame, :finish)
        @test frame.framecode.scope == @which f(2, 3)
    end

    h_1(x, y) = h_2(x, y)
    h_2(x, y) = h_3(x; y=y)
    h_3(x; y = 2) = x + y
    @testset "stepping through kwprep after stepping through wrapper" begin
        frame = JuliaInterpreter.enter_call(h_1, 2, 1)
        frame, pc = debug_command(frame, :s)
        # Should have skipped the kwprep in h_2 and be at call to kwfunc h_3
        @test Core.kwfunc(h_3) == JuliaInterpreter.lookup(frame, JuliaInterpreter.pc_expr(frame).args[1])
    end

    @testset "si should not step through wrappers or kwprep" begin
        frame = JuliaInterpreter.enter_call(h_1, 2, 1)
        frame, pc = debug_command(frame, :si)
        @test frame.pc == (@static VERSION >= v"1.11-" ? 2 : 1)
    end

    @testset "breakpoints hit during wrapper step through" begin
        f(x = g()) = x
        g() = 5
        @breakpoint g()
        frame = JuliaInterpreter.enter_call(f)
        JuliaInterpreter.maybe_step_through_wrapper!(frame)
        @test leaf(frame).framecode.scope == @which g()
    end

    @testset "preservation of stack when throwing to toplevel" begin
        f() = "αβ"[2]
        frame1 = JuliaInterpreter.enter_call(f);
        err = try debug_command(frame1, :c)
        catch err
            err
        end
        try
            break_on(:error)
            frame2, pc = @interpret f()
            @test leaf(frame2).framecode.scope === leaf(frame1).framecode.scope
        finally
            break_off(:error)
        end
    end

    @testset "breakpoint in next line" begin
        function f(a, b)
            a == 0 && return abs(b)
            @bp
            return b
        end

        frame = JuliaInterpreter.enter_call(f, 5, 10)
        frame, pc = JuliaInterpreter.debug_command(frame, :n)
        @test pc isa BreakpointRef
    end

    @testset "kw wrapper heuristic #435" begin
        foo() = UInt8('\t')
        frame = JuliaInterpreter.enter_call(foo)
        frame, pc = debug_command(frame, :s)
        @test pc isa BreakpointRef
    end
# end

module InterpretedModuleTest
    using ..JuliaInterpreter
    function f(x)
        x
        @bp
        x
    end
end
@testset "interpreted methods" begin
    push!(JuliaInterpreter.compiled_modules, InterpretedModuleTest)
    frame = JuliaInterpreter.enter_call(5) do x
        InterpretedModuleTest.f(5)
    end
    frame, pc = JuliaInterpreter.debug_command(frame, :n)
    @test !(pc isa BreakpointRef)

    push!(JuliaInterpreter.interpreted_methods, first(methods(InterpretedModuleTest.f)))
    frame = JuliaInterpreter.enter_call(5) do x
        InterpretedModuleTest.f(5)
    end
    frame, pc = JuliaInterpreter.debug_command(frame, :n)
    @test pc isa BreakpointRef
end

@testset "step last call on line" begin
    g(x) = x
    f(x) = x
    h(x) = x
    function z(x)
        a = h(f(x) + g(x) - 3)
        x = 3
        b = h(g(x))
    end
    frame = JuliaInterpreter.enter_call(z, 5)
    frame, pc = JuliaInterpreter.debug_command(frame, :sl)
    @test JuliaInterpreter.scopeof(frame).name === :h
    frame, pc = JuliaInterpreter.debug_command(frame, :finish)
    frame, pc = JuliaInterpreter.debug_command(frame, :sl)
    @test JuliaInterpreter.scopeof(frame).name === :h
end

@testset "step until return" begin
    function f(x)
        if x == 1
            return 2
        end
        return 3
    end
    frame = JuliaInterpreter.enter_call(f, 1)
    frame, _ = JuliaInterpreter.debug_command(frame, :sr)
    @test JuliaInterpreter.get_return(frame) == f(1)
    frame = JuliaInterpreter.enter_call(f, 4)
    frame, _ = JuliaInterpreter.debug_command(frame, :sr)
    @test JuliaInterpreter.get_return(frame) == f(4)
    function g()
        y = f(1) + f(2)
        return y
    end
    frame = JuliaInterpreter.enter_call(g)
    frame, _ = JuliaInterpreter.debug_command(frame, :sr)
    @test JuliaInterpreter.get_return(frame) == g()
end
