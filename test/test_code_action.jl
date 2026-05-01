module test_code_action

using Test
using JETLS
using JETLS: JL, JS
using JETLS.LSP
using JETLS.LSP.URIs2

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

module lowering_module end

function get_lowering_diagnostics(
        text::AbstractString, code::Union{AbstractString,Nothing} = nothing;
        mod::Module = lowering_module, kwargs...
    )
    filename = abspath(pkgdir(JETLS), "test", "test_code_action.jl")
    fi = JETLS.FileInfo(#=version=#0, text, filename)
    uri = filepath2uri(filename)
    st0_top = JETLS.build_syntax_tree(fi)
    diagnostics = LSP.Diagnostic[]
    JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        JETLS.lowering_diagnostics!(diagnostics, uri, fi, mod, st0; kwargs...)
    end
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
        @test code_actions[1].title == "Prefix with '_' to indicate intentionally unused"
        @test code_actions[1].isPreferred == true
        @test code_actions[2].title == "Delete assignment"
        @test code_actions[2].edit.changes[uri][1].newText == ""
        @test code_actions[2].edit.changes[uri][1].range.start == positions[1]
        @test code_actions[2].edit.changes[uri][1].range.var"end" == positions[2]
        @test code_actions[3].title == "Delete statement"
        @test code_actions[3].edit.changes[uri][1].newText == ""
        @test code_actions[3].edit.changes[uri][1].range.start == positions[1]
        @test code_actions[3].edit.changes[uri][1].range.var"end" == positions[3]
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
        rename_actions = filter(a -> contains(a.title, "Prefix") || contains(a.title, "Replace"), code_actions)
        @test isempty(rename_actions)
    end
end

function get_sort_imports_code_actions(text::AbstractString)
    diagnostics, uri = get_lowering_diagnostics(text, JETLS.LOWERING_UNSORTED_IMPORT_NAMES_CODE)
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
    server = JETLS.Server()
    uri = URI("file:///test_unused_imports.jl")
    fi = JETLS.cache_file_info!(server, uri, 1, text)
    st0_top = JETLS.build_syntax_tree(fi)
    diagnostics = JETLS.analyze_unused_imports(server, uri, fi, st0_top;
        skip_context_check=true)
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
    diagnostics, uri = get_lowering_diagnostics(text, JETLS.LOWERING_UNREACHABLE_CODE)
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
    diagnostics, uri = get_lowering_diagnostics(text, JETLS.LOWERING_UNUSED_LABEL_CODE)
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
    diagnostics, uri = get_lowering_diagnostics(
        text, JETLS.LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE; mod = soft_scope_module)
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
        @test code_actions[1].isPreferred == true
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

end # module test_code_action
