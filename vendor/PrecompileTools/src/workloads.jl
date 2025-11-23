const newly_inferred = Core.CodeInstance[]   # only used to support verbose[]

function workload_enabled(mod::Module)
    try
        if load_preference(@__MODULE__, "precompile_workloads", true)
            return load_preference(mod, "precompile_workload", true)
        else
            return false
        end
    catch
        true
    end
end

@noinline is_generating_output() = ccall(:jl_generating_output, Cint, ()) == 1

macro latestworld_if_toplevel()
    Expr(Symbol("latestworld-if-toplevel"))
end

function tag_newly_inferred_enable()
    ccall(:jl_tag_newly_inferred_enable, Cvoid, ())
    if !Base.generating_output()   # for verbose[]
        ccall(:jl_set_newly_inferred, Cvoid, (Any,), newly_inferred)
    end
end
function tag_newly_inferred_disable()
    ccall(:jl_tag_newly_inferred_disable, Cvoid, ())
    if !Base.generating_output()   # for verbose[]
        ccall(:jl_set_newly_inferred, Cvoid, (Any,), nothing)
    end
    if verbose[]
        for ci in newly_inferred
            println(ci.def)
        end
    end
    return nothing
end

"""
    @compile_workload f(args...)

`precompile` (and save in the `compile_workload` file) any method-calls that occur inside the expression. All calls (direct or indirect) inside a
`@compile_workload` block will be cached.

`@compile_workload` has three key features:

1. code inside runs only when the package is being precompiled (i.e., a `*.ji`
   precompile `compile_workload` file is being written)
2. the interpreter is disabled, ensuring your calls will be compiled
3. both direct and indirect callees will be precompiled, even for methods defined in other packages
   and even for runtime-dispatched callees (requires Julia 1.8 and above).

!!! note
    For comprehensive precompilation, ensure the first usage of a given method/argument-type combination
    occurs inside `@compile_workload`.

    In detail: runtime-dispatched callees are captured only when type-inference is executed, and they
    are inferred only on first usage. Inferrable calls that trace back to a method defined in your package,
    and their *inferrable* callees, will be precompiled regardless of "ownership" of the callees
    (Julia 1.8 and higher).

    Consequently, this recommendation matters only for:

        - direct calls to methods defined in Base or other packages OR
        - indirect runtime-dispatched calls to such methods.
"""
macro compile_workload(ex::Expr)
    local iscompiling = :($PrecompileTools.is_generating_output() && $PrecompileTools.workload_enabled(@__MODULE__))
    ex = quote
        begin
            $PrecompileTools.@latestworld_if_toplevel  # block inference from proceeding beyond this point (xref https://github.com/JuliaLang/julia/issues/57957)
            $(esc(ex))
        end
    end
    ex = quote
        $PrecompileTools.tag_newly_inferred_enable()
        try
            $ex
        finally
            $PrecompileTools.tag_newly_inferred_disable()
        end
    end
    return quote
        if $iscompiling || $PrecompileTools.verbose[]
            $ex
        end
    end
end

"""
    @setup_workload begin
        vars = ...
        ⋮
    end

Run the code block only during package precompilation. `@setup_workload` is often used in combination
with [`@compile_workload`](@ref), for example:

    @setup_workload begin
        vars = ...
        @compile_workload begin
            y = f(vars...)
            g(y)
            ⋮
        end
    end

`@setup_workload` does not force compilation (though it may happen anyway) nor intentionally capture
runtime dispatches (though they will be precompiled anyway if the runtime-callee is for a method belonging
to your package).
"""
macro setup_workload(ex::Expr)
    local iscompiling = :((ccall(:jl_generating_output, Cint, ()) == 1 && $PrecompileTools.workload_enabled(@__MODULE__)))
    # Ideally we'd like a `let` around this to prevent namespace pollution, but that seem to
    # trigger inference & codegen in undesirable ways (see #16).
    return quote
        if $iscompiling || $PrecompileTools.verbose[]
            let
                $PrecompileTools.@latestworld_if_toplevel  # block inference from proceeding beyond this point (xref https://github.com/JuliaLang/julia/issues/57957)
                $(esc(ex))
            end
        end
    end
end
