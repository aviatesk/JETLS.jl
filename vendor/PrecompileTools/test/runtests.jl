using PrecompileTools
using Test
using Pkg
using UUIDs
using Base: specializations

@testset "PrecompileTools.jl" begin
    push!(LOAD_PATH, @__DIR__)

    using PC_A
    # Check that calls inside @setup_workload are not precompiled
    m = which(Tuple{typeof(Base.vect), Vararg{T}} where T)
    have_mytype = false
    for mi in specializations(m)
        mi === nothing && continue
        have_mytype |= Base.unwrap_unionall(mi.specTypes).parameters[2] === PC_A.MyType
    end
    have_mytype && @warn "Code in setup_workload block was precompiled"
    # Check that calls inside @compile_workload are precompiled
    m = only(methods(PC_A.call_findfirst))
    count = 0
    for mi in specializations(m)
        mi === nothing && continue
        sig = Base.unwrap_unionall(mi.specTypes)
        if sig == Tuple{typeof(PC_A.call_findfirst), PC_A.MyType, Vector{PC_A.MyType}}
            count += 1
        end
    end
    @test count == 1
    # Even one that was runtime-dispatched
    m = which(Tuple{typeof(findfirst), Base.Fix2{typeof(==), T}, Vector{T}} where T)
    count = 0
    for mi in specializations(m)
        mi === nothing && continue
        sig = Base.unwrap_unionall(mi.specTypes)
        if sig.parameters[3] == Vector{PC_A.MyType}
            count += 1
        end
    end
    @test count == 1

    pipe = Pipe()
    id = Base.PkgId(UUID("d38b61e7-59a2-4ef9-b4d3-320bdc69b817"), "PC_B")
    redirect_stderr(pipe) do
        @test_throws Exception Base.require(id)
    end
    close(pipe.in)
    str = read(pipe.out, String)
    @test occursin(r"UndefVarError: `?missing_function`? not defined", str)

    using PC_C

    script = """
    using PC_D
    exit(isdefined(PC_D, :workload_ran) === parse(Bool, ARGS[1]) ? 0 : 1)
    """

    projfile = Base.active_project()
    Pkg.activate("PC_D")
    Pkg.instantiate()
    using PC_D

    PrecompileTools.Preferences.set_preferences!(PC_D, "precompile_workload" => false)
    @test success(run(`$(Base.julia_cmd()) --project=$(joinpath(@__DIR__, "PC_D")) -e $script 0`))

    PrecompileTools.Preferences.delete_preferences!(PC_D, "precompile_workload"; force = true)
    @test success(run(`$(Base.julia_cmd()) --project=$(joinpath(@__DIR__, "PC_D")) -e $script 1`))
    Pkg.activate(projfile)

    preffile = joinpath(@__DIR__, "PC_D", "LocalPreferences.toml")
    if isfile(preffile)
        rm(preffile)
    end

    oldval = PrecompileTools.verbose[]
    PrecompileTools.verbose[] = true
    mktemp() do path, io
        redirect_stdout(io) do
            include(joinpath(@__DIR__, "PC_E", "src", "PC_E.jl"))
        end
        close(io)
        str = read(path, String)
        @test occursin("MethodInstance for", str)
        modscope = "PC_E."
        @test occursin("$(modscope)f(::$Int)", str)
        @test occursin("$(modscope)f(::String)", str)
    end
    PrecompileTools.verbose[] = oldval

    using NotToplevel
    # Check that calls inside @setup_workload are not precompiled
    m = NotToplevel.NotPrecompiled.themethod
    have_char = have_float = false
    for mi in specializations(m)
        mi === nothing && continue
        have_char |= mi.specTypes.parameters[2] === Char
        have_float |= mi.specTypes.parameters[2] === Float64
    end
    @test !have_float       # not wrapped inside `@compile_workload`
    @test_broken have_char  # is wrapped

    ## @recompile_invalidations

    # Mimic the format written to `_jl_debug_method_invalidation`
    # As a source of MethodInstances, `getproperty` has lots
    m = which(getproperty, (Any, Symbol))
    mis, cis = Core.MethodInstance[], Core.CodeInstance[]
    for mi in specializations(m)
        length(cis) >= 10 && break
        mi === nothing && continue
        push!(mis, mi)
        isdefined(mi, :cache) && push!(cis, mi.cache)
    end
    # These mimic the format of the logs produced by `jl_debug_method_invalidation` (both variants)
    invs = Any[mis[1], 0, mis[2], 1, Tuple{}, m, "jl_method_table_insert"]
    @test PrecompileTools.invalidation_leaves(invs, []) == Set([mis[2]])
    invs = Any[mis[1], 0, mis[2], 1, mis[3], 1, Tuple{}, m, "jl_method_table_insert"]
    @test PrecompileTools.invalidation_leaves(invs, []) == Set([mis[2], mis[3]])
    invs = Any[mis[1], 0, mis[2], 1, Tuple{}, mis[1], 1, mis[3], "jl_method_table_insert", m, "jl_method_table_insert"]
    @test PrecompileTools.invalidation_leaves(invs, []) == Set(mis[1:3])
    invs = Any[mis[1], 1, mis[2], "jl_method_table_disable", m, "jl_method_table_disable"]
    @test PrecompileTools.invalidation_leaves(invs, []) == Set([mis[1], mis[2]])
    invs = Any[mis[1], 1, mis[2], "jl_method_table_disable", mis[3], "jl_method_table_insert", m]
    @test Set([mis[1], mis[2]]) ⊆ PrecompileTools.invalidation_leaves(invs, [])
    invs = Any[mis[1], 1, mis[2], "jl_method_table_insert", mis[2], "invalidate_mt_cache", m, "jl_method_table_insert"]
    @test PrecompileTools.invalidation_leaves(invs, []) == Set([mis[1], mis[2]])
    invs = Any[m, "method_globalref", cis[1], nothing, Tuple{}, "insert_backedges_callee", cis[2], Any[m], cis[3], "verify_methods", cis[4]]
    @test PrecompileTools.invalidation_leaves([], invs) == Set(Core.Compiler.get_ci_mi.(cis[1:3]))

    # Coverage isn't on during package precompilation, so let's test a few things here
    PrecompileTools.precompile_mi(mis[1])

    # Add a real invalidation & repair test
    cproj = Base.active_project()
    mktempdir() do dir
        push!(LOAD_PATH, dir)
        cd(dir) do
            # Method insertion invalidations
            for ((pkg1, pkg2, pkg3), recompile) in ((("RC_A", "RC_B", "RC_C"), false,),
                                                    (("RC_D", "RC_E", "RC_F"), true))
                Pkg.generate(pkg1)
                open(joinpath(dir, pkg1, "src", pkg1*".jl"), "w") do io
                    println(io, """
                    module $pkg1
                    nbits(::Int8) = 8
                    nbits(::Int16) = 16
                    call_nbits(c) = nbits(only(c))
                    begin
                        Base.Experimental.@force_compile
                        call_nbits(Any[Int8(5)])
                    end
                    end
                    """)
                end
                Pkg.generate(pkg2)
                Pkg.activate(joinpath(dir, pkg2))
                Pkg.develop(PackageSpec(path=joinpath(dir, pkg1)))
                open(joinpath(dir, pkg2, "src", pkg2*".jl"), "w") do io
                    println(io, """
                    module $pkg2
                    using $pkg1
                    $(pkg1).nbits(::Int32) = 32
                    end
                    """)
                end
                # pkg3 is like a "Startup" package that recompiles the invalidations from loading the "code universe"
                Pkg.generate(pkg3)
                Pkg.activate(joinpath(dir, pkg3))
                Pkg.develop(PackageSpec(path=joinpath(dir, pkg2)))
                Pkg.develop(PackageSpec(path=dirname(@__DIR__)))   # depend on PrecompileTools
                open(joinpath(dir, pkg3, "src", pkg3*".jl"), "w") do io
                    if recompile
                        println(io, """
                        module $pkg3
                        using PrecompileTools
                        @recompile_invalidations using $pkg2
                        end
                        """)
                    else
                        println(io, """
                        module $pkg3
                        using PrecompileTools
                        using $pkg2
                        end
                        """)
                    end
                end

                @eval using $(Symbol(pkg3))
                mod3 = Base.@invokelatest getglobal(@__MODULE__, Symbol(pkg3))
                mod2 = Base.@invokelatest getglobal(mod3, Symbol(pkg2))
                mod1 = Base.@invokelatest getglobal(mod2, Symbol(pkg1))
                m = only(methods(mod1.call_nbits))
                mi = first(specializations(m))
                wc = Base.get_world_counter()
                @test recompile ? mi.cache.max_world >= wc : mi.cache.max_world < wc
            end

            # Edge-invalidation
            for ((pkg1, pkg2, pkg3), recompile) in ((("RC_G", "RC_H", "RC_I"), false,),
                                                    (("RC_J", "RC_K", "RC_L"), true))
                Pkg.generate(pkg1)
                open(joinpath(dir, pkg1, "src", pkg1*".jl"), "w") do io
                    println(io, """
                    module $pkg1
                    nbits(::Int8) = 8
                    nbits(::Int16) = 16
                    end
                    """)
                end
                Pkg.generate(pkg2)
                Pkg.activate(joinpath(dir, pkg2))
                Pkg.develop(PackageSpec(path=joinpath(dir, pkg1)))
                open(joinpath(dir, pkg2, "src", pkg2*".jl"), "w") do io
                    println(io, """
                    module $pkg2
                    using $pkg1
                    call_nbits(c) = $pkg1.nbits(only(c))
                    begin
                        Base.Experimental.@force_compile
                        call_nbits(Any[Int8(5)])
                    end
                    end
                    """)
                end
                Pkg.generate(pkg3)
                Pkg.activate(joinpath(dir, pkg3))
                Pkg.develop(PackageSpec(path=joinpath(dir, pkg1)))
                Pkg.develop(PackageSpec(path=joinpath(dir, pkg2)))
                Pkg.develop(PackageSpec(path=dirname(@__DIR__)))   # depend on PrecompileTools
                open(joinpath(dir, pkg3, "src", pkg3*".jl"), "w") do io
                    if recompile
                        println(io, """
                        module $pkg3
                        using PrecompileTools
                        @recompile_invalidations begin
                            using $pkg1
                            $pkg1.nbits(::Int32) = 32  # This will cause an edge invalidation
                            using $pkg2
                        end
                        end
                        """)
                    else
                        println(io, """
                        module $pkg3
                        using PrecompileTools
                        using $pkg1
                        $pkg1.nbits(::Int32) = 32  # This will cause an edge invalidation
                        using $pkg2
                        end
                        """)
                    end
                end

                @eval using $(Symbol(pkg3))
                mod3 = Base.@invokelatest getglobal(@__MODULE__, Symbol(pkg3))
                mod2 = Base.@invokelatest getglobal(mod3, Symbol(pkg2))
                mod1 = Base.@invokelatest getglobal(mod2, Symbol(pkg1))
                m = only(methods(mod2.call_nbits))
                mi = first(specializations(m))
                wc = Base.get_world_counter()
                @test recompile ? mi.cache.max_world >= wc : mi.cache.max_world < wc
            end

        end
        pop!(LOAD_PATH)
    end
    Pkg.activate(cproj)

    pop!(LOAD_PATH)
end
