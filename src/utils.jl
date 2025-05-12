# TODO Need to make them thread safe when making the message handling multithreaded

let debounced = Dict{UInt,Timer}()
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
Fetch cached FileInfo given an LSclient-provided structure with a URI
"""
function get_fileinfo(s::ServerState, t::TextDocumentIdentifier)
    uri = URI(t.uri)
    return haskey(s.file_cache, uri) ? s.file_cache[uri] : nothing
end

# JuliaLowering uses byte offsets; LSP uses lineno and UTF-* character offset.
# These functions do the conversion.

"""
Convert 0-based `(;line = y, character = x)` to a 1-based byte offset
"""
function xy_to_offset(fi::FileInfo, pos::Position)
    code = fi.parsed_stream.textbuf
    b = 0
    for z in 1:pos.line
        b = findnext(isequal(UInt8('\n')), code, b + 1)
    end
    lend = findnext(isequal(UInt8('\n')), code, b + 1)
    lend = isnothing(lend) ? lastindex(code) + 1 : lend
    s = String(code[b+1:lend-1]) # current line, containing no newlines
    line_b = 1
    for i in 1:pos.character
        line_b = nextind(s, line_b)
    end
    return b + line_b
end

"""
Convert a 1-based byte offset to a 0-based line and character number
"""
function offset_to_xy(fi::FileInfo, b::Integer)
    sf = JuliaSyntax.SourceFile(fi.parsed_stream)
    l, c = JuliaSyntax.source_location(sf, b)
    return Position(;line = l-1, character = c-1)
end
