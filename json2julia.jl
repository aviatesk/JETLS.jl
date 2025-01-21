using JSON3

const kinds = Dict(
    9 => :literal_number,
    11 => :literal_string,
    80 => :identifier,
    95 => :export,
    106 => :null,
    136 => :boolean,
    150 => :number,
    154 => :string,
    171 => :member,
    183 => :type_identifier,
    187 => :type_anonymous,
    188 => :type_array,
    192 => :type_union,
    201 => :type_literal,
    224 => :operator,
    264 => :interface,
    265 => :type,
    267 => :namespace,
    307 => :toplevel,
)

const _VAL_DEFS = Dict{Symbol,Any}()

const _TYPE_DEFS = Dict{Symbol,Union{Symbol,Expr}}(
    :integer => :Int,
    :uinteger => :UInt,
    :decimal => :Float64,
    :LSPAny => :Any,
    :LSPObject => :(Dict{String,Any}),
    :LSPArray => :(Vector{Any}))
const _PREDEFINED_TYPE_DEFS = keys(_TYPE_DEFS)

struct InterfaceDefLine
    field::Symbol
    doc::Union{Nothing,String}
    line::Expr
    nullable::Bool
end

const _INTERFACE_DEFS = Dict{Symbol,Vector{InterfaceDefLine}}()

const method_dispatcher = Dict{String,Symbol}()

function ts2jl(node, anon_defs=nothing)
    kindidx = node[:kind]
    if !haskey(kinds, kindidx)
        error("Unknown kind: ", kindidx, " in ", node)
    end
    kind = kinds[kindidx]
    if kind === :literal_string
        return node[:text]
    elseif kind === :literal_number
        return JSON3.read(node[:text])
    elseif kind === :null
        return :nothing
    elseif kind === :boolean
        return :Bool
    elseif kind === :number
        return :Number
    elseif kind === :string
        return :String
    elseif kind === :identifier
        return _VAL_DEFS[Symbol(node[:escapedText])]
    elseif kind === :type_identifier
        typenode = node[:typeName]
        typekind = typenode[:kind]
        if typekind == 166 # A.B
            # XXX This pattern happens for something like `DocumentDiagnosticReportKind.Full`,
            #     i.e. a literal type that is a member of some namespace.
            #     But this path can be hit for other reasons too?
            # TODO Can we replicate this literal type information in Julia somehow?
            name = typenode[:left][:escapedText]
        else
            kinds[typekind] === :identifier || error("Unexpected kind: ", typekind, " in ", typenode)
            name = typenode[:escapedText]
        end
        return _TYPE_DEFS[Symbol(name)]
    elseif kind === :type_anonymous
        if anon_defs === nothing
            error("Unexpected anonymous type definition in ", node)
        end
        Name = gensym(:AnonymousType)
        append!(anon_defs, process_interface_statement(IOBuffer(), Name, node))
        push!(anon_defs, Base.remove_linenums!(:(Base.convert(::Type{$Name}, nt::NamedTuple) = $Name(;nt...)))) # allows `NamedTuple` to be converted to the anonymous type at the call site
        return _TYPE_DEFS[Name]
    elseif kind === :type_array
        return Expr(:curly, :Vector, ts2jl(node[:elementType], anon_defs))
    elseif kind === :type_union
        return ts2jl_union(node, anon_defs)
    elseif kind === :type_literal
        # TODO Can we replicate this literal type information in Julia somehow?
        return Expr(:call, GlobalRef(Core,:typeof), ts2jl(node[:literal], anon_defs))
    elseif kind === :operator
        if node[:operator] == 41 # -xxx
            return Expr(:call, :-, ts2jl(node[:operand], anon_defs))
        else
            error("Unimplemented operator: ", node[:operator], " in ", node)
        end
    else
        error("Unimplemented kind: ", kind, " in ", node)
    end
end

function ts2jl_union(node, anon_defs)
    out = Expr(:curly, :Union)
    for type in node[:types]
        push!(out.args, ts2jl(type, anon_defs))
    end
    return out
end

function process_jsDoc(jsDoc)
    jsDoc = only(jsDoc)
    doc = haskey(jsDoc, :comment) ? jsDoc[:comment] : ""
    if haskey(jsDoc, :tags)
        tags = "# Tags\n"
        for tag in jsDoc[:tags]
            tagname = tag[:tagName][:escapedText]
            comment = tag[:comment]
            tags *= "\n- $tagname – $comment"
        end
        doc *= "\n\n" * tags
    end
    return doc
end

function process_type_statement(io, statement)
    Name = Symbol(statement[:name][:escapedText])
    ret = Any[]
    if Name ∉ _PREDEFINED_TYPE_DEFS
        if haskey(_TYPE_DEFS, Name)
            error("Duplicated type definition found: ", statement)
        end
        jltype = ts2jl(statement[:type])
        lsptypeofdef = Base.remove_linenums!(:(lsptypeof(::Val{$(QuoteNode(Name))}) = $jltype))
        push!(ret, lsptypeofdef)
        println(io, lsptypeofdef)
        _TYPE_DEFS[Name] = :(lsptypeof(Val($(QuoteNode(Name)))))
    end
    if haskey(statement, :jsDoc)
        doc = process_jsDoc(statement[:jsDoc])
        docex = Expr(:macrocall, Symbol("@doc"), nothing, doc, Name)
        push!(ret, docex)
        println(io, docex)
        println(io)
        return ret
    end
    return ret
end

function process_interface_statement(io, statement)
    Name = Symbol(statement[:name][:escapedText])
    return process_interface_statement(io, Name, statement)
end
function process_interface_statement(io, Name::Symbol, statement)
    structbody = Expr(:block)
    structdef = Expr(:struct, false, Name, structbody)
    deflines = InterfaceDefLine[]
    anon_defs = Any[]
    if haskey(statement, :heritageClauses)
        for clause in statement[:heritageClauses]
            for typ in clause[:types]
                extended = Symbol(typ[:expression][:escapedText])
                append!(deflines, _INTERFACE_DEFS[extended])
            end
        end
    end
    for member in statement[:members]
        fname = Symbol(member[:name][:escapedText])
        deleteat!(deflines, findall(x->x.field===fname, deflines))
        doc = haskey(member, :jsDoc) ? process_jsDoc(member[:jsDoc]) : nothing
        ftype = ts2jl(member[:type], anon_defs)
        if fname === :method && kinds[member[:type][:kind]] === :type_literal
            method = ts2jl(member[:type][:literal])::String
            method_dispatcher[method] = Name
        end
        if haskey(member, :questionToken)
            ftype = Expr(:curly, :Union, ftype, :Nothing)
            structline = Expr(:(::), fname, ftype)
            structline = Expr(:(=), structline, :nothing)
            nullable = true
        else
            structline = Expr(:(::), fname, ftype)
            nullable = false
            if fname === :jsonrpc
                structline = Expr(:(=), structline, "2.0")
            end
        end
        push!(deflines, InterfaceDefLine(fname, doc, structline, nullable))
    end
    for defline in deflines
        if defline.doc !== nothing
            push!(structbody.args, defline.doc)
        end
        push!(structbody.args, defline.line)
    end
    _TYPE_DEFS[Name] = Name
    _INTERFACE_DEFS[Name] = deflines
    structdef = Expr(:macrocall, Symbol("@kwdef"), nothing, structdef)
    nullable_fields = map(i->deflines[i].field, findall(x->x.nullable, deflines))
    omitempties_defs = isempty(nullable_fields) ? () :
        (Base.remove_linenums!(:(StructTypes.omitempties(::Type{$Name}) = $(Tuple(nullable_fields)))),)
    isempty(anon_defs) || (join(io, anon_defs, "\n"), println(io))
    println(io, structdef)
    isempty(omitempties_defs) || println(io, only(omitempties_defs))
    ret = Any[anon_defs..., structdef, omitempties_defs...]
    if haskey(statement, :jsDoc)
        doc = process_jsDoc(statement[:jsDoc])
        docex = Expr(:macrocall, Symbol("@doc"), nothing, doc, Name)
        println(io, docex)
        println(io)
        push!(ret, docex)
    else
        println(io)
    end
    return ret
end

function process_namespace_statement(io, statement)
    Name = Symbol(statement[:name][:escapedText])
    modbody = Expr(:block)
    for bodystatement in statement[:body][:statements]
        decls = bodystatement[:declarationList][:declarations]
        @assert length(decls) == 1
        decl = only(decls)
        name = Symbol(decl[:name][:escapedText])
        val = ts2jl(decl[:initializer])
        _VAL_DEFS[name] = val
        push!(modbody.args, :(const $name = $val))
        if haskey(bodystatement, :jsDoc)
            doc = process_jsDoc(bodystatement[:jsDoc])
            docex = Expr(:macrocall, Symbol("@doc"), nothing, doc, name)
            push!(modbody.args, docex)
        end
    end
    modex = Expr(:module, true, Name, modbody)
    println(io, modex)
    ret = Any[modex]
    if haskey(statement, :jsDoc)
        doc = process_jsDoc(statement[:jsDoc])
        docex = Expr(:macrocall, Symbol("@doc"), nothing, doc, Name)
        println(io, docex)
        println(io)
        push!(ret, docex)
    else
        println(io)
    end
    return ret
end

function process_statement(io, statement)
    kindidx = statement[:kind]
    kindidx == 242 && return # XXX
    haskey(kinds, kindidx) || error("Unknown kind: ", kindidx, " in ", statement)
    kind = kinds[kindidx]
    if kind === :type
        process_type_statement(io, statement)
    elseif kind === :interface
        process_interface_statement(io, statement)
    elseif kind === :namespace
        process_namespace_statement(io, statement)
    else
        error("Unexpected kind: ", kind, " in ", statement)
    end
end

# HACK
@eval Base function show_sym(io::IO, sym::Symbol; allow_macroname=false)
    if sym === :end
        print(io, "var\"end\"")
    elseif is_valid_identifier(sym)
        print(io, sym)
    elseif allow_macroname && (sym_str = string(sym); startswith(sym_str, '@'))
        print(io, '@')
        show_sym(io, Symbol(sym_str[2:end]))
    else
        print(io, "var", repr(string(sym))) # TODO: this is not quite right, since repr uses String escaping rules, and Symbol uses raw string rules
    end
end

const LSP_JSON_FILE = "LSP.json"
const LSP_JL_FILE = "src/LSP.jl"
let lsp = JSON3.read(LSP_JSON_FILE)
    @info "Read LSP defintions of the JSON format at $LSP_JSON_FILE"
    @assert kinds[lsp[:kind]] === :toplevel
    @info "Converting the JSON LSP definitions into Julia equivalent"
    open(LSP_JL_FILE, "w") do f
        for (i,statement) in enumerate(lsp[:statements])
            process_statement(f, statement)
        end
        print(f, """
        # message dispatcher definition
        const method_dispatcher = Dict{String,DataType}(
        """)
        for (method, TypeName) in method_dispatcher
            println(f, "    \"$method\" => $TypeName,")
        end
        println(f, ")")
        # export everything we got
        names = Set{String}()
        for name in keys(_TYPE_DEFS); push!(names, String(name)); end
        for name in keys(_INTERFACE_DEFS); push!(names, String(name)); end
        names = sort!(collect(names))
        println(f, "export")
        println(f, "    method_dispatcher,")
        print(f, "    ")
        join(f, names, ",\n    ")
    end
    @info "Julia LSP definitions written to $LSP_JL_FILE"
end
