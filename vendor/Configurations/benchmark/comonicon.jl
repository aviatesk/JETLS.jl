using BenchmarkTools
using Configurations

struct Asset
    package::Union{Nothing,String}
    path::String
end

function Asset(s::String)
    parts = strip.(split(s, ":"))
    if length(parts) == 1
        Asset(nothing, parts[1])
    elseif length(parts) == 2
        Asset(parts[1], parts[2])
    else
        error("invalid syntax for asset string: $s")
    end
end

macro asset_str(s::String)
    return Asset(s)
end

function Base.show(io::IO, x::Asset)
    print(io, "asset\"")
    if x.package !== nothing
        printstyled(io, x.package, ": "; color=:green)
    end
    printstyled(io, x.path, "\""; color=:cyan)
end

Base.convert(::Type{Asset}, s::String) = Asset(s)

@option struct Install
    path::String = "~/.julia"
    completion::Bool = true
    quiet::Bool = false
    compile::String = "yes"
    optimize::Int = 2
end

@option struct Precompile
    execution_file::Vector{String} = String[]
    statements_file::Vector{String} = String[]
end

@option struct SysImg
    path::String = "deps"
    incremental::Bool = true
    filter_stdlibs::Bool = false
    cpu_target::String = "pentium4;sandybridge,-xsaveopt,clone_all"
    precompile::Precompile = Precompile()
end

@option struct Download
    host::String = "github.com"
    user::String
    repo::String
end

@option struct Application
    path::String = "build"
    assets::Vector{Asset} = Asset[]
    incremental::Bool = false
    filter_stdlibs::Bool = true
    cpu_target::String = "pentium4;sandybridge,-xsaveopt,clone_all"
    precompile::Precompile = Precompile()
    c_driver_program::Union{String,Nothing} = nothing
end

@option struct Comonicon
    name::String

    install::Install = Install()
    sysimg::Maybe{SysImg} = nothing
    download::Union{Download,Nothing} = nothing
    application::Union{Application,Nothing} = nothing
end

option = Comonicon("foo",
    Install("~/.julia", true, false, "min", 2),
    SysImg(
        "deps", true, false, "native",
        Precompile(["deps/precopmile.jl"], String[])
    ),
    Download("github.com", "Roger-luo", "Foo.jl"),
    Application(
        "build",
        Asset[asset"PkgTemplate: templates", asset"assets/images"],
        true, false,
        "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)",
        Precompile(String[], String[]),
        nothing
    )
)

d = to_dict(option)
@btime from_dict(Comonicon, d)

using Configurations: from_dict_dynamic, from_dict_specialize, from_dict_generated

@btime from_dict_dynamic(Comonicon, d)
