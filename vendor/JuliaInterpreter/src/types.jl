"""
    abstract type Interpreter end

An interpreter that subtypes this type can implement its own evaluation strategies, by
overloading the certain methods in JuliaInterpreter that are defined for this base type.
The default behavior of `Interpreter` is same as that of [`RecursiveInterpreter`](@ref),
meaning it will recursively interpret all `:call` expressions.
"""
abstract type Interpreter end

"""
    RecursiveInterpreter <: Interpreter

`RecursiveInterpreter` is an [`Interpreter`](@ref) that recursively interprets any `:call`
expressions in the code being interpreted.

With this interpreter, code runs in fully interpreted mode; it will never be compiled for execution.
"""
struct RecursiveInterpreter <: Interpreter end

"""
    NonRecursiveInterpreter <: Interpreter

`NonRecursiveInterpreter` is an [`Interpreter`](@ref) that evaluates any `:call` expressions
in the code being interpreted using Julia's normal code execution engine with the native
compiler.

`JuliaInterpreter.Compiled` is aliased to `NonRecursiveInterpreter` for backward compatibility.
"""
struct NonRecursiveInterpreter <: Interpreter end

"""
    const Compiled = NonRecursiveInterpreter

As of JuliaInterpreter v0.10, `Compiled` is now an alias for [`NonRecursiveInterpreter`](@ref).
This remains for backward compatibility for packages using `Compiled`, and may be removed or
redefined as a completely different type in v0.11 or later.
"""
const Compiled = NonRecursiveInterpreter # for backward compatibility
Base.similar(::Compiled, sz) = Compiled()  # to support similar(stack, 0)

"""
    method_table(interpreter::Interpreter) -> mt::Union{Nothing,MethodTable}

Configures the method table used for method lookups performed by the interpreter.
Uses the global method table by default.
"""
method_table(::Interpreter) = nothing

# Our own replacements for Core types. We need to do this to ensure we can tell the difference
# between "data" (Core types) and "code" (our types) if we step into Core.Compiler
struct SSAValue
    id::Int
end
struct SlotNumber
    id::Int
end

Base.show(io::IO, ssa::SSAValue)    = print(io, "%J", ssa.id)
Base.show(io::IO, slot::SlotNumber) = print(io, "_J", slot.id)

# Breakpoint support
truecondition(frame) = true
falsecondition(frame) = false
const break_on_error = Ref(false)
const break_on_throw = Ref(false)

"""
    BreakpointState(isactive=true, condition=JuliaInterpreter.truecondition)

`BreakpointState` represents a breakpoint at a particular statement in
a `FrameCode`. `isactive` indicates whether the breakpoint is currently
[`enable`](@ref)d or [`disable`](@ref)d. `condition` is a function that accepts
a single `Frame`, and `condition(frame)` must return either
`true` or `false`. Execution will stop at a breakpoint only if `isactive`
and `condition(frame)` both evaluate as `true`. The default `condition` always
returns `true`.

To create these objects, see [`breakpoint`](@ref).
"""
struct BreakpointState
    isactive::Bool
    condition::Function
end
BreakpointState(isactive::Bool) = BreakpointState(isactive, truecondition)
BreakpointState() = BreakpointState(true)

function breakpointchar(bps::BreakpointState)
    if bps.isactive
        return bps.condition === truecondition ? 'b' : 'c'  # unconditional : conditional
    end
    return bps.condition === falsecondition ? ' ' : 'd'     # no breakpoint : disabled
end

struct _FrameInstance{FrameCode}
    framecode::FrameCode
    sparam_vals::SimpleVector
    enter_generated::Bool
end
Base.show(io::IO, instance::_FrameInstance) =
    print(io, "FrameInstance(", scopeof(instance.framecode), ", ", instance.sparam_vals, ", ", instance.enter_generated, ')')

mutable struct _DispatchableMethod{FrameCode}
    next::Union{Nothing,_DispatchableMethod{FrameCode}}  # linked-list representation
    frameinstance::Union{Compiled,_FrameInstance{FrameCode}} # really a Union{Compiled, FrameInstance} but we have a cyclic dependency
    sig::Type # for speed of matching, this is a *concrete* signature. `sig <: frameinstance.framecode.scope.sig`
end

# 0: none
# 1: user
# 2: all
const COVERAGE = Ref{Int8}()
function do_coverage(m::Module)
    COVERAGE[] == 2 && return true
    if COVERAGE[] == 1
       root = Base.moduleroot(m)
       return root !== Base && root !== Core
    end
    return false
end

"""
`FrameCode` holds static information about a method or toplevel code.
One `FrameCode` can be shared by many calling `Frame`s.

Important fields:
- `scope`: the `Method` or `Module` in which this frame is to be evaluated.
- `src`: the `CodeInfo` object storing (optimized) lowered source code.
- `methodtables`: a vector, each entry potentially stores a "local method table" for the corresponding
  `:call` expression in `src` (undefined entries correspond to statements that do not
  contain `:call` expressions).
- `used`: a `BitSet` storing the list of SSAValues that get referenced by later statements.
"""
struct FrameCode
    scope::Union{Method,Module}
    src::CodeInfo
    methodtables::Vector{Union{Compiled,_DispatchableMethod{FrameCode}}} # line-by-line method tables for generic-function :call Exprs
    breakpoints::Vector{BreakpointState}
    slotnamelists::Dict{Symbol,Vector{Int}}
    used::BitSet
    generator::Bool   # true if this is for the expression-generator of a @generated function
    report_coverage::Bool
    unique_files::Set{Symbol}
end

"""
`FrameInstance` represents a method specialized for particular argument types.

Fields:
- `framecode`: the [`FrameCode`](@ref) for the method.
- `sparam_vals`: the static parameter values for the method.
"""
const FrameInstance = _FrameInstance{FrameCode}
const DispatchableMethod = _DispatchableMethod{FrameCode}

const BREAKPOINT_EXPR = :($(QuoteNode(getproperty))($JuliaInterpreter, :__BREAKPOINT_MARKER__))
function is_breakpoint_expr(ex::Expr)
    # Sadly, comparing QuoteNodes calls isequal(::Any, ::Any), and === seems not to work.
    # To avoid invalidations, do it the hard way.
    ex.head === :call || return false
    length(ex.args) === 3 || return false
    (q = ex.args[1]; isa(q, QuoteNode) && q.value === getproperty) || return false
    ex.args[2] === JuliaInterpreter || return false
    q = ex.args[3]
    return isa(q, QuoteNode) && q.value === :__BREAKPOINT_MARKER__
end

@static if isbindingresolved_deprecated
    is_breakpoint_marker(stmt) = is_global_ref(stmt, JuliaInterpreter, :__BREAK_POINT_MARKER__)
else
    is_breakpoint_marker(stmt) = stmt === __BREAK_POINT_MARKER__
end

function FrameCode(scope, src::CodeInfo; generator=false, optimize=true)
    if optimize
        src, methodtables = optimize!(copy(src), scope)
    else
        src = replace_coretypes!(copy(src))
        methodtables = Vector{Union{Compiled,DispatchableMethod}}(undef, length(src.code))
    end
    breakpoints = Vector{BreakpointState}(undef, length(src.code))
    for (i, pc_expr) in enumerate(src.code)
        if is_breakpoint_marker(lookup_stmt(src.code, pc_expr))
            breakpoints[i] = BreakpointState()
            src.code[i] = nothing
        end
    end
    slotnamelists = Dict{Symbol,Vector{Int}}()
    for (i, sym) in enumerate(src.slotnames)
        list = get(slotnamelists, sym, Int[])
        slotnamelists[sym] = push!(list, i)
    end
    used = find_used(src)
    report_coverage = do_coverage(moduleof(scope))

    lt = linetable(src)
    unique_files = Set{Symbol}()
    @static if VERSION ≥ v"1.12.0-DEV.173"
    function pushuniquefiles!(unique_files::Set{Symbol}, lt)
        for edge in lt.edges
            pushuniquefiles!(unique_files, edge)
        end
        linetable = lt.linetable
        if linetable === nothing
            push!(unique_files, Base.IRShow.debuginfo_file1(lt))
        else
            pushuniquefiles!(unique_files, linetable)
        end
    end
    pushuniquefiles!(unique_files, lt)
    else # VERSION < v"1.12.0-DEV.173"
    for entry in lt
        push!(unique_files, entry.file)
    end
    end # @static if

    framecode = FrameCode(scope, src, methodtables, breakpoints, slotnamelists, used, generator, report_coverage, unique_files)
    if scope isa Method
        for bp in _breakpoints
            # Manual union splitting
            if bp isa BreakpointSignature
                add_breakpoint_if_match!(framecode, bp)
            elseif bp isa BreakpointFileLocation
                add_breakpoint_if_match!(framecode, bp)
            else
                error("unhandled breakpoint type")
            end
        end
    else
        for bp in _breakpoints
            if bp isa BreakpointFileLocation
                add_breakpoint_if_match!(framecode, bp)
            end
        end
    end

    return framecode
end

nstatements(framecode::FrameCode) = length(framecode.src.code)

Base.show(io::IO, framecode::FrameCode) = print_framecode(io, framecode)

"""
`FrameData` holds the arguments, local variables, and intermediate execution state
in a particular call frame.

Important fields:
- `locals`: a vector containing the input arguments and named local variables for this frame.
  The indexing corresponds to the names in the `slotnames` of the src. Use [`locals`](@ref)
  to extract the current value of local variables.
- `ssavalues`: a vector containing the
  [Static Single Assignment](https://en.wikipedia.org/wiki/Static_single_assignment_form)
  values produced at the current state of execution.
- `sparams`: the static type parameters, e.g., for `f(x::Vector{T}) where T` this would store
  the value of `T` given the particular input `x`.
- `exception_frames`: a list of indexes to `catch` blocks for handling exceptions within
  the current frame. The active handler is the last one on the list.
- `last_exception`: the exception `throw`n by this frame or one of its callees.
"""
struct FrameData
    locals::Vector{Union{Nothing,Some{Any}}}
    ssavalues::Vector{Any}
    sparams::Vector{Any}
    exception_frames::Vector{Int}
    current_scopes::Vector{Scope}
    last_exception::Base.RefValue{Any}
    caller_will_catch_err::Bool
    last_reference::Vector{Int}
    callargs::Vector{Any}  # a temporary for processing arguments of :call exprs
end

"""
    _INACTIVE_EXCEPTION

Represents a case where no exceptions are thrown yet.
End users will not see this singleton type, otherwise it usually means there is missing
error handling in the interpretation process.
"""
struct _INACTIVE_EXCEPTION end

"""
`Frame` represents the current execution state in a particular call frame.
Fields:
- `framecode`: the [`FrameCode`](@ref) for this frame.
- `framedata`: the [`FrameData`](@ref) for this frame.
- `pc`: the program counter (integer index of the next statment to be evaluated) for this frame.
- `caller`: the parent caller of this frame, or `nothing`.
- `callee`: the frame called by this one, or `nothing`.

The `Base` functions `show_backtrace` and `display_error` are overloaded such that
`show_backtrace(io::IO, frame::Frame)` and `display_error(io::IO, er, frame::Frame)`
shows a backtrace or error, respectively, in a similar way as to how Base shows
them.
"""
mutable struct Frame
    framecode::FrameCode
    framedata::FrameData
    pc::Int
    assignment_counter::Int64
    caller::Union{Frame,Nothing}
    callee::Union{Frame,Nothing}
    last_codeloc::Int
    # TODO: This is incompletely implemented
    world::UInt
end
function Frame(framecode::FrameCode, framedata::FrameData, pc=1, caller=nothing,
               world=@static isdefinedglobal(Base, :tls_world_age) ? Base.tls_world_age() : Base.get_world_counter())
    if length(junk_frames) > 0
        frame = pop!(junk_frames)
        frame.framecode = framecode
        frame.framedata = framedata
        frame.pc = pc
        frame.assignment_counter = 1
        frame.caller = caller
        frame.callee = nothing
        frame.last_codeloc = 0
        frame.world = world
        return frame
    else
        return Frame(framecode, framedata, pc, 1, caller, nothing, 0, world)
    end
end
"""
    frame = Frame(mod::Module, src::CodeInfo; kwargs...)

Construct a `Frame` to evaluate `src` in module `mod`.
"""
function Frame(mod::Module, src::CodeInfo; kwargs...)
    framecode = FrameCode(mod, src; kwargs...)
    return Frame(framecode, prepare_framedata(framecode, []))
end
"""
    frame = Frame(mod::Module, ex::Expr)

Construct a `Frame` to evaluate `ex` in module `mod`.

This constructor can error, for example if lowering `ex` results in an `:error` or `:incomplete`
expression, or if it otherwise fails to return a `:thunk`.
"""
function Frame(mod::Module, ex::Expr)
    lwr = Meta.lower(mod, ex)
    isexpr(lwr, :thunk) && return Frame(mod, lwr.args[1])
    if isexpr(lwr, :error) || isexpr(lwr, :incomplete)
        throw(ArgumentError("lowering returned an error, $lwr"))
    end
    throw(ArgumentError("lowering did not return a `:thunk` expression, got $lwr"))
end

caller(frame) = frame.caller
callee(frame) = frame.callee

function traverse(f, frame)
    while f(frame) !== nothing
        frame = f(frame)
    end
    return frame
end

"""
    rframe = root(frame)

Return the initial frame in the call stack.
"""
root(frame) = traverse(caller, frame)

"""
    lframe = leaf(frame)

Return the deepest callee in the call stack.
"""
leaf(frame) = traverse(callee, frame)

function Base.show(io::IO, frame::Frame)
    frame_loc = Base.fixup_stdlib_path(repr(scopeof(frame)))
    println(io, "Frame for ", frame_loc)
    pc = frame.pc
    ns = nstatements(frame.framecode)
    range = get(io, :limit, false) ? (max(1, pc-2):min(ns, pc+2)) : (1:ns)
    first(range) > 1 && println(io, "⋮")
    print_framecode(io, frame.framecode; pc=pc, range=range)
    last(range) < ns && print(io, "\n⋮")
    print_vars(IOContext(io, :limit=>true, :compact=>true), locals(frame))
    if caller(frame) !== nothing
        print(io, "\ncaller: ", scopeof(caller(frame)))
    end
    if callee(frame) !== nothing
        print(io, "\ncallee: ", scopeof(callee(frame)))
    end
end

"""
`Variable` is a struct representing a variable with an asigned value.
By calling the function [`locals`](@ref) on a [`Frame`](@ref) a
`Vector` of `Variable`'s is returned.

Important fields:
- `value::Any`: the value of the local variable.
- `name::Symbol`: the name of the variable as given in the source code.
- `isparam::Bool`: if the variable is a type parameter, for example `T` in `f(x::T) where {T} = x`.
- `is_captured_closure::Bool`: if the variable has been captured by a closure
"""
struct Variable
    value::Any
    name::Symbol
    isparam::Bool
    is_captured_closure::Bool
end
Variable(value, name) = Variable(value, name, false, false)
Variable(value, name, isparam) = Variable(value, name, isparam, false)
Base.show(io::IO, var::Variable) = (print(io, var.name, " = "); show(io,var.value))
Base.isequal(var1::Variable, var2::Variable) =
    var1.value == var2.value && var1.name === var2.name && var1.isparam == var2.isparam &&
    var1.is_captured_closure == var2.is_captured_closure
Base.:(==)(var1::Variable, var2::Variable) = isequal(var1, var2)

# A type that is unique to this package for which there are no valid operations
struct Unassigned end

"""
    BreakpointRef(framecode, stmtidx)
    BreakpointRef(framecode, stmtidx, err)

A reference to a breakpoint at a particular statement index `stmtidx` in `framecode`.
If the break was due to an error, supply that as well.

Commands that execute complex control-flow (e.g., `next_line!`) may also return a
`BreakpointRef` to indicate that the execution stack switched frames, even when no
breakpoint has been set at the corresponding statement.
"""
struct BreakpointRef
    framecode::FrameCode
    stmtidx::Int
    err
end
BreakpointRef(framecode, stmtidx) = BreakpointRef(framecode, stmtidx, nothing)
Base.getindex(bp::BreakpointRef) = bp.framecode.breakpoints[bp.stmtidx]
Base.setindex!(bp::BreakpointRef, isactive::Bool) =
    bp.framecode.breakpoints[bp.stmtidx] = BreakpointState(isactive, bp[].condition)

function Base.show(io::IO, bp::BreakpointRef)
    if checkbounds(Bool, bp.framecode.breakpoints, bp.stmtidx)
        lineno = linenumber(bp.framecode, bp.stmtidx)
        print(io, "breakpoint(", bp.framecode.scope, ", line ", lineno)
    else
        print(io, "breakpoint(", bp.framecode.scope, ", %", bp.stmtidx)
    end
    if bp.err !== nothing
        print(io, ", ", bp.err)
    end
    print(io, ')')
end

# Possible types for breakpoint condition
const Condition = Union{Nothing,Expr,Tuple{Module,Expr}}

"""
`AbstractBreakpoint` is the abstract type that is the supertype for breakpoints. Currently,
the concrete breakpoint types [`BreakpointSignature`](@ref) and [`BreakpointFileLocation`](@ref)
exist.

Common fields shared by the concrete breakpoints:

- `condition::Union{Nothing,Expr,Tuple{Module,Expr}}`: the condition when the breakpoint applies .
  `nothing` means unconditionally, otherwise when the `Expr` (optionally in `Module`).
- `enabled::Ref{Bool}`: If the breakpoint is enabled (should not be directly modified, use [`enable()`](@ref) or [`disable()`](@ref)).
- `instances::Vector{BreakpointRef}`: All the [`BreakpointRef`](@ref) that the breakpoint has applied to.
- `line::Int` The line of the breakpoint (equal to 0 if unset).

See [`BreakpointSignature`](@ref) and [`BreakpointFileLocation`](@ref) for additional fields in the concrete types.
"""
abstract type AbstractBreakpoint end

same_location(::AbstractBreakpoint, ::AbstractBreakpoint) = false

function print_bp_condition(io::IO, cond::Condition)
    if cond !== nothing
        if isa(cond, Tuple{Module, Expr}) && (expr = expr[2])
            cond = (cond[1], Base.remove_linenums!(copy(cond[2])))
        elseif isa(cond, Expr)
            cond = Base.remove_linenums!(copy(cond))
        end
        print(io, " ", cond)
    end
end

"""
A `BreakpointSignature` is a breakpoint that is set on methods or functions.

Fields:

- `f::Union{Method, Function, Type}`: A method or function that the breakpoint should apply to.
- `sig::Union{Nothing, Type}`: if `f` is a `Method`, always equal to `nothing`. Otherwise, contains the method signature
   as a tuple type for what methods the breakpoint should apply to.

For common fields shared by all breakpoints, see [`AbstractBreakpoint`](@ref).
"""
struct BreakpointSignature <: AbstractBreakpoint
    f::Union{Method, Base.Callable}
    sig::Union{Nothing, Type}
    line::Int # 0 is a sentinel for first statement
    condition::Condition
    enabled::Base.RefValue{Bool}
    instances::Vector{BreakpointRef}
end
same_location(bp2::BreakpointSignature, bp::BreakpointSignature) =
    bp2.f == bp.f && bp2.sig == bp.sig && bp2.line == bp.line
function Base.show(io::IO, bp::BreakpointSignature)
    print(io, bp.f)
    bbsig = bp.sig
    if bbsig !== nothing
        print(io, '(', join("::" .* string.(bbsig.types), ", "), ')')
    end
    if bp.line !== 0
        print(io, ":", bp.line)
    end
    print_bp_condition(io, bp.condition)
    if !bp.enabled[]
        print(io, " [disabled]")
    end
end

"""
A `BreakpointFileLocation` is a breakpoint that is set on a line in a file.

Fields:
- `path::String`: The literal string that was used to create the breakpoint, e.g. `"path/file.jl"`.
- `abspath`::String: The absolute path to the file when the breakpoint was created, e.g. `"/Users/Someone/path/file.jl"`.

For common fields shared by all breakpoints, see [`AbstractBreakpoint`](@ref).
"""
struct BreakpointFileLocation <: AbstractBreakpoint
    # Both the input path and the absolute path is stored to handle the case
    # where a user sets a breakpoint on a relative path e.g. `../foo.jl`. The absolute path is needed
    # to handle the case where the current working directory change, and
    # the input path is needed to do "partial path matches", e.g match "src/foo.jl" against
    # "Package/src/foo.jl".
    path::String
    abspath::String
    line::Int
    condition::Condition
    enabled::Base.RefValue{Bool}
    instances::Vector{BreakpointRef}
end
same_location(bp2::BreakpointFileLocation, bp::BreakpointFileLocation) =
    bp2.path == bp.path && bp2.abspath == bp.abspath && bp2.line == bp.line
function Base.show(io::IO, bp::BreakpointFileLocation)
    print(io, bp.path, ':', bp.line)
    print_bp_condition(io, bp.condition)
    if !bp.enabled[]
        print(io, " [disabled]")
    end
end
