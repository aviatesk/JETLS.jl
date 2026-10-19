# Defines the `@diagnostics` code block, which renders its code with the diagnostics that
# JETLS reports for it, as editors display them. The code is analyzed as an unsaved buffer,
# as `jetls check -` does. The block takes keyword arguments in its header, e.g.
# `@diagnostics; file = "scripts/foo.jl", codes = ["lowering/unused-local"]`:
# - `workspace`: analyzes the code in the workspace of this name, which is shared by the
#   blocks with the same `workspace` in a page; the code is also written to `file` there
# - `file`: analyzes the code as the file at this path relative to the root path, as
#   `jetls check --stdin-filename` does. The code of `.JETLSConfig.toml` is instead
#   diagnosed as the configuration file open in an editor, since `jetls check` does not
#   report the diagnostics of the configuration file.
# - `codes`: a vector of diagnostic codes; shows only the diagnostics with these codes, and
#   fails the docs build when any of them is not reported
# - `absent_codes`: a vector of diagnostic codes; fails the docs build when any of them is
#   reported, e.g. for examples of code that is not reported
# Either `codes` or `absent_codes` is required, so that every block tests the diagnostics.
# The codes must have their sections in the diagnostic reference, which the diagnostics
# link to.
#
# The `@diagnostics-file` and `@diagnostics-setup` code blocks write their code to `file` in
# `workspace`, e.g. `.JETLSConfig.toml` or the files of a package, for the later
# `@diagnostics` blocks of the workspace. `@diagnostics-file` displays the code as a code
# block, while `@diagnostics-setup` is not displayed.
#
# The empty `@diagnostics-run` code block runs `file` in `workspace` with `julia` and
# displays its output up to the first stack trace, e.g. to compare the diagnostics with the
# errors and warnings that Julia reports at runtime.

using Documenter: Documenter
using JETLSCore: CodeAction, Command, Diagnostic, DiagnosticSeverity, DiagnosticTag,
    JETLSCore, PositionEncodingKind, URI
using JuliaSyntaxHighlighting: highlight
using Markdown: Markdown

abstract type DiagnosticsBlocks <: Documenter.Expanders.NestedExpanderPipeline end

Documenter.Selectors.order(::Type{DiagnosticsBlocks}) = 12.0
Documenter.Selectors.matcher(::Type{DiagnosticsBlocks}, node, _page, _doc) =
    Documenter.iscode(node, r"^@diagnostics(\s|;|$)")
function Documenter.Selectors.runner(::Type{DiagnosticsBlocks}, node, page, doc)
    code = node.element.code
    source, kwargs = @something parse_block_kwargs("@diagnostics", node, page, doc,
        (:workspace, :file, :codes, :absent_codes)) return nothing
    haskey(kwargs, :codes) || haskey(kwargs, :absent_codes) ||
        error("In ", source, ": the `@diagnostics` block requires `codes` or `absent_codes`")
    workspace = string_kwarg(kwargs, :workspace, source)
    file = string_kwarg(kwargs, :file, source)
    root = workspace === nothing ? DIAGNOSTICS_BLOCK_ROOT : workspace_root(page, workspace)
    uri = if file === nothing
        JETLSCore.STDIN_URI
    elseif workspace === nothing
        JETLSCore.filepath2uri(joinpath(root, file))
    else
        JETLSCore.filepath2uri(write_workspace_file(root, file, code, source))
    end
    codes = diagnostic_codes(kwargs, :codes, source)
    absent_codes = diagnostic_codes(kwargs, :absent_codes, source)
    if file == JETLSCore.CONFIG_FILE
        diagnostics, code_actions = analyze_config_diagnostics_block(
            code, root, uri, codes, absent_codes, source)
        classes = toml_hljs_classes(code)
    else
        diagnostics, code_actions = analyze_diagnostics_block(
            code, root, uri, codes, absent_codes, source)
        classes = hljs_classes(code)
    end
    html = render_diagnostics_block(
        code, classes, root, uri, diagnostics, code_actions, diagnostic_page_href(page, doc))
    node.element = Documenter.RawNode(:html, html)
    return nothing
end

abstract type DiagnosticsFileBlocks <: Documenter.Expanders.NestedExpanderPipeline end

Documenter.Selectors.order(::Type{DiagnosticsFileBlocks}) = 12.1
Documenter.Selectors.matcher(::Type{DiagnosticsFileBlocks}, node, _page, _doc) =
    Documenter.iscode(node, r"^@diagnostics-(file|setup)(\s|;|$)")
function Documenter.Selectors.runner(::Type{DiagnosticsFileBlocks}, node, page, doc)
    code = node.element.code
    lang = startswith(node.element.info, "@diagnostics-file") ? "@diagnostics-file" : "@diagnostics-setup"
    source, kwargs = @something parse_block_kwargs(lang, node, page, doc, (:workspace, :file)) return nothing
    workspace = required_string_kwarg(kwargs, :workspace, lang, source)
    file = required_string_kwarg(kwargs, :file, lang, source)
    write_workspace_file(workspace_root(page, workspace), file, code, source)
    node.element = if lang == "@diagnostics-file"
        Documenter.MarkdownAST.CodeBlock(file_language(file), code)
    else
        Documenter.RawNode(:html, "")
    end
    return nothing
end

abstract type DiagnosticsRunBlocks <: Documenter.Expanders.NestedExpanderPipeline end

Documenter.Selectors.order(::Type{DiagnosticsRunBlocks}) = 12.2
Documenter.Selectors.matcher(::Type{DiagnosticsRunBlocks}, node, _page, _doc) =
    Documenter.iscode(node, r"^@diagnostics-run(\s|;|$)")
function Documenter.Selectors.runner(::Type{DiagnosticsRunBlocks}, node, page, doc)
    lang = "@diagnostics-run"
    source, kwargs = @something parse_block_kwargs(lang, node, page, doc, (:workspace, :file)) return nothing
    isempty(strip(node.element.code)) || error("In ", source, ": the `", lang, "` block must be empty")
    workspace = required_string_kwarg(kwargs, :workspace, lang, source)
    file = required_string_kwarg(kwargs, :file, lang, source)
    root = workspace_root(page, workspace)
    isfile(joinpath(root, file)) ||
        error("In ", source, ": `", file, "` is not written in the workspace `", workspace, "`")
    output = IOBuffer()
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --color=yes $file`; dir = root)
    run(pipeline(ignorestatus(cmd); stdout = output, stderr = output))
    # rendered with the ANSI colors, as Documenter renders the outputs of `@repl` blocks
    node.element = Documenter.MarkdownAST.CodeBlock("documenter-ansi",
        elide_stacktrace(relative_paths(String(take!(output)), root)))
    return nothing
end

function elide_stacktrace(output::String)
    lines = split(output, '\n')
    i = @something findfirst(
        line -> startswith(replace(line, r"\e\[[0-9;]*m" => ""), "Stacktrace:"),
        lines) return output
    return join(push!(lines[1:i], "..."), '\n')
end

# Unlike `Documenter.parse_codeblock_args`, which only warns about unsupported keyword
# arguments, reject them, since a misspelled `absent_codes` would silently skip its test
function parse_block_kwargs(
        lang::String, node, page::Documenter.Page, doc::Documenter.Document,
        allowed_keys::Tuple{Vararg{Symbol}}
    )
    block = node.element
    source = Documenter.locrepr(doc, page, Documenter.find_block_in_file(block.code, page.source))
    success, name, kwargs_str = Documenter.parse_codelang(lang, block, doc, source)
    success || return nothing
    name === nothing || error("In ", source, ": the `", lang, "` block does not take a name: ", name)
    kwargs = @something Documenter.parse_kwargs(lang, kwargs_str, block, doc, source) return nothing
    for key in keys(kwargs)
        key in allowed_keys ||
            error("In ", source, ": unsupported keyword argument of the `", lang, "` block: ", key)
    end
    return source, kwargs
end

function string_kwarg(kwargs::Dict{Symbol,Any}, key::Symbol, source::String)
    haskey(kwargs, key) || return nothing
    value = kwargs[key]
    value isa String || error("In ", source, ": `", key, "` must be a string: ", value)
    return value
end

required_string_kwarg(kwargs::Dict{Symbol,Any}, key::Symbol, lang::String, source::String) =
    @something(string_kwarg(kwargs, key, source),
        error("In ", source, ": the `", lang, "` block requires `", key, "`"))

function diagnostic_codes(kwargs::Dict{Symbol,Any}, key::Symbol, source::String)
    haskey(kwargs, key) || return String[]
    codes = kwargs[key]
    Meta.isexpr(codes, :vect) && !isempty(codes.args) && all(code -> code isa String, codes.args) ||
        error("In ", source, ": `", key, "` must be a non-empty vector of strings: ", codes)
    result = String[codes.args...]
    for code in result
        code in JETLSCore.ALL_DIAGNOSTIC_CODES ||
            error("In ", source, ": unknown diagnostic code in `", key, "`: ", code)
        "diagnostic/reference/" * code in DIAGNOSTIC_PAGE_IDS ||
            error("In ", source, ": `", code, "` in `", key, "` has no section in ", DIAGNOSTIC_PAGE)
    end
    return result
end

# An empty root path, so that no `.JETLSConfig.toml` affects the reported diagnostics
const DIAGNOSTICS_BLOCK_ROOT = mktempdir()

const DIAGNOSTICS_WORKSPACES = Dict{Tuple{String,String},String}()

workspace_root(page::Documenter.Page, workspace::String) =
    get!(mktempdir, DIAGNOSTICS_WORKSPACES, (page.source, workspace))

function write_workspace_file(root::String, file::String, code::String, source::String)
    isabspath(file) && error("In ", source, ": `file` must be a relative path: ", file)
    path = joinpath(root, file)
    mkpath(dirname(path))
    write(path, endswith(code, '\n') ? code : code * '\n')
    return path
end

function file_language(file::String)
    ext = splitext(file)[2]
    return ext == ".jl" ? "julia" : ext == ".toml" ? "toml" : ""
end

# The capabilities of a client that renders the messages as Markdown, as the hovers do, so
# that e.g. stack traces are formatted as code blocks, and that can create files, to which
# the quick fix that creates `.JETLSConfig.toml` is offered
const DIAGNOSTICS_BLOCK_CAPABILITIES = JETLSCore.ClientCapabilities(;
    textDocument = JETLSCore.TextDocumentClientCapabilities(;
        diagnostic = JETLSCore.DiagnosticClientCapabilities(; markupMessageSupport = true)),
    workspace = JETLSCore.WorkspaceClientCapabilities(;
        workspaceEdit = JETLSCore.WorkspaceEditClientCapabilities(;
            documentChanges = true,
            resourceOperations = JETLSCore.ResourceOperationKind.Ty[
                JETLSCore.ResourceOperationKind.Create])))

function analyze_diagnostics_block(
        code::String, root::String, uri::URI, codes::Vector{String}, absent_codes::Vector{String},
        source::String
    )
    input = JETLSCore.InputSource(uri, code)
    progress_ctx = JETLSCore.ProgressContext(JETLSCore.PROGRESS_NONE, devnull)
    logger = Base.CoreLogging.SimpleLogger(stderr, Base.CoreLogging.Warn)
    return Base.CoreLogging.with_logger(logger) do
        server = JETLSCore.start_cli_server(root)
        server.state.init_params = JETLSCore.InitializeParams(;
            processId = getpid(), rootUri = JETLSCore.filepath2uri(root),
            capabilities = DIAGNOSTICS_BLOCK_CAPABILITIES)
        try
            result = @something JETLSCore.collect_check_diagnostics!(
                server, root, JETLSCore.InputSource[], input, progress_ctx;
                skip_analysis = false) error("In ", source, ": failed to analyze the `@diagnostics` block")
            diagnostics = select_diagnostics!(
                get(result[1], uri, Diagnostic[]), root, codes, absent_codes, source)
            code_actions = map(diagnostics) do diagnostic
                return JETLSCore.quickfix_code_actions!(
                    Union{CodeAction,Command}[], server, uri, Diagnostic[diagnostic])
            end
            return diagnostics, code_actions
        finally
            JETLSCore.cleanup_cli_tasks(server)
        end
    end
end

function analyze_config_diagnostics_block(
        code::String, root::String, uri::URI, codes::Vector{String}, absent_codes::Vector{String},
        source::String
    )
    JETLSCore.TS.tryparse(code) isa JETLSCore.TS.Document ||
        error("In ", source, ": the `@diagnostics` block is not valid TOML")
    server = JETLSCore.Server()
    try
        server.state.init_params = JETLSCore.InitializeParams(;
            processId = getpid(), rootUri = JETLSCore.filepath2uri(root),
            capabilities = DIAGNOSTICS_BLOCK_CAPABILITIES)
        JETLSCore.cache_config_document!(server.state, uri, 1, code)
        diagnostics = select_diagnostics!(
            JETLSCore.deprecated_config_diagnostics(code, server.state.encoding),
            root, codes, absent_codes, source)
        code_actions = map(diagnostics) do diagnostic
            return JETLSCore.deprecated_config_code_actions!(
                Union{CodeAction,Command}[], server, uri, Diagnostic[diagnostic])
        end
        return diagnostics, code_actions
    finally
        close(server.endpoint)
    end
end

function select_diagnostics!(
        diagnostics::Vector{Diagnostic}, root::String, codes::Vector{String},
        absent_codes::Vector{String}, source::String
    )
    for code in codes
        any(diagnostic -> diagnostic.code == code, diagnostics) ||
            error("In ", source, ": `", code, "` is not reported for the `@diagnostics` block; ",
                "reported codes: ", join(unique(diagnostic_code.(diagnostics)), ", "))
    end
    for diagnostic in diagnostics
        diagnostic.code in absent_codes &&
            error("In ", source, ": `", diagnostic_code(diagnostic), "` is reported for the ",
                "`@diagnostics` block, which is expected to be absent: ",
                diagnostic_message(diagnostic, root))
    end
    filter!(diagnostic -> diagnostic.code in codes, diagnostics)
    return sort!(diagnostics; by = function (diagnostic)
        return (diagnostic.severity, diagnostic.range.start.line, diagnostic.range.start.character)
    end)
end

const DIAGNOSTIC_PAGE = "diagnostic.md"

const DIAGNOSTIC_PAGE_IDS = let
    content = read(joinpath(@__DIR__, "src", DIAGNOSTIC_PAGE), String)
    Set{String}(m[1]::AbstractString for m in eachmatch(r"\(@id ([^)]+)\)", content))
end

const DIAGNOSTIC_SOURCE_ID = let source_id = "diagnostic/source"
    source_id in DIAGNOSTIC_PAGE_IDS ||
        error(DIAGNOSTIC_PAGE, " has no section of `", source_id, "`")
    source_id
end

# The relative URL of the diagnostic reference page from `page`, computed as the HTML
# writer of Documenter computes the URLs of cross-references
function diagnostic_page_href(page::Documenter.Page, doc::Documenter.Document)
    src = relpath(page.source, doc.user.source)
    src == DIAGNOSTIC_PAGE && return ""
    ctx = (; settings = only(format for format in doc.user.format if format isa Documenter.HTML))
    from = Documenter.HTMLWriter.get_url(ctx, src)
    to = Documenter.HTMLWriter.get_url(ctx, DIAGNOSTIC_PAGE)
    return Documenter.HTMLWriter.pretty_url(ctx, Documenter.HTMLWriter.relhref(from, to))
end

# Maps the faces of JuliaSyntaxHighlighting.jl to the highlight.js classes that the
# Documenter themes style, roughly as highlight.js highlights Julia code
const HLJS_CLASSES = Dict{Symbol,String}(
    :julia_keyword => "hljs-keyword",
    :julia_comment => "hljs-comment",
    :julia_string => "hljs-string",
    :julia_string_delim => "hljs-string",
    :julia_backslash_literal => "hljs-string",
    :julia_char => "hljs-string",
    :julia_char_delim => "hljs-string",
    :julia_cmd => "hljs-string",
    :julia_cmd_delim => "hljs-string",
    :julia_regex => "hljs-string",
    :julia_number => "hljs-number",
    :julia_bool => "hljs-literal",
    :julia_singleton_identifier => "hljs-literal",
    :julia_symbol => "hljs-symbol",
    :julia_macro => "hljs-meta",
    :julia_type => "hljs-built_in",
    :julia_builtin => "hljs-built_in",
)

function hljs_classes(code::String)
    classes = Vector{Union{Nothing,String}}(nothing, ncodeunits(code))
    # Apply the narrower regions later so that nested faces take precedence, e.g. the
    # braces of `Vector{T}` over its `:julia_type`
    annots = sort!(collect(Base.annotations(highlight(code))); by = function (annot)
        return (-length(annot.region), haskey(HLJS_CLASSES, annot.value))
    end)
    for annot in annots
        # Only the syntax faces count, e.g. not `:code` for backquoted text in comments,
        # which would otherwise clear the comment class
        annot.label === :face && startswith(string(annot.value), "julia_") || continue
        classes[annot.region] .= get(HLJS_CLASSES, annot.value, nothing)
    end
    return classes
end

# Highlights TOML code roughly as highlight.js does, from the source locations of its items
function toml_hljs_classes(code::String)
    classes = Vector{Union{Nothing,String}}(nothing, ncodeunits(code))
    bytes = codeunits(code)
    for item in values(JETLSCore.TS.parse(code).items)
        (; key, value, entry) = item
        if item.kind in (JETLSCore.TS.HEADER_TABLE, JETLSCore.TS.TABLE_ARRAY_ELEMENT)
            value === nothing || (classes[value.first:value.past_last-1] .= "hljs-section")
            continue
        end
        if key !== nothing && entry !== nothing
            # from the first segment of a dotted key
            classes[entry.first:key.past_last-1] .= "hljs-attr"
        end
        if item.kind === JETLSCore.TS.SCALAR && value !== nothing
            classes[value.first:value.past_last-1] .=
                bytes[value.first] in (UInt8('"'), UInt8('\'')) ? "hljs-string" :
                bytes[value.first] in (UInt8('t'), UInt8('f')) ? "hljs-literal" : "hljs-number"
        end
    end
    # Every `#` outside the items, which cover the strings, starts a comment
    for i in findall(==(UInt8('#')), bytes)
        classes[i] === nothing || continue
        j = something(findnext(==(UInt8('\n')), bytes, i), length(bytes) + 1)
        classes[i:j-1] .= "hljs-comment"
    end
    return classes
end

function lsp_byte_range(
        code::String, textbuf::Vector{UInt8}, line_starts::Vector{Int}, range::JETLSCore.Range
    )
    (; start, var"end") = range
    startbyte = JETLSCore._xy_to_offset(textbuf, start, PositionEncodingKind.UTF16, line_starts)
    endbyte = JETLSCore._xy_to_offset(textbuf, var"end", PositionEncodingKind.UTF16, line_starts)
    endbyte > startbyte && return startbyte:endbyte-1
    if startbyte > ncodeunits(code) || code[startbyte] == '\n'
        startbyte == 1 && return 1:0
        startbyte = prevind(code, startbyte)
    end
    return startbyte:startbyte
end

severity_name(severity::DiagnosticSeverity.Ty) =
    severity == DiagnosticSeverity.Error ? "error" :
    severity == DiagnosticSeverity.Warning ? "warning" :
    severity == DiagnosticSeverity.Information ? "information" : "hint"

has_tag(diagnostic::Diagnostic, tag::DiagnosticTag.Ty) =
    diagnostic.tags !== nothing && tag in diagnostic.tags

diagnostic_code(diagnostic::Diagnostic) =
    diagnostic.code === nothing ? "" : string(diagnostic.code)

escape_html(s::AbstractString) = replace(s,
    '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&#39;")

markdown_html(s::AbstractString) = Markdown.html(Markdown.parse(s))

# Shows the paths in the root path relative to it, also when they are given by the real
# path, e.g. `/private/var/...` for `/var/...` on macOS, which contains the root path and
# so is replaced first
function relative_paths(s::String, root::String)
    for dir in unique!([realpath(root), root])
        s = replace(s, dir * '/' => "")
    end
    return s
end

diagnostic_message(diagnostic::Diagnostic, root::String) =
    relative_paths(JETLSCore.get_raw_message(diagnostic)::String, root)

diagnostic_summary(diagnostic::Diagnostic, root::String) =
    first(eachsplit(diagnostic_message(diagnostic, root), '\n'))

function print_code_link(io::IO, diagnostic::Diagnostic, page_href::String)
    code = diagnostic_code(diagnostic)
    isempty(code) && return
    print(io, "<a class=\"jetls-diagnostic-code\" href=\"", escape_html(page_href),
        "#diagnostic/reference/", escape_html(code), "\">", escape_html(code), "</a>")
end

function related_location(location::JETLSCore.Location, root::String, uri::URI)
    line = Int(location.range.start.line) + 1
    location.uri == uri && return "Line $line"
    filepath = @something JETLSCore.uri2filepath(location.uri) return string(location.uri, ':', line)
    path = relative_paths(filepath, root)
    return string(isabspath(path) ? basename(path) : path, ':', line)
end

# Related information messages are plain text, but the hover renders them as Markdown, so
# shows the signatures of stack frames as code, including those labeled as `entry: h()` in
# inference diagnostics
function related_message(message::String)
    m = match(r"^((?:origin|via|entry): )?(.*)$"s, message)::RegexMatch
    label, sig = something(m[1], ""), m[2]::AbstractString
    occursin('\n', sig) && return message
    Meta.isexpr(Meta.parse(sig; raise = false), (:call, :where)) || return message
    return string(label, '`', sig, '`')
end

# The content of the hover shown by `assets/diagnostics.js`
function print_hover_template(
        io::IO, id::Int, diagnostic::Diagnostic,
        code_actions::Vector{Union{CodeAction,Command}}, root::String, uri::URI,
        page_href::String
    )
    print(io, "<template data-diagnostic=\"", id, "\"><div class=\"jetls-diagnostic-hover-item ",
        "jetls-diagnostic-hover-", severity_name(diagnostic.severity::DiagnosticSeverity.Ty), "\">")
    print(io, "<div class=\"jetls-diagnostic-hover-message\">",
        markdown_html(diagnostic_message(diagnostic, root)), "</div>")
    print_hover_source(io, diagnostic, page_href)
    related_information = diagnostic.relatedInformation
    if related_information !== nothing && !isempty(related_information)
        print_hover_list(io, "jetls-diagnostic-hover-related", "Related information", String[
            string(related_location(info.location, root, uri), ": ", related_message(info.message))
            for info in related_information])
    end
    if !isempty(code_actions)
        print_hover_list(io, "jetls-diagnostic-hover-actions", "Quick fixes",
            String[code_action.title for code_action in code_actions])
    end
    print(io, "</div></template>")
end

# The content of the hover of related information, which shows its message as Zed does,
# along with the diagnostic that refers to it
function print_related_hover_template(
        io::IO, id::Int, info::JETLSCore.DiagnosticRelatedInformation, diagnostic::Diagnostic,
        root::String, page_href::String
    )
    print(io, "<template data-related=\"", id, "\"><div class=\"jetls-diagnostic-hover-item ",
        "jetls-diagnostic-hover-item-related\">")
    print(io, "<div class=\"jetls-diagnostic-hover-message\">",
        markdown_html(related_message(info.message)), "</div>")
    print_hover_source(io, diagnostic, page_href)
    print_hover_list(io, "jetls-diagnostic-hover-related", "Related to", String[
        string("Line ", diagnostic.range.start.line + 1, ": ", diagnostic_summary(diagnostic, root))])
    print(io, "</div></template>")
end

function print_hover_source(io::IO, diagnostic::Diagnostic, page_href::String)
    print(io, "<div class=\"jetls-diagnostic-hover-source\"><a href=\"", escape_html(page_href), '#',
        DIAGNOSTIC_SOURCE_ID, "\">", escape_html(string(diagnostic.source)), "</a> (")
    print_code_link(io, diagnostic, page_href)
    print(io, ")</div>")
end

function print_hover_list(io::IO, class::String, title::String, items::Vector{String})
    print(io, "<div class=\"", class, "\">", title, "<ul>")
    for item in items
        print(io, "<li>", markdown_html(item), "</li>")
    end
    print(io, "</ul></div>")
end

function print_highlighted(
        io::IO, code::String, bytes::UnitRange{Int}, classes::Vector{Union{Nothing,String}}
    )
    i = first(bytes)
    while i ≤ last(bytes)
        class = classes[i]
        j = nextind(code, i)
        while j ≤ last(bytes) && classes[j] == class
            j = nextind(code, j)
        end
        text = escape_html(code[i:prevind(code, j)])
        if class === nothing
            print(io, text)
        else
            print(io, "<span class=\"", class, "\">", text, "</span>")
        end
        i = j
    end
end

function print_diagnostic_run(
        io::IO, code::String, bytes::UnitRange{Int}, classes::Vector{Union{Nothing,String}},
        diagnostics::Vector{Diagnostic}, ids::Vector{Int}
    )
    diagnostics = diagnostics[ids]
    severity = minimum(diagnostic -> diagnostic.severity, diagnostics)::DiagnosticSeverity.Ty
    spanclasses = ["jetls-diagnostic", "jetls-diagnostic-" * severity_name(severity)]
    if any(diagnostic -> has_tag(diagnostic, DiagnosticTag.Unnecessary), diagnostics)
        push!(spanclasses, "jetls-diagnostic-unnecessary")
    end
    if any(diagnostic -> has_tag(diagnostic, DiagnosticTag.Deprecated), diagnostics)
        push!(spanclasses, "jetls-diagnostic-deprecated")
    end
    print(io, "<span class=\"", join(spanclasses, ' '), "\" data-diagnostics=\"", join(ids, ' '), "\">")
    print_highlighted(io, code, bytes, classes)
    print(io, "</span>")
end

# The last line with non-whitespace code in `byte_range`, e.g. not the line of `else` for
# an inactive `@static if` branch whose range ends at the indentation before `else`
function message_line(
        code::String, line_starts::Vector{Int}, byte_range::UnitRange{Int}, nlines::Int
    )
    lastbyte = findprev(!isspace, code, thisind(code, max(first(byte_range), last(byte_range))))
    if lastbyte === nothing || lastbyte < first(byte_range)
        lastbyte = first(byte_range)
    end
    return min(searchsortedlast(line_starts, lastbyte), nlines)
end

# Leaves the indentation un-underlined, as the line-wide ranges of inference diagnostics
# would otherwise underline it
covering_diagnostics(byte_ranges::Vector{UnitRange{Int}}, i::Int, indentend::Int) =
    i < indentend ? Int[] : Int[k for (k, range) in enumerate(byte_ranges) if i in range]

# The related information in the same code is underlined as Zed does
covering_related(related_ranges::Vector{UnitRange{Int}}, i::Int, indentend::Int) =
    i < indentend ? Int[] : Int[k for (k, range) in enumerate(related_ranges) if i in range]

function print_related_run(
        io::IO, code::String, bytes::UnitRange{Int}, classes::Vector{Union{Nothing,String}},
        ids::Vector{Int}
    )
    print(io, "<span class=\"jetls-diagnostic-related\" data-related=\"", join(ids, ' '), "\">")
    print_highlighted(io, code, bytes, classes)
    print(io, "</span>")
end

# Shows the first line of the message below the last line of the diagnostic, aligned with
# the start of its range on that line. The line is text, so that selecting the code also
# copies the messages, and `assets/diagnostics.js` hides it while the copy button copies
# the code.
function print_diagnostic_message(
        io::IO, diagnostic::Diagnostic, id::Int, column::Int, root::String, page_href::String
    )
    message = diagnostic_summary(diagnostic, root)
    print(io, "<span class=\"jetls-diagnostic-message-line\">\n", ' '^column,
        "<span class=\"jetls-diagnostic-message jetls-diagnostic-message-",
        severity_name(diagnostic.severity::DiagnosticSeverity.Ty), "\" data-diagnostics=\"", id, "\">",
        "└─ ", escape_html(message), ' ')
    print_code_link(io, diagnostic, page_href)
    print(io, "</span></span>")
end

function render_diagnostics_block(
        code::String, classes::Vector{Union{Nothing,String}}, root::String, uri::URI,
        diagnostics::Vector{Diagnostic}, code_actions::Vector{Vector{Union{CodeAction,Command}}},
        page_href::String
    )
    textbuf = Vector{UInt8}(code)
    line_starts = JETLSCore.build_line_starts(textbuf)
    byte_ranges = UnitRange{Int}[
        lsp_byte_range(code, textbuf, line_starts, diagnostic.range) for diagnostic in diagnostics]
    related_infos = Tuple{Int,JETLSCore.DiagnosticRelatedInformation}[]
    related_ranges = UnitRange{Int}[]
    for (id, diagnostic) in enumerate(diagnostics)
        related_information = @something diagnostic.relatedInformation continue
        for info in related_information
            info.location.uri == uri && !isempty(info.message) || continue
            push!(related_infos, (id, info))
            push!(related_ranges, lsp_byte_range(code, textbuf, line_starts, info.location.range))
        end
    end

    io = IOBuffer()
    print(io, "<div class=\"jetls-diagnostics\"><pre><code class=\"nohighlight hljs\">")
    nlines = length(line_starts)
    if nlines > 1 && line_starts[end] > ncodeunits(code)
        nlines -= 1 # the phantom line after the trailing newline
    end
    message_lines = Int[
        message_line(code, line_starts, byte_range, nlines) for byte_range in byte_ranges]
    for line in 1:nlines
        linestart = line_starts[line]
        lineend = line < length(line_starts) ? line_starts[line+1] - 1 : ncodeunits(code) + 1
        indentend = something(findnext(c -> !isspace(c), code, linestart), lineend)
        i = linestart
        while i < lineend
            covering = covering_diagnostics(byte_ranges, i, indentend)
            related = covering_related(related_ranges, i, indentend)
            j = nextind(code, i)
            while j < lineend && covering_diagnostics(byte_ranges, j, indentend) == covering &&
                    covering_related(related_ranges, j, indentend) == related
                j = nextind(code, j)
            end
            if !isempty(covering)
                print_diagnostic_run(io, code, i:j-1, classes, diagnostics, covering)
            elseif !isempty(related)
                print_related_run(io, code, i:j-1, classes, related)
            else
                print_highlighted(io, code, i:j-1, classes)
            end
            i = j
        end
        messages = Tuple{Int,Int}[]
        for (id, (byte_range, message_line)) in enumerate(zip(byte_ranges, message_lines))
            message_line == line || continue
            startbyte = min(max(first(byte_range), indentend), lineend)
            push!(messages, (textwidth(SubString(code, linestart, prevind(code, startbyte))), id))
        end
        for (column, id) in sort!(messages; by = first)
            print_diagnostic_message(io, diagnostics[id], id, column, root, page_href)
        end
        line < nlines && print(io, '\n')
    end
    print(io, "</code></pre>")
    for (id, diagnostic) in enumerate(diagnostics)
        print_hover_template(io, id, diagnostic, code_actions[id], root, uri, page_href)
    end
    for (k, (id, info)) in enumerate(related_infos)
        print_related_hover_template(io, k, info, diagnostics[id], root, page_href)
    end
    print(io, "</div>")
    return String(take!(io))
end
