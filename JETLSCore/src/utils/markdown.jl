const JULIA_LIKE_LANGUAGES = [
    "julia",
    "julia-repl",
    "jldoctest"
]

# Documenter cross-reference links — `[label](@ref)` / `[label](@ref target)` —
# get reduced to bare `label` text in LSP output. The target isn't a navigable
# URL, so clients either pop a "can't open this URI" prompt or silently drop the
# click; showing the label as plain text is the least surprising fallback until
# a proper resolver lands.
const REF_LINK_REGEX = r"\[([^\]]+)\]\(@ref(?:\s[^)]*)?\)"
strip_ref_links(s::AbstractString) = replace(s, REF_LINK_REGEX => s"\1")

"""
    lsrender(md::Markdown.MD) -> String

Render Markdown for LSP display with the following conversions:
- Code blocks with Julia-like languages (see `JULIA_LIKE_LANGUAGES`) normalized to "julia"
- Documenter `@ref` cross-reference links flattened to their label text
- Documenter admonitions (`!!! tip "Title"` …) rewritten as portable
  Markdown blockquotes with an emoji + title header
  (see [`admonition_marker`](@ref) for the category-to-emoji mapping)

TODO: Resolve `@ref` targets to actual definitions rather than stripping the link.
"""
lsrender(md::Markdown.MD) = strip_ref_links(sprint(lsrender, md))

lsrender(io::IO, md::Markdown.MarkdownElement) = Markdown.plain(io, md)

function lsrender(io::IO, md::Markdown.MD)
    isempty(md.content) && return
    for md in md.content[1:end-1]
        lsrender(io, md)
        println(io)
    end
    lsrender(io, md.content[end])
end

function lsrender(io::IO, code::Markdown.Code)
    n = mapreduce(m -> length(m.match), max, eachmatch(r"^`+"m, code.code); init=2) + 1
    println(io, "`" ^ n, code.language in JULIA_LIKE_LANGUAGES ? "julia" : code.language)
    println(io, code.code)
    println(io, "`" ^ n)
end

function admonition_marker(category::AbstractString)
    cat = lowercase(category)
    cat == "note"    && return "📝"
    cat == "info"    && return "ℹ️"
    cat == "tip"     && return "💡"
    cat == "warning" && return "⚠️"
    cat == "danger"  && return "🚨"
    cat == "compat"  && return "⬆️"
    return "💬"
end

function lsrender(io::IO, ad::Markdown.Admonition)
    marker = admonition_marker(ad.category)
    title = isempty(ad.title) ? uppercasefirst(ad.category) : ad.title
    println(io, "> **", marker, " ", title, "**")
    isempty(ad.content) && return
    body = sprint() do bio
        for i = 1:(length(ad.content)-1)
            lsrender(bio, ad.content[i])
            println(bio)
        end
        lsrender(bio, ad.content[end])
    end
    println(io, ">")
    for line in eachsplit(rstrip(body), '\n')
        isempty(line) ? println(io, ">") : println(io, "> ", line)
    end
end

@static if VERSION < v"1.13.0-DEV.823" # JuliaLang/julia#58916
lsrender(io::IO, table::Markdown.Table) = Markdown.plain(io, table)
lsrender(io::IO, latex::Markdown.LaTeX) = Markdown.plain(io, latex)
end
