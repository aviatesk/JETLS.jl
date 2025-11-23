Base.Experimental.@optlevel 1

using Core: SimpleVector, MethodTable
using Core.IR: CodeInfo, GotoIfNot, GotoNode, IR, MethodInstance, ReturnNode
@static if isdefined(Core.IR, :EnterNode)
    using Core.IR: EnterNode
end
using .CC:
    BasicBlock, CFG,
    compute_basic_blocks, construct_domtree, construct_postdomtree,
    nearest_common_dominator, postdominates

@static if isdefined(CC, :IRShow)
    using .CC: IRShow
else
    using Base: IRShow
end

using Base.Meta: isexpr

const SSAValues = Union{Core.IR.SSAValue, JuliaInterpreter.SSAValue}

const trackedheads = (:method,)    # Revise uses this (for now), don't delete; also update test/hastrackedexpr if this list gets expanded
const structdecls = (:_structtype, :_abstracttype, :_primitivetype)

export signature, rename_framemethods!, methoddef!, methoddefs!, bodymethod
export CodeEdges, lines_required, lines_required!, selective_eval!, selective_eval_fromstart!

include("utils.jl")
include("signatures.jl")
include("codeedges.jl")

# precompilation

if ccall(:jl_generating_output, Cint, ()) == 1
    ex = :(f(x; color::Symbol=:green) = 2x)
    lwr = Meta.lower(@__MODULE__, ex)
    frame = Frame(@__MODULE__, lwr.args[1])
    rename_framemethods!(frame)
    ex = quote
        s = 0
        k = 5
        for i = 1:3
            global s, k
            s += rand(1:5)
            k += i
        end
    end
    lwr = Meta.lower(@__MODULE__, ex)
    src = lwr.args[1]
    edges = CodeEdges(@__MODULE__, src)
    isrequired = lines_required(GlobalRef(@__MODULE__, :s), src, edges)
    lines_required(GlobalRef(@__MODULE__, :s), src, edges; norequire=())
    lines_required(GlobalRef(@__MODULE__, :s), src, edges; norequire=exclude_named_typedefs(src, edges))
    for isreq in (isrequired, convert(Vector{Bool}, isrequired))
        lines_required!(isreq, src, edges; norequire=())
        lines_required!(isreq, src, edges; norequire=exclude_named_typedefs(src, edges))
    end
    frame = Frame(@__MODULE__, src)
    # selective_eval_fromstart!(frame, isrequired, true)
    precompile(selective_eval_fromstart!, (typeof(frame), typeof(isrequired), Bool))  # can't @eval during precompilation
    print_with_code(Base.inferencebarrier(devnull)::IO, src, edges)
    print_with_code(Base.inferencebarrier(devnull)::IO, src, isrequired)
end
