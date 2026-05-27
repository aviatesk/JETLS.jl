module PrecompileTools

using Preferences

export @setup_workload, @compile_workload, @recompile_invalidations

const verbose = Ref(false)    # if true, prints all the precompiles
const enabled = @load_preference("precompile_workloads", true)::Bool

function precompile_mi(mi::Core.MethodInstance)
    precompile(mi)
    verbose[] && println(mi)
    return
end

include("workloads.jl")
include("invalidations.jl")

end
