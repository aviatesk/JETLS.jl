# Defines the `@diagnostics` code block, which renders its code with the diagnostics that
# JETLS reports for it, as editors display them. The code is analyzed as an unsaved buffer,
# as `jetls check -` does. The block takes keyword arguments in its header, e.g.
# `@diagnostics; file = "scripts/foo.jl", codes = ["lowering/unused-local"]`:
# - `workspace`: analyzes the code in the workspace of this name, which is shared by the
#   blocks with the same `workspace` in a page; the code is also written to `file` there
# - `file`: analyzes the code as the file at this path relative to the root path, as
#   `jetls check --stdin-filename` does
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
    parsed = parse_block_kwargs("@diagnostics", node, page, doc,
        (:workspace, :file, :codes, :absent_codes))
    parsed === nothing && return nothing
    source, kwargs = parsed
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
    codes = haskey(kwargs, :codes) ? diagnostic_codes(kwargs[:codes], :codes, source) : String[]
    absent_codes = haskey(kwargs, :absent_codes) ?
        diagnostic_codes(kwargs[:absent_codes], :absent_codes, source) : String[]
    diagnostics, code_actions = analyze_diagnostics_block(code, root, uri, codes, absent_codes, source)
    html = render_diagnostics_block(
        code, root, uri, diagnostics, code_actions, diagnostic_page_href(page, doc))
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
    parsed = parse_block_kwargs(lang, node, page, doc, (:workspace, :file))
    parsed === nothing && return nothing
    source, kwargs = parsed
    workspace = string_kwarg(kwargs, :workspace, source)
    file = string_kwarg(kwargs, :file, source)
    workspace === nothing && error("In ", source, ": the `", lang, "` block requires `workspace`")
    file === nothing && error("In ", source, ": the `", lang, "` block requires `file`")
    write_workspace_file(workspace_root(page, workspace), file, code, source)
    node.element = if lang == "@diagnostics-file"
        Documenter.MarkdownAST.CodeBlock(file_language(file), code)
    else
        Documenter.RawNode(:html, "")
    end
    return nothing
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
    kwargs = Documenter.parse_kwargs(lang, kwargs_str, block, doc, source)
    kwargs === nothing && return nothing
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

function diagnostic_codes(@nospecialize(codes), key::Symbol, source::String)
    Meta.isexpr(codes, :vect) && !isempty(codes.args) && all(code -> code isa String, codes.args) ||
        error("In ", source, ": `", key, "` must be a non-empty vector of strings: ", codes)
    result = String[codes.args...]
    for code in result
        code in JETLSCore.ALL_DIAGNOSTIC_CODES ||
            error("In ", source, ": unknown diagnostic code in `", key, "`: ", code)
        code in DIAGNOSTIC_REFERENCE_CODES ||
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

# Some code actions depend on the client capabilities, e.g. the one that creates
# `.JETLSConfig.toml` is offered only to clients that can create files
const DIAGNOSTICS_BLOCK_CAPABILITIES = JETLSCore.ClientCapabilities(;
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
        try
            result = JETLSCore.collect_check_diagnostics!(
                server, root, JETLSCore.InputSource[], input, progress_ctx;
                skip_analysis = false)
            result === nothing && error("In ", source, ": failed to analyze the `@diagnostics` block")
            diagnostics = get(result[1], uri, Diagnostic[])
            for code in codes
                any(diagnostic::Diagnostic -> diagnostic.code == code, diagnostics) ||
                    error("In ", source, ": `", code, "` is not reported for the `@diagnostics` block; ",
                        "reported codes: ", join(unique(diagnostic_code.(diagnostics)), ", "))
            end
            for diagnostic in diagnostics
                diagnostic.code in absent_codes &&
                    error("In ", source, ": `", diagnostic_code(diagnostic), "` is reported for the ",
                        "`@diagnostics` block, which is expected to be absent: ",
                        diagnostic_message(diagnostic, root))
            end
            filter!(diagnostic::Diagnostic -> diagnostic.code in codes, diagnostics)
            sort!(diagnostics; by = function (diagnostic::Diagnostic)
                return (diagnostic.severity, diagnostic.range.start.line, diagnostic.range.start.character)
            end)
            server.state.init_params = JETLSCore.InitializeParams(;
                processId = getpid(), rootUri = JETLSCore.filepath2uri(root),
                capabilities = DIAGNOSTICS_BLOCK_CAPABILITIES)
            code_actions = map(diagnostics) do diagnostic::Diagnostic
                return JETLSCore.quickfix_code_actions!(
                    Union{CodeAction,Command}[], server, uri, Diagnostic[diagnostic])
            end
            return diagnostics, code_actions
        finally
            JETLSCore.cleanup_cli_tasks(server)
        end
    end
end

const DIAGNOSTIC_PAGE = "diagnostic.md"

const DIAGNOSTIC_REFERENCE_CODES = Set{String}(
    m[1]::SubString{String} for m in eachmatch(r"\(@id diagnostic/reference/([^)]+)\)",
        read(joinpath(@__DIR__, "src", DIAGNOSTIC_PAGE), String)))

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

# Shows the paths in the root path relative to it, also when they are given via symlinks,
# e.g. `/private/var` for `/var` on macOS
function relative_paths(s::String, root::String)
    for dir in unique!([root, realpath(root)])
        s = replace(s, dir * '/' => "")
    end
    return s
end

diagnostic_message(diagnostic::Diagnostic, root::String) =
    relative_paths(JETLSCore.get_raw_message(diagnostic)::String, root)

function print_code_link(io::IO, diagnostic::Diagnostic, page_href::String; css::Bool)
    code = diagnostic_code(diagnostic)
    isempty(code) && return
    print(io, "<a class=\"jetls-diagnostic-code\" href=\"", escape_html(page_href),
        "#diagnostic/reference/", escape_html(code), '"')
    if css
        print(io, " data-code=\"", escape_html(code), "\"></a>")
    else
        print(io, '>', escape_html(code), "</a>")
    end
end

function related_location(location::JETLSCore.Location, root::String, uri::URI)
    line = Int(location.range.start.line) + 1
    location.uri == uri && return "Line $line"
    filepath = JETLSCore.uri2filepath(location.uri)
    filepath === nothing && return string(location.uri, ':', line)
    path = relative_paths(filepath, root)
    return string(isabspath(path) ? basename(path) : path, ':', line)
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
    related_information = diagnostic.relatedInformation
    if related_information !== nothing && !isempty(related_information)
        print(io, "<ul class=\"jetls-diagnostic-hover-related\">")
        for info in related_information
            print(io, "<li>", markdown_html(string(
                related_location(info.location, root, uri), ": ", info.message)), "</li>")
        end
        print(io, "</ul>")
    end
    print(io, "<div class=\"jetls-diagnostic-hover-source\">", escape_html(string(diagnostic.source)), " (")
    print_code_link(io, diagnostic, page_href; css = false)
    print(io, ")</div>")
    if !isempty(code_actions)
        print(io, "<div class=\"jetls-diagnostic-hover-actions\">Quick fixes<ul>")
        for code_action in code_actions
            print(io, "<li>", markdown_html(code_action.title), "</li>")
        end
        print(io, "</ul></div>")
    end
    print(io, "</div></template>")
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
    severity = minimum(diagnostic::Diagnostic -> diagnostic.severity, diagnostics)::DiagnosticSeverity.Ty
    spanclasses = ["jetls-diagnostic", "jetls-diagnostic-" * severity_name(severity)]
    if any(diagnostic::Diagnostic -> has_tag(diagnostic, DiagnosticTag.Unnecessary), diagnostics)
        push!(spanclasses, "jetls-diagnostic-unnecessary")
    end
    if any(diagnostic::Diagnostic -> has_tag(diagnostic, DiagnosticTag.Deprecated), diagnostics)
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

# The related information in the same code is underlined as Zed does, and hovering it shows
# the diagnostics that refer to it
covering_related(related_ranges::Vector{Tuple{Int,UnitRange{Int}}}, i::Int, indentend::Int) =
    i < indentend ? Int[] : unique!(Int[id for (id, range) in related_ranges if i in range])

function print_related_run(
        io::IO, code::String, bytes::UnitRange{Int}, classes::Vector{Union{Nothing,String}},
        ids::Vector{Int}
    )
    print(io, "<span class=\"jetls-diagnostic-related\" data-diagnostics=\"", join(ids, ' '), "\">")
    print_highlighted(io, code, bytes, classes)
    print(io, "</span>")
end

# Shows the first line of the message below the last line of the diagnostic, aligned with
# the start of its range on that line. The text is put in attributes and rendered by CSS,
# so that copying the code excludes it.
function print_diagnostic_message(
        io::IO, diagnostic::Diagnostic, id::Int, column::Int, root::String, page_href::String
    )
    raw_msg = diagnostic_message(diagnostic, root)
    message = first(eachsplit(raw_msg, '\n'))
    print(io, "<span class=\"jetls-diagnostic-message jetls-diagnostic-message-",
        severity_name(diagnostic.severity::DiagnosticSeverity.Ty), "\" style=\"padding-left: ", column, "ch\" data-message=\"",
        escape_html(message), "\" data-diagnostics=\"", id, "\">")
    print_code_link(io, diagnostic, page_href; css = true)
    print(io, "</span>")
end

function render_diagnostics_block(
        code::String, root::String, uri::URI, diagnostics::Vector{Diagnostic},
        code_actions::Vector{Vector{Union{CodeAction,Command}}}, page_href::String
    )
    textbuf = Vector{UInt8}(code)
    line_starts = JETLSCore.build_line_starts(textbuf)
    classes = hljs_classes(code)
    byte_ranges = UnitRange{Int}[
        lsp_byte_range(code, textbuf, line_starts, diagnostic.range) for diagnostic in diagnostics]
    related_ranges = Tuple{Int,UnitRange{Int}}[]
    for (id, diagnostic) in enumerate(diagnostics)
        related_information = diagnostic.relatedInformation
        related_information === nothing && continue
        for info in related_information
            info.location.uri == uri && !isempty(info.message) || continue
            push!(related_ranges, (id, lsp_byte_range(code, textbuf, line_starts, info.location.range)))
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
        indentend = something(findnext(c::Char -> !isspace(c), code, linestart), lineend)
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
        # The message elements are blocks, which break the line by themselves: an additional
        # newline would be copied as an empty line
        isempty(messages) && line < nlines && print(io, '\n')
        for (column, id) in sort!(messages; by = first)
            print_diagnostic_message(io, diagnostics[id], id, column, root, page_href)
        end
    end
    print(io, "</code></pre>")
    for (id, diagnostic) in enumerate(diagnostics)
        print_hover_template(io, id, diagnostic, code_actions[id], root, uri, page_href)
    end
    print(io, "</div>")
    return String(take!(io))
end
