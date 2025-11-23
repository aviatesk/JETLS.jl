using Base: UUID
using Preferences, Test, TOML, Pkg, SHA

function activate(f::Function, env_dir::String)
    saved_active_project = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = env_dir
    try
        f()
    finally
        Base.ACTIVE_PROJECT[] = saved_active_project
    end
end

function with_temp_depot(f::Function)
    mktempdir() do dir
        saved_depot_path = copy(Base.DEPOT_PATH)
        empty!(Base.DEPOT_PATH)
        push!(Base.DEPOT_PATH, dir)
        try
            f()
        finally
            empty!(Base.DEPOT_PATH)
            append!(Base.DEPOT_PATH, saved_depot_path)
        end
    end
end

function activate_and_run(project_dir::String, code::String; env::Dict = Dict())
    mktempdir() do dir
        open(joinpath(dir, "test_code.jl"), "w") do io
            write(io, code)
        end

        out = Pipe()
        cmd = setenv(`$(Base.julia_cmd()) --project=$(project_dir) $(dir)/test_code.jl`,
                     env..., "JULIA_DEPOT_PATH" => Base.DEPOT_PATH[1])
        p = run(pipeline(cmd, stdout=out, stderr=out); wait=false)
        close(out.in)
        wait(p)
        output = String(read(out))
        if !success(p)
            println(output)
        end
        @test success(p)
        return output
    end
end

# Some useful constants
up_uuid = UUID(TOML.parsefile(joinpath(@__DIR__, "UsesPreferences", "Project.toml"))["uuid"])
up_path = joinpath(@__DIR__, "UsesPreferences")

@testset "Preferences" begin
    # Ensure there is no LocalPreferences.toml file in UsesPreferences:
    local_prefs_toml = joinpath(up_path, "LocalPreferences.toml")
    rm(local_prefs_toml; force=true)
    with_temp_depot() do
        # Start with the default test of the backend being un-set, we just get the default
        activate_and_run(up_path, """
            using UsesPreferences, Test, Preferences
            using Base: UUID
            @test load_preference($(repr(up_uuid)), "backend") === nothing
            @test UsesPreferences.backend == "OpenCL"
        """)

        # Test clearing a preference (setting to `nothing`)
        activate_and_run(up_path, """
            using UsesPreferences
            UsesPreferences.clear_backend()
        """)
        prefs = TOML.parsefile(local_prefs_toml)
        @test prefs["UsesPreferences"]["__clear__"] == ["backend", "extra"]

        # Next, change a setting
        activate_and_run(up_path, """
            using UsesPreferences
            UsesPreferences.set_backend("CUDA")
        """)

        # Ensure that's showing up in LocalPreferences.toml:
        prefs = TOML.parsefile(local_prefs_toml)
        @test haskey(prefs, "UsesPreferences")
        @test prefs["UsesPreferences"]["backend"] == "CUDA"
        # Setting a preference value should remove it from `__clear__`:
        @test !haskey(prefs["UsesPreferences"], "__clear__")

        # Now show that it forces recompilation
        function did_precompile(output)
            occursin("Precompiling UsesPreferences [$(string(up_uuid))]", output) ||
            occursin("Precompiling\e[22m\e[39m UsesPreferences", output) ||
            occursin(r"\e\[32m +✓ +\e\[39mUsesPreferences", output)
        end
        cuda_test = """
        using UsesPreferences, Test
        @test UsesPreferences.backend == "CUDA"
        """
        output = activate_and_run(up_path, cuda_test; env=Dict("JULIA_DEBUG" => "loading"))
        @test did_precompile(output)

        # Show that it does not force a recompile the second time
        output = activate_and_run(up_path, cuda_test; env=Dict("JULIA_DEBUG" => "loading"))
        @test !did_precompile(output)

        # Test non-compiletime preferences a bit
        activate_and_run(up_path, """
            using UsesPreferences, Test, Preferences
            using Base: UUID
            @test load_preference($(repr(up_uuid)), "username") === nothing
            @test !UsesPreferences.has_username()
            @test UsesPreferences.get_username() === nothing
            UsesPreferences.set_username("giordano")
            @test UsesPreferences.get_username() == "giordano"
        """)

        # This does not cause a recompilation, and we can also get the username back again:
        username_test = """
        using UsesPreferences, Test, Preferences
        @test UsesPreferences.get_username() == "giordano"
        """
        output = activate_and_run(up_path, username_test; env=Dict("JULIA_DEBUG" => "loading"))
        @test !did_precompile(output)

        _prefs_delete_username = "delete_preferences!($(repr(up_uuid)), \"username\"; block_inheritance = false)"
        _delete_username = "UsesPreferences.delete_username()"
        _has_username = "@test UsesPreferences.has_username()"
        _doesnt_have_username = "!@test UsesPreferences.has_username()"
        _set_username = "UsesPreferences.set_username(\"giordano\")"
        _get_username = "@test UsesPreferences.get_username() == \"giordano\""
        _doesnt_have_set_get_username = """
        $(_doesnt_have_username)
        $(_set_username)
        $(_get_username)
        """
        snippets = [
            _prefs_delete_username,
            _doesnt_have_set_get_username,
            _has_username,
            _delete_username,
            _doesnt_have_set_get_username,
            _has_username,
            _prefs_delete_username,
            _doesnt_have_set_get_username,
            _has_username,
            _prefs_delete_username,
            _doesnt_have_set_get_username,
            _has_username,
        ]
        for snippet in snippets
            code = """
            using UsesPreferences, Test, Preferences
            using Base: UUID

            $(snippet)
            """
            output = activate_and_run(up_path, username_test; env=Dict("JULIA_DEBUG" => "loading"))
            @test !did_precompile(output)
        end
    end
end

@testset "Loading UUID from Project.toml" begin
    local_prefs_toml = joinpath(up_path, "LocalPreferences.toml")
    rm(local_prefs_toml; force=true)

    function test_uuid_loading_from_name(switch)
        with_temp_depot() do; mktempdir() do dir
            activate(dir) do
                push!(Base.LOAD_PATH, dir)
                try
                    # Can't do this unless `UsesPreferences` is added as a dep
                    @test_throws ArgumentError set_preferences!("UsesPreferences", "location" => "exists")
                    @test_throws ArgumentError has_preference("UsesPreferences", "location")
                    @test_throws ArgumentError load_preference("UsesPreferences", "location")
                    @test_throws ArgumentError delete_preferences!("UsesPreferences", "location")

                    switch()

                    # After switching `up_path`, it works.
                    set_preferences!("UsesPreferences", "location" => "exists")
                    @test has_preference("UsesPreferences", "location")
                    @test load_preference("UsesPreferences", "location") == "exists"
                    delete_preferences!("UsesPreferences", "location"; force=true)
                    @test !has_preference("UsesPreferences", "location")
                finally
                    pop!(Base.LOAD_PATH)
                    rm(local_prefs_toml; force=true)
                end
            end
        end; end
    end

    test_uuid_loading_from_name() do
        Pkg.develop(; path=up_path) # load UUID with dependency's name
    end
    test_uuid_loading_from_name() do
        Pkg.activate(up_path)       # load UUID with the active project name
    end
end

# Load UsesPreferences, as we need it loaded to satisfy `set_preferences!()` below,
# otherwise it can't properly map from a UUID to a name when installing into a package
# that doesn't have UsesPreferences added yet.
activate(up_path) do
    eval(:(using UsesPreferences))
end
@testset "Inheritance" begin
    # Ensure there is no LocalPreferences.toml file in UsesPreferences:
    local_prefs_toml = joinpath(up_path, "LocalPreferences.toml")
    rm(local_prefs_toml; force=true)
    with_temp_depot() do; mktempdir() do env_dir
        try
            # We're going to create a higher environment
            push!(Base.LOAD_PATH, env_dir)

            # We're going to add `UsesPreferences` to this environment
            open(joinpath(env_dir, "Project.toml"), "w") do io
                TOML.print(io, Dict(
                    "deps" => Dict(
                        "UsesPreferences" => string(up_uuid),
                    )
                ))
            end

            # We're going to write out some Preferences for UP in the higher environment
            activate(env_dir) do
                set_preferences!(up_uuid, "location" => "outer_public"; export_prefs=true)
                # Verify that this is stored in the environment's Project.toml file
                proj = Base.parsed_toml(joinpath(env_dir, "Project.toml"))
                @test haskey(proj, "preferences")
                @test haskey(proj["preferences"], "UsesPreferences")
                @test proj["preferences"]["UsesPreferences"]["location"] == "outer_public"
                @test load_preference(up_uuid, "location") == "outer_public"

                # Add preferences to the outer env's `LocalPreferences.toml`
                set_preferences!(up_uuid, "location" => "outer_local")
                prefs = Base.parsed_toml(joinpath(env_dir, "LocalPreferences.toml"))
                @test haskey(prefs, "UsesPreferences")
                @test prefs["UsesPreferences"]["location"] == "outer_local"
                @test load_preference(up_uuid, "location") == "outer_local"
            end

            # Ensure that we can load the preferences even if we exit the `activate()`
            # because `env_dir` is a part of `LOAD_PATH`.
            @test load_preference(up_uuid, "location") == "outer_local"

            # Next, we're going to create a lower environment, add some preferences there, and ensure
            # the inheritance works properly.
            activate(up_path) do
                # Ensure that activating this other path doesn't change anything
                @test load_preference(up_uuid, "location") == "outer_local"

                # Set a local preference in this location, which should be the first location on the load path
                set_preferences!(up_uuid, "location" => "inner_local")
                prefs = Base.parsed_toml(joinpath(up_path, "LocalPreferences.toml"))
                @test haskey(prefs, "UsesPreferences")
                @test prefs["UsesPreferences"]["location"] == "inner_local"
                @test load_preference(up_uuid, "location") == "inner_local"
            end

            # Let's add some complex objects, test that recursive merging works, and that
            # the special meaning of `nothing` and `missing` works
            activate(env_dir) do
                set_preferences!(up_uuid, "nested" => Dict(
                    "nested2" => Dict("a" => 1, "b" => 2),
                    "leaf" => "hello",
                ); export_prefs=true)
                set_preferences!(up_uuid, "nested" => Dict(
                    "nested2" => Dict("b" => 3)),
                )

                nested = load_preference(up_uuid, "nested")
                @test isa(nested, Dict) && haskey(nested, "nested2")
                @test nested["nested2"]["a"] == 1
                @test nested["nested2"]["b"] == 3
                @test nested["leaf"] == "hello"
            end

            # Add another layer in the inner environment
            activate(up_path) do
                set_preferences!(up_uuid, "nested" => Dict(
                    "nested2" => Dict("a" => "foo"),
                    "leaf" => "world",
                ))
                nested = load_preference(up_uuid, "nested")
                @test isa(nested, Dict) && haskey(nested, "nested2")
                @test nested["nested2"]["a"] == "foo"
                @test nested["nested2"]["b"] == 3
                @test nested["leaf"] == "world"
            end

            # Set the local setting of the upper environment to `missing`; this causes it to
            # pass through and `b` will suddenly equal `2`:
            activate(env_dir) do
                # Test that trying to over-set a preference in another package fails unless we force it
                @test_throws ArgumentError set_preferences!(up_uuid, "nested" => nothing)
                set_preferences!(up_uuid, "nested" => Dict(
                    "nested2" => missing,
                    "leaf" => nothing,
                ); force=true)
                nested = load_preference(up_uuid, "nested")
                @test isa(nested, Dict) && haskey(nested, "nested2")
                @test nested["nested2"]["a"] == 1
                @test nested["nested2"]["b"] == 2

                # Let's check that the `__clear__` keys are what we expect:
                prefs = Base.parsed_toml(joinpath(env_dir, "LocalPreferences.toml"))
                @test prefs["UsesPreferences"]["nested"]["__clear__"] == ["leaf"]
                @test !haskey(prefs["UsesPreferences"]["nested"], "leaf")
                @test !haskey(nested, "leaf")
            end

            # Show that it cascades down to the lower levels as well
            activate(up_path) do
                nested = load_preference(up_uuid, "nested")
                @test isa(nested, Dict) && haskey(nested, "nested2")
                @test nested["nested2"]["a"] == "foo"
                @test nested["nested2"]["b"] == 2
                @test nested["leaf"] == "world"
            end

            # Test that setting a preference for UsesPreferences in a project that does
            # not contain UsesPreferences adds the dependency if `active_project_only`
            # is set, which is the default:
            mktempdir() do empty_project_dir
                touch(joinpath(empty_project_dir, "Project.toml"))
                activate(empty_project_dir) do
                    # This will search up the environment stack for a project that contains
                    # the UsesPreferences UUID and insert the preference there.
                    set_preferences!(up_uuid, "location" => "overridden_outer_local"; active_project_only=false, force=true)
                    prefs = Base.parsed_toml(joinpath(env_dir, "LocalPreferences.toml"))
                    @test prefs["UsesPreferences"]["location"] == "overridden_outer_local"

                    # This will set it in the currently active project, and add `UsesPreferences`
                    # as a dependency under the `"extras"` section
                    set_preferences!(up_uuid, "location" => "empty_inner_local"; active_project_only=true)
                    prefs = Base.parsed_toml(joinpath(empty_project_dir, "LocalPreferences.toml"))
                    @test prefs["UsesPreferences"]["location"] == "empty_inner_local"
                    proj = Base.parsed_toml(joinpath(empty_project_dir, "Project.toml"))
                    @test haskey(proj, "extras")
                    @test haskey(proj["extras"], "UsesPreferences")
                    @test proj["extras"]["UsesPreferences"] == string(up_uuid)

                    # Now that UsesPreferences has been added to the empty project, this will
                    # set the preference in the local project since it is found in there first.
                    set_preferences!(up_uuid, "location" => "still_empty_inner_local"; active_project_only=false, force=true)
                    prefs = Base.parsed_toml(joinpath(empty_project_dir, "LocalPreferences.toml"))
                    @test prefs["UsesPreferences"]["location"] == "still_empty_inner_local"
                end
            end
        finally
            # Remove the `env_dir` we added
            pop!(Base.LOAD_PATH)
        end
    end; end
end

@testset "Issue #34" begin
    with_temp_depot() do; mktempdir() do dir
        activate(dir) do
            push!(Base.LOAD_PATH, dir)
            try
                Preferences.set_preferences!(up_uuid, "location" => "exists")
                proj = Base.parsed_toml(joinpath(dir, "Project.toml"))
                @test haskey(proj, "extras")
                @test haskey(proj["extras"], "UsesPreferences")
                @test proj["extras"]["UsesPreferences"] == string(up_uuid)
            finally
                pop!(Base.LOAD_PATH)
            end
        end
    end; end
end

@testset "Pkg.test()" begin
    # Let's test that using `Pkg.test()` on a fake little package works as expected
    # This package will both expect to read a preference that was defined in the
    # package's Project.toml and in a LocalPreferneces.toml, as well as attempt to
    # set and load preferences during the test.  We'll even "export" preferences
    # during the test and assert that the Project.toml file remains unchanged.
    project_hash = open(io -> SHA.sha256(io), joinpath(@__DIR__, "PTest", "Project.toml"))
    Pkg.activate(joinpath(@__DIR__, "PTest")) do
        Pkg.test(; io=devnull)
    end
    @test project_hash == open(io -> SHA.sha256(io), joinpath(@__DIR__, "PTest", "Project.toml"))
end

const PkgA_DIR = normpath(@__DIR__, "PkgA")
const PkgB_DIR = normpath(@__DIR__, "PkgB")
function test_with_PkgAB(test_func)
    old = Pkg.project().path
    mktempdir() do tempdir
        try
            pkgdir = normpath(tempdir, "NonPkgConfig")
            Pkg.generate(pkgdir; io=devnull)
            Pkg.activate(pkgdir; io=devnull)
            Pkg.develop(; path=PkgA_DIR, io=devnull)
            Pkg.develop(; path=PkgB_DIR, io=devnull)

            local_prefs_toml = normpath(pkgdir, "LocalPreferences.toml")
            open(local_prefs_toml, "w") do io
                write(io, """
                [PkgA]
                PkgAConfig = true
                PkgARuntimeConfig = 1

                [PkgB]
                PkgBConfig = true
                PkgBRuntimeConfig = 2
                """)
            end

            @eval $test_func()
        finally
            Pkg.activate(old; io=devnull)
        end
    end
end

@testset "Configuration override for non-package module" begin
    test_with_PkgAB() do
        # test the support of configuration override for non-package module
        try
            Preferences.main_uuid[] = Pkg.project().dependencies["PkgA"]
            PkgA = include(normpath(PkgA_DIR, "src", "PkgA.jl"))
            @test PkgA.PkgAConfig
            @test 1 == Base.invokelatest(PkgA.PkgARuntimeConfig_macro)
            @test 1 == Base.invokelatest(PkgA.PkgARuntimeConfig_func)
        finally
            Preferences.main_uuid[] = nothing
        end

        try
            Preferences.main_uuid[] = Pkg.project().dependencies["PkgB"]
            PkgB = include(normpath(PkgB_DIR, "src", "PkgB.jl"))
            @test PkgB.PkgBConfig
            @test 2 == Base.invokelatest(PkgB.PkgBRuntimeConfig_macro)
            @test 2 == Base.invokelatest(PkgB.PkgBRuntimeConfig_func)

            # the overridden configuration should persist across the same session
            @test 1 == Base.invokelatest(PkgA.PkgARuntimeConfig_macro)
            @test 1 == Base.invokelatest(PkgA.PkgARuntimeConfig_func)
        finally
            Preferences.main_uuid[] = nothing
        end
    end
end
