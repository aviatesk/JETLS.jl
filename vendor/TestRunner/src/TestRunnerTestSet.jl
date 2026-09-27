using Test: Test

struct TestRunnerTestSet <: Test.AbstractTestSet
    dts::Test.DefaultTestSet
    function TestRunnerTestSet(args...; options...)
        return new(Test.DefaultTestSet(args...; options...))
    end
end

struct WrappedString
    value::String
end
Base.show(io::IO, ws::WrappedString) = print(io, ws.value)

function Test.record(trts::TestRunnerTestSet, @nospecialize res)
    global current_interpreter
    interp = current_interpreter[]
    if res isa Test.Threw
        (; exception, #=backtrace,=# source) = res
        excs = copy(interp.current_exceptions)
        res = Test.Threw(exception, excs, source)
        errors_and_fails[res] = excs
        empty!(interp.current_exceptions)
    elseif res isa Test.Error
        excs = copy(interp.current_exceptions)
        if !isempty(excs)
            (; test_type, orig_expr, value, #=backtrace,=# source) = res
            res = Test.Error(test_type, orig_expr, WrappedString(value), Base.ExceptionStack(excs), source)
        end
        errors_and_fails[res] = excs
        empty!(interp.current_exceptions)
    end
    Test.record(trts.dts, res)
end
function Test.finish(trts::TestRunnerTestSet)
    if Test.get_testset_depth() != 0
        # Attach this test set to the parent test set (unless this is TestRunnerMetaTestSet)
        parent_ts = Test.get_testset()
        if !(parent_ts isa TestRunnerMetaTestSet)
            Test.finish(trts.dts) # records the end time as well as attaches it to `parent_ts`
        end
    else
        last_toplevel_testset[] = trts.dts
        Test.finish(trts.dts)
    end
    return trts.dts
end

# Used by tests only
struct TestRunnerMetaTestSet <: Test.AbstractTestSet
    dts::Test.DefaultTestSet
    function TestRunnerMetaTestSet(args...; options...)
        return new(Test.DefaultTestSet(args...; options...))
    end
end

Test.record(trts::TestRunnerMetaTestSet, @nospecialize res) = Test.record(trts.dts, res)
Test.finish(trts::TestRunnerMetaTestSet) = Test.finish(trts.dts)
