module PC_E

f(::Int) = 1
f(::String) = 2
f(::Dict) = 3
f(::Real) = 4
f(::Any) = 5

g(list) = [f(x) for x in list]

using PrecompileTools

@setup_workload begin
    list = Any[1, "hi"]
    @compile_workload begin
        for item in list
            f(item)
        end
    end
end

end # module PC_E
