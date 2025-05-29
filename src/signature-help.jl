using .JS
using .JL

function make_paraminfo(p::JL.SyntaxTree)
    # A parameter's `label` is either a string the client searches for, or
    # an inclusive-exclusive range within in the signature.
    srcloc = (x::JL.SyntaxTree) -> let r = JS.byte_range(x);
        [UInt(r.start-1), UInt(r.stop)]
    end

    # defaults: whole parameter expression
    label = srcloc(p)
    documentation = string(JS.sourcetext(p))

    if JS.is_leaf(p)
        documentation = nothing
    elseif kind(p) === K"="
        @assert JS.numchildren(p) === 2
        label = kwname(p, #=msig=#true) # TODO kwname should return syntaxtree
    elseif kind(p) === K"::"
        if JS.numchildren(p) === 1
            documentation = "(unused) " * documentation
        else
            @assert JS.numchildren(p) === 2
            label = srcloc(p[1])
        end
    elseif kind(p) === K"..."
        label = make_paraminfo(p[1]).label
    end
    # do clients tolerate string labels better?
    # if !isa(label, String)
    #     label = string(p.source.file[label[1]:label[2]])
    # end
    return ParameterInformation(; label, documentation)
end

"""
Return (args, first_kwarg_i), one SyntaxTree per argument to call.  Ignore function
name and K"error" (e.g. missing closing paren)
"""
function flatten_call_args(call::JL.SyntaxTree)
    if kind(call) === K"where"
        return flatten_call_args(call[1])
    end
    @assert kind(call) === K"call" || kind(call) === K"dotcall"
    usable = (arg::JL.SyntaxTree) -> (kind(arg) != K"parameters" && kind(arg) != K"error")
    args_lhs = filter(usable, JS.children(call)[2:end])
    args_rhs = kind(call[end]) === K"parameters" ?
        filter(usable, JS.children(call[end])) : JL.SyntaxTree[]
    return vcat(args_lhs, args_rhs), length(args_lhs) + 1
end

# a, (= a 1), (= (:: a T) 1)
function kwname(a::JL.SyntaxTree, msig=false)
    if kind(a) === K"Identifier"
        return a.name_val
    elseif kind(a) === K"=" && kind(a[1]) === K"Identifier"
        return a[1].name_val
    elseif msig && kind(a) === K"=" && kind(a[1]) === K"::" && kind(a[1][1]) === K"Identifier"
        return a[1][1].name_val
    end
    JETLS_DEV_MODE && (@info "Unknown kwarg form" a)
    return nothing
end

# False negatives are fine here;  false positives would hide signatures.
"""
Map kwname to position in `args`.  args[kw_i] and later are after the semicolon.
If `msig`, then K"=" before the semicolon should be interpreted as optional
positional args instead of kwargs.
"""
function find_kws(args::Vector{JL.SyntaxTree}, kw_i::Int, msig=false)
    out = Dict{String, Int}()
    for i in (msig ? (kw_i:lastindex(args)) : eachindex(args))
        (kind(args[i]) != K"=") && i < kw_i && continue
        n = kwname(args[i])
        if !isnothing(n)
            out[n] = i
        end
    end
    return out
end

function make_siginfo(m::Method, active_arg::Union{String, Int, Nothing})
    # methodshow prints "f(x::T) [unparseable stuff]"
    # parse the first part and put the remainder in documentation
    mstr = sprint(show, m)
    mnode = JS.parsestmt(JL.SyntaxTree, mstr; ignore_errors=true)[1]
    label, documentation = let b = JS.last_byte(mnode)
        mstr[1:b], string(strip(mstr[b+1:end]))
    end

    # We could show the full docs, but there isn't(?) a way to separate by
    # method (or resolve one at a time), and the user may have seen this already
    # in the completions UI.
    # documentation = MarkupContent(;
    #     kind = MarkupKind.Markdown,
    #     value = string(Base.Docs.doc(Base.Docs.Binding(m.var"module", m.name))))

    f_params, kw_i = flatten_call_args(mnode)
    activeParameter = if isnothing(active_arg)
        nothing
    elseif active_arg isa String
        kwmap = find_kws(f_params, kw_i, #=msig=#true)
        get(kwmap, active_arg, nothing) - 1 # TODO post-semicolon vararg
    elseif active_arg isa Int && active_arg >= kw_i
        # @assert
        nothing # TODO pre-semicolon vararg
    elseif active_arg isa Int
        active_arg - 1
    end
    @info "active param calculated:" active_arg activeParameter

    parameters = map(make_paraminfo, f_params)
    return SignatureInformation(; label, documentation, parameters, activeParameter)
end

"""
Return false if we can definitely rule out `f(args...|` from being a call to `m`
"""
function compatible_call(m::Method, args::Vector{JL.SyntaxTree}, used_kws, pos_map)
    # TODO: (later) This should use type information from args (which we already
    # have from m's params).  For now, just parse the method signature like we
    # do in make_siginfo.

    mstr = sprint(show, m)
    mnode = JS.parsestmt(JL.SyntaxTree, mstr; ignore_errors=true)[1]
    params, kw_i = flatten_call_args(mnode)
    has_kw_splat = kw_i <= length(params) &&
        length(params) >= 1 &&
        kind(params[end]) === K"..."
    kwp_map = find_kws(params, kw_i, #=msig=#true)

    (length(pos_map) >= kw_i) && return false
    !has_kw_splat && !(keys(used_kws) ⊆ keys(kwp_map)) && return false
    return true
end

"""
Resolve a name's value given a root module and an expression like `M1.M2.M3.f`,
which parses to `(. (. (. M1 M2) M3) f)`.  If we hit something undefined, return
nothing.  This doesn't support some cases, e.g. `(print("hi"); Base).print`
"""
function resolve_property(mod::Module, rhs::JL.SyntaxTree)
    if JS.is_leaf(rhs)
        # Would otherwise throw an unhelpful error.  Is this true of all leaf nodes?
        @assert JL.hasattr(rhs, :name_val)
        s = Symbol(rhs.name_val)
        !isdefined(mod, s) && return nothing
        return getproperty(mod, s)
    elseif kind(rhs) === K"."
        @assert JS.numchildren(rhs) === 2
        lhs = resolve_property(mod, rhs[1])
        return resolve_property(lhs, rhs[2])
    elseif JETLS_DEV_MODE
        @info "resolve_property couldn't handle form:" mod rhs
    end
end

function get_siginfos(s::ServerState, msg::SignatureHelpRequest)
    uri = URI(msg.params.textDocument.uri)
    fi = get_fileinfo(s, uri)
    mod = find_file_module!(s, uri, msg.params.position)
    b = xy_to_offset(fi, msg.params.position)
    out = SignatureInformation[]

    call = let st0 = JS.build_tree(JL.SyntaxTree, fi.parsed_stream; ignore_errors=true)
        bas = byte_ancestors(st0, b)
        i = findfirst(st -> JS.kind(st) === K"call", bas)
        i === nothing && return out
        bas[i]
    end
    # TODO: dotcall support
    JS.numchildren(call) === 0 && return out

    # TODO: We could be calling a local variable.  If it shadows a method, our
    # ignoring it is misleading.  We need to either know about local variables
    # in this scope (maybe by caching completion info) or duplicate some work.
    fn = resolve_property(mod, call[1])
    !isa(fn, Function) && return out

    args, kw_i = flatten_call_args(call)
    @info "flatten_call_args" args kw_i

    pos_map = Int[] # which positional arg => position in `args`
    for i in eachindex(args[1:kw_i-1])
        if kind(args[i]) === K"..."
            break # don't know beyond here
        elseif kind(args[i]) === K"="
            continue
        else
            push!(pos_map, i)
        end
    end

    # we don't keep commas---do we want the green node here?
    active_arg = let i = findfirst(a -> JS.byte_range(a).stop + 1 >= b, args)
        if isnothing(i) || kind(args[i]) === K"..."
            nothing
        elseif kind(args[i]) === K"=" || i >= kw_i
            kwname(args[i])
        elseif i in pos_map
            findfirst(x -> x === i, pos_map)
        else
            JETLS_DEV_MODE && (@info "No active arg" i args[i] call)
            nothing
        end
    end

    used_kws = find_kws(args, kw_i)

    for m in methods(fn)
        if compatible_call(m, args, used_kws, pos_map)
            # TODO: don't suggest signature we are currently editing
            push!(out, make_siginfo(m, active_arg))
        end
    end
    return out
end

"""
textDocument/signatureHelp is requested when one of the negotiated trigger
characters is typed.  Eglot (emacs) requests it more frequently.
"""
function handle_SignatureHelpRequest(s::ServerState, msg::SignatureHelpRequest)
    signatures = get_siginfos(s, msg)
    activeSignature = 0
    activeParameter = nothing
    return s.send(
        ResponseMessage(;
            id = msg.id,
            result = isempty(signatures) ?
              null
            : SignatureHelp(;
                  signatures,
                  activeSignature,
                  activeParameter)))
end
