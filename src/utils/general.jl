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

let debounced = Dict{UInt, Timer}(),
    on_cancels = Dict{UInt, Any}()
    global function debounce(f, id::UInt, delay; on_cancel=nothing)
        if haskey(debounced, id)
            close(debounced[id])
            if haskey(on_cancels, id)
                try
                    on_cancels[id]()
                finally
                    delete!(on_cancels, id)
                end
            end
        end

        if on_cancel !== nothing
            on_cancels[id] = on_cancel
        end

        debounced[id] = Timer(delay) do _
            try
                f()
            finally
                delete!(debounced, id)
                delete!(on_cancels, id)
            end
        end
        nothing
    end
end

let throttled = Dict{UInt, Tuple{Union{Nothing,Timer}, Float64}}(),
    on_cancels = Dict{UInt, Any}()
    global function throttle(f, id::UInt, interval; on_cancel=nothing)
        if !haskey(throttled, id)
            f()
            throttled[id] = (nothing, time())
            return nothing
        end
        last_timer, last_time = throttled[id]
        if last_timer !== nothing
            close(last_timer)
            if haskey(on_cancels, id)
                try
                    on_cancels[id]()
                finally
                    delete!(on_cancels, id)
                end
            end
        end

        if on_cancel !== nothing
            on_cancels[id] = on_cancel
        end

        delay = max(0.0, interval - (time() - last_time))
        throttled[id] = (Timer(delay) do _
            try
                f()
            finally
                throttled[id] = (nothing, time())
                delete!(on_cancels, id)
            end
        end, last_time)
        nothing
    end
end

"""
    getobjpath(obj, path::Symbo...)

An accessor primarily written for accessing fields of LSP objects whose fields
may be unset (set to `nothing`) depending on client/server capabilities.
Traverses the field chain `paths...` of `obj`, and returns `nothing` if any
`nothing` field is encountered along the way.
"""
function getobjpath(obj, path::Symbol, paths::Symbol...)
    nextobj = getfield(obj, path)
    if nextobj === nothing
        return nothing
    end
    getobjpath(nextobj, paths...)
end
getobjpath(obj) = obj
