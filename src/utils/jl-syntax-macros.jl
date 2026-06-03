# Staging ground for common Base macros defined in the new style definitions.
# These are in addition to JuliaLowering.jl/src/syntax_macros.jl,
# and can be merged there when possible.

# TODO: @boundscheck, @simd

"""
    mapchildren(f, ctx, ex, indices::UnitRange{Int})

Like `JS.mapchildren(f, ctx, ex)`, but applies `f` only to children at the
given `indices`, leaving other children unchanged.
"""
function mapchildren(f, ctx, ex::SyntaxTreeC, indices::UnitRange{<:Integer})
    i = Ref(0)
    JS.mapchildren(ctx, ex) do c
        i[] += 1
        i[] in indices ? f(c) : c
    end
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
    node::SyntaxTreeC
    msg::String
    severity::DiagnosticSeverity.Ty
end

"""
    MACRO_DIAGNOSTIC_SINK :: ScopedValue{Union{Nothing,Vector{MacroDiagnostic}}}

Side channel that lets macro stubs surface issues as LSP diagnostics without
aborting expansion — the producer/consumer contract for [`push_macro_error!`](@ref)
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
        node::SyntaxTreeC, msg::AbstractString, severity::DiagnosticSeverity.Ty
    )
    sink = MACRO_DIAGNOSTIC_SINK[]
    sink === nothing && return
    push!(sink, MacroDiagnostic(node, String(msg), severity))
    return
end

"""
    push_macro_warning!(node::SyntaxTreeC, msg::AbstractString)

Push a `DiagnosticSeverity.Warning` entry anchored on `node` into
[`MACRO_DIAGNOSTIC_SINK`](@ref) (no-op if the sink is unbound).

$macro_issue_contract
"""
push_macro_warning!(node::SyntaxTreeC, msg::AbstractString) =
    push_macro_diagnostic!(node, msg, DiagnosticSeverity.Warning)

"""
    push_macro_error!(node::SyntaxTreeC, msg::AbstractString)

Push a `DiagnosticSeverity.Error` entry anchored on `node` into
[`MACRO_DIAGNOSTIC_SINK`](@ref) (no-op if the sink is unbound).

$macro_issue_contract
"""
push_macro_error!(node::SyntaxTreeC, msg::AbstractString) =
    push_macro_diagnostic!(node, msg, DiagnosticSeverity.Error)

# Simple (non-qualified) macro names whose new-style implementations in this file and
# `JuliaLowering/src/syntax_macros.jl` preserve fine-grained source provenance during
# expansion. Unlike old-style macros — whose expansion collapses source positions to
# line granularity and is why `_remove_macrocalls` exists — these don't need to be
# rewritten to a `block` to keep accurate locations for scope resolution.
# This is used by `remove_macrocalls` in ast.jl
const NEW_STYLE_MACROCALL_NAMES = (
    # JuliaLowering/src/syntax_macros.jl
    "@__FUNCTION__",
    "@ccall",
    "@cfunction",
    "@eval",
    "@generated",
    "@goto",
    "@isdefined",
    "@locals",
    "@nospecialize",
    # src/utils/jl-syntax-macros.jl
    "@assert",
    "@assume_effects",
    "@debug",
    "@error",
    "@inbounds",
    "@inferred",
    "@info",
    "@inline",
    "@invoke",
    "@invokelatest",
    "@kwdef",
    "@label",
    "@logmsg",
    "@noinline",
    "@propagate_inbounds",
    "@show",
    "@something",
    "@spawn",
    "@specialize",
    "@test",
    "@test_broken",
    "@test_deprecated",
    "@test_logs",
    "@test_nowarn",
    "@test_skip",
    "@test_throws",
    "@test_warn",
    "@testset",
    "@warn",
)

function Base.var"@specialize"(__context__::JL.MacroContext)
    JL.@ast(__context__,
            __context__.macrocall::SyntaxTreeC,
            [JS.K"meta" "specialize"::JS.K"Identifier"])
end

function Base.var"@specialize"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    JL.@ast(__context__, __context__.macrocall::SyntaxTreeC, ex)
end

function Base.var"@specialize"(
        __context__::JL.MacroContext,
        ex1::SyntaxTreeC, ex2::SyntaxTreeC, exs::SyntaxTreeC...
    )
    JL.@ast(__context__, __context__.macrocall::SyntaxTreeC,
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
    JL.@ast(__context__, __context__.macrocall::SyntaxTreeC,
            [JS.K"meta" "inline"::JS.K"Identifier"])
end

function Base.var"@inline"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    JL.@ast(__context__, ex, ex)
end

function Base.var"@noinline"(__context__::JL.MacroContext)
    JL.@ast(__context__, __context__.macrocall::SyntaxTreeC,
            [JS.K"meta" "noinline"::JS.K"Identifier"])
end

function Base.var"@noinline"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    JL.@ast(__context__, ex, ex)
end

function Base.var"@propagate_inbounds"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    JL.@ast(__context__, ex, ex)
end

function Base.var"@inbounds"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    JL.@ast(__context__, ex, ex)
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

function Base.Threads.var"@spawn"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC,
        unwrap_interpolations(ex))
end

function Base.Threads.var"@spawn"(
        __context__::JL.MacroContext,
        threadpool::SyntaxTreeC, ex::SyntaxTreeC
    )
    _validate_spawn_threadpool(threadpool)
    return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC,
        [JS.K"block" threadpool unwrap_interpolations(ex)])
end

function _validate_spawn_threadpool(threadpool::SyntaxTreeC)
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

function Base.Threads.var"@spawn"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
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
function Base.var"@label"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    if JS.kind(ex) !== JS.K"Identifier"
        push_macro_error!(ex, "@label requires an identifier")
        # Recovery: let the expression flow through so any identifier inside still
        # reaches scope analysis. Goto-target semantics are lost.
        return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC, ex)
    end
    return JL.@ast(__context__, ex, [JS.K"symboliclabel" ex])
end

function Base.var"@label"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
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
function Base.var"@something"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
    expr = JL.@ast(__context__, mc,
        [JS.K"call" "something"::JS.K"Identifier" nothing::JS.K"Value"])
    for i in length(args):-1:1
        arg = args[i]
        val_name = "val_$i"
        expr = JL.@ast(__context__, mc, [JS.K"let"
            [JS.K"block"
                [JS.K"=" val_name::JS.K"Identifier" arg]]
            [JS.K"block"
                [JS.K"if"
                    [JS.K"call" "isnothing"::JS.K"Identifier"
                        val_name::JS.K"Identifier"]
                    expr
                    [JS.K"call" "something"::JS.K"Identifier"
                        val_name::JS.K"Identifier"]]]])
    end
    return expr
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
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc, "@assert: at least one argument is required")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

function Base.var"@assert"(
        __context__::JL.MacroContext, ex::SyntaxTreeC, msgs::SyntaxTreeC...
    )
    mc = __context__.macrocall::SyntaxTreeC
    msg_arg = isempty(msgs) ?
        JL.@ast(__context__, mc, JS.sourcetext(ex)::JS.K"Value") :
        msgs[1]
    if_throw = JL.@ast(__context__, mc, [JS.K"if" ex
        nothing::JS.K"Value"
        [JS.K"call" "throw"::JS.K"Identifier"
            [JS.K"call" "AssertionError"::JS.K"Identifier" msg_arg]]])
    length(msgs) <= 1 && return if_throw
    extras = msgs[2:end]
    return JL.@ast(__context__, mc, [JS.K"block" extras... if_throw])
end

# Stub for `Base.@show`. The real macro emits per-argument
# `println("ex = ", repr(ex))` scaffolding and returns the last argument's value
# (or `nothing` for the zero-arg form); for LSP analysis we only need each
# user-written expression to flow through with its provenance intact, so we
# drop the printing and route the args through a `block` whose final value
# naturally matches Base's return semantics.
function Base.var"@show"(__context__::JL.MacroContext, exs::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
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
        __context__::JL.MacroContext, message::SyntaxTreeC, exs::SyntaxTreeC...
    )
    return _logmsg_stub(__context__, (message, exs...), "@debug")
end

function Base.CoreLogging.var"@debug"(__context__::JL.MacroContext)
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc, "@debug requires at least one argument: a `message`")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

function Base.CoreLogging.var"@info"(
        __context__::JL.MacroContext, message::SyntaxTreeC, exs::SyntaxTreeC...
    )
    return _logmsg_stub(__context__, (message, exs...), "@info")
end

function Base.CoreLogging.var"@info"(__context__::JL.MacroContext)
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc, "@info requires at least one argument: a `message`")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

function Base.CoreLogging.var"@warn"(
        __context__::JL.MacroContext, message::SyntaxTreeC, exs::SyntaxTreeC...
    )
    return _logmsg_stub(__context__, (message, exs...), "@warn")
end

function Base.CoreLogging.var"@warn"(__context__::JL.MacroContext)
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc, "@warn requires at least one argument: a `message`")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

function Base.CoreLogging.var"@error"(
        __context__::JL.MacroContext, message::SyntaxTreeC, exs::SyntaxTreeC...
    )
    return _logmsg_stub(__context__, (message, exs...), "@error")
end

function Base.CoreLogging.var"@error"(__context__::JL.MacroContext)
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc, "@error requires at least one argument: a `message`")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

# `@logmsg` adds a leading `level` argument. The level is a user-written
# expression (a `LogLevel` constant or computed value), so it still needs to
# flow through to scope resolution.
function Base.CoreLogging.var"@logmsg"(
        __context__::JL.MacroContext, level::SyntaxTreeC, message::SyntaxTreeC,
        exs::SyntaxTreeC...
    )
    return _logmsg_stub(__context__, (level, message, exs...), "@logmsg")
end

function Base.CoreLogging.var"@logmsg"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc,
        "@logmsg requires at least two arguments: a `level` and a `message`")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args... nothing::JS.K"Value"])
end

function _logmsg_stub(
        ctx::JL.MacroContext, exs::Tuple{Vararg{SyntaxTreeC}}, name::AbstractString
    )
    mc = ctx.macrocall::SyntaxTreeC
    children = SyntaxTreeC[]
    seen_kws = Set{String}()
    for ex in exs
        k = JS.kind(ex)
        if k === JS.K"="
            if JS.numchildren(ex) != 2
                push_macro_error!(ex, "$name: malformed keyword argument")
                continue
            end
            kwname = _validate_logmsg_kw(ex)
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

# Returns the kwarg name as a `String`, or `nothing` if the name isn't a
# plain identifier. The latter case (e.g. `"foo"=val`, which Base silently
# routes through `Symbol(k)`) is rare enough that we just skip the
# duplicate check rather than reject it outright. Assumes `JS.numchildren(kw) == 2`
# (the caller pre-validates the shape so it can safely access `kw[2]`).
function _validate_logmsg_kw(kw::SyntaxTreeC)
    key = kw[1]
    if JS.kind(key) === JS.K"Identifier" && hasproperty(key, :name_val)
        n = key.name_val
        return n isa AbstractString ? String(n) : nothing
    end
    return nothing
end

# New-style implementations of `Base.@invoke` / `Base.@invokelatest`. These match Base's
# expansion (`Core.invoke(f, Tuple{T1,...}, args...)` / `Base.invokelatest(f, args...)`)
# rather than routing the body through unchanged, so type inference (e.g.
# `TypeAnnotation`) sees the actual `Core.invoke` / `Base.invokelatest` call and not the
# surface-syntax call. The same call shapes Base's `destructure_callex` handles are
# accepted (`f(args...; kwargs...)`, `x.f`, `xs[i]`, `x.f = v`, `xs[i] = v`); other shapes
# are rejected at expansion time with a clear message.
function Base.var"@invoke"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    destructured = _destructure_invoke_callex(__context__, ex, "@invoke")
    destructured === nothing &&
        return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC, ex)
    f, args, kwargs = destructured
    return _build_invoke_call(__context__, ex, f, args, kwargs)
end

function Base.var"@invoke"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc,
        "@invoke expects exactly one argument: `f(args...; kwargs...)` (or one of `x.f`, `xs[i]`, `x.f = v`, `xs[i] = v`)")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

function Base.var"@invokelatest"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    destructured = _destructure_invoke_callex(__context__, ex, "@invokelatest")
    destructured === nothing &&
        return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC, ex)
    f, args, kwargs = destructured
    return _build_invokelatest_call(__context__, f, args, kwargs)
end

function Base.var"@invokelatest"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
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
        ctx::JL.MacroContext, ex::SyntaxTreeC, m::AbstractString
    )
    k = JS.kind(ex)
    if k === JS.K"call"
        f = ex[1]
        args = SyntaxTreeC[]
        kwargs = SyntaxTreeC[]
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
        return f, SyntaxTreeC[ex[1], ex[2]], SyntaxTreeC[]
    elseif k === JS.K"ref"
        # `xs[i, j, ...]` -> getindex(xs, i, j, ...).
        f = JL.@ast(ctx, ex, [JS.K"top" "getindex"::JS.K"Identifier"])
        args = SyntaxTreeC[ex[i] for i in 1:JS.numchildren(ex)]
        return f, args, SyntaxTreeC[]
    elseif k === JS.K"=" && JS.numchildren(ex) == 2
        lhs, rhs = ex[1], ex[2]
        lhs_k = JS.kind(lhs)
        if lhs_k === JS.K"."
            # `x.f = v` -> setproperty!(x, :f, v).
            f = JL.@ast(ctx, ex, [JS.K"top" "setproperty!"::JS.K"Identifier"])
            return f, SyntaxTreeC[lhs[1], lhs[2], rhs], SyntaxTreeC[]
        elseif lhs_k === JS.K"ref"
            # `xs[i, ...] = v` -> setindex!(xs, v, i, ...).
            args = SyntaxTreeC[lhs[1], rhs]
            for i in 2:JS.numchildren(lhs)
                push!(args, lhs[i])
            end
            f = JL.@ast(ctx, ex, [JS.K"top" "setindex!"::JS.K"Identifier"])
            return f, args, SyntaxTreeC[]
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
        ctx::JL.MacroContext, srcref::SyntaxTreeC,
        f::SyntaxTreeC, args::Vector{SyntaxTreeC}, kwargs::Vector{SyntaxTreeC}
    )
    types = SyntaxTreeC[]
    new_args = SyntaxTreeC[]
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
    mc = ctx.macrocall::SyntaxTreeC
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
        f::SyntaxTreeC, args::Vector{SyntaxTreeC}, kwargs::Vector{SyntaxTreeC}
    )
    mc = ctx.macrocall::SyntaxTreeC
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
function Base.var"@kwdef"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    if JS.kind(ex) !== JS.K"struct"
        push_macro_error!(ex, "Invalid usage of @kwdef")
        # Recovery: let the argument flow through unchanged so e.g. a half-typed
        # struct or an accidentally-decorated function still reaches scope analysis.
        return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC, ex)
    end

    # EST struct children: [Value(is_mutable), type_sig, body]
    type_sig = ex[2]
    type_body = ex[3]

    field_names = SyntaxTreeC[]
    field_defaults = Union{Nothing,SyntaxTreeC}[]
    stripped = SyntaxTreeC[]
    _kwdef_collect_fields!(__context__, type_body, field_names, field_defaults, stripped)

    stripped_body = JL.@ast(__context__, type_body::SyntaxTreeC,
                           [JS.K"block" stripped...])
    new_struct = mapchildren(_ -> stripped_body, __context__, ex, 3:3)

    if isempty(field_names)
        return new_struct
    end

    constructors = _kwdef_make_constructors(
        __context__, type_sig, field_names, field_defaults)

    return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC,
                   [JS.K"block" new_struct constructors...])
end

function _kwdef_collect_fields!(
        ctx::JL.MacroContext, body::SyntaxTreeC, field_names::Vector{SyntaxTreeC},
        field_defaults::Vector{Union{Nothing,SyntaxTreeC}},
        stripped::Vector{SyntaxTreeC}
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
        decl::SyntaxTreeC, default::SyntaxTreeC, field_names::Vector{SyntaxTreeC},
        field_defaults::Vector{Union{Nothing,SyntaxTreeC}}
    )
    name = _kwdef_extract_name(decl)
    if name !== nothing
        push!(field_names, name)
        push!(field_defaults, default)
    end
end

function _kwdef_extract_name(st::SyntaxTreeC)
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
        ctx::JL.MacroContext, type_sig::SyntaxTreeC, field_names::Vector{SyntaxTreeC},
        field_defaults::Vector{Union{Nothing,SyntaxTreeC}}
    )
    mc = __source__ = ctx.macrocall::SyntaxTreeC

    if JS.kind(type_sig) === JS.K"<:"
        type_sig = type_sig[1]
    end

    params = SyntaxTreeC[]
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
        return SyntaxTreeC[JL.@ast(ctx, mc, [JS.K"function" sig body])]
    elseif JS.kind(type_sig) === JS.K"curly"
        S = type_sig[1]
        P = SyntaxTreeC[type_sig[i] for i::Int in 2:JS.numchildren(type_sig)]
        Q = SyntaxTreeC[JS.kind(p) === JS.K"<:" ? p[1] : p for p in P]
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

        return SyntaxTreeC[def1, def2]
    else
        # Recovery: emit no constructors. The bare (stripped) struct definition
        # still reaches downstream lowering.
        push_macro_error!(type_sig, "Invalid type signature for @kwdef")
        return SyntaxTreeC[]
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
function Test.var"@test"(__context__::JL.MacroContext, ex::SyntaxTreeC, kws::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
    seen_broken = seen_skip = seen_context = nothing
    rhss = SyntaxTreeC[]
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
        __context__::JL.MacroContext, ex::SyntaxTreeC, kws::SyntaxTreeC...
    )
    mc = __context__.macrocall::SyntaxTreeC
    rhss = SyntaxTreeC[]
    for kw in kws
        _validate_test_kw(kw) === nothing && continue
        push!(rhss, kw[2])
    end
    isempty(rhss) && return JL.@ast(__context__, mc, ex)
    return JL.@ast(__context__, mc, [JS.K"block" rhss... ex])
end

function Test.var"@test_skip"(
        __context__::JL.MacroContext, ex::SyntaxTreeC, kws::SyntaxTreeC...
    )
    mc = __context__.macrocall::SyntaxTreeC
    rhss = SyntaxTreeC[]
    for kw in kws
        _validate_test_kw(kw) === nothing && continue
        push!(rhss, kw[2])
    end
    isempty(rhss) && return JL.@ast(__context__, mc, ex)
    return JL.@ast(__context__, mc, [JS.K"block" rhss... ex])
end

function Test.var"@test_throws"(
        __context__::JL.MacroContext, extype::SyntaxTreeC, ex::SyntaxTreeC
    )
    return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC,
        [JS.K"block" extype ex])
end

function Test.var"@test_throws"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc,
        "@test_throws expects exactly two arguments: `extype` and `ex`")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

function Test.var"@test_warn"(
        __context__::JL.MacroContext, msg::SyntaxTreeC, ex::SyntaxTreeC
    )
    return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC,
        [JS.K"block" msg ex])
end

function Test.var"@test_nowarn"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC, ex)
end

function Test.var"@test_logs"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
    if isempty(args)
        push_macro_error!(mc, "@test_logs needs at least one argument")
        return JL.@ast(__context__, mc, nothing::JS.K"Value")
    end
    body = last(args)
    block_children = SyntaxTreeC[]
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

function Test.var"@test_deprecated"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC, ex)
end

function Test.var"@test_deprecated"(
        __context__::JL.MacroContext, pattern::SyntaxTreeC, ex::SyntaxTreeC
    )
    return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC,
        [JS.K"block" pattern ex])
end

function Test.var"@test_deprecated"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc,
        "@test_deprecated expects one or two arguments: `[pattern] expr`")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

function Test.var"@inferred"(__context__::JL.MacroContext, ex::SyntaxTreeC)
    return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC, ex)
end

function Test.var"@inferred"(
        __context__::JL.MacroContext, allow::SyntaxTreeC, ex::SyntaxTreeC
    )
    return JL.@ast(__context__, __context__.macrocall::SyntaxTreeC,
        [JS.K"block" allow ex])
end

function Test.var"@inferred"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc, "@inferred expects one or two arguments: `[allow] ex`")
    isempty(args) && return JL.@ast(__context__, mc, nothing::JS.K"Value")
    return JL.@ast(__context__, mc, [JS.K"block" args...])
end

function _validate_test_kw(kw::SyntaxTreeC)
    if JS.kind(kw) !== JS.K"="
        push_macro_error!(kw, "invalid test macro call: expected `keyword=value`")
        return nothing
    end
    if JS.numchildren(kw) != 2
        push_macro_error!(kw, "invalid test macro call: malformed keyword argument")
        return nothing
    end
    name = kw[1]
    if !(JS.kind(name) === JS.K"Identifier" && hasproperty(name, :name_val))
        push_macro_error!(name, "invalid test macro call: keyword name must be an identifier")
        return nothing
    end
    return name.name_val::String
end

function Test.var"@testset"(__context__::JL.MacroContext, args::SyntaxTreeC...)
    mc = __context__.macrocall::SyntaxTreeC
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

function _validate_testset_option(arg::SyntaxTreeC)
    if JS.numchildren(arg) != 2
        push_macro_error!(arg, "@testset: malformed option")
        return nothing
    end
    name = arg[1]
    if !(JS.kind(name) === JS.K"Identifier" && hasproperty(name, :name_val))
        push_macro_error!(name, "@testset: option name must be an identifier")
        return nothing
    end
    return name.name_val::String
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
    mc = __context__.macrocall::SyntaxTreeC
    push_macro_error!(mc, "@assume_effects: at least one argument is required")
    return JL.@ast(__context__, mc, nothing::JS.K"Value")
end

function Base.var"@assume_effects"(
        __context__::JL.MacroContext, args::SyntaxTreeC...
    )
    mc = __context__.macrocall::SyntaxTreeC
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

function _validate_assume_effect_setting(setting::SyntaxTreeC)
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

function _is_recognized_assume_effect_setting(setting::SyntaxTreeC)
    name = _extract_assume_effect_setting_name(setting)
    return name !== nothing && name in _ASSUME_EFFECTS_SETTINGS
end

# Strip any number of `!` negations, then check for the symbol-literal shape
# `:foo` (an `inert` node wrapping an `Identifier`). Returns the bare name
# as a `String`, or `nothing` if the shape doesn't match.
function _extract_assume_effect_setting_name(setting::SyntaxTreeC)
    while JS.kind(setting) === JS.K"call" && JS.numchildren(setting) == 2
        op = setting[1]
        JS.kind(op) === JS.K"Identifier" && hasproperty(op, :name_val) &&
            op.name_val === "!" || break
        setting = setting[2]
    end
    if JS.kind(setting) === JS.K"inert" && JS.numchildren(setting) >= 1
        inner = setting[1]
        if JS.kind(inner) === JS.K"Identifier" && hasproperty(inner, :name_val)
            name = inner.name_val
            return name isa AbstractString ? name : nothing
        end
    end
    return nothing
end
