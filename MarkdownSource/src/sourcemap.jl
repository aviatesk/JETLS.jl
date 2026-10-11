"""
    Span(first::Int, past_last::Int)

A half-open range of 1-based UTF-8 byte offsets into a document's source.
"""
struct Span
    first::Int
    past_last::Int
end

# Spans not recorded yet; source offsets start at 1.
const UNSET = Span(0, 0)

# Bytes `offset:offset+length-1` of a stream, as 0-based positions, are the source bytes
# `first:first+length-1`.
struct Segment
    offset::Int
    first::Int
    length::Int
end

"""
    SourceMap

Maps the bytes of a string derived from the source, such as the `code` of a `Code`, back
to the source. Most bytes are copied from the source, but some are not, e.g. the `\\n` that
replaces a `\\r\\n`. See `source_span`.
"""
struct SourceMap
    segments::Vector{Segment}
end

"""
    LinkSpans

The source locations of the parts of a `Link` or an `Image`:

- `text`: the text between the brackets, i.e. the link text or the alternative text
- `url`: the destination between the parentheses, or between the angle brackets of an
  autolink. It covers the destination as written, while `url` of the element has escapes
  and entities replaced, and `mailto:` prepended to email autolinks.
"""
struct LinkSpans
    text::Span
    url::Span
end

# Index of the last segment starting at or before `position`, or 0
function segment_index(segments::Vector{Segment}, position::Int)
    lo, hi = 1, length(segments)
    while lo ≤ hi
        mid = (lo + hi) >>> 1
        if segments[mid].offset ≤ position
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return hi
end

# The source offset of the byte at `position`. A byte not copied from the source maps to the
# next source byte that is.
function start_offset(segments::Vector{Segment}, position::Int)
    i = segment_index(segments, position)
    if i > 0
        segment = segments[i]
        position < segment.offset + segment.length &&
            return segment.first + (position - segment.offset)
    end
    i < length(segments) && return segments[i+1].first
    segment = segments[end]
    return segment.first + segment.length
end

# The source offset right after the byte before `position`. A byte not copied from the source
# maps to the end of the previous source byte that is.
function end_offset(segments::Vector{Segment}, position::Int)
    i = segment_index(segments, position - 1)
    i == 0 && return segments[1].first
    segment = segments[i]
    return segment.first + min(position - segment.offset, segment.length)
end

# Map the bytes `first:past_last-1` at 0-based positions to the source.
function source_span(segments::Vector{Segment}, first::Int, past_last::Int)
    start = start_offset(segments, first)
    first == past_last && return Span(start, start)
    return Span(start, max(start, end_offset(segments, past_last)))
end

"""
    source_span(map::SourceMap, first::Int, past_last::Int) -> Span

Return the span of the source that the bytes `first:past_last-1` of the string described by
`map` come from. Bytes not copied from the source are attributed to the source bytes next to
them.
"""
source_span(map::SourceMap, first::Int, past_last::Int) =
    source_span(map.segments, first - 1, past_last - 1)

#####################
# Recording streams #
#####################

# The parser reads nested blocks and inline content from new streams, such as the lines of
# a block quote without their `>` markers. A `StreamMap` holds the content of such a stream
# and where its bytes come from in the source.
struct StreamMap
    text::String
    segments::Vector{Segment}
end

# Elements are keys of `links` and `contents`, but their types are defined later.
struct Recorder
    maps::IdDict{IOBuffer,StreamMap}
    # Segments of the buffers being written by `copyline!`
    pending::IdDict{IOBuffer,Vector{Segment}}
    spans::IdDict{Any,Vector{Span}}
    links::IdDict{Any,LinkSpans}
    contents::IdDict{Any,SourceMap}
end
Recorder() = Recorder(IdDict{IOBuffer,StreamMap}(), IdDict{IOBuffer,Vector{Segment}}(),
    IdDict{Any,Vector{Span}}(), IdDict{Any,LinkSpans}(), IdDict{Any,SourceMap}())

const RECORDER = ScopedValue{Union{Nothing,Recorder}}(nothing)

# The recorder and the map of `stream`, unless locations in `stream` are not recorded
function recording(stream::IO)
    recorder = RECORDER[]
    recorder === nothing && return nothing
    map = get(recorder.maps, stream, nothing)
    (map === nothing || isempty(map.segments)) && return nothing
    return recorder, map
end

function push_segment!(segments::Vector{Segment}, segment::Segment)
    if !isempty(segments)
        last = segments[end]
        if last.offset + last.length == segment.offset &&
                last.first + last.length == segment.first
            segments[end] = Segment(last.offset, last.first, last.length + segment.length)
            return segments
        end
    end
    return push!(segments, segment)
end

# Append the segments of `length` bytes copied from `map` at `position`, placed at `offset`
# of another stream.
function compose!(composed::Vector{Segment}, map::StreamMap, offset::Int, position::Int,
                  length::Int)
    segments = map.segments
    stop = position + length
    for i in max(segment_index(segments, position), 1):lastindex(segments)
        segment = segments[i]
        segment.offset ≥ stop && break
        first = max(position, segment.offset)
        past_last = min(stop, segment.offset + segment.length)
        first < past_last && push_segment!(composed, Segment(offset + (first - position),
            segment.first + (first - segment.offset), past_last - first))
    end
    return composed
end
compose(map::StreamMap, offset::Int, position::Int, length::Int) =
    compose!(Segment[], map, offset, position, length)

isblank(byte::UInt8) =
    byte == UInt8(' ') || byte == UInt8('\t') || byte == UInt8('\n') || byte == UInt8('\r')

# Map the bytes `first:past_last-1` at 0-based positions of `map` to the source, from the
# first non-whitespace byte to the end of the last non-blank line. Spaces at the end of that
# line are kept since they may belong to the text of a paragraph.
function trimmed_span(map::StreamMap, first::Int, past_last::Int)
    bytes = codeunits(map.text)
    start, stop = first, past_last
    while start < stop && isblank(bytes[start+1])
        start += 1
    end
    start == stop && return source_span(map.segments, first, first)
    while isblank(bytes[stop])
        stop -= 1
    end
    while stop < past_last && (bytes[stop+1] == UInt8(' ') || bytes[stop+1] == UInt8('\t'))
        stop += 1
    end
    return source_span(map.segments, start, stop)
end

recorded_spans(recorder::Recorder, items::AbstractVector) =
    get!(Vector{Span}, recorder.spans, items)

# Extend `span` over the spans of `items`, which may end with a line end, e.g. that of a line
# break, while blocks are trimmed
function covering(recorder::Recorder, span::Span, @nospecialize(items))
    items isa AbstractVector || return span
    first, past_last = span.first, span.past_last
    for item_span in get(recorder.spans, items, Span[])
        item_span === UNSET && continue
        first = min(first, item_span.first)
        past_last = max(past_last, item_span.past_last)
    end
    return Span(first, past_last)
end

function set_span!(recorder::Recorder, items::AbstractVector, i::Int, span::Span)
    spans = recorded_spans(recorder, items)
    length(spans) < length(items) && append!(spans, fill(UNSET, length(items) - length(spans)))
    spans[i] = span
    return spans
end

# A new stream reading `text`, copied from `stream` at `position`
function mapped_stream(text::String, stream::IO, position::Int)
    new = IOBuffer(text)
    found = recording(stream)
    found === nothing && return new
    recorder, map = found
    segments = compose(map, 0, position, ncodeunits(text))
    isempty(segments) || (recorder.maps[new] = StreamMap(text, segments))
    return new
end

leading_space(text::AbstractString) = ncodeunits(text) - ncodeunits(lstrip(text))

# Length of the run of the byte at `position`
function delimiter_run(bytes::AbstractVector{UInt8}, position::Int)
    n = 1
    while position + n < length(bytes) && bytes[position+n+1] == bytes[position+1]
        n += 1
    end
    return n
end

function record_content!(recorder::Recorder, @nospecialize(element), text::String,
                         map::StreamMap, position::Int)
    segments = compose(map, 0, position, ncodeunits(text))
    isempty(segments) || (recorder.contents[element] = SourceMap(segments))
    return nothing
end

##############################
# Hooks called by the parser #
##############################

# `write(buffer, readline(stream; keep))`, recording where the line comes from
function copyline!(buffer::IOBuffer, stream::IO; keep::Bool = true)
    position_before = position(stream)
    line = readline(stream; keep)
    found = recording(stream)
    if found !== nothing
        recorder, map = found
        segments = get!(Vector{Segment}, recorder.pending, buffer)
        if isempty(line)
            # Locate what the buffer holds even if it is empty, e.g. an empty list item.
            push_segment!(segments,
                Segment(position(buffer), start_offset(map.segments, position_before), 0))
        else
            compose!(segments, map, position(buffer), position_before, ncodeunits(line))
        end
    end
    write(buffer, line)
    return nothing
end

# Like `takestring!(buffer)`, but return a stream of the string, recording that its bytes
# come from where `copyline!` copied them from
function takebuffer!(buffer::IOBuffer)
    text = String(take!(buffer))
    new = IOBuffer(text)
    recorder = RECORDER[]
    recorder === nothing && return new
    segments = pop!(recorder.pending, buffer, nothing)
    segments === nothing || (recorder.maps[new] = StreamMap(text, segments))
    return new
end

# A stream reading `text`, copied from `stream` at `position`
substream(text::String, stream::IO, position::Int) = mapped_stream(text, stream, position)

# A stream reading `text`, a substring of the line of `stream` starting at `line_start`
linestream(text::SubString{String}, stream::IO, line_start::Int) =
    mapped_stream(String(text), stream, line_start + text.offset)

# A stream reading `text`, the content `parse_inline_wrapper` just read from `stream`
function wrappedstream(text::String, stream::IO)
    found = recording(stream)
    found === nothing && return IOBuffer(text)
    _, map = found
    # The closing delimiter run is as long as the opening one, and follows content that does
    # not end with the delimiter.
    bytes = codeunits(map.text)
    stop = position(stream)
    n = 0
    while stop - n > 0 && bytes[stop-n] == bytes[stop]
        n += 1
    end
    return mapped_stream(text, stream, stop - n - ncodeunits(text))
end

# The line starting at `line_start` and the 0-based byte ranges of its cells, as split by
# `parserow`. Empty `SubString`s do not keep their offsets, hence the ranges.
function raw_cells(map::StreamMap, line_start::Int)
    line = readline(seek(IOBuffer(map.text), line_start))
    cells = UnitRange{Int}[]
    first = 0
    for separator in eachmatch(r"(?<!\\)\|", line)
        push!(cells, first:separator.offset-2)
        first = separator.offset
    end
    push!(cells, first:ncodeunits(line)-1)
    isempty(cells[1]) && popfirst!(cells)
    return line, cells
end

cell_text(line::String, cell::UnitRange{Int}) = String(codeunits(line)[cell .+ 1])

# A stream reading `cell`, the `column`-th cell of the table row of `stream` starting at
# `line_start`, as stripped and unescaped by `parserow`
function cellstream(cell::AbstractString, stream::IO, line_start::Int, column::Int)
    text = String(cell)
    new = IOBuffer(text)
    found = recording(stream)
    found === nothing && return new
    recorder, map = found
    line, cells = raw_cells(map, line_start)
    column ≤ length(cells) || return new
    cell_range = cells[column]
    raw = cell_text(line, cell_range)
    segments = Segment[]
    bytes = codeunits(raw)
    offset = 0
    i = leading_space(raw) + 1
    while offset < ncodeunits(text) && i ≤ length(bytes)
        # `parserow` replaces `\|` by `|`.
        if bytes[i] == UInt8('\\') && i < length(bytes) && bytes[i+1] == UInt8('|')
            i += 1
        end
        compose!(segments, map, offset, line_start + first(cell_range) + i - 1, 1)
        offset += 1
        i += 1
    end
    isempty(segments) || (recorder.maps[new] = StreamMap(text, segments))
    return new
end

# Called by `_parse` after a block parser read `stream` from `start` on and pushed new
# elements after the first `n` elements of `block`. Paragraphs record their own spans, since
# their parser also reads the blocks interrupting them.
function record_blocks!(block, stream::IO, n::Int, start::Int)
    found = recording(stream)
    found === nothing && return true
    recorder, map = found
    content = block.content
    spans = recorded_spans(recorder, content)
    for i in n+1:length(content)
        i ≤ length(spans) && spans[i] !== UNSET && continue
        element = content[i]
        span = trimmed_span(map, start, position(stream))
        spans = set_span!(recorder, content, i, covering(recorder, span, children(element)))
        if element isa Markdown.LaTeX && !haskey(recorder.contents, element)
            # `$$ ... $$` parsed by `blocktex`
            bytes = codeunits(map.text)
            formula_start = start
            while isblank(bytes[formula_start+1])
                formula_start += 1
            end
            formula_start += delimiter_run(bytes, formula_start)
            record_content!(recorder, element, element.formula, map, formula_start)
        elseif element isa Markdown.Table
            record_table!(recorder, element, map, start)
        end
    end
    return true
end

# `github_table` reads the rows from consecutive lines, the second one aligning the columns.
function record_table!(recorder::Recorder, table, map::StreamMap, start::Int)
    stream = seek(IOBuffer(map.text), start)
    for i in 1:length(table.rows)+1
        line_start = position(stream)
        line, cells = raw_cells(map, line_start)
        readline(stream)
        i == 2 && continue
        r = max(i - 1, 1)
        row = table.rows[r]
        set_span!(recorder, table.rows, r,
            trimmed_span(map, line_start, line_start + ncodeunits(line)))
        line_end = line_start + ncodeunits(rstrip(line))
        for column in 1:length(row)
            span = if column ≤ length(cells)
                cell_range = cells[column]
                raw = cell_text(line, cell_range)
                first = line_start + Base.first(cell_range) + leading_space(raw)
                past_last = line_start + Base.first(cell_range) + ncodeunits(rstrip(raw))
                source_span(map.segments, first, max(first, past_last))
            else
                source_span(map.segments, line_end, line_end)
            end
            set_span!(recorder, row, column, span)
        end
    end
    return nothing
end

# Called by `paragraph` with the buffer of its text, read from `stream` at `start`
function record_paragraph!(block, paragraph, buffer::IOBuffer, stream::IO, start::Int)
    found = recording(stream)
    found === nothing && return nothing
    recorder, map = found
    text = String(take!(copy(buffer)))
    # The text is copied from the stream, except that line ends become `\n`, and that with
    # `\r` line ends, `_parse` skips blank lines while checking whether a block interrupts
    # the paragraph, which drops them from the text.
    segments = Segment[]
    bytes = codeunits(map.text)
    position = start
    run_offset, run_position, run_length = 0, start, 0
    for offset in 0:ncodeunits(text)-1
        byte = codeunit(text, offset + 1)
        newline = byte == UInt8('\n')
        while position < length(bytes) && bytes[position+1] != byte &&
                !(newline && bytes[position+1] == UInt8('\r'))
            position += 1
        end
        position < length(bytes) || return nothing
        if newline && bytes[position+1] == UInt8('\r') && position + 1 < length(bytes) &&
                bytes[position+2] == UInt8('\n')
            # Attribute the `\n` to the `\n` of the `\r\n`.
            position += 1
        end
        if run_length > 0 && run_position + run_length == position
            run_length += 1
        else
            run_length > 0 && compose!(segments, map, run_offset, run_position, run_length)
            run_offset, run_position, run_length = offset, position, 1
        end
        position += 1
    end
    run_length > 0 && compose!(segments, map, run_offset, run_position, run_length)
    isempty(segments) && return nothing
    recorder.maps[buffer] = StreamMap(text, segments)
    # Not trimmed, since the text may end with a line end escaped by `\`
    i = findlast(x -> x === paragraph, block.content)
    i === nothing || set_span!(recorder, block.content, i,
        source_span(segments, 0, ncodeunits(text)))
    return nothing
end

# Called by `pushitem!` with the stream of the item just pushed to `items`
function record_item!(items::Vector, stream::IO)
    found = recording(stream)
    found === nothing && return nothing
    recorder, map = found
    span = trimmed_span(map, 0, ncodeunits(map.text))
    set_span!(recorder, items, length(items), covering(recorder, span, items[end]))
    return nothing
end

# Called by `parseinline` after it pushed an element parsed from `inner_start` on, after any
# text read from `text_start` on. Returns where the next text starts.
function record_inline!(content::Vector, stream::IO, text_start::Int, inner_start::Int)
    stop = position(stream)
    found = recording(stream)
    found === nothing && return stop
    recorder, map = found
    n = length(content)
    if length(recorded_spans(recorder, content)) < n - 1
        set_span!(recorder, content, n - 1, source_span(map.segments, text_start, inner_start))
    end
    set_span!(recorder, content, n, trimmed_span(map, inner_start, stop))
    element = content[n]
    bytes = codeunits(map.text)
    if element isa Markdown.Code || element isa Markdown.LaTeX
        text = element isa Markdown.Code ? element.code : element.formula
        code_start = inner_start + delimiter_run(bytes, inner_start)
        if bytes[inner_start+1] == UInt8('`')
            # `inline_code` strips the code.
            code_start += leading_space(String(bytes[code_start+1:stop]))
        end
        record_content!(recorder, element, text, map, code_start)
    elseif element isa Markdown.Link && !haskey(recorder.links, element)
        # An autolink, whose text is its destination
        span = source_span(map.segments, inner_start + 1, stop - 1)
        recorder.links[element] = LinkSpans(span, span)
        set_span!(recorder, element.text, 1, span)
    end
    return stop
end

# Called by `parseinline` at the end of `stream`, after any text read from `text_start` on
function record_text!(content::Vector, stream::IO, text_start::Int)
    found = recording(stream)
    found === nothing && return nothing
    recorder, map = found
    n = length(content)
    if length(recorded_spans(recorder, content)) < n
        set_span!(recorder, content, n, source_span(map.segments, text_start, position(stream)))
    end
    return nothing
end

# Called by `link` and `image` with where their text and their destination start
function record_link!(element, stream::IO, text_start::Int, text_stop::Int, url_start::Int)
    found = recording(stream)
    found === nothing && return element
    recorder, map = found
    text = source_span(map.segments, text_start, text_stop)
    url = source_span(map.segments, url_start, position(stream) - 1)
    recorder.links[element] = LinkSpans(text, url)
    return element
end

# Called by the parsers of code blocks with the buffer their lines were copied to
function sourced(element, buffer::IOBuffer)
    recorder = RECORDER[]
    recorder === nothing && return element
    segments = pop!(recorder.pending, buffer, nothing)
    segments === nothing && return element
    text = element isa Markdown.Code ? element.code : element.formula
    length = ncodeunits(text)
    clipped = Segment[Segment(s.offset, s.first, min(s.length, length - s.offset))
        for s in segments if s.offset < length]
    isempty(clipped) || (recorder.contents[element] = SourceMap(clipped))
    return element
end
