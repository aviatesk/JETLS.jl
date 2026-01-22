module test_code_action

using Test
using JETLS
using JETLS: JL, JS
using JETLS.LSP
using JETLS.LSP.URIs2

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

@testset "unused_variable_code_actions" begin
    uri = URI("file:///test.jl")

    let diagnostic = Diagnostic(;
            range = Range(;
                start = Position(; line=0, character=13),
                var"end" = Position(; line=0, character=14)),
            severity = DiagnosticSeverity.Information,
            message = "Unused argument `y`",
            source = JETLS.DIAGNOSTIC_SOURCE_LIVE,
            code = JETLS.LOWERING_UNUSED_ARGUMENT_CODE)
        code_actions = Union{CodeAction,Command}[]
        JETLS.unused_variable_code_actions!(code_actions, uri, [diagnostic])
        @test length(code_actions) == 1
        action = only(code_actions)
        @test action.title == "Prefix with '_' to indicate intentionally unused"
        @test action.isPreferred == true
        @test action.edit !== nothing
        changes = action.edit.changes
        @test haskey(changes, uri)
        edits = changes[uri]
        @test length(edits) == 1
        edit = only(edits)
        @test edit.range.start.line == 0
        @test edit.range.start.character == 13
        @test edit.newText == "_"
    end

    let diagnostic = Diagnostic(;
            range = Range(;
                start = Position(; line=1, character=10),
                var"end" = Position(; line=1, character=11)),
            severity = DiagnosticSeverity.Information,
            message = "Unused local binding `x`",
            source = JETLS.DIAGNOSTIC_SOURCE_LIVE,
            code = JETLS.LOWERING_UNUSED_LOCAL_CODE)
        code_actions = Union{CodeAction,Command}[]
        JETLS.unused_variable_code_actions!(code_actions, uri, [diagnostic])
        @test length(code_actions) == 1
        action = only(code_actions)
        @test action.title == "Prefix with '_' to indicate intentionally unused"
        @test action.disabled === nothing
        @test action.isPreferred == true
    end

    let diagnostic = Diagnostic(;
            range = Range(;
                start = Position(; line=0, character=13),
                var"end" = Position(; line=0, character=14)),
            severity = DiagnosticSeverity.Information,
            message = "Unused argument `y`",
            source = JETLS.DIAGNOSTIC_SOURCE_LIVE,
            code = JETLS.LOWERING_UNUSED_ARGUMENT_CODE)
        code_actions = Union{CodeAction,Command}[]
        JETLS.unused_variable_code_actions!(code_actions, uri, [diagnostic]; allow_unused_underscore=false)
        @test length(code_actions) == 1
        action = only(code_actions)
        @test action.title == "Replace with '_' to indicate intentionally unused"
        @test action.isPreferred == true
        @test action.disabled === nothing
        edits = action.edit.changes[uri]
        edit = only(edits)
        @test edit.range.start.character == 13
        @test edit.range.var"end".character == 14
        @test edit.newText == "_"
    end

    let diagnostic = Diagnostic(;
            range = Range(;
                start = Position(; line=0, character=0),
                var"end" = Position(; line=0, character=10)),
            severity = DiagnosticSeverity.Error,
            message = "Some other error",
            source = JETLS.DIAGNOSTIC_SOURCE_LIVE,
            code = JETLS.LOWERING_ERROR_CODE)
        code_actions = Union{CodeAction,Command}[]
        JETLS.unused_variable_code_actions!(code_actions, uri, [diagnostic])
        @test isempty(code_actions)
    end

    # Test delete actions for unused local bindings with UnusedVariableData
    let assignment_range = Range(;
            start = Position(; line=1, character=4),
            var"end" = Position(; line=1, character=18))
        lhs_eq_range = Range(;
            start = Position(; line=1, character=4),
            var"end" = Position(; line=1, character=8))
        data = UnusedVariableData(false, assignment_range, lhs_eq_range)
        diagnostic = Diagnostic(;
            range = Range(;
                start = Position(; line=1, character=4),
                var"end" = Position(; line=1, character=5)),
            severity = DiagnosticSeverity.Information,
            message = "Unused local binding `y`",
            source = JETLS.DIAGNOSTIC_SOURCE_LIVE,
            code = JETLS.LOWERING_UNUSED_LOCAL_CODE,
            data)
        code_actions = Union{CodeAction,Command}[]
        JETLS.unused_variable_code_actions!(code_actions, uri, [diagnostic])
        @test length(code_actions) == 3  # _ prefix + delete assignment + delete statement
        @test code_actions[1].title == "Prefix with '_' to indicate intentionally unused"
        @test code_actions[1].isPreferred == true
        @test code_actions[2].title == "Delete assignment"
        @test code_actions[2].isPreferred === nothing
        @test code_actions[2].edit.changes[uri][1].range == lhs_eq_range
        @test code_actions[2].edit.changes[uri][1].newText == ""
        @test code_actions[3].title == "Delete statement"
        @test code_actions[3].isPreferred === nothing
        @test code_actions[3].edit.changes[uri][1].range == assignment_range
        @test code_actions[3].edit.changes[uri][1].newText == ""
    end

    # Test no delete actions for tuple unpacking
    let data = UnusedVariableData(true, nothing, nothing)
        diagnostic = Diagnostic(;
            range = Range(;
                start = Position(; line=1, character=7),
                var"end" = Position(; line=1, character=8)),
            severity = DiagnosticSeverity.Information,
            message = "Unused local binding `y`",
            source = JETLS.DIAGNOSTIC_SOURCE_LIVE,
            code = JETLS.LOWERING_UNUSED_LOCAL_CODE,
            data)
        code_actions = Union{CodeAction,Command}[]
        JETLS.unused_variable_code_actions!(code_actions, uri, [diagnostic])
        @test length(code_actions) == 1  # only _ prefix
        @test code_actions[1].title == "Prefix with '_' to indicate intentionally unused"
    end
end

function get_sort_imports_code_actions(text::AbstractString)
    fi = JETLS.FileInfo(#=version=#0, text, @__FILE__)
    uri = filepath2uri(@__FILE__)
    st0 = JETLS.build_syntax_tree(fi)
    diagnostics = Diagnostic[]
    JETLS.analyze_unsorted_imports!(diagnostics, fi, st0)
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

end # module test_code_action
