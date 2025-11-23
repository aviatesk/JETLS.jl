"""
    from_dict(::Type{T}, d::AbstractDict{String}; kw...) where T

Convert dictionary `d` to an option type `T`, the value of valid fields of `T`
in this dictionary `d` can be override by keyword arguments.

!!! compat "Configurations 0.17"

    `convert_to_option` interface is deprecated for conversion, please overload
    the 3-arg or 4-arg `from_dict` instead. See also [Type Conversion](@ref type-conversion)
    section.

# Example

```julia-repl
julia> @option struct OptionA
           name::String = "Sam"
           age::Int = 25
       end

julia> d = Dict{String, Any}(
           "name" => "Roger",
           "age" => 10,
       );

julia> from_dict(OptionA, d; age=25)
OptionA(;
    name = "Roger",
    age = 25,
)
```
"""
function from_dict(::Type{OptionType}, d::AbstractDict{String}; kw...) where {OptionType}
    if !isconcretetype(OptionType)
        throw(ArgumentError("expect a concrete type, got $OptionType"))
    end

    # deepcopy is quite expensive
    # error earlier before that
    assert_field_match_exactly(OptionType, d)

    if !isempty(kw)
        d = from_underscore_kwargs!(deepcopy(d), OptionType; kw...)
    end

    return from_dict_specialize(OptionType, d)
end

# An already-parsed option should be kept in nested parsing.
from_dict(::Type{T}, t::T) where {T} = t

"""
    ignore_extra(option_type) -> Bool

Return `true` if the option type ignores extra fields when
read from a dict-like object.

!!! note
    Normally, we require the dict-like object to have exactly the same
    number of fields with the option type. However, it could be useful
    to have ignore extra fields when wrapping network work services to
    ignore some irrelavent optional fields.

!!! note
    Unlike [pydantic](https://pydantic-docs.helpmanual.io/usage/model_config/),
    we do not allow dynamically adding fields to a given type. One should manually
    define fields you would like to include in a struct type and let it to have
    type `Dict{String, Any}`.

# Example

```julia
julia> Configurations.ignore_extra(::Type{MyOption}) = true
```
"""
function ignore_extra(::Type{OptionType}) where {OptionType}
    is_option(OptionType) || error("expect an option type")
    return false
end

function assert_field_match_exactly(::Type{OptionType}, d::AbstractDict{String}) where {OptionType}
    ignore_extra(OptionType) && return

    nf = fieldcount(OptionType)
    option_keys = [string(fieldname(OptionType, idx)) for idx in 1:nf]
    for key in keys(d)
        key == "#metadata#" && continue
        key in option_keys || throw(InvalidKeyError(key, option_keys))
    end
    return
end


"""
    OptionField{name}
    OptionField(name::Symbol)

Trait type that denotes a field of an option type. Mainly used
for dispatch purpose. `name` should be a `Symbol`.
"""
struct OptionField{name} end

OptionField(name::Symbol) = OptionField{name}()

"""
    from_dict(::Type{OptionType}, ::OptionField{f_name}, ::Type{T}, x) where {OptionType, f_name, T}

For option type `OptionType`, convert the object `x` to the field type `T` and assign it to the field
`f_name`.
Raise `FieldTypeConversionError`s errors if `Base.convert` raises exception
```
ERROR: MethodError: Cannot `convert` an object of type ...
```
"""
function from_dict(::Type{OptionType}, optionfield::OptionField{f_name}, ::Type{T}, x
      ) where {OptionType,f_name,T}
    try
        return from_dict(OptionType, T, x)
    catch err
        if err isa MethodError && err.f === convert
            throw(FieldTypeConversionError(typeof(x), f_name, T, OptionType))
        else
            throw(err)
        end
    end
end

function from_dict(
    ::Type{OptionType}, of::OptionField, ::Type{T}, x
) where {OptionType,T<:AbstractVector}
    if eltype(T) isa Union
        return map(x) do each
            from_dict_union_type(OptionType, of, eltype(T), each)
        end
    else
        return map(x) do each
            from_dict(OptionType, of, eltype(T), each)
        end
    end
end

# default conversions
"""
    from_dict(::Type{OptionType}, ::Type{T}, x) where {OptionType, T}

For option type `OptionType`, convert the object `x` to type `T`. This is
similar to `Base.convert(::Type{T}, x)` and will fallback to `Base.convert`
if not defined.
"""
function from_dict(::Type{OptionType}, ::Type{T}, x) where {OptionType,T}
    is_option(T) && return from_dict(T, x)
    # TODO: deprecate convert_to_option
    # then just use the following
    # return convert(T, x)
    return deprecated_conversion(OptionType, T, x)
    # return convert(T, x)
end

from_dict(::Type, ::Type{VersionNumber}, x) = VersionNumber(x)

function deprecated_conversion(::Type{OptionType}, ::Type{T}, x) where {OptionType,T}
    ret = convert_to_option(OptionType, T, x)
    if ret === ConvertNotFound()
        return convert(T, x)
    else
        return ret
    end
end

@generated function from_dict_union_type(
    ::Type{OptionType}, ::OptionField{f_name}, ::Type{FieldType}, value
) where {OptionType,f_name,FieldType}
    types = Base.uniontypes(FieldType)
    return from_dict_union_type_generated(OptionType, OptionField(f_name), types, :value)
end

function from_dict_union_type_dynamic(
    ::Type{OptionType}, of::OptionField{f_name}, ::Type{FieldType}, value
) where {OptionType,f_name,FieldType}
    FieldType isa Union || return from_dict(OptionType, of, FieldType, value)
    assert_duplicated_alias_union(FieldType)

    types = Base.uniontypes(FieldType)
    if Nothing in types
        value === nothing && return nothing # happy path
        types = filter(x -> x !== Nothing, types)
        if length(types) == 1
            return from_dict(OptionType, of, types[1], value)
        end
    end

    for T in types
        if is_option(T)
            alias = type_alias(T)
            reflect_idx = find_reflect_field(T)
            # type can be determined by alias
            if haskey(value, alias)
                return from_dict(T, value[alias])
            elseif reflect_idx !== nothing # type can be determined by reflect field
                reflect_f_name = fieldname(T, reflect_idx)
                reflect_key = string(reflect_f_name)
                if haskey(value, reflect_key)
                    if alias == value[reflect_key] # find alias in reflect
                        return from_dict(T, value)
                    else
                        type = tryparse_jltype(value[reflect_key], get_type_alias_map(OptionType))
                        type === nothing && continue
                        # NOTE: type is always more specialized
                        type <: T && return from_dict(type, value)
                    end
                end
                continue
            end

            if alias === nothing && reflect_idx === nothing
                # not much information, try parse
                try
                    return from_dict(T, value)
                catch
                    continue
                end
            end
        else
            try
                return from_dict(OptionType, of, T, value)
            catch
                continue
            end
        end
    end
    return error("cannot parse field $f_name, expect $FieldType, got $(typeof(value))")
end

function find_reflect_field(::Type{OptionType}) where {OptionType}
    nf = fieldcount(OptionType)
    for f_idx in 1:nf
        f_type = fieldtype(OptionType, f_idx)
        if f_type <: Reflect
            return f_idx
        end
    end
    return nothing
end

function assert_duplicated_alias_union(::Type{UnionType}) where {UnionType}
    set = String[]
    for T in Base.uniontypes(UnionType)
        if is_option(T)
            alias = type_alias(T)
            if alias !== nothing
                alias in set && throw(DuplicatedAliasError(alias))
                push!(set, alias)
            end
        end
    end
    return nothing
end

"""
    from_dict_specialize(::Type{OptionType}, x) where {OptionType}

A specialized [`from_dict`](@ref) method for option type `OptionType`.
This is usually generated by [`@option`](@ref), but one may also specialized
this manually to acheive maximal performance.
"""
function from_dict_specialize(::Type{OptionType}, x) where {OptionType}
    error(
        "specialized from_dict is not generated for `$OptionType` " *
        "consider define your own `from_dict` " *
        "otherwise use the `@option` macro to create the option type."
    )
end

"""
    from_dict_generated(::Type{OptionType}, value::Symbol) where {OptionType}

Generate a specialized Julia expression to convert an `AbstractDict{String}` to
our `OptionType`.
"""
function from_dict_generated(::Type{OptionType}, value::Symbol) where {OptionType}
    nf = fieldcount(OptionType)
    ret = Expr(:block)
    construct = Expr(:call, OptionType)
    for f_idx in 1:nf
        f_name = fieldname(OptionType, f_idx)
        f_type = fieldtype(OptionType, f_idx)
        f_default = field_default(OptionType, f_name)

        var = f_name
        key = string(f_name)
        field_value = gensym(:field_value)
        push!(construct.args, var)

        jl = JLIfElse()

        if f_default === no_default
            err_msg = "expect key: $key"
            jl[:(!haskey($value, $key))] = :(error($err_msg))
        elseif f_default isa PartialDefault
            jl[:(!haskey($value, $key))] = :($var = $(f_default.lambda)($(f_default.vars...)))
        else
            jl[:(!haskey($value, $key))] = :($var = $(QuoteNode(f_default)))
        end

        body = from_dict_generated(OptionType, OptionField(f_name), f_type, field_value)
        # Maybe{option} type wants to treat empty dict
        # as all default value
        types = Base.uniontypes(f_type)
        types = filter(x -> x !== Nothing, types)
        
        if f_default === nothing && length(types) == 1 && is_option(types[1])
            jl.otherwise = quote
                $field_value = $value[$key]
                $var = $body
            end
        elseif f_default === nothing
            jl.otherwise = quote
                $field_value = $value[$key]
                if $field_value isa AbstractDict && isempty($field_value)
                    $var = nothing
                else
                    $var = $body
                end
            end
        else
            jl.otherwise = quote
                $field_value = $value[$key]
                $var = $body
            end
        end

        push!(ret.args, codegen_ast(jl))
    end
    push!(ret.args, construct)
    return ret
end

function from_dict_generated(
    option_type, of::OptionField, f_type::Type, field_value::Symbol
)
    if is_option(f_type)
        quote
            $field_value isa AbstractDict || $field_value isa $f_type ||
                error("expect an AbstractDict or $($f_type), got $(typeof($field_value))")
            # NOTE: we want to allow user overloaded from_dict here
            # thus we don't use $(from_dict_generated(f_type, value))
            $Configurations.from_dict($f_type, $field_value)
        end
    elseif f_type isa Union
        types = Base.uniontypes(f_type)
        from_dict_union_type_generated(option_type, of, types, field_value)
    elseif f_type <: Reflect # check if the reflect value match current type
        msg = "type mismatch, expect $option_type got"
        alias = type_alias(option_type)
        alias_map = get_type_alias_map(option_type)
        if alias === nothing
            quote
                $Configurations.parse_jltype($field_value, $alias_map) <: $option_type ||
                    throw(ArgumentError($msg * " $($field_value)"))
                $Reflect()
            end
        else
            quote
                $field_value == $alias ||
                    $Configurations.parse_jltype($field_value, $alias_map) <: $option_type ||
                    throw(ArgumentError($msg * " $($field_value)"))
                $Reflect()
            end
        end
    else
        quote
            $Configurations.from_dict($option_type, $of, $f_type, $field_value)
        end
    end
end

function from_dict_union_type_generated(
    option_type, of::OptionField, types::Vector{Any}, value::Symbol
)
    if Nothing in types
        from_dict_maybe_type_generated(option_type, of, types, value)
    elseif has_same_reflect_field(types)
        _from_dict_union_type_similar_reflect_field(types, value)
    else # fallback to dynamic
        FieldType = Union{types...}
        return quote
            $Configurations.from_dict_union_type_dynamic(
                $option_type, $of, $FieldType, $value
            )
        end
    end
end

function from_dict_maybe_type_generated(
    option_type, of::OptionField, types::Vector{Any}, value::Symbol
)
    types = filter(x -> x !== Nothing, types)
    if length(types) == 1 # Maybe{T}
        return quote
            if $value === nothing
                nothing
            else
                $(from_dict_generated(option_type, of, types[1], value))
            end
        end
    else # Maybe{Union{A, B, C...}}
        return quote
            if $value === nothing
                nothing
            else
                $(from_dict_union_type_generated(option_type, of, types, value))
            end
        end
    end
end

function _from_dict_union_type_similar_reflect_field(types::Vector{Any}, value::Symbol)
    T = first(types)
    f_alias_map = alias_map(types)
    f_alias_map = isempty(f_alias_map) ? nothing : f_alias_map
    idx = find_reflect_field(T)
    reflect_key = string(fieldname(T, idx))
    msg = "expect key: $reflect_key"

    type_err_msg = "expect one of the following option type: " *
        join(map(x->string("`", x, "`"), types), ", ")
    @gensym type
    return quote
        haskey($value, $reflect_key) || error($msg)
        $type = $Configurations.parse_jltype($value[$reflect_key], $f_alias_map)
        $type <: $(Union{types...}) || error($type_err_msg * " got `$($type)`")
        $Configurations.from_dict_specialize($type, $value)
    end
end

"""
    has_same_reflect_field(types::Vector{Any})

Check if all types has the same reflect field name.
"""
function has_same_reflect_field(types::Vector{Any})
    idx = find_reflect_field(first(types))
    idx === nothing && return false

    f_reflect = fieldname(first(types), idx)
    for t_idx in 2:length(types)
        T = types[t_idx]
        t_reflect_idx = find_reflect_field(T)
        t_reflect_idx === nothing && return false

        t_f_reflect = fieldname(T, t_reflect_idx)
        if f_reflect !== t_f_reflect
            return false
        end
    end
    return true
end

"""
    alias_map(types::Vector{Any})

Create a `Dict` mapping type alias to a type.
"""
function alias_map(types::Vector{Any})
    d = Dict{String,Any}()
    for t in types
        if is_option(t)
            alias_map = get_type_alias_map(t)::Dict{String, Any}
            merge!(d, alias_map)
        end
    end
    return d
end
