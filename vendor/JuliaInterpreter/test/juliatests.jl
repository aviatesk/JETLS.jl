using JuliaInterpreter
using Test, Random, InteractiveUtils, Distributed, Dates
using JuliaInterpreter: isdefinedglobal

# Much of this file is taken from Julia's test/runtests.jl file.

if !isdefinedglobal(Main, :read_and_parse)
    include("utils.jl")
end

const juliadir = dirname(dirname(Sys.BINDIR))
const testdir = joinpath(juliadir, "test")
if isdir(testdir)
    include(joinpath(testdir, "choosetests.jl"))
else
    @error "Julia's test/ directory not found, can't run Julia tests"
end

function test_path(test)
    t = split(test, '/')
    if t[1] in STDLIBS
        if length(t) == 2
            return joinpath(STDLIB_DIR, t[1], "test", t[2])
        else
            return joinpath(STDLIB_DIR, t[1], "test", "runtests")
        end
    else
        return joinpath(testdir, test)
    end
end

nstmts = 10^4  # very quick, aborts a lot
outputfile = "results.md"
i = 1
while i <= length(ARGS)
    global i
    a = ARGS[i]
    if a == "--nstmts"
        global nstmts = parse(Int, ARGS[i+1])
        deleteat!(ARGS, i:i+1)
    elseif a == "--output"
        global outputfile = ARGS[i+1]
        deleteat!(ARGS, i:i+1)
    else
        i += 1
    end
end

tests, _, exit_on_error, seed = choosetests(ARGS)

function spin_up_worker()
    p = addprocs(1)[1]
    remotecall_wait(include, p, "utils.jl")
    remotecall_wait(configure_test, p)
    return p
end

function spin_up_workers(n)
    procs = addprocs(n)
    @sync begin
        @async for p in procs
            remotecall_wait(include, p, "utils.jl")
            remotecall_wait(configure_test, p)
        end
    end
    return procs
end

# Really, we're just going to skip all the tests that run on node1
const node1_tests = String[]
function move_to_node1(t)
    if t in tests
        splice!(tests, findfirst(isequal(t), tests))
        push!(node1_tests, t)
    end
    nothing
end
move_to_node1("precompile")
move_to_node1("SharedArrays")
move_to_node1("stress")
move_to_node1("Distributed")

@testset "Julia tests" begin
    nworkers = min(Sys.CPU_THREADS, length(tests))
    println("Using $nworkers workers")
    results = Dict{String,Any}()
    tests0 = copy(tests)
    all_tasks = Union{Task,Nothing}[]
    try
        @sync begin
            for i = 1:nworkers
                @async begin
                    push!(all_tasks, current_task())
                    while length(tests) > 0
                        nleft = length(tests)
                        test = popfirst!(tests)
                        println(nleft, " remaining, starting ", test, " on task ", i)
                        local resp
                        fullpath = test_path(test) * ".jl"
                        try
                            resp = disable_sigint() do
                                p = spin_up_worker()
                                result = remotecall_fetch(run_test_by_eval, p, test, fullpath, nstmts)
                                rmprocs(p; waitfor=5)
                                result
                            end
                        catch e
                            if isa(e, InterruptException)
                                println("interrupting ", test)
                                break # rethrow(e)
                            end
                            resp = e
                            if isa(e, ProcessExitedException)
                                println("exited on ", test)
                            end
                        end
                        results[test] = resp
                        if resp isa Exception && exit_on_error
                            skipped = length(tests)
                            empty!(tests)
                        end
                    end
                    println("Task ", i, " complete")
                    all_tasks[i] = nothing
                end
            end
        end
    catch err
        isa(err, InterruptException) || rethrow(err)
        # If the test suite was merely interrupted, still print the
        # summary, which can be useful to diagnose what's going on
        foreach(all_tasks) do task
            try
                if isa(task, Task)
                    println("trying to interrupt ", task)
                    schedule(task, InterruptException(); error=true)
                end
            catch
            end
        end
        foreach(wait, all_tasks)
    end

    open(outputfile, "w") do io
        versioninfo(io)
        println(io, "Test run at: ", now())
        println(io)
        println(io, "Maximum number of statements per lowered expression: ", nstmts)
        println(io)
        println(io, "| Test file | Passes | Fails | Errors | Broken | Aborted blocks |")
        println(io, "| --------- | ------:| -----:| ------:| ------:| --------------:|")
        for test in tests0
            result = get(results, test, "")
            if isa(result, Tuple{Test.AbstractTestSet, Vector})
                ts, aborts = result
                passes, fails, errors, broken, c_passes, c_fails, c_errors, c_broken = Test.get_test_counts(ts)
                naborts = length(aborts)
                println(io, "| ", test, " | ", passes+c_passes, " | ", fails+c_fails, " | ", errors+c_errors, " | ", broken+c_broken, " | ", naborts, " |")
            elseif isa(result, ProcessExitedException)
                println(io, "| ", test, " | ☠️ | ☠️ | ☠️ | ☠️ | ☠️ |")
            else
                println(test, " => ", result)
                println(io, "| ", test, " | X | X | X | X | X |")
            end
        end
    end
end
