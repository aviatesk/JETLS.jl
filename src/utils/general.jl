# Internal `@show` definition for JETLS: outputs information to `stderr` instead of `stdout`,
# making it usable for LS debugging.
macro show(exs...)
    blk = Expr(:block)
    for ex in exs
        push!(blk.args, :(println(stderr, $(sprint(Base.show_unquoted,ex)*" = "),
                                  repr(begin local value = $(esc(ex)) end))))
    end
    isempty(exs) || push!(blk.args, :value)
    return blk
end

# Internal `@time` definitions for JETLS: outputs information to `stderr` instead of `stdout`,
# making it usable for LS debugging.
macro time(ex)
    quote
        @time nothing $(esc(ex))
    end
end
macro time(msg, ex)
    quote
        local ret = @timed $(esc(ex))
        local _msg = $(esc(msg))
        local _msg_str = _msg === nothing ? _msg : string(_msg)
        Base.time_print(stderr, ret.time*1e9, ret.gcstats.allocd, ret.gcstats.total_time, Base.gc_alloc_count(ret.gcstats), ret.lock_conflicts, ret.compile_time*1e9, ret.recompile_time*1e9, true; msg=_msg_str)
        ret.value
    end
end

"""
    @elapsed ex

Internal `@elapsed` definition for JETLS that is only active in `JETLS_DEV_MODE`.
When `JETLS_DEV_MODE` is `false`, this macro simply evaluates the expression without timing.
"""
macro elapsed(ex)
    if JETLS_DEV_MODE
        :(Base.@elapsed $(esc(ex)))
    else
        :(begin $(esc(ex)); 0.0; end)
    end
end

"""
    @somereal(x...)

Short-circuiting version of [`somereal`](@ref).
Like [`@something`](@ref), but also skips `missing` values and empty collections.

The following values are skipped:
- `nothing`
- `missing`
- empty `AbstractVector`

Values wrapped in `Some` are unwrapped.

# Examples
```julia
julia> f(x) = (println("f(\$x)"); nothing);

julia> a = 3;

julia> @somereal a f(1) f(2) error("Unable to find default for `a`")
f(1)
f(2)
3

julia> b = missing;

julia> @somereal b f(1) f(2) error("Unable to find default for `b`")
f(1)
f(2)
ERROR: ArgumentError: No value arguments present
Stacktrace:

julia> c = Int[];

julia> c = @somereal c [1, 2] error("Unable to find default for `c`")
2-element Vector{Int64}:
 1
 2
```
"""
macro somereal(args...)
    somereal = GlobalRef(@__MODULE__, :somereal)
    issomereal = GlobalRef(@__MODULE__, :issomereal)
    expr = :(throw(ArgumentError("No values present")))
    for arg in reverse(args)
        expr = :(let val = $(esc(arg))
            if $issomereal(val)
                $somereal(val)
            else
                $expr
            end
        end)
    end
    return expr
end

issomereal(::Nothing) = false
issomereal(::Missing) = false
issomereal(xs::AbstractVector) = !isempty(xs)
issomereal(::Any) = true

"""
    somereal(x...)

Like [`something`](@ref), but also skips `missing` values and empty collections.

The following values are skipped:
- `nothing`
- `missing`
- empty `AbstractVector`

Values wrapped in `Some` are unwrapped.
Throws `ArgumentError` if no valid value found.
"""
function somereal end

somereal() = throw(ArgumentError("No values present"))
somereal(::Nothing, xs...) = somereal(xs...)
somereal(::Missing, xs...) = somereal(xs...)
somereal(x::Some, _xs...) = x.value
somereal(x::AbstractVector, xs...) = !isempty(x) ? x : somereal(xs...)
somereal(x::Any, _xs...) = x

"""
    @define_override_constructor T

Takes a type `T` and defines a constructor for `T` as follows:
```julia
function T(x::T;
           f1::T1 = x.f1,
           f2::T2 = x.f2,
           ...,
           fn::Tn = x.fn)
    return T(f1, f2, ..., fn)
end
```
`T` must be overloadable in the macro call context.
When overloading types from other modules, you can pass `Mod.T`.
"""
macro define_override_constructor(Tex)
    T = Core.eval(__module__, Tex)
    assignments = Expr[]
    fieldvalues = Symbol[]
    for i = 1:fieldcount(T)
        fname, ftype = fieldname(T, i), fieldtype(T, i)
        arg = Expr(:(::), fname, ftype)
        default = Expr(:., :x, QuoteNode(fname))
        push!(assignments, Expr(:kw, arg, default))
        push!(fieldvalues, fname)
    end
    sig = Expr(:call, Tex, Expr(:parameters, assignments...), Expr(:(::), :x, Tex))
    new = Expr(:new, Tex, fieldvalues...)
    body = Expr(:block, __source__, new)
    return Expr(:(=), sig, body)
end

"""
    @tryinvokelatest f(args...; kwargs...)

Safely invoke a function with the latest method definitions and automatic error handling.

This macro combines the functionality of `@invokelatest` and `try`-`catch` error handling,
providing a robust way to call functions in the JETLS server environment where:
- Methods that are called from unrevisable loop may be updated by Revise.jl during development
- Errors should be logged but not crash the server (in non-test mode)

The macro's behavior depends on the JETLS execution mode:
- `JETLS_DEV_MODE=true`: Wraps the call with `@invokelatest` to ensure Revise.jl
  changes are reflected without restarting the server
- `JETLS_DEV_MODE=false`: Direct function call without `@invokelatest`
- `JETLS_TEST_MODE=true`: No `try`-`catch` wrapping, allowing errors to propagate for testing
- `JETLS_TEST_MODE=false`: Wraps the call in `try`-`catch` to log errors without crashing
"""
macro tryinvokelatest(ex)
    Meta.isexpr(ex, :call) || error("@tryinvokelatest expects :call expresion")

    f, args, kwargs = Base.destructure_callex(__module__, ex)
    f = esc(f); args = esc.(args); kwargs = esc.(kwargs);

    callex = Expr(:call, f)
    isempty(kwargs) || push!(callex.args, Expr(:parameters, kwargs...))
    push!(callex.args, args...)
    callex = if JETLS_DEV_MODE
        # `@invokelatest` for allowing changes maded by Revise to be reflected without
        # terminating the `runserver` loop
        :(@invokelatest $(callex))
    else
        callex
    end

    JETLS_TEST_MODE && return callex

    arglist = Any[f, args..., kwargs...]
    callargs = map(1:length(arglist)) do i::Int
        arg = arglist[i]
        name = Symbol("argtype", i)
        Expr(:(=), name, Expr(:call, GlobalRef(Core,:typeof), arg))
    end
    return :(try
        $callex
    catch err
        @error "@tryinvokelatest failed with" $(callargs...)
        Base.display_error(stderr, err, catch_backtrace())
    end)
end

"""
    methods_at_world(world::UInt, f, [t::Type=Tuple{Vararg{Any}}]; mod=nothing) ->
        Base.MethodList

`Base.methods` with the dispatch world fixed at `world` instead of resolved
lazily from `Base.get_world_counter()`. Use this when reflection happens
during a request that has already pinned a world (e.g. hover, type
definition) — `Base.methods(f)` would otherwise pick up methods added by a
concurrent analysis update mid-request.

Uses `Base._methods` / `Base.matches_to_methods` internals because the
public `methods` entry point reads `Base.get_world_counter()` itself, which
is exactly what we're trying to avoid.
"""
methods_at_world(world::UInt, @nospecialize(f); mod=nothing) =
    methods_at_world(world, f, Tuple{Vararg{Any}}; mod)
function methods_at_world(world::UInt, @nospecialize(f), @nospecialize(t); mod=nothing)
    ms = Base._methods(f, t, -1, world)::Vector{Any}
    return Base.matches_to_methods(ms, typeof(f).name, mod)
end

# types that should be compared by `===` rather than `==`
const _EGAL_TYPES_ = Any[Symbol, Core.MethodInstance, Type]

macro define_eq_overloads(Tyname)
    Ty = Core.eval(__module__, Tyname)
    fld2typs = Pair{Symbol,Any}[Pair{Symbol,Any}(fieldname(Ty, i), fieldtype(Ty, i)) for i = 1:fieldcount(Ty)]
    hash_body = Expr(:block)
    for fld2typ in fld2typs
        fld, _ = fld2typ
        push!(hash_body.args, :(h = Base.hash(x.$fld, h)::UInt))
    end
    push!(hash_body.args, :(return h))
    hash_func = :(function Base.hash(x::$Tyname, h::UInt); $hash_body; end)
    eq_body = foldr(fld2typs; init = true) do fld2typ, x
        fld, typ = fld2typ
        if (typ in _EGAL_TYPES_)::Bool
            eq_ex = :(x1.$fld === x2.$fld)
        else
            eq_ex = :((x1.$fld == x2.$fld)::Bool)
        end
        Expr(:&&, eq_ex, x)
    end
    eq_func = :(function Base.:(==)(x1::$Tyname, x2::$Tyname); $eq_body; end)
    return quote
        $eq_func
        $hash_func
    end
end

"""
    getobjpath(obj, path::Symbol...)

An accessor primarily written for accessing fields of LSP objects whose fields
may be unset (set to `nothing`) depending on client/server capabilities.
Traverses the field chain `paths...` of `obj`, and returns `nothing` if any
`nothing` field is encountered along the way.
"""
Base.@constprop :aggressive function getobjpath(obj, path::Symbol, paths::Symbol...)
    nextobj = @something getfield(obj, path) return nothing
    getobjpath(nextobj, paths...)
end
getobjpath(obj) = obj

function format_duration(duration::Float64)
    if duration < 1
        "$(round(duration * 1000, digits=1))ms"
    elseif duration < 60
        "$(round(duration, digits=2))s"
    else
        minutes = floor(Int, duration / 60)
        seconds = round(duration % 60, digits=1)
        "$(minutes)m $(seconds)s"
    end
end

# `Base.type_limited_string_from_context` clamps width to `max(_, 120)`, which
# is too wide for inline hints — call `type_depth_limit` directly. Two passes:
# `maxdepth` first to cap structural depth, then `maxwidth` to cap textual
# width. Passing `typemax(Int)` for either is the canonical "no limit".
function truncate_typstr(str::String, maxdepth::Int, maxwidth::Int)
    str = Base.type_depth_limit(str, 0; maxdepth)
    str = Base.type_depth_limit(str, maxwidth)
    return str
end

rlstrip(s::AbstractString, args...) = lstrip(rstrip(s, args...), args...)

const JULIA_LIKE_LANGUAGES = [
    "julia",
    "julia-repl",
    "jldoctest"
]

# Documenter cross-reference links — `[label](@ref)` / `[label](@ref target)` —
# get reduced to bare `label` text in LSP output. The target isn't a navigable
# URL, so clients either pop a "can't open this URI" prompt or silently drop the
# click; showing the label as plain text is the least surprising fallback until
# a proper resolver lands.
const REF_LINK_REGEX = r"\[([^\]]+)\]\(@ref(?:\s[^)]*)?\)"
strip_ref_links(s::AbstractString) = replace(s, REF_LINK_REGEX => s"\1")

"""
    lsrender(md) -> String

Render Markdown for LSP display with the following conversions:
- Code blocks with Julia-like languages (see `JULIA_LIKE_LANGUAGES`) normalized to "julia"
- Documenter `@ref` cross-reference links flattened to their label text

TODO: Resolve `@ref` targets to actual definitions rather than stripping the link.
"""
lsrender(md::Union{Markdown.MarkdownElement, Markdown.MD}) = strip_ref_links(sprint(lsrender, md))
lsrender(io::IO, md::Markdown.MarkdownElement) = Markdown.plain(io, md)

function lsrender(io::IO, md::Markdown.MD)
    isempty(md.content) && return
    for md in md.content[1:end-1]
        lsrender(io, md)
        println(io)
    end
    lsrender(io, md.content[end])
end

function lsrender(io::IO, code::Markdown.Code)
    n = mapreduce(m -> length(m.match), max, eachmatch(r"^`+"m, code.code); init=2) + 1
    println(io, "`" ^ n, code.language in JULIA_LIKE_LANGUAGES ? "julia" : code.language)
    println(io, code.code)
    println(io, "`" ^ n)
end

function admonition_marker(category::AbstractString)
    cat = lowercase(category)
    cat == "note"    && return "📝"
    cat == "info"    && return "ℹ️"
    cat == "tip"     && return "💡"
    cat == "warning" && return "⚠️"
    cat == "danger"  && return "🚨"
    cat == "compat"  && return "⬆️"
    return "💬"
end

function lsrender(io::IO, ad::Markdown.Admonition)
    marker = admonition_marker(ad.category)
    title = isempty(ad.title) ? uppercasefirst(ad.category) : ad.title
    println(io, "> **", marker, " ", title, "**")
    isempty(ad.content) && return
    body = sprint() do bio
        for i = 1:(length(ad.content)-1)
            lsrender(bio, ad.content[i])
            println(bio)
        end
        lsrender(bio, ad.content[end])
    end
    println(io, ">")
    for line in eachsplit(rstrip(body), '\n')
        isempty(line) ? println(io, ">") : println(io, "> ", line)
    end
end

@static if VERSION < v"1.13.0-DEV.823" # JuliaLang/julia#58916
lsrender(io::IO, table::Markdown.Table) = Markdown.plain(io, table)
lsrender(io::IO, latex::Markdown.LaTeX) = Markdown.plain(io, latex)
end

struct LSPostProcessor
    inner::JET.PostProcessor
    LSPostProcessor(inner::JET.PostProcessor) = new(inner)
end
LSPostProcessor() = LSPostProcessor(JET.PostProcessor())

(processor::LSPostProcessor)(md::Markdown.MD) = processor.inner(lsrender(md))
(processor::LSPostProcessor)(s::AbstractString) = processor.inner(s)

function install_instruction_message(app::AbstractString, instruction_url::AbstractString)
    """
    Follow this [instruction]($instruction_url)
    to install the `$app` app.
    """
end

function check_settings_message(setting_path::Symbol...)
    """
    This value is configured in the `$(join(setting_path, "."))`.
    Please check the settings.
    """
end

app_notfound_message(app::AbstractString) = "`$app` executable is not found on the `PATH`."

function is_abstract_fieldtype(@nospecialize typ)
    if typ isa Type
        if typ isa UnionAll
            # If field type is `UnionAll`, then it's always an abstract field type, e.g.
            # `struct A; xs::Vector{<:Integer}; end`
            return true
        end
        if isabstracttype(typ)
            return true
        end
        if typ isa DataType
            for i = 1:length(typ.parameters)
                if is_abstract_fieldtype(typ.parameters[i])
                    return true
                end
            end
        end
    end
    return false
end
