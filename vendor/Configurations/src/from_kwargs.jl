"""
    from_kwargs(convention!, ::Type{T}; kw...) where T

Convert keyword arguments to given option type `T` using `convention!`.
See also [`from_dict`](@ref).

# Convention

- `from_underscore_kwargs!`: use `_` to disambiguate subfields of the same name, this is the default behaviour.
- `from_field_kwargs!`: do not disambiguate subfields, errors if there are disambiguity
"""
function from_kwargs(convention!, ::Type{T}; kw...) where {T}
    d = OrderedDict{String,Any}()
    convention!(d, T; kw...)
    return from_dict(T, d)
end

"""
    from_kwargs(::Type{T}; kw...) where T

Convert keyword arguments to given option type `T` using the underscore convention.
"""
from_kwargs(::Type{T}; kw...) where {T} = from_underscore_kwargs(T; kw...)

"""
    from_underscore_kwargs(::Type{T}; kw...) where T

Convert keyword arguments to given option type `T` using the underscore convention.
"""
function from_underscore_kwargs(::Type{T}; kw...) where {T}
    return from_kwargs(from_underscore_kwargs!, T; kw...)
end

"""
    from_field_kwargs(::Type{T}; kw...) where T

Convert keyword arguments to given option type `T` using the field keyword convention.
"""
from_field_kwargs(::Type{T}; kw...) where {T} = from_kwargs(from_field_kwargs!, T; kw...)

# NOTE: this is for compatibilty
"""
    from_kwargs!(d::AbstractDict{String}, ::Type{T}, prefix::Maybe{Symbol} = nothing; kw...) where T

Internal method for inserting keyword arguments to given dictionary object `d`. It will overwrite
existing keys in `d` if it is specified by keyword argument.
"""
function from_kwargs!(
    d::AbstractDict{String}, ::Type{T}, prefix::Maybe{Symbol}=nothing; kw...
) where {T}
    return from_underscore_kwargs!(d, T, prefix; kw...)
end

function from_underscore_kwargs!(
    d::AbstractDict{String}, ::Type{T}, prefix::Maybe{Symbol}=nothing; kw...
) where {T}
    validate_keywords(T, underscore_keywords(T); kw...)
    return unsafe_from_underscore_kwargs!(d, T, prefix; kw...)
end

function unsafe_from_underscore_kwargs!(
    d::AbstractDict{String}, ::Type{T}, prefix::Maybe{Symbol}=nothing; kw...
) where {T}
    foreach_keywords(T) do name, type
        key = underscore(prefix, name)

        from_kwargs_option_key!(d, type, name, key, kw) do field_d, field_type
            unsafe_from_underscore_kwargs!(field_d, field_type, key; kw...)
        end
    end
    return d
end

function from_field_kwargs!(d::AbstractDict{String}, ::Type{T}; kw...) where {T}
    validate_keywords(T, field_keywords(T); kw...)
    return unsafe_from_field_kwargs!(d, T; kw...)
end

function unsafe_from_field_kwargs!(d::AbstractDict{String}, ::Type{T}; kw...) where {T}
    foreach_keywords(T) do name, type
        from_kwargs_option_key!(d, type, name, name, kw) do field_d, field_type
            unsafe_from_field_kwargs!(field_d, field_type; kw...)
        end
    end
    return d
end

function from_kwargs_option_key!(
    f, d::AbstractDict, ::Type{T}, name::Symbol, key::Symbol, kw
) where {T}
    key_str = string(key)
    name_str = string(name)
    # shortcut
    if haskey(kw, key)
        d[name_str] = kw[key]
        return d
    end

    if is_option(T)
        field_d = OrderedDict{String,Any}()
        if haskey(d, name_str) && (d_value = d[name_str]) isa AbstractDict
            field_d = merge!(field_d, d_value)
        end

        f(field_d, T) # recurse into subfields
        if !isempty(field_d)
            d[name_str] = field_d
        end
    elseif T isa Union
        from_kwargs_option_key!(f, d, T.a, name, key, kw)
        from_kwargs_option_key!(f, d, T.b, name, key, kw)
    end
    return d
end

function validate_keywords(::Type{T}, keys=underscore_keywords(T); kw...) where {T}
    for (k, v) in kw
        k in keys || throw(InvalidKeyError(k, keys))
    end
    return nothing
end

"""
    field_keywords(::Type{T}) where T

Return all the option type field names given `T`, error if there are duplicated sub-fields.
"""
function field_keywords(::Type{T}) where {T}
    return collect_field_keywords!(Symbol[], T, T)
end

"""
    underscore_keywords(::Type{T}) where T

Return keywords given `T` using the underscore convention.
"""
function underscore_keywords(::Type{T}) where {T}
    return collect_underscore_keywords!(Symbol[], T)
end

function foreach_keywords(f, ::Type{T}) where {T}
    is_option(T) || return

    for name in fieldnames(T)
        type = fieldtype(T, name)
        f(name, type)
    end
    return
end

function underscore(prefix::Maybe{Symbol}, name)
    if prefix === nothing
        return name
    else
        return Symbol(prefix, :_, name)
    end
end

function collect_field_keywords!(list::Vector{Symbol}, ::Type{Top}, ::Type{T}) where {Top,T}
    foreach_keywords(T) do name, type
        if is_option(type)
            collect_field_keywords!(list, Top, type)
        elseif type isa Union
            name in list && error(msg)
            push!(list, name)
            # recurse into Union
            collect_field_keywords!(list, Top, type.a)
            collect_field_keywords!(list, Top, type.b)
        else
            name in list && throw(DuplicatedFieldError(name, Top))
            push!(list, name)
        end
    end
    return list
end

function collect_underscore_keywords!(
    list::Vector{Symbol}, ::Type{T}, prefix::Maybe{Symbol}=nothing
) where {T}
    foreach_keywords(T) do name, type
        key = underscore(prefix, name)

        if is_option(type)
            collect_underscore_keywords!(list, type, key)
        elseif type isa Union
            push!(list, key)
            collect_underscore_keywords!(list, type.a, key)
            collect_underscore_keywords!(list, type.b, key)
        else
            push!(list, key)
        end
    end
    return list
end
