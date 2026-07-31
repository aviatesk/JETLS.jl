# Staging ground for common Base macros defined in the new style definitions.
# These are in addition to JuliaLowering.jl/src/syntax_macros.jl,
# and can be merged there when possible.

# TODO: @boundscheck, @simd

"""
    mapchildren(f, ex, indices::UnitRange{Int})

Like `JS.mapchildren(f, ex)`, but applies `f` only to children at the
given `indices`, leaving other children unchanged.
"""
function mapchildren(f, ex::SyntaxTree, indices::UnitRange{<:Integer})
    i = Ref(0)
    JS.mapchildren(ex) do c
        i[] += 1
        i[] in indices ? f(c) : c
    end
end

# `@ast` copies the source tree's `SyntaxContext`. Use a valid, context-free
# `TOMBSTONE` provenance anchor so generated syntax receives the macro-definition
# layer while retaining the original macrocall's source range.
function _macro_generated_source(ctx::JL.MacroContext)
    mc = ctx.macrocall::SyntaxTree
    return JS.newleaf(JS.sourceref(mc), JS.K"TOMBSTONE")
end

const macro_issue_contract = """
# Macro issue contract

When a stub detects a problem, *never throw* — produce a valid recovery expansion so
lowering of the enclosing top-level form (function body, let, etc.) keeps succeeding,
and surface the issue via the sink with the severity Base would assign. A throw would
abort that lowering and take every lowering-based analysis (undef-var, references,
[`TypeAnnotation`](@ref) for hover / inlay / signature-help, …) for the whole
enclosing form down with it.

| helper                        | when                                                  |
|:------------------------------|:------------------------------------------------------|
| [`push_macro_error!`](@ref)   | Base also rejects                                     |
| [`push_macro_warning!`](@ref) | Base accepts silently or only emits `depwarn`         |

Common recovery shapes:

- 0-arg / unrecoverable single arg → `nothing::K"Value"`
- variadic with potentially analyzable args → `[block args...]` (with a trailing
  `nothing::K"Value"` if the original macro returned `nothing`)
- single-arg shape error → flow the arg through unchanged

The helpers feed [`MACRO_DIAGNOSTIC_SINK`](@ref); see its docstring for the
producer/consumer contract. By contrast, when `JL.MacroExpansionError` is thrown directly
(which JuliaLowering itself does on e.g. macro-not-found), `per_stmt_diagnostics!` falls
back to re-lowering the enclosing form with macrocalls stripped — a much coarser recovery
than the sink path.
"""

struct MacroDiagnostic
    node::SyntaxTree
    msg::String
    severity::DiagnosticSeverity.Ty
    code::String
end

"""
    MACRO_DIAGNOSTIC_SINK :: ScopedValue{Union{Nothing,Vector{MacroDiagnostic}}}

Side channel that lets macro stubs surface issues — and purely informational
notes like [`push_inactive_code!`](@ref) — as LSP diagnostics without aborting
expansion; the producer/consumer contract for [`push_macro_error!`](@ref)
and [`push_macro_warning!`](@ref).

Consumers bind this to a vector via `Base.ScopedValues.@with` around their lowering
call and drain it afterwards. Currently only `per_stmt_diagnostics!` does that; the
other lowering consumers (`get_inferrable_tree`, `cursor_bindings`,
`occurrence-analysis`, `document-symbol`) leave the sink unbound, so the push helpers
become no-ops and those consumers simply see the recovered expansion without emitting
diagnostics — which is exactly what makes `TypeAnnotation` etc. keep working across
recoverable macro errors.

Concurrency-safe by construction: `ScopedValue` binds per task and propagates to
child tasks, so the concurrent `per_stmt_diagnostics!` workers spawned under
workspace diagnostic each get their own sink without cross-talk or locking.

See also: [`push_macro_error!`](@ref), [`push_macro_warning!`](@ref)
"""
const MACRO_DIAGNOSTIC_SINK =
    Base.ScopedValues.ScopedValue{Union{Nothing,Vector{MacroDiagnostic}}}(nothing)

@noinline function push_macro_diagnostic!(
        node::SyntaxTree, msg::AbstractString, severity::DiagnosticSeverity.Ty,
        code::String = LOWERING_MACRO_EXPANSION_ERROR_CODE
    )
    sink = MACRO_DIAGNOSTIC_SINK[]
    sink === nothing && return
    push!(sink, MacroDiagnostic(node, String(msg), severity, code))
    return
end

"""
    push_macro_warning!(node::SyntaxTree, msg::AbstractString)

Push a `DiagnosticSeverity.Warning` entry anchored on `node` into
[`MACRO_DIAGNOSTIC_SINK`](@ref) (no-op if the sink is unbound).

$macro_issue_contract
"""
push_macro_warning!(node::SyntaxTree, msg::AbstractString) =
    push_macro_diagnostic!(node, msg, DiagnosticSeverity.Warning)

"""
    push_macro_error!(node::SyntaxTree, msg::AbstractString)

Push a `DiagnosticSeverity.Error` entry anchored on `node` into
[`MACRO_DIAGNOSTIC_SINK`](@ref) (no-op if the sink is unbound).

$macro_issue_contract
"""
push_macro_error!(node::SyntaxTree, msg::AbstractString) =
    push_macro_diagnostic!(node, msg, DiagnosticSeverity.Error)

"""
    push_inactive_code!(node::SyntaxTree, condval::Bool)

Report `node` — a branch dropped at macro expansion time, e.g. the not-taken
side of an `@static` conditional — as `lowering/inactive-code` at Hint severity
into [`MACRO_DIAGNOSTIC_SINK`](@ref) (no-op if the sink is unbound). The
consumer tags these `DiagnosticTag.Unnecessary` so clients render the region
grayed out. Unlike the issue helpers above this is purely informational: the
code is intentionally inactive in the current environment, not a problem.
`condval` is the value the governing condition evaluated to.
"""
push_inactive_code!(node::SyntaxTree, condval::Bool) =
    push_macro_diagnostic!(node,
        "Inactive `@static` branch (condition evaluated to `$condval`)",
        DiagnosticSeverity.Hint, LOWERING_INACTIVE_CODE)

# Macro bindings whose new-style implementations in this file and
# `JuliaLowering/src/syntax_macros.jl` preserve fine-grained source provenance during
# expansion. Unlike old-style macros — whose expansion collapses source positions to
# line granularity and is why `_remove_macrocalls` exists — these don't need to be
# rewritten to a `block` to keep accurate locations for scope resolution.
const NEW_STYLE_MACRO_BINDINGS = (
    # JuliaLowering/src/syntax_macros.jl
    Base => Symbol("@__FUNCTION__"),
    Base => Symbol("@ccall"),
    Base => Symbol("@cfunction"),
    Base => Symbol("@eval"),
    Base => Symbol("@generated"),
    Base => Symbol("@goto"),
    Base => Symbol("@isdefined"),
    Base => Symbol("@locals"),
    Base => Symbol("@nospecialize"),
    # src/utils/jl-syntax-macros.jl
    Base => Symbol("@assert"),
    Base => Symbol("@assume_effects"),
    Base => Symbol("@inbounds"),
    Base => Symbol("@inline"),
    Base => Symbol("@invoke"),
    Base => Symbol("@invokelatest"),
    Base => Symbol("@kwdef"),
    Base => Symbol("@label"),
    Base => Symbol("@lazy_str"),
    Base => Symbol("@lock"),
    Base => Symbol("@noinline"),
    Base => Symbol("@propagate_inbounds"),
    Base => Symbol("@show"),
    Base => Symbol("@something"),
    Base => Symbol("@specialize"),
    Base => Symbol("@static"),
    Base.Threads => Symbol("@spawn"),
    Base.CoreLogging => Symbol("@debug"),
    Base.CoreLogging => Symbol("@error"),
    Base.CoreLogging => Symbol("@info"),
    Base.CoreLogging => Symbol("@logmsg"),
    Base.CoreLogging => Symbol("@warn"),
    Test => Symbol("@inferred"),
    Test => Symbol("@test"),
    Test => Symbol("@test_broken"),
    Test => Symbol("@test_deprecated"),
    Test => Symbol("@test_logs"),
    Test => Symbol("@test_nowarn"),
    Test => Symbol("@test_skip"),
    Test => Symbol("@test_throws"),
    Test => Symbol("@test_warn"),
    Test => Symbol("@testset"),
)

function Base.var"@specialize"(__context__::JL.MacroContext)
    JL.@ast(__context__,
            __context__.macrocall::SyntaxTree,
            [JS.K"meta" "specialize"::JS.K"Identifier"])
end

function Base.var"@specialize"(__context__::JL.MacroContext, ex::SyntaxTree)
    JL.@ast(__context__, __context__.macrocall::SyntaxTree, ex)
end

function Base.var"@specialize"(
        __context__::JL.MacroContext,
        ex1::SyntaxTree, ex2::SyntaxTree, exs::SyntaxTree...
    )
    JL.@ast(__context__, __context__.macrocall::SyntaxTree,
            [JS.K"block" ex1 ex2 exs...])
end

# `@inline` / `@noinline` / `Base.@propagate_inbounds` decorate a function definition
# or a code block with codegen hints. The standard expansion rewrites the wrapped function
# body to inject `Expr(:meta, …)` markers; that produces synthetic nodes whose byte ranges
# don't anchor in the source, breaking surface lookups (inlay hints, hover, …) on the inner
# funcdef. For static analysis the markers have no semantic effect, so we drop them and let
# the wrapped expression flow through with its own provenance intact.
# The 0-arg form keeps the `K"meta"` so scope resolution treats it like the original.
function Base.var"@inline"(__context__::JL.MacroContext)
    JL.@ast(__context__, __context__.macrocall::SyntaxTree,
            [JS.K"meta" "inline"::JS.K"Identifier"])
end

function Base.var"@inline"(__context__::JL.MacroContext, ex::SyntaxTree)
    JL.@ast(__context__, ex, ex)
end

function Base.var"@noinline"(__context__::JL.MacroContext)
    JL.@ast(__context__, __context__.macrocall::SyntaxTree,
            [JS.K"meta" "noinline"::JS.K"Identifier"])
end

function Base.var"@noinline"(__context__::JL.MacroContext, ex::SyntaxTree)
    JL.@ast(__context__, ex, ex)
end

function Base.var"@propagate_inbounds"(__context__::JL.MacroContext, ex::SyntaxTree)
    JL.@ast(__context__, ex, ex)
end

function Base.var"@inbounds"(__context__::JL.MacroContext, ex::SyntaxTree)
    JL.@ast(__context__, ex, ex)
end

# Keep the lock expression in the enclosing scope, but wrap only the protected
# body in a local scope to mirror the `try` scope introduced by Base's macro.
function Base.var"@lock"(
        __context__::JL.MacroContext, lock::SyntaxTree, body::SyntaxTree
    )
    mc = __context__.macrocall::SyntaxTree
    return JL.@ast(__context__, mc,
        [JS.K"block"
            lock
            [JS.K"let"
                [JS.K"block"]
                [JS.K"block" body]]])
end

function Base.var"@lock"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "@lock expects exactly two arguments: `lock body`")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
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

function Base.Threads.var"@spawn"(__context__::JL.MacroContext, ex::SyntaxTree)
    return JL.@ast(__context__, __context__.macrocall::SyntaxTree,
        unwrap_interpolations(ex))
end

function Base.Threads.var"@spawn"(
        __context__::JL.MacroContext,
        threadpool::SyntaxTree, ex::SyntaxTree
    )
    _validate_spawn_threadpool(threadpool)
    return JL.@ast(__context__, __context__.macrocall::SyntaxTree,
        [JS.K"block" threadpool unwrap_interpolations(ex)])
end

function _validate_spawn_threadpool(threadpool::SyntaxTree)
    k = JS.kind(threadpool)
    if k === JS.K"Identifier"
        return # variable reference — assumed to evaluate to a Symbol at runtime
    elseif k === JS.K"inert" && JS.numchildren(threadpool) >= 1
        # Literal symbol form (`:foo` parses as `K"inert"` containing
        # `K"Identifier"`, the EST analog of `QuoteNode(:foo)`).
        inner = threadpool[1]
        if JS.kind(inner) === JS.K"Identifier"
            name = get_name_val(inner)
            if name !== nothing
                name in _SPAWN_THREADPOOLS && return
                # Base defers the threadpool check to runtime; flag it statically as an
                # error but keep expanding so the body (and threadpool identifier, if any)
                # still reaches scope analysis.
                push_macro_error!(threadpool, "unsupported threadpool in @spawn: $name")
                return
            end
        end
    end
    push_macro_error!(threadpool,
        "threadpool argument in @spawn must be `:default`, `:interactive`, `:samepool`, or a bare variable")
    nothing
end

function Base.Threads.var"@spawn"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "wrong number of arguments in @spawn")
    # Recovery: flow whatever the user wrote through scope analysis. 0-arg →
    # `nothing`, ≥3-arg → a block of every arg so identifiers inside stay visible.
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args... nothing::JS.K"Value"])
end

# New-style implementation of `Base.@label`. Mirrors `Base.@goto` in
# `JuliaLowering/src/syntax_macros.jl`: `@label name` lowers to a
# `K"symboliclabel"` so that scope analysis treats the name as a goto target.
#
# The block forms documented in `Base.@label` (`@label expr`, `@label name
# expr`) are intentionally not supported here — the goto-target form is the
# common case and the only one needed for most LSP analyses.
function Base.var"@label"(__context__::JL.MacroContext, ex::SyntaxTree)
    if JS.kind(ex) !== JS.K"Identifier"
        push_macro_error!(ex, "@label requires an identifier")
        # Recovery: let the expression flow through so any identifier inside still
        # reaches scope analysis. Goto-target semantics are lost.
        return JL.@ast(__context__, __context__.macrocall::SyntaxTree, ex)
    end
    # Keep the label token's exact range without inheriting its caller context, so
    # macro expansion records the originating `@label` call in `SyntaxContext`.
    src = JS.sourceref(ex)
    return JL.@ast(__context__, ex, [JS.K"symboliclabel"(src; context=nothing) ex])
end

function Base.var"@label"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc,
        "@label currently only supports the `@label name` form")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

# New-style implementation of `Base.@something`. The macro is sometimes called with arguments
# that themselves contain control flow (e.g. `@something(x, return default)`, `@something(x, @goto fallback)`).
# Mirroring Base's nested `let val_i = arg_i; if !isnothing(val_i) something(val_i) else <next> end end`
# chain as a new-style macro lets JuliaLowering model that control flow accurately in the
# CFG, so LSP analyses (`lowering/unreachable-code`, `lowering/undef-local-var`, ...)
# account for which paths each arg's body actually executes on.  The fresh `val_i` names
# live in the macro's scope layer so they cannot clash with user code.
function Base.var"@something"(__context__::JL.MacroContext, args::SyntaxTree...)
    src = _macro_generated_source(__context__)
    expr = JL.@ast(__context__, src,
        [JS.K"call"
            [JS.K"top" "something"::JS.K"Identifier"]
            nothing::JS.K"Value"])
    for i in length(args):-1:1
        arg = args[i]
        val_name = "val_$i"
        expr = JL.@ast(__context__, src, [JS.K"let"
            [JS.K"block"
                [JS.K"=" val_name::JS.K"Identifier" arg]]
            [JS.K"block"
                [JS.K"if"
                    [JS.K"call"
                        [JS.K"top" "isnothing"::JS.K"Identifier"]
                        val_name::JS.K"Identifier"]
                    expr
                    [JS.K"call"
                        [JS.K"top" "something"::JS.K"Identifier"]
                        val_name::JS.K"Identifier"]]]])
    end
    return expr
end

# New-style implementation of `Base.@lazy_str`. Surface string macros arrive as
# raw `K"String"` payloads, while string macros nested inside old-style macro
# expansions arrive as `K"Value"` strings. In both cases `$` interpolations are
# not parsed into child nodes yet. Mirror Base's `Meta.parseatom` loop using
# JuliaSyntax, then copy each parsed interpolation back into the macro context
# with source ranges remapped when source text is available and scope adopted
# from the call site.
function Base.var"@lazy_str"(__context__::JL.MacroContext, text::SyntaxTree)
    mc = __context__.macrocall::SyntaxTree
    if !(text.value isa String)
        push_macro_error!(text, "@lazy_str expects a string literal")
        return JL.@ast(__context__, mc, text)
    end
    value = text.value::String
    raw = if JS.kind(text) === JS.K"String"
        String(JS.sourcetext(text))
    elseif JS.kind(text) === JS.K"Value"
        value
    else
        push_macro_error!(text, "@lazy_str expects a string literal")
        return JL.@ast(__context__, mc, text)
    end
    source_map = _lazy_str_source_map(value, raw)
    parts = _lazy_str_parts(__context__, text, value, source_map)
    src = _macro_generated_source(__context__)
    return JL.@ast(__context__, src,
        [JS.K"call" [JS.K"top" "LazyString"::JS.K"Identifier"] parts...])
end

function Base.var"@lazy_str"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "@lazy_str expects exactly one string argument")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

function _lazy_str_parts(
        ctx::JL.MacroContext, text::SyntaxTree, value::String, source_map::Dict{Int,Int}
    )
    parts = SyntaxTree[]
    isempty(value) && return parts
    lastidx = idx = firstindex(value)
    while true
        dollar = findnext('$', value, idx)
        dollar === nothing && break
        if lastidx < dollar
            push!(parts, _lazy_str_literal_part(text, value, source_map, lastidx, prevind(value, dollar)))
        end
        atom_start = nextind(value, dollar)
        if atom_start > lastindex(value)
            push_macro_error!(text, "@lazy_str: invalid interpolation")
            push!(parts, _lazy_str_literal_part(text, value, source_map, dollar, lastindex(value)))
            return parts
        end
        parsed, nextidx = @something _lazy_str_parse_interpolation(
            ctx, text, value, source_map, atom_start) begin
            push!(parts, _lazy_str_literal_part(text, value, source_map, dollar, lastindex(value)))
            return parts
        end
        push!(parts, parsed)
        lastidx = idx = nextidx
    end
    if lastidx <= lastindex(value)
        push!(parts, _lazy_str_literal_part(text, value, source_map, lastidx, lastindex(value)))
    end
    return parts
end

function _lazy_str_source_map(value::String, raw::String)
    if startswith(raw, "\"\"\"") && endswith(raw, "\"\"\"")
        return _lazy_str_triple_source_map(value, raw)
    end
    return _lazy_str_linear_source_map(value, raw)
end

function _lazy_str_linear_source_map(value::String, raw::String)
    value_to_raw = Dict{Int,Int}()
    vi = firstindex(value)
    ri = firstindex(raw)
    value_to_raw[vi] = ri
    while vi <= lastindex(value) && ri <= lastindex(raw)
        vi, ri = _lazy_str_step_source_map!(value_to_raw, value, raw, vi, ri)
    end
    return value_to_raw
end

function _lazy_str_triple_source_map(value::String, raw::String)
    value_to_raw = Dict{Int,Int}()
    vi = firstindex(value)
    ri = nextind(raw, firstindex(raw), 3)
    closing = prevind(raw, lastindex(raw), 2)
    payload_end = prevind(raw, closing)
    if ri <= payload_end && raw[ri] == '\n'
        ri = nextind(raw, ri)
    elseif ri <= payload_end && raw[ri] == '\r'
        ri_next = nextind(raw, ri)
        if ri_next <= payload_end && raw[ri_next] == '\n'
            ri = nextind(raw, ri_next)
        end
    end
    indent = _lazy_str_closing_indent(raw, closing)
    value_to_raw[vi] = _lazy_str_skip_dedent(raw, ri, payload_end, indent)
    ri = value_to_raw[vi]
    while vi <= lastindex(value) && ri <= payload_end
        ri = _lazy_str_skip_dedent(raw, ri, payload_end, indent)
        value_to_raw[vi] = ri
        ri <= payload_end || break
        vi, ri = _lazy_str_step_source_map!(value_to_raw, value, raw, vi, ri)
    end
    return value_to_raw
end

function _lazy_str_step_source_map!(
        value_to_raw::Dict{Int,Int}, value::String, raw::String, vi::Int, ri::Int
    )
    vc = value[vi]
    vi_next = nextind(value, vi)
    ri_next = nextind(raw, ri)
    if raw[ri] == vc
        value_to_raw[vi_next] = ri_next
    elseif raw[ri] == '\\' && ri_next <= lastindex(raw) && raw[ri_next] == vc
        value_to_raw[vi_next] = nextind(raw, ri_next)
    else
        value_to_raw[vi_next] = ri_next
    end
    return vi_next, value_to_raw[vi_next]
end

function _lazy_str_closing_indent(raw::String, closing::Int)
    line_start = closing
    while line_start > firstindex(raw)
        prev = prevind(raw, line_start)
        raw[prev] == '\n' && break
        line_start = prev
    end
    return raw[line_start:prevind(raw, closing)]
end

function _lazy_str_skip_dedent(
        raw::String, ri::Int, payload_end::Int, indent::AbstractString
    )
    isempty(indent) && return ri
    if ri > firstindex(raw) && raw[prevind(raw, ri)] != '\n'
        return ri
    end
    i = ri
    for c in indent
        i <= payload_end && raw[i] == c || return ri
        i = nextind(raw, i)
    end
    return i
end

function _lazy_str_literal_part(
        text::SyntaxTree, value::String,
        source_map::Dict{Int,Int}, startidx::Int, stopidx::Int
    )
    src = JS.sourceref(text)
    if src isa JS.SourceRef
        srcref = _lazy_str_source_ref(text, src, value, source_map, startidx, stopidx)
        return JS.newleaf(srcref, JS.K"String", value[startidx:stopidx])
    end
    return JS.newleaf(text, JS.K"String", value[startidx:stopidx])
end

function _lazy_str_parse_interpolation(
        ctx::JL.MacroContext, text::SyntaxTree, value::String,
        source_map::Dict{Int,Int}, idx::Int
    )
    parsed, nextidx = try
        JS.parseatom(JS.SyntaxTree, value, idx; ignore_errors=false)
    catch err
        msg = first(split(sprint(showerror, err), '\n'))
        push_macro_error!(text, "@lazy_str: failed to parse interpolation: $msg")
        return nothing
    end
    src = JS.sourceref(text)
    copied = if src isa JS.SourceRef
        _lazy_str_copy_with_source(parsed, text, src, value, source_map)
    else
        parsed
    end
    return JL.adopt_scope(ctx.macrocall, copied), nextidx
end

function _lazy_str_copy_with_source(
        node::JS.SyntaxTree, text::SyntaxTree, src::JS.SourceRef,
        value::String, source_map::Dict{Int,Int}
    )
    srcref = _lazy_str_source_ref(text, src, value, source_map, JS.first_byte(node), JS.last_byte(node))
    children = if JS.is_leaf(node)
        nothing
    else
        cs = JS.SyntaxList()
        for child in JS.children(node)
            push!(cs, _lazy_str_copy_with_source(child, text, src, value, source_map))
        end
        cs
    end
    return JL.@mknode(node; source=srcref, children)
end

function _lazy_str_source_ref(
        text::SyntaxTree, src::JS.SourceRef, value::String, source_map::Dict{Int,Int},
        startidx::Int, stopbyte::Int
    )
    stopidx = thisind(value, stopbyte)
    raw_start = get(source_map, startidx, startidx)
    afteridx = nextind(value, stopidx)
    raw_after = get(source_map, afteridx, afteridx)
    first_byte = JS.first_byte(text) + raw_start - 1
    last_byte = JS.first_byte(text) + raw_after - 2
    return JS.SourceRef(src.file, UInt32(first_byte), UInt32(last_byte))
end

# Stub for `Base.@assert`. Mirrors the real expansion
# `cond ? nothing : throw(AssertionError(msg))` so that downstream control-flow analyses
# (`lowering/undef-local-var`, `lowering/unreachable-code`, ...) correctly model the
# assertion as a guard: code following `@assert cond` may assume `cond` was true, and any
# unreachable branch (e.g. `@assert false; ...`) is recognized.
#
# When no user message is supplied, the source text of the condition is spliced in as
# a static string placeholder, matching Base's `string(ex)` fallback. Base's `@assert`
# accepts any number of trailing message arguments and silently uses only the first;
# we mirror that leniency, but route extras through a leading `block` so identifiers
# inside (e.g. an interpolated `"got $y"`) still get scope-resolved.
function Base.var"@assert"(__context__::JL.MacroContext)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "@assert: at least one argument is required")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

function Base.var"@assert"(
        __context__::JL.MacroContext, ex::SyntaxTree, msgs::SyntaxTree...
    )
    src = _macro_generated_source(__context__)
    msg_arg = isempty(msgs) ?
        JL.@ast(__context__, src, JS.sourcetext(ex)::JS.K"Value") :
        msgs[1]
    if_throw = JL.@ast(__context__, src, [JS.K"if" ex
        nothing::JS.K"Value"
        [JS.K"call" [JS.K"core" "throw"::JS.K"Identifier"]
            [JS.K"call"
                [JS.K"core" "AssertionError"::JS.K"Identifier"]
                msg_arg]]])
    length(msgs) <= 1 && return if_throw
    extras = msgs[2:end]
    return JL.@ast(__context__, src, [JS.K"block" extras... if_throw])
end

# Stub for `Base.@show`. The real macro emits per-argument
# `println("ex = ", repr(ex))` scaffolding and returns the last argument's value
# (or `nothing` for the zero-arg form); for LSP analysis we only need each
# user-written expression to flow through with its provenance intact, so we
# drop the printing and route the args through a `block` whose final value
# naturally matches Base's return semantics.
function Base.var"@show"(__context__::JL.MacroContext, exs::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    isempty(exs) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    length(exs) == 1 && return JL.@ast(__context__, mc, exs[1])
    return JL.@ast(__context__, mc, [JS.K"block" exs...])
end

# Stubs for `Base.CoreLogging.@debug` / `@info` / `@warn` / `@error` / `@logmsg`.
# The real macros wrap the message+kwargs evaluation in try/catch, dispatch
# through the active logger, and emit a lot of compile-time metadata
# (`_module` / `_group` / `_id` / `_file` / `_line`); for LSP analysis we only
# need each user-written expression to flow through with its provenance intact,
# so we drop the logging scaffolding and route the args through a `block` whose
# trailing `nothing::K"Value"` matches Base's "always returns `nothing`"
# contract.
#
# Argument shapes accepted (mirroring Base's `process_logmsg_exs`):
# - `key=value` kwargs (including the `_module` / `_group` / `_id` / `_file` /
#   `_line` metadata overrides): the RHS flows through and the `K"="` wrapper
#   is dropped so it doesn't reach later lowering passes.
# - `xs...` splatting: the spliced expression flows through, with the `K"..."`
#   wrapper dropped for the same reason.
# - Bare positional arguments: passed through as-is (Base auto-converts each
#   to `Symbol(ex) => ex` at expansion time, but for scope analysis only the
#   value side matters).
#
# Duplicate kwarg names are rejected at expansion time. Base would let the
# expansion succeed and only fail at lowering of the synthesized
# `(; k=1, k=2)` named tuple with a generic `syntax: field name "k" repeated`
# error; surfacing the duplicate as a `lowering/macro-expansion-error` here
# anchors the diagnostic on the user's `@info` call site instead.
function Base.CoreLogging.var"@debug"(
        __context__::JL.MacroContext, message::SyntaxTree, exs::SyntaxTree...
    )
    return _logmsg_stub(__context__, (message, exs...), "@debug")
end

function Base.CoreLogging.var"@debug"(__context__::JL.MacroContext)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "@debug requires at least one argument: a `message`")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

function Base.CoreLogging.var"@info"(
        __context__::JL.MacroContext, message::SyntaxTree, exs::SyntaxTree...
    )
    return _logmsg_stub(__context__, (message, exs...), "@info")
end

function Base.CoreLogging.var"@info"(__context__::JL.MacroContext)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "@info requires at least one argument: a `message`")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

function Base.CoreLogging.var"@warn"(
        __context__::JL.MacroContext, message::SyntaxTree, exs::SyntaxTree...
    )
    return _logmsg_stub(__context__, (message, exs...), "@warn")
end

function Base.CoreLogging.var"@warn"(__context__::JL.MacroContext)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "@warn requires at least one argument: a `message`")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

function Base.CoreLogging.var"@error"(
        __context__::JL.MacroContext, message::SyntaxTree, exs::SyntaxTree...
    )
    return _logmsg_stub(__context__, (message, exs...), "@error")
end

function Base.CoreLogging.var"@error"(__context__::JL.MacroContext)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "@error requires at least one argument: a `message`")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

# `@logmsg` adds a leading `level` argument. The level is a user-written
# expression (a `LogLevel` constant or computed value), so it still needs to
# flow through to scope resolution.
function Base.CoreLogging.var"@logmsg"(
        __context__::JL.MacroContext, level::SyntaxTree, message::SyntaxTree,
        exs::SyntaxTree...
    )
    return _logmsg_stub(__context__, (level, message, exs...), "@logmsg")
end

function Base.CoreLogging.var"@logmsg"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc,
        "@logmsg requires at least two arguments: a `level` and a `message`")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args... nothing::JS.K"Value"])
end

function _logmsg_stub(
        ctx::JL.MacroContext, exs::Tuple{Vararg{SyntaxTree}}, name::AbstractString
    )
    mc = ctx.macrocall::SyntaxTree
    children = SyntaxTree[]
    seen_kws = Set{String}()
    for ex in exs
        k = JS.kind(ex)
        if k === JS.K"="
            if JS.numchildren(ex) != 2
                push_macro_error!(ex, "$name: malformed keyword argument")
                continue
            end
            key = ex[1]
            kwname = JS.kind(key) === JS.K"Identifier" ? get_name_val(key) : nothing
            if kwname !== nothing
                if kwname in seen_kws
                    # Base would let the synthesized `(; k=…, k=…)` named tuple fail
                    # lowering; flag the dup here but keep the RHS in `children` so
                    # any identifier inside still gets scope-resolved.
                    push_macro_error!(ex, "$name: keyword `$kwname` provided more than once")
                else
                    push!(seen_kws, kwname)
                end
            end
            push!(children, ex[2])
        elseif k === JS.K"..."
            if JS.numchildren(ex) >= 1
                push!(children, ex[1])
            else
                push_macro_error!(ex, "$name: malformed splat argument")
            end
        else
            push!(children, ex)
        end
    end
    return JL.@ast(ctx, mc, [JS.K"block" children... nothing::JS.K"Value"])
end

# New-style implementations of `Base.@invoke` / `Base.@invokelatest`. These match Base's
# expansion (`Core.invoke(f, Tuple{T1,...}, args...)` / `Base.invokelatest(f, args...)`)
# rather than routing the body through unchanged, so type inference (e.g.
# `TypeAnnotation`) sees the actual `Core.invoke` / `Base.invokelatest` call and not the
# surface-syntax call. The same call shapes Base's `destructure_callex` handles are
# accepted (`f(args...; kwargs...)`, `x.f`, `xs[i]`, `x.f = v`, `xs[i] = v`); other shapes
# are rejected at expansion time with a clear message.
function Base.var"@invoke"(__context__::JL.MacroContext, ex::SyntaxTree)
    destructured = _destructure_invoke_callex(__context__, ex, "@invoke")
    destructured === nothing &&
        return JL.@ast(__context__, __context__.macrocall::SyntaxTree, ex)
    f, args, kwargs = destructured
    return _build_invoke_call(__context__, ex, f, args, kwargs)
end

function Base.var"@invoke"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc,
        "@invoke expects exactly one argument: `f(args...; kwargs...)` (or one of `x.f`, `xs[i]`, `x.f = v`, `xs[i] = v`)")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

function Base.var"@invokelatest"(__context__::JL.MacroContext, ex::SyntaxTree)
    destructured = _destructure_invoke_callex(__context__, ex, "@invokelatest")
    destructured === nothing &&
        return JL.@ast(__context__, __context__.macrocall::SyntaxTree, ex)
    f, args, kwargs = destructured
    return _build_invokelatest_call(__context__, f, args, kwargs)
end

function Base.var"@invokelatest"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc,
        "@invokelatest expects exactly one argument: `f(args...; kwargs...)` (or one of `x.f`, `xs[i]`, `x.f = v`, `xs[i] = v`)")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

# Mirror of Base's `destructure_callex` for EST: returns `(f, args, kwargs)` where
# `f` is the function (already a `K"top"` reference for the synthesized `getproperty`,
# `setindex!`, etc. forms), `args` are the positional arguments, and `kwargs` are the
# raw `K"kw"` nodes (collected from both bare-`kw` children and `K"parameters"` blocks).
# Returns `nothing` when `ex` doesn't match any accepted shape; the caller is
# responsible for falling back to a recovery expansion.
function _destructure_invoke_callex(
        ctx::JL.MacroContext, ex::SyntaxTree, m::AbstractString
    )
    k = JS.kind(ex)
    if k === JS.K"call"
        f = ex[1]
        args = SyntaxTree[]
        kwargs = SyntaxTree[]
        for i in 2:JS.numchildren(ex)
            child = ex[i]
            ck = JS.kind(child)
            if ck === JS.K"parameters"
                for kw in JS.children(child)
                    push!(kwargs, kw)
                end
            elseif ck === JS.K"kw"
                push!(kwargs, child)
            else
                push!(args, child)
            end
        end
        return f, args, kwargs
    elseif k === JS.K"."
        # `x.f` -> getproperty(x, :f). `ex[2]` is the `K"inert"`-wrapped field name.
        f = JL.@ast(ctx, ex, [JS.K"top" "getproperty"::JS.K"Identifier"])
        return f, SyntaxTree[ex[1], ex[2]], SyntaxTree[]
    elseif k === JS.K"ref"
        # `xs[i, j, ...]` -> getindex(xs, i, j, ...).
        f = JL.@ast(ctx, ex, [JS.K"top" "getindex"::JS.K"Identifier"])
        args = SyntaxTree[ex[i] for i in 1:JS.numchildren(ex)]
        return f, args, SyntaxTree[]
    elseif k === JS.K"=" && JS.numchildren(ex) == 2
        lhs, rhs = ex[1], ex[2]
        lhs_k = JS.kind(lhs)
        if lhs_k === JS.K"."
            # `x.f = v` -> setproperty!(x, :f, v).
            f = JL.@ast(ctx, ex, [JS.K"top" "setproperty!"::JS.K"Identifier"])
            return f, SyntaxTree[lhs[1], lhs[2], rhs], SyntaxTree[]
        elseif lhs_k === JS.K"ref"
            # `xs[i, ...] = v` -> setindex!(xs, v, i, ...).
            args = SyntaxTree[lhs[1], rhs]
            for i in 2:JS.numchildren(lhs)
                push!(args, lhs[i])
            end
            f = JL.@ast(ctx, ex, [JS.K"top" "setindex!"::JS.K"Identifier"])
            return f, args, SyntaxTree[]
        end
        push_macro_error!(ex,
            "$m: expected a `setproperty!` expression `x.f = v` or `setindex!` expression `x[i] = v`")
        return nothing
    end
    push_macro_error!(ex,
        "$m: expected a `:call` expression `f(args...; kwargs...)`")
    return nothing
end

# Build `Core.invoke(f, Tuple{T1, ...}, x, ...)`, mirroring Base's expansion. Each `x::T`
# arg has its annotation stripped, with `T` going into the types tuple; a bare `x` arg
# gets `Core.Typeof(x)` as its placeholder type.
function _build_invoke_call(
        ctx::JL.MacroContext, srcref::SyntaxTree,
        f::SyntaxTree, args::Vector{SyntaxTree}, kwargs::Vector{SyntaxTree}
    )
    types = SyntaxTree[]
    new_args = SyntaxTree[]
    for arg in args
        if JS.kind(arg) === JS.K"::" && JS.numchildren(arg) == 2
            push!(new_args, arg[1])
            push!(types, arg[2])
        else
            push!(new_args, arg)
            push!(types, JL.@ast(ctx, arg,
                [JS.K"call" [JS.K"core" "Typeof"::JS.K"Identifier"] arg]))
        end
    end
    types_tuple = JL.@ast(ctx, srcref,
        [JS.K"curly" [JS.K"core" "Tuple"::JS.K"Identifier"] types...])
    mc = ctx.macrocall::SyntaxTree
    if isempty(kwargs)
        return JL.@ast(ctx, mc, [JS.K"call"
            [JS.K"core" "invoke"::JS.K"Identifier"]
            f
            types_tuple
            new_args...])
    end
    return JL.@ast(ctx, mc, [JS.K"call"
        [JS.K"core" "invoke"::JS.K"Identifier"]
        [JS.K"parameters" kwargs...]
        f
        types_tuple
        new_args...])
end

# Build `Base.invokelatest(f, args...)`. We intentionally skip Base's `invokelatest_gr`
# optimization (which special-cases globally-bound `f` via `GlobalRef`) since it doesn't
# affect what user identifiers reach scope/type analysis.
function _build_invokelatest_call(
        ctx::JL.MacroContext,
        f::SyntaxTree, args::Vector{SyntaxTree}, kwargs::Vector{SyntaxTree}
    )
    mc = ctx.macrocall::SyntaxTree
    if isempty(kwargs)
        return JL.@ast(ctx, mc, [JS.K"call"
            [JS.K"top" "invokelatest"::JS.K"Identifier"]
            f
            args...])
    end
    return JL.@ast(ctx, mc, [JS.K"call"
        [JS.K"top" "invokelatest"::JS.K"Identifier"]
        [JS.K"parameters" kwargs...]
        f
        args...])
end

# New-style `@kwdef` macro that preserves provenance information.
# This strips default values from struct fields and generates keyword constructors,
# matching the semantics of Base.@kwdef.
function Base.var"@kwdef"(__context__::JL.MacroContext, ex::SyntaxTree)
    if JS.kind(ex) !== JS.K"struct"
        push_macro_error!(ex, "Invalid usage of @kwdef")
        # Recovery: let the argument flow through unchanged so e.g. a half-typed
        # struct or an accidentally-decorated function still reaches scope analysis.
        return JL.@ast(__context__, __context__.macrocall::SyntaxTree, ex)
    end

    # EST struct children: [Value(is_mutable), type_sig, body]
    type_sig = ex[2]
    type_body = ex[3]

    field_names = SyntaxTree[]
    field_defaults = Union{Nothing,SyntaxTree}[]
    stripped = SyntaxTree[]
    _kwdef_collect_fields!(__context__, type_body, field_names, field_defaults, stripped)

    stripped_body = JL.@ast(__context__, type_body::SyntaxTree,
                           [JS.K"block" stripped...])
    new_struct = mapchildren(_ -> stripped_body, ex, 3:3)

    if isempty(field_names)
        return new_struct
    end

    constructors = _kwdef_make_constructors(
        __context__, type_sig, field_names, field_defaults)

    return JL.@ast(__context__, __context__.macrocall::SyntaxTree,
                   [JS.K"block" new_struct constructors...])
end

function _kwdef_collect_fields!(
        ctx::JL.MacroContext, body::SyntaxTree, field_names::Vector{SyntaxTree},
        field_defaults::Vector{Union{Nothing,SyntaxTree}},
        stripped::Vector{SyntaxTree}
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
            push!(stripped, mapchildren(_ -> inner[1], field, 1:1))
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
        decl::SyntaxTree, default::SyntaxTree, field_names::Vector{SyntaxTree},
        field_defaults::Vector{Union{Nothing,SyntaxTree}}
    )
    name = _kwdef_extract_name(decl)
    if name !== nothing
        push!(field_names, name)
        push!(field_defaults, default)
    end
end

function _kwdef_extract_name(st::SyntaxTree)
    while true
        k = JS.kind(st)
        if k === JS.K"Identifier"
            return st
        elseif (k === JS.K"::" || k === JS.K"const" || k === JS.K"atomic") &&
               JS.numchildren(st) >= 1
            st = st[1]
        else
            return nothing
        end
    end
end

function _kwdef_make_constructors(
        ctx::JL.MacroContext, type_sig::SyntaxTree, field_names::Vector{SyntaxTree},
        field_defaults::Vector{Union{Nothing,SyntaxTree}}
    )
    mc = __source__ = ctx.macrocall::SyntaxTree

    if JS.kind(type_sig) === JS.K"<:"
        type_sig = type_sig[1]
    end

    params = SyntaxTree[]
    for (name, default) in zip(field_names, field_defaults)
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
        return SyntaxTree[JL.@ast(ctx, mc, [JS.K"function" sig body])]
    elseif JS.kind(type_sig) === JS.K"curly"
        S = type_sig[1]
        P = SyntaxTree[type_sig[i] for i::Int in 2:JS.numchildren(type_sig)]
        Q = SyntaxTree[JS.kind(p) === JS.K"<:" ? p[1] : p for p in P]
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

        return SyntaxTree[def1, def2]
    else
        # Recovery: emit no constructors. The bare (stripped) struct definition
        # still reaches downstream lowering.
        push_macro_error!(type_sig, "Invalid type signature for @kwdef")
        return SyntaxTree[]
    end
end

# Stubs for `Test.jl` testing macros. The real macros wrap user-written bodies in
# test-recording / exception-catching / setup scaffolding; for LSP scope analysis we only
# need each user-written sub-expression to flow through with its provenance intact, so we
# drop the scaffolding and either return the body alone or emit a `block` so identifiers
# inside every argument are visible to the resolver.
#
# For macros with the `body kws...` shape (`@test`, `@test_broken`, `@test_skip`,
# `@test_logs`) we keep only the kw RHS so any user-written identifier there still gets
# scope-resolved (e.g. `broken=flag` flows `flag` through to undef-var / reference
# analysis), and drop the `K"="` wrapper itself so it doesn't reach later lowering passes.
function Test.var"@test"(__context__::JL.MacroContext, ex::SyntaxTree, kws::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    seen_broken = seen_skip = seen_context = nothing
    rhss = SyntaxTree[]
    # Base `extract_broken_skip_kws` hard-errors on dup or `skip`+`broken`; we report
    # as Error but keep every RHS in the block so identifiers inside (e.g. dup values)
    # still reach scope analysis.
    for kw in kws
        name = _validate_test_kw(kw)
        name === nothing && continue # malformed kw already reported via sink
        push!(rhss, kw[2])
        if name == "broken"
            seen_broken === nothing || push_macro_error!(kw,
                "invalid test macro call: cannot set `broken` keyword multiple times")
            seen_broken = kw
        elseif name == "skip"
            seen_skip === nothing || push_macro_error!(kw,
                "invalid test macro call: cannot set `skip` keyword multiple times")
            seen_skip = kw
        elseif name == "context"
            seen_context === nothing || push_macro_error!(kw,
                "invalid test macro call: cannot set `context` keyword multiple times")
            seen_context = kw
        end
    end
    if seen_skip !== nothing && seen_broken !== nothing
        push_macro_error!(mc,
            "invalid test macro call: cannot set both `skip` and `broken` keywords")
    end
    isempty(rhss) && return JL.@ast(__context__, mc, ex)
    return JL.@ast(__context__, mc, [JS.K"block" rhss... ex])
end

function Test.var"@test_broken"(
        __context__::JL.MacroContext, ex::SyntaxTree, kws::SyntaxTree...
    )
    mc = __context__.macrocall::SyntaxTree
    rhss = SyntaxTree[]
    for kw in kws
        _validate_test_kw(kw) === nothing && continue
        push!(rhss, kw[2])
    end
    isempty(rhss) && return JL.@ast(__context__, mc, ex)
    return JL.@ast(__context__, mc, [JS.K"block" rhss... ex])
end

function Test.var"@test_skip"(
        __context__::JL.MacroContext, ex::SyntaxTree, kws::SyntaxTree...
    )
    mc = __context__.macrocall::SyntaxTree
    rhss = SyntaxTree[]
    for kw in kws
        _validate_test_kw(kw) === nothing && continue
        push!(rhss, kw[2])
    end
    isempty(rhss) && return JL.@ast(__context__, mc, ex)
    return JL.@ast(__context__, mc, [JS.K"block" rhss... ex])
end

function Test.var"@test_throws"(
        __context__::JL.MacroContext, extype::SyntaxTree, ex::SyntaxTree
    )
    return JL.@ast(__context__, __context__.macrocall::SyntaxTree,
        [JS.K"block" extype ex])
end

function Test.var"@test_throws"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc,
        "@test_throws expects exactly two arguments: `extype` and `ex`")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

function Test.var"@test_warn"(
        __context__::JL.MacroContext, msg::SyntaxTree, ex::SyntaxTree
    )
    return JL.@ast(__context__, __context__.macrocall::SyntaxTree,
        [JS.K"block" msg ex])
end

function Test.var"@test_nowarn"(__context__::JL.MacroContext, ex::SyntaxTree)
    return JL.@ast(__context__, __context__.macrocall::SyntaxTree, ex)
end

function Test.var"@test_logs"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    if isempty(args)
        push_macro_error!(mc, "@test_logs needs at least one argument")
        return JL.@ast(__context__, mc, nothing::JS.K"Value")
    end
    body = last(args)
    block_children = SyntaxTree[]
    for i in 1:length(args)-1
        arg = args[i]
        if JS.kind(arg) === JS.K"="
            _validate_test_kw(arg) === nothing && continue
            push!(block_children, arg[2])
        else
            push!(block_children, arg)
        end
    end
    push!(block_children, body)
    return JL.@ast(__context__, mc, [JS.K"block" block_children...])
end

function Test.var"@test_deprecated"(__context__::JL.MacroContext, ex::SyntaxTree)
    return JL.@ast(__context__, __context__.macrocall::SyntaxTree, ex)
end

function Test.var"@test_deprecated"(
        __context__::JL.MacroContext, pattern::SyntaxTree, ex::SyntaxTree
    )
    return JL.@ast(__context__, __context__.macrocall::SyntaxTree,
        [JS.K"block" pattern ex])
end

function Test.var"@test_deprecated"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc,
        "@test_deprecated expects one or two arguments: `[pattern] expr`")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

function Test.var"@inferred"(__context__::JL.MacroContext, ex::SyntaxTree)
    return JL.@ast(__context__, __context__.macrocall::SyntaxTree, ex)
end

function Test.var"@inferred"(
        __context__::JL.MacroContext, allow::SyntaxTree, ex::SyntaxTree
    )
    return JL.@ast(__context__, __context__.macrocall::SyntaxTree,
        [JS.K"block" allow ex])
end

function Test.var"@inferred"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "@inferred expects one or two arguments: `[allow] ex`")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

function _validate_test_kw(kw::SyntaxTree)
    if JS.kind(kw) !== JS.K"="
        push_macro_error!(kw, "invalid test macro call: expected `keyword=value`")
        return nothing
    end
    if JS.numchildren(kw) != 2
        push_macro_error!(kw, "invalid test macro call: malformed keyword argument")
        return nothing
    end
    name = kw[1]
    if !(JS.kind(name) === JS.K"Identifier" && has_name_val(name))
        push_macro_error!(name, "invalid test macro call: keyword name must be an identifier")
        return nothing
    end
    return name_val(name)
end

function Test.var"@testset"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    if isempty(args)
        push_macro_error!(mc, "No arguments to @testset")
        return JL.@ast(__context__, mc, nothing::JS.K"Value")
    end

    body = last(args)
    if JS.kind(body) ∉ JS.KSet"for block call let"
        # Recovery: let the body flow through anyway. Wrapped in `let` below so its
        # bindings still get the testset-local scope treatment.
        push_macro_error!(body,
            "@testset: body argument must be a `for`, `begin`/`end`, function call, or `let` expression")
    end

    desc = testsettype = nothing
    seen_options = Set{String}()
    for i in 1:length(args)-1
        arg = args[i]
        k = JS.kind(arg)
        if k === JS.K"Identifier" || k === JS.K"."
            # Mirror `Base.@testset`'s `depwarn` on extra testset types — the last one wins.
            testsettype === nothing || push_macro_warning!(arg,
                "Multiple testset types provided to @testset. This is deprecated and may error in the future.")
            testsettype = arg
        elseif k === JS.K"String" || k === JS.K"string"
            desc === nothing || push_macro_warning!(arg,
                "Multiple descriptions provided to @testset. This is deprecated and may error in the future.")
            desc = arg
        elseif k === JS.K"="
            # Base's `parse_testset_args` silently appends duplicate options to the
            # `Dict` literal and lets last-wins absorb them; warn instead of erroring
            # so we still flag the redundancy without aborting expansion.
            name = _validate_testset_option(arg)
            if name === nothing
                continue # malformed option already reported via sink
            elseif name in seen_options
                push_macro_warning!(arg, "@testset: option `$name` provided more than once")
            else
                push!(seen_options, name)
            end
        else
            # Recovery: skip the unrecognized arg — Base would error here but we
            # prefer to keep the testset's body analyzable.
            push_macro_error!(arg, "@testset: unexpected argument")
        end
    end

    # Wrap the body in a `let` block to reproduce the local scope the real
    # macro creates via `try`/`catch` — without it, bindings would leak into
    # the enclosing scope and sibling testsets would share names.
    return JL.@ast(__context__, mc,
        [JS.K"let"
            [JS.K"block"]            # empty bindings list
            [JS.K"block" body]])
end

function _validate_testset_option(arg::SyntaxTree)
    if JS.numchildren(arg) != 2
        push_macro_error!(arg, "@testset: malformed option")
        return nothing
    end
    name = arg[1]
    if !(JS.kind(name) === JS.K"Identifier" && has_name_val(name))
        push_macro_error!(name, "@testset: option name must be an identifier")
        return nothing
    end
    return name_val(name)
end

# Stub for `Base.@assume_effects`. The real macro emits `Expr(:purity)` / `Expr(:meta)`
# directives that drive effect overrides in inference; for LSP analysis these are
# irrelevant, so we just validate the setting names and route the user-written body through
# unchanged. New-style expansion preserves provenance, which the old-style macro destroys.
#
# Accepted setting names mirror `Base.compute_assumed_setting` (`base/expr.jl`).
# `:consistent_overlay` and `:nortcall` are deliberately omitted since Base does not accept
# them as standalone inputs (they are only set via the `:foldable` / `:total` shortcuts).
const _ASSUME_EFFECTS_SETTINGS = (
    "consistent", "effect_free", "nothrow", "terminates_globally", "terminates_locally",
    "notaskstate", "inaccessiblememonly", "noub", "noub_if_noinbounds", "foldable",
    "removable", "total",
)

function Base.var"@assume_effects"(__context__::JL.MacroContext)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "@assume_effects: at least one argument is required")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

function Base.var"@assume_effects"(
        __context__::JL.MacroContext, args::SyntaxTree...
    )
    mc = __context__.macrocall::SyntaxTree
    for i in 1:length(args)-1
        _validate_assume_effect_setting(args[i])
    end
    lastex = args[end]
    if _is_recognized_assume_effect_setting(lastex)
        # Declaration form (Base's "anonymous function case"): all arguments
        # are settings, no body. The real macro emits `Expr(:meta, purity)`
        # to attach effects to the enclosing function; for LSP analysis we
        # only need a no-op placeholder.
        return JL.@ast(__context__, mc, nothing::JS.K"Value")
    end
    # `lastex` is the body — function definition, `@ccall` macrocall, or
    # call-site annotation. All three cases reduce to "return the body
    # unchanged" since we don't need to attach effect metadata.
    return JL.@ast(__context__, mc, lastex)
end

function _validate_assume_effect_setting(setting::SyntaxTree)
    # Base hard-errors on either of these via `compute_assumed_setting`; we report as
    # Error but let the body still flow through, since the setting only affects effect
    # metadata which the LSP analyses don't consume.
    name = _extract_assume_effect_setting_name(setting)
    if name === nothing
        push_macro_error!(setting,
            "@assume_effects: expected an effect setting (e.g. `:consistent`, `!:nothrow`)")
    elseif name ∉ _ASSUME_EFFECTS_SETTINGS
        push_macro_error!(setting,
            "@assume_effects: unrecognized effect setting `:$name`")
    end
    return nothing
end

function _is_recognized_assume_effect_setting(setting::SyntaxTree)
    name = _extract_assume_effect_setting_name(setting)
    return name !== nothing && name in _ASSUME_EFFECTS_SETTINGS
end

# Strip any number of `!` negations, then check for the symbol-literal shape
# `:foo` (an `inert` node wrapping an `Identifier`). Returns the bare name
# as a `String`, or `nothing` if the shape doesn't match.
function _extract_assume_effect_setting_name(setting::SyntaxTree)
    while JS.kind(setting) === JS.K"call" && JS.numchildren(setting) == 2
        op = setting[1]
        JS.kind(op) === JS.K"Identifier" && get_name_val(op) === "!" || break
        setting = setting[2]
    end
    if JS.kind(setting) === JS.K"inert" && JS.numchildren(setting) >= 1
        inner = setting[1]
        if JS.kind(inner) === JS.K"Identifier"
            return get_name_val(inner)
        end
    end
    return nothing
end

# New-style implementation of `Base.@static`. Like the real macro, the condition is
# evaluated at expansion time and only the taken branch survives — but as a new-style
# macro that branch keeps its fine-grained provenance. The condition is `JL.eval`'d in
# the base syntax layer's module, matching the `__module__` JuliaLowering hands to
# old-style macros. A condition that fails to evaluate (or doesn't produce a `Bool`) is
# reported via the sink and recovered by returning the whole conditional unchanged, so
# every branch and the condition itself still reach scope analysis as a runtime
# conditional.
#
# Each dropped branch is reported via `push_inactive_code!` so editors can gray out
# code that is excluded in the current environment (and won't get completion, hover,
# diagnostics, etc.). When a branch chains further conditionals (`elseif`, right-nested
# `&&`/`||`), dropping it covers the whole remaining chain — including conditions that
# were consequently never evaluated — in one contiguous range.
#
# In EST a ternary stays `K"?"` (Expr conversion is what folds it into `:if`), so the
# if-like kinds form one equivalence class when deciding whether to keep folding a
# selected branch, mirroring Base's `x.head === :elseif || x.head === hd` loop.
const _STATIC_IF_KINDS = JS.KSet"if elseif ?"
const _STATIC_COND_KINDS = JS.KSet"if elseif ? && ||"

function Base.var"@static"(__context__::JL.MacroContext, ex::SyntaxTree)
    mc = __context__.macrocall::SyntaxTree
    if JS.kind(ex) ∉ _STATIC_COND_KINDS
        push_macro_error!(ex, "invalid @static macro")
        return JL.@ast(__context__, mc, ex)
    end
    x = ex
    while true
        k = JS.kind(x)
        cond = _static_eval_cond(__context__, x[1])
        cond === nothing && return JL.@ast(__context__, mc, ex)
        i = xor(cond, k === JS.K"||") ? 2 : 3
        if i == 2
            JS.numchildren(x) ≥ 3 && push_inactive_code!(x[3], cond)
        else
            push_inactive_code!(x[2], cond)
            if JS.numchildren(x) < 3
                if k in _STATIC_IF_KINDS
                    return JL.@ast(__context__, mc, nothing::JS.K"Value")
                end
                return JL.@ast(__context__, mc, cond::JS.K"Value")
            end
        end
        x = x[i]
        xk = JS.kind(x)
        if xk === k || (xk in _STATIC_IF_KINDS && k in _STATIC_IF_KINDS)
            continue # `elseif` chain, right-nested `&&`/`||`, or nested ternary
        end
        return JL.@ast(__context__, mc, x)
    end
end

function Base.var"@static"(__context__::JL.MacroContext, args::SyntaxTree...)
    mc = __context__.macrocall::SyntaxTree
    push_macro_error!(mc, "invalid @static macro")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

# Returns the condition's value as a `Bool`, or `nothing` (with the issue reported via
# the sink) when it cannot be statically evaluated. Legacy `@static` discards macro
# hygiene before calling `Core.eval(__module__, ...)`, so replace all syntax layers with
# a fresh base context before running the condition through JuliaLowering's pipeline.
# Base lets evaluation errors propagate out of expansion; we recover per the macro issue
# contract.
function _static_eval_cond(ctx::JL.MacroContext, cond::SyntaxTree)
    sc = (ctx.macrocall::SyntaxTree).context::JS.SyntaxContext
    base_mod = JS.base_layer(sc).mod
    eval_cond = JS.fill_context(cond, JS.SyntaxContext(base_mod, sc.version))
    val = try
        JL.eval(base_mod, eval_cond)
    catch err
        msg = first(split(sprint(showerror, err), '\n'))
        push_macro_error!(cond, "@static: failed to evaluate condition: $msg")
        return nothing
    end
    val isa Bool && return val
    push_macro_error!(cond, "@static: condition did not evaluate to a Bool")
    return nothing
end
