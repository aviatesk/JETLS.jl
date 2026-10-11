# This file is a part of Julia. License is MIT: https://julialang.org/license

# Forked from `stdlib/Markdown/src/GitHub/GitHub.jl` of JuliaLang/julia at the commit in
# `upstream.toml`. Local changes record source locations.

include("table.jl")

function github_paragraph(stream::IO, md::MD)
    skipwhitespace(stream)
    start = position(stream)
    buffer = IOBuffer()
    p = Paragraph()
    push!(md, p)
    for char in readeach(stream, Char)
        # handle Windows line ends
        if char == '\r'
            peek(stream, Char) == '\n' && read(stream, Char)
            char = '\n'
        end
        if char == '\n'
            eof(stream) && break
            if blankline(stream) || _parse(stream, md, breaking = true)
                break
            else
                write(buffer, '\n')
            end
        else
            write(buffer, char)
        end
    end
    record_paragraph!(md, p, buffer, stream, start)
    p.content = parseinline(seek(buffer, 0), md)
    return true
end

@flavor github [fencedcode, horizontalrule, list, indentcode, blockquote, admonition, footnote, hashheader,
                html_block, html_block_type7, github_table, github_paragraph,

                # Backslash escapes do not work in code blocks, code spans, autolinks, or raw HTML
                inline_code, autolink, html_inline,
                linebreak, escapes, entity,
                en_or_em_dash,
                double_tilde_strikethrough, tilde_strikethrough,
                asterisk_bold, underscore_bold,
                asterisk_italic, underscore_italic,
                image, footnote_link, link]
