module PTest

using Test, Preferences

function do_test()
    @set_preferences!("dynamic" => "Local preference set just now")
    @test @load_preference("dynamic", default = nothing) == "Local preference set just now"

    set_preferences!(@__MODULE__, "dynamic_exported" => "Local preference just exported"; export_prefs = true)
    @test @load_preference("dynamic_exported", default = nothing) == "Local preference just exported"

    @test @load_preference("set_by_runtests", default = nothing) == "This was set by runtests.jl"

    @test load_preference("TOML", "set_by_runtests", nothing) == "This was set by runtests.jl"
   
    # Pkg handling preferences correctly only came into being in v1.8.0:
    # X-ref: https://github.com/JuliaLang/Pkg.jl/commit/e7f1659abd7ae93ce2fbaab491873624cd24eb01
    # X-ref: https://github.com/JuliaLang/julia/pull/44140
    if VERSION >= v"1.8.0-"
        @test @load_preference("pkg_copied_exported", default = nothing) == "Exported preference copied over by Pkg.jl"
        @test @load_preference("pkg_copied", default = nothing) == "Local preference copied over by Pkg.jl"
    end
end

end # module PTest
