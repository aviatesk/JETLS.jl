# This file is a part of Julia. License is MIT: https://julialang.org/license

# Forked from `stdlib/Markdown/src/IPython/IPython.jl` of JuliaLang/julia at the commit in
# `upstream.toml`. Local changes drop the renderers.

mutable struct LaTeX <: MarkdownElement
    formula::String
end

@trigger '$' ->
function tex(stream::IO, md::MD)
    result = parse_inline_wrapper(stream, "\$", rep = true)
    return result === nothing ? nothing : LaTeX(result)
end

function blocktex(stream::IO, md::MD)
    withstream(stream) do
        ex = tex(stream, md)
        if ex ≡ nothing
            return false
        else
            push!(md, ex)
            return true
        end
    end
end

show(io::IO, tex::LaTeX) =
    print(io, '$', tex.formula, '$')
