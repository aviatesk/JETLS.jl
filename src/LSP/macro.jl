const _TYPE_DEFS = Dict{Symbol,Any}(
    :LSPAny => :Any,
    :LSPObject => :NamedTuple,
    :LSPArray => :(Vector{Any}))

const _INTERFACE_DEFS = Dict{Symbol,Expr}()

macro lsp(exs...)
    nexs = length(exs)
    for i = 1:nexs
        ex = exs[i]
        if Meta.isexpr(ex, :export)
            ex = ex.args[1]
        end
        if ex === :namespace
            nexs == i+2 || error("Invalid `namespace` syntax: ", exs)
            Name, defex = exs[i+1], exs[i+2]
            Name isa Symbol || error("Invalid `namespace` syntax: ", exs)
            Meta.isexpr(defex, :braces) || Meta.isexpr(defex, :bracescat) || error("Invalid `namespace` syntax: ", exs)
            return namespace(Name, defex, __source__)
        elseif ex === :interface
            nexs == i + 2 || nexs == i + 4 || error("Invalid `interface syntax: ", exs)
            Name = exs[i+1]
            Name isa Symbol || error("Invalid `interface` syntax: ", exs)
            if nexs == i + 4
                exs[i+2] === :extends || error("Invalid `interface` syntax: ", exs)
                extends = exs[i+3]
                if extends isa Symbol || (
                    Meta.isexpr(extends, :tuple) &&
                    all(@nospecialize(x)->x isa Symbol, extends.args))
                    defex = exs[i+4]
                else
                    error("Invalid `interface` syntax: ", exs)
                end
            else
                extends = nothing
                defex = exs[i+2]
            end
            if Meta.isexpr(defex, :braces)
                isempty(defex.args) || length(defex.args) == 1 ||
                    error("Invalid `interface` syntax: ", exs)
            else
                Meta.isexpr(defex, :bracescat) || error("Invalid `interface` syntax: ", exs)
            end
            _INTERFACE_DEFS[Name] = defex
            _TYPE_DEFS[Name] = Name
            return interface(Name, defex, extends, __source__)
        elseif ex === :type
            nexs == i + 1 || error("Invalid `type` syntax: ", exs)
            defex = exs[i+1]
            Meta.isexpr(defex, :(=)) || error("Invalid `type` syntax: ", exs)
            Name = defex.args[1]
            Name isa Symbol || error("Invalid `type` syntax: ", exs)
            _TYPE_DEFS[Name] = tstype_to_juliatype(defex.args[2])
            return :(Core.@__doc__ $(QuoteNode(Name)))
        end
    end
    if !(@isdefined kind_idx)
        error("Unknown LSP syntax: ", exs)
    end
end

function namespace(Name::Symbol, defex::Expr, __source__::LineNumberNode)
    defs = Expr(:block)

    # Documentation for enum values
    docs = Any[]

    local doc = nothing # documentation for the next enum element
    for arg in defex.args
        if arg isa String
            doc === nothing || error("Unexpected `namespace` syntax: ", defex)
            doc = arg
        elseif Meta.isexpr(arg, :row)
            if arg.args[1] ≠ :(export const)
                error("Unexpected `namespace` syntax: ", defex)
            end
            defline = arg.args[2]
            if !Meta.isexpr(defline, :(=))
                error("Invalid `namespace` syntax: ", defex)
            end
            n, v = defline.args
            if Meta.isexpr(n, :call) && n.args[1] === :(:)
                n = n.args[2]
            end
            n isa Symbol || return error("Invalid `namespace` syntax")
            push!(defs.args, :(const $n = $v))
            if doc !== nothing
                push!(docs, :(@doc $doc $n))
                doc = nothing
            end
        else
            error("Unexpected `namespace` syntax: ", defex)
        end
    end

    modex = Expr(:block, defs, docs...)
    return esc(Expr(:toplevel,
        Expr(:module, true, Name, modex),
        :(Base.@__doc__ $Name)))
end

using StructTypes

function interface(Name::Symbol, defex::Expr, extends, __source__::LineNumberNode)
    structbody = Expr(:block)
    structdef = Expr(:struct, false, Name, structbody)
    nullable_fields = Symbol[]
    if extends !== nothing
        if Meta.isexpr(extends, :tuple)
            for extend in extends.args
                add_extended_interface!(structbody, extend::Symbol, nullable_fields)
            end
        else
            add_extended_interface!(structbody, extends::Symbol, nullable_fields)
        end
    end
    process_interface_def!(structbody, defex, nullable_fields)
    if isempty(nullable_fields)
        return esc(:(Base.@kwdef $structdef)) # `Base.@kwdef` will attach `Core.__doc__` automatically
    else
        omitempties = Tuple(nullable_fields)
        return quote
            Base.@kwdef $structdef # `Base.@kwdef` will attach `Core.__doc__` automatically
            $StructTypes.omitempties(::Type{$Name}) = $omitempties
        end |> esc
    end
    return esc(:(Base.@__doc__ Base.@kwdef $structdef))
end

function add_extended_interface!(xbody::Expr, extend::Symbol, nullable_fields::Vector{Symbol})
    process_interface_def!(xbody, _INTERFACE_DEFS[extend], nullable_fields)
end

function process_interface_def!(xbody::Expr, defex::Expr, nullable_fields::Vector{Symbol}, namedtuple::Bool=false)
    for defline in defex.args
        if defline isa String # field documentation
            if !namedtuple
                push!(xbody.args, defline)
            end
        elseif Meta.isexpr(defline, :row) # field var"?:" FieldType
            length(defline.args) == 3 || error("Unexpected `interface` syntax: ", defex)
            defline.args[2] === Symbol("?:") || error("Unexpected `interface` syntax: ", defex)
            fname, ftype = defline.args[1], defline.args[3]
            ftype = tstype_to_juliatype(ftype)
            ftype = Expr(:curly, :Union, ftype, :Nothing)
            fdecl = Expr(:(::), fname, ftype)
            if namedtuple
                push!(xbody.args, fdecl)
            else
                fdecl = Expr(:(=), Expr(:(::), fname, ftype), :nothing)
                push!(xbody.args, fdecl)
            end
            push!(nullable_fields, fname)
        elseif Meta.isexpr(defline, :call) # field : FieldType
            length(defline.args) == 3 || error("Unexpected `interface` syntax: ", defex)
            defline.args[1] === :(:) || error("Unexpected `interface` syntax: ", defex)
            fname, ftype = defline.args[2], defline.args[3]
            ftype = tstype_to_juliatype(ftype)
            push!(xbody.args, Expr(:(::), fname, ftype))
        else
            error("Unexpected `interface` syntax: ", defex)
        end
    end
end

# TODO Handle nested interface declaration properly

function tstype_to_juliatype(@nospecialize x)
    if x isa Symbol
        if x === :integer
            return :Int
        elseif x === :string
            return :String
        elseif x === :uinteger
            return :UInt
        elseif x === :decimal
            return :Float64
        elseif x === :boolean
            return :Bool
        elseif x === :null
            return :Nothing
        end
        return _TYPE_DEFS[x]
    elseif Meta.isexpr(x, :call) && length(x.args) == 3 && x.args[1] === :| # t1 | t2 [| t3 ...]
        return Expr(:curly, :Union, tstype_to_juliatype(x.args[2]), tstype_to_juliatype(x.args[3]))
    elseif Meta.isexpr(x, :.) && length(x.args) == 2 # kind: DocumentDiagnosticReportKind.Full
        return tstype_to_juliatype(x.args[1]) # DocumentDiagnosticReportKind
    elseif Meta.isexpr(x, :ref) && length(x.args) == 1
        return Expr(:curly, :Vector, tstype_to_juliatype(only(x.args)))
    elseif Meta.isexpr(x, :braces) || Meta.isexpr(x, :bracescat)
        if Meta.isexpr(x, :braces)
            isempty(x.args) || length(x.args) == 1 ||
                error("Invalid TypeScript type expression: ", exs)
        else
            Meta.isexpr(x, :bracescat) || error("Invalid TypeScript type expression: ", exs)
        end
        namedtuple = :(@NamedTuple{})
        process_interface_def!(namedtuple.args[end], x, Symbol[], #=namedtuple=#true)
        return namedtuple
    else # literal values
        return :(typeof($x))
    end
end
