"""
    SourceEdit(span::Span, text::String)

Replace `span` of a document's source with `text`.
"""
struct SourceEdit
    span::Span
    text::String
end

"""
    apply(source::String, edit::SourceEdit) -> String

Return `source` with `edit` applied.
"""
function apply(source::String, edit::SourceEdit)
    bytes = codeunits(source)
    return string(String(bytes[1:edit.span.first-1]), edit.text,
        String(bytes[edit.span.past_last:end]))
end

"""
    minimal_edit(original::String, edited::String) -> SourceEdit

Return the smallest edit that turns `original` into `edited`.
"""
function minimal_edit(original::String, edited::String)
    a, b = codeunits(original), codeunits(edited)
    n = min(length(a), length(b))
    prefix = 0
    while prefix < n && a[prefix+1] == b[prefix+1]
        prefix += 1
    end
    suffix = 0
    while suffix < n - prefix && a[end-suffix] == b[end-suffix]
        suffix += 1
    end
    # Different characters can share leading or trailing bytes; do not split them.
    first = thisind(original, prefix + 1)
    past_last = length(a) - suffix + 1
    while past_last ≤ length(a) && !isvalid(original, past_last)
        past_last += 1
    end
    edited_past_last = length(b) - length(a) + past_last
    return SourceEdit(Span(first, past_last), String(b[first:edited_past_last-1]))
end

const BLANK_BYTES = (UInt8(' '), UInt8('\t'))
const LINE_BREAK_BYTES = (UInt8('\n'), UInt8('\r'))

const SourceBytes = Base.CodeUnits{UInt8,String}

function line_start(bytes::SourceBytes, i::Int)
    while i > 1 && bytes[i-1] != UInt8('\n')
        i -= 1
    end
    return i
end

# The offset of the line break at or after `i`, or one past the end
function line_end(bytes::SourceBytes, i::Int)
    while i ≤ length(bytes) && bytes[i] ∉ LINE_BREAK_BYTES
        i += 1
    end
    return i
end

# The offset of the line after the line break at `i`
function next_line_start(bytes::SourceBytes, i::Int)
    i ≤ length(bytes) && bytes[i] == UInt8('\r') && (i += 1)
    i ≤ length(bytes) && bytes[i] == UInt8('\n') && (i += 1)
    return i
end

# The line ending at or after `offset`, or else the first one in the source
function line_ending(bytes::SourceBytes, offset::Int)
    newline = ==(UInt8('\n'))
    i = something(findnext(newline, bytes, offset), findfirst(newline, bytes), 0)
    return i > 1 && bytes[i-1] == UInt8('\r') ? "\r\n" : "\n"
end

"""
    format_value(value) -> String

Format `value` as a single-line TOML value, writing tables inline.
"""
function format_value(@nospecialize(value))
    if value isa AbstractDict
        entries = (format_key(key) * " = " * format_value(val) for (key, val) in value)
        return "{" * join(entries, ", ")::String * "}"
    elseif value isa AbstractVector
        return "[" * join((format_value(val) for val in value), ", ")::String * "]"
    end
    return String(chop(sprint(TOML.print, Dict("value" => value)); head=8, tail=1))
end

function format_key(@nospecialize(key))
    key isa AbstractString || throw(ArgumentError("TOML keys must be strings"))
    return String(chop(sprint(TOML.print, Dict(key => 0)); tail=5))
end

format_dotted_key(keys::AbstractVector) =
    join((format_key(key) for key in keys), ".")::String

function lookup(data::Dict{String,Any}, path::AbstractVector)
    value = data
    for component in path
        if component isa AbstractString && value isa AbstractDict
            value = get(value, component, nothing)
        elseif component isa Integer && value isa AbstractVector
            checkbounds(Bool, value, component) || return nothing
            value = value[component]
        else
            return nothing
        end
    end
    return value
end

# Return `edit` if applying it parses to `expected`, which guards against edits that
# land in the wrong place or change other data.
function verified(doc::Document, edit::SourceEdit, expected::Dict{String,Any})
    return isequal(parse_data(apply(doc.source, edit)), expected) ? edit : nothing
end

function parsed_value(text::String)
    data = parse_data("value = " * text)
    data isa ParserError && throw(ArgumentError("Cannot format a TOML value: $text"))
    return data["value"]
end

"""
    prepend_array_element(doc::Document, path::AbstractVector, value) -> Union{SourceEdit,Nothing}

Return an edit that inserts `value` before the first element of the array literal at
`path`, or before the closing bracket of an empty one. Text around the insertion point,
including comments, is kept. If the first element is on its own line, the new element gets
its own line with the same indentation and line ending; otherwise it is separated by `, `.

Return `nothing` if `path` is not an array literal, or if the edited source would not parse
to `doc.data` with `value` prepended. Unsupported Julia values throw.
"""
function prepend_array_element(doc::Document, path::AbstractVector, @nospecialize(value))
    array = item(doc, path)
    (array === nothing || array.kind !== ARRAY) && return nothing
    first_element = item(doc, push!(collect(Any, path), 1))
    text = format_value(value)
    edit = array_insertion(doc.source, array.value::Span,
        first_element === nothing ? nothing : first_element.value::Span, text)
    expected = deepcopy(doc.data)
    values = lookup(expected, path)
    values isa AbstractVector || return nothing
    container = lookup(expected, @view path[1:end-1])
    container[path[end]] = pushfirst!(Vector{Any}(values), parsed_value(text))
    return verified(doc, edit, expected)
end

function array_insertion(
        source::String, array::Span, first_element::Union{Nothing,Span}, text::String
    )
    offset = first_element === nothing ? array.past_last - 1 : first_element.first
    bytes = codeunits(source)
    start = line_start(bytes, offset)
    own_line = start > array.first && all(i -> bytes[i] in BLANK_BYTES, start:offset-1)
    separator = if own_line
        newline = start > 2 && bytes[start-2] == UInt8('\r') ? "\r\n" : "\n"
        indent = String(bytes[start:offset-1])
        (first_element === nothing ? "" : ",") * newline * indent
    else
        first_element === nothing ? "" : ", "
    end
    return SourceEdit(Span(offset, offset), text * separator)
end

"""
    insert_table_entry(doc::Document, path::AbstractVector, key::AbstractString, value)
        -> Union{SourceEdit,Nothing}

Return an edit that adds `key = value` to the table at `path`. In the root table or a table
opened by a header, the entry goes on a new line after the last entry of that section, with
the same indentation and line ending, or right after the header of an empty section. In an
inline table, it goes after the last entry, or inside the braces of an empty one.

Return `nothing` if `path` is not such a table, if the table already has `key`, or if the
edited source would not parse to `doc.data` with the entry added. Unsupported Julia values
throw.
"""
function insert_table_entry(
        doc::Document, path::AbstractVector, key::AbstractString, @nospecialize(value)
    )
    table = item(doc, path)
    table === nothing && return nothing
    expected = deepcopy(doc.data)
    target = lookup(expected, path)
    (target isa AbstractDict && !haskey(target, key)) || return nothing
    text = format_value(value)
    entry = format_key(key) * " = " * text
    edit = @something entry_insertion(doc, table, entry) return nothing
    target[key] = parsed_value(text)
    return verified(doc, edit, expected)
end

const SECTION_KINDS = (ROOT_TABLE, HEADER_TABLE, TABLE_ARRAY_ELEMENT)

function entry_insertion(doc::Document, table::Item, entry::String)
    if table.kind === INLINE_TABLE
        braces = table.value::Span
        last_entry = last_entry_in(doc, braces.first + 1, braces.past_last - 1)
        last_entry === nothing &&
            return SourceEdit(Span(braces.past_last - 1, braces.past_last - 1), entry)
        offset = (last_entry.value::Span).past_last
        return SourceEdit(Span(offset, offset), ", " * entry)
    elseif table.kind in SECTION_KINDS
        return section_insertion(doc, table, entry)
    end
    return nothing
end

# Values of nested items end within their parent's value, so the value ending last within a
# range belongs to the last entry there.
function last_entry_in(doc::Document, first::Int, past_last::Int)
    found = nothing
    for item in values(doc.items)
        value = item.value
        (value === nothing || item.kind in SECTION_KINDS) && continue
        first ≤ value.first && value.past_last ≤ past_last || continue
        if found === nothing || value.past_last > (found.value::Span).past_last
            found = item
        end
    end
    return found
end

# A section runs from the end of its header, or the start of the document, to the next
# header.
function section_range(doc::Document, table::Item)
    first = table.kind === ROOT_TABLE ? 1 : (table.value::Span).past_last
    past_last = ncodeunits(doc.source) + 1
    for item in values(doc.items)
        item.kind === HEADER_TABLE || item.kind === TABLE_ARRAY_ELEMENT || continue
        header = item.value::Span
        header.first ≥ first && (past_last = min(past_last, header.first))
    end
    return first, past_last
end

function section_insertion(doc::Document, table::Item, entry::String)
    bytes = codeunits(doc.source)
    first, past_last = section_range(doc, table)
    last_entry = last_entry_in(doc, first, past_last)
    if last_entry === nothing
        if table.kind === ROOT_TABLE
            return SourceEdit(Span(1, 1), entry * line_ending(bytes, 1))
        end
        anchor, indent = first, ""
    else
        anchor = (last_entry.value::Span).past_last
        start = line_start(bytes, (last_entry.entry::Span).first)
        indent_end = start
        while bytes[indent_end] in BLANK_BYTES
            indent_end += 1
        end
        indent = String(bytes[start:indent_end-1])
    end
    offset = line_end(bytes, anchor)
    return SourceEdit(Span(offset, offset), line_ending(bytes, offset) * indent * entry)
end

"""
    delete_entry(doc::Document, path::AbstractVector; prune::Bool = false)
        -> Union{SourceEdit,Nothing}

Return an edit that removes the item at `path`: an item defined by a `key = value` entry,
an element of an array literal, or a table opened by a `[a.b]` header together with its
entries. An entry in a section is removed with its whole lines, including a trailing
comment, along with a blank line next to them if they are between blank lines or at either
end of the source. An array element on a line of its own is removed with that line, and an
entry in an inline table or any other array element with a comma next to it. With `prune`,
tables left empty are removed as well, except the root table and elements of arrays of
tables.

Return `nothing` if the item cannot be removed this way, or if the edited source would not
parse to `doc.data` without the item.
"""
function delete_entry(doc::Document, path::AbstractVector; prune::Bool = false)
    removed, target = removal_paths(doc, path, prune)
    edit = @something deletion(doc, target) return nothing
    expected = deepcopy(doc.data)
    remove!(expected, removed) || return nothing
    return verified(doc, edit, expected)
end

# `removed` is the outermost item that disappears from the data, and `target` the outermost
# one whose text is removed: an implicit table disappears along with its content.
function removal_paths(doc::Document, path::AbstractVector, prune::Bool)
    removed = target = collect(Any, path)
    while prune && length(removed) > 1
        parent = removed[1:end-1]
        table = lookup(doc.data, parent)
        (table isa AbstractDict && length(table) == 1) || break
        parent_item = @something item(doc, parent) break
        parent_item.kind in (HEADER_TABLE, INLINE_TABLE, IMPLICIT_TABLE) || break
        removed = parent
        parent_item.kind === IMPLICIT_TABLE || (target = parent)
    end
    return removed, target
end

function remove!(data::Dict{String,Any}, path::AbstractVector)
    isempty(path) && return false
    container = lookup(data, @view path[1:end-1])
    key = path[end]
    if container isa AbstractDict && key isa AbstractString && haskey(container, key)
        delete!(container, key)
    elseif container isa AbstractVector && key isa Integer &&
            checkbounds(Bool, container, key)
        deleteat!(container, key)
    else
        return false
    end
    return true
end

function set!(data::Dict{String,Any}, path::AbstractVector, @nospecialize(value))
    container = data
    for key in @view path[1:end-1]
        if key isa AbstractString && container isa AbstractDict
            container = get!(Dict{String,Any}, container, key)
        elseif key isa Integer && container isa AbstractVector &&
                checkbounds(Bool, container, key)
            container = container[key]
        else
            return false
        end
    end
    (container isa AbstractDict && path[end] isa AbstractString) || return false
    container[path[end]] = value
    return true
end

function deletion(doc::Document, path::AbstractVector)
    target = @something item(doc, path) return nothing
    bytes = codeunits(doc.source)
    entry = target.entry
    if entry !== nothing
        container = item(doc, containing_table(doc, entry))
        if container !== nothing && container.kind === INLINE_TABLE
            return inline_entry_deletion(bytes, entry)
        end
        start = line_start(bytes, entry.first)
        past_last = next_line_start(bytes, line_end(bytes, entry.past_last))
    elseif target.kind === HEADER_TABLE
        first, past_last = section_range(doc, target)
        last_entry = last_entry_in(doc, first, past_last)
        stop = last_entry === nothing ? first : (last_entry.value::Span).past_last
        start = line_start(bytes, (target.value::Span).first)
        past_last = next_line_start(bytes, line_end(bytes, stop))
    elseif is_array_literal_element(doc, path)
        return array_element_deletion(bytes, target.value::Span)
    else
        return nothing
    end
    return SourceEdit(lines_removal(bytes, start, past_last), "")
end

function is_array_literal_element(doc::Document, path::AbstractVector)
    isempty(path) && return false
    path[end] isa Integer || return false
    parent = @something item(doc, path[1:end-1]) return false
    return parent.kind === ARRAY
end

function array_element_deletion(bytes::SourceBytes, value::Span)
    start = line_start(bytes, value.first)
    if all(in(BLANK_BYTES), @view bytes[start:value.first-1])
        rest = skip_blanks(bytes, value.past_last)
        if rest ≤ length(bytes) && bytes[rest] == UInt8(',')
            rest = skip_blanks(bytes, rest + 1)
        end
        if rest > length(bytes) || bytes[rest] in LINE_BREAK_BYTES ||
                bytes[rest] == UInt8('#')
            past_last = next_line_start(bytes, line_end(bytes, rest))
            return SourceEdit(lines_removal(bytes, start, past_last), "")
        end
    end
    return inline_entry_deletion(bytes, value)
end

function skip_blanks(bytes::SourceBytes, i::Int)
    while i ≤ length(bytes) && bytes[i] in BLANK_BYTES
        i += 1
    end
    return i
end

# Removing the lines from `start` to `past_last` would leave two blank lines in a row, or one
# at the start or end of the source, when blank lines surround them: remove one of those too.
function lines_removal(bytes::SourceBytes, start::Int, past_last::Int)
    blank_before = start > 1 && is_blank_line(bytes, line_start(bytes, start - 1))
    blank_after = past_last ≤ length(bytes) && is_blank_line(bytes, past_last)
    if (start == 1 || blank_before) && blank_after
        past_last = next_line_start(bytes, line_end(bytes, past_last))
    elseif blank_before && past_last > length(bytes)
        start = line_start(bytes, start - 1)
    end
    return Span(start, past_last)
end

is_blank_line(bytes::SourceBytes, i::Int) =
    all(in(BLANK_BYTES), @view bytes[i:line_end(bytes, i)-1])

# The path of the table whose section or inline braces contain `span`
function containing_table(doc::Document, span::Span)
    found, found_first = Path(), 0
    for (path, item) in doc.items
        if item.kind === INLINE_TABLE
            value = item.value::Span
            value.first < span.first && span.past_last < value.past_last || continue
        elseif item.kind === HEADER_TABLE || item.kind === TABLE_ARRAY_ELEMENT
            value = item.value::Span
            value.first < span.first || continue
        else
            continue
        end
        if value.first > found_first
            found, found_first = path, value.first
        end
    end
    return found
end

# An inline table entry goes with the comma after it, or else the one before it.
function inline_entry_deletion(bytes::SourceBytes, entry::Span)
    past_last = entry.past_last
    while past_last ≤ length(bytes) && bytes[past_last] in BLANK_BYTES
        past_last += 1
    end
    if past_last ≤ length(bytes) && bytes[past_last] == UInt8(',')
        past_last += 1
        while past_last ≤ length(bytes) && bytes[past_last] in BLANK_BYTES
            past_last += 1
        end
        return SourceEdit(Span(entry.first, past_last), "")
    end
    first = entry.first
    while first > 1 && bytes[first-1] in BLANK_BYTES
        first -= 1
    end
    if first > 1 && bytes[first-1] == UInt8(',')
        return SourceEdit(Span(first - 1, entry.past_last), "")
    end
    return SourceEdit(Span(entry.first, past_last), "")
end

"""
    move_entry(doc::Document, old_path::AbstractVector, new_path::AbstractVector;
               prune::Bool = false) -> Union{SourceEdit,Nothing}

Return an edit that moves the item at `old_path`, defined by a `key = value` entry, to
`new_path`, keeping the text of its value. If `new_path` lies within the table where the
entry is written, only the key is rewritten, as a dotted key if needed. Otherwise the entry
is added to the deepest existing table along `new_path`, with a dotted key if needed, and
removed from its old place as by [`delete_entry`](@ref) with `prune`.

Return `nothing` if `old_path` is not defined by an entry, if `new_path` already exists, or
if the edited source would not parse to `doc.data` with the item moved.
"""
function move_entry(
        doc::Document, old_path::AbstractVector, new_path::AbstractVector;
        prune::Bool = false
    )
    old = @something item(doc, old_path) return nothing
    entry = @something old.entry return nothing
    (isempty(new_path) || lookup(doc.data, new_path) !== nothing) && return nothing
    expected = deepcopy(doc.data)
    value = lookup(expected, old_path)
    remove!(expected, first(removal_paths(doc, old_path, prune))) || return nothing
    set!(expected, new_path, value) || return nothing
    base = containing_table(doc, entry)
    if length(new_path) > length(base) && view(new_path, 1:length(base)) == base
        keys = view(new_path, length(base)+1:length(new_path))
        if all(key -> key isa AbstractString, keys)
            key_span = Span(entry.first, (old.key::Span).past_last)
            moved = verified(doc, SourceEdit(key_span, format_dotted_key(keys)), expected)
            moved === nothing || return moved
        end
    end
    # Add the new entry first, so that tables shared with the old place are not pruned.
    for depth in length(new_path)-1:-1:0
        table = item(doc, new_path[1:depth])
        table === nothing && continue
        table.kind === INLINE_TABLE || table.kind in SECTION_KINDS || continue
        keys = new_path[depth+1:end]
        all(key -> key isa AbstractString, keys) || return nothing
        value_text = source_text(doc.source, old.value::Span)
        insertion = @something entry_insertion(
            doc, table, format_dotted_key(keys) * " = " * value_text) return nothing
        inserted = tryparse(apply(doc.source, insertion))
        inserted isa Document || return nothing
        removal = @something deletion(
            inserted, last(removal_paths(inserted, old_path, prune))) return nothing
        edited = apply(inserted.source, removal)
        isequal(parse_data(edited), expected) || return nothing
        return minimal_edit(doc.source, edited)
    end
    return nothing
end

source_text(source::String, span::Span) =
    String(codeunits(source)[span.first:span.past_last-1])

"""
    replace_value(doc::Document, path::AbstractVector, value) -> Union{SourceEdit,Nothing}

Return an edit that replaces the value of the item at `path`, defined by a `key = value`
entry, with `value`, keeping the text around it.

Return `nothing` if `path` is not defined by an entry, or if the edited source would not
parse to `doc.data` with the value replaced. Unsupported Julia values throw.
"""
function replace_value(doc::Document, path::AbstractVector, @nospecialize(value))
    target = @something item(doc, path) return nothing
    target.entry === nothing && return nothing
    text = format_value(value)
    expected = deepcopy(doc.data)
    set!(expected, path, parsed_value(text)) || return nothing
    return verified(doc, SourceEdit(target.value::Span, text), expected)
end
