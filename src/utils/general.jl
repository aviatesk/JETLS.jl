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

# TODO Need to make them thread safe when making the message handling multithreaded

let debounced = Dict{UInt, Timer}()
    global function debounce(f, id::UInt, delay)
        if haskey(debounced, id)
            close(debounced[id])
        end
        debounced[id] = Timer(delay) do _
            try
                f()
            finally
                delete!(debounced, id)
            end
        end
        nothing
    end
end

let throttled = Dict{UInt, Tuple{Union{Nothing,Timer}, Float64}}()
    global function throttle(f, id::UInt, interval)
        if !haskey(throttled, id)
            f()
            throttled[id] = (nothing, time())
            return nothing
        end
        last_timer, last_time = throttled[id]
        if last_timer !== nothing
            close(last_timer)
        end
        delay = max(0.0, interval - (time() - last_time))
        throttled[id] = (Timer(delay) do _
            try
                f()
            finally
                throttled[id] = (nothing, time())
            end
        end, last_time)
        nothing
    end
end

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
    getobjpath(obj, path::Symbo...)

An accessor primarily written for accessing fields of LSP objects whose fields
may be unset (set to `nothing`) depending on client/server capabilities.
Traverses the field chain `paths...` of `obj`, and returns `nothing` if any
`nothing` field is encountered along the way.
"""
function getobjpath(obj, path::Symbol, paths::Symbol...)
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

rlstrip(s::AbstractString, args...) = lstrip(rstrip(s, args...), args...)

const JULIA_LIKE_LANGUAGES = [
    "julia",
    "julia-repl",
    "jldoctest"
]

"""
    lsrender(md) -> String

Render Markdown for LSP display with the following conversions:
- Code blocks with Julia-like languages (see `JULIA_LIKE_LANGUAGES`) normalized to "julia"

TODO: Handle `@ref` correctly
"""
lsrender(md::Union{Markdown.MarkdownElement, Markdown.MD}) = sprint(lsrender, md)
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

@static if VERSION < v"1.13.0-DEV.823" # JuliaLang/julia#58916
lsrender(io::IO, table::Markdown.Table) = Markdown.plain(io, table)
lsrender(io::IO, latex::Markdown.LaTeX) = Markdown.plain(io, latex)
end

(processor::LSPostProcessor)(md::Markdown.MD) = processor.inner(lsrender(md))
(processor::LSPostProcessor)(s::AbstractString) = processor.inner(s)

function install_instruction_message(app::AbstractString, instruction_url::AbstractString)
    """
    Follow this [instruction]($instruction_url)
    to install the `$app` app.
    """
end

function check_settings_message(setting_path::String...)
    """
    This value is configured in the `$(join(setting_path, "."))`.
    Please check the settings.
    """
end

function app_notfound_message(app::AbstractString, setting_path::String...; is_default_setting::Bool=true)
    msg = """
    `$app` executable is not found on the `PATH`.
    """

    if !isempty(setting_path) && !is_default_setting
        return msg * check_settings_message(setting_path...)
    end

    if app == "testrunner"
        instruction_url = "https://github.com/aviatesk/JETLS.jl#prerequisites"
    elseif app == "runic"
        instruction_url = "https://github.com/fredrikekre/Runic.jl#installation"
    end

    return msg * install_instruction_message(app, instruction_url)
end
