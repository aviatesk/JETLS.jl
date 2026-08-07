module test_code_action

using Test
using JETLS
using JETLS: JL, JS
using JETLS.LSP
using JETLS.LSP.URIs2
using JETLS.TOML

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

module lowering_module end

function get_lowering_diagnostics(
        text::AbstractString;
        code::Union{AbstractString,Nothing} = nothing,
        context_module::Module = lowering_module,
        world::UInt = Base.get_world_counter(),
        kwargs...
    )
    filename = abspath(pkgdir(JETLS), "test", "test_code_action.jl")
    server = JETLS.Server()
    uri = filepath2uri(filename)
    fi = JETLS.cache_file_info!(server, uri, 1, text)
    st0_top = JETLS.build_syntax_tree(fi)
    diagnostics = LSP.Diagnostic[]
    candidates = JETLS.UndefGlobalCandidate[]
    def_used_names = Dict{Module,JETLS.DefUsedNames}()
    JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        JETLS.per_stmt_diagnostics!(diagnostics, candidates, uri, fi,
            st0, context_module, world, #=analyzer=#nothing, JETLS.LSPostProcessor();
            kwargs...)
        binding_occurrences = JETLS.get_binding_occurrences!(server.state, uri, fi, st0)
        binding_occurrences !== nothing &&
            JETLS.update_def_used_names!(def_used_names, context_module, binding_occurrences)
    end
    explicit_imports = JETLS.collect_explicit_imports_by_module(server.state, uri, fi, st0_top)
    # Mirror the cross-file phase. `skip_context_check=true` because the test server
    # has no populated `analysis_manager` — we want this single file to count as
    # part of its own unit anyway.
    per_file = JETLS.PerFileDiagnosticsResult(
        diagnostics, candidates, def_used_names, explicit_imports)
    JETLS.cross_file_diagnostics!(diagnostics, JETLS.DefUsedNamesCache(),
        server, uri, per_file; skip_context_check=true)
    if code !== nothing
        filter!(d -> d.code == code, diagnostics)
    end
    return diagnostics, uri
end

function get_unused_var_code_actions(marked_text::AbstractString; kwargs...)
    text, positions = JETLS.get_text_and_positions(marked_text)
    diagnostics, uri = get_lowering_diagnostics(text; kwargs...)
    code_actions = Union{CodeAction,Command}[]
    JETLS.unused_variable_code_actions!(code_actions, uri, diagnostics; kwargs...)
    return code_actions, uri, positions
end

@testset "unused variable code actions" begin
    # Unused positional argument: rename action
    let (code_actions, uri, _) = get_unused_var_code_actions("""
        function f(x, y)
            return x
        end
        """)
        @test length(code_actions) == 1
        action = only(code_actions)
        @test action.title == "Prefix with '_' to indicate intentionally unused"
        @test action.isPreferred == true
        edit = only(action.edit.changes[uri])
        @test edit.newText == "_"
    end

    # allow_unused_underscore=false: replace instead of prefix
    let (code_actions, uri, _) = get_unused_var_code_actions("""
        function f(x, y)
            return x
        end
        """; allow_unused_underscore=false)
        @test length(code_actions) == 1
        action = only(code_actions)
        @test action.title == "Replace with '_' to indicate intentionally unused"
        edit = only(action.edit.changes[uri])
        @test edit.newText == "_"
    end

    # Unused local with assignment: rename + delete assignment + delete statement
    let (code_actions, uri, positions) = get_unused_var_code_actions("""
        function f()
            │y = │rand()│
            return nothing
        end
        """)
        @test length(code_actions) == 3
        rename_actions = filter(a -> contains(a.title, "Prefix"), code_actions)
        @test length(rename_actions) == 1
        @test only(rename_actions).isPreferred == true
        delete_actions = filter(a -> contains(a.title, "Delete"), code_actions)
        @test length(delete_actions) == 2
        @test delete_actions[1].title == "Delete assignment"
        @test delete_actions[1].edit.changes[uri][1].newText == ""
        @test delete_actions[1].edit.changes[uri][1].range.start == positions[1]
        @test delete_actions[1].edit.changes[uri][1].range.var"end" == positions[2]
        @test delete_actions[2].title == "Delete statement"
        @test delete_actions[2].edit.changes[uri][1].newText == ""
        @test delete_actions[2].edit.changes[uri][1].range.start == positions[1]
        @test delete_actions[2].edit.changes[uri][1].range.var"end" == positions[3]
    end

    let (code_actions, uri, positions) = get_unused_var_code_actions("""
        function f()
            │y = │1│
        end
        """)
        @test length(code_actions) == 3
        @test code_actions[1].title == "Insert explicit return"
        @test code_actions[1].isPreferred == true
        edit = only(code_actions[1].edit.changes[uri])
        @test edit.range.start == positions[3]
        @test edit.range.var"end" == positions[3]
        @test edit.newText == "\n    return y"
        @test code_actions[2].title == "Prefix with '_' to indicate intentionally unused"
        @test code_actions[2].isPreferred == true
        @test code_actions[3].title == "Delete assignment"
        @test code_actions[3].edit.changes[uri][1].range.start == positions[1]
        @test code_actions[3].edit.changes[uri][1].range.var"end" == positions[2]
        @test !any(a -> a.title == "Delete statement", code_actions)
    end

    # Tuple unpacking: only rename, no delete
    let (code_actions, _, _) = get_unused_var_code_actions("""
        function f()
            (x, y) = (1, 2)
            return x
        end
        """)
        unused_y = filter(a -> contains(a.title, "Prefix"), code_actions)
        @test length(unused_y) == 1
        delete_actions = filter(a -> contains(a.title, "Delete"), code_actions)
        @test isempty(delete_actions)
    end

    # Unused keyword argument: no rename action
    let (code_actions, _, _) = get_unused_var_code_actions("""
        function f(; kwarg=1)
            return nothing
        end
        """)
        @test isempty(code_actions)
    end

    # Unused positional argument with a default value: rename action should appear
    let (code_actions, uri, _) = get_unused_var_code_actions("""
        function f(x, bar="bar")
            return x
        end
        """)
        @test length(code_actions) == 1
        action = only(code_actions)
        @test action.title == "Prefix with '_' to indicate intentionally unused"
        edit = only(action.edit.changes[uri])
        @test edit.newText == "_"
    end
end

@testset "unused assignment code actions" begin
    # unused-assignment gets delete actions but NOT rename action
    let (code_actions, uri, positions) = get_unused_var_code_actions("""
        function f()
            │x = │1│
            x = 2
            return x
        end
        """)
        # The first `x = 1` is a dead store
        delete_actions = filter(a -> contains(a.title, "Delete"), code_actions)
        @test length(delete_actions) == 2
        @test delete_actions[1].title == "Delete assignment"
        @test delete_actions[1].edit.changes[uri][1].newText == ""
        @test delete_actions[1].edit.changes[uri][1].range.start == positions[1]
        @test delete_actions[1].edit.changes[uri][1].range.var"end" == positions[2]
        @test delete_actions[2].title == "Delete statement"
        @test delete_actions[2].edit.changes[uri][1].newText == ""
        @test delete_actions[2].edit.changes[uri][1].range.start == positions[1]
        @test delete_actions[2].edit.changes[uri][1].range.var"end" == positions[3]
        # No rename action for unused assignments
        rename_actions = filter(code_actions) do action
            contains(action.title, "Prefix") || contains(action.title, "Replace")
        end
        @test isempty(rename_actions)
    end

    let (code_actions, uri, positions) = get_unused_var_code_actions("""
        function f()
            x = 1
            println(x)
            │x = │2│
        end
        """)
        @test length(code_actions) == 2
        @test code_actions[1].title == "Insert explicit return"
        @test code_actions[1].isPreferred == true
        edit = only(code_actions[1].edit.changes[uri])
        @test edit.range.start == positions[3]
        @test edit.range.var"end" == positions[3]
        @test edit.newText == "\n    return x"
        @test code_actions[2].title == "Delete assignment"
        @test code_actions[2].edit.changes[uri][1].range.start == positions[1]
        @test code_actions[2].edit.changes[uri][1].range.var"end" == positions[2]
        @test !any(a -> a.title == "Delete statement", code_actions)
        rename_actions = filter(code_actions) do action
            contains(action.title, "Prefix") || contains(action.title, "Replace")
        end
        @test isempty(rename_actions)
    end
end

function get_sort_imports_code_actions(text::AbstractString)
    diagnostics, uri = get_lowering_diagnostics(text;
        code = JETLS.LOWERING_UNSORTED_IMPORT_NAMES_CODE)
    code_actions = Union{CodeAction,Command}[]
    JETLS.sort_imports_code_actions!(code_actions, uri, diagnostics)
    return code_actions, uri
end

@testset "sort imports code action" begin
    let (code_actions, uri) = get_sort_imports_code_actions("import Foo: c, a, b")
        @test length(code_actions) == 1
        action = only(code_actions)
        @test action.title == "Sort import names"
        edit = action.edit.changes[uri][1]
        @test edit.newText == "import Foo: a, b, c"
    end

    let (code_actions, uri) = get_sort_imports_code_actions("export z, y, x, w")
        @test length(code_actions) == 1
        edit = code_actions[1].edit.changes[uri][1]
        @test edit.newText == "export w, x, y, z"
    end

    let (code_actions, _) = get_sort_imports_code_actions("import Foo: a, b, c")
        @test isempty(code_actions)
    end

    let (code_actions, uri) = get_sort_imports_code_actions("using Foo: bar as baz, alpha as a")
        @test length(code_actions) == 1
        edit = code_actions[1].edit.changes[uri][1]
        @test edit.newText == "using Foo: alpha as a, bar as baz"
    end

    let (code_actions, uri) = get_sort_imports_code_actions("import Core, ..Base, Base")
        @test length(code_actions) == 1
        edit = code_actions[1].edit.changes[uri][1]
        @test edit.newText == "import ..Base, Base, Core"
    end

    let (code_actions, uri) = get_sort_imports_code_actions(
            "import LongModuleName: zzz, yyy, xxx, www, vvv, uuu, ttt, sss, rrr, qqq, ppp, ooo, nnn, mmm, lll, kkk, jjj, iii, hhh, ggg, fff, eee, ddd, ccc, bbb, aaa")
        @test length(code_actions) == 1
        edit = code_actions[1].edit.changes[uri][1]
        expected = "import LongModuleName: aaa, bbb, ccc, ddd, eee, fff, ggg, hhh, iii, jjj, kkk, lll, mmm, nnn,\n    ooo, ppp, qqq, rrr, sss, ttt, uuu, vvv, www, xxx, yyy, zzz"
        @test edit.newText == expected
    end

    let (code_actions, uri) = get_sort_imports_code_actions(
            "module A\n    export zzz, yyy, xxx, www, vvv, uuu, ttt, sss, rrr, qqq, ppp, ooo, nnn, mmm, lll, kkk\nend")
        @test length(code_actions) == 1
        edit = code_actions[1].edit.changes[uri][1]
        expected = "export kkk, lll, mmm, nnn, ooo, ppp, qqq, rrr, sss, ttt, uuu, vvv, www, xxx, yyy, zzz"
        @test edit.newText == expected
    end

    let (code_actions, uri) = get_sort_imports_code_actions(
            "module A\n    export zzz, yyy, xxx, www, vvv, uuu, ttt, sss, rrr, qqq, ppp, ooo, nnn, mmm, lll, kkk, jjj, iii, hhh, ggg\nend")
        @test length(code_actions) == 1
        edit = code_actions[1].edit.changes[uri][1]
        expected = "export ggg, hhh, iii, jjj, kkk, lll, mmm, nnn, ooo, ppp, qqq, rrr, sss, ttt, uuu, vvv,\n        www, xxx, yyy, zzz"
        @test edit.newText == expected
    end

    let (code_actions, _) = get_sort_imports_code_actions("import Foo: c, a, b")
        @test length(code_actions) == 1
        action = only(code_actions)
        @test length(action.diagnostics) == 1
        @test action.diagnostics[1].code == JETLS.LOWERING_UNSORTED_IMPORT_NAMES_CODE
    end
end

function get_unused_import_code_actions(marked_text::AbstractString)
    text, positions = JETLS.get_text_and_positions(marked_text)
    diagnostics, uri = get_lowering_diagnostics(text;
        code = JETLS.LOWERING_UNUSED_IMPORT_CODE,
        skip_analysis_requiring_context = true)
    code_actions = Union{CodeAction,Command}[]
    JETLS.delete_range_code_actions!(code_actions, uri, diagnostics)
    return code_actions, uri, positions
end

@testset "unused import code actions" begin
    # Single import: delete entire statement
    let (code_actions, uri, positions) = get_unused_import_code_actions(
            "│using Base: cos│")
        @test length(code_actions) == 1
        action = only(code_actions)
        @test action.title == "Remove unused import"
        @test action.isPreferred == true
        edit = only(action.edit.changes[uri])
        @test edit.newText == ""
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[2]
    end

    # Multiple imports, remove last: delete ", cos"
    let (code_actions, uri, positions) = get_unused_import_code_actions(
            "using Base: sin│, cos│\nsin(1.0)")
        @test length(code_actions) == 1
        edit = only(code_actions[1].edit.changes[uri])
        @test edit.newText == ""
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[2]
    end

    # Multiple imports, remove first: delete "sin, "
    let (code_actions, uri, positions) = get_unused_import_code_actions(
            "using Base: │sin, │cos\ncos(1.0)")
        @test length(code_actions) == 1
        edit = only(code_actions[1].edit.changes[uri])
        @test edit.newText == ""
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[2]
    end

    # Three imports, remove middle: delete "cos, "
    let (code_actions, uri, positions) = get_unused_import_code_actions(
            "using Base: sin, │cos, │tan\nsin(1.0)\ntan(1.0)")
        @test length(code_actions) == 1
        edit = only(code_actions[1].edit.changes[uri])
        @test edit.newText == ""
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[2]
    end

    # Single import on its own line: delete also absorbs the trailing newline
    let (code_actions, uri, positions) = get_unused_import_code_actions(
            "│using Base: cos\n│sin(1.0)")
        @test length(code_actions) == 1
        edit = only(code_actions[1].edit.changes[uri])
        @test edit.newText == ""
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[2]
    end

    # Single import indented: also absorbs the leading indentation
    let (code_actions, uri, positions) = get_unused_import_code_actions(
            "module M\n│    using Base: cos\n│end")
        @test length(code_actions) == 1
        edit = only(code_actions[1].edit.changes[uri])
        @test edit.newText == ""
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[2]
    end
end

function get_unreachable_code_actions(marked_text::AbstractString)
    text, positions = JETLS.get_text_and_positions(marked_text)
    diagnostics, uri = get_lowering_diagnostics(text;
        code = JETLS.LOWERING_UNREACHABLE_CODE)
    code_actions = Union{CodeAction,Command}[]
    JETLS.delete_range_code_actions!(code_actions, uri, diagnostics)
    return code_actions, uri, positions
end

@testset "unreachable code actions" begin
    # Delete range covers from end of `return 1` to end of `x = 2`
    let (code_actions, uri, positions) = get_unreachable_code_actions("""
        function foo()
            return 1│
            x = 2│
        end
        """)
        @test length(code_actions) == 1
        action = only(code_actions)
        @test action.title == "Delete unreachable code"
        @test action.isPreferred == true
        edit = only(action.edit.changes[uri])
        @test edit.newText == ""
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[2]
    end

    # Multiple unreachable statements: single delete covering all of them
    let (code_actions, uri, positions) = get_unreachable_code_actions("""
        function foo()
            return 1│
            x = 2
            y = 3│
        end
        """)
        @test length(code_actions) == 1
        edit = only(code_actions[1].edit.changes[uri])
        @test edit.newText == ""
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[2]
    end

    # No code action when there's no unreachable code
    let (code_actions, _, _) = get_unreachable_code_actions("""
        function foo()
            x = 2
            return x
        end
        """)
        @test isempty(code_actions)
    end
end

function get_unused_label_code_actions(marked_text::AbstractString)
    text, positions = JETLS.get_text_and_positions(marked_text)
    diagnostics, uri = get_lowering_diagnostics(text;
        code = JETLS.LOWERING_UNUSED_LABEL_CODE)
    code_actions = Union{CodeAction,Command}[]
    JETLS.delete_range_code_actions!(code_actions, uri, diagnostics)
    return code_actions, uri, positions
end

@testset "unused label code actions" begin
    # Label on its own line: delete the whole line including indent and trailing newline
    let (code_actions, uri, positions) = get_unused_label_code_actions("""
        function f()
        │    @label unused
        │    return 1
        end
        """)
        @test length(code_actions) == 1
        action = only(code_actions)
        @test action.title == "Remove unused label"
        @test action.isPreferred == true
        @test length(action.diagnostics) == 1
        @test action.diagnostics[1].code == JETLS.LOWERING_UNUSED_LABEL_CODE
        edit = only(action.edit.changes[uri])
        @test edit.newText == ""
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[2]
    end

    # Label sharing a line with other statements: delete only the macrocall bytes
    let (code_actions, uri, positions) = get_unused_label_code_actions(
            "function f(); │@label unused│; return 1; end")
        @test length(code_actions) == 1
        edit = only(code_actions[1].edit.changes[uri])
        @test edit.newText == ""
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[2]
    end
end

module soft_scope_module
    global x = 1
end

function get_ambiguous_soft_scope_code_actions(marked_text::AbstractString)
    text, positions = JETLS.get_text_and_positions(marked_text)
    diagnostics, uri = get_lowering_diagnostics(text;
        code = JETLS.LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE,
        context_module = soft_scope_module)
    code_actions = Union{CodeAction,Command}[]
    JETLS.ambiguous_soft_scope_code_actions!(code_actions, uri, diagnostics)
    return code_actions, uri, positions
end

@testset "ambiguous soft scope code actions" begin
    # Basic case: for loop with indentation
    let (code_actions, uri, positions) = get_ambiguous_soft_scope_code_actions("""
        for _ = 1:10
        │    x = 2
        end
        """)
        @test length(code_actions) == 2
        @test code_actions[1].title == "Insert `global x` declaration"
        @test code_actions[1].isPreferred === nothing
        edit = only(code_actions[1].edit.changes[uri])
        @test edit.newText == "    global x\n"
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[1]
        @test code_actions[2].title == "Insert `local x` declaration"
        @test code_actions[2].isPreferred === nothing
        edit = only(code_actions[2].edit.changes[uri])
        @test edit.newText == "    local x\n"
        @test edit.range.start == positions[1]
    end

    # No code action when no global exists
    let (code_actions, _, _) = get_ambiguous_soft_scope_code_actions("""
        for _ = 1:10
            y = 2
        end
        """)
        @test isempty(code_actions)
    end

    # Tuple unpacking: indent matches the line, not the variable position
    let (code_actions, uri, positions) = get_ambiguous_soft_scope_code_actions("""
        for _ = 1:10
        │    y, x = 1, 2
        end
        """)
        global_actions = filter(a -> contains(a.title, "global"), code_actions)
        @test length(global_actions) == 1
        edit = only(global_actions[1].edit.changes[uri])
        @test edit.newText == "    global x\n"
        @test edit.range.start == positions[1]
        @test edit.range.var"end" == positions[1]
    end
end

function missing_concretization_diagnostic(assignment_file::String)
    return Diagnostic(;
        range = JETLS.line_range(1),
        severity = DiagnosticSeverity.Error,
        message = "`USE_PULSE` is not concretized",
        source = JETLS.DIAGNOSTIC_SOURCE_SAVE,
        code = JETLS.TOPLEVEL_MISSING_CONCRETIZATION_CODE,
        data = MissingConcretizationData("USE_PULSE", "USE_PULSE = x_", assignment_file))
end

@testset HierarchicalTestSet "missing concretization code actions" begin
    @testset "`jetls_config_append_text` appends a new pattern" begin
        text = "foo = 1\n"
        appended = JETLS.jetls_config_append_text(text, "USE_PULSE = x_", "issue464.jl")
        parsed = TOML.parse(text * appended)
        pattern_config = only(parsed["full_analysis"]["concretization_patterns"])
        @test pattern_config["pattern"] == "USE_PULSE = x_"
        @test pattern_config["path"] == "issue464.jl"
    end

    @testset "`format_jetls_concretization_pattern` escapes special characters" begin
        pattern = "A\nB\t\u0001\\\"雪"
        path = "src/A\nB\t\u0001\\\"雪.jl"
        text = JETLS.format_jetls_concretization_pattern(pattern, path)
        parsed = TOML.parse(text)
        pattern_config = only(parsed["full_analysis"]["concretization_patterns"])
        @test pattern_config["pattern"] == pattern
        @test pattern_config["path"] == path
    end

    @testset "inline concretization pattern arrays are extended" begin
        configs = String[
            """
            [full_analysis]
            concretization_patterns = []
            """,
            """
            [full_analysis]
            concretization_patterns = [{ pattern = "OLD = x_" }]
            """,
            "note = '''concretization_patterns = []'''\n" *
                "[full_analysis]\n" *
                "concretization_patterns = [\n" *
                "    { pattern = \"OLD = x_\", path = \"old.jl\" },\n" *
                "]\n",
            """
            full_analysis = { concretization_patterns = [] }
            """,
            """
            [full_analysis]
            "concretization_patterns" = []
            """,
        ]
        for original in configs
            before = TOML.parse(original)
            old_patterns = before["full_analysis"]["concretization_patterns"]
            edit = JETLS.jetls_config_inline_array_edit(
                original, "USE_PULSE = x_", "src/config.jl",
                PositionEncodingKind.UTF16)::TextEdit
            updated = JETLS.apply_text_change(
                original, edit.range, edit.newText, PositionEncodingKind.UTF16)
            parsed = TOML.parse(updated)
            patterns = parsed["full_analysis"]["concretization_patterns"]
            @test length(patterns) == length(old_patterns) + 1
            @test any(patterns) do config
                config["pattern"] == "USE_PULSE = x_" && config["path"] == "src/config.jl"
            end
            if haskey(before, "note")
                @test parsed["note"] == before["note"]
            end
        end
    end

    @testset "`jetls_config_append_text` skips already configured patterns" begin
        text = """
            [[full_analysis.concretization_patterns]]
            pattern = "USE_PULSE = x_"
            path = "issue464.jl"
            """
        @test JETLS.jetls_config_append_text(text, "USE_PULSE = x_", "issue464.jl") === nothing
    end

    @testset "existing config: append via `changes` fallback" begin
        mktempdir() do dir
            assignment_path = joinpath(dir, "config.jl")
            config_path = joinpath(dir, ".JETLSConfig.toml")
            write(assignment_path, "USE_PULSE = false\n")
            write(config_path, """
                [[full_analysis.concretization_patterns]]
                pattern = "OLD = x_"
                """)
            rootUri = filepath2uri(dir)
            withserver(; rootUri) do (; server)
                code_actions = Union{CodeAction,Command}[]
                JETLS.missing_concretization_code_actions!(
                    code_actions, server,
                    Diagnostic[missing_concretization_diagnostic(assignment_path)])
                action = only(code_actions)
                @test action.title ==
                    "Add `.JETLSConfig.toml` concretization pattern for `USE_PULSE`"
                edit = only(action.edit.changes[filepath2uri(config_path)])
                @test edit.range.start == edit.range.var"end"
                original = read(config_path, String)
                updated = JETLS.apply_text_change(
                    original, edit.range, edit.newText, server.state.encoding)
                parsed = TOML.parse(updated)
                patterns = parsed["full_analysis"]["concretization_patterns"]
                @test [config["pattern"] for config in patterns] == ["OLD = x_", "USE_PULSE = x_"]
                @test patterns[2]["path"] == "config.jl"

                dirty = original * "# unsaved\n"
                updated_dirty = JETLS.apply_text_change(
                    dirty, edit.range, edit.newText, server.state.encoding)
                @test occursin("# unsaved\n", updated_dirty)
            end
        end
    end

    @testset "existing config: edit inline array" begin
        mktempdir() do dir
            assignment_path = joinpath(dir, "config.jl")
            config_path = joinpath(dir, ".JETLSConfig.toml")
            original = """
                [full_analysis]
                concretization_patterns = []
                """
            write(assignment_path, "USE_PULSE = false\n")
            write(config_path, original)
            rootUri = filepath2uri(dir)
            withserver(; rootUri) do (; server)
                code_actions = Union{CodeAction,Command}[]
                JETLS.missing_concretization_code_actions!(
                    code_actions, server,
                    Diagnostic[missing_concretization_diagnostic(assignment_path)])
                action = only(code_actions)
                edit = only(action.edit.changes[filepath2uri(config_path)])
                updated = JETLS.apply_text_change(
                    original, edit.range, edit.newText, server.state.encoding)
                pattern_config = only(
                    TOML.parse(updated)["full_analysis"]["concretization_patterns"])
                @test pattern_config["pattern"] == "USE_PULSE = x_"
                @test pattern_config["path"] == "config.jl"
            end
        end
    end

    @testset "existing config: versioned edit for the synced document" begin
        mktempdir() do dir
            config_path = joinpath(dir, ".JETLSConfig.toml")
            config_uri = filepath2uri(config_path)
            original = """
                [[full_analysis.concretization_patterns]]
                pattern = "OLD = x_"
                """
            write(config_path, original)
            rootUri = filepath2uri(dir)
            capabilities = ClientCapabilities(;
                workspace = WorkspaceClientCapabilities(;
                    workspaceEdit = WorkspaceEditClientCapabilities(;
                        documentChanges = true)))
            withserver(; rootUri, capabilities) do (; server)
                JETLS.handle_DidOpenTextDocumentNotification(server,
                    make_DidOpenTextDocumentNotification(config_uri, original; languageId = "toml", version = 1))
                config_document = JETLS.get_config_document(server.state, config_uri)
                @test config_document.version == 1
                @test config_document.config_data == TOML.parse(original)

                live = original * "# unsaved\n"
                JETLS.handle_DidChangeTextDocumentNotification(server,
                    make_DidChangeTextDocumentNotification(config_uri, live, 2))
                config_document = JETLS.get_config_document(server.state, config_uri)
                @test config_document.version == 2
                @test config_document.text == live
                @test config_document.config_data == TOML.parse(live)

                edit = JETLS.jetls_config_workspace_edit(server, config_path, "USE_PULSE = x_", "issue464.jl")
                @test edit.changes === nothing
                document_edit = only(edit.documentChanges)::TextDocumentEdit
                @test document_edit.textDocument.uri == config_uri
                @test document_edit.textDocument.version == 2
                text_edit = only(document_edit.edits)
                updated = JETLS.apply_text_change(live, text_edit.range, text_edit.newText, server.state.encoding)
                @test startswith(updated, live)
                patterns = TOML.parse(updated)["full_analysis"]["concretization_patterns"]
                @test [config["pattern"] for config in patterns] == ["OLD = x_", "USE_PULSE = x_"]

                # The live document remains the edit target even after the file is
                # deleted on disk.
                rm(config_path)
                edit = JETLS.jetls_config_workspace_edit(server, config_path, "USE_PULSE = x_", "issue464.jl")
                document_edit = only(edit.documentChanges)::TextDocumentEdit
                @test document_edit.textDocument.version == 2

                invalid = "[full_analysis"
                JETLS.handle_DidChangeTextDocumentNotification(server,
                    make_DidChangeTextDocumentNotification(config_uri, invalid, 3))
                config_document = JETLS.get_config_document(server.state, config_uri)
                @test config_document.version == 3
                @test config_document.config_data === nothing
                @test JETLS.jetls_config_workspace_edit(server, config_path, "USE_PULSE = x_", "issue464.jl") === nothing

                JETLS.handle_DidCloseTextDocumentNotification(server,
                    make_DidCloseTextDocumentNotification(config_uri))
                @test JETLS.get_config_document(server.state, config_uri) === nothing
            end
        end
    end

    @testset "missing config: `CreateFile` edit" begin
        mktempdir() do dir
            script_path = joinpath(dir, "issue464.jl")
            write(script_path, "USE_PULSE = false\n")
            rootUri = filepath2uri(dir)
            capabilities = ClientCapabilities(;
                workspace = WorkspaceClientCapabilities(;
                    workspaceEdit = WorkspaceEditClientCapabilities(;
                        documentChanges = true,
                        resourceOperations = ResourceOperationKind.Ty[
                            ResourceOperationKind.Create])))
            withserver(; rootUri, capabilities) do (; server)
                code_actions = Union{CodeAction,Command}[]
                JETLS.missing_concretization_code_actions!(
                    code_actions, server,
                    Diagnostic[missing_concretization_diagnostic(script_path)])
                action = only(code_actions)
                @test action.title ==
                    "Create `.JETLSConfig.toml` concretization pattern for `USE_PULSE`"
                edit = action.edit
                @test edit.documentChanges !== nothing
                @test edit.documentChanges[1] isa CreateFile
                @test edit.documentChanges[2] isa TextDocumentEdit
                text_edit = only(edit.documentChanges[2].edits)
                parsed = TOML.parse(text_edit.newText)
                patterns = parsed["full_analysis"]["concretization_patterns"]
                pattern_config = only(patterns)
                @test pattern_config["pattern"] == "USE_PULSE = x_"
                @test pattern_config["path"] == "issue464.jl"
            end
        end
    end

    @testset "missing config: no edit without `CreateFile` support" begin
        mktempdir() do dir
            config_path = joinpath(dir, ".JETLSConfig.toml")
            rootUri = filepath2uri(dir)
            capabilities = ClientCapabilities(;
                workspace = WorkspaceClientCapabilities(;
                    workspaceEdit = WorkspaceEditClientCapabilities(;
                        documentChanges = true)))
            withserver(; rootUri, capabilities) do (; server)
                @test JETLS.jetls_config_workspace_edit(
                    server, config_path, "USE_PULSE = x_", "issue464.jl") === nothing
            end
        end
    end

    @testset "external assignment: no code action" begin
        mktempdir() do dir
            workspace = joinpath(dir, "workspace")
            mkpath(workspace)
            assignment_path = joinpath(dir, "config.jl")
            write(assignment_path, "USE_PULSE = false\n")
            write(joinpath(workspace, ".JETLSConfig.toml"), "")
            rootUri = filepath2uri(workspace)
            withserver(; rootUri) do (; server)
                @test isnothing(JETLS.concretization_pattern_path_for_code_action(
                    server, assignment_path))
                code_actions = Union{CodeAction,Command}[]
                JETLS.missing_concretization_code_actions!(
                    code_actions, server,
                    Diagnostic[missing_concretization_diagnostic(assignment_path)])
                @test isempty(code_actions)
            end
        end
    end
end

end # module test_code_action
