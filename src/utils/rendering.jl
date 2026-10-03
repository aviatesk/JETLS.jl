# Older Julia versions mutate shared module-color caches even for uncolored output.
# Remove this workaround once all supported versions have Base's color-cache lock.
# This only coordinates JETLS renderers, not independent dependency logging.
@static if isdefined(Base, :get_stacktrace_color) # JuliaLang/julia#63554
    with_base_render_lock(f::F, args...; kwargs...) where {F} = f(args...; kwargs...)
else
    const BASE_RENDER_LOCK = ReentrantLock()
    function with_base_render_lock(f::F, args...; kwargs...) where {F}
        return @lock BASE_RENDER_LOCK f(args...; kwargs...)
    end
end

function locked_showerror(io::IO, @nospecialize(err), args...; kwargs...)
    return with_base_render_lock(showerror, io, err, args...; kwargs...)
end

function locked_display_error(io::IO, @nospecialize(err), bt::Vector)
    return with_base_render_lock(Base.display_error, io, err, bt)
end

function locked_show_backtrace(io::IO, bt::Vector)
    return with_base_render_lock(Base.show_backtrace, io, bt)
end
