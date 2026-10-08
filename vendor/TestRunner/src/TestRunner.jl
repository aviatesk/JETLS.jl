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
    file_patterns::Union{Nothing,Vector{Any}} # `nothing` executes all code of the file
    context::Module
    current_exceptions::Vector{ExceptionFrame}
    # constant across per-top-level-expression execution
    selected_lines::Set{Int}
end
function TRInterpreter(interp::TRInterpreter;
                       patterns::Dict{String,Vector{Any}} = interp.patterns,
                       filter_lines::Dict{String,Set{Int}} = interp.filter_lines,
                       root_path::Union{Nothing,String} = interp.root_path,
                       filename::String = interp.filename,
                       file_patterns::Union{Nothing,Vector{Any}} = interp.file_patterns,
                       context::Module = interp.context,
                       current_exceptions::Vector{ExceptionFrame} = interp.current_exceptions,
                       selected_lines::Set{Int} = interp.selected_lines)
    return TRInterpreter(patterns, filter_lines, root_path, filename, file_patterns, context,
                         current_exceptions, selected_lines)
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
- All code except unmatched tests (`@test`, `@testset`, etc.) is automatically executed,
  both at the top level and around tests nested in other code, e.g. in `let` blocks or in
  the testsets enclosing matched code. Only the code using what unmatched tests compute,
  e.g. `n = (@testset "name" ...).n_passed`, is skipped along with them
- Only top-level code is interpreted; function calls within tests are compiled for performance
- Matched code runs within its enclosing testsets without running their other tests
- If an empty patterns collection is provided, only non-test top-level code will be executed
  (no `@test` or `@testset` expressions will run). This includes all function definitions,
  imports, and other setup code, including any `include` statements
- Files included by matched code, e.g. by `@testset "name" include("file.jl")`, are executed
  entirely, including the files they include in turn. Files included by the other code have
  only their non-test top-level code executed
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
    interp = TRInterpreter(patterns, filter_lines, rp, filepath, patterns[filepath], topmodule,
                           ExceptionFrame[], Set{Int}())
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
  Files not listed in this dictionary are executed entirely when they are the entry file or
  included by matched code (including the files they `include` in turn), and otherwise only
  their non-test top-level code is executed
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
    ["test/runtests.jl" => [],
     "test/core.jl" => ["important tests"]],
    filter_lines=["test/core.jl" => [45, 46, 47]]
)
```

# Notes
- The entry file is always executed starting from `entryfilename`
- Files included via `include()` statements will be discovered and processed automatically
- Files not specified in `patterns` are executed entirely when included by matched code,
  and otherwise only their non-test top-level code is executed
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
    interp = TRInterpreter(patterns, filter_lines, rp, filepath, get(patterns, filepath, nothing),
                           topmodule, ExceptionFrame[], Set{Int}())
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
    patterns = interp.file_patterns
    filter_lines = get(interp.filter_lines, interp.filename, nothing)
    ret = nothing
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
            if children !== nothing
                for newsn in children
                    _selective_run(newinterp, newsn)
                end
            end
            ret = newcontext
            continue
        end

        # Check if this is a top-level @testset or @test
        expr = Expr(node)
        is_test_expr = is_testset_or_test(expr)

        # TODO Handle expanded module expression once JL is integrated
        # For the meanwhile, we should also raise an error to indicate that
        # TestRunner fails to selectively execute such code.

        lines = Set{Int}()
        isnothing(patterns) || matched_lines!(lines, node, patterns, filter_lines)
        nodeinterp = TRInterpreter(interp; selected_lines=lines)
        test_lines = isnothing(patterns) ? Set{Int}() : unmatched_test_lines(node, lines)

        if !isnothing(patterns) && is_test_expr
            # For @testset and @test, use pattern matching
            expr = attribute_testset_to_call_site(expr::Expr)

            expr = Expr(:block, expr, lnn)
            lwr = Meta.lower(context, expr)

            if !Meta.isexpr(lwr, :thunk)
                ret = Core.eval(context, lwr)
                continue
            end
            src = only(lwr.args)::CodeInfo

            concretized = falses(length(src.code))
            controller = select_statements!(nodeinterp, concretized, src, context, lines,
                                            test_lines)

            frame = JI.Frame(context, src)
            ret = LCU.selective_eval_fromstart!(nodeinterp, frame, concretized, controller, #=istoplevel=#true)
        else
            # Unconditionally execute non-test top-level code, except the unmatched tests
            # nested in it, or no patterns are specified for this file.
            # Note: We use `JI.finish_and_return!` here instead of `Core.eval`
            # to ensure proper handling of `include` statements through our
            # custom `evaluate_call!` implementation
            isempty(test_lines) || (expr = attribute_testset_to_call_site(expr::Expr))
            # `global x` alone can't be lowered within a block on Julia 1.12, and has no code
            # for `is_matched` to check anyway
            isdecl = Meta.isexpr(expr, :global) &&
                     !any(arg -> Meta.isexpr(arg, :(=)), expr.args)
            if !(Meta.isexpr(expr, :toplevel) || isdecl)
                # Attribute the code to its line, like `JI.ExprSplitter` does, for `is_matched`
                expr = Expr(:block, lnn, expr)
            end
            lwr = Meta.lower(context, expr)

            if !Meta.isexpr(lwr, :thunk)
                ret = Core.eval(context, lwr)
                continue
            end
            src = only(lwr.args)::CodeInfo

            frame = JI.Frame(context, src)
            if isempty(test_lines)
                ret = JI.finish_and_return!(nodeinterp, frame, #=istoplevel=#true)
            else
                concretized = falses(length(src.code))
                controller = select_statements!(nodeinterp, concretized, src, context,
                                                lines, test_lines)
                ret = LCU.selective_eval_fromstart!(nodeinterp, frame, concretized,
                                                    controller, #=istoplevel=#true)
            end
        end
    end
    return ret
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

# The lines of the test macro calls in `node` that don't overlap `matched_lines`. The tests
# that do overlap them are matched or enclose matched code, so the code in them is searched
# for unmatched tests like any other code, except definitions and quoted code, which don't
# run along with `node`.
function unmatched_test_lines(node::JS.SyntaxNode, matched_lines::Set{Int})
    lines = Set{Int}()
    stack = JS.SyntaxNode[node]
    while !isempty(stack)
        current = pop!(stack)
        kind = JS.kind(current)
        if kind == JS.K"function" || kind == JS.K"macro" || kind == JS.K"->" ||
           kind == JS.K"quote"
            continue
        elseif kind == JS.K"macrocall" && is_testset_or_test(Expr(current))
            sourcefile = JS.sourcefile(current)
            first_line = JS.source_line(sourcefile, JS.first_byte(current))
            last_line = JS.source_line(sourcefile, JS.last_byte(current))
            if !any(in(matched_lines), first_line:last_line)
                union!(lines, first_line:last_line)
                continue
            end
        end
        for i = JS.numchildren(current):-1:1
            push!(stack, current[i])
        end
    end
    return lines
end

# Compared without MacroTools, which would take the underscores in e.g. `@test_broken` for
# pattern variables
const TEST_MACRO_NAMES = (Symbol("@inferred"), Symbol("@test"), Symbol("@test_broken"),
                          Symbol("@test_deprecated"), Symbol("@test_logs"),
                          Symbol("@test_warn"), Symbol("@test_nowarn"), Symbol("@test_skip"),
                          Symbol("@test_throws"), Symbol("@testset"))

function is_testset_or_test(@nospecialize expr)
    # Check if expression is a test-related macro call
    return Meta.isexpr(expr, :macrocall) && expr.args[1] in TEST_MACRO_NAMES
end

function select_statements!(interp::TRInterpreter, concretized::BitVector, src::CodeInfo,
                            mod::Module, lines::Set{Int}, test_lines::Set{Int})
    cl = LCU.CodeLinks(mod, src)
    edges = LCU.CodeEdges(src, cl)

    line_stacks = Vector{Vector{Int}}(undef, length(src.code))
    for idx in 1:length(src.code)
        line_stacks[idx] = stmt_line_stack(interp, src, idx)
        # If the line containing this statement is requested by pattern match,
        # this statement needs to be executed.
        if any(in(lines), line_stacks[idx])
            concretized[idx] = true
        end
    end
    excluded = select_nontest_code!(concretized, edges, line_stacks, test_lines)

    controller = select_dependencies!(concretized, src, edges, cl, excluded)

    # Debug: uncomment to see which statements are selected
    # LCU.print_with_code(stdout, src, concretized)

    return controller
end

# Select the code around the unmatched tests attributed to `test_lines`, e.g. the rest of a
# `let` block or an enclosing `@testset` wrapping them, except those tests and the code
# using what they compute. Return them as `excluded`, so that the dependency selection adds
# them only when needed. Statements without lines, e.g. some `goto`s, are left to the
# dependency selection.
function select_nontest_code!(concretized::BitVector, edges::LCU.CodeEdges,
                              line_stacks::Vector{Vector{Int}}, test_lines::Set{Int})
    excluded = falses(length(concretized))
    worklist = Int[]
    for idx in 1:length(concretized)
        if !concretized[idx] && any(in(test_lines), line_stacks[idx])
            excluded[idx] = true
            push!(worklist, idx)
        end
    end
    while !isempty(worklist)
        for succ in edges.succs[pop!(worklist)]
            if !concretized[succ] && !excluded[succ]
                excluded[succ] = true
                push!(worklist, succ)
            end
        end
    end
    for idx in 1:length(concretized)
        if !excluded[idx] && !isempty(line_stacks[idx])
            concretized[idx] = true
        end
    end
    return excluded
end

function stmt_line_stack(interp::TRInterpreter, src::CodeInfo, idx::Int)
    lins = Base.IRShow.buildLineInfoNode(src.debuginfo, nothing, idx)
    return Int[lin.line for lin in lins if String(lin.file) == interp.filename]
end

function select_dependencies!(concretized::BitVector, src::CodeInfo, edges, cl,
                              excluded::BitVector)
    typedefs = LCU.find_typedefs(src)
    cfg = CC.compute_basic_blocks(src.code)
    postdomtree = CC.construct_postdomtree(cfg.blocks)
    ssavalue_uses = CC.find_ssavalue_uses(src.code, length(src.code))

    changed = true
    while changed
        changed = false
        changed |= LCU.add_ssa_preds!(concretized, src, edges, ())
        changed |= add_ssas_uses!(concretized, ssavalue_uses, excluded)
        changed |= add_slot_deps!(concretized, cl, excluded)
        changed |= LCU.add_typedefs!(concretized, src, edges, typedefs, ())
        changed |= LCU.add_control_flow!(concretized, src, cfg, postdomtree)
    end

    controller = LCU.SelectiveEvalController()
    LCU.add_active_gotos!(concretized, src, cfg, postdomtree, controller)
    LCU.record_termination_points!(controller, concretized, cfg)

    return controller
end

# Add statements that use SSA values produced by already selected statements
function add_ssas_uses!(concretized::BitVector, ssavalue_uses, excluded::BitVector)
    changed = false
    for idx = 1:length(concretized)
        if concretized[idx]
            for use_idx in ssavalue_uses[idx]
                if !concretized[use_idx] && !excluded[use_idx]
                    concretized[use_idx] = true
                    changed = true
                end
            end
        end
    end
    return changed
end

function add_slot_deps!(concretized::BitVector, cl::LCU.CodeLinks, excluded::BitVector)
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
            if !concretized[succ_idx] && !excluded[succ_idx]
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
    isinclude(f) && return invokelatest_in_scope(frame, handle_include, interp, frame, f, args)
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

function handle_include(interp::TRInterpreter, frame::JI.Frame, @nospecialize(include_func),
                        args::Vector{Any})
    nargs = length(args)
    if nargs == 1 && args[1] isa String
        include_context = interp.context
    elseif nargs == 2 && args[1] isa Module && args[2] isa String
        include_context = args[1]::Module
    elseif nargs ≥ 2 && args[1] isa Function && args[end] isa String
        # `mapexpr` takes whole top-level expressions, including `module`s that
        # `_selective_run` splits up, so `include(mapexpr, [m,] path)` runs natively, with
        # an absolute path that native `include` doesn't resolve against `:SOURCE_PATH`
        path = abspath(include_path(interp, args[end]::String))
        return @invokelatest include_func(args[1:end-1]..., path)
    else
        return @invokelatest include_func(args...)
    end
    included_file = include_path(interp, args[end]::String)
    # Files without their own patterns run their tests only when included by matched code
    file_patterns = get(interp.patterns, included_file) do
        is_matched(interp, frame) ? nothing : Any[]
    end
    newinterp = TRInterpreter(interp; filename=included_file, file_patterns,
                              context=include_context)
    return _selective_run(newinterp)
end

function is_matched(interp::TRInterpreter, frame::JI.Frame)
    interp.file_patterns === nothing && return true
    line_stack = stmt_line_stack(interp, frame.framecode.src, frame.pc)
    return any(in(interp.selected_lines), line_stack)
end

# Use `interp.root_path` only as a fallback when the current file has no
# meaningful directory (i.e. a virtual top-level filename). Once an
# include resolves into a real path, nested includes use that file's
# `dirname` as usual.
function include_path(interp::TRInterpreter, fname::String)
    filedir = dirname(interp.filename)
    base = isempty(filedir) ? something(interp.root_path, "") : filedir
    return normpath(base, fname)
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
