module test_config

using Test
using HierarchicalTestSets
using JETLSCore: JETLSCore

@testset HierarchicalTestSet "Configuration utilities" begin
    @testset "`get_default_config`" begin
        @test JETLSCore.get_default_config(:testrunner, :env) == Dict{String,String}()
        @test JETLSCore.get_default_config(:testrunner, :julia_args) == String[]
        @test JETLSCore.get_default_config(:formatter) == "Runic"
        @test_throws FieldError JETLSCore.get_default_config(:nonexistent)
        @test_throws FieldError JETLSCore.get_default_config(:full_analysis, :nonexistent)
    end

    @testset "`merge_settings`" begin
        base_config = JETLSCore.JETLSConfig(;
            full_analysis=JETLSCore.FullAnalysisConfig(; debounce=1.0),
            testrunner=JETLSCore.TestRunnerConfig(; julia_args=["base_arg"]),
        )
        overlay_config = JETLSCore.JETLSConfig(;
            full_analysis=JETLSCore.FullAnalysisConfig(; debounce=2.0),
        )
        merged = JETLSCore.merge_settings(base_config, overlay_config)

        @test JETLSCore.getobjpath(merged, :full_analysis, :debounce) == 2.0
        @test JETLSCore.getobjpath(merged, :testrunner, :julia_args) == ["base_arg"]

        @testset "`merge_settings` for `Vector{<:ConfigSection}`" begin
            pattern1 = JETLSCore.DiagnosticPattern(r"error1", "code", "regex", 1, nothing, "error1")
            pattern2 = JETLSCore.DiagnosticPattern(r"error2", "code", "regex", 2, nothing, "error2")
            pattern3 = JETLSCore.DiagnosticPattern(r"error3", "code", "regex", 3, nothing, "error3")
            # Same merge key; only severity differs.
            pattern1_updated = JETLSCore.DiagnosticPattern(r"error1", "code", "regex", 4, nothing, "error1")

            let base = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern1, pattern2]))
                overlay = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern1_updated, pattern3]))
                merged = JETLSCore.merge_settings(base, overlay)
                patterns = JETLSCore.getobjpath(merged, :diagnostic, :patterns)
                @test length(patterns) == 3
                patterns_by_key = Dict(p.__pattern_value__ => p for p in patterns)
                @test patterns_by_key["error1"].severity == 4  # updated
                @test haskey(patterns_by_key, "error2")  # preserved from base
                @test haskey(patterns_by_key, "error3")  # added from overlay
            end

            let base = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=nothing))
                overlay = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern1]))
                merged = JETLSCore.merge_settings(base, overlay)
                patterns = JETLSCore.getobjpath(merged, :diagnostic, :patterns)
                @test length(patterns) == 1
                @test patterns[1] == pattern1
            end

            let base = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern1]))
                overlay = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=nothing))
                merged = JETLSCore.merge_settings(base, overlay)
                patterns = JETLSCore.getobjpath(merged, :diagnostic, :patterns)
                @test length(patterns) == 1
                @test patterns[1] == pattern1
            end

            # Overlay entries come after unmatched base entries in merged order.
            let base = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern1, pattern2]))
                overlay = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern3, pattern1_updated]))
                merged = JETLSCore.merge_settings(base, overlay)
                patterns = JETLSCore.getobjpath(merged, :diagnostic, :patterns)
                @test [p.__pattern_value__ for p in patterns] == ["error2", "error3", "error1"]
                @test patterns[end].severity == 4
            end
        end

        @testset "composite merge key for DiagnosticPattern" begin
            src_path = JETLSCore.Glob.FilenameMatch("src/**/*.jl", "")
            test_path = JETLSCore.Glob.FilenameMatch("test/**/*.jl", "")

            # Same pattern value but different paths should be treated as different entries
            pattern_src = JETLSCore.DiagnosticPattern(r".*", "code", "regex", 2, src_path, ".*")
            pattern_test = JETLSCore.DiagnosticPattern(r".*", "code", "regex", 0, test_path, ".*")

            let base = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern_src, pattern_test]))
                overlay = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=nothing))
                merged = JETLSCore.merge_settings(base, overlay)
                patterns = JETLSCore.getobjpath(merged, :diagnostic, :patterns)
                @test length(patterns) == 2
            end

            # Updating only one of them should preserve the other
            pattern_src_updated = JETLSCore.DiagnosticPattern(r".*", "code", "regex", 1, src_path, ".*")
            let base = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern_src, pattern_test]))
                overlay = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern_src_updated]))
                merged = JETLSCore.merge_settings(base, overlay)
                patterns = JETLSCore.getobjpath(merged, :diagnostic, :patterns)
                @test length(patterns) == 2
                patterns_by_path = Dict(p.path => p for p in patterns)
                @test patterns_by_path[src_path].severity == 1  # updated
                @test patterns_by_path[test_path].severity == 0  # preserved
            end
        end

        @testset "concretization pattern merge keys" begin
            src_path = JETLSCore.Glob.FilenameMatch("src/**/*.jl", "")
            test_path = JETLSCore.Glob.FilenameMatch("test/**/*.jl", "")
            pattern_src = JETLSCore.ConcretizationPattern(:(USE_PULSE = x_), src_path, "USE_PULSE = x_")
            pattern_test = JETLSCore.ConcretizationPattern(:(USE_PULSE = x_), test_path, "USE_PULSE = x_")
            pattern_src_updated = JETLSCore.ConcretizationPattern(:(USE_PULSE = y_), src_path, "USE_PULSE = x_")

            let base = JETLSCore.JETLSConfig(;
                    full_analysis=JETLSCore.FullAnalysisConfig(;
                        concretization_patterns=[pattern_src, pattern_test]))
                overlay = JETLSCore.JETLSConfig(;
                    full_analysis=JETLSCore.FullAnalysisConfig(;
                        concretization_patterns=[pattern_src_updated]))
                merged = JETLSCore.merge_settings(base, overlay)
                patterns = JETLSCore.getobjpath(merged, :full_analysis, :concretization_patterns)
                @test length(patterns) == 2
                patterns_by_path = Dict(p.path => p for p in patterns)
                @test patterns_by_path[src_path].pattern == :(USE_PULSE = y_)
                @test patterns_by_path[test_path].pattern == :(USE_PULSE = x_)
            end
        end
    end

    @testset "`track_setting_changes`" begin
        let config1 = JETLSCore.JETLSConfig(;
                full_analysis=JETLSCore.FullAnalysisConfig(; debounce=1.0),
                testrunner=JETLSCore.TestRunnerConfig(; julia_args=["arg1"]),
            )
            config2 = JETLSCore.JETLSConfig(;
                full_analysis=JETLSCore.FullAnalysisConfig(; debounce=2.0),
                testrunner=JETLSCore.TestRunnerConfig(; julia_args=["arg2"])
            )
            paths_called = []
            JETLSCore.track_setting_changes(config1, config2) do _, _, path
                push!(paths_called, path)
            end
            @test Set(paths_called) == Set([
                (:full_analysis, :debounce),
                (:testrunner, :julia_args),
            ])
        end

        @testset "concretization pattern updates record the changed globs" begin
            glob = JETLSCore.Glob.FilenameMatch("src/*.jl", "dp")
            pattern1 = JETLSCore.ConcretizationPattern(:(USE_PULSE = x_), nothing, "USE_PULSE = x_")
            pattern2 = JETLSCore.ConcretizationPattern(:(USE_PULSE = y_), glob, "USE_PULSE = y_")
            pattern3 = JETLSCore.ConcretizationPattern(:(USE_TICK = x_), glob, "USE_TICK = x_")
            config(patterns...) = JETLSCore.JETLSConfig(; full_analysis=JETLSCore.FullAnalysisConfig(;
                concretization_patterns=JETLSCore.ConcretizationPattern[patterns...]))
            let tracker = JETLSCore.ConfigChangeTracker()
                JETLSCore.track_setting_changes(tracker, config(pattern1, pattern3), config(pattern2, pattern3))
                @test issetequal(tracker.changed_concretization_globs, [nothing, glob])
                @test !tracker.concretization_timeout_changed
            end
            let tracker = JETLSCore.ConfigChangeTracker()
                JETLSCore.track_setting_changes(tracker, config(pattern1, pattern2), config(pattern2, pattern1))
                @test isempty(tracker.changed_concretization_globs)
            end
        end

        # Test that updating severity of an existing pattern is tracked
        let pattern1 = JETLSCore.DiagnosticPattern(r"error1", "code", "regex", 1, nothing, "error1")
            pattern1_updated = JETLSCore.DiagnosticPattern(r"error1", "code", "regex", 4, nothing, "error1")
            pattern2 = JETLSCore.DiagnosticPattern(r"error2", "code", "regex", 2, nothing, "error2")
            config1 = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern1]))
            config2 = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern1_updated, pattern2]))
            changes = []
            JETLSCore.track_setting_changes(config1, config2) do old_val, new_val, path
                push!(changes, (old_val, new_val, path))
            end
            @test any(changes) do (old_val, new_val, path)
                path == (:diagnostic, :patterns, :severity) &&
                old_val == 1 && new_val == 4
            end
        end

        # Reordering patterns should invalidate diagnostics caches.
        let pattern1 = JETLSCore.DiagnosticPattern(r"error1", "code", "regex", 1, nothing, "error1")
            pattern2 = JETLSCore.DiagnosticPattern(r"error2", "code", "regex", 2, nothing, "error2")
            config1 = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern1, pattern2]))
            config2 = JETLSCore.JETLSConfig(; diagnostic=JETLSCore.DiagnosticConfig(; patterns=[pattern2, pattern1]))
            changes = []
            JETLSCore.track_setting_changes(config1, config2) do old_val, new_val, path
                push!(changes, (old_val, new_val, path))
            end
            @test any(changes) do (_, _, path)
                path == (:diagnostic, :patterns)
            end
        end
    end

    @testset "`is_config_document_uri`" begin
        mktempdir() do dir
            state = JETLSCore.Server().state
            state.root_path = dir
            @test JETLSCore.is_config_document_uri(state, JETLSCore.filepath2uri(joinpath(dir, JETLSCore.CONFIG_FILE)))
            @test JETLSCore.is_config_document_uri(state, JETLSCore.filepath2uri(joinpath(dir, "nested", "..", JETLSCore.CONFIG_FILE)))
            @test !JETLSCore.is_config_document_uri(state, JETLSCore.filepath2uri(joinpath(dir, "nested", JETLSCore.CONFIG_FILE)))
            @test !JETLSCore.is_config_document_uri(state, JETLSCore.filepath2uri(joinpath(dir, "config.toml")))
        end
    end
end

@testset "`parse_config_from_dict` reports full key paths in `InvalidKeyError`" begin
    let err = try
            JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, Dict{String,Any}("___unknown___" => 1))
            nothing
        catch e; e; end
        @test err isa JETLSCore.InvalidKeyError
        @test err.path == ["___unknown___"]
    end
    let err = try
            JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, Dict{String,Any}(
                "diagnostic" => Dict{String,Any}("___unknown___" => 1)))
            nothing
        catch e; e; end
        @test err isa JETLSCore.InvalidKeyError
        @test err.path == ["diagnostic", "___unknown___"]
    end
end

@testset "`validate_config_data` enforces concrete untyped data" begin
    let config_data = Dict{Symbol,Any}(:diagnostic => Dict{String,Any}())
        err = try
            JETLSCore.validate_config_data(config_data)
            nothing
        catch e; e; end
        @test err isa JETLSCore.InvalidConfigDataError
        message = sprint(showerror, err)
        @test occursin("expected `Dict{String,Any}`", message)
        @test occursin("got `Dict{Symbol, Any}`", message)
    end

    let config_data = Dict{String,Any}("diagnostic" => Dict("enabled" => true))
        err = try
            JETLSCore.validate_config_data(config_data)
            nothing
        catch e; e; end
        @test err isa JETLSCore.InvalidConfigDataError
        message = sprint(showerror, err)
        @test occursin("at `diagnostic`", message)
        @test occursin("expected `Dict{String,Any}`", message)
        @test occursin("got `Dict{String, Bool}`", message)
    end

    let config_data = Dict{String,Any}(
            "full_analysis" => Dict{String,Any}(
                "concretization_patterns" => Any[
                    Dict("pattern" => "USE_PULSE = x_")]))
        err = try
            JETLSCore.validate_config_data(config_data)
            nothing
        catch e; e; end
        @test err isa JETLSCore.InvalidConfigDataError
        message = sprint(showerror, err)
        @test occursin("at `full_analysis.concretization_patterns[1]`", message)
        @test occursin("expected `Dict{String,Any}`", message)
    end

    let value = SubString("value", 1, 5),
        config_data = Dict{String,Any}(
            "testrunner" => Dict{String,Any}(
                "env" => Dict{String,Any}("NAME" => value)))
        err = try
            JETLSCore.validate_config_data(config_data)
            nothing
        catch e; e; end
        @test err isa JETLSCore.InvalidConfigDataError
        message = sprint(showerror, err)
        @test occursin("at `testrunner.env.NAME`", message)
        @test occursin("expected `String`", message)
        @test occursin("got `SubString{String}`", message)
    end

    let patterns = @view(Any[Dict{String,Any}()][1:1]),
        config_data = Dict{String,Any}(
            "diagnostic" => Dict{String,Any}("patterns" => patterns))
        err = try
            JETLSCore.validate_config_data(config_data)
            nothing
        catch e; e; end
        @test err isa JETLSCore.InvalidConfigDataError
        message = sprint(showerror, err)
        @test occursin("at `diagnostic.patterns`", message)
        @test occursin("expected `Vector`", message)
    end

    let config_data = Dict{String,Any}(
            "formatter" => "Runic",
            "full_analysis" => Dict{String,Any}(
                "concretization_patterns" => String["A = x_"]))
        @test JETLSCore.validate_config_data(config_data) === config_data
    end
    let config_data = Dict{String,Any}(
            "formatter" => "Runic",
            "full_analysis" => Dict{String,Any}(
                "concretization_patterns" => Any["A = x_"]))
        @test JETLSCore.validate_config_data(config_data) === config_data
    end
end

@testset "`parse_dict_value` error messages include the dotted path" begin
    # Wrong leaf type at top level (single-segment path).
    let err = try
            JETLSCore.parse_config_from_dict(JETLSCore.DiagnosticConfig, Dict{String,Any}("enabled" => "yes"))
            nothing
        catch e; e; end
        @test err isa ErrorException
        @test occursin("Invalid value at `enabled`", err.msg)
        @test occursin("expected Bool", err.msg)
        @test occursin("got String", err.msg)
    end

    # Wrong leaf type at a nested location (multi-segment path).
    let err = try
            JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, Dict{String,Any}(
                "diagnostic" => Dict{String,Any}("allow_unused_underscore" => "yes")))
            nothing
        catch e; e; end
        @test err isa ErrorException
        @test occursin("Invalid value at `diagnostic.allow_unused_underscore`", err.msg)
        @test occursin("expected Bool", err.msg)
        @test occursin("got String", err.msg)
    end

    # `ConfigSection` field that should be a table.
    let err = try
            JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, Dict{String,Any}("diagnostic" => "nope"))
            nothing
        catch e; e; end
        @test err isa ErrorException
        @test occursin("Invalid value at `diagnostic`", err.msg)
        @test occursin("expected a table for", err.msg)
    end

    # Vector field that should be an array.
    let err = try
            JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, Dict{String,Any}(
                "diagnostic" => Dict{String,Any}("patterns" => "not an array")))
            nothing
        catch e; e; end
        @test err isa ErrorException
        @test occursin("Invalid value at `diagnostic.patterns`", err.msg)
        @test occursin("expected a vector", err.msg)
    end

    # Formatter field expects a string or `{custom = ...}` table.
    let err = try
            JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, Dict{String,Any}("formatter" => 123))
            nothing
        catch e; e; end
        @test err isa ErrorException
        @test occursin("Invalid value at `formatter`", err.msg)
        @test occursin("expected formatter string or table", err.msg)
    end

    # Formatter table missing the `custom` key.
    let err = try
            JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, Dict{String,Any}(
                "formatter" => Dict{String,Any}("not_custom" => Dict{String,Any}())))
            nothing
        catch e; e; end
        @test err isa ErrorException
        @test occursin("Invalid value at `formatter`", err.msg)
        @test occursin("expected formatter table key `custom`", err.msg)
    end
end

@testset HierarchicalTestSet "`parse_config_from_dict` concretization patterns" begin
    @testset "patterns with and without `path`" begin
        raw_config = Dict{String,Any}(
            "full_analysis" => Dict{String,Any}(
                "concretization_patterns" => Any[
                    Dict{String,Any}("pattern" => "USE_PULSE = x_"),
                    Dict{String,Any}(
                        "pattern" => "SIMULATE = x_",
                        "path" => "examples/**/*.jl")]))
        config = JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, raw_config)
        patterns = config.full_analysis.concretization_patterns
        @test length(patterns) == 2
        @test patterns[1].pattern == :(USE_PULSE = x_)
        @test patterns[1].path === nothing
        @test patterns[2].pattern == :(SIMULATE = x_)
        @test occursin(patterns[2].path, "examples/foo.jl")
    end

    @testset "non-table entry is rejected" begin
        raw_config = Dict{String,Any}(
            "full_analysis" => Dict{String,Any}(
                "concretization_patterns" => Any["USE_PULSE = x_"]))
        err = try
            JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, raw_config)
            nothing
        catch e; e; end
        @test err isa ErrorException
        @test occursin("expected a table for", err.msg)
    end

    @testset "incomplete pattern expression is rejected" begin
        raw_config = Dict{String,Any}(
            "full_analysis" => Dict{String,Any}(
                "concretization_patterns" => Any[Dict{String,Any}(
                    "pattern" => "USE_PULSE =",
                    "path" => "examples/**/*.jl")]))
        err = try
            JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, raw_config)
            nothing
        catch e; e; end
        @test err isa ErrorException
        @test occursin("full_analysis.concretization_patterns.pattern", err.msg)
    end

    @testset "empty or comment-only patterns are rejected" begin
        for pattern in ("", "  \t\n", "# comment only")
            raw_config = Dict{String,Any}(
                "full_analysis" => Dict{String,Any}(
                    "concretization_patterns" => Any[Dict{String,Any}(
                        "pattern" => pattern)]))
            err = try
                JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, raw_config)
                nothing
            catch e; e; end
            @test err isa ErrorException
            @test occursin("full_analysis.concretization_patterns.pattern", err.msg)
            @test occursin("expected a Julia expression pattern", err.msg)
        end
    end
end

@testset "`parse_config_from_dict` analysis overrides" begin
    parse_override(entry) = only(JETLSCore.parse_config_from_dict(JETLSCore.InitOptions,
        Dict{String,Any}("analysis_overrides" => Any[entry])).analysis_overrides)
    let override = parse_override(Dict{String,Any}("path" => "test/fixtures/**"))
        @test override.on_include == "stop"
        @test !override.full_analysis
    end
    let override = parse_override(Dict{String,Any}("path" => "test/upstream.jl", "on_include" => "skip"))
        @test override.on_include == "skip"
    end
    for on_include in ("continue", true)
        err = try
            parse_override(Dict{String,Any}("path" => "test/upstream.jl", "on_include" => on_include))
            nothing
        catch e; e; end
        @test err isa ErrorException
        @test occursin("on_include", err.msg)
    end
end

function store_file_config!(manager::JETLSCore.ConfigManager, filepath::AbstractString, new_config::JETLSCore.JETLSConfig)
    JETLSCore.store!(manager) do old_data
        new_data = JETLSCore.ConfigManagerData(old_data;
            file_config=new_config,
            file_config_path=filepath
        )
        return new_data, nothing
    end
end

function store_lsp_config!(manager::JETLSCore.ConfigManager, new_config::JETLSCore.JETLSConfig)
    JETLSCore.store!(manager) do old_data
        new_data = JETLSCore.ConfigManagerData(old_data; lsp_config=new_config)
        return new_data, nothing
    end
end

@testset "ConfigManager" begin
    manager = JETLSCore.ConfigManager(JETLSCore.ConfigManagerData())

    test_config = JETLSCore.JETLSConfig(;
        full_analysis=JETLSCore.FullAnalysisConfig(; debounce=2.0),
        testrunner=JETLSCore.TestRunnerConfig(; julia_args=["test_arg"]),
    )

    store_file_config!(manager, "/foo/bar/.JETLSConfig.toml", test_config)

    @test JETLSCore.get_config(manager, :full_analysis, :debounce) === 2.0
    @test JETLSCore.get_config(manager, :testrunner, :julia_args) == ["test_arg"]
    @test_throws FieldError JETLSCore.get_config(manager, :nonexistent)

    # Type stability check (N.B: Nothing is not allowed)
    @test Base.infer_return_type((typeof(manager),)) do manager
           JETLSCore.get_config(manager, :full_analysis, :debounce)
    end == Float64
    @test Base.infer_return_type((typeof(manager),)) do manager
           JETLSCore.get_config(manager, :formatter)
    end == JETLSCore.FormatterConfig

    # Test priority: file config has higher priority than LSP config
    lsp_config = JETLSCore.JETLSConfig(;
        full_analysis=JETLSCore.FullAnalysisConfig(; debounce=999.0),
        testrunner=JETLSCore.TestRunnerConfig(; julia_args=["lsp_arg"])
    )
    store_lsp_config!(manager, lsp_config)
    # High priority file config should win
    @test JETLSCore.get_config(manager, :full_analysis, :debounce) === 2.0
    @test JETLSCore.get_config(manager, :testrunner, :julia_args) == ["test_arg"]

    # Test updating config
    store_lsp_config!(manager, JETLSCore.EMPTY_CONFIG)
    updated_config = JETLSCore.JETLSConfig(;
        full_analysis=JETLSCore.FullAnalysisConfig(; debounce=3.0),
        testrunner=JETLSCore.TestRunnerConfig(; julia_args=["new_arg"]),
    )
    store_file_config!(manager, "/foo/bar/.JETLSConfig.toml", updated_config)
    @test JETLSCore.get_config(manager, :full_analysis, :debounce) == 3.0
    @test JETLSCore.get_config(manager, :testrunner, :julia_args) == ["new_arg"]
end

@testset "LSP configuration priority and merging" begin
    manager = JETLSCore.ConfigManager(JETLSCore.ConfigManagerData())

    lsp_config = JETLSCore.JETLSConfig(;
        full_analysis=JETLSCore.FullAnalysisConfig(; debounce=2.0),
        testrunner=nothing
    )
    file_config = JETLSCore.JETLSConfig(;
        testrunner=JETLSCore.TestRunnerConfig(; julia_args=["file_arg"]),
        full_analysis=nothing
    )

    store_lsp_config!(manager, lsp_config)
    store_file_config!(manager, "/project/.JETLSConfig.toml", file_config)

    # File config has higher priority, so it wins when both are set
    @test JETLSCore.get_config(manager, :testrunner, :julia_args) == ["file_arg"]
    # When file config doesn't set a value, LSP config is used
    @test JETLSCore.get_config(manager, :full_analysis, :debounce) == 2.0
end

@testset "LSP configuration merging without file config" begin
    manager = JETLSCore.ConfigManager(JETLSCore.ConfigManagerData())
    lsp_config = JETLSCore.JETLSConfig(;
        full_analysis=JETLSCore.FullAnalysisConfig(; debounce=3.0),
        testrunner=JETLSCore.TestRunnerConfig(; julia_args=["lsp_arg"])
    )
    store_lsp_config!(manager, lsp_config)
    @test JETLSCore.get_config(manager, :testrunner, :julia_args) == ["lsp_arg"]
    @test JETLSCore.get_config(manager, :full_analysis, :debounce) == 3.0
end

@testset "Formatter configuration" begin
    @testset "preset formatter: Runic" begin
        manager = JETLSCore.ConfigManager(JETLSCore.ConfigManagerData())
        config = JETLSCore.JETLSConfig(; formatter="Runic")
        store_file_config!(manager, "/path/.JETLSConfig.toml", config)
        @test JETLSCore.get_config(manager, :formatter) == "Runic"
    end

    @testset "preset formatter: JuliaFormatter" begin
        manager = JETLSCore.ConfigManager(JETLSCore.ConfigManagerData())
        config = JETLSCore.JETLSConfig(; formatter="JuliaFormatter")
        store_file_config!(manager, "/path/.JETLSConfig.toml", config)
        @test JETLSCore.get_config(manager, :formatter) == "JuliaFormatter"
    end

    @testset "custom formatter" begin
        manager = JETLSCore.ConfigManager(JETLSCore.ConfigManagerData())
        custom = JETLSCore.CustomFormatterConfig("my-formatter", "my-range-formatter")
        config = JETLSCore.JETLSConfig(; formatter=custom)
        store_file_config!(manager, "/path/.JETLSConfig.toml", config)
        formatter = JETLSCore.get_config(manager, :formatter)
        @test formatter isa JETLSCore.CustomFormatterConfig
        @test formatter.executable == "my-formatter"
        @test formatter.executable_range == "my-range-formatter"
    end

    @testset "custom formatter without executable_range" begin
        manager = JETLSCore.ConfigManager(JETLSCore.ConfigManagerData())
        custom = JETLSCore.CustomFormatterConfig("my-formatter", nothing)
        config = JETLSCore.JETLSConfig(; formatter=custom)
        store_file_config!(manager, "/path/.JETLSConfig.toml", config)
        formatter = JETLSCore.get_config(manager, :formatter)
        @test formatter isa JETLSCore.CustomFormatterConfig
        @test formatter.executable == "my-formatter"
        @test formatter.executable_range === nothing
    end
end

@testset "parse_config_dict accepts legacy `block_end_min_lines`" begin
    deprecations = Pair{Vector{String},Union{Nothing,Vector{String}}}[
        ["inlay_hint", "block_end_min_lines"] => ["inlay_hint", "block_end", "min_lines"]
    ]
    d = JETLSCore.validate_config_data(Dict{String,Any}(
        "inlay_hint" => Dict{String,Any}(
            "block_end_min_lines" => 7)))
    warnings = JETLSCore.migrate_deprecated_config!(d, deprecations)
    @test length(warnings) == 1
    @test occursin("`inlay_hint.block_end_min_lines` is deprecated", warnings[1])
    config = JETLSCore.parse_config_dict(d)
    @test config isa JETLSCore.JETLSConfig
    @test config.inlay_hint.block_end.min_lines == 7
end

@testset "parse_config_dict drops removed `prepend_inference_result`" begin
    deprecations = Pair{Vector{String},Union{Nothing,Vector{String}}}[
        ["completion", "method_signature", "prepend_inference_result"] => nothing
    ]
    d = JETLSCore.validate_config_data(Dict{String,Any}(
        "completion" => Dict{String,Any}(
            "method_signature" => Dict{String,Any}(
                "prepend_inference_result" => true))))
    warnings = JETLSCore.migrate_deprecated_config!(d, deprecations)
    @test length(warnings) == 1
    @test occursin("`completion.method_signature.prepend_inference_result` is deprecated", warnings[1])
    @test !haskey(d, "completion")
    config = JETLSCore.parse_config_dict(d)
    @test config isa JETLSCore.JETLSConfig
end

@testset "`testrunner.executable` is deprecated" begin
    d = JETLSCore.validate_config_data(Dict{String,Any}(
        "testrunner" => Dict{String,Any}(
            "executable" => "testrunner")))
    warnings = JETLSCore.migrate_deprecated_config!(d)
    @test length(warnings) == 1
    @test occursin("`testrunner.executable` is deprecated", warnings[1])
    @test !haskey(d, "testrunner")
    @test JETLSCore.parse_config_dict(d) isa JETLSCore.JETLSConfig
end

@testset "`testrunner.env`" begin
    parse_env(env) = JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, Dict{String,Any}(
        "testrunner" => Dict{String,Any}("env" => env)))
    let config = parse_env(Dict{String,Any}("JULIAUP_CHANNEL" => "1.12"))
        @test config.testrunner.env == Dict("JULIAUP_CHANNEL" => "1.12")
    end
    for key in JETLSCore.TESTRUNNER_RESERVED_ENV_KEYS
        @test_throws "Invalid value at `testrunner.env.$key`" parse_env(
            Dict{String,Any}(key => "/path"))
    end
    @test_throws "Invalid value at `testrunner.env.JULIA_NUM_THREADS`: expected String" parse_env(
        Dict{String,Any}("JULIA_NUM_THREADS" => 4))
    @test_throws "Invalid value at `testrunner.env`: expected a table" parse_env("1.12")
end

@testset "`did_change_configuration_registration` reflects `configuration_section`" begin
    let reg = JETLSCore.did_change_configuration_registration(JETLSCore.DEFAULT_INIT_OPTIONS)
        @test reg.registerOptions === nothing
    end
    let init_options = JETLSCore.InitOptions(; configuration_section = "jetls-client.settings")
        reg = JETLSCore.did_change_configuration_registration(init_options)
        registerOptions = reg.registerOptions
        @test registerOptions isa JETLSCore.LSP.DidChangeConfigurationRegistrationOptions
        @test registerOptions.section == "jetls-client.settings"
    end
end

@testset "`full_analysis.auto_instantiate` values" begin
    @test JETLSCore.get_default_config(:full_analysis, :auto_instantiate) ===
        (JETLSCore.JETLS_TEST_MODE ? JETLSCore.AUTO_INSTANTIATE_ALWAYS : JETLSCore.AUTO_INSTANTIATE_PROMPT)
    parse_auto_instantiate(value) = JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, Dict{String,Any}(
        "full_analysis" => Dict{String,Any}("auto_instantiate" => value)))
    for value in JETLSCore.AUTO_INSTANTIATE_VALUES
        @test parse_auto_instantiate(value).full_analysis.auto_instantiate === value
    end
    @test parse_auto_instantiate(nothing).full_analysis.auto_instantiate === nothing
    # booleans are deprecated values, which the migration replaces before parsing
    for (value, expected) in (true => JETLSCore.AUTO_INSTANTIATE_ALWAYS,
                              false => JETLSCore.AUTO_INSTANTIATE_NEVER)
        d = Dict{String,Any}("full_analysis" => Dict{String,Any}("auto_instantiate" => value))
        warnings = JETLSCore.migrate_deprecated_config!(d)
        @test only(warnings) == JETLSCore.deprecated_config_value_message(
            ["full_analysis", "auto_instantiate"], value, expected)
        @test JETLSCore.parse_config_dict(d).full_analysis.auto_instantiate === expected
    end
    let d = Dict{String,Any}("full_analysis" => Dict{String,Any}("auto_instantiate" => 1))
        @test isempty(JETLSCore.migrate_deprecated_config!(d))
    end
    for value in ("yes", 1, true)
        err = try
            parse_auto_instantiate(value)
            nothing
        catch e; e; end
        @test err isa ErrorException
        @test occursin("Invalid value at `full_analysis.auto_instantiate`", err.msg)
        @test occursin("expected one of", err.msg)
    end
    let manager = JETLSCore.ConfigManager(JETLSCore.ConfigManagerData())
        @test Base.infer_return_type((typeof(manager),)) do manager
            JETLSCore.get_config(manager, :full_analysis, :auto_instantiate)
        end == String
    end
end

@testset HierarchicalTestSet "`full_analysis.concretization_timeout`" begin
    @testset "parsed values" begin
        @test JETLSCore.FullAnalysisConfig().concretization_timeout === nothing
        @test JETLSCore.get_default_config(:full_analysis, :concretization_timeout) ===
            JETLSCore.JET.DEFAULT_CONCRETIZATION_TIMEOUT
        for (value, expected) in ((15, 15.0), (0.25, 0.25), (nothing, nothing), ("inf", Inf))
            raw_config = Dict{String,Any}(
                "full_analysis" => Dict{String,Any}("concretization_timeout" => value))
            config = JETLSCore.parse_config_dict(raw_config)
            @test config.full_analysis.concretization_timeout === expected
        end
        for (value, expected) in (("15", 15.0), ("0.25", 0.25), ("\"inf\"", Inf))
            raw_config = JETLSCore.TOML.parse("[full_analysis]\nconcretization_timeout = $value")
            config = JETLSCore.parse_config_dict(raw_config, "/project/.JETLSConfig.toml")
            @test config.full_analysis.concretization_timeout === expected
        end
    end

    @testset "invalid values report the setting path" begin
        message = "Invalid value at `full_analysis.concretization_timeout`: " *
            "expected a positive finite number of seconds or \"inf\""
        for value in (0, -1, true, false, Inf, -Inf, NaN, "15", "Inf", " inf ", Any[])
            raw_config = Dict{String,Any}(
                "full_analysis" => Dict{String,Any}("concretization_timeout" => value))
            @test_throws message JETLSCore.parse_config_from_dict(JETLSCore.JETLSConfig, raw_config)
        end
        let raw_config = JETLSCore.TOML.parse("[full_analysis]\nconcretization_timeout = inf")
            @test occursin(message,
                JETLSCore.parse_config_dict(raw_config, "/project/.JETLSConfig.toml"))
        end
    end

    @testset "file, LSP, and default precedence" begin
        let manager = JETLSCore.ConfigManager(JETLSCore.ConfigManagerData())
            @test JETLSCore.get_config(manager, :full_analysis, :concretization_timeout) === JETLSCore.JET.DEFAULT_CONCRETIZATION_TIMEOUT
            lsp_config = JETLSCore.parse_config_dict(Dict{String,Any}(
                "full_analysis" => Dict{String,Any}("concretization_timeout" => "inf")))
            store_lsp_config!(manager, lsp_config)
            @test JETLSCore.get_config(manager, :full_analysis, :concretization_timeout) === Inf

            file_config = JETLSCore.parse_config_dict(JETLSCore.TOML.parse(
                "[full_analysis]\nconcretization_timeout = 2.5"))
            store_file_config!(manager, "/project/.JETLSConfig.toml", file_config)
            @test JETLSCore.get_config(manager, :full_analysis, :concretization_timeout) === 2.5

            unset_config = JETLSCore.parse_config_dict(JETLSCore.TOML.parse("[full_analysis]"))
            @test unset_config.full_analysis.concretization_timeout === nothing
            store_file_config!(manager, "/project/.JETLSConfig.toml", unset_config)
            @test JETLSCore.get_config(manager, :full_analysis, :concretization_timeout) === Inf
            store_lsp_config!(manager, JETLSCore.EMPTY_CONFIG)
            @test JETLSCore.get_config(manager, :full_analysis, :concretization_timeout) === JETLSCore.JET.DEFAULT_CONCRETIZATION_TIMEOUT
        end
    end

    @testset "changes and removal mark reanalysis" begin
        for (old_value, new_value) in ((1.0, 2.5), (2.5, Inf), (Inf, nothing), (2.5, 2.5))
            old_config = JETLSCore.JETLSConfig(; full_analysis=JETLSCore.FullAnalysisConfig(;
                concretization_timeout=old_value))
            new_config = JETLSCore.JETLSConfig(; full_analysis=JETLSCore.FullAnalysisConfig(;
                concretization_timeout=new_value))
            tracker = JETLSCore.ConfigChangeTracker()
            JETLSCore.track_setting_changes(tracker, old_config, new_config)
            @test tracker.concretization_timeout_changed == (old_value !== new_value)
        end
    end
end

end # test_config
