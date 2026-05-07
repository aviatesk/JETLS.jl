module PC_A

using PrecompileTools: @setup_workload, @compile_workload

struct MyType
    x::Int
end

inferencebarrier(@nospecialize(arg)) = Base.inferencebarrier(arg)

function call_findfirst(x, list)
    # call a method defined in Base by runtime dispatch
    return findfirst(==(inferencebarrier(x)), inferencebarrier(list))
end

@setup_workload begin
    list = [MyType(1), MyType(2), MyType(3)]
    @compile_workload begin
        call_findfirst(MyType(2), list)
    end
end

end # module PC_A
