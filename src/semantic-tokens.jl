# Semantic tokens feature implementation
#
# Semantic tokens augment the editor's built-in (tree-sitter / TextMate) syntax
# highlighting with information that requires semantic analysis. We deliberately
# emit only the kinds of tokens that the surface highlighter cannot produce on
# its own, namely identifier classifications derived from binding analysis:
# `parameter`, `typeParameter`, and `variable`. Keywords, operators, literals,
# comments, macros, etc. are left to the client's syntactic highlighter (which
# is enabled via the `augmentsSyntaxTokens` capability).
#
# The implementation reuses `binding_occurrences_cache` via `iterate_toplevel_tree`,
# i.e. the same path used by document-highlight / references for global lookups.

const SEMANTIC_TOKENS_REGISTRATION_ID = "jetls-semantic-tokens"
const SEMANTIC_TOKENS_REGISTRATION_METHOD = "textDocument/semanticTokens"

const SEMANTIC_TOKEN_TYPES = String[
    SemanticTokenTypes.parameter,
    SemanticTokenTypes.typeParameter,
    SemanticTokenTypes.variable,
    # Custom type for `:global` bindings whose concrete kind (function / type / module /
    # variable / ...) we don't resolve. Sending a type name that no theme rule matches keeps
    # the syntactic highlighter's color in place (under `augmentsSyntaxTokens = true`),
    # while modifiers like `definition` / `declaration` can still apply via `*.<modifier>` rules.
    # We may replace this with predefined types once the inferred tree cache lets us
    # classify global bindings precisely.
    "jetls.unspecified",
]

const SEMANTIC_TOKEN_TYPE_PARAMETER      = UInt(0)
const SEMANTIC_TOKEN_TYPE_TYPE_PARAMETER = UInt(1)
const SEMANTIC_TOKEN_TYPE_VARIABLE       = UInt(2)
const SEMANTIC_TOKEN_TYPE_UNSPECIFIED    = UInt(3)

# Token modifiers we emit. Encoded as a bitmask (bit `i` = `SEMANTIC_TOKEN_MODIFIERS[i+1]`).
const SEMANTIC_TOKEN_MODIFIERS = String[
    SemanticTokenModifiers.declaration,
    SemanticTokenModifiers.definition,
]

const SEMANTIC_TOKEN_MODIFIER_DECLARATION = UInt(1) << 0
const SEMANTIC_TOKEN_MODIFIER_DEFINITION  = UInt(1) << 1

const SEMANTIC_TOKENS_LEGEND = SemanticTokensLegend(;
    tokenTypes = SEMANTIC_TOKEN_TYPES,
    tokenModifiers = SEMANTIC_TOKEN_MODIFIERS)

function semantic_tokens_options()
    return SemanticTokensOptions(;
        legend = SEMANTIC_TOKENS_LEGEND,
        full = true,
        range = true)
end

function semantic_tokens_registration()
    return Registration(;
        id = SEMANTIC_TOKENS_REGISTRATION_ID,
        method = SEMANTIC_TOKENS_REGISTRATION_METHOD,
        registerOptions = SemanticTokensRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            legend = SEMANTIC_TOKENS_LEGEND,
            full = true,
            range = true))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = SEMANTIC_TOKENS_REGISTRATION_ID,
#     method = SEMANTIC_TOKENS_REGISTRATION_METHOD))
# register(currently_running, semantic_tokens_registration())

function handle_SemanticTokensFullRequest(
        server::Server, msg::SemanticTokensFullRequest, cancel_flag::CancelFlag
    )
    state = server.state
    uri = msg.params.textDocument.uri

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, SemanticTokensFullResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, SemanticTokensFullResponse(;
            id = msg.id, result = nothing, error = result))
    end
    fi = result

    data = compute_semantic_tokens(state, uri, fi)
    return send(server, SemanticTokensFullResponse(;
        id = msg.id,
        result = SemanticTokens(; data)))
end

function handle_SemanticTokensRangeRequest(
        server::Server, msg::SemanticTokensRangeRequest, cancel_flag::CancelFlag
    )
    state = server.state
    uri = msg.params.textDocument.uri
    range = Range(;
        start = adjust_position(state, uri, msg.params.range.start),
        var"end" = adjust_position(state, uri, msg.params.range.var"end"))

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, SemanticTokensRangeResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, SemanticTokensRangeResponse(;
            id = msg.id, result = nothing, error = result))
    end
    fi = result

    data = compute_semantic_tokens(state, uri, fi; range)
    return send(server, SemanticTokensRangeResponse(;
        id = msg.id,
        result = SemanticTokens(; data)))
end

# (line, character, length, tokenType, tokenModifiers) — pre-encoding form
const SemanticTokenTuple = NTuple{5,UInt}

function compute_semantic_tokens(
        state::ServerState, uri::URI, fi::FileInfo;
        range::Union{Nothing,Range} = nothing,
    )
    st0_top = build_syntax_tree(fi)
    raw = SemanticTokenTuple[]
    # For range requests, convert the LSP range to a byte range so we can
    # cheaply skip toplevel statements that don't overlap.
    range_bytes = range === nothing ? nothing :
        xy_to_offset(fi, range.start):(xy_to_offset(fi, range.var"end") - 1)
    iterate_toplevel_tree(st0_top) do st0::SyntaxTreeC
        if range_bytes !== nothing && !overlaps_byte_range(st0, range_bytes)
            return
        end
        occs = get_binding_occurrences!(state, uri, fi, st0)
        collect_semantic_tokens_for_occurrences!(raw, state, uri, fi, occs)
    end
    sort!(raw)
    merge_overlapping_tokens!(raw)
    if range !== nothing
        filter_tokens_by_range!(raw, range)
    end
    return encode_semantic_tokens(raw)
end

function overlaps_byte_range(st0::SyntaxTreeC, byte_range::UnitRange{Int})
    JS.last_byte(st0) < first(byte_range) && return false
    JS.first_byte(st0) > last(byte_range) && return false
    return true
end

function filter_tokens_by_range!(raw::Vector{SemanticTokenTuple}, range::Range)
    rs_line, rs_char = range.start.line, range.start.character
    re_line, re_char = range.var"end".line, range.var"end".character
    filter!(raw) do tk
        line, char = tk[1], tk[2]
        after_start = line > rs_line || (line == rs_line && char >= rs_char)
        before_end = line < re_line || (line == re_line && char < re_char)
        return after_start && before_end
    end
    return raw
end

# A single source identifier may yield multiple occurrences at the same byte
# range (e.g. `where T` carries both `:def` and `:decl`). LSP encodes modifiers
# as a bitmask, so collapse duplicates of the same (line, char, len, type) and
# OR the modifier bits.
function merge_overlapping_tokens!(raw::Vector{SemanticTokenTuple})
    isempty(raw) && return raw
    write = 1
    @inbounds for read in 2:length(raw)
        prev = raw[write]
        cur = raw[read]
        if cur[1] == prev[1] && cur[2] == prev[2] && cur[3] == prev[3] && cur[4] == prev[4]
            raw[write] = (prev[1], prev[2], prev[3], prev[4], prev[5] | cur[5])
        else
            write += 1
            raw[write] = cur
        end
    end
    resize!(raw, write)
    return raw
end

function collect_semantic_tokens_for_occurrences!(
        raw::Vector{SemanticTokenTuple}, state::ServerState, uri::URI, fi::FileInfo,
        occs::BindingOccurrencesResult,
    )
    # `:static_parameter` bindings often coexist with same-named `:local`
    # aliases produced by `where`-clause scope blocks, sharing the same
    # occurrence set. Emitting both classifies one identifier as both
    # `typeParameter` and `variable`. Drop the `:local` aliases.
    static_param_names = Set{String}()
    for binfo_key in keys(occs)
        if binfo_key.kind === :static_parameter
            push!(static_param_names, binfo_key.name)
        end
    end
    for (binfo_key, occurrences) in occs
        binfo_key.kind === :local && binfo_key.name in static_param_names && continue
        ttype = classify_token_type(binfo_key.kind)
        name_bytes = sizeof(binfo_key.name)
        for occurrence in occurrences
            push_semantic_token!(raw, state, uri, fi, occurrence, ttype, name_bytes)
        end
    end
    return raw
end

function push_semantic_token!(
        raw::Vector{SemanticTokenTuple}, state::ServerState, uri::URI, fi::FileInfo,
        occurrence::CachedBindingOccurrence, ttype::UInt, name_bytes::Int,
    )
    # Reject occurrences without a precise source byte range. Macro-internal
    # bindings can have `fb` or `lb` set to `0` (= unknown), and `jsobj_to_range`
    # then falls back to `line_range`, producing a `typemax(Int32)` `character`
    # that we'd otherwise emit as a giant single-line token spanning the rest of
    # the file's encoding space.
    (occurrence.tree.fb == 0 || occurrence.tree.lb == 0) && return
    # Drop occurrences whose source range does not match the binding name's byte
    # length. Macro expansion may introduce synthetic bindings whose spans cover
    # the whole macro call; emitting those would attach a bogus multi-token-wide
    # highlight. Compare in UTF-8 bytes (not via `jsobj_to_range`, which returns
    # LSP encoding units like UTF-16 and would mismatch for non-ASCII identifiers).
    occurrence.tree.lb - occurrence.tree.fb + 1 == name_bytes || return
    range = jsobj_to_range(occurrence.tree, fi)
    range, target_uri = unadjust_range(state, uri, range)
    # For notebooks, `fi` is the concatenated buffer that spans every cell, so
    # `iterate_toplevel_tree` reaches occurrences belonging to other cells. The
    # response is scoped to the cell that issued the request, so drop tokens that
    # `unadjust_range` resolved to a different cell.
    target_uri == uri || return
    spos, epos = range.start, range.var"end"
    # LSP semantic tokens cannot span multiple lines without `multilineTokenSupport`.
    spos.line == epos.line || return
    epos.character > spos.character || return
    line = spos.line
    char = spos.character
    len = epos.character - spos.character
    tmod = classify_token_modifier(occurrence.kind)
    push!(raw, (line, char, len, ttype, tmod))
    return raw
end

function classify_token_type(binfo_kind::Symbol)
    if binfo_kind === :argument
        return SEMANTIC_TOKEN_TYPE_PARAMETER
    elseif binfo_kind === :static_parameter
        return SEMANTIC_TOKEN_TYPE_TYPE_PARAMETER
    elseif binfo_kind === :local
        return SEMANTIC_TOKEN_TYPE_VARIABLE
    elseif binfo_kind === :global
        return SEMANTIC_TOKEN_TYPE_UNSPECIFIED
    else error("Unknown binding kind found") end
end

function classify_token_modifier(occurrence_kind::Symbol)
    if occurrence_kind === :decl
        return SEMANTIC_TOKEN_MODIFIER_DECLARATION
    elseif occurrence_kind === :def
        return SEMANTIC_TOKEN_MODIFIER_DEFINITION
    end
    return UInt(0)
end

# LSP delta-encoding: each token becomes 5 ints
#   [deltaLine, deltaStart, length, tokenType, tokenModifiers]
# `deltaStart` is relative to the previous token only when on the same line.
function encode_semantic_tokens(raw::Vector{SemanticTokenTuple})
    data = UInt[]
    sizehint!(data, 5 * length(raw))
    prev_line = UInt(0)
    prev_char = UInt(0)
    for (line, char, len, ttype, tmod) in raw
        delta_line = line - prev_line
        delta_start = delta_line == 0 ? char - prev_char : char
        push!(data, delta_line, delta_start, len, ttype, tmod)
        prev_line = line
        prev_char = char
    end
    return data
end

# used by tests
function semantic_tokens(fi::FileInfo; range::Union{Nothing,Range} = nothing)
    state = ServerState()
    uri = filepath2uri(fi.filename)
    store!(state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end
    return compute_semantic_tokens(state, uri, fi; range)
end
