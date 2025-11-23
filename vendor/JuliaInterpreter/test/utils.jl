using JuliaInterpreter
using JuliaInterpreter: Frame, Interpreter, RecursiveInterpreter
using JuliaInterpreter: finish_and_return!, evaluate_call!, step_expr!, shouldbreak,
                        do_assignment!, SSAValue, isassign, pc_expr, handle_err, get_return,
                        moduleof
using Base.Meta: isexpr
using Test, Random, SHA

@static if JuliaInterpreter.isbindingresolved_deprecated
    is_getproperty(stmt) = JuliaInterpreter.is_global_ref(stmt, Base, :getproperty)
else
    is_getproperty(stmt) = JuliaInterpreter.is_quotenode_egal(stmt, Base.getproperty)
end

function stacklength(frame)
    n = 1
    frame = frame.callee
    while frame !== nothing
        n += 1
        frame = frame.callee
    end
    return n
end

# Execute a frame using Julia's regular compiled-code dispatch for any :call expressions
runframe(frame) = Some{Any}(finish_and_return!(NonRecursiveInterpreter(), frame))

# Execute a frame using the interpreter for all :call expressions (except builtins & intrinsics)
runstack(frame) = Some{Any}(finish_and_return!(frame))

## For juliatests.jl

function read_and_parse(filename)
    src = read(filename, String)
    ex = Base.parse_input_line(src; filename=filename)
end

## For running interpreter frames under resource limitations

struct Aborted    # for signaling that some statement or test blocks were interrupted
    at::Base.IRShow.LineInfoNode
end
const dummylin = length(fieldnames(Base.IRShow.LineInfoNode)) == 5 ? Base.IRShow.LineInfoNode(Main, nothing, :none, Int32(0), Int32(0)) :  # dummy lineinfo for fallback
                                                                     Base.IRShow.LineInfoNode(nothing, :none, Int32(0))

function Aborted(frame::Frame, pc)
    lineidx = JuliaInterpreter.codelocs(frame, pc)
    lineidx == 0 && return Aborted(dummylin)  # fallback to a dummy lineinfo if no location found
    lineinfo = JuliaInterpreter.linetable(frame, lineidx; macro_caller=true)
    return Aborted(lineinfo)
end

mutable struct LimitedExec <: Interpreter
    nstmts::Int
end

"""
    ret, nstmtsleft = evaluate_limited!(interp::Interpreter, frame, nstmts, istoplevel::Bool=true)

Run `frame` until one of:
- execution terminates normally (`ret = Some{Any}(val)`, where `val` is the returned value of `frame`)
- if `istoplevel` and a `thunk` or `method` expression is encountered (`ret = nothing`)
- more than `nstmts` have been executed (`ret = Aborted(lin)`, where `lnn` is the `LineInfoNode` of termination).
"""
function evaluate_limited!(interp::Interpreter, frame::Frame, nstmts::Int, istoplevel::Bool=false)
    limited_interp = LimitedExec(nstmts)
    # The following is like finish!, except we intercept :call expressions so that we can run them
    # with limexec! rather than the default finish_and_return!
    pc = frame.pc
    while nstmts > 0
        shouldbreak(frame, pc) && return BreakpointRef(frame.framecode, pc), limited_interp.nstmts
        stmt = pc_expr(frame, pc)
        # uncomment the following to calibrate `nstmts` in test/limits.jl
        # _lnn_ = Aborted(frame, pc).at
        # _lnn_.file == Symbol("fake.jl") && _lnn_.line == 5 && isa(stmt, Core.GotoIfNot) && @show nstmts
        if isa(stmt, Expr)
            if stmt.head === :call && !isa(interp, NonRecursiveInterpreter)
                limited_interp.nstmts = nstmts
                try
                    rhs = evaluate_call!(limited_interp, frame, stmt)
                    isa(rhs, Aborted) && return rhs, limited_interp.nstmts
                    lhs = SSAValue(pc)
                    do_assignment!(frame, lhs, rhs)
                    new_pc = pc + 1
                catch err
                    new_pc = handle_err(interp, frame, err)
                end
                nstmts = limited_interp.nstmts
            elseif stmt.head === :(=) && isexpr(stmt.args[2], :call) && !isa(interp, NonRecursiveInterpreter)
                limited_interp.nstmts = nstmts
                try
                    rhs = evaluate_call!(limited_interp, frame, stmt.args[2])
                    isa(rhs, Aborted) && return rhs, limited_interp.nstmts
                    do_assignment!(frame, stmt.args[1], rhs)
                    new_pc = pc + 1
                catch err
                    new_pc = handle_err(interp, frame, err)
                end
                nstmts = limited_interp.nstmts
            elseif istoplevel && stmt.head === :thunk
                code = stmt.args[1]
                if length(code.code) == 1 && JuliaInterpreter.is_return(code.code[end]) && isexpr(code.code[end].args[1], :method)
                    # Julia 1.2+ puts a :thunk before the start of each method
                    new_pc = pc + 1
                else
                    limited_interp.nstmts = nstmts
                    newframe = Frame(moduleof(frame), stmt)
                    ret = finish_and_return!(limited_interp, newframe, true)
                    isa(ret, Aborted) && return ret, limited_interp.nstmts
                    JuliaInterpreter.recycle(newframe)
                    # Because thunks may define new methods, return to toplevel
                    frame.pc = pc + 1
                    return nothing, limited_interp.nstmts
                end
            elseif istoplevel && stmt.head === :method && length(stmt.args) == 3
                step_expr!(interp, frame, stmt, istoplevel)
                frame.pc = pc + 1
                return nothing, nstmts - 1
            else
                new_pc = step_expr!(interp, frame, stmt, istoplevel)
                nstmts -= 1
            end
        else
            new_pc = step_expr!(interp, frame, stmt, istoplevel)
            nstmts -= 1
        end
        (new_pc === nothing || isa(new_pc, BreakpointRef)) && break
        pc = frame.pc = new_pc
    end
    # Handle the return
    stmt = pc_expr(frame, pc)
    if nstmts == 0 && !JuliaInterpreter.is_return(stmt)
        ret = Aborted(frame, pc)
        return ret, nstmts
    end
    ret = get_return(frame)
    return Some{Any}(ret), nstmts
end

evaluate_limited!(interp::Interpreter, modex::Tuple{Module,Expr,Frame}, nstmts::Int, istoplevel::Bool=true) =
    evaluate_limited!(interp, modex[end], nstmts, istoplevel)
evaluate_limited!(interp::Interpreter, modex::Tuple{Module,Expr,Expr}, nstmts::Int, istoplevel::Bool=true) =
    Some{Any}(Core.eval(modex[1], modex[3])), nstmts

evaluate_limited!(frame::Union{Frame, Tuple}, nstmts::Int, istoplevel::Bool=false) =
    evaluate_limited!(RecursiveInterpreter(), frame, nstmts, istoplevel)

function JuliaInterpreter.finish_and_return!(interp::LimitedExec, newframe::Frame, istoplevel::Bool)
    ret, nleft = evaluate_limited!(interp, newframe, interp.nstmts, istoplevel)
    interp.nstmts = nleft
    return isa(ret, Aborted) ? ret : something(ret)
end

### Functions needed on workers for running tests

function configure_test()
    # To run tests efficiently, certain methods must be run in the compiled mode,
    # in particular those that are used by the Test infrastructure
    cm = JuliaInterpreter.compiled_methods
    empty!(cm)
    JuliaInterpreter.set_compiled_methods()
    push!(cm, which(Test.eval_test, Tuple{Expr, Expr, LineNumberNode}))
    push!(cm, which(Test.get_testset, Tuple{}))
    push!(cm, which(Test.push_testset, Tuple{Test.AbstractTestSet}))
    push!(cm, which(Test.pop_testset, Tuple{}))
    for f in (Test.record, Test.finish)
        for m in methods(f)
            push!(cm, m)
        end
    end
    push!(cm, which(Random.seed!, Tuple{Union{Integer,Vector{UInt32}}}))
    push!(cm, which(copy!, Tuple{Random.MersenneTwister, Random.MersenneTwister}))
    push!(cm, which(copy, Tuple{Random.MersenneTwister}))
    push!(cm, which(Base.include, Tuple{Module, String}))
    push!(cm, which(Base.show_backtrace, Tuple{IO, Vector}))
    push!(cm, which(Base.show_backtrace, Tuple{IO, Vector{Any}}))
    # issue #101
    push!(cm, which(SHA.update!, Tuple{SHA.SHA1_CTX,Vector{UInt8}}))
end

function run_test_by_eval(test, fullpath, nstmts)
    Core.eval(Main, Expr(:toplevel, :(module JuliaTests using Test, Random end), quote
        # These must be run at top level, so we can't put this in a function
        println("Working on ", $test, "...")
        ex = read_and_parse($fullpath)
        isexpr(ex, :error) && @error "error parsing $($test): $ex"
        aborts = Aborted[]
        ts = Test.DefaultTestSet($test)
        Test.push_testset(ts)
        current_task().storage[:SOURCE_PATH] = $fullpath
        modexs = collect(ExprSplitter(JuliaTests, ex))
        for (i, modex) in enumerate(modexs)  # having the index can be useful for debugging
            nstmtsleft = $nstmts
            # mod, ex = modex
            # @show mod ex
            frame = Frame(modex)
            yield()  # allow communication between processes
            ret, nstmtsleft = evaluate_limited!(frame, nstmtsleft, true)
            if isa(ret, Aborted)
                push!(aborts, ret)
                JuliaInterpreter.finish_stack!(NonRecursiveInterpreter(), frame, true)
            end
        end
        println("Finished ", $test)
        return ts, aborts
    end))
end
