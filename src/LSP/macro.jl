macro namespace(Name, ex)
    Meta.isexpr(ex, :block) || error("Expected :block expression")

    # JSON import
    JSON = gensym("JSON")
    jsonimport = :(import JSON as $JSON)

    # `@enum` definition
    enumbody = Expr(:block)
    enumdef = Expr(:macrocall, Symbol("@enum"), __source__, Name, enumbody)

    # `JSON.lower` definition
    lowerbody = Expr(:block)

    # Documentation for enum values
    enumdocs = Any[]

    for arg in ex.args
        if Meta.isexpr(arg, :macrocall)
            arg.args[1] === GlobalRef(Core, Symbol("@doc")) || error("Unsupported macro call within `@namespace`")
            arg′ = pop!(arg.args)
            Meta.isexpr(arg′, :(=)) || error("Invalid `@namespace`")
            push!(arg.args, arg′.args[1])
            push!(enumdocs, arg)
            arg = arg′
        end
        if Meta.isexpr(arg, :(=))
            eval, lval = arg.args
            push!(enumbody.args, eval)
            push!(lowerbody.args, :(x === $eval && return $lval))
        else
            push!(enumbody.args, arg)
        end
    end

    push!(lowerbody.args, :(error("Uncovered enum")))
    lowerdef = Expr(:(=), Expr(:call, :($JSON.lower), :(x::$Name)), lowerbody)

    Namespace = Symbol(Name, "Namespace")
    modex = Expr(:block, jsonimport, enumdef, enumdocs..., lowerdef)
    return esc(Expr(:toplevel,
        Expr(:module, true, Namespace, modex),
        :(using .$Namespace: $Namespace, $Name),
        :(Base.@__doc__ $Namespace),
        :(Base.@__doc__ $Name)))
end

macro extends(Tx)
	nothing
end

const _TS_DEFS = Dict{Symbol,Expr}()
macro tsdef(ex)
    Meta.isexpr(ex, :struct) || error("Expected :struct expression")
    structbody = ex.args[3]
    Meta.isexpr(structbody, :block) || error("Unexpected `:struct` expression")
    for i = 1:length(structbody.args)
        structline = structbody.args[i]
        Meta.isexpr(structline, :macrocall) || continue
        structline.args[1] === Symbol("@extends") || continue
        for j = 2:length(structline.args)
            structlineⱼ = structline.args[j]
            structlineⱼ isa Symbol || continue
            haskey(_TS_DEFS, structlineⱼ) || error("`@extends` unknown definition")
            extendsex = _TS_DEFS[structlineⱼ]
            @assert Meta.isexpr(extendsex, :struct)
            extendsbody = extendsex.args[3]
            @assert Meta.isexpr(extendsbody, :block)
            for extendsline in extendsbody.args
                insert!(structbody.args, i, extendsline)
            end
        end
    end
    _TS_DEFS[ex.args[2]::Symbol] = ex
    structdef = :(Base.@kwdef $ex)
    return esc(structdef)
end

# """/**
#  * A type indicating how positions are encoded,
#  * specifically what column offsets mean.
#  *
#  * @since 3.17.0
#  */"""
# @ts export type PositionEncodingKind = string;

# """/**
#  * A set of predefined position encoding kinds.
#  *
#  * @since 3.17.0
#  */"""
# @ts export namespace PositionEncodingKind {

# 	"""/**
# 	 * Character offsets count UTF-8 code units (e.g bytes).
# 	 */"""
# 	UTF8: PositionEncodingKind = "utf-8";

# 	"""/**
# 	 * Character offsets count UTF-16 code units.
# 	 *
# 	 * This is the default and must always be supported
# 	 * by servers
# 	 */"""
# 	UTF16: PositionEncodingKind = "utf-16";

# 	"""/**
# 	 * Character offsets count UTF-32 code units.
# 	 *
# 	 * Implementation note: these are the same as Unicode code points,
# 	 * so this `PositionEncodingKind` may also be used for an
# 	 * encoding-agnostic representation of character offsets.
# 	 */"""
# 	UTF32: PositionEncodingKind = "utf-32";
# }

# @ts interface ServerCapabilities {

# 	"""/**
# 	 * The position encoding the server picked from the encodings offered
# 	 * by the client via the client capability `general.positionEncodings`.
# 	 *
# 	 * If the client didn't provide any position encodings the only valid
# 	 * value that a server can return is 'utf-16'.
# 	 *
# 	 * If omitted it defaults to 'utf-16'.
# 	 *
# 	 * @since 3.17.0
# 	 */"""
# 	positionEncoding var"?:" PositionEncodingKind;
# }
