module test_eval

using JuliaInterpreter, Test
using JuliaInterpreter: debug_command, enter_call, finish_and_return!, finish_stack!,
    get_return, scopeof

module Target
    const calls = Ref(0)
    seed = 17

    function callee(x)
        calls[] += 1
        return x + 1
    end

    function thrower(err)
        calls[] += 1
        throw(err)
    end
end

core_eval(mod, ex) = Core.eval(mod, ex)
base_eval(mod, ex) = Base.eval(mod, ex)
macro_eval(mod, ex) = @eval mod $ex
invoke_eval(mod, ex) = Core.invoke(Core.eval, Tuple{Module, Any}, mod, ex)

function unoptimized_eval_frame(mod, ex)
    method = which(Core.eval, Tuple{Module, Any})
    code = JuliaInterpreter.FrameCode(method, Base.uncompressed_ir(method); optimize=false)
    return JuliaInterpreter.prepare_frame(code, Any[Core.eval, mod, ex], Core.svec())
end

@static if JuliaInterpreter.isdefinedglobal(Base, :ScopedValues)
    const eval_scope = Base.ScopedValues.ScopedValue(1)
    scoped_reader() = eval_scope[]

    function scoped_eval()
        inside = Base.ScopedValues.@with eval_scope => 2 begin
            Core.eval(@__MODULE__, :(scoped_reader()))
        end
        return inside, eval_scope[]
    end

    macro read_eval_scope()
        return eval_scope[]
    end

    function scoped_macro_eval()
        inside = Base.ScopedValues.@with eval_scope => 2 begin
            Core.eval(@__MODULE__, :(@read_eval_scope()))
        end
        return inside, eval_scope[]
    end
end

function eval_with_effects(mod, ex, effects)
    effects[1] += 1
    value = Core.eval(mod, ex)
    effects[4] += 1
    return value
end

function eval_in_old_world(f, mod, ex)
    before = f(1)
    value = Core.eval(mod, ex)
    after = f(1)
    return before, value, after
end

function catch_eval(mod, ex, effects)
    effects[1] += 1
    try
        Core.eval(mod, ex)
    catch err
        effects[2] += 1
        return err
    end
    return :not_caught
end

function finish_with_command(frame, cmd)
    current = leaf(frame)
    for _ in 1:2000
        # The root is a method even when the active frame belongs to eval.
        ret = debug_command(RecursiveInterpreter(), current, cmd, false)
        ret === nothing && return get_return(frame)
        current = ret[1]
    end
    error("eval did not finish after 2000 $cmd commands")
end

function check_eval_stack(frame, mod, f; min_toplevel_frames=1)
    @test scopeof(frame) isa Method
    @test frame.caller === nothing
    current = leaf(frame)
    @test scopeof(current) === only(methods(f))
    @test root(current) === frame
    ntoplevel = 0
    while current !== frame
        if scopeof(current) === mod
            ntoplevel += 1
            @test current.world >= frame.world
        end
        parent = current.caller
        @test parent isa Frame
        parent isa Frame || break
        @test parent.callee === current
        current = parent
    end
    @test ntoplevel >= min_toplevel_frames
end

@testset "Recursive Core.eval" begin
    @testset "Values and globals ($interp)" for interp in (RecursiveInterpreter(), NonRecursiveInterpreter())
        quoted = :(this_expression_is_data + 1)
        for (ex, expected) in ((42, 42), (nothing, nothing), (:seed, 17),
                               (QuoteNode(:seed), :seed), (QuoteNode(quoted), quoted),
                               (:(seed + 1), 18))
            frame = enter_call(core_eval, Target, ex)
            @test finish_and_return!(interp, frame) == expected
        end
        frame = enter_call(core_eval, Target, :eval_test_unbound_symbol)
        @test_throws UndefVarError finish_and_return!(interp, frame)
    end

    @testset "Toplevel return values with line nodes" begin
        lnn = LineNumberNode(42, :eval_return_test)
        for (stmts, expected, ncalls) in ((Any[], nothing, 0),
                                          (Any[lnn], nothing, 0),
                                          (Any[:(callee(41))], 42, 1),
                                          (Any[lnn, :(callee(41))], 42, 1),
                                          (Any[:(callee(41)), lnn], nothing, 1),
                                          (Any[:(callee(41)), lnn, lnn], nothing, 1))
            ex = Expr(:toplevel, stmts...)
            Target.calls[] = 0
            @test Core.eval(Target, ex) === expected
            @test Target.calls[] == ncalls
            Target.calls[] = 0
            @test finish_and_return!(Frame(Target, ex), true) === expected
            @test Target.calls[] == ncalls
            Target.calls[] = 0
            frame = enter_call(core_eval, Target, ex)
            @test finish_and_return!(RecursiveInterpreter(), frame) === expected
            @test Target.calls[] == ncalls
        end
    end

    @testset "IR nodes and quoted expressions are data" begin
        node = Core.ReturnNode(9)
        @test Core.eval(Target, node) === node
        frame = enter_call(Core.eval, Target, node)
        @test finish_and_return!(RecursiveInterpreter(), frame) === node

        quoted = :(callee(41))
        Target.calls[] = 0
        @test Core.eval(Target, QuoteNode(quoted)) == quoted
        frame = enter_call(Core.eval, Target, QuoteNode(quoted))
        @test finish_and_return!(RecursiveInterpreter(), frame) == quoted
        @test Target.calls[] == 0
    end

    @testset "Lowered eval payload" begin
        payload = Meta.lower(Target, :(callee(41)))
        @test Meta.isexpr(payload, :thunk)
        Target.calls[] = 0
        frame = enter_call(Core.eval, Target, payload)
        @test finish_and_return!(RecursiveInterpreter(), frame) == 42
        @test Target.calls[] == 1

        Target.calls[] = 0
        bp = breakpoint(Target.callee)
        try
            frame = enter_call(Core.eval, Target, payload)
            ret = finish_and_return!(RecursiveInterpreter(), frame)
            @test ret isa BreakpointRef
            if ret isa BreakpointRef
                check_eval_stack(frame, Target, Target.callee)
                @test Target.calls[] == 0
                @test finish_stack!(RecursiveInterpreter(), frame, false) == 42
            end
            @test Target.calls[] == 1
            @test frame.callee === nothing
        finally
            remove(bp)
        end
    end

    @testset "Definitions ($interp)" for interp in (RecursiveInterpreter(), NonRecursiveInterpreter())
        mod = Module(gensym(:EvalDefinitions))
        ex = quote
            global value = 7
            struct Item
                value::Int
            end
            read_item(x::Item) = x.value
            global item = Item(value)
            read_item(item)
        end
        @test finish_and_return!(interp, enter_call(core_eval, mod, ex)) == 7
        itemtype = Base.invokelatest(getglobal, mod, :Item)
        item = Base.invokelatest(getglobal, mod, :item)
        reader = Base.invokelatest(getglobal, mod, :read_item)
        @test parentmodule(itemtype) === mod
        @test item isa itemtype
        @test Base.invokelatest(reader, item) == 7
        @test Base.invokelatest(getglobal, mod, :value) == 7

        ex = quote
            module Child
                const value = 11
                read_value() = value
            end
            Child.read_value()
        end
        ex = Expr(:toplevel, ex.args...)
        @test finish_and_return!(interp, enter_call(core_eval, mod, ex)) == 11
        child = Base.invokelatest(getglobal, mod, :Child)
        @test parentmodule(child) === mod
        @test Base.invokelatest(getglobal, child, :value) == 11
    end

    @testset "Function definition binding checks" begin
        mod = Module(gensym(:EvalBindings))
        Core.eval(mod, :(struct Value end))
        Core.eval(mod, :(value = Value()))
        ex = :(value(x) = x)
        @test_throws ErrorException Core.eval(mod, ex)
        @test_throws ErrorException finish_and_return!(enter_call(core_eval, mod, ex))

        Core.eval(mod, :(module Provider; f() = 0; end))
        Core.eval(mod, :(using .Provider: f))
        ex = :(f(x::Int) = x + 1)
        @test_throws ErrorException Core.eval(mod, ex)
        @test_throws ErrorException finish_and_return!(enter_call(core_eval, mod, ex))

        Core.eval(mod, :(import .Provider: f))
        f = Core.eval(mod, :f)
        @test finish_and_return!(enter_call(core_eval, mod, ex)) === f
        @test Base.invokelatest(f, 1) == 2
        ex = :(Provider.f(x::Float64) = x + 2; Provider.f(1.0))
        @test finish_and_return!(enter_call(core_eval, mod, ex)) == 3.0
        @test Base.invokelatest(f, 1.0) == 3.0
    end

    # The module semantics are those of `Frame` (see test/toplevel.jl); these tests cover
    # how eval connects them to the calling method.
    @testset "Module evaluation ($interp)" for interp in (RecursiveInterpreter(), NonRecursiveInterpreter())
        mod = Module(gensym(:EvalModules))
        log = Symbol[]
        ex = :(module Child
            __init__() = push!($log, :init)
        end)
        # Each eval creates a fresh module, initializes it, and evaluates to it.
        old = finish_and_return!(interp, enter_call(core_eval, mod, ex))
        new = finish_and_return!(interp, enter_call(core_eval, mod, ex))
        @test old isa Module && new isa Module && old !== new
        @test Base.invokelatest(getglobal, mod, :Child) === new
        @test log == [:init, :init]
        Core.eval(mod, :(macro make_module() esc(:(module MacroMade end)) end))
        made = finish_and_return!(interp, enter_call(core_eval, mod, :(@make_module)))
        @test made isa Module && nameof(made) === :MacroMade
        # A failing `__init__` reaches the caller's `catch`.
        effects = zeros(Int, 3)
        frame = enter_call(catch_eval, mod, :(module BadInit; __init__() = error("init failed"); end), effects)
        err = finish_and_return!(interp, frame)
        @test err isa InitError && err.mod === :BadInit
        @test effects == [1, 1, 0]
    end

    @testset "Resume a module body in eval with $cmd" for cmd in (:finish_stack, :s, :finish, :c)
        mod = Module(gensym(:EvalModuleResume))
        effects = zeros(Int, 4)
        log = Symbol[]
        ex = :(module Paused
            value = $(Target.callee)(41)
            __init__() = push!($log, :init)
        end)
        Target.calls[] = 0
        bp = breakpoint(Target.callee)
        try
            frame = enter_call(eval_with_effects, mod, ex, effects)
            ret = finish_and_return!(RecursiveInterpreter(), frame)
            @test ret isa BreakpointRef
            if ret isa BreakpointRef
                check_eval_stack(frame, mod, Target.callee)
                @test isempty(log)
                result = cmd === :finish_stack ? finish_stack!(RecursiveInterpreter(), frame, false) :
                                                finish_with_command(frame, cmd)
                paused = Base.invokelatest(getglobal, mod, :Paused)
                @test result === paused
                @test Base.invokelatest(getglobal, paused, :value) == 42
            end
            @test log == [:init]
            @test effects == [1, 0, 0, 1]
            @test frame.callee === nothing
        finally
            remove(bp)
        end
    end

    @testset "Latest eval world, fixed caller world ($interp)" for interp in (RecursiveInterpreter(), NonRecursiveInterpreter())
        mod = Module(gensym(:EvalWorld))
        f = Core.eval(mod, :(dispatch(::Any) = :old))
        world = Base.get_world_counter()
        ex = quote
            dispatch(::Float64) = :defined_inside_eval
            (dispatch(1), dispatch(1.0))
        end
        frame = enter_call(eval_in_old_world, f, mod, ex; world)
        Core.eval(mod, :(dispatch(::Int) = :new))
        @test frame.world == world
        @test finish_and_return!(interp, frame) ===
              (:old, (:new, :defined_inside_eval), :old)
        @test frame.world == world
        @test Base.invokelatest(f, 1) === :new
    end

    @testset "Nested eval preserves the enclosing thunk's world" begin
        native_mod = Module(gensym(:NativeNestedWorld))
        interpreted_mod = Module(gensym(:InterpretedNestedWorld))
        for mod in (native_mod, interpreted_mod)
            Core.eval(mod, :(f() = :old))
        end
        ex = quote
            Core.eval(@__MODULE__, :(f() = :new))
            f()
        end
        # Since Julia 1.12, a thunk's world advances only at `:latestworld`.
        native = Core.eval(native_mod, ex)
        @test native === (VERSION >= v"1.12-" ? :old : :new)
        frame = enter_call(core_eval, interpreted_mod, ex)
        @test finish_and_return!(RecursiveInterpreter(), frame) === native
        @test Core.eval(interpreted_mod, :(f())) === :new
    end

    @testset "Nested eval through $wrapper" for wrapper in (core_eval, base_eval, macro_eval)
        mod = Module(gensym(:NestedEval))
        inner = :($(Target.callee)(41))
        ex = :(Core.eval(@__MODULE__, $(QuoteNode(inner))))
        Target.calls[] = 0
        bp = breakpoint(Target.callee)
        try
            frame = enter_call(wrapper, mod, ex)
            world = frame.world
            ret = finish_and_return!(RecursiveInterpreter(), frame)
            @test ret isa BreakpointRef
            if ret isa BreakpointRef
                check_eval_stack(frame, mod, Target.callee; min_toplevel_frames=2)
                @test Target.calls[] == 0
                @test finish_stack!(RecursiveInterpreter(), frame, false) == 42
            end
            @test frame.world == world
            @test Target.calls[] == 1
            @test frame.callee === nothing
        finally
            remove(bp)
        end
    end

    @testset "Resume eval with $cmd" for cmd in (:finish_stack, :s, :si, :finish, :c)
        mod = Module(gensym(:ResumeEval))
        effects = zeros(Int, 4)
        ex = quote
            $effects[2] += 1
            global value = $(Target.callee)(41)
            after_pause() = value
            $effects[3] += 1
            Core.eval(@__MODULE__, :(after_pause()))
        end
        Target.calls[] = 0
        bp = breakpoint(Target.callee)
        try
            frame = enter_call(eval_with_effects, mod, ex, effects)
            world = frame.world
            ret = finish_and_return!(RecursiveInterpreter(), frame)
            @test ret isa BreakpointRef
            if ret isa BreakpointRef
                check_eval_stack(frame, mod, Target.callee)
                @test effects == [1, 1, 0, 0]
                @test Target.calls[] == 0
                result = cmd === :finish_stack ? finish_stack!(RecursiveInterpreter(), frame, false) :
                                                finish_with_command(frame, cmd)
                @test result == 42
            end
            @test effects == ones(Int, 4)
            @test Target.calls[] == 1
            @test frame.world == world
            @test frame.callee === nothing
            @test Base.invokelatest(getglobal, mod, :value) == 42
        finally
            remove(bp)
        end
    end

    @testset "Outer interpreted catch ($interp)" for interp in (RecursiveInterpreter(), NonRecursiveInterpreter())
        effects = zeros(Int, 3)
        err = ArgumentError("error inside eval")
        ex = quote
            $(Target.thrower)($err)
            $effects[3] += 1
        end
        Target.calls[] = 0
        frame = enter_call(catch_eval, Target, ex, effects)
        @test finish_and_return!(interp, frame) === err
        @test effects == [1, 1, 0]
        @test Target.calls[] == 1
        @test frame.callee === nothing

        # Symbol evaluation can throw without entering a lowered expression frame.
        effects .= 0
        frame = enter_call(catch_eval, Target, :eval_test_unbound_symbol, effects)
        @test finish_and_return!(interp, frame) isa UndefVarError
        @test effects == [1, 1, 0]
    end

    @testset "Eval syntax errors match native exceptions" begin
        for ex in (:(break), Expr(:incomplete, "bad"))
            native = try
                Core.eval(Target, ex)
            catch err
                err
            end
            @test native isa Exception
            effects = zeros(Int, 3)
            frame = enter_call(catch_eval, Target, ex, effects)
            err = finish_and_return!(RecursiveInterpreter(), frame)
            @test typeof(err) === typeof(native)
            @test sprint(showerror, err) == sprint(showerror, native)
            @test effects == [1, 1, 0]
        end
    end

    @testset "Catch after pausing, $cmd" for cmd in (:finish_stack, :s, :si, :finish, :c)
        effects = zeros(Int, 3)
        err = ArgumentError("error after eval breakpoint")
        ex = quote
            $(Target.thrower)($err)
            $effects[3] += 1
        end
        Target.calls[] = 0
        bp = breakpoint(Target.thrower)
        try
            frame = enter_call(catch_eval, Target, ex, effects)
            world = frame.world
            ret = finish_and_return!(RecursiveInterpreter(), frame)
            @test ret isa BreakpointRef
            if ret isa BreakpointRef
                check_eval_stack(frame, Target, Target.thrower)
                @test effects == [1, 0, 0]
                @test Target.calls[] == 0
                result = cmd === :finish_stack ? finish_stack!(RecursiveInterpreter(), frame, false) :
                                                finish_with_command(frame, cmd)
                @test result === err
            end
            @test effects == [1, 1, 0]
            @test Target.calls[] == 1
            @test frame.world == world
            @test frame.callee === nothing
        finally
            remove(bp)
        end
    end

    @testset "Native eval opt-outs" begin
        bp = breakpoint(Target.callee)
        evalmethod = which(Core.eval, Tuple{Module, Any})
        wascompiled = evalmethod in JuliaInterpreter.compiled_methods
        try
            Target.calls[] = 0
            frame = enter_call(core_eval, Target, :(callee(41)))
            @test finish_and_return!(NonRecursiveInterpreter(), frame) == 42
            @test Target.calls[] == 1
            @test frame.callee === nothing

            push!(JuliaInterpreter.compiled_methods, evalmethod)
            Target.calls[] = 0
            frame = enter_call(core_eval, Target, :(callee(41)))
            @test finish_and_return!(RecursiveInterpreter(), frame) == 42
            @test Target.calls[] == 1
            @test frame.callee === nothing
        finally
            wascompiled || delete!(JuliaInterpreter.compiled_methods, evalmethod)
            remove(bp)
        end
    end

    @testset "Core.eval entry via $entry" for entry in (:invoke, :unoptimized)
        Target.calls[] = 0
        bp = breakpoint(Target.callee)
        try
            frame = if entry === :invoke
                enter_call(invoke_eval, Target, :(callee(41)))
            else
                frame = unoptimized_eval_frame(Target, :(callee(41)))
                @test any(frame.framecode.src.code) do stmt
                    Meta.isexpr(stmt, :call) && stmt.args[1] === JuliaInterpreter.eval_in_frame
                end
                frame
            end
            ret = finish_and_return!(RecursiveInterpreter(), frame)
            @test ret isa BreakpointRef
            if ret isa BreakpointRef
                check_eval_stack(frame, Target, Target.callee)
                @test Target.calls[] == 0
                @test finish_stack!(RecursiveInterpreter(), frame, false) == 42
            end
            @test Target.calls[] == 1
            @test frame.callee === nothing
        finally
            remove(bp)
        end
    end

    @testset ":s enters eval before side effects (optimize=$optimize)" for optimize in (true, false)
        Target.calls[] = 0
        ex = :(calls[] += 1; 42)
        frame = optimize ? enter_call(Core.eval, Target, ex) : unoptimized_eval_frame(Target, ex)
        world = frame.world
        # No function breakpoint: stepping must expose eval's body, not run it natively.
        ret = debug_command(RecursiveInterpreter(), frame, :s, false)
        @test ret isa Tuple{Frame, BreakpointRef}
        @test Target.calls[] == 0
        if ret isa Tuple{Frame, BreakpointRef}
            child, _ = ret
            @test scopeof(child) === Target
            @test child.caller === frame
            @test frame.callee === child
            @test finish_stack!(RecursiveInterpreter(), frame, false) == 42
        end
        @test Target.calls[] == 1
        @test frame.world == world
        @test frame.callee === nothing
    end

    @testset "Step through eval without breakpoints ($cmd)" for cmd in (:s, :si)
        Target.calls[] = 0
        frame = enter_call(Core.eval, Target, :(callee(20 + 21)))
        @test finish_with_command(frame, cmd) == 42
        @test Target.calls[] == 1
        @test frame.callee === nothing
    end

    @testset "Step into a function defined by eval ($cmd)" for cmd in (:s, :si)
        mod = Module(gensym(:EvalStepWorld))
        ex = quote
            f(x) = x + 1
            f(1)
        end
        frame = enter_call(core_eval, mod, ex)
        world = frame.world
        @test finish_with_command(frame, cmd) == 2
        @test frame.world == world
        @test frame.callee === nothing
    end

    @static if JuliaInterpreter.isdefinedglobal(Base, :ScopedValues)
        @testset "Eval lowering inherits interpreted dynamic scope" begin
            @test scoped_macro_eval() == (2, 1)
            frame = enter_call(scoped_macro_eval)
            @test finish_and_return!(RecursiveInterpreter(), frame) == (2, 1)
            @test eval_scope[] == 1
            @test Core.eval(@__MODULE__, :(@read_eval_scope())) == 1
        end

        @testset "Eval inherits interpreted dynamic scope" begin
            bp = breakpoint(scoped_reader)
            try
                frame = enter_call(scoped_eval)
                ret = finish_and_return!(RecursiveInterpreter(), frame)
                @test ret isa BreakpointRef
                @test eval_scope[] == 1
                if ret isa BreakpointRef
                    check_eval_stack(frame, @__MODULE__, scoped_reader)
                    @test finish_stack!(RecursiveInterpreter(), frame, false) == (2, 1)
                end
                @test eval_scope[] == 1
                @test frame.callee === nothing
            finally
                remove(bp)
            end
        end
    end

    @testset "Direct @interpret Core.eval" begin
        @test @interpret(Core.eval(Target, :seed)) == 17
        @test @interpret(Core.eval(Target, QuoteNode(:seed))) === :seed
        Target.calls[] = 0
        bp = breakpoint(Target.callee)
        try
            ret = @interpret Core.eval(Target, :(callee(41)))
            @test ret isa Tuple{Frame, BreakpointRef}
            if ret isa Tuple{Frame, BreakpointRef}
                frame, _ = ret
                @test scopeof(leaf(frame)) === only(methods(Target.callee))
                @test Target.calls[] == 0
                @test finish_stack!(RecursiveInterpreter(), frame, false) == 42
            end
            @test Target.calls[] == 1
            Target.calls[] = 0
            @test (@interpret interp=NonRecursiveInterpreter() Core.eval(Target, :(callee(41)))) == 42
            @test Target.calls[] == 1
        finally
            remove(bp)
        end
    end
end

end # module test_eval
