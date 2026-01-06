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
#     id = SIGNATURE_HELP_REGISTRATION_ID,
#     method = SIGNATURE_HELP_REGISTRATION_METHOD))
# register(currently_running, signature_help_registration())

# utils
# =====

"""
    flatten_args(call::JL.SyntaxTree) -> (args::JL.SyntaxList, first_kwarg_i::Int, has_semicolon::Bool)

Return `(args::JL.SyntaxList, first_kwarg_i::Int, has_semicolon::Bool)`,
one `SyntaxTree` per argument to call.
Ignore function name and `K"error"` (e.g. missing closing paren).
`has_semicolon` is true if the call contains a `K"parameters"` node (explicit semicolon).
"""
function flatten_args(call::JL.SyntaxTree)
    if kind(call) === K"where"
        return flatten_args(call[1])
    end
    if !(kind(call) in CALL_KINDS)
        println(stderr, JL.sourcetext(call))
        error(lazy"Unexpected call kind: $(kind(call))")
    end
    usable = (arg::JL.SyntaxTree) -> kind(arg) != K"error"
    orig = filter(usable, JS.children(call)[2:end])

    args = JL.SyntaxList(orig.graph)
    kw_i = 1
    has_semicolon = false
    for i in eachindex(orig)
        iskw = kind(orig[i]) === K"parameters"
        if !iskw
            push!(args, orig[i])
            kw_i += 1
        elseif i == lastindex(orig) && iskw
            has_semicolon = true
            for p in filter(usable, JS.children(orig[i]))
                push!(args, p)
            end
        end
    end
    return args, kw_i, has_semicolon
end

"""
Get K"Identifier" tree from a kwarg tree (child of K"call" or K"parameters").
`sig`: treat this as a signature rather than a call
               a => a
         (= a 1) => a
        (kw a 1) => a
  (= (:: a T) 1) => a  # only when sig=true
 (kw (:: a T) 1) => a  # only when sig=true
"""
function extract_kwarg_name(a::JL.SyntaxTree; sig::Bool=false)
    ret = identitifier_like(a)
    isnothing(ret) || return ret
    if kind(a) === K"=" || kind(a) === K"kw"
        a1 = a[1]
        ret = identitifier_like(a1)
        isnothing(ret) || return ret
        if sig && kind(a1) === K"::"
            ret = identitifier_like(a1[1])
            isnothing(ret) || return ret
        end
    elseif kind(a) === K"..."
        return nothing
    end
    JETLS_DEBUG_LOWERING && @info "Unknown kwarg form" a
    return nothing
end

function identitifier_like(st::JL.SyntaxTree)
    if kind(st) === K"Identifier"
        return st
    elseif kind(st) === K"var"
        inner = st[1]
        if kind(inner) === K"Identifier"
            return inner
        end
    end
    return nothing
end

"""
Best-effort mapping of kwname to position in `args`.  `args[kw_i]` and later are
after the semicolon.  False negatives are fine here; false positives would hide
signatures.

If `sig`, then `=`/`kw` trees before the semicolon should be interpreted as
optional positional args instead of kwargs.

Keywords should be ignored if `cursor` is within the keyword's name.

Note: the `=` form doesn't always correspond to a keyword arg after macro
expansion, but signature help is only used on unexpanded code.
"""
function find_kws(args::JL.SyntaxList, kw_i::Int; sig=false, cursor::Int=-1)
    out = Dict{String, Int}()
    for i in (sig ? (kw_i:lastindex(args)) : eachindex(args))
        kind(args[i]) ∉ JS.KSet"= kw" && i < kw_i && continue
        n = extract_kwarg_name(args[i]; sig)
        if !isnothing(n) && !(JS.first_byte(n) <= cursor <= JS.last_byte(n) + 1)
            out[n.name_val] = i
        end
    end
    return out
end

"""
    CallArgs

Information from a call site's arguments for filtering method signatures.
- `args`: Every valid child of the `K"call"` and its `K"parameters"` if present
- `kw_i`: Index where `K"parameters"` (semicolon) args begin; `length(args)+1` if no semicolon
- `pos_map`: Map from index in `args` to `(min, max)` possible positional arg index.
             `K"=" K"kw"` forms are excluded. `max` is `nothing` when a splat precedes.
             e.g. `f(a, k=1, b..., c)` -> `{1 => (1, 1), 3 => (2, nothing), 4 => (2, nothing)}`
- `pos_args_lb`: Number of definite positional args (excludes splats)
- `pos_args_ub`: Upper bound on positional args; `nothing` if splat is present
- `kw_map`: kwname => index in `args`. Excludes any WIP kw (see `find_kws`)
- `has_semicolon`: whether the call contains an explicit semicolon (`K"parameters"`)
- `kind`: Item in `CALL_KINDS`
"""
struct CallArgs
    args::JL.SyntaxList
    kw_i::Int
    pos_map::Dict{Int, Tuple{Int, Union{Int, Nothing}}}
    pos_args_lb::Int
    pos_args_ub::Union{Int, Nothing}
    kw_map::Dict{String, Int}
    has_semicolon::Bool
    kind::JS.Kind
    function CallArgs(st0::JL.SyntaxTree, cursor::Int=-1)
        @assert -1 ∉ JS.byte_range(st0)
        args, kw_i, has_semicolon = flatten_args(st0)
        pos_map = Dict{Int, Tuple{Int, Union{Int, Nothing}}}()
        lb = 0; ub = 0
        for i in eachindex(args[1:kw_i-1])
            if kind(args[i]) === K"..."
                ub = nothing
                pos_map[i] = (lb + 1, ub)
            elseif kind(args[i]) ∉ JS.KSet"= kw"
                lb += 1
                !isnothing(ub) && (ub += 1)
                pos_map[i] = (lb, ub)
            end
        end
        kw_map = find_kws(args, kw_i; sig=false, cursor)
        new(args, kw_i, pos_map, lb, ub, kw_map, has_semicolon, kind(st0))
    end
end

"""
    compatible_method(m::Method, ca::CallArgs) -> Bool

Return `false` if we can definitely rule out `f(args...|` from being a call to `m`.

This is an analysis based on the number of arguments and keyword names, and fundamentally
the type-based filtering performed by `find_all_matches` is generally more accurate.
However, especially in cases involving splats like `func(xs...,1,2,3|)`, when `find_all_matches`
cannot analyze the type of `xs`, it cannot perform effective method filtering, whereas
this method can filter out candidates like `func(::Int,::Int)` using the information after
the splat (`1,2,3`), making it beneficial in some cases.
"""
function compatible_method(m::Method, ca::CallArgs)
    msig = @something get_sig_str(m, ca) return false
    mnode = JS.parsestmt(JL.SyntaxTree, msig; ignore_errors=true)

    params, kwp_i, _ = flatten_args(mnode)
    has_var_params = kwp_i > 1 && kind(params[kwp_i - 1]) === K"..."
    has_var_kwp = kwp_i <= length(params) && kind(params[end]) === K"..."

    kwp_map = find_kws(params, kwp_i; sig=true)

    !has_var_params && (ca.pos_args_lb >= kwp_i) && return false
    !has_var_kwp && (keys(ca.kw_map) ⊈ keys(kwp_map)) && return false
    if ca.has_semicolon
        # Filter out methods where user hasn't provided enough positional args
        # e.g., g(42;│) should not match g(x, y) which requires 2 positional args
        if !has_var_params
            required_pos_args = count(i::Int->kind(params[i]) ∉ JS.KSet"= kw ...", 1:kwp_i-1)
            !isnothing(ca.pos_args_ub) && ca.pos_args_ub < required_pos_args && return false
        end
    end
    return true
end

const keyword_matchers = let
    keyword_syms = [
        :baremodule, :begin, :break, :catch, :ccall, :const, :continue, :do, :else, :elseif,
        :end, :export, :var"false", :finally, :for, :function, :global, :if, :import,
        :let, :local, :macro, :module, :public, :quote, :return, :struct, :var"true",
        :try, :using, :while]
    map(keyword_syms) do kw::Symbol
        kws = String(kw)
        kws => Regex("\\b" * kws * "\\b" * "((?:::[^,)]*)?,?)") => SubstitutionString("var\"$kws\"\\1")
    end
end

# TODO: (later) This should use type information from args (which we already
# have from m's params).  For now, just parse the method signature like we
# do in make_siginfo.
function get_sig_str(m::Method, ca::CallArgs)
    @static if VERSION ≥ v"1.13.0-DEV.710"
        msig = sprint(show, m; context=(:compact=>true, :print_method_signature_only=>true))
    else
        # methodshow prints "f(x::T) [unparseable stuff]"
        # parse the first part and put the remainder in documentation
        mstr = sprint(show, m; context=(:compact=>true))
        msig_locinfo = split(mstr, " @ ")
        length(msig_locinfo) == 2 || return nothing
        msig = strip(msig_locinfo[1])
    end
    @static if VERSION < v"1.13.0-DEV.5"
        # HACK: Use JuliaLang/julia#57268 for v1.12. Delete me.
        for (_, rep) in keyword_matchers
            msig = replace(msig, rep)
        end
    end
    if ca.kind === K"macrocall" # hack. TODO delete
        msig = replace(msig, "__source__::LineNumberNode, __module__::Module, "=>"",
                       "__source__::LineNumberNode, __module__::Module"=>""; count=1)
    end
    return msig
end

# LSP objects and handler
# =======================

function make_paraminfo(
        param::JL.SyntaxTree, active_argtree::Union{Nothing,JL.SyntaxTree},
        @nospecialize(active_argtype), postprocessor::LSPostProcessor
    )
    label = let r = JS.byte_range(param)
        UInt[UInt(r.start-1), UInt(r.stop)]
    end
    docs = backtick(JS.sourcetext(param))
    if !isnothing(active_argtree)
        argrepr = JS.sourcetext(active_argtree)
        if !isnothing(active_argtype)
            argrepr = string('(', argrepr, ')', " :: ", postprocessor(string(active_argtype)))
        end
        docs *= " ← " * backtick(argrepr)
    end
    documentation = MarkupContent(;
        kind = MarkupKind.Markdown,
        value = docs)
    # do clients tolerate string labels better?
    # if !isa(label, String)
    #     label = string(p.source.file[label[1]+1:label[2]])
    # end
    return ParameterInformation(; label, documentation)
end

# active_arg is either an argument index, or :next (available pos. arg), or :none
function make_siginfo(
        m::Method, ca::CallArgs, active_arg::Union{Nothing,Bool,Int}, argtypes::Vector{Any};
        postprocessor::LSPostProcessor = LSPostProcessor()
    )
    msig = @something get_sig_str(m, ca)
    msig = postprocessor(msig)
    mnode = JS.parsestmt(JL.SyntaxTree, msig; ignore_errors=true)
    label = String(msig)
    documentation = let
        mdl = postprocessor(string(Base.parentmodule(m)))
        file, line = Base.updated_methodloc(m)
        filename = to_full_path(file)
        MarkupContent(;
            kind = MarkupKind.Markdown,
            value = "@ `$(mdl)` " * create_source_location_link(filename2uri(filename); line))
    end

    # We could show the full docs, but there isn't a way to resolve items lazily
    # like completions, so we might be sending many copies.  The user may have
    # seen this already in the completions UI, too.
    # documentation = MarkupContent(;
    #     kind = MarkupKind.Markdown,
    #     value = string(Base.Docs.doc(Base.Docs.Binding(m.var"module", m.name))))

    params, kwp_i, _ = flatten_args(mnode)
    maybe_var_params = kwp_i > 1 && kind(params[kwp_i - 1]) === K"..." ?
        kwp_i - 1 : nothing
    maybe_var_kwp = kwp_i <= length(params) && kind(params[end]) === K"..." ?
        lastindex(params) : nothing
    kwp_map = find_kws(params, kwp_i; sig=true)

    # Map active arg to active param, or nothing
    activeParameter =
        if active_arg === nothing # none
            nothing
        elseif active_arg isa Bool # next arg if able
            if active_arg # After semicolon
                # Find the first keyword parameter not in the given keyword argument list;
                # fallback to variadic keyword parameter
                local active_kw = maybe_var_kwp
                rev_kwp_map = Pair{Int,String}[]
                for (kw, i) in kwp_map
                    push!(rev_kwp_map, i=>kw)
                end
                sort!(rev_kwp_map; by=first)
                for (i, kw) in rev_kwp_map
                    if kw ∉ keys(ca.kw_map)
                        active_kw = i
                        break
                    end
                end
                active_kw
            else
                # If the given positional argument list is larger than the positional parameter
                # list, then use the position of the last parameter position, which is likely a
                # vararg parameter, otherwise use the exact argument position.
                max(1, ca.kw_i ≥ kwp_i ? kwp_i-1 : ca.kw_i)
            end
        elseif active_arg in keys(ca.pos_map)
            lb, ub = get(ca.pos_map, active_arg, (1, nothing))
            if !isnothing(maybe_var_params) && lb >= maybe_var_params
                maybe_var_params
            else
                lb == ub ? lb : nothing
            end
        elseif kind(ca.args[active_arg]) === K"..."
            # splat after semicolon
            maybe_var_kwp
        elseif kind(ca.args[active_arg]) in JS.KSet"= kw" || active_arg >= ca.kw_i
            n = extract_kwarg_name(ca.args[active_arg]).name_val # we don't have a backwards mapping
            out = get(kwp_map, n, nothing)
            isnothing(out) ? maybe_var_kwp : out
        else
            JETLS_DEBUG_LOWERING && @info "No active arg" active_arg ca.args[active_arg]
            nothing
        end

    parameters = ParameterInformation[]
    for (i, param) in enumerate(params)
        isactive = !isnothing(activeParameter) && activeParameter == i
        active_argtree = isactive && checkbounds(Bool, ca.args, activeParameter) ? ca.args[activeParameter] : nothing
        active_argtype = isactive && checkbounds(Bool, argtypes, activeParameter) ? argtypes[activeParameter] : nothing
        push!(parameters, make_paraminfo(param, active_argtree, active_argtype, postprocessor))
    end
    isnothing(activeParameter) || (activeParameter -= 1) # shift to 0-based
    return SignatureInformation(; label, documentation, parameters, activeParameter)
end

const empty_siginfos = SignatureInformation[]

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
        _bas[j - 1]._id == _bas[j][1]._id
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
    tc = token_before_offset(ps, b)
    if !isnothing(tc) && JS.kind(tc) === K"Comment"
        return nothing
    end

    let bas = byte_ancestors(st0, b),
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
    end

    # `i` is nothing.  Eat preceding whitespace and check again.
    let pnb = prev_nontrivia_byte(ps, b-1; pass_newlines=true)
        (isnothing(pnb) || pnb == b) && return nothing
        bas = byte_ancestors(st0, pnb)
        # If the previous nontrivia byte is part of a call or macrocall, and it is
        # missing a closing paren, use that.
        i = findfirst(st::JL.SyntaxTree -> is_relevant_call(st) && !noparen_macrocall(st), bas)
        if !isnothing(i)
            basᵢ = bas[i]
            if JS.is_error(JS.children(basᵢ)[end])
                return call_is_decl(bas, i, basᵢ) ? nothing : basᵢ
            end
        end
    end

    # If the previous nontrivia byte within this line is part of an
    # unparenthesized macrocall, use that.
    let pnb_line = prev_nontrivia_byte(ps, b-1; pass_newlines=false, strict=true)
        (isnothing(pnb_line) || pnb_line == b) && return nothing
        # Don't provide completion if the current position is within a newline token and crosses over that newline
        pnt_line = prev_nontrivia(ps, b-1; pass_newlines=false) # include the current token (`strict=false`)
        if !isnothing(pnt_line) && any(==(UInt8('\n')), @view ps.textbuf[JS.first_byte(pnt_line):b-1])
            return nothing
        end
        bas = byte_ancestors(st0, pnb_line)
        i = findfirst(noparen_macrocall, bas)
        return isnothing(i) ? nothing : bas[i]
    end
end

"""
    collect_call_argtypes(analyzer::LSAnalyzer, mod::Module, ca::CallArgs) -> argtypes::Vector{Any}

Infer the types of positional arguments contained in `ca` and return them as `argtypes::Vector{Any}`.
Note that neither `ca` nor `argtypes` include the type of the function object itself.
Also note that this function resolves the type of each argument in `ca` in the global scope,
completely ignoring information arising from the local scope in which it is contained.

In the future, with the integration of `JL.SyntaxTree` and the full-analysis,
this method should be replaced with a query to a cached typed-`JL.SyntaxTree`.
"""
function collect_call_argtypes(analyzer::LSAnalyzer, mod::Module, ca::CallArgs)
    argtypes = Any[]
    for i in sort!(collect(keys(ca.pos_map)))
        arg = ca.args[i]
        if JS.kind(arg) === JS.K"..."
            # This is a very crude and poor modeling of `abstract_apply`, and is also
            # too conservative than necessary.
            # This implementation that imperfectly mimics the infernece behavior should be
            # discarded, and instead the type of this splat argument should be extracted
            # as a query to the Typed-AST.
            arg = Expr(:tuple, Expr(arg))
            argtype = CC.widenconst(@something resolve_type(analyzer, mod, arg) @goto bailout)
            argtype isa DataType || @goto bailout
            argtype.name === Tuple.name || @goto bailout
            any(Base.isvarargtype, argtype.parameters) && @goto bailout
            for i = 1:length(argtype.parameters)
                push!(argtypes, argtype.parameters[i])
            end
        else
            push!(argtypes, CC.widenconst(@something resolve_type(analyzer, mod, arg) Any))
        end
    end
    if !ca.has_semicolon
        @label bailout
        push!(argtypes, Vararg{Any})
    end
    return argtypes
end

function fixup_argtypes!(argtypes::Vector{Any}, @nospecialize(fntyp))
    if fntyp isa Core.Const
        fn = fntyp.val
        if fn isa Function && startswith(String(nameof(fn)), '@')
            pushfirst!(argtypes, LineNumberNode, Module) # TODO The new style macro?
        end
    end
    pushfirst!(argtypes, CC.widenconst(fntyp))
    return argtypes
end

function find_all_matches(
        argtypes::Vector{Any};
        world::UInt = Base.get_world_counter(),
        limit::Int = -1
    )
    atype = Tuple{argtypes...}
    return CC._findall(atype, nothing, world, limit)
end

function cursor_siginfos(mod::Module, fi::FileInfo, b::Int, analyzer::LSAnalyzer;
                         postprocessor::LSPostProcessor=LSPostProcessor())
    st0 = build_syntax_tree(fi)
    call = cursor_call(fi.parsed_stream, st0, b)
    isnothing(call) && return empty_siginfos
    after_semicolon = let
        params_i = findfirst(st::JL.SyntaxTree -> kind(st) === K"parameters", JS.children(call))
        !isnothing(params_i) && b > JS.first_byte(call[params_i])
    end

    # TODO: We could be calling a local variable.  If it shadows a method, our
    # ignoring it is misleading.  We need to either know about local variables
    # in this scope (maybe by caching completion info) or duplicate some work.
    fntyp = @something resolve_type(analyzer, mod, call[1]) return empty_siginfos

    ca = CallArgs(call, b)

    argtypes = collect_call_argtypes(analyzer, mod, ca)
    argtypes′ = copy(argtypes)
    fixup_argtypes!(argtypes, fntyp)
    matches = find_all_matches(argtypes)
    isempty(matches) && return empty_siginfos

    # Influence parameter highlighting by selecting the active argument (which
    # may be mapped to a parameter in make_siginfo).  If cursor is after all
    # pos. args and not after semicolon, ask for the next param, which may not
    # exist.  Otherwise, highlight the param for the arg we're in.
    #
    # We don't keep commas---do we want the green node here?
    no_args = ca.kw_i == 1
    past_pos_args = no_args || b > JS.last_byte(ca.args[ca.kw_i - 1]) + 1
    if past_pos_args && !after_semicolon
        active_arg = false # before semicolon, highlight next positional arg
    else
        active_arg = findfirst(a::JL.SyntaxTree -> JS.first_byte(a) <= b <= JS.last_byte(a) + 1, ca.args)
        if active_arg === nothing && after_semicolon
            active_arg = true # after semicolon, highlight next keyword arg
        end
    end

    out = SignatureInformation[]
    for match in matches
        m = match.method
        compatible_method(m, ca) || continue
        siginfo = make_siginfo(m, ca, active_arg, argtypes′; postprocessor)
        if siginfo !== nothing
            push!(out, siginfo)
        end
    end
    return out
end

"""
`textDocument/signatureHelp` is requested when one of the negotiated trigger characters is typed.
Some clients, e.g. Eglot (emacs), requests it more frequently.
"""
function handle_SignatureHelpRequest(
        server::Server, msg::SignatureHelpRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    result = get_file_info(state, uri, cancel_flag)
    if result isa ResponseError
        return send(server,
            SignatureHelpResponse(;
                id = msg.id,
                result = nothing,
                error = result))
    end
    fi = result
    pos = adjust_position(state, uri, msg.params.position)
    (; mod, analyzer, postprocessor) = get_context_info(state, uri, pos)
    b = xy_to_offset(fi, pos)
    signatures = cursor_siginfos(mod, fi, b, analyzer; postprocessor)
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
