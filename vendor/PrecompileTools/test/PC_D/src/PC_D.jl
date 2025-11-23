module PC_D

using PrecompileTools
using PrecompileTools.Preferences

@setup_workload begin
    @compile_workload begin
        global workload_ran = true
    end
end

end # module PC_D
