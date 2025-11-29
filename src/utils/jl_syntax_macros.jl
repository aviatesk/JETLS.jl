# Staging ground for common Base macros defined on SyntaxTree.  These are in
# addition to JuliaLowering.jl/src/syntax_macros.jl, and can be merged there
# when possible.

# TODO: @inline, @noinline, @inbounds, @simd, @ccall, @isdefined, @assume_effects

# @nospecialize on >=2 args
function Base.var"@nospecialize"(__context__::JL.MacroContext, ex1, ex2, exs...)
    to_nospecialize = JL.SyntaxTree[ex1, ex2, exs...]
    JL.@ast(__context__,
            __context__.macrocall,
            [JS.K"block" map(st->JL._apply_nospecialize(__context__, st), to_nospecialize)...])
end

function Base.var"@nospecialize"(__context__::JL.MacroContext)
    JL.@ast(__context__,
            __context__.macrocall,
            [JS.K"meta" "nospecialize"::JS.K"Symbol"])
end
