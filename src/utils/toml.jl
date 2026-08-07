"""
    format_toml_inline_table(table::AbstractDict{String}) -> String

Serialize `table` as a TOML inline table without an enclosing key assignment.
"""
function format_toml_inline_table(table::AbstractDict{String})
    inline_tables = Base.IdSet{typeof(table)}()
    push!(inline_tables, table)
    io = IOBuffer()
    TOML.print(io, Dict("value" => table); inline_tables)
    text = chomp(String(take!(io)))
    prefix = "value = "
    @assert startswith(text, prefix)
    return String(text[sizeof(prefix)+1:end])
end

"""
    toml_array_entry_insertion(
        text::String, content_start_offset::Int, entry::String,
        isempty_array::Bool
    ) -> Tuple{Int,String}

Return the end byte offset and replacement text for inserting `entry` at the start of a
TOML array. `content_start_offset` is the 1-based byte offset immediately after the
opening `[`.
"""
function toml_array_entry_insertion(
        text::String, content_start_offset::Int, entry::String, isempty_array::Bool
    )
    bytes = codeunits(text)
    content_start_offset > length(bytes) && return content_start_offset, entry
    first_byte = bytes[content_start_offset]
    if first_byte != UInt8('\n') && first_byte != UInt8('\r')
        return content_start_offset, entry * (isempty_array ? "" : ", ")
    end
    indent_start = content_start_offset + 1
    if (first_byte == UInt8('\r') && indent_start ≤ length(bytes) &&
            bytes[indent_start] == UInt8('\n'))
        indent_start += 1
    end
    end_offset = indent_start
    while (end_offset ≤ length(bytes) &&
            (bytes[end_offset] == UInt8(' ') || bytes[end_offset] == UInt8('\t')))
        end_offset += 1
    end
    linebreak = String(bytes[content_start_offset:indent_start-1])
    indent = String(bytes[indent_start:end_offset-1])
    prefix = linebreak * indent
    separator = (isempty_array ? "" : ",") * linebreak * indent
    return end_offset, prefix * entry * separator
end
