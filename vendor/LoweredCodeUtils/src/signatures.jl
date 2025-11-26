"""
    sig = signature(sigsv::SimpleVector)

Compute a method signature from a suitable `SimpleVector`: `sigsv[1]` holds the signature
and `sigsv[2]` the `TypeVar`s.

# Example:

For `f(x::AbstractArray{T}) where T`, the corresponding `sigsv` is constructed as

    T = TypeVar(:T)
    sig1 = Core.svec(typeof(f), AbstractArray{T})
    sig2 = Core.svec(T)
    sigsv = Core.svec(sig1, sig2)
    sig = signature(sigsv)
"""
function signature(sigsv::SimpleVector)
    sigp::SimpleVector, sigtv::SimpleVector = sigsv
    sig = Tuple{sigp...}
    for i = length(sigtv):-1:1
        sig = UnionAll(sigtv[i], sig)
    end
    return sig::Union{DataType,UnionAll}
end

"""
    (mt, sigt), lastpc = signature([interp::Interpreter=RecursiveInterpreter()], frame::Frame, pc::Int)

Compute the method table `mt` and signature-type `sigt` of a method whose definition in `frame` starts at `pc`.
Generally, `pc` should point to the `Expr(:method, methname)` statement, in which case
`lastpc` is the final statement number in `frame` that is part of the signature
(i.e, the line above the 3-argument `:method` expression).
Alternatively, `pc` can point to the 3-argument `:method` expression,
as long as all the relevant SSAValues have been assigned.
In this case, `lastpc == pc`.

If no 3-argument `:method` expression is found, `nothing` will be returned in place of `(mt, sigt)`.
"""
function signature(interp::Interpreter, frame::Frame, @nospecialize(stmt), pc::Int)
    mod = moduleof(frame)
    lastpc = frame.pc = pc
    while !isexpr(stmt, :method, 3)  # wait for the 3-arg version
        if isanonymous_typedef(stmt)
            lastpc = pc = step_through_methoddef(interp, frame, stmt)   # define an anonymous function
        elseif is_Typeof_for_anonymous_methoddef(stmt, frame.framecode.src.code, mod)
            return nothing, pc
        else
            lastpc = pc
            pc = step_expr!(interp, frame, stmt, true)
            pc === nothing && return nothing, lastpc
        end
        stmt = pc_expr(frame, pc)
    end
    isa(stmt, Expr) || return nothing, pc
    mt = extract_method_table(frame, stmt)
    sigsv = lookup(interp, frame, stmt.args[2])::SimpleVector
    sigt = signature(sigsv)
    return MethodInfoKey(mt, sigt), lastpc
end
signature(interp::Interpreter, frame::Frame, pc::Int) = signature(interp, frame, pc_expr(frame, pc), pc)
signature(frame::Frame, pc::Int) = signature(RecursiveInterpreter(), frame, pc)

function is_Typeof_for_anonymous_methoddef(@nospecialize(stmt), code::Vector{Any}, mod::Module)
    isexpr(stmt, :call) || return false
    f = stmt.args[1]
    isa(f, QuoteNode) || return false
    f.value === Core.Typeof || return false
    arg1 = stmt.args[2]
    if isa(arg1, SSAValue)
        arg1 = code[arg1.id]
    end
    arg1 isa Symbol || return false
    return !isdefined(mod, arg1)
end

function minid(@nospecialize(node), stmts, id)
    if isa(node, SSAValue)
        id = min(id, node.id)
        stmt = stmts[node.id]
        return minid(stmt, stmts, id)
    elseif isa(node, Expr)
        for a in node.args
            id = minid(a, stmts, id)
        end
    end
    return id
end

function signature_top(frame, stmt::Expr, pc)
    @assert ismethod3(stmt)
    return minid(stmt.args[2], frame.framecode.src.code, pc)
end

function step_through_methoddef(interp::Interpreter, frame::Frame, @nospecialize(stmt))
    while !isexpr(stmt, :method)
        pc = step_expr!(interp, frame, stmt, true)
        stmt = pc_expr(frame, pc)
    end
    return step_expr!(interp, frame, stmt, true)  # also define the method
end

"""
    MethodInfo(start, stop, refs)

Given a frame and its CodeInfo, `start` is the line of the first `Expr(:method, name)`,
whereas `stop` is the line of the last `Expr(:method, name, sig, src)` expression for `name`.
`refs` is a vector of line numbers of other references.
Some of these will be the location of the "declaration" of a method,
the `:thunk` expression containing a CodeInfo that just returns a 1-argument `:method` expression.
Others may be `:global` declarations.

In some cases there may be more than one method with the same name in the `start:stop` range.
"""
mutable struct MethodInfo
    start::Int
    stop::Int
    refs::Vector{Int}
end
MethodInfo(start) = MethodInfo(start, -1, Int[])

struct SelfCall
    linetop::Int
    linebody::Int
    callee::GlobalRef
    caller::Union{GlobalRef,Bool,Nothing}
end

"""
    methodinfos::Dict{GlobalRef,MethodInfo}, selfcalls::Vector{SelfCall} = identify_framemethod_calls(frame::Frame)

Analyze the code in `frame` to locate method definitions and "self-calls," i.e., calls
to methods defined in `frame` that occur within `frame`.

`methodinfos` is a Dict of `name=>info` pairs, where `info` is a [`MethodInfo`](@ref).

`selfcalls` is a list of `SelfCall(linetop, linebody, callee, caller)` that holds the location of
calls the methods defined in `frame`. `linetop` is the line in `frame` (top meaning "top level"),
which will correspond to a 3-argument `:method` expression containing a `CodeInfo` body.
`linebody` is the line within the `CodeInfo` body from which the call is made.
`callee` is the Symbol of the called method.
"""
function identify_framemethod_calls(frame::Frame)
    refs = Pair{GlobalRef,Int}[]
    methodinfos = Dict{GlobalRef,MethodInfo}()
    selfcalls = SelfCall[]
    for (i, stmt) in enumerate(frame.framecode.src.code)
        isa(stmt, Expr) || continue
        if stmt.head === :global && length(stmt.args) == 1
            key = normalize_defsig(stmt.args[1], frame)
            if isa(key, GlobalRef)
                # We don't know for sure if this is a reference to a method, but let's
                # tentatively cue it
                push!(refs, key=>i)
            end
        elseif stmt.head === :thunk && stmt.args[1] isa CodeInfo
            tsrc = stmt.args[1]::CodeInfo
            if length(tsrc.code) == 1
                tstmt = tsrc.code[1]
                if is_return(tstmt)
                    tex = tstmt.val
                    if isa(tex, Expr)
                        if tex.head === :method && (methname = tex.args[1]; isa(methname, Union{Symbol, GlobalRef}))
                            push!(refs, normalize_defsig(methname, frame)=>i)
                        end
                    end
                end
            end
        elseif ismethod1(stmt)
            key = stmt.args[1]
            key = normalize_defsig(key, frame)
            key = key::GlobalRef
            mi = get(methodinfos, key, nothing)
            if mi === nothing
                methodinfos[key] = MethodInfo(i)
            else
                mi.stop == -1 && (mi.start = i) # advance the statement # unless we've seen the method3
            end
        elseif ismethod3(stmt)
            key = stmt.args[1]
            key = normalize_defsig(key, frame)
            if key isa GlobalRef
                # XXX A temporary hack to fix https://github.com/JuliaDebug/LoweredCodeUtils.jl/issues/80
                #     We should revisit it.
                mi = get(methodinfos, key, MethodInfo(1))
                mi.stop = i
            elseif key isa Expr   # this is a module-scoped call. We don't have to worry about these because they are named
                continue
            end
            msrc = stmt.args[3]
            if msrc isa CodeInfo
                # XXX: Properly support interpolated `Core.MethodTable`. This will require using
                # `stmt.args[2]` instead of `stmt.args[1]` to identify the parent function.
                isa(key, Union{GlobalRef,Bool,Nothing}) || continue
                for (j, mstmt) in enumerate(msrc.code)
                    isa(mstmt, Expr) || continue
                    jj = j
                    if mstmt.head === :call
                        mkey = normalize_defsig(mstmt.args[1], frame)
                        if isa(mkey, SSAValue) || isa(mkey, Core.SSAValue)
                            refstmt = msrc.code[mkey.id]
                            if isa(refstmt, Union{Symbol, GlobalRef})
                                jj = mkey.id
                                mkey = normalize_defsig(refstmt, frame)
                            end
                        end
                        if is_global_ref(mkey, Core, :_apply_iterate)
                            ssaref = mstmt.args[end-1]
                            if isa(ssaref, JuliaInterpreter.SSAValue)
                                id = ssaref.id
                                has_self_call(msrc, msrc.code[id]) || continue
                            end
                            mkey = normalize_defsig(mstmt.args[end-2], frame)
                            if isa(mkey, GlobalRef)
                                haskey(methodinfos, mkey) && push!(selfcalls, SelfCall(i, jj, mkey, key))
                            end
                        elseif isa(mkey, GlobalRef)
                            haskey(methodinfos, mkey) && push!(selfcalls, SelfCall(i, jj, mkey, key))
                        end
                    elseif mstmt.head === :meta && mstmt.args[1] === :generated
                        newex = mstmt.args[2]
                        if isa(newex, Expr)
                            if newex.head === :new && length(newex.args) >= 2 && is_global_ref(newex.args[1], Core, :GeneratedFunctionStub)
                                mkey = newex.args[2]
                                if isa(mkey, Symbol)
                                    mkey = GlobalRef(moduleof(frame), mkey)
                                end
                                haskey(methodinfos, mkey) && push!(selfcalls, SelfCall(i, jj, mkey, key))
                            end
                        end
                    end
                end
            end
        end
    end
    for r in refs
        mi = get(methodinfos, r.first, nothing)
        mi === nothing || push!(mi.refs, r.second)
    end
    return methodinfos, selfcalls
end

# try to normalize `def` to `GlobalRef` representation
function normalize_defsig(@nospecialize(def), mod::Module)
    if def isa QuoteNode
        def = nameof(def.value)
    end
    if def isa Symbol
        def = GlobalRef(mod, def)
    end
    return def
end
normalize_defsig(@nospecialize(def), frame::Frame) = normalize_defsig(def, moduleof(frame))

const CalledBy = Dict{GlobalRef,Union{GlobalRef,Bool,Nothing}}

function callchain(selfcalls)
    calledby = CalledBy()
    for sc in selfcalls
        startswith(String(sc.callee.name), '#') || continue
        caller = get(calledby, sc.callee, nothing)
        if caller === nothing
            calledby[sc.callee] = sc.caller
        elseif caller == sc.caller
        else
            error("unexpected multiple callers, ", caller, " and ", sc.caller)
        end
    end
    return calledby
end

function set_to_running_name!(interp::Interpreter, replacements::Dict{GlobalRef,GlobalRef}, frame::Frame,
                              methodinfos::Dict{GlobalRef,MethodInfo}, selfcall::SelfCall,
                              calledby::CalledBy, callee::GlobalRef, @nospecialize caller#=::Union{GlobalRef,Bool,Nothing}=#)
    if isa(caller, GlobalRef) && startswith(String(caller.name), '#')
        rep = get(replacements, caller, nothing)
        if rep === nothing
            parentcaller = get(calledby, caller, nothing)
            if parentcaller !== nothing
                set_to_running_name!(interp, replacements, frame, methodinfos, selfcall, calledby, caller, parentcaller)
            end
        else
            caller = rep
        end
    end
    # Back up to the beginning of the signature
    pc = selfcall.linetop
    stmt = pc_expr(frame, pc)
    while pc > 1 && !ismethod1(stmt)
        pc -= 1
        stmt = pc_expr(frame, pc)
    end
    @assert ismethod1(stmt)
    cname, _pc, _ = try
        get_running_name(interp, frame, pc+1, callee)
    catch err
        if isa(err, UndefVarError)
            # The function may not be defined, in which case there is nothing to replace
            return replacements
        end
        throw(err)
    end
    replacements[callee] = cname
    mi = methodinfos[cname] = methodinfos[callee]
    src = frame.framecode.src
    replacename!(src, callee=>cname) # the method itself
    return replacements
end

"""
    methranges = rename_framemethods!([interp::Interpreter=RecursiveInterpreter()], frame::Frame)

Rename the gensymmed methods in `frame` to match those that are currently active.
The issues are described in https://github.com/JuliaLang/julia/issues/30908.
`frame` will be modified in-place as needed.

Returns a vector of `name=>start:stop` pairs specifying the range of lines in `frame`
at which method definitions occur. In some cases there may be more than one method with
the same name in the `start:stop` range.
"""
function rename_framemethods! end

function _rename_framemethods!(interp::Interpreter, frame::Frame,
                               methodinfos::Dict{GlobalRef,MethodInfo}, selfcalls::Vector{SelfCall}, calledby::CalledBy)
    src = frame.framecode.src
    replacements = Dict{GlobalRef,GlobalRef}()
    for (callee, caller) in calledby
        (!startswith(String(callee.name), '#') || haskey(replacements, callee)) && continue
        idx = findfirst(sc->sc.callee === callee && sc.caller === caller, selfcalls)
        idx === nothing && continue
        try
            set_to_running_name!(interp, replacements, frame, methodinfos, selfcalls[idx], calledby, callee, caller)
        catch err
            @warn "skipping callee $callee (called by $caller) due to $err"
        end
    end
    for sc in selfcalls
        linetop, linebody, callee, caller = sc.linetop, sc.linebody, sc.callee, sc.caller
        cname = get(replacements, callee, nothing)
        if cname !== nothing && cname !== callee
            replacename!((src.code[linetop].args[3])::CodeInfo, callee=>cname)
        end
    end
    return methodinfos
end

function rename_framemethods!(interp::Interpreter, frame::Frame)
    pc0 = frame.pc
    methodinfos, selfcalls = identify_framemethod_calls(frame)
    calledby = callchain(selfcalls)
    _rename_framemethods!(interp, frame, methodinfos, selfcalls, calledby)
    frame.pc = pc0
    return methodinfos
end
rename_framemethods!(frame::Frame) = rename_framemethods!(RecursiveInterpreter(), frame)

"""
    pctop, isgen = find_name_caller_sig(interp::Interpreter, frame::Frame, pc::Int, name::GlobalRef)

Scans forward from `pc` in `frame` until a method is found that calls `name`.
`pctop` points to the beginning of that method's signature.
`isgen` is true if `name` corresponds to sa GeneratedFunctionStub.

Alternatively, this returns `nothing` if `pc` does not appear to point to either
a keyword or generated method.
"""
function find_name_caller_sig(interp::Interpreter, frame::Frame, pc::Int, name::GlobalRef)
    stmt = pc_expr(frame, pc)
    while true
        pc0 = pc
        while !ismethod3(stmt)
            pc = next_or_nothing(interp, frame, pc)
            pc === nothing && return nothing
            stmt = pc_expr(frame, pc)
        end
        body = stmt.args[3]
        if normalize_defsig(stmt.args[1], frame) !== name && isa(body, CodeInfo)
            # This might be the GeneratedFunctionStub for a @generated method
            for (i, bodystmt) in enumerate(body.code)
                if isexpr(bodystmt, :meta) && (bodystmt::Expr).args[1] === :generated
                    return signature_top(frame, stmt, pc), true
                end
                i >= 5 && break  # we should find this early
            end
            if length(body.code) > 1
                bodystmt = body.code[end-1]  # the line before the final return
                iscallto(bodystmt, moduleof(frame), name, body) && return signature_top(frame, stmt, pc), false
            end
        end
        pc = next_or_nothing(interp, frame, pc)
        pc === nothing && return nothing
        stmt = pc_expr(frame, pc)
    end
end

"""
    replacename!(stmts, oldname=>newname)

Replace a Symbol `oldname` with GlobalRef `newname` in `stmts`.
"""
function replacename!(ex::Expr, pr)
    replacename!(ex.args, pr)
    return ex
end

replacename!(src::CodeInfo, pr) = replacename!(src.code, pr)

function replacename!(args::AbstractVector, pr)
    oldname, newname = pr
    for i = 1:length(args)
        a = args[i]
        if isa(a, Expr)
            replacename!(a, pr)
        elseif isa(a, CodeInfo)
            replacename!(a.code, pr)
        elseif isa(a, QuoteNode) && a.value === oldname
            args[i] = QuoteNode(newname)
        elseif isa(a, QuoteNode) && a.value === oldname.name
            args[i] = QuoteNode(newname.name)
        elseif isa(a, Vector{Any})
            replacename!(a, pr)
        elseif isa(a, Core.ReturnNode) && isdefined(a, :val) && a.val isa Expr
            # there is something like `ReturnNode(Expr(:method, Symbol(...)))`
            replacename!(a.val::Expr, pr)
        elseif a === oldname
            args[i] = newname
        elseif a == oldname.name
            args[i] = newname.name
        end
    end
    return args
end

function get_running_name(interp::Interpreter, frame::Frame, pc::Int, name::GlobalRef)
    nameinfo = find_name_caller_sig(interp, frame, pc, name)
    if nameinfo === nothing
        pc = skip_until(@nospecialize(stmt)->isexpr(stmt, :method, 3), frame, pc)
        pc = next_or_nothing(interp, frame, pc)
        return name, pc, nothing
    end
    pctop, isgen = nameinfo
    # Sometimes signature_top---which follows SSAValue links backwards to find the first
    # line needed to define the signature---misses out on a SlotNumber assignment.
    # Fix https://github.com/timholy/Revise.jl/issues/422
    stmt = pc_expr(frame, pctop)
    while pctop > 1 && isa(stmt, SlotNumber) && !isassigned(frame.framedata.locals, pctop)
        pctop -= 1
        stmt = pc_expr(frame, pctop)
    end   # end fix
    (mt, sigtparent), lastpcparent = signature(interp, frame, pctop)
    sigtparent === nothing && return name, pc, lastpcparent
    methparent = whichtt(sigtparent, mt)
    methparent === nothing && return name, pc, lastpcparent  # caller isn't defined, no correction is needed
    if isgen
        cname = GlobalRef(moduleof(frame), nameof(methparent.generator.gen))
    else
        bodyparent = Base.uncompressed_ast(methparent)
        bodystmt = bodyparent.code[end-1]
        @assert isexpr(bodystmt, :call)
        ref = getcallee(bodystmt)
        if isa(ref, SSAValue) || isa(ref, Core.SSAValue)
            ref = bodyparent.code[ref.id]
        end
        isa(ref, GlobalRef) || @show ref typeof(ref)
        @assert isa(ref, GlobalRef)
        @assert ref.mod == moduleof(frame)
        cname = ref
    end
    return cname, pc, lastpcparent
end

"""
    nextpc = next_or_nothing([interp::Interpreter=RecursiveInterpreter()], frame::Frame, pc::Int)
    nextpc = next_or_nothing!([interp::Interpreter=RecursiveInterpreter()], frame::Frame)

Advance the program counter without executing the corresponding line.
If `frame` is finished, `nextpc` will be `nothing`.
"""
next_or_nothing(frame::Frame, pc::Int) = next_or_nothing(RecursiveInterpreter(), frame, pc)
next_or_nothing(::Interpreter, frame::Frame, pc::Int) = pc < nstatements(frame.framecode) ? pc+1 : nothing
next_or_nothing!(frame::Frame) = next_or_nothing!(RecursiveInterpreter(), frame)
function next_or_nothing!(::Interpreter, frame::Frame)
    pc = frame.pc
    if pc < nstatements(frame.framecode)
        return frame.pc = pc + 1
    end
    return nothing
end

"""
    nextpc = skip_until(predicate, [interp::Interpreter=RecursiveInterpreter()], frame, pc)
    nextpc = skip_until!(predicate, [interp::Interpreter=RecursiveInterpreter()], frame)

Advance the program counter until `predicate(stmt)` return `true`.
"""
skip_until(predicate, frame::Frame, pc::Int) = skip_until(predicate, RecursiveInterpreter(), frame, pc)
function skip_until(predicate::F, interp::Interpreter, frame::Frame, pc::Int) where F
    stmt = pc_expr(frame, pc)
    while !predicate(stmt)
        pc = next_or_nothing(interp, frame, pc)
        pc === nothing && return nothing
        stmt = pc_expr(frame, pc)
    end
    return pc
end
skip_until!(predicate, frame::Frame) = skip_until!(predicate, RecursiveInterpreter(), frame)
function skip_until!(predicate::F, interp::Interpreter, frame::Frame) where F
    pc = frame.pc
    stmt = pc_expr(frame, pc)
    while !predicate(stmt)
        pc = next_or_nothing!(interp, frame)
        pc === nothing && return nothing
        stmt = pc_expr(frame, pc)
    end
    return pc
end

"""
    ret = methoddef!([interp::Interpreter=RecursiveInterpreter()], signatures, frame; define=true)

Compute the method table/signature pair of a method definition. `frame.pc` should point to a
`:method` expression. Upon exit, the new method table/signature pair will be added to `signatures`.

There are several possible return values:

    pc, pc3 = ret

is the typical return. `pc` will point to the next statement to be executed, or be `nothing`
if there are no further statements in `frame`. `pc3` will point to the 3-argument `:method`
expression.

Alternatively,

    pc = ret

occurs for "empty method" expressions, e.g., `:(function foo end)`. `pc` will be `nothing`.

By default the method will be defined (evaluated). You can prevent this by setting `define=false`.
This is recommended if you are simply extracting signatures from code that has already been evaluated.
"""
function methoddef!(interp::Interpreter, signatures::Vector{MethodInfoKey}, frame::Frame, @nospecialize(stmt), pc::Int; define::Bool=true)
    framecode, pcin = frame.framecode, pc
    if ismethod3(stmt)
        pc3 = pc
        arg1 = stmt.args[1]
        (mt, sigt), pc = signature(interp, frame, stmt, pc)
        meth = whichtt(sigt, mt)
        if isa(meth, Method) && (meth.sig <: sigt && sigt <: meth.sig)
            pc = define ? step_expr!(interp, frame, stmt, true) : next_or_nothing!(interp, frame)
        elseif define
            pc = step_expr!(interp, frame, stmt, true)
            meth = whichtt(sigt, mt)
        end
        if isa(meth, Method) && (meth.sig <: sigt && sigt <: meth.sig)
            push!(signatures, MethodInfoKey(mt, meth.sig))
        else
            if arg1 === false || arg1 === nothing || isa(mt, MethodTable)
                # If it's anonymous and not defined, define it
                pc = step_expr!(interp, frame, stmt, true)
                meth = whichtt(sigt, mt)
                isa(meth, Method) && push!(signatures, MethodInfoKey(mt, meth.sig))
                return pc, pc3
            else
                # guard against busted lookup, e.g., https://github.com/JuliaLang/julia/issues/31112
                code = framecode.src
                codeloc = codelocation(code, pc)
                loc = linetable(code, codeloc)
                ft = Base.unwrap_unionall((Base.unwrap_unionall(sigt)::DataType).parameters[1])
                if !startswith(String((ft.name::Core.TypeName).name), "##")
                    @warn "file $(loc.file), line $(loc.line): no method found for $sigt"
                end
                if pc == pc3
                    pc = next_or_nothing!(interp, frame)
                end
            end
        end
        frame.pc = pc
        return pc, pc3
    end
    ismethod1(stmt) || Base.invokelatest(error, "expected method opening, got ", stmt)
    name = normalize_defsig(stmt.args[1], frame)
    if isa(name, Bool)
        error("not valid for anonymous methods")
    elseif name === missing
        Base.invokelatest(error, "given invalid definition: ", stmt)
    end
    name = name::GlobalRef
    # Is there any 3-arg method definition with the same name? If not, avoid risk of executing code that
    # we shouldn't (fixes https://github.com/timholy/Revise.jl/issues/758)
    found = false
    for i = pc+1:length(framecode.src.code)
        newstmt = framecode.src.code[i]
        if ismethod3(newstmt)
            if ismethod_with_name(framecode.src, newstmt, string(name.name))
                found = true
                break
            end
        end
    end
    found || return nothing
    while true  # methods containing inner methods may need multiple trips through this loop
        (mt, sigt), pc = signature(interp, frame, stmt, pc)
        stmt = pc_expr(frame, pc)
        while !isexpr(stmt, :method, 3)
            pc = next_or_nothing(interp, frame, pc)  # this should not check define, we've probably already done this once
            pc === nothing && return nothing   # this was just `function foo end`, signal "no def"
            stmt = pc_expr(frame, pc)
        end
        pc3 = pc
        stmt = stmt::Expr
        name3 = normalize_defsig(stmt.args[1], frame)
        sigt === nothing && (error("expected a signature"); return next_or_nothing(interp, frame, pc)), pc3
        # Methods like f(x::Ref{<:Real}) that use gensymmed typevars will not have the *exact*
        # signature of the active method. So let's get the active signature.
        frame.pc = pc
        pc = define ? step_expr!(interp, frame, stmt, true) : next_or_nothing!(interp, frame)
        meth = whichtt(sigt, mt)
        isa(meth, Method) && push!(signatures, MethodInfoKey(mt, meth.sig)) # inner methods are not visible
        name === name3 && return pc, pc3     # if this was an inner method we should keep going
        stmt = pc_expr(frame, pc)  # there *should* be more statements in this frame
    end
end
methoddef!(interp::Interpreter, signatures::Vector{MethodInfoKey}, frame::Frame, pc::Int; define::Bool=true) =
    methoddef!(interp, signatures, frame, pc_expr(frame, pc), pc; define)
function methoddef!(interp::Interpreter, signatures::Vector{MethodInfoKey}, frame::Frame; define::Bool=true)
    pc = frame.pc
    stmt = pc_expr(frame, pc)
    if !ismethod(stmt)
        pc = next_until!(ismethod, interp, frame, true)
    end
    pc === nothing && error("pc at end of frame without finding a method")
    methoddef!(interp, signatures, frame, pc; define)
end
methoddef!(signatures::Vector{MethodInfoKey}, frame::Frame, pc::Int; define::Bool=true) =
    methoddef!(RecursiveInterpreter(), signatures, frame, pc_expr(frame, pc), pc; define)
methoddef!(signatures::Vector{MethodInfoKey}, frame::Frame; define::Bool=true) =
    methoddef!(RecursiveInterpreter(), signatures, frame; define)

function methoddefs!(interp::Interpreter, signatures::Vector{MethodInfoKey}, frame::Frame, pc::Int; define::Bool=true)
    ret = methoddef!(interp, signatures, frame, pc; define)
    pc = ret === nothing ? ret : ret[1]
    return _methoddefs!(interp, signatures, frame, pc; define)
end
function methoddefs!(interp::Interpreter, signatures::Vector{MethodInfoKey}, frame::Frame; define::Bool=true)
    ret = methoddef!(interp, signatures, frame; define)
    pc = ret === nothing ? ret : ret[1]
    return _methoddefs!(interp, signatures, frame, pc; define)
end
methoddefs!(signatures::Vector{MethodInfoKey}, frame::Frame, pc::Int; define::Bool=true) =
    methoddefs!(RecursiveInterpreter(), signatures, frame, pc; define)
methoddefs!(signatures::Vector{MethodInfoKey}, frame::Frame; define::Bool=true) =
    methoddefs!(RecursiveInterpreter(), signatures, frame; define)

function _methoddefs!(interp::Interpreter, signatures::Vector{MethodInfoKey}, frame::Frame, pc::Int; define::Bool=define)
    while pc !== nothing
        stmt = pc_expr(frame, pc)
        if !ismethod(stmt)
            pc = next_until!(ismethod, interp, frame, true)
        end
        pc === nothing && break
        ret = methoddef!(interp, signatures, frame, pc; define)
        pc = ret === nothing ? ret : ret[1]
    end
    return pc
end

function is_self_call(@nospecialize(stmt), slotnames, argno::Integer=1)
    if isa(stmt, Expr)
        if stmt.head == :call
            a = stmt.args[argno]
            if isa(a, SlotNumber) || isa(a, Core.SlotNumber)
                sn = slotnames[a.id]
                if sn == Symbol("#self#") || sn == Symbol("") # allow empty to fix https://github.com/timholy/CodeTracking.jl/pull/48
                    return true
                end
            end
        end
    end
    return false
end

function has_self_call(src, stmt::Expr)
    # Check that it has a #self# call
    hasself = false
    for i = 2:length(stmt.args)
        hasself |= is_self_call(stmt, src.slotnames, i)
    end
    return hasself
end

"""
    mbody = bodymethod(m::Method)

Return the "body method" for a method `m`. `mbody` contains the code of the function body
when `m` was defined.
"""
function bodymethod(mkw::Method)
    Base.unwrap_unionall(mkw.sig).parameters[1] !== typeof(Core.kwcall) && isempty(Base.kwarg_decl(mkw)) && return mkw
    mths = methods(Base.bodyfunction(mkw))
    if length(mths) != 1
        @show mkw
        display(mths)
    end
    return only(mths)
end
