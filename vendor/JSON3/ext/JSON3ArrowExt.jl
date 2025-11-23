module JSON3ArrowExt

using JSON3
using ArrowTypes

const JSON3_ARROW_NAME = Symbol("JuliaLang.JSON3.Object")

# It might looks strange to have this as a StructKind when JSON objects are
# very dict-like, but the valtype is Any, which Arrow.jl really not like
# and even if we add a
# toarrow(d::JSON3.Object) d = Dict{String, Union{typeof.(values(d))...}
# that does not seem to solve the problem.
ArrowTypes.ArrowKind(::Type{<:JSON3.Object}) = ArrowTypes.StructKind()
ArrowTypes.arrowname(::Type{<:JSON3.Object}) = JSON3_ARROW_NAME
ArrowTypes.JuliaType(::Val{JSON3_ARROW_NAME}) = JSON3.Object

end # module
