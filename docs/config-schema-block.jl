# Generates the TOML schema block embedded in `src/configuration.md` via its `@eval`
# code block. Entries and default values are derived from `JETLS.JETLSConfig` /
# `JETLS.DEFAULT_CONFIG`, and the docs build fails when this file drifts from the
# actual configuration structs:
# - the displayed block, as well as its variant with all the commented-out entries
#   enabled, must be valid TOML and parse into a valid `JETLSConfig`
# - the entries must cover exactly the options reachable from `JETLSConfig`

using JETLS
using Markdown
using TOML

struct SchemaRow
    key::String     # dotted option key claimed by this row ("" for table headers)
    code::String    # TOML source text, without the trailing comment
    comment::String
    commented::Bool # displayed commented out (entry without a default value)
    validate::Bool  # included in the validation rendering
end

function toml_repr(@nospecialize x)
    if x isa Union{Bool, Int, Float64}
        return string(x)
    elseif x isa String
        return repr(x)
    elseif x isa Vector
        isempty(x) || error("cannot render a non-empty array default: ", repr(x))
        return "[]"
    else
        error("cannot render a default value of type ", typeof(x), ": ", repr(x))
    end
end

function default_entry(path::Symbol...; comment::String, note::String = "", validate::Bool = true)
    value = JETLS.getobjpath(JETLS.DEFAULT_CONFIG, path...)
    code = string(last(path), " = ", toml_repr(value))
    comment = string(comment, ", default: ", toml_repr(value), note)
    return SchemaRow(join(path, '.'), code, comment, false, validate)
end

function example_entry(key::String, value::String; comment::String)
    code = string(last(split(key, '.')), " = ", value)
    return SchemaRow(key, code, comment, true, true)
end

table_header(name::String; comment::String = "", commented::Bool = false) =
    SchemaRow("", "[$name]", comment, commented, true)

array_header(name::String; comment::String = "") =
    SchemaRow("", "[[$name]]", comment, true, true)

# Schema directive honored by TOML language servers (e.g. tombi). Unlike the one in
# this repository's own `.JETLSConfig.toml`, which points at `schemas/` relatively,
# the documented block is meant to be copied into other projects, so it refers to
# the released schema file
const CONFIG_TOML_SCHEMA_URL =
    "https://github.com/aviatesk/JETLS.jl/releases/latest/download/config-toml.schema.json"

schema_directive() =
    SchemaRow("", "#:schema $CONFIG_TOML_SCHEMA_URL", "", false, true)

display_code(row::SchemaRow) = row.commented ? string("# ", row.code) : row.code

# Renders `rows` (`SchemaRow`s and `nothing`s for blank lines) with all the trailing
# comments aligned to the same column
function render_display(rows::Vector{Union{Nothing, SchemaRow}})
    width = maximum(
        textwidth ∘ display_code,
        (row for row in rows if row isa SchemaRow && !isempty(row.comment))
    )
    lines = String[]
    for row in rows
        if row === nothing
            push!(lines, "")
        else
            code = display_code(row)
            push!(
                lines, isempty(row.comment) ? code :
                    string(rpad(code, width + 1), "# ", row.comment)
            )
        end
    end
    return join(lines, '\n')
end

const SKIP_OPTIONS = ("initialization_options",) # documented in launching.md, not here

strip_sentinels(@nospecialize T) = Base.typesplit(Base.typesplit(T, Nothing), Missing)

function option_keys!(acc::Set{String}, ::Type{T}, prefix::String) where {T}
    for i in 1:fieldcount(T)
        name = String(fieldname(T, i)::Symbol)
        startswith(name, "__") && continue # internal fields
        key = isempty(prefix) ? name : string(prefix, '.', name)
        key in SKIP_OPTIONS && continue
        S = strip_sentinels(fieldtype(T, i))
        if S == JETLS.FormatterConfig
            push!(acc, key) # the string preset form
            option_keys!(
                acc, JETLS.CustomFormatterConfig,
                string(key, '.', JETLS.CUSTOM_FORMATTER_ALIAS)
            )
        elseif S <: JETLS.ConfigSection
            option_keys!(acc, S, key)
        elseif S <: Vector && eltype(S) <: JETLS.ConfigSection
            push!(acc, key) # the array itself (e.g. `patterns = []`)
            option_keys!(acc, eltype(S), key)
        else
            push!(acc, key)
        end
    end
    return
end

function toml_keys!(acc::Set{String}, dict::AbstractDict{String}, prefix::String)
    for (key, value) in dict
        path = isempty(prefix) ? key : string(prefix, '.', key)
        if value isa AbstractDict{String}
            toml_keys!(acc, value, path)
        elseif value isa AbstractVector && all(Base.Fix2(isa, AbstractDict{String}), value)
            foreach(elem::AbstractDict{String} -> toml_keys!(acc, elem, path), value)
        else
            push!(acc, path)
        end
    end
end

function assert_valid_config(toml_text::String)
    config_dict = JETLS.validate_config_data(TOML.parse(toml_text))
    result = JETLS.parse_config_dict(config_dict)
    result isa JETLS.JETLSConfig ||
        error("the schema block is not a valid configuration: ", result)
    return result
end

let rows = Union{Nothing, SchemaRow}[
        schema_directive(),
        nothing,
        default_entry(:formatter; comment = "\"Runic\"/\"JuliaFormatter\"", validate = false),
        nothing,
        table_header("formatter.custom"; commented = true, comment = "table, alternative to the string preset form above"),
        example_entry("formatter.custom.executable", "\"/path/to/formatter\""; comment = "string, required"),
        example_entry("formatter.custom.executable_range", "\"/path/to/range-formatter\""; comment = "string, optional"),
        nothing,
        table_header("full_analysis"),
        default_entry(:full_analysis, :debounce; comment = "number (seconds)"),
        default_entry(:full_analysis, :auto_instantiate; comment = "boolean"),
        default_entry(:full_analysis, :concretization_patterns; comment = "array of tables", validate = false),
        nothing,
        array_header("full_analysis.concretization_patterns"; comment = "table, an entry of the concretization patterns array above"),
        example_entry("full_analysis.concretization_patterns.pattern", "\"RandomType = x_\""; comment = "Julia expression pattern, required"),
        example_entry("full_analysis.concretization_patterns.path", "\"scripts/random-type.jl\""; comment = "string (glob), optional"),
        nothing,
        table_header("diagnostic"),
        default_entry(:diagnostic, :enabled; comment = "boolean"),
        default_entry(:diagnostic, :all_files; comment = "boolean"),
        default_entry(:diagnostic, :allow_unused_underscore; comment = "boolean"),
        default_entry(:diagnostic, :patterns; comment = "array of tables", validate = false),
        nothing,
        array_header("diagnostic.patterns"; comment = "table, an entry of the patterns array above"),
        example_entry("diagnostic.patterns.pattern", "\"lowering/unused-.*\""; comment = "string, required"),
        example_entry("diagnostic.patterns.match_by", "\"code\""; comment = "\"code\"/\"message\", required"),
        example_entry("diagnostic.patterns.match_type", "\"regex\""; comment = "\"literal\"/\"regex\", required"),
        example_entry("diagnostic.patterns.severity", "\"hint\""; comment = "\"error\"/\"warning\"/\"info\"/\"hint\"/\"off\" or 0-4, required"),
        example_entry("diagnostic.patterns.path", "\"test/**/*.jl\""; comment = "string (glob), optional"),
        nothing,
        table_header("completion.latex_emoji"),
        example_entry("completion.latex_emoji.strip_prefix", "true"; comment = "boolean, default: unset (auto-detect based on client)"),
        nothing,
        table_header("code_lens"),
        default_entry(:code_lens, :references; comment = "boolean"),
        default_entry(:code_lens, :testrunner; comment = "boolean"),
        nothing,
        table_header("inlay_hint.block_end"),
        default_entry(:inlay_hint, :block_end, :enabled; comment = "boolean"),
        default_entry(:inlay_hint, :block_end, :min_lines; comment = "integer"),
        nothing,
        table_header("inlay_hint.types"),
        default_entry(:inlay_hint, :types, :enabled; comment = "boolean"),
        nothing,
        table_header("testrunner"),
        default_entry(:testrunner, :executable; comment = "string", note = " (\"testrunner.bat\" on Windows)"),
    ]

    display_text = render_display(rows)
    assert_valid_config(display_text)

    schema_rows = SchemaRow[row for row in rows if row isa SchemaRow]
    # The validation rendering enables all the commented-out entries and drops rows
    # incompatible with them (the string preset form of `formatter` conflicts with
    # the `[formatter.custom]` table, and array defaults conflict with their
    # corresponding array-of-tables entries)
    validation_text = join((row.code for row in schema_rows if row.validate), '\n')
    validation_dict = TOML.parse(validation_text)
    assert_valid_config(validation_text)

    covered = Set{String}()
    toml_keys!(covered, validation_dict, "")
    for row in schema_rows
        if !row.validate && !isempty(row.key)
            push!(covered, row.key)
        end
    end

    expected = Set{String}()
    option_keys!(expected, JETLS.JETLSConfig, "")

    if covered != expected
        error(
            """
            the schema block is out of sync with `JETLSConfig`:
              missing options: $(join(sort!(collect(setdiff(expected, covered))), ", "))
              unknown options: $(join(sort!(collect(setdiff(covered, expected))), ", "))
            """
        )
    end

    Markdown.parse("""
    ```toml
    $display_text
    ```
    """)
end
