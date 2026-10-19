module Preferences

# Before Julia 1.6 the package installs and loads but provides nothing, so that
# packages depending on it can still support older Julia versions.
if VERSION >= v"1.6.0-DEV"
    include("impl.jl")
end

end # module Preferences
