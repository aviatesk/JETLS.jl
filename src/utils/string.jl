# JuliaSyntax/JuliaLowering uses byte offsets; LSP uses lineno and UTF-* character offset.
# These functions do the conversion.

"""
    pos_to_utf8_offset(s::String, ch::UInt, encoding::PositionEncodingKind.Ty = PositionEncodingKind.UTF16) -> offset::Int

Convert a character position to a UTF-8 byte offset in a Julia string.

# Arguments
- `s::String`: A Julia string (UTF-8 encoded) representing a single line (no newlines)
- `ch::UInt`: 0-based character/code-unit position in the specified encoding
- `encoding::PositionEncodingKind.Ty`: The encoding that `ch` is based on (default: UTF-16)

# Returns
1-based byte offset in the UTF-8 encoded string `s`

# Details
According to the LSP specification:
- For UTF-8: `ch` represents byte offset
- For UTF-16: `ch` represents UTF-16 code units (characters in BMP count as 1, outside BMP count as 2)
- For UTF-32: `ch` represents character count (each Unicode character counts as 1)
"""
function pos_to_utf8_offset(s::String, ch::UInt, encoding::PositionEncodingKind.Ty)
    offset = 1
    char_count = 0
    if encoding == PositionEncodingKind.UTF16
        while offset <= sizeof(s) && char_count < ch
            cp = codepoint(s[offset])
            utf16_units = cp < 0x10000 ? 1 : 2
            char_count += utf16_units
            if char_count > ch
                break
            end
            offset = nextind(s, offset)
        end
    elseif encoding == PositionEncodingKind.UTF8 # UTF-8 counts bytes
        offset = min(Int(ch), sizeof(s)) + 1
    else # UTF-32 counts characters
        while offset <= sizeof(s) && char_count < ch
            char_count += 1
            offset = nextind(s, offset)
        end
    end
    return offset
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

xy_to_offset(fi::FileInfo, pos::Position) = _xy_to_offset(fi.parsed_stream.textbuf, pos, fi.encoding)
xy_to_offset( # used by tests
    s::Union{Vector{UInt8},AbstractString}, pos::Position, filename::AbstractString,
    encoding::PositionEncodingKind.Ty = PositionEncodingKind.UTF16
) = xy_to_offset(FileInfo(#=version=#0, s, filename, encoding), pos)

function _xy_to_offset(textbuf::Vector{UInt8}, pos::Position, encoding::PositionEncodingKind.Ty)
    b = 0
    for _ in 1:pos.line
        nextb = findnext(isequal(UInt8('\n')), textbuf, b + 1)
        if isnothing(nextb) # guard against invalid `pos`
            break
        end
        b = nextb
    end
    lend = findnext(isequal(UInt8('\n')), textbuf, b + 1)
    lend = isnothing(lend) ? lastindex(textbuf) + 1 : lend
    curline = String(textbuf[b+1:lend-1]) # current line, containing no newlines
    return b + pos_to_utf8_offset(curline, pos.character, encoding)
end

"""
    offset_to_xy(fi::FileInfo, byte::Integer) -> pos::Position

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

offset_to_xy(fi::FileInfo, byte::Integer) = _offset_to_xy(fi.parsed_stream.textbuf, byte, fi.encoding)
offset_to_xy( # used by tests
    s::Union{Vector{UInt8},AbstractString}, byte::Integer, filename::AbstractString,
    encoding::PositionEncodingKind.Ty = PositionEncodingKind.UTF16
) = offset_to_xy(FileInfo(#=version=#0, s, filename, encoding), byte)

function _offset_to_xy(textbuf::Vector{UInt8}, byte::Integer, encoding::PositionEncodingKind.Ty)
    if byte < 1
        throw(ArgumentError(lazy"Byte offset must be >= 1, got $byte"))
    elseif byte > lastindex(textbuf) + 1
        byte = lastindex(textbuf) + 1
    end

    # Find which line the byte is on
    line = 0
    line_start_byte = 1
    current_byte = 1

    while current_byte < byte && current_byte <= lastindex(textbuf)
        if textbuf[current_byte] == UInt8('\n')
            line += 1
            line_start_byte = current_byte + 1
        end
        current_byte += 1
    end

    # Find the end of the current line
    line_end_byte = findnext(isequal(UInt8('\n')), textbuf, line_start_byte)
    if isnothing(line_end_byte)
        line_end_byte = lastindex(textbuf) + 1
    end

    target_byte_in_line = min(byte, line_end_byte)

    # Count characters from line start to just before the target position
    if target_byte_in_line > line_start_byte
        if encoding == PositionEncodingKind.UTF8
            # For UTF-8, character is the byte offset within the line (0-based)
            character = target_byte_in_line - line_start_byte
        else
            character = 0
            full_text = String(copy(textbuf))
            byte_idx = line_start_byte

            while byte_idx < target_byte_in_line && byte_idx <= sizeof(full_text)
                next_byte_idx = nextind(full_text, byte_idx)
                if next_byte_idx > target_byte_in_line
                    break
                end

                if encoding == PositionEncodingKind.UTF16
                    cp = codepoint(full_text[byte_idx])
                    character += cp < 0x10000 ? 1 : 2
                else # UTF-32
                    character += 1
                end

                byte_idx = next_byte_idx
            end
        end
    else
        character = 0
    end

    return Position(; line, character)
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
