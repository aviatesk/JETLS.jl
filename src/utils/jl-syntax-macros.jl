# Staging ground for common Base macros defined on SyntaxTree.  These are in
# addition to JuliaLowering.jl/src/syntax_macros.jl, and can be merged there
# when possible.

# TODO: @inline, @noinline, @inbounds, @simd, @ccall, @isdefined, @assume_effects

# @nospecialize on >=2 args
function Base.var"@nospecialize"(__context__::JL.MacroContext, ex1, ex2, exs...)
    to_nospecialize = JS.SyntaxTree[ex1, ex2, exs...]
    JL.@ast(__context__,
            __context__.macrocall::JS.SyntaxTree,
            [JS.K"block" map(st->JL._apply_nospecialize(__context__, st), to_nospecialize)...])
end

function Base.var"@nospecialize"(__context__::JL.MacroContext)
    JL.@ast(__context__,
            __context__.macrocall::JS.SyntaxTree,
            [JS.K"meta" "nospecialize"::JS.K"Symbol"])
end

# This is a mock definition to enable the minimum code lowering necessary
# for LSP features such as rename/document highlight.
# TODO Provide proper defintions of `@specialize`

function Base.var"@specialize"(__context__::JL.MacroContext, exs...)
    JL.@ast(__context__, __context__.macrocall::JS.SyntaxTree, [JS.K"block" exs...])
end

function Base.var"@specialize"(__context__::JL.MacroContext, ex)
    JL.@ast(__context__, __context__.macrocall::JS.SyntaxTree, ex)
end

function Base.var"@specialize"(__context__::JL.MacroContext)
    JL.@ast(__context__,
            __context__.macrocall::JS.SyntaxTree,
            [JS.K"meta" "specialize"::JS.K"Symbol"])
end
