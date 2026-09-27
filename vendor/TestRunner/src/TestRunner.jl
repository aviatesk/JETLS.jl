module TestRunner

export TestRunnerTestSet, runtest, runtests

using Core.IR
using Compiler: Compiler as CC
using JuliaInterpreter: JuliaInterpreter as JI
using LoweredCodeUtils: LoweredCodeUtils as LCU
using JuliaSyntax: JuliaSyntax as JS
using MacroTools: MacroTools
using Test: Test

const BacktraceElm = Union{Ptr{Nothing},Base.InterpreterIP}
const ExceptionFrame = @NamedTuple{exception::Any,backtrace::Vector{BacktraceElm}}

struct TRInterpreter <: JI.Interpreter
    # constant across execution
    patterns::Dict{String,Vector{Any}}   # absolute path => patterns
    filter_lines::Dict{String,Set{Int}}  # absolute path => filter lines
    # Fallback base directory for resolving relative `include` paths when the
    # current file's `dirname` is empty (e.g. when `runtest` was given a
    # virtual `filename` like an unsaved buffer name). `nothing` keeps the
    # default behavior (resolution relative to cwd).
    root_path::Union{Nothing,String}
    # constant across per-file execution
    filename::String # absolute path
    context::Module
    current_exceptions::Vector{ExceptionFrame}
end
function TRInterpreter(interp::TRInterpreter;
                       patterns::Dict{String,Vector{Any}} = interp.patterns,
                       filter_lines::Dict{String,Set{Int}} = interp.filter_lines,
                       root_path::Union{Nothing,String} = interp.root_path,
                       filename::String = interp.filename,
                       context::Module = interp.context,
                       current_exceptions::Vector{ExceptionFrame} = interp.current_exceptions)
    return TRInterpreter(patterns, filter_lines, root_path, filename, context, current_exceptions)
end

const current_interpreter = Ref{TRInterpreter}()

const errors_and_fails = Dict{Union{Test.Error,Test.Fail},Vector{Any}}()

# Keeps the results of the outermost `TestRunnerTestSet` available even when finishing it
# throws `Test.TestSetException`
const last_toplevel_testset = Ref{Union{Nothing,Test.DefaultTestSet}}(nothing)

include("TestRunnerTestSet.jl")

"""
    runtest(filename::AbstractString, patterns, lines=();
            topmodule::Module=Main, source=nothing, root_path=nothing)

Run tests from a file that match the given patterns and/or are on the specified lines.

This function selectively executes test code based on pattern matching and line numbers.
Only the tests that match the criteria are run, along with necessary dependencies like
function definitions, imports, and struct definitions.

# Arguments
- `filename::AbstractString`: Path to the test file to run
- `patterns`: Collection of patterns to match against. Can include:
  - Strings: Match `@testset` names exactly (e.g., `"my test"`)
  - Regex: Match `@testset` names by pattern (e.g., `r"test.*"`)
  - Expressions: Match arbitrary Julia code using MacroTools patterns (e.g., `:(@test f_(x_) == y_)`)
  - Integers: Execute code on specific line numbers (e.g., `42`)
  - Ranges: Execute code on line ranges (e.g., `10:15`)
- `filter_lines=nothing`: Optional collection of line numbers to filter pattern matches.
  When provided, only pattern matches that overlap with these lines will be executed
- `topmodule::Module=Main`: Module context for execution (default: `Main`)
- `source::Union{Nothing,AbstractString}=nothing`: When provided, use this source text for
  the entry file instead of reading it from disk. `filename` is still used for
  `@__FILE__`, error messages, and resolving paths of `include`d files (which are
  read from disk as usual)
- `root_path::Union{Nothing,AbstractString}=nothing`: Fallback base directory used when
  resolving relative `include` paths from `filename` whose `dirname` is empty (typical
  when `filename` is a virtual identifier such as an unsaved buffer name). Once an
  include is resolved into a real path, nested includes resolve relative to that file
  as usual. Defaults to `nothing`, in which case relative includes resolve against the
  current working directory

# Returns
Test results from the selectively executed tests, compatible with Julia's Test.jl framework.

# Examples
```julia
# Run a specific testset by name
runtest("testfile.jl", ["my tests"])

# Run tests matching a regex pattern
runtest("testfile.jl", [r"integration.*"])

# Run tests that match an expression pattern
runtest("testfile.jl", [:(@test startswith(s_, "prefix"))])

# Run tests on specific lines
runtest("testfile.jl", [10, 20, 30])

# Run tests in a line range
runtest("testfile.jl", [10:15])

# Combine different pattern types
runtest("testfile.jl", ["unit tests", r"helper.*", 42])
```

# Notes
- All top-level code (except @test and @testset) is automatically executed
- Only top-level code is interpreted; function calls within tests are compiled for performance
- Matched code runs within its enclosing testsets without running their other tests
- If an empty patterns collection is provided, only non-test top-level code will be executed
  (no `@test` or `@testset` expressions will run). This includes all function definitions,
  imports, and other setup code, including any `include` statements
"""
function runtest(filename::AbstractString, patterns;
                 filter_lines=nothing,
                 topmodule::Module=Main,
                 source::Union{Nothing,AbstractString}=nothing,
                 root_path::Union{Nothing,AbstractString}=nothing)
    # When the caller supplies `source`, treat `filename` as a virtual identifier
    # and avoid `abspath` so callers like editor integrations can pass a
    # synthetic name (e.g. an untitled buffer name) and have it round-trip
    # through diagnostics unchanged.
    filepath = source === nothing ? abspath(filename) : String(filename)
    patterns = Dict{String,Vector{Any}}(filepath => Any[pat for pat in patterns])
    if isnothing(filter_lines)
        filter_lines = Dict{String,Set{Int}}()
    else
        filter_lines = Dict{String,Set{Int}}(filepath => Set{Int}(filter_lines))
    end
    rp = root_path === nothing ? nothing : String(root_path)
    interp = TRInterpreter(patterns, filter_lines, rp, filepath, topmodule, ExceptionFrame[])
    global current_interpreter
    current_interpreter[] = interp
    empty!(errors_and_fails)
    _selective_run(interp; source)
end

"""
    runtests(entryfilename::AbstractString, patterns;
             filter_lines=nothing,
             topmodule::Module=Main)

Run tests from multiple files with file-specific pattern matching configurations.

This function allows you to specify different patterns for different files, enabling
fine-grained control over which tests run in each file. This is particularly useful
for test suites that include multiple test files via `include` statements.

# Arguments
- `entryfilename::AbstractString`: Path to the entry point test file (e.g., "test/runtests.jl")
- `patterns`: A collection of `filename => patterns_collection` pairs that specify which
  patterns to match in each file. For example:
  ```julia
  patterns = [
      "test/runtests.jl" => ["integration tests"],
      "test/unit_tests.jl" => [r"fast.*", :(@test foo(x_) == y_)],
      "test/perf_tests.jl" => [50:100]  # run tests on lines 50-100
  ]
  ```
  Files not listed in this dictionary will have all their top-level code executed
  (excluding `@test` and `@testset` expressions)
- `filter_lines=nothing`: Optional collection of `filename => line_numbers` pairs that
  specify line-based filtering for each file. When provided for a file, only pattern matches
  that overlap with the specified lines will be executed in that file
- `topmodule::Module=Main`: Module context for execution (default: `Main`)

# Returns
Test results from the selectively executed tests across all files.

# Examples
```julia
# Run specific tests in different included files
runtests("test/runtests.jl", [
    "test/runtests.jl" => ["basic tests"],
    "test/integration.jl" => [r"api.*"],
    "test/utils.jl" => [:(@test validate(x_))]
])

# Run tests on specific lines in different files
runtests("test/runtests.jl", [
    "test/runtests.jl" => [],  # no tests in entry file
    "test/core.jl" => [10:50, 100:150],
    "test/edge_cases.jl" => [25, 30, 35]
])

# Combine with line filtering for precise control
runtests("test/runtests.jl",
    ["test/core.jl" => ["important tests"]],
    filter_lines=["test/core.jl" => [45, 46, 47]]
)
```

# Notes
- The entry file is always executed starting from `entryfilename`
- Files included via `include()` statements will be discovered and processed automatically
- For files not specified in `patterns`, all non-test top-level code is executed
  (no @test or @testset expressions will run)
- Pattern types for each file follow the same rules as `runtest`:
  strings, regexes, expressions, integers, and ranges
"""
function runtests(entryfilename::AbstractString, patterns_for_files;
                  filter_lines_for_files=nothing,
                  topmodule::Module=Main,
                  source::Union{Nothing,AbstractString}=nothing,
                  root_path::Union{Nothing,AbstractString}=nothing)
    patterns = Dict{String,Vector{Any}}()
    for (filepath, pats) in patterns_for_files
        patterns[abspath(filepath)] = Any[pat for pat in pats]
    end
    filter_lines = Dict{String,Set{Int}}()
    if !isnothing(filter_lines_for_files)
        for (filepath, lines) in filter_lines_for_files
            filter_lines[abspath(filepath)] = Set{Int}(lines)
        end
    end
    # See `runtest` — keep `entryfilename` verbatim when `source` is supplied.
    filepath = source === nothing ? abspath(entryfilename) : String(entryfilename)
    rp = root_path === nothing ? nothing : String(root_path)
    interp = TRInterpreter(patterns, filter_lines, rp, filepath, topmodule, ExceptionFrame[])
    global current_interpreter
    current_interpreter[] = interp
    empty!(errors_and_fails)
    _selective_run(interp; source)
end

function _selective_run(interp::TRInterpreter;
                        source::Union{Nothing,AbstractString}=nothing)
    filename = interp.filename
    if source === nothing
        isfile(filename) || throw(SystemError(lazy"opening file \"$filename\"", 2, nothing))
        toptext = read(filename, String)
    else
        toptext = source
    end
    stream = JS.ParseStream(toptext)
    JS.parse!(stream; rule=:all)
    isempty(stream.diagnostics) || throw(JS.ParseError(stream))
    sntop = JS.build_tree(JS.SyntaxNode, stream; filename)
    _selective_run(interp, sntop)
end

function _selective_run(interp::TRInterpreter, sntop::JS.SyntaxNode)
    vnodes = JS.SyntaxNode[]
    if JS.kind(sntop) == JS.K"toplevel"
        for i = JS.numchildren(sntop):-1:1
            push!(vnodes, sntop[i])
        end
    else
        push!(vnodes, sntop)
    end

    context = interp.context
    while !isempty(vnodes)
        node = pop!(vnodes)
        lnn = LineNumberNode(JS.source_line(node), interp.filename)

        if JS.kind(node) == JS.K"module"
            # Julia 1.14+ prepends a `VERSION` child that records the parser version
            n = JS.numchildren(node)
            @assert n == 2 || n == 3 "malformed `module` AST"
            ModuleName, newsntop = node[n-1], node[n]
            isbare = JS.has_flags(node, JS.BARE_MODULE_FLAG)
            newcontext = Core.eval(context, Expr(:module, !isbare, Expr(ModuleName), Expr(:block, lnn)))
            newinterp = TRInterpreter(interp; context=newcontext)
            children = JS.children(newsntop)
            children === nothing && continue
            for newsn in children
                _selective_run(newinterp, newsn)
            end
            continue
        end

        # Check if this is a top-level @testset or @test
        expr = Expr(node)
        is_test_expr = is_testset_or_test(expr)

        # TODO Handle expanded module expression once JL is integrated
        # For the meanwhile, we should also raise an error to indicate that
        # TestRunner fails to selectively execute such code.

        patterns = get(interp.patterns, interp.filename, nothing)

        if !isnothing(patterns) && is_test_expr
            # For @testset and @test, use pattern matching
            expr = attribute_testset_to_call_site(expr::Expr)
            lines = Set{Int}()
            matched_lines!(lines, node, patterns, get(interp.filter_lines, interp.filename, nothing))

            expr = Expr(:block, expr, lnn)
            lwr = Meta.lower(context, expr)

            if !Meta.isexpr(lwr, :thunk)
                Core.eval(context, lwr)
                continue
            end
            src = only(lwr.args)::CodeInfo

            concretized = falses(length(src.code))
            controller = select_statements!(interp, concretized, src, context, lines)

            frame = JI.Frame(interp.context, src)
            LCU.selective_eval_fromstart!(interp, frame, concretized, controller, #=istoplevel=#true)
        else
            # Unconditionally execute non-test top-level code,
            # or no patterns are specified for this file.
            # Note: We use `JI.finish!` here instead of `Core.eval`
            # to ensure proper handling of `include` statements through our
            # custom `evaluate_call!` implementation
            lwr = Meta.lower(context, expr)

            if !Meta.isexpr(lwr, :thunk)
                Core.eval(context, lwr)
                continue
            end
            src = only(lwr.args)::CodeInfo

            frame = JI.Frame(context, src)
            JI.finish!(interp, frame, #=istoplevel=#true)
        end
    end
end

# `Test.@testset` attributes its whole expansion to the first `LineNumberNode` of the body
# ("preserve outer location"), so the code of an enclosing testset (including its other
# tests) shares the line of the first statement of the body. Prepend the line of the
# `@testset` call itself so that the expansion is attributed to that line instead.
function attribute_testset_to_call_site(ex::Expr)
    return MacroTools.postwalk(ex) do @nospecialize x
        if Meta.isexpr(x, :macrocall) && MacroTools.@capture(x, @testset(args__))
            lnn = x.args[2]
            body = x.args[end]
            if lnn isa LineNumberNode && Meta.isexpr(body, :block)
                x = Expr(:macrocall, x.args[1:end-1]..., Expr(:block, lnn, body.args...))
            end
        end
        return x
    end
end

function traverse(f, node::JS.SyntaxNode)
    stack = JS.SyntaxNode[node]
    while !isempty(stack)
        current = pop!(stack)
        f(current)
        for i = JS.numchildren(current):-1:1
            push!(stack, current[i])
        end
    end
end

function matched_lines!(lines::Set{Int}, sn::JS.SyntaxNode, patterns::Vector{Any},
                        filter_lines::Union{Nothing,Set{Int}}=nothing)
    # First, handle line number patterns (Int and UnitRange{Int})
    for pattern in patterns
        if pattern isa Integer
            push!(lines, pattern)
        elseif pattern isa UnitRange{<:Integer}
            for line in pattern
                push!(lines, line)
            end
        end
    end

    # Then, handle other patterns
    traverse(sn) do node::JS.SyntaxNode
        expr = Expr(node)
        if matches_pattern(expr, patterns)
            sourcefile = JS.sourcefile(node)
            first_line = JS.source_line(sourcefile, JS.first_byte(node))
            last_line = JS.source_line(sourcefile, JS.last_byte(node))

            # If filter_lines is provided, only include matches that overlap with specified lines
            if filter_lines === nothing
                push!(lines, (first_line:last_line)...)
            else
                for line in first_line:last_line
                    if line in filter_lines
                        push!(lines, (first_line:last_line)...)
                        break
                    end
                end
            end
        end
    end
    return lines
end

function matches_pattern(@nospecialize(expr), patterns::Vector{Any})
    for pattern in patterns
        if pattern isa Integer || pattern isa UnitRange{<:Integer}
            # Skip line number patterns - they are handled separately
            continue
        elseif pattern isa AbstractString || pattern isa Regex
            # Match @testset names
            if matches_named_testset_call(pattern, expr)
                # @info "Matched" pattern expr
                return true
            end
        elseif MacroTools.@capture(expr, $pattern)
            # @info "Matched" pattern expr
            return true
        end
    end
    return false
end

function matches_named_testset_call(pat::Union{AbstractString,Regex}, @nospecialize ex)
    name = nothing
    if MacroTools.@capture(ex, @testset name_String xs__)
        # vanilla form: `@testset "name" body`
    elseif MacroTools.@capture(ex, @testset Type_Symbol name_String xs__)
        # custom test set type: `@testset Type "name" body`
    else
        return false
    end
    return pat isa Regex ? occursin(pat, name) : pat == name
end

function is_testset_or_test(@nospecialize expr)
    # Check if expression is a test-related macro call
    return MacroTools.@capture(expr, @inferred(xs__)) ||
           MacroTools.@capture(expr, @test(xs__)) ||
           MacroTools.@capture(expr, @test_broken(xs__)) ||
           MacroTools.@capture(expr, @test_deprecated(xs__)) ||
           MacroTools.@capture(expr, @test_logs(xs__)) ||
           MacroTools.@capture(expr, @test_warn(xs__)) ||
           MacroTools.@capture(expr, @test_skip(xs__)) ||
           MacroTools.@capture(expr, @test_throws(xs__)) ||
           MacroTools.@capture(expr, @testset(xs__))
end

function select_statements!(interp::TRInterpreter, concretized::BitVector, src::CodeInfo, mod::Module, lines::Set{Int})
    cl = LCU.CodeLinks(mod, src)
    edges = LCU.CodeEdges(src, cl)

    line_stacks = Vector{Vector{Int}}(undef, length(src.code))
    for idx in 1:length(src.code)
        lins = Base.IRShow.buildLineInfoNode(src.debuginfo, nothing, idx)
        line_stacks[idx] = Int[lin.line for lin in lins if String(lin.file) == interp.filename]
        # If the line containing this statement is requested by pattern match,
        # this statement needs to be executed.
        if any(in(lines), line_stacks[idx])
            concretized[idx] = true
        end
    end
    select_enclosing_macro_code!(concretized, line_stacks)

    controller = select_dependencies!(concretized, src, edges, cl)

    # Debug: uncomment to see which statements are selected
    # LCU.print_with_code(stdout, src, concretized)

    return controller
end

# The code expanded from an enclosing macro call, e.g. the setup and teardown of an enclosing
# `@testset`, is attributed to a proper prefix of the line stack of the code nested in it,
# while the other code in the macro call (e.g. the other tests of that `@testset`) is
# attributed to longer stacks. Select the former so that the selected code runs within its
# enclosing context, e.g. so that selected tests are recorded into their enclosing testsets.
function select_enclosing_macro_code!(concretized::BitVector, line_stacks::Vector{Vector{Int}})
    prefixes = Set{Vector{Int}}()
    for idx in 1:length(concretized)
        concretized[idx] || continue
        line_stack = line_stacks[idx]
        for n in 1:length(line_stack)-1
            push!(prefixes, line_stack[1:n])
        end
    end
    for idx in 1:length(concretized)
        if !concretized[idx] && line_stacks[idx] in prefixes
            concretized[idx] = true
        end
    end
    return concretized
end

function select_dependencies!(concretized::BitVector, src::CodeInfo, edges, cl)
    typedefs = LCU.find_typedefs(src)
    cfg = CC.compute_basic_blocks(src.code)
    postdomtree = CC.construct_postdomtree(cfg.blocks)
    ssavalue_uses = CC.find_ssavalue_uses(src.code, length(src.code))

    changed = true
    while changed
        changed = false
        changed |= LCU.add_ssa_preds!(concretized, src, edges, ())
        changed |= add_ssas_uses!(concretized, ssavalue_uses)
        changed |= add_slot_deps!(concretized, cl)
        changed |= LCU.add_typedefs!(concretized, src, edges, typedefs, ())
        changed |= LCU.add_control_flow!(concretized, src, cfg, postdomtree)
    end

    controller = LCU.SelectiveEvalController()
    LCU.add_active_gotos!(concretized, src, cfg, postdomtree, controller)
    LCU.record_termination_points!(controller, concretized, cfg)

    return controller
end

# Add statements that use SSA values produced by already selected statements
function add_ssas_uses!(concretized::BitVector, ssavalue_uses)
    changed = false
    for idx = 1:length(concretized)
        if concretized[idx]
            for use_idx in ssavalue_uses[idx]
                if !concretized[use_idx]
                    concretized[use_idx] = true
                    changed = true
                end
            end
        end
    end
    return changed
end

function add_slot_deps!(concretized::BitVector, cl::LCU.CodeLinks)
    changed = false

    # For each slot, check if any selected statement uses it
    for slot_id = 1:length(cl.slotsuccs)
        slot_succs = cl.slotsuccs[slot_id]
        slot_preds = cl.slotpreds[slot_id]
        slot_assigns = cl.slotassigns[slot_id]

        # Check if any successor (user) of this slot is selected
        is_selected = false
        for succ_idx in slot_succs.ssas
            if concretized[succ_idx]
                is_selected = true
                break
            end
        end

        is_selected || continue

        # If this slot is selected, we need to select:
        # 1. All predecessors (statements that the slot depends on)
        # 2. All assignments to the slot
        # 3. All prior uses of the slot (to ensure their dependencies are tracked)

        # Select predecessors
        for pred_idx in slot_preds.ssas
            if !concretized[pred_idx]
                concretized[pred_idx] = true
                changed = true
            end
        end

        for assign_idx in slot_assigns
            if !concretized[assign_idx]
                concretized[assign_idx] = true
                changed = true
            end
        end

        # Select all prior uses of the slot (to ensure their effects are included)
        for succ_idx in slot_succs.ssas
            if !concretized[succ_idx]
                # Only select uses that come before the latest selected use
                # This helps avoid selecting unrelated later uses
                latest_selected = 0
                for idx in slot_succs.ssas
                    if concretized[idx]
                        latest_selected = max(latest_selected, idx)
                    end
                end
                if succ_idx < latest_selected
                    concretized[succ_idx] = true
                    changed = true
                end
            end
        end
    end

    return changed
end

# This overload has exactly the same implementation as `JI.evaluate_call!(::JI.NonRecursiveInterpreter, ...)`,
# but since the default `JI.evaluate_call!(::Interpreter, ...)` is for the recursive interpretation,
# we need to provide this implementation for `TRInterpreter`.
function JI.evaluate_call!(interp::TRInterpreter, frame::JI.Frame, call_expr::Expr, enter_generated::Bool=false)
    # @assert !enter_generated
    pc = frame.pc
    ret = JI.bypass_builtins(interp, frame, call_expr, pc)
    isa(ret, Some{Any}) && return ret.value
    ret = JI.maybe_evaluate_builtin(interp, frame, call_expr, false)
    isa(ret, Some{Any}) && return ret.value
    fargs = JI.collect_args(interp, frame, call_expr)
    return JI.evaluate_call!(interp, frame, fargs, enter_generated)
end

# This overload performs almost the same work as
# `JI.evaluate_call!(::JI.NonRecursiveInterpreter, ...)`
# but includes a few important adjustments specific to TestRunner's virtual process:
# - Special handling for `include` calls: recursively apply the virtual process to included files.
# - `rethrow` is left to JuliaInterpreter: exceptions caught by interpreted handlers do
#   not live on the task's native exception stack, so it needs to re-raise the one being
#   handled by the interpreted frames.
function JI.evaluate_call!(interp::TRInterpreter, frame::JI.Frame, fargs::Vector{Any},
                           enter_generated::Bool)
    if fargs[1] === Base.rethrow
        return @invoke JI.evaluate_call!(interp::JI.Interpreter, frame::JI.Frame,
                                         fargs::Vector{Any}, enter_generated::Bool)
    end
    f = popfirst!(fargs)
    args = fargs # now it's really args
    isinclude(f) && return invokelatest_in_scope(frame, handle_include, interp, f, args)
    return invokelatest_in_scope(frame, f, args...)
end

# JuliaInterpreter tracks the dynamic scopes entered by interpreted code (e.g. the testset
# scope entered by `@testset`) in `frame.framedata.current_scopes` instead of installing them
# on the task, so calls into compiled code need to run within those scopes explicitly, as
# `JI.maybe_eval_with_scope` does for `JI.NonRecursiveInterpreter`.
function invokelatest_in_scope(frame::JI.Frame, @nospecialize(f), @nospecialize(args...))
    scopes = frame.framedata.current_scopes
    isempty(scopes) && return @invokelatest f(args...)
    pairs = eltype(Base.ScopedValues.ScopeStorage)[]
    for scope in scopes
        append!(pairs, scope.values)
    end
    return Base.ScopedValues.with(pairs...) do
        @invokelatest f(args...)
    end
end

isinclude(@nospecialize f) = f isa Base.IncludeInto || (isa(f, Function) && nameof(f) === :include)

function handle_include(interp::TRInterpreter, @nospecialize(include_func), args::Vector{Any})
    nargs = length(args)
    include_context = interp.context
    if nargs == 1
        fname = only(args)
    elseif nargs == 2
        x, fname = args
        if isa(x, Module)
            include_context = x
        elseif isa(x, Function)
            @warn "TestRunner is unable to execute `include(mapexpr::Function, filename::String)` call currently."
        else
            @invokelatest include_func(args...) # make it throw throw
            @assert false "unreachable"
        end
    else
        @invokelatest include_func(args...) # make it throw throw
        throw(ErrorException("unreachable"))
    end
    if !isa(fname, String)
        @invokelatest include_func(args...) # make it throw throw
        @assert false "unreachable"
    end
    # Use `interp.root_path` only as a fallback when the current file has no
    # meaningful directory (i.e. a virtual top-level filename). Once an
    # include resolves into a real path, nested includes use that file's
    # `dirname` as usual.
    filedir = dirname(interp.filename)
    base = isempty(filedir) ? something(interp.root_path, "") : filedir
    included_file = normpath(base, fname)
    newinterp = TRInterpreter(interp; filename=included_file, context=include_context)
    _selective_run(newinterp)
end

function JI.handle_err(interp::TRInterpreter, frame::JI.Frame, @nospecialize(err))
    if isempty(interp.current_exceptions) ||
       interp.current_exceptions[end].exception !== err
        excs = map(current_exceptions()) do exc
            ExceptionFrame((exc.exception, exc.backtrace))
        end
        append!(interp.current_exceptions, scrub_exc_stack(excs))
    end # otherwise `err` is being re-raised by `rethrow` and has already been recorded
    return @invoke JI.handle_err(interp::JI.Interpreter, frame::JI.Frame, err::Any)
end

const JULIAINTERPRETER_INTERPRET_FILE = let
    jlfile = pathof(JI)::String
    Symbol(normpath(jlfile, "..", "interpret.jl"))
end

function scrub_backtrace(bt::Vector{BacktraceElm})
    runtest_idx = @something let
            findfirst(ip::BacktraceElm ->
                Test.ip_has_file_and_func(ip, @__FILE__, (:runtest, :runtests)), bt)
        end return bt
    internal_idx = @something let
            findfirst(ip::BacktraceElm -> ip_has_file(ip, @__FILE__), bt)
        end let
            findfirst(ip::BacktraceElm ->
                Test.ip_has_file_and_func(ip, JULIAINTERPRETER_INTERPRET_FILE, (:step_expr!,:eval_rhs,)), bt)
        end return bt
    internal_idx < runtest_idx || return bt
    return append!(bt[1:internal_idx-1], bt[runtest_idx:end])
end

function ip_has_file(ip::BacktraceElm, file::String)
    return any(Base.StackTraces.lookup(ip)) do fr::Base.StackTraces.StackFrame
        string(fr.file) == file
    end
end

function scrub_exc_stack(excs::Vector{ExceptionFrame})
    return ExceptionFrame[ ExceptionFrame((exc, scrub_backtrace(bt))) for (exc, bt) in excs ]
end

include("app.jl")
using .App: app_runner_module, main

include("precompile.jl")

end # module TestRunner
