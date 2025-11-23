function assert_option(x)
    return is_option(x) || error("$(typeof(x)) is not an option type")
end

@option struct ToDictOption
    include_defaults::Bool = true
    exclude_nothing::Bool = false
end

"""
    TOMLStyle::ToDictOption

Predefined option for TOML compatible [`to_dict`](@ref) option.
"""
const TOMLStyle = ToDictOption(; include_defaults=true, exclude_nothing=true)

"""
    YAMLStyle::ToDictOption

Predefined option for YAML compatible [`to_dict`](@ref) option.
"""
const YAMLStyle = ToDictOption(; include_defaults=true, exclude_nothing=false)

"""
    JSONStyle::ToDictOption

Predefined option for JSON compatible [`to_dict`](@ref) option.
"""
const JSONStyle = ToDictOption(; include_defaults=true, exclude_nothing=false)

"""
    to_dict(x; include_defaults=true, exclude_nothing=false) -> OrderedDict

Convert an object `x` to an `OrderedDict`.

# Kwargs

- `include_defaults`: include the default value, default is `true`.
- `exclude_nothing`: exclude fields that have value `nothing`,
    this supersedes `include_defaults` when they are both `true`.

# Format Compatibilty

When mapping an option struct from Julia to TOML/YAML/JSON/etc. format,
there are some subtle semantic compatibilty one need to deal with, we provide
some convenient predefined conversion option constants as [`TOMLStyle`](@ref),
[`YAMLStyle`](@ref), [`JSONStyle`](@ref).

!!! tips
    `to_dict` does not export fields that are of the same values as the defaults. 
    In most cases, this should be the default behaviour, and users should not use
    `include_defaults`, however,  this can be overridden by changing `include_defaults`
    to `true`.
"""
function to_dict(x; kw...)
    return to_dict(x, ToDictOption(; kw...))
end

"""
    to_dict(x, option::ToDictOption) -> OrderedDict

Convert an object `x` to an `OrderedDict` with `ToDictOption` specified.

# Example

```julia
to_dict(x, TOMLStyle) # TOML compatible
to_dict(x, YAMLStyle) # YAML compatible
to_dict(x, JSONStyle) # JSON compatible
```
"""
function to_dict(x, option::ToDictOption)
    assert_option(x)
    return to_dict(typeof(x), x, option)
end

# disambiguity
to_dict(x::Type, ::ToDictOption) = error("$x is not an option type")

"""
    to_dict(::Type{T}, x, option::ToDictOption) where T

Convert `x` when `x` is inside an option type `T`. `option`
is a set of options to determine the conversion behaviour. this can
be overloaded to change the behaviour of `to_dict(x; kw...)`.

    to_dict(::Type{T}, x) where T

One can also use the 2-arg version when `x` is not or does not
contain an option type for convenience.

# Example

The following is a builtin overload to handle list of options.

```julia
function Configurations.to_dict(::Type{T}, x::Vector, option::ToDictOption) where T
    if is_option(eltype(x))
        return map(p->to_dict(T, p, include_defaults), x)
    else
        return x
    end
end
```

The following overloads the 2-arg `to_dict` to convert all `VersionNumber` to
a `String` for all kinds of option types.

```julia
Configurations.to_dict(::Type, x::VersionNumber) = string(x)
```
"""
function to_dict(::Type{T}, x, option::ToDictOption) where {T}
    if is_option(x)
        return _option_to_dict(x, option)
    else
        return to_dict(T, x) # fall through 2-arg version
    end
end

to_dict(::Type, x) = x

# handle list of options as builtin
function to_dict(::Type{T}, x::Vector, option::ToDictOption) where {T}
    return map(x) do each
        d = to_dict(T, each, option)
        if eltype(x) isa Union && is_option(each)
            FieldType = typeof(each)
            alias = type_alias(FieldType)
            idx = find_reflect_field(FieldType)
            if alias !== nothing && idx === nothing
                return OrderedDict{String,Any}(alias => d)
            end
        end
        return d
    end
end

function _option_to_dict(x, option::ToDictOption)
    assert_option(x)

    d = OrderedDict{String,Any}()
    T = typeof(x)
    for name in fieldnames(T)
        type = fieldtype(T, name)
        value = getfield(x, name)
        name_str = string(name)
        if option.exclude_nothing && value === nothing
            continue
        end

        if option.include_defaults || value != field_default(T, name)
            field_dict = to_dict(T, value, option)

            # 1. option type contains field of type Reflect
            # 2. option type contains field of Union{options...}
            # 3. other types
            #
            # NOTE:
            # we always add an alias if it's a Union
            # of multiple option types
            if type === Reflect
                # we don't implement this via `to_dict`
                # because we want it error when `Reflect`
                # is used as a normal type
                # `Reflect` should be only used to denote
                # a field contains the type info as a `String`.
                if type_alias(T) === nothing
                    d[name_str] = full_typename(T)
                else
                    d[name_str] = type_alias(T)
                end
            elseif is_option(value) && is_union_of_multiple_options(type)
                if contains_reflect_type(typeof(value))
                    d[name_str] = field_dict
                    continue
                end

                alias = type_alias(typeof(value))
                if alias === nothing
                    error("please define an alias for option type $(typeof(value))")
                end

                d[name_str] = OrderedDict{String,Any}(alias => field_dict)
            else
                d[name_str] = field_dict
            end
        end
    end
    return d
end

"""
    is_option_maybe(::Type{T}) where T

`T` is an option struct or if `T` is an union, one of the types
is an option struct.
"""
function is_option_maybe(::Type{T}) where {T}
    is_option(T) && return true
    T isa Union || return false
    return is_option_maybe(T.a) || is_option_maybe(T.b)
end

"""
    to_toml([f::Function], io::IO, option; sorted=false, by=identity, kw...)

Convert an instance `option` of option type to TOML and write it to `IO`. See [`to_dict`](@ref)
for other valid keyword options. See also `TOML.print` in the stdlib for the explaination of
`sorted`, `by` and `f`.

# Exclude `nothing`

In TOML specification, there is [no null type](https://github.com/toml-lang/toml/issues/802). One
should exclude the field if it is not specified (of value `nothing` in Julia). In `to_toml` the option
`exclude_nothing` is always `true`.

In most cases, `nothing` is used with another type to denote optional or not specified field,
thus one should always put a default
value `nothing` to the option struct, e.g

One should define

```julia
@option struct OptionX
    a::Union{Nothing, Int} = nothing
    b::Maybe{Int} = nothing
end
```

Here `Maybe{T}` is a convenient alias of `Union{Nothing, T}`.
"""
function to_toml(f, io::IO, x; sorted::Bool=false, by=identity, kw...)
    is_option(x) || error("argument is not an option type")
    d = to_dict(x; exclude_nothing=true, kw...)
    return TOML.print(f, io, d; sorted=sorted, by=by)
end

"""
    to_toml([f::Function], filename::String, option; sorted=false, by=identity, kw...)

Convert an instance `option` of option type to TOML and write it to `filename`. See also `TOML.print`.
"""
function to_toml(f, filename::String, x; sorted::Bool=false, by=identity, kw...)
    open(filename, "w+") do io
        to_toml(f, io, x; sorted=sorted, by=by, kw...)
    end
end

function to_toml(io::IO, x; sorted::Bool=false, by=identity, kw...)
    return to_toml(identity, io, x; sorted=sorted, by=by, kw...)
end

function to_toml(filename::String, x; sorted::Bool=false, by=identity, kw...)
    return to_toml(identity, filename, x; sorted=sorted, by=by, kw...)
end

"""
    to_toml(x; sorted=false, by=identity, kw...)

Convert an instance `x` of option type to TOML and write it to `String`. See also `TOML.print`. 

`to_toml` does not export fields that are of the same values as the defaults. This can be 
overridden by changing `include_defaults` to `true`.
"""
function to_toml(x; sorted::Bool=false, by=identity, kw...)
    return sprint(x) do io, x
        to_toml(io, x; sorted=sorted, by=by, kw...)
    end
end
