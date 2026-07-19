module test_rename

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

function rename_testcase(
        code::AbstractString, n::Int;
        # Use a unique filename per call so that the various server caches
        # (file cache, binding-occurrences cache, analysis info) keyed by URI
        # stay isolated between tests — otherwise successive tests sharing a
        # URI can hit stale cache entries when byte ranges of top-level
        # statements happen to coincide.
        filename::AbstractString = joinpath(@__DIR__, "testfile_$(gensym(:rename_testcase)).jl"),
        server::Union{JETLS.Server,Nothing} = nothing,
        context_module::Union{Module,Nothing} = nothing,
    )
    clean_code, positions = JETLS.get_text_and_positions(code)
    @assert length(positions) == n
    fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
    @assert issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
    furi = filename2uri(filename)
    # Register the file with the provided server so that
    # `get_file_info`/`collect_global_rename_edits!` can actually find it —
    # otherwise global rename silently returns an empty `changes` dict.
    if server !== nothing
        JETLS.store!(server.state.file_cache) do cache
            Base.PersistentDict(cache, furi => fi), nothing
        end
        # Tie the file URI to a dedicated module so that `get_context_info`
        # (and downstream occurrence resolution) agrees with whatever module
        # the caller passes to `global_binding_rename`. Without this the file
        # falls back to `Main`, causing a module mismatch that makes
        # `find_global_binding_occurrences!` miss every occurrence.
        if context_module !== nothing
            JETLS.cache_out_of_scope!(
                server.state.analysis_manager, furi, JETLS.OutOfScope(context_module))
        end
    end
    return fi, positions, furi
end

module test_import_rename_context end

function binding_rename_testcase(code::AbstractString, n::Int; kwargs...)
    fi, positions, furi = rename_testcase(code, n; kwargs...)
    world = Base.get_world_counter()
    return (; fi, positions, furi, world)
end

function local_rename_preparation_testcase(
        state::JETLS.ServerState, code::AbstractString, n::Int,
        context_module::Module
    )
    (; fi, positions, furi, world) = binding_rename_testcase(code, n)
    prepare(pos::Position) = JETLS.prepare_local_binding_rename(
        state, furi, fi, pos, context_module, world)
    return (; positions, prepare)
end

function global_rename_preparation_testcase(
        state::JETLS.ServerState, code::AbstractString, n::Int,
        context_module::Module
    )
    (; fi, positions, furi, world) = binding_rename_testcase(code, n)
    prepare(pos::Position) = JETLS.prepare_global_binding_rename(
        state, furi, fi, pos, context_module, world)
    return (; positions, prepare)
end

function local_rename_testcase(
        server::JETLS.Server, code::AbstractString, n::Int,
        context_module::Module
    )
    (; fi, positions, furi, world) = binding_rename_testcase(code, n)
    rename_binding(pos::Position, new_name::String) = JETLS.get_local_binding_rename(
        server, furi, fi, pos, context_module, world, new_name)
    return (; positions, furi, rename_binding)
end

function global_rename_testcase(
        server::JETLS.Server, code::AbstractString, n::Int,
        context_module::Module; register_file::Bool = false
    )
    testcase = if register_file
        binding_rename_testcase(code, n; server, context_module)
    else
        binding_rename_testcase(code, n)
    end
    (; fi, positions, furi, world) = testcase
    rename_binding(pos::Position, new_name::String) = JETLS.get_global_binding_rename(
        server, furi, fi, pos, context_module, world, new_name)
    return (; positions, furi, rename_binding)
end

@testset "local_binding_rename_preparation" begin
    state = JETLS.ServerState()
    let code = """
        function func(│xx│x│, yyy)
            │pri│ntln│(│xx│x│, yyy)
        end
        """
        (; positions, prepare) = local_rename_preparation_testcase(state, code, 9, @__MODULE__)
        for (i, pos) in enumerate(positions)
            if i in (4,5,6) # println
                rename_prep = prepare(pos)
                @test isnothing(rename_prep)
            else
                rename_prep = prepare(pos)
                @test !isnothing(rename_prep)
                @test rename_prep.placeholder == "xxx"
            end
        end
    end

    let code = """
        func(xxx) = println(xxx, 4│2)
        """
        (; positions, prepare) = local_rename_preparation_testcase(state, code, 1, @__MODULE__)
        rename_prep = prepare(only(positions))
        @test isnothing(rename_prep)
    end

    @testset "static parameter rename prepare" begin
        code = """
        func(::│TTT│) where │TTT│<:Integer = zero(│TTT│)
        """
        (; positions, prepare) = local_rename_preparation_testcase(state, code, 6, @__MODULE__)
        for pos in positions
            rename_prep = prepare(pos)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "TTT"
        end
    end

    @testset "rename prepare with docstring" begin
        code = """
        \"\"\"Docstring\"\"\"
        function func(│xxx│, yyy)
            println(│xxx│, yyy)
        end
        """
        (; positions, prepare) = local_rename_preparation_testcase(state, code, 4, @__MODULE__)
        for pos in positions
            rename_prep = prepare(pos)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "xxx"
        end
    end

    @testset "rename prepare with macrocall" begin
        code = """
        func(│xxx│) = @something rand((│xxx│, nothing)) return nothing
        """
        (; positions, prepare) = local_rename_preparation_testcase(state, code, 4, @__MODULE__)
        for pos in positions
            rename_prep = prepare(pos)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "xxx"
        end
    end
end

@testset "local_binding_rename" begin
    server = JETLS.Server()
    let code = """
        function func(│xx│x│, yyy)
            │pri│ntln│(│xx│x│, yyy)
        end
        """
        (; positions, furi, rename_binding) = local_rename_testcase(server, code, 9, @__MODULE__)
        for (i, pos) in enumerate(positions)
            if i in (4,5,6) # println, should never be called if client supports rename prepare
                rename = rename_binding(pos, "zzz")
                @test isnothing(rename)
            else
                (; result, error) = rename_binding(pos, "zzz")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 2
                    @test count(edits) do edit
                        edit.newText == "zzz" &&
                        edit.range == Range(; start=positions[1], var"end"=positions[3])
                    end == 1
                    @test count(edits) do edit
                        edit.newText == "zzz" &&
                        edit.range == Range(; start=positions[7], var"end"=positions[9])
                    end == 1
                end
            end
        end
    end

    # Guard against invalid variable names
    let code = "func(xx│x, yyy) = println(xxx, yyy)"
        (; positions, rename_binding) = local_rename_testcase(server, code, 1, @__MODULE__)
        let
            (; result, error) = rename_binding(only(positions), "zzz zzz")
            @test isnothing(result) && error isa ResponseError
        end
        let
            (; result, error) = rename_binding(only(positions), "42zzz")
            @test isnothing(result) && error isa ResponseError
        end
        let
            (; result, error) = rename_binding(only(positions), "'zzz'")
            @test isnothing(result) && error isa ResponseError
        end
    end

    # Allow renaming on var"names"
    let code = """func(var"│xxx│") = println(var"│xxx│")"""
        (; positions, furi, rename_binding) = local_rename_testcase(server, code, 4, @__MODULE__)
        for pos in positions
            (; result, error) = rename_binding(pos, "zzz zzz")
            @test result isa WorkspaceEdit && isnothing(error)
            for (uri, edits) in result.changes
                @test furi == uri
                @test length(edits) == 2
                @test count(edits) do edit
                    edit.newText == "zzz zzz" &&
                    edit.range == Range(; start=positions[1], var"end"=positions[2])
                end == 1
                @test count(edits) do edit
                    edit.newText == "zzz zzz" &&
                    edit.range == Range(; start=positions[3], var"end"=positions[4])
                end == 1
            end
        end
    end

    @testset "static parameter rename" begin
        let code = """
            func(::│TTT│) where │TTT│<:Integer = zero(│TTT│)
            """
            (; positions, furi, rename_binding) = local_rename_testcase(server, code, 6, @__MODULE__)
            for pos in positions
                (; result, error) = rename_binding(pos, "SSS")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 3
                    @test count(edits) do edit
                        edit.newText == "SSS" &&
                        edit.range == Range(; start=positions[1], var"end"=positions[2])
                    end == 1
                    @test count(edits) do edit
                        edit.newText == "SSS" &&
                        edit.range == Range(; start=positions[3], var"end"=positions[4])
                    end == 1
                    @test count(edits) do edit
                        edit.newText == "SSS" &&
                        edit.range == Range(; start=positions[5], var"end"=positions[6])
                    end == 1
                end
            end
        end
    end

    @testset "rename with docstring" begin
        code = """
        \"\"\"Docstring\"\"\"
        function func(│xxx│, yyy)
            println(│xxx│, yyy)
        end
        """
        (; positions, furi, rename_binding) = local_rename_testcase(server, code, 4, @__MODULE__)
        for pos in positions
            (; result, error) = rename_binding(pos, "zzz")
            @test result isa WorkspaceEdit && isnothing(error)
            for (uri, edits) in result.changes
                @test furi == uri
                @test length(edits) == 2
                @test count(edits) do edit
                    edit.newText == "zzz" &&
                    edit.range == Range(; start=positions[1], var"end"=positions[2])
                end == 1
                @test count(edits) do edit
                    edit.newText == "zzz" &&
                    edit.range == Range(; start=positions[3], var"end"=positions[4])
                end == 1
            end
        end
    end

    @testset "rename with macrocall" begin
        code = """
        func(│xxx│) = @something rand((│xxx│, nothing)) return nothing
        """
        (; positions, furi, rename_binding) = local_rename_testcase(server, code, 4, @__MODULE__)
        for pos in positions
            (; result, error) = rename_binding(pos, "yyy")
            @test result isa WorkspaceEdit && isnothing(error)
            for (uri, edits) in result.changes
                @test furi == uri
                @test length(edits) == 2
                @test count(edits) do edit
                    edit.newText == "yyy" &&
                    edit.range == Range(; start=positions[1], var"end"=positions[2])
                end == 1
                @test count(edits) do edit
                    edit.newText == "yyy" &&
                    edit.range == Range(; start=positions[3], var"end"=positions[4])
                end == 1
            end
        end
    end

    @testset "rename across @static branches" begin
        # A use in a `@static` branch not selected for the current platform must be
        # renamed too — otherwise the rename leaves that branch referring to the old name,
        # breaking the code on the platform where the branch is taken.
        code = """
        function func()
            │xx│x│ = 1
            @static if Sys.iswindows()
                println(│xx│x│)
            else
                println(│xx│x│)
            end
        end
        """
        (; positions, furi, rename_binding) = local_rename_testcase(server, code, 9, @__MODULE__)
        for pos in positions
            (; result, error) = rename_binding(pos, "yyy")
            @test result isa WorkspaceEdit && isnothing(error)
            for (uri, edits) in result.changes
                @test furi == uri
                @test length(edits) == 3
                @test count(edits) do edit
                    edit.newText == "yyy" &&
                    edit.range == Range(; start=positions[1], var"end"=positions[3])
                end == 1
                @test count(edits) do edit
                    edit.newText == "yyy" &&
                    edit.range == Range(; start=positions[4], var"end"=positions[6])
                end == 1
                @test count(edits) do edit
                    edit.newText == "yyy" &&
                    edit.range == Range(; start=positions[7], var"end"=positions[9])
                end == 1
            end
        end
    end

    @testset "@generated function rename" begin
        let code = """
            @generated function foo(│x│)
                return :(copy(│x│) + │x│)
            end
            """
            (; positions, furi, rename_binding) = local_rename_testcase(server, code, 6, @__MODULE__)
            for pos in positions
                (; result, error) = rename_binding(pos, "y")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 3
                    @test all(edit -> edit.newText == "y", edits)
                end
            end
        end

        # Quote-local bindings shadow the generated argument.
        let code = """
            @generated function foo(│x│)
                return :(let │x│ = 1
                    │x│
                end)
            end
            """
            (; positions, rename_binding) = local_rename_testcase(server, code, 6, @__MODULE__)
            let rename_result = rename_binding(positions[1], "arg")
                @test rename_result !== nothing
                (; result, error) = rename_result
                @test result isa WorkspaceEdit && isnothing(error)
                edits = only(result.changes).second
                @test length(edits) == 1
            end
            let rename_result = rename_binding(positions[3], "local_x")
                @test rename_result !== nothing
                (; result, error) = rename_result
                @test result isa WorkspaceEdit && isnothing(error)
                edits = only(result.changes).second
                @test length(edits) == 2
            end
        end

        # Static parameter merging
        let code = """
            @generated function foo(x::│T│) where {│T│}
                return :(zero(│T│))
            end
            """
            (; positions, furi, rename_binding) = local_rename_testcase(server, code, 6, @__MODULE__)
            for pos in positions
                (; result, error) = rename_binding(pos, "S")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 3
                    @test all(edit -> edit.newText == "S", edits)
                end
            end
        end

        # aviatesk/JETLS.jl#722: a `@generated` function nested inside a
        # `struct` body must still attribute its argument's inert uses.
        let code = """
            struct Test722
                x::Int
                @generated function Test722(│x│)
                    return Expr(:new, :(Test722), :│x│)
                end
            end
            """
            (; positions, furi, rename_binding) = local_rename_testcase(server, code, 4, @__MODULE__)
            for pos in positions
                (; result, error) = rename_binding(pos, "y")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 2
                    @test all(edit -> edit.newText == "y", edits)
                end
            end
        end
    end

    @testset "ordinary quote-local rename" begin
        code = """
        f() = :(let │x│ = 1
            │x│
        end)
        """
        (; positions, rename_binding) = local_rename_testcase(server, code, 4, @__MODULE__)
        for pos in positions
            rename_result = rename_binding(pos, "y")
            @test rename_result !== nothing &&
                rename_result.result isa WorkspaceEdit &&
                length(only(rename_result.result.changes).second) == 2
        end
    end
end

@testset "global_binding_rename_preparation" begin
    state = JETLS.ServerState()
    let code = """
        │foo│() = 42
        │bar│ = │foo│()
        │println│(│bar│)
        """
        (; positions, prepare) = global_rename_preparation_testcase(state, code, 10, @__MODULE__)
        for pos in positions[1:2]
            rename_prep = prepare(pos)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "foo"
        end
        for pos in positions[3:4]
            rename_prep = prepare(pos)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "bar"
        end
        for pos in positions[5:6]
            rename_prep = prepare(pos)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "foo"
        end
        for pos in positions[7:8]
            rename_prep = prepare(pos)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "println"
        end
        for pos in positions[9:10]
            rename_prep = prepare(pos)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "bar"
        end
    end

    # Non-binding position should be rejected
    let code = "func(xxx) = println(xxx, 4│2)"
        (; positions, prepare) = global_rename_preparation_testcase(state, code, 1, @__MODULE__)
        rename_prep = prepare(only(positions))
        @test isnothing(rename_prep)
    end

    @testset "ordinary unanchored quote" begin
        let code = "f() = :(use(│x│))"
            (; positions, prepare) = global_rename_preparation_testcase(state, code, 2, @__MODULE__)
            for pos in positions
                rename_prep = prepare(pos)
                @test !isnothing(rename_prep) && rename_prep.placeholder == "x"
            end
        end

        # An atomic quoted identifier is Symbol data, not a global binding target.
        let code = "names = (:│sin│, :cos)"
            (; positions, prepare) = global_rename_preparation_testcase(state, code, 2, @__MODULE__)
            for pos in positions
                rename_prep = prepare(pos)
                @test isnothing(rename_prep)
            end
        end
    end

    @testset "macro rename prepare" begin
        # From definition site
        let code = """
            macro │mymacro│(ex)
                esc(ex)
            end
            @mymacro println("hello")
            """
            (; positions, prepare) = global_rename_preparation_testcase(state, code, 2, @__MODULE__)
            # Only test start position (end position selects implicit macro arg)
            rename_prep = prepare(positions[1])
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "mymacro"
        end

        # From macrocall site
        let code = """
            macro mymacro(ex)
                esc(ex)
            end
            │@my│macro println("hello")
            """
            (; positions, prepare) = global_rename_preparation_testcase(state, code, 2, @__MODULE__)
            for pos in positions
                rename_prep = prepare(pos)
                @test !isnothing(rename_prep)
                @test rename_prep.placeholder == "mymacro"
            end
        end
    end
end

@testset "global_binding_rename" begin
    server = JETLS.Server()
    let code = """
        │foo│() = 42
        baz() = │foo│()
        │foo│(x) = x + 1
        """
        (; positions, furi, rename_binding) = global_rename_testcase(server, code, 6, @__MODULE__)
        for pos in positions
            (; result, error) = rename_binding(pos, "qux")
            @test result isa WorkspaceEdit && isnothing(error)
            for (uri, edits) in result.changes
                @test furi == uri
                @test length(edits) == 3
                @test all(edit -> edit.newText == "qux", edits)
            end
        end
    end

    @testset "macro rename" begin
        # All occurrences should be renamed to the identifier without `@`,
        # and `@` at call sites should be preserved.
        let code = """
            macro │mymacro(ex)
                esc(ex)
            end
            │@│mymacro println("hello")
            │@│mymacro println("world")
            """
            (; positions, furi, rename_binding) = global_rename_testcase(server, code, 5, @__MODULE__)
            # Test from definition position
            let pos = positions[1]
                (; result, error) = rename_binding(pos, "newmacro")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 3
                    @test all(edit -> edit.newText == "newmacro", edits)
                    # Call site ranges should skip `@`
                    for edit in edits
                        if edit.range.start.line != positions[1].line
                            @test edit.range.start.character == positions[2].character + 1
                        end
                    end
                end
            end
            # Test from macrocall positions
            for pos in positions[2:5]
                (; result, error) = rename_binding(pos, "newmacro")
                @test result isa WorkspaceEdit && isnothing(error)
                for (_, edits) in result.changes
                    @test length(edits) == 3
                    @test all(edit -> edit.newText == "newmacro", edits)
                end
            end
        end

        # newName with `@` prefix should also work
        let code = """
            macro │mymacro(ex)
                esc(ex)
            end
            │@│mymacro println("hello")
            """
            (; positions, rename_binding) = global_rename_testcase(server, code, 3, @__MODULE__)
            for pos in positions
                (; result, error) = rename_binding(pos, "@newmacro")
                @test result isa WorkspaceEdit && isnothing(error)
                for (_, edits) in result.changes
                    @test all(edit -> edit.newText == "newmacro", edits)
                end
            end
        end
    end

    @testset "import/using rename" begin
        # Renaming a bare imported name inserts ` as newname` at the import
        # site (preserving the source name) and replaces local uses.
        let code = """
            using Base: │foo│
            │foo│(1)
            bar() = │foo│()
            """
            (; positions, rename_binding) = global_rename_testcase(
                server, code, 6, test_import_rename_context; register_file=true)
            for pos in positions
                (; result, error) = rename_binding(pos, "qux")
                @test result isa WorkspaceEdit && isnothing(error)
                edits = only(result.changes).second
                @test length(edits) == 3
                @test count(e -> e.newText == "qux", edits) == 2
                @test count(e -> e.newText == " as qux", edits) == 1
                # The as-insertion is zero-width, right after the import identifier
                as_edit = only(filter(e -> e.newText == " as qux", edits))
                @test as_edit.range.start == as_edit.range.var"end"
                @test as_edit.range.start == positions[2]
            end
        end

        # Renaming an existing `as`-alias just renames the alias.
        let code = """
            using Base: foo as │myfoo│
            │myfoo│(1)
            """
            (; positions, rename_binding) = global_rename_testcase(
                server, code, 4, test_import_rename_context; register_file=true)
            for pos in positions
                (; result, error) = rename_binding(pos, "qux")
                @test result isa WorkspaceEdit && isnothing(error)
                edits = only(result.changes).second
                @test length(edits) == 2
                @test all(e -> e.newText == "qux", edits)
            end
        end

        # Renaming an alias back to its source name drops the ` as <alias>`.
        let code = """
            using Random: randcycle as │randcycle2│
            │randcycle2│(5)
            """
            (; positions, rename_binding) = global_rename_testcase(
                server, code, 4, test_import_rename_context; register_file=true)
            for pos in positions
                (; result, error) = rename_binding(pos, "randcycle")
                @test result isa WorkspaceEdit && isnothing(error)
                edits = only(result.changes).second
                @test length(edits) == 2
                @test count(e -> e.newText == "randcycle", edits) == 1
                @test count(e -> e.newText == "", edits) == 1
                # The deletion is at the end of `randcycle` inside the import,
                # spanning through the end of `randcycle2` (i.e. ` as randcycle2`)
                delete_edit = only(filter(e -> e.newText == "", edits))
                @test delete_edit.range.var"end" == positions[2]
            end
        end

        # `import M.name` supports `as`, so the same as-insertion is used.
        let code = """
            import Base.│sin│
            │sin│(1.0)
            """
            (; positions, rename_binding) = global_rename_testcase(
                server, code, 4, test_import_rename_context; register_file=true)
            for pos in positions
                (; result, error) = rename_binding(pos, "mysin")
                @test result isa WorkspaceEdit && isnothing(error)
                edits = only(result.changes).second
                @test length(edits) == 2
                @test count(e -> e.newText == "mysin", edits) == 1
                @test count(e -> e.newText == " as mysin", edits) == 1
            end
        end

        # `using M.name` cannot use `as` (invalid Julia syntax), so fall back
        # to a bare replacement of the module name.
        let code = """
            using Base.│Iterators│
            """
            (; positions, rename_binding) = global_rename_testcase(
                server, code, 2, test_import_rename_context; register_file=true)
            for pos in positions
                (; result, error) = rename_binding(pos, "MyIter")
                @test result isa WorkspaceEdit && isnothing(error)
                edits = only(result.changes).second
                @test length(edits) == 1
                @test only(edits).newText == "MyIter"
            end
        end
    end

    @testset "export/public rename" begin
        # Renaming from a cursor inside `export`/`public` should rewrite every
        # occurrence, including the export statement itself.
        code = """
        │foo│() = 42
        export │foo│
        bar() = │foo│()
        """
        (; positions, rename_binding) = global_rename_testcase(
            server, code, 6, @__MODULE__)
        for pos in positions
            (; result, error) = rename_binding(pos, "qux")
            @test result isa WorkspaceEdit && isnothing(error)
            for (_, edits) in result.changes
                @test length(edits) == 3
                @test all(edit -> edit.newText == "qux", edits)
            end
        end
    end
end

@testset "file_rename_preparation" begin
    state = JETLS.ServerState()
    mktempdir() do dir
        touch(joinpath(dir, "foo.jl"))
        mkdir(joinpath(dir, "subdir"))
        touch(joinpath(dir, "subdir/foo.jl"))
        touch(joinpath(dir, "README.md"))

        for target_name = ("foo.jl", "subdir/foo.jl", "README.md")
            code = """include("│$(target_name)│")"""
            fi, positions, furi = rename_testcase(code, 2;
                filename = joinpath(dir, "main.jl"))
            for pos in positions
                rename_prep = JETLS.prepare_file_rename(state, furi, fi, pos)
                @test !isnothing(rename_prep)
                @test rename_prep.placeholder == target_name
            end
        end

        let code = """include("│nonexistent.jl│")"""
            fi, positions, furi = rename_testcase(code, 2;
                filename = joinpath(dir, "main.jl"))
            rename_prep = JETLS.prepare_file_rename(state, furi, fi, positions[1])
            @test isnothing(rename_prep)
        end
    end
end

@testset "file_rename" begin
    server = JETLS.Server()
    mktempdir() do dir
        touch(joinpath(dir, "foo.jl"))
        code = """include("│foo.jl│")"""
        fi, positions, furi = rename_testcase(code, 2;
            filename = joinpath(dir, "main.jl"))
        for pos in positions
            (; result, error) = JETLS.get_file_rename(server, furi, fi, pos, "bar.jl")
            @test result isa WorkspaceEdit && isnothing(error)
            @test length(result.changes) == 1
            edits = result.changes[furi]
            @test length(edits) == 1
            @test edits[1].newText == "bar.jl"
        end
    end
end

end # test_rename
