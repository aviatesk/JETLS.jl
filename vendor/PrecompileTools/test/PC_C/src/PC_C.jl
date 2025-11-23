module PC_C

using PrecompileTools

# mimic `RecipesBase` code - see github.com/JuliaPlots/Plots.jl/issues/4597 and #317
module RB
    export @recipe

    apply_recipe(args...) = nothing
    macro recipe(ex::Expr)
        _, func_body = ex.args
        func = Expr(:call, :($RB.apply_recipe))
        Expr(
            :function,
            func,
            quote
                @nospecialize
                func_return = $func_body
            end |> esc
        )
    end
end
using .RB

@setup_workload begin
    struct Foo end
    @compile_workload begin
        @recipe f(::Foo) = nothing
    end
end

end # module PC_C
