"""
    field_default(::Type{T}, name::Symbol)

Return the default value of field `name` of an option type `T`.
"""
function field_default(::Type{T}, name::Symbol) where {T}
    if !isconcretetype(T) && is_option(T)
        error("field_default requires a concrete type, got $T{...}")
    else
        error("field_default is not defined for $T, it may not be an option type")
    end
end

"""
    field_defaults(::Type)

Return default values of given option types.
"""
function field_defaults(::Type{T}) where {T}
    is_option(T) || error("$T is not an option type")
    return Any[field_default(T, each) for each in fieldnames(T)]
end

"""
    type_alias(::Type{OptionType}) -> String

Return the alias name of given `OptionType`.
"""
function type_alias(::Type{T}) where {T}
    is_option(T) || error("$T is not an option type")
    return error("`type_alias` is not defined for $T, it may not be an option type")
end

function set_type_alias(::Type{T}, name::String) where {T}
    isconcretetype(T) || error("cannot set alias for non concrete type")
    type_alias_map = get_type_alias_map(T)::Dict{String, Any}
    type_alias_map[name] = T
    return
end

function get_type_alias_map(::Type{T}) where {T}
    error("`get_type_alias_map` is not defined for `$T`, it may not be an option type")
end
