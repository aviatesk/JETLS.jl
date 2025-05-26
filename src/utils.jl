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
get_fileinfo(s::ServerState, uri::URI) = haskey(s.file_cache, uri) ? s.file_cache[uri] : nothing
get_fileinfo(s::ServerState, t::TextDocumentIdentifier) = get_fileinfo(s, URI(t.uri))

# JuliaLowering uses byte offsets; LSP uses lineno and UTF-* character offset.
# These functions do the conversion.

"""
    xy_to_offset(code::Vector{UInt8}, pos::Position)
    xy_to_offset(fi::FileInfo, pos::Position)

Convert 0-based `pos::Position` (equivalent to `(; line = y, character = x)`) to a 1-based byte offset.
Basically, `pos` is expected to be valid with respect to `code`.
However, some language server clients sometimes send invalid `Position`s,
so this function is designed not to error on such invalid `Position`s.
Note that the byte offset returned in such cases has almost no meaning.
"""
function xy_to_offset(code::Vector{UInt8}, pos::Position)
    b = 0
    for z in 1:pos.line
        nextb = findnext(isequal(UInt8('\n')), code, b + 1)
        if isnothing(nextb) # guard against invalid `pos`
            break
        end
        b = nextb
    end
    lend = findnext(isequal(UInt8('\n')), code, b + 1)
    lend = isnothing(lend) ? lastindex(code) + 1 : lend
    curline = String(code[b+1:lend-1]) # current line, containing no newlines
    line_b = 1
    for i in 1:pos.character
        checkbounds(Bool, curline, line_b) || break # guard against invalid `pos`
        line_b = nextind(curline, line_b)
    end
    return b + line_b
end
xy_to_offset(fi::FileInfo, pos::Position) = xy_to_offset(fi.parsed_stream.textbuf, pos)

"""
    offset_to_xy(ps::JS.ParseStream, b::Integer)
    offset_to_xy(fi::FileInfo, b::Integer)

Convert a 1-based byte offset to a 0-based line and character number
"""
function offset_to_xy(ps::JS.ParseStream, b::Integer)
    # ps must be parsed already
    @assert b in JS.first_byte(ps):JS.last_byte(ps) + 1
    sf = JS.SourceFile(ps)
    l, c = JuliaSyntax.source_location(sf, b)
    return Position(;line = l-1, character = c-1)
end
function offset_to_xy(code::Union{AbstractString, Vector{UInt8}}, b::Integer) # used by tests
    ps = JS.parse!(JS.ParseStream(code), rule=:all)
    return offset_to_xy(ps, b)
end
offset_to_xy(fi::FileInfo, b::Integer) = offset_to_xy(fi.parsed_stream, b)
