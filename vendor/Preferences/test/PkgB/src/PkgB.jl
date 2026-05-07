module PkgB

using Preferences

const PkgBConfig = @load_preference("PkgBConfig", false)

function PkgBRuntimeConfig_macro()
    @load_preference("PkgBRuntimeConfig", 0)
end

function PkgBRuntimeConfig_func()
    load_preference(@__MODULE__, "PkgBRuntimeConfig", 0)
end

end # module PkgA
