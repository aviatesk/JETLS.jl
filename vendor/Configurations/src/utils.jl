"""
    is_option(x)

Check if `x` is an option type or not.
"""
is_option(x) = false

"""
    compare_options(a, b, xs...)::Bool

Compare option types check if they are the same.
"""
function compare_options(a, b, xs...)::Bool
    compare_options(a, b) || return false
    return compare_options(b, xs...)
end

compare_options(a, b) = false

function compare_options(a::A, b::A) where {A}
    is_option(A) || return a == b # fall through to normal compare
    for idx in 1:nfields(a)
        compare_options(getfield(a, idx), getfield(b, idx)) || return false
    end
    return true
end

function tryparse_jltype(s, alias_map=nothing)
    s isa String || throw(ArgumentError("expect type String, got: $(typeof(s))"))
    if alias_map !== nothing
        haskey(alias_map, s) && return alias_map[s]
    end

    type_ex = Meta.parse(s)
    is_datatype_expr(type_ex) ||
        throw(ArgumentError("expect type expression got: $type_ex"))
    try
        return eval(type_ex)
    catch
        return nothing
    end
end

function parse_jltype(s, alias_map=nothing)
    type = tryparse_jltype(s, alias_map)
    type === nothing && throw(ArgumentError("cannot parse $s to a Julia type"))
    return type
end

# NOTE: copied from JLD
# https://github.com/JuliaIO/JLD.jl/blob/83ea0c5ef7293c78d7d9c8ffdf9ede599b54dc4c/src/JLD00.jl#L991
# we only have DataType to serialize
function full_typename(jltype::DataType)
    tname = string(jltype.name.module, ".", jltype.name.name)
    if isempty(jltype.parameters)
        return tname
    else
        params_str = join([full_typename(x) for x in jltype.parameters], ",")
        return string(tname, "{", params_str, "}")
    end
end

function contains_reflect_type(::Type{T}) where {T}
    for idx in 1:fieldcount(T)
        Reflect === fieldtype(T, idx) && return true
    end
    return false
end

function is_union_of_multiple_options(::Type{T}) where {T}
    T isa Union || return false
    T.a === Nothing && return is_union_of_multiple_options(T.b)
    T.b === Nothing && return is_union_of_multiple_options(T.a)

    # not option type
    return is_option_maybe(T.a) && is_option_maybe(T.b)
end
