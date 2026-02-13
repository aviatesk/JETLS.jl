# Staging ground for common Base macros defined on SyntaxTree.  These are in
# addition to JuliaLowering.jl/src/syntax_macros.jl, and can be merged there
# when possible.

# TODO: @inline, @noinline, @inbounds, @simd, @ccall, @isdefined, @assume_effects

function Base.var"@nospecialize"(__context__::JL.MacroContext)
    JL.@ast(__context__,
            __context__.macrocall::JS.SyntaxTree,
            [JS.K"meta" "nospecialize"::JS.K"Symbol"])
end

# `@nospecialize` with 1-arg is defined in JuliaLowering.jl.

function Base.var"@nospecialize"(
        __context__::JL.MacroContext,
        ex1::JS.SyntaxTree, ex2::JS.SyntaxTree, exs::JS.SyntaxTree...
    )
    to_nospecialize = JS.SyntaxTree[ex1, ex2, exs...]
    JL.@ast(__context__,
            __context__.macrocall::JS.SyntaxTree,
            [JS.K"block" map(st->JL._apply_nospecialize(__context__, st), to_nospecialize)...])
end

function Base.var"@specialize"(__context__::JL.MacroContext)
    JL.@ast(__context__,
            __context__.macrocall::JS.SyntaxTree,
            [JS.K"meta" "specialize"::JS.K"Symbol"])
end

function Base.var"@specialize"(__context__::JL.MacroContext, ex::JS.SyntaxTree)
    JL.@ast(__context__, __context__.macrocall::JS.SyntaxTree, ex)
end

function Base.var"@specialize"(
        __context__::JL.MacroContext,
        ex1::JS.SyntaxTree, ex2::JS.SyntaxTree, exs::JS.SyntaxTree...
    )
    JL.@ast(__context__, __context__.macrocall::JS.SyntaxTree,
            [JS.K"block" ex1 ex2 exs...])
end

# New-style `@kwdef` macro that preserves provenance information.
# This strips default values from struct fields and generates keyword constructors,
# matching the semantics of Base.@kwdef.
function Base.var"@kwdef"(__context__::JL.MacroContext, ex::JS.SyntaxTree)
    JS.kind(ex) === JS.K"struct" ||
        throw(JL.MacroExpansionError(ex, "Invalid usage of @kwdef"))

    type_sig = ex[1]
    type_body = ex[2]

    field_names = JS.SyntaxTree[]
    field_defaults = Union{Nothing,JS.SyntaxTree}[]
    stripped = JS.SyntaxTree[]
    _kwdef_collect_fields!(__context__, type_body, field_names, field_defaults, stripped)

    stripped_body = JL.@ast(__context__, type_body::JS.SyntaxTree,
                           [JS.K"block" stripped...])
    new_struct = JS.mapchildren(_ -> stripped_body, __context__, ex, [2])

    if isempty(field_names)
        return new_struct
    end

    constructors = _kwdef_make_constructors(
        __context__, type_sig, field_names, field_defaults)

    return JL.@ast(__context__, __context__.macrocall::JS.SyntaxTree,
                   [JS.K"block" new_struct constructors...])
end

function _kwdef_collect_fields!(
        ctx::JL.MacroContext, body::JS.SyntaxTree,
        field_names::Vector{JS.SyntaxTree},
        field_defaults::Vector{Union{Nothing,JS.SyntaxTree}},
        stripped::Vector{JS.SyntaxTree})
    for field::JS.SyntaxTree in JS.children(body)
        k = JS.kind(field)
        if k === JS.K"="
            _kwdef_push_field!(field[1], field[2], field_names, field_defaults)
            push!(stripped, field[1])
        elseif k === JS.K"const" && JS.numchildren(field) >= 1 &&
               JS.kind(field[1]) === JS.K"="
            inner = field[1]
            _kwdef_push_field!(inner[1], inner[2], field_names, field_defaults)
            push!(stripped, JS.mapchildren(_ -> inner[1], ctx, field, [1]))
        elseif k === JS.K"block"
            _kwdef_collect_fields!(ctx, field, field_names, field_defaults, stripped)
        else
            name = _kwdef_extract_name(field)
            if name !== nothing
                push!(field_names, name)
                push!(field_defaults, nothing)
            end
            push!(stripped, field)
        end
    end
end

function _kwdef_push_field!(
        decl::JS.SyntaxTree, default::JS.SyntaxTree,
        field_names::Vector{JS.SyntaxTree},
        field_defaults::Vector{Union{Nothing,JS.SyntaxTree}})
    name = _kwdef_extract_name(decl)
    if name !== nothing
        push!(field_names, name)
        push!(field_defaults, default)
    end
end

function _kwdef_extract_name(st::JS.SyntaxTree)
    k = JS.kind(st)
    if k === JS.K"Identifier"
        return st
    elseif k === JS.K"::" && JS.numchildren(st) >= 1
        return _kwdef_extract_name(st[1])
    elseif k === JS.K"const" && JS.numchildren(st) >= 1
        return _kwdef_extract_name(st[1])
    elseif k === JS.K"atomic" && JS.numchildren(st) >= 1
        return _kwdef_extract_name(st[1])
    else
        return nothing
    end
end

function _kwdef_make_constructors(
        ctx::JL.MacroContext, type_sig::JS.SyntaxTree,
        field_names::Vector{JS.SyntaxTree},
        field_defaults::Vector{Union{Nothing,JS.SyntaxTree}})
    mc = __source__ = ctx.macrocall::JS.SyntaxTree

    params = JS.SyntaxTree[]
    for (name::JS.SyntaxTree, default) in zip(field_names, field_defaults)
        if default !== nothing
            push!(params, JL.@ast(ctx, name, [JS.K"kw" name default]))
        else
            push!(params, name)
        end
    end
    parameters = JL.@ast(ctx, mc, [JS.K"parameters" params...])

    if JS.kind(type_sig) === JS.K"Identifier"
        sig = JL.@ast(ctx, mc, [JS.K"call" type_sig parameters])
        body = JL.@ast(ctx, mc, [JS.K"block"
            [JS.K"call" type_sig field_names...]
        ])
        return JS.SyntaxTree[JL.@ast(ctx, mc, [JS.K"function" sig body])]
    elseif JS.kind(type_sig) === JS.K"curly"
        S = type_sig[1]
        P = JS.SyntaxTree[type_sig[i] for i::Int in 2:JS.numchildren(type_sig)]
        Q = JS.SyntaxTree[
            JS.kind(p) === JS.K"<:" ? p[1] : p for p::JS.SyntaxTree in P]
        SQ = JL.@ast(ctx, type_sig, [JS.K"curly" S Q...])

        # def1: S(; a=default, b) = S(a, b)
        sig1 = JL.@ast(ctx, mc, [JS.K"call" S parameters])
        body1 = JL.@ast(ctx, mc, [JS.K"block"
            [JS.K"call" S field_names...]
        ])
        def1 = JL.@ast(ctx, mc, [JS.K"function" sig1 body1])

        # def2: S{T}(; a=default, b) where {T<:Real} = S{T}(a, b)
        sig2_call = JL.@ast(ctx, mc, [JS.K"call" SQ parameters])
        braces = JL.@ast(ctx, mc, [JS.K"braces" P...])
        sig2 = JL.@ast(ctx, mc, [JS.K"where" sig2_call braces])
        body2 = JL.@ast(ctx, mc, [JS.K"block"
            [JS.K"call" SQ field_names...]
        ])
        def2 = JL.@ast(ctx, mc, [JS.K"function" sig2 body2])

        return JS.SyntaxTree[def1, def2]
    else
        throw(JL.MacroExpansionError(
            type_sig, "Invalid type signature for @kwdef"))
    end
end
