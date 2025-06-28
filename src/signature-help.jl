using .JS
using .JL

# initialization
# ==============

signature_help_options() = SignatureHelpOptions(;
    triggerCharacters = ["(", ",", ";", "\"", "=", " "],
    retriggerCharacters = ["."])

const SIGNATURE_HELP_REGISTRATION_ID = "jetls-signature-help"
const SIGNATURE_HELP_REGISTRATION_METHOD = "textDocument/signatureHelp"
const CALL_KINDS = JS.KSet"call macrocall dotcall"

function signature_help_registration()
    (; triggerCharacters, retriggerCharacters) = signature_help_options()
    return Registration(;
        id = SIGNATURE_HELP_REGISTRATION_ID,
        method = SIGNATURE_HELP_REGISTRATION_METHOD,
        registerOptions = SignatureHelpRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            triggerCharacters,
            retriggerCharacters))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id=SIGNATURE_HELP_REGISTRATION_ID,
#     method=SIGNATURE_HELP_REGISTRATION_METHOD))
# register(currently_running, signature_help_registration())

# utils
# =====

"""
Return (args, first_kwarg_i), one SyntaxTree per argument to call.  Ignore function
name and K"error" (e.g. missing closing paren)
"""
function flatten_args(call::JL.SyntaxTree)
    if kind(call) === K"where"
        return flatten_args(call[1])
    end
    @assert kind(call) in CALL_KINDS
    usable = (arg::JL.SyntaxTree) -> kind(arg) != K"error"
    orig = filter(usable, JS.children(call)[2:end])

    args = JL.SyntaxList(orig.graph)
    kw_i = 1
    for i in eachindex(orig)
        iskw = kind(orig[i]) === K"parameters"
        if !iskw
            push!(args, orig[i])
            kw_i += 1
        elseif i === lastindex(orig) && iskw
            for p in filter(usable, JS.children(orig[i]))
                push!(args, p)
            end
        end
    end
    return args, kw_i
end

"""
Get K"Identifier" tree from a kwarg tree (child of K"call" or K"parameters").
`sig`: treat this as a signature rather than a call
               a => a
         (= a 1) => a
  (= (:: a T) 1) => a  # only when sig=true
"""
function kwname(a::JL.SyntaxTree; sig=false)
    if kind(a) === K"Identifier"
        return a
    elseif kind(a) === K"=" && kind(a[1]) === K"Identifier"
        return a[1]
    elseif sig && kind(a) === K"=" && kind(a[1]) === K"::" && kind(a[1][1]) === K"Identifier"
        return a[1][1]
    elseif kind(a) === K"..."
        return nothing
    end
    JETLS_DEV_MODE && @info "Unknown kwarg form" a
    return nothing
end

"""
Best-effort mapping of kwname to position in `args`.  args[kw_i] and later are
after the semicolon.  False negatives are fine here; false positives would hide
signatures.

If `sig`, then K"=" trees before the semicolon should be interpreted as optional
positional args instead of kwargs.

Keywords should be ignored if `cursor` is within the keyword's name.
"""
function find_kws(args::JL.SyntaxList, kw_i::Int; sig=false, cursor::Int=-1)
    out = Dict{String, Int}()
    for i in (sig ? (kw_i:lastindex(args)) : eachindex(args))
        (kind(args[i]) != K"=") && i < kw_i && continue
        n = kwname(args[i]; sig)
        if !isnothing(n) && !(JS.first_byte(n) <= cursor <= JS.last_byte(n) + 1)
            out[n.name_val] = i
        end
    end
    return out
end

"""
Information from one call's arguments for filtering signatures.
- args: Every valid child of the K"call" and its K"parameters" if present
- kw_i: One plus the number of args not in K"parameters" (semicolon)
- pos_map: Map from position in `args` to (min, max) possible positional arg
           e.g. f(a, k=1, b..., c)
                 --> a => (1, 1), b => (2, nothing), c => (2, nothing)
- pos_args_*: lower and upper bounds on # of positional args
- kw_map: kwname => position in `args`.  Excludes any WIP kw (see find_kws)
- kind: Item in `CALL_KINDS`

TODO: types
"""
struct CallArgs
    args::JL.SyntaxList
    kw_i::Int
    pos_map::Dict{Int, Tuple{Int, Union{Int, Nothing}}}
    pos_args_lb::Int
    pos_args_ub::Union{Int, Nothing}
    kw_map::Dict{String, Int}
    kind::JS.Kind
end

function CallArgs(st0::JL.SyntaxTree, cursor::Int)
    @assert !(-1 in JS.byte_range(st0))
    args, kw_i = flatten_args(st0)
    pos_map = Dict{Int, Tuple{Int, Union{Int, Nothing}}}()
    lb = 0; ub = 0
    for i in eachindex(args[1:kw_i-1])
        if kind(args[i]) === K"..."
            ub = nothing
            pos_map[i] = (lb + 1, ub)
        elseif kind(args[i]) != K"="
            lb += 1
            !isnothing(ub) && (ub += 1)
            pos_map[i] = (lb, ub)
        end
    end
    kw_map = find_kws(args, kw_i; sig=false, cursor)
    CallArgs(args, kw_i, pos_map, lb, ub, kw_map, kind(st0))
end

"""
Return false if we can definitely rule out `f(args...|` from being a call to `m`
"""
function compatible_method(m::Method, ca::CallArgs)
    # TODO: (later) This should use type information from args (which we already
    # have from m's params).  For now, just parse the method signature like we
    # do in make_siginfo.

    @static if VERSION ≥ v"1.13.0-DEV.710"
        msig = sprint(show, m; context=(:compact=>true, :print_method_signature_only=>true))
    else
        mstr = sprint(show, m; context=(:compact=>true))
        msig_locinfo = split(mstr, " @ ")
        length(msig_locinfo) == 2 || return false
        msig = strip(msig_locinfo[1])
    end
    if ca.kind === K"macrocall" # hack. TODO delete
        msig = replace(msig, "__source__::LineNumberNode, __module__::Module, "=>"",
                       "__source__::LineNumberNode, __module__::Module"=>""; count=1)
    end
    mnode = JS.parsestmt(JL.SyntaxTree, msig; ignore_errors=true)

    params, kwp_i = flatten_args(mnode)
    has_var_params = kwp_i > 1 && kind(params[kwp_i - 1]) === K"..."
    has_var_kwp = kwp_i <= length(params) && kind(params[end]) === K"..."

    kwp_map = find_kws(params, kwp_i; sig=true)

    !has_var_params && (ca.pos_args_lb >= kwp_i) && return false
    !has_var_kwp && !(keys(ca.kw_map) ⊆ keys(kwp_map)) && return false
    return true
end

# LSP objects and handler
# =======================

function make_paraminfo(p::JL.SyntaxTree)
    # A parameter's `label` is either a string the client searches for, or
    # an inclusive-exclusive range within in the signature.
    srcloc = (x::JL.SyntaxTree) -> let r = JS.byte_range(x);
        [UInt(r.start-1), UInt(r.stop)]
    end

    # defaults: whole parameter expression
    label = srcloc(p)
    documentation = string('`', JS.sourcetext(p), '`')

    if JS.is_leaf(p)
        documentation = nothing
    elseif kind(p) === K"="
        @assert JS.numchildren(p) === 2
        label = kwname(p; sig=true).name_val
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
    #     label = string(p.source.file[label[1]+1:label[2]])
    # end
    if documentation !== nothing
        documentation = MarkupContent(;
            kind = MarkupKind.Markdown,
            value = documentation)
    end
    return ParameterInformation(; label, documentation)
end

# active_arg is either an argument index, or :next (available pos. arg), or :none
function make_siginfo(m::Method, ca::CallArgs, active_arg::Union{Int, Symbol};
                      postprocessor::JET.PostProcessor=JET.PostProcessor())
    # methodshow prints "f(x::T) [unparseable stuff]"
    # parse the first part and put the remainder in documentation
    @static if VERSION ≥ v"1.13.0-DEV.710"
        msig = sprint(show, m; context=(:compact=>true, :print_method_signature_only=>true))
    else
        mstr = sprint(show, m; context=(:compact=>true))
        msig_locinfo = split(mstr, " @ ")
        length(msig_locinfo) == 2 || return false
        msig = strip(msig_locinfo[1])
    end
    if ca.kind === K"macrocall"
        msig = replace(msig, "__source__::LineNumberNode, __module__::Module, "=>"",
                       "__source__::LineNumberNode, __module__::Module"=>""; count=1)
    end
    msig = postprocessor(msig)
    mnode = JS.parsestmt(JL.SyntaxTree, msig; ignore_errors=true)
    label = String(msig)
    documentation = let
        mdl = postprocessor(string(Base.parentmodule(m)))
        file, line = Base.updated_methodloc(m)
        filepath = to_full_path(file)
        MarkupContent(;
            kind = MarkupKind.Markdown,
            value = "@ `$(mdl)` " * create_source_location_link(filepath; line))
    end

    # We could show the full docs, but there isn't a way to resolve items lazily
    # like completions, so we might be sending many copies.  The user may have
    # seen this already in the completions UI, too.
    # documentation = MarkupContent(;
    #     kind = MarkupKind.Markdown,
    #     value = string(Base.Docs.doc(Base.Docs.Binding(m.var"module", m.name))))

    params, kwp_i = flatten_args(mnode)
    maybe_var_params = kwp_i > 1 && kind(params[kwp_i - 1]) === K"..." ?
        kwp_i - 1 : nothing
    maybe_var_kwp = kwp_i <= length(params) && kind(params[end]) === K"..." ?
        lastindex(params) : nothing
    kwp_map = find_kws(params, kwp_i; sig=true)

    # Map active arg to active param, or nothing
    activeParameter = let i = active_arg
        if i === :none
            nothing
        elseif i === :next # next pos arg if able
            kwp_i > ca.kw_i ? ca.kw_i : nothing
        elseif i in keys(ca.pos_map)
            lb, ub = get(ca.pos_map, i, (1, nothing))
            if !isnothing(maybe_var_params) && lb >= maybe_var_params
                maybe_var_params
            else
                lb === ub ? lb : nothing
            end
        elseif kind(ca.args[i]) === K"..."
            # splat after semicolon
            maybe_var_kwp
        elseif kind(ca.args[i]) === K"=" || i >= ca.kw_i
            n = kwname(ca.args[i]).name_val # we don't have a backwards mapping
            out = get(kwp_map, n, nothing)
            isnothing(out) ? maybe_var_kwp : out
        else
            JETLS_DEV_MODE && @info "No active arg" i ca.args[i]
            nothing
        end
    end

    !isnothing(activeParameter) && (activeParameter -= 1) # shift to 0-based
    parameters = map(make_paraminfo, params)
    return SignatureInformation(; label, documentation, parameters, activeParameter)
end

const empty_siginfos = SignatureInformation[]

"""
Return the last byte at or before `b` that isn't in whitespace or a comment (or
if `pass_newlines=false`, also isn't a newline).
"""
function prev_nontrivia_byte(ps::JS.ParseStream, b::Int; pass_newlines=false)
    ti = get_current_token_idx(ps, min(JS.last_byte(ps), b))
    isnothing(ti) && return nothing
    skip = (i::Int) -> let tok = ps.tokens[i]; k = kind(tok)
        b < tok.next_byte || JS.is_whitespace(k) && (pass_newlines || k != K"NewlineWs")
    end
    while skip(ti)
        ti -= 1
        ti < 1 && return nothing
    end
    return ps.tokens[ti].next_byte - 1
end

function is_relevant_call(call::JL.SyntaxTree)
    kind(call) in CALL_KINDS &&
        # don't show help for a+b, M', etc., where call[1] isn't the function
        !(JS.is_infix_op_call(call) || JS.is_postfix_op_call(call))
end

# If parents of our call are like (macro/function (where (where... (call |) ...))),
# we're actually in a declaration, and shouldn't show signature help.
function call_is_decl(_bas::JL.SyntaxList, i::Int, _basᵢ::JL.SyntaxTree = _bas[i])
    kind(_basᵢ) != JS.K"call" && return false
    j = i + 1
    while j <= lastindex(_bas) && kind(_bas[j]) === JS.K"where"
        j += 1
    end
    return j <= lastindex(_bas) &&
        kind(_bas[j]) in JS.KSet"macro function" &&
        # in `f(x) = g(x)`, return true in `f`, false in `g`
        _bas[j - 1] === _bas[j][1]
end

# Find cases where a macro call is not surrounded by parentheses
# and the current cursor position is on a different line from the `@` macro call
function is_crossline_noparen_macrocall(call::JL.SyntaxTree, cursor_byte::Int)
    return noparen_macrocall(call) && let source_file = JS.sourcefile(call)
        # Check if cursor is on a different line from the @ symbol
        JS.numchildren(call) ≥ 1 &&
            JS.source_line(source_file, JS.first_byte(call[1])) ≠ JS.source_line(source_file, cursor_byte)
    end
end

"""
Return the nearest call in `st0` containing cursor byte b (if any).

Some adjustment is done if there's trivia before the cursor in an unterminated
call expression, e.g. `foo(#=hi=# |`, `@bar |`.  A more accurate description
would be: return the nearest call in `st0` such that stuff inserted at the
cursor would be descendents of it.
"""
function cursor_call(ps::JS.ParseStream, st0::JL.SyntaxTree, b::Int)
    # disable signature help if invoked within comment scope
    prev_token_idx = get_prev_token_idx(ps, b)
    if !isnothing(prev_token_idx) && JS.kind(ps.tokens[prev_token_idx]) === K"Comment"
        return nothing
    end

    bas = byte_ancestors(st0, b)
    i = findfirst(is_relevant_call, bas)
    if !isnothing(i)
        basᵢ = bas[i]
        if call_is_decl(bas, i, basᵢ)
            return nothing
        elseif is_crossline_noparen_macrocall(basᵢ, b)
            # Consider cases like:
            # @testset begin
            #     ... | ...
            # end
            return nothing
        elseif any(j::Int->JS.kind(bas[j])===JS.K"do", 1:i)
            # bail out if this is actually within a `do` block
            return nothing
        end
        return basᵢ
    end

    # `i` is nothing.  Eat preceding whitespace and check again.
    pnb_line = prev_nontrivia_byte(ps, b; pass_newlines=false)
    pnb = prev_nontrivia_byte(ps, b; pass_newlines=true)

    (isnothing(pnb) || pnb === b) && return nothing
    bas = byte_ancestors(st0, pnb)
    # If the previous nontrivia byte is part of a call or macrocall, and it is
    # missing a closing paren, use that.
    i = findfirst(st -> is_relevant_call(st) && !noparen_macrocall(st), bas)
    if !isnothing(i)
        basᵢ = bas[i]
        if JS.is_error(JS.children(basᵢ)[end])
            return call_is_decl(bas, i, basᵢ) ? nothing : basᵢ
        end
    end

    (isnothing(pnb_line) || pnb_line === b) && return nothing
    bas = byte_ancestors(st0, pnb_line)
    # If the previous nontrivia byte within this line is part of an
    # unparenthesized macrocall, use that.
    i = findfirst(noparen_macrocall, bas)
    return isnothing(i) ? nothing : bas[i]
end

function cursor_siginfos(mod::Module, ps::JS.ParseStream, b::Int, analyzer::LSAnalyzer;
                         postprocessor::JET.PostProcessor=JET.PostProcessor())
    st0 = JS.build_tree(JL.SyntaxTree, ps; ignore_errors=true)
    call = cursor_call(ps, st0, b)
    isnothing(call) && return empty_siginfos
    after_semicolon = let
        params_i = findfirst(st -> kind(st) === K"parameters", JS.children(call))
        !isnothing(params_i) && b > JS.first_byte(call[params_i])
    end

    # TODO: We could be calling a local variable.  If it shadows a method, our
    # ignoring it is misleading.  We need to either know about local variables
    # in this scope (maybe by caching completion info) or duplicate some work.
    fntyp = resolve_type(analyzer, mod, call[1])
    fntyp isa Core.Const || return empty_siginfos
    fn = fntyp.val
    candidate_methods = methods(fn)
    isempty(candidate_methods) && return empty_siginfos

    ca = CallArgs(call, b)

    # Influence parameter highlighting by selecting the active argument (which
    # may be mapped to a parameter in make_siginfo).  If cursor is after all
    # pos. args and not after semicolon, ask for the next param, which may not
    # exist.  Otherwise, highlight the param for the arg we're in.
    #
    # We don't keep commas---do we want the green node here?
    active_arg = let no_args = ca.kw_i === 1,
        past_pos_args = no_args || b > JS.last_byte(ca.args[ca.kw_i - 1]) + 1
        if past_pos_args && !after_semicolon
            :next
        else
            arg_i = findfirst(a -> JS.first_byte(a) <= b <= JS.last_byte(a) + 1, ca.args)
            isnothing(arg_i) ? :none : arg_i
        end
    end

    out = SignatureInformation[]
    for m in candidate_methods
        if compatible_method(m, ca)
            siginfo = make_siginfo(m, ca, active_arg; postprocessor)
            if siginfo !== nothing
                push!(out, siginfo)
            end
        end
    end
    return out
end

"""
`textDocument/signatureHelp` is requested when one of the negotiated trigger characters is typed.
Some clients, e.g. Eglot (emacs), requests it more frequently.
"""
function handle_SignatureHelpRequest(server::Server, msg::SignatureHelpRequest)
    state = server.state
    uri = msg.params.textDocument.uri
    fi = get_fileinfo(state, uri)
    if fi === nothing
        return send(server,
            SignatureHelpResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end
    (; mod, analyzer, postprocessor) = get_context_info(state, uri, msg.params.position)
    b = xy_to_offset(fi, msg.params.position)
    signatures = cursor_siginfos(mod, fi.parsed_stream, b, analyzer; postprocessor)
    activeSignature = nothing
    activeParameter = nothing
    return send(server,
        SignatureHelpResponse(;
            id = msg.id,
            result = isempty(signatures) ?
              null
            : SignatureHelp(;
                  signatures,
                  activeSignature,
                  activeParameter)))
end
