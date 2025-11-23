struct DuplicatedAliasError <: Exception
    name::String
end

function Base.showerror(io::IO, err::DuplicatedAliasError)
    print(io, "DuplicatedAliasError: duplicated alias name: ")
    return printstyled(io, err.name; color=:cyan)
end

struct InvalidKeyError <: Exception
    got::Union{Symbol, String}
    keys::Union{Vector{Symbol}, Vector{String}}
end

function Base.showerror(io::IO, err::InvalidKeyError)
    print(io, "InvalidKeyError: invalid key ")
    printstyled(io, err.got; color=:light_blue)
    print(io, ", possible keys are: ")

    if length(err.keys) > 8
        for idx in 1:8
            printstyled(io, err.keys[idx]; color=:light_blue)
            if idx != 8
                print(io, ", ")
            end
        end
        print(io, "... please check documentation for other valid keys")
    else
        for idx in eachindex(err.keys)
            printstyled(io, err.keys[idx]; color=:light_blue)
            if idx != lastindex(err.keys)
                print(io, ", ")
            end
        end
    end
    return nothing
end

"""
    DuplicatedFieldError(name, type)

A field with `name` of given option `type` is duplicated in the subfields option type.
Thus one cannot use the field keyword convention when seeing this error.
"""
struct DuplicatedFieldError <: Exception
    name::Symbol
    type
end

function Base.showerror(io::IO, err::DuplicatedFieldError)
    print(io, "DuplicatedFieldError: duplicated field ")
    printstyled(io, err.name; color=:light_blue)
    print(io, " in type ")
    printstyled(io, err.type; color=:green)
    return print(io, " and its sub-fields")
end

"""
    FieldTypeConversionError(type, fieldname, fieldtype, optiontype)

A conversion from `type` to `fieldtype` belonging to `fieldname` in an `optiontype` failed.
"""
struct FieldTypeConversionError <: Exception
    type
    fieldname::Symbol
    fieldtype
    optiontype
end

function Base.showerror(io::IO, err::FieldTypeConversionError)
    print(io, "FieldTypeConversionError: conversion from ")
    printstyled(io, err.type; color=:red)
    print(io, " to type ")
    printstyled(io, err.fieldtype; color=:green)
    print(io, " for field ")
    printstyled(io, err.fieldname; color=:light_blue)
    print(io, " in type ")
    printstyled(io, err.optiontype; color=:green)
    return print(io, " failed")
end
