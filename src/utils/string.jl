# JuliaSyntax/JuliaLowering uses byte offsets; LSP uses lineno and UTF-* character offset.
# These functions do the conversion.

backtick(s...) = string('`', s..., '`')::String

"""
    apply_text_change(
        text::String, range::Range, new_text::String, encoding::PositionEncodingKind.Ty
    ) -> String

Apply a text change (replacement) to a string at the specified range.

This function handles incremental text document changes as specified in the LSP protocol.
It converts the LSP range (0-based line/character positions) to byte offsets and replaces
the specified range with the new text.

# Arguments
- `text::String`: The original text content
- `range::Range`: The LSP range to replace (0-based line and character positions)
- `new_text::String`: The text to insert at the specified range
- `encoding::PositionEncodingKind.Ty`: The encoding for character positions
"""
function apply_text_change(
        text::String, range::Range, new_text::String, encoding::PositionEncodingKind.Ty
    )
    textbuf = Vector{UInt8}(text)
    line_starts = build_line_starts(textbuf)
    start_byte = _xy_to_offset(textbuf, range.start, encoding, line_starts)
    end_byte = _xy_to_offset(textbuf, range.var"end", encoding, line_starts)
    return String(textbuf[1:start_byte-1]) * new_text * String(textbuf[end_byte:end])
end

# UTF-8 leading byte → (n_bytes_in_sequence, n_code_units_in_target_encoding).
# Continuation bytes (0x80..0xBF) appearing as a "leading byte" indicate malformed
# UTF-8; we treat them as a single 1-unit char rather than throwing — matching the
# robustness contract the LSP layer expects from invalid client input.
# `encoding` only differentiates the 4-byte branch (UTF-16 surrogate pair = 2 units
# vs. 1 unit elsewhere); callers short-circuit the UTF-8 path before reaching here.
@inline function utf8_seq_info(byte::UInt8, encoding::PositionEncodingKind.Ty)
    if byte < 0x80
        return 1, UInt(1)
    elseif byte < 0xC0
        return 1, UInt(1)
    elseif byte < 0xE0
        return 2, UInt(1)
    elseif byte < 0xF0
        return 3, UInt(1)
    else
        return 4, encoding == PositionEncodingKind.UTF16 ? UInt(2) : UInt(1)
    end
end

"""
    xy_to_offset(fi::FileInfo, pos::Position) -> byte::Int

Convert a 0-based line and character position to a 1-based byte offset.

# Arguments
- `fi::FileInfo`: The file info containing the parsed content
- `pos::Position`: 0-based position with `line` and `character` fields

# Returns
1-based byte offset into the UTF-8 encoded buffer.

# Note
This function is designed to be robust against invalid positions that some LSP clients
may send. If the position is beyond the end of a line or file, it clamps to valid bounds
rather than throwing an error. The returned byte offset in such cases points to the
closest valid position.

# See also
[`offset_to_xy`](@ref) - Convert byte offset to line/character position
"""
function xy_to_offset end

xy_to_offset(fi::FileInfo, pos::Position) =
    _xy_to_offset(fi.parsed_stream.textbuf, pos, fi.encoding, fi.line_starts)
xy_to_offset( # used by tests
    s::Union{Vector{UInt8},AbstractString}, pos::Position, filename::AbstractString,
    encoding::PositionEncodingKind.Ty = PositionEncodingKind.UTF16
) = xy_to_offset(FileInfo(#=version=#0, s, filename, encoding), pos)

function _xy_to_offset(
        textbuf::Vector{UInt8}, pos::Position, encoding::PositionEncodingKind.Ty,
        line_starts::LineStartsIndex
    )
    line_idx = min(Int(pos.line) + 1, length(line_starts))
    line_start_byte = line_starts[line_idx]
    line_end_byte = line_idx + 1 <= length(line_starts) ?
        line_starts[line_idx + 1] - 1 : lastindex(textbuf) + 1
    return units_to_byte_in_line(textbuf, line_start_byte, line_end_byte, pos.character, encoding)
end

# `ch` code units into the line → 1-based byte offset within textbuf. If `ch`
# falls in the middle of a multi-unit character (UTF-16 surrogate pair), returns
# the byte offset of that character.
function units_to_byte_in_line(
        textbuf::Vector{UInt8}, line_start::Integer, line_end::Integer,
        ch::Integer, encoding::PositionEncodingKind.Ty
    )
    if encoding == PositionEncodingKind.UTF8
        return min(Int(line_start) + Int(ch), Int(line_end))
    end
    target = UInt(ch)
    i = Int(line_start)
    bend = Int(line_end)
    units = UInt(0)
    @inbounds while i < bend && units < target
        n_bytes, n_units = utf8_seq_info(textbuf[i], encoding)
        if units + n_units > target
            break
        end
        units += n_units
        i += n_bytes
    end
    return i
end

"""
    offset_to_xy(fi::FileInfo, byte::Integer) -> pos::Position
    offset_to_xy(sfi::SavedFileInfo, byte::Integer) -> pos::Position

Convert a 1-based byte offset to a 0-based line and character number.

# Arguments
- `fi::FileInfo`: The file info containing the parsed content
- `byte::Integer`: 1-based byte offset into the buffer

# Returns
`pos::Position` where both are 0-based indices, with character position calculated according
to the specified encoding per LSP specification:
- UTF-8: Byte offset within the line
- UTF-16: UTF-16 code units (BMP chars = 1 unit, non-BMP = 2 units)
- UTF-32: Character count (each Unicode character = 1 unit)

# See also
[`xy_to_offset`](@ref) - Convert line/character position to byte offset
"""
function offset_to_xy end

offset_to_xy(fi::FileInfo, byte::Integer) =
    _offset_to_xy(fi.parsed_stream.textbuf, byte, fi.encoding, fi.line_starts)
offset_to_xy(sfi::SavedFileInfo, byte::Integer) =
    _offset_to_xy(sfi.parsed_stream.textbuf, byte, sfi.encoding, sfi.line_starts)
offset_to_xy( # used by tests
    s::Union{Vector{UInt8},AbstractString}, byte::Integer, filename::AbstractString,
    encoding::PositionEncodingKind.Ty = PositionEncodingKind.UTF16
) = offset_to_xy(FileInfo(#=version=#0, s, filename, encoding), byte)

# One-shot overload for callers that don't have a cached index and only convert
# a single offset (e.g. `cell_range`); builds `line_starts` internally.
_offset_to_xy(textbuf::Vector{UInt8}, byte::Integer, encoding::PositionEncodingKind.Ty) =
    _offset_to_xy(textbuf, byte, encoding, build_line_starts(textbuf))

function _offset_to_xy(
        textbuf::Vector{UInt8}, byte::Integer, encoding::PositionEncodingKind.Ty,
        line_starts::LineStartsIndex
    )
    if byte < 1
        throw(ArgumentError(lazy"Byte offset must be >= 1, got $byte"))
    elseif byte > lastindex(textbuf) + 1
        byte = lastindex(textbuf) + 1
    end

    line_idx = searchsortedlast(line_starts, byte)
    line = line_idx - 1
    line_start_byte = line_starts[line_idx]
    line_end_byte = line_idx + 1 <= length(line_starts) ?
        line_starts[line_idx + 1] - 1 :
        lastindex(textbuf) + 1
    target = min(Int(byte), line_end_byte)
    character = Int(count_units_in_byte_range(textbuf, line_start_byte, target, encoding))
    return Position(; line, character)
end

# Byte range → number of code units of the requested encoding. Walks the line
# only (not the whole textbuf) and avoids `String(copy(...))` allocations.
function count_units_in_byte_range(
        textbuf::Vector{UInt8}, b_start::Integer, b_end::Integer,
        encoding::PositionEncodingKind.Ty
    )
    if encoding == PositionEncodingKind.UTF8
        return UInt(b_end - b_start)
    end
    units = UInt(0)
    i = Int(b_start)
    bend = Int(b_end)
    @inbounds while i < bend
        n_bytes, n_units = utf8_seq_info(textbuf[i], encoding)
        if i + n_bytes > bend
            break # partial char at the end (shouldn't happen for well-formed input)
        end
        units += n_units
        i += n_bytes
    end
    return units
end

"""
    get_text_and_positions(
            text::AbstractString;
            matcher::Regex = r"│",
            encoding::PositionEncodingKind.Ty = PositionEncodingKind.UTF16
        ) -> (clean_text::String, positions::Vector{Position})

Extract positions of markers in text and return the cleaned text with markers removed.

This function is primarily used in tests to mark specific positions in code snippets.
It finds all occurrences of the marker pattern, records their positions as LSP-compatible
`Position` objects, and returns the text with all markers removed.

# Arguments
- `text::AbstractString`: The input text containing position markers
- `matcher::Regex=r"│"`: The regex pattern to match position markers (default: `│`)
- `encoding::PositionEncodingKind.Ty=PositionEncodingKind.UTF16`: The encoding for character positions

# Returns
`(clean_text::String, positions::Vector{Position})`:
- `clean_text::String`: The input text with all markers removed
- `positions::Vector{Position}`: LSP Position objects (0-based line and character indices)

# Notes
- Character positions are calculated correctly for multi-byte characters (e.g., Unicode)
- The function properly converts byte offsets to character offsets as required by LSP
- Positions are 0-based as per LSP specification

# Example
```julia
text = \"\"\"
function foo()
    return x│ + 1
end
\"\"\"
clean_text, positions = get_text_and_positions(text)
# clean_text: "function foo()\\n    return x + 1\\nend\\n"
# positions: [Position(line=1, character=11)]
```
"""
function get_text_and_positions(
        text::AbstractString;
        matcher::Regex = r"│",
        encoding::PositionEncodingKind.Ty = PositionEncodingKind.UTF16
    )
    positions = Position[]
    lines = split(text, '\n')

    for (i, line) in enumerate(lines)
        char_offset_adjustment = 0
        for m in eachmatch(matcher, line)
            if encoding == PositionEncodingKind.UTF8
                char_offset = m.offset - 1  # m.offset is 1-based, LSP is 0-based
            elseif encoding == PositionEncodingKind.UTF16
                char_offset = 0
                byte_pos = 1
                while byte_pos < m.offset
                    cp = codepoint(line[byte_pos])
                    char_offset += cp < 0x10000 ? 1 : 2
                    byte_pos = nextind(line, byte_pos)
                end
            else # UTF-32
                char_offset = 0
                byte_pos = 1
                while byte_pos < m.offset
                    char_offset += 1
                    byte_pos = nextind(line, byte_pos)
                end
            end

            adjusted_char_offset = char_offset - char_offset_adjustment
            push!(positions, Position(; line=i-1, character=adjusted_char_offset))

            if encoding == PositionEncodingKind.UTF8
                char_offset_adjustment += sizeof(m.match)
            elseif encoding == PositionEncodingKind.UTF16
                marker_length = 0
                for c in m.match
                    cp = codepoint(c)
                    marker_length += cp < 0x10000 ? 1 : 2
                end
                char_offset_adjustment += marker_length
            else # UTF-32
                char_offset_adjustment += length(m.match)
            end
        end
    end

    for (i, line) in enumerate(lines)
        lines[i] = replace(line, matcher => "")
    end

    return join(lines, '\n'), positions
end

"""
    encoded_length(s::AbstractString, encoding::PositionEncodingKind.Ty) -> Int

Calculate the length of a string in the specified encoding units.

# Returns
- UTF-8: byte count (same as `sizeof(s)`)
- UTF-16: UTF-16 code unit count (BMP chars = 1, non-BMP = 2)
- UTF-32: character count (same as `length(s)`)
"""
function encoded_length(s::AbstractString, encoding::PositionEncodingKind.Ty)
    if encoding == PositionEncodingKind.UTF8
        return sizeof(s)
    elseif encoding == PositionEncodingKind.UTF32
        return length(s)
    else # UTF-16
        count = 0
        for c in s
            cp = codepoint(c)
            count += cp < 0x10000 ? 1 : 2
        end
        return count
    end
end
