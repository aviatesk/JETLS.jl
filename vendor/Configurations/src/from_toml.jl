
"""
    from_toml(::Type{T}, filename::String; kw...) where T

Convert a given TOML file `filename` to an option type `T`. Valid fields
can be override by keyword arguments. See also [`from_dict`](@ref).
"""
function from_toml(::Type{T}, filename::String; kw...) where {T}
    is_option(T) || error("not an option type")
    d = TOML.parsefile(filename)

    filepath = normpath(filename)
    d["#metadata#"] = Dict{String, Any}(
        "file" => filepath,
        "dir" => dirname(filepath),
        "format" => "TOML",
    )
    return from_dict(T, d; kw...)
end

"""
    from_toml_if_exists(::Type{T}, filename::String; kw...) where T

Similar to [`from_toml`](@ref) but will create the option instance
via `from_kwargs(T;kw...)` instead of error if the file does not exist.
"""
function from_toml_if_exists(::Type{T}, filename::String; kw...) where {T}
    if isfile(filename)
        return from_toml(T, filename; kw...)
    else
        return from_kwargs(T; kw...)
    end
end
