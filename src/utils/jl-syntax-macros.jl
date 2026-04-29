# Staging ground for common Base macros defined on SyntaxTree.  These are in
# addition to JuliaLowering.jl/src/syntax_macros.jl, and can be merged there
# when possible.

# TODO: @inline, @noinline, @inbounds, @simd, @assume_effects

"""
    mapchildren(f, ctx, ex, indices::UnitRange{Int})

Like `JS.mapchildren(f, ctx, ex)`, but applies `f` only to children at the
given `indices`, leaving other children unchanged.
"""
function mapchildren(f, ctx, ex::JS.SyntaxTree, indices::UnitRange{<:Integer})
    i = Ref(0)
    JS.mapchildren(ctx, ex) do c
        i[] += 1
        i[] in indices ? f(c) : c
    end
end

@noinline throw_macro_error(node::JS.SyntaxTree, msg::AbstractString) =
    throw(JL.MacroExpansionError(node, msg))

function Base.var"@specialize"(__context__::JL.MacroContext)
    JL.@ast(__context__,
            __context__.macrocall::JS.SyntaxTree,
            [JS.K"meta" "specialize"::JS.K"Identifier"])
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

# Stub new-style implementation of `Threads.@spawn`. The real macro wraps the
# expression in a `Task` and schedules it on a thread pool, but for LSP
# analysis we only care that identifiers in the user-written body keep
# accurate provenance, so the threading constructs are dropped entirely.
#
# `$x` interpolations in the body would normally copy the value of `x` into
# the constructed closure; for scope resolution this is equivalent to a plain
# reference to `x` in the enclosing scope, so we strip the `K"$"` wrappers
# (`unwrap_interpolations`) before returning the body. Without this, a `$`
# surviving outside of a quote context would fail later lowering passes.
#
# The optional threadpool argument is preserved as a sibling in a `block` so
# it shows up in find-references etc. when written as a variable; literal
# `:default`/`:interactive`/`:samepool` symbols remain inert under a
# `K"quote"` and don't pollute scope analysis.
#
# Error reporting mirrors `Base.Threads.@spawn`: an unsupported threadpool and
# the wrong number of arguments both `throw` so that JETLS surfaces them as
# `lowering/macro-expansion-error` diagnostics. The real macro defers the type
# check on the threadpool to runtime (`_spawn_set_thrpool(::Task, ::Symbol)`),
# but we are stricter at expansion time and only accept what we can statically
# tell will (or might at runtime) be one of the allowed pool symbols:
#
# - `:default`, `:interactive`, `:samepool` literals
# - a bare identifier (e.g. `def = :default; Threads.@spawn def body`)
#
# Anything else (other literals, function calls, qualified access, ...) is
# rejected so the user gets immediate LSP feedback.
const _SPAWN_THREADPOOLS = ("interactive", "default", "samepool")

function Base.Threads.var"@spawn"(__context__::JL.MacroContext, ex::JS.SyntaxTree)
    return JL.@ast(__context__, __context__.macrocall::JS.SyntaxTree,
        unwrap_interpolations(ex))
end

function Base.Threads.var"@spawn"(
        __context__::JL.MacroContext,
        threadpool::JS.SyntaxTree, ex::JS.SyntaxTree
    )
    _validate_spawn_threadpool(threadpool)
    return JL.@ast(__context__, __context__.macrocall::JS.SyntaxTree,
        [JS.K"block" threadpool unwrap_interpolations(ex)])
end

function _validate_spawn_threadpool(threadpool::JS.SyntaxTree)
    k = JS.kind(threadpool)
    if k === JS.K"Identifier"
        return # variable reference — assumed to evaluate to a Symbol at runtime
    elseif k === JS.K"inert" && JS.numchildren(threadpool) >= 1
        # Literal symbol form (`:foo` parses as `K"inert"` containing
        # `K"Identifier"`, the EST analog of `QuoteNode(:foo)`).
        inner = threadpool[1]
        if JS.kind(inner) === JS.K"Identifier" && hasproperty(inner, :name_val)
            name = inner.name_val
            if name isa AbstractString
                name in _SPAWN_THREADPOOLS && return
                throw_macro_error(threadpool, "unsupported threadpool in @spawn: $name")
            end
        end
    end
    throw_macro_error(threadpool,
        "threadpool argument in @spawn must be `:default`, `:interactive`, `:samepool`, or a bare variable")
end

function Base.Threads.var"@spawn"(__context__::JL.MacroContext, ::JS.SyntaxTree...)
    throw_macro_error(__context__.macrocall::JS.SyntaxTree,
                 "wrong number of arguments in @spawn")
end

# New-style implementation of `Base.@label`. Mirrors `Base.@goto` in
# `JuliaLowering/src/syntax_macros.jl`: `@label name` lowers to a
# `K"symboliclabel"` so that scope analysis treats the name as a goto target.
#
# The block forms documented in `Base.@label` (`@label expr`, `@label name
# expr`) are intentionally not supported here — the goto-target form is the
# common case and the only one needed for most LSP analyses.
function Base.var"@label"(__context__::JL.MacroContext, ex::JS.SyntaxTree)
    JS.kind(ex) === JS.K"Identifier" ||
        throw_macro_error(ex, "@label requires an identifier")
    return JL.@ast(__context__, ex, [JS.K"symboliclabel" ex])
end

function Base.var"@label"(__context__::JL.MacroContext, ::JS.SyntaxTree...)
    throw_macro_error(__context__.macrocall::JS.SyntaxTree,
        "@label currently only supports the `@label name` form")
end

# New-style `@kwdef` macro that preserves provenance information.
# This strips default values from struct fields and generates keyword constructors,
# matching the semantics of Base.@kwdef.
function Base.var"@kwdef"(__context__::JL.MacroContext, ex::JS.SyntaxTree)
    JS.kind(ex) === JS.K"struct" ||
        throw_macro_error(ex, "Invalid usage of @kwdef")

    # EST struct children: [Value(is_mutable), type_sig, body]
    type_sig = ex[2]
    type_body = ex[3]

    field_names = JS.SyntaxTree[]
    field_defaults = Union{Nothing,JS.SyntaxTree}[]
    stripped = JS.SyntaxTree[]
    _kwdef_collect_fields!(__context__, type_body, field_names, field_defaults, stripped)

    stripped_body = JL.@ast(__context__, type_body::JS.SyntaxTree,
                           [JS.K"block" stripped...])
    new_struct = mapchildren(_ -> stripped_body, __context__, ex, 3:3)

    if isempty(field_names)
        return new_struct
    end

    constructors = _kwdef_make_constructors(
        __context__, type_sig, field_names, field_defaults)

    return JL.@ast(__context__, __context__.macrocall::JS.SyntaxTree,
                   [JS.K"block" new_struct constructors...])
end

function _kwdef_collect_fields!(
        ctx::JL.MacroContext, body::JS.SyntaxTree, field_names::Vector{JS.SyntaxTree},
        field_defaults::Vector{Union{Nothing,JS.SyntaxTree}},
        stripped::Vector{JS.SyntaxTree}
    )
    for field in JS.children(body)
        k = JS.kind(field)
        k === JS.K"Value" && continue
        if k === JS.K"="
            _kwdef_push_field!(field[1], field[2], field_names, field_defaults)
            push!(stripped, field[1])
        elseif k === JS.K"const" && JS.numchildren(field) >= 1 &&
               JS.kind(field[1]) === JS.K"="
            inner = field[1]
            _kwdef_push_field!(inner[1], inner[2], field_names, field_defaults)
            push!(stripped, mapchildren(_ -> inner[1], ctx, field, 1:1))
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
        decl::JS.SyntaxTree, default::JS.SyntaxTree, field_names::Vector{JS.SyntaxTree},
        field_defaults::Vector{Union{Nothing,JS.SyntaxTree}}
    )
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
        ctx::JL.MacroContext, type_sig::JS.SyntaxTree, field_names::Vector{JS.SyntaxTree},
        field_defaults::Vector{Union{Nothing,JS.SyntaxTree}}
    )
    mc = __source__ = ctx.macrocall::JS.SyntaxTree

    if JS.kind(type_sig) === JS.K"<:"
        type_sig = type_sig[1]
    end

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
        sig2 = JL.@ast(ctx, mc, [JS.K"where" sig2_call P...])
        body2 = JL.@ast(ctx, mc, [JS.K"block"
            [JS.K"call" SQ field_names...]
        ])
        def2 = JL.@ast(ctx, mc, [JS.K"function" sig2 body2])

        return JS.SyntaxTree[def1, def2]
    else
        throw_macro_error(type_sig, "Invalid type signature for @kwdef")
    end
end
