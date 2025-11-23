module PkgA

using Preferences

const PkgAConfig = @load_preference("PkgAConfig", false)

function PkgARuntimeConfig_macro()
    @load_preference("PkgARuntimeConfig", 0)
end

function PkgARuntimeConfig_func()
    load_preference(@__MODULE__, "PkgARuntimeConfig", 0)
end

end # module PkgA
