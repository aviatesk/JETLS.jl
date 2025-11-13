const _INTERFACE_DEFS = Dict{Symbol,Expr}()

macro interface(exs...)
    nexs = length(exs)
    if nexs == 1
        # macro calls are expanded from outermost to innermost, so anonymous `@interface`
        # won't be expanded unless it's used standalone
        error("Anonymous `@interface` is only supported within a named `@interface` definition: ", exs)
    else
        nexs == 2 || error("Invalid `@interface` syntax: ", exs)
    end
    Name, defex = exs
    Name isa Symbol || error("Invalid `@interface` syntax: ", exs)
    if Meta.isexpr(defex, :macrocall)
        length(defex.args) == 4 || error("Invalid `@interface` syntax: ", exs)
        defex.args[1] === Symbol("@extends") || error("Invalid `@interface` syntax: ", exs)
        defex.args[2] isa LineNumberNode || error("Invalid `@interface` syntax: ", exs)
        extends = defex.args[3]
        if extends isa Symbol
            extends = Symbol[extends]
        elseif Meta.isexpr(extends, :tuple) && all(@nospecialize(x)->x isa Symbol, extends.args)
            extends = Symbol[extends.args[i]::Symbol for i = 1:length(extends.args)]
        else
            error("Invalid `@interface` syntax: ", exs)
        end
        defex = defex.args[4]
    else
        extends = nothing
    end
    Meta.isexpr(defex, :block) || error("Invalid `@interface` syntax: ", exs)

    toplevelblk = Expr(:toplevel)

    is_method_dispatchable = false
    structbody = Expr(:block, __source__)
    extended_fields = Dict{Symbol,Vector{Int}}()
    duplicated_fields = Int[]
    if extends !== nothing
        for extend in extends
            is_method_dispatchable |= extend === :RequestMessage || extend === :NotificationMessage
            add_extended_interface!(toplevelblk, structbody,
                                    extended_fields,
                                    duplicated_fields,
                                    extend,
                                    __source__)
        end
    end
    _, method = process_interface_def!(toplevelblk, structbody,
                                       extended_fields,
                                       duplicated_fields,
                                       defex,
                                       __source__,
                                       Name)

    if is_method_dispatchable
        method isa String || error("`method::String` not defined in `@interface` for dispatchable message: ", exs)
        push!(toplevelblk.args, :($(GlobalRef(@__MODULE__, :method_dispatcher))[$method] = $Name))
    end

    push!(toplevelblk.args, :(push!($(GlobalRef(@__MODULE__, :exports)), $(QuoteNode(Name)))))

    push!(toplevelblk.args, :(return $Name))

    return esc(toplevelblk)
end

function process_interface_def!(toplevelblk::Expr, structbody::Expr,
                                extended_fields::Dict{Symbol,Vector{Int}},
                                duplicated_fields::Vector{Int},
                                defex::Expr,
                                __source__::LineNumberNode,
                                Name::Union{Symbol,Nothing})
    method = _process_interface_def!(toplevelblk, structbody, extended_fields, duplicated_fields, defex, __source__)
    deleteat!(structbody.args, duplicated_fields)
    is_anon = Name === nothing
    if is_anon
        # Name = Symbol("AnonymousInterface", string(__source__)) # XXX this doesn't work probably due to Julia internal bug
        Name = Symbol("AnonymousInterface", gensym())
    end
    structdef = Expr(:struct, false, Name, structbody)
    # TODO Use `StructUtils.@defaults` here?
    kwdef = Expr(:macrocall, GlobalRef(Base, Symbol("@kwdef")), __source__, structdef) # `@kwdef` will attach `Core.__doc__` automatically
    push!(toplevelblk.args, kwdef)
    if is_anon
        push!(toplevelblk.args, :(Base.convert(::Type{$Name}, nt::NamedTuple) = $Name(; nt...)))
    end
    if !is_anon
        push!(toplevelblk.args, :($(GlobalRef(@__MODULE__, :_INTERFACE_DEFS))[$(QuoteNode(Name))] = $(QuoteNode(structbody))))
    end
    return Name, method
end

function add_extended_interface!(toplevelblk::Expr, structbody::Expr,
                                 extended_fields::Dict{Symbol,Vector{Int}},
                                 duplicated_fields::Vector{Int},
                                 extend::Symbol,
                                __source__::LineNumberNode)
    return _process_interface_def!(toplevelblk, structbody,
                                   extended_fields,
                                   duplicated_fields,
                                   _INTERFACE_DEFS[extend],
                                   __source__;
                                   extending = true)
end

function _process_interface_def!(toplevelblk::Expr, structbody::Expr,
                                 extended_fields::Dict{Symbol,Vector{Int}},
                                 duplicated_fields::Vector{Int},
                                 defex::Expr,
                                 __source__::LineNumberNode;
                                 extending::Bool = false)
    @assert Meta.isexpr(defex, :block)
    extended_idxs = Int[]
    method = nothing
    for i = 1:length(defex.args)
        defarg = defex.args[i]
        fieldline = defarg
        if fieldline isa LineNumberNode || fieldline isa String
            if fieldline isa LineNumberNode
                __source__ = fieldline
            end
            push!(structbody.args, fieldline)
            if extending
                push!(extended_idxs, length(structbody.args))
            end
            continue
        end
        if Meta.isexpr(fieldline, :macrocall)
            if fieldline.args[1] === GlobalRef(Core, Symbol("@doc"))
                fielddoc = fieldline.args[3]
                fielddoc isa String || error("Invalid `@interface` syntax: ", defex)
                push!(structbody.args, fielddoc)
                if extending
                    push!(extended_idxs, length(structbody.args))
                end
                fieldline = fieldline.args[end]
            else
                error("Unsupported syntax found in `@interface`: ", defex)
            end
        end
        if Meta.isexpr(fieldline, :(=))
            fielddecl, default = fieldline.args
            if Meta.isexpr(fielddecl, :(::))
                fieldname = fielddecl.args[1]
            else
                fieldname = fielddecl
            end
            fieldname isa Symbol || error("Invalid `@interface` syntax: ", defex)
            if fieldname === :method
                default isa String || error("Invalid message definition: ", defex)
                method isa String && error("Duplicated method definition: ", defex)
                method = default
            end
        else
            fielddecl = fieldline
        end
        if Meta.isexpr(fielddecl, :(::))
            fieldname = fielddecl.args[1]
            fieldtype = fielddecl.args[2]
            if Meta.isexpr(fieldtype, :curly)
                for i = 1:length(fieldtype.args)
                    ufty = fieldtype.args[i]
                    if Meta.isexpr(ufty, :macrocall) && ufty.args[1] === Symbol("@interface")
                        anon_defex = ufty.args[end]
                        Meta.isexpr(anon_defex, :block) || error("Invalid `@interface` syntax: ", ufty)
                        fieldtype.args[i] = process_anon_interface_def!(toplevelblk, anon_defex, __source__)
                    end
                end
            elseif Meta.isexpr(fieldtype, :macrocall) && fieldtype.args[1] === Symbol("@interface")
                anon_defex = fieldtype.args[end]
                Meta.isexpr(anon_defex, :block) || error("Invalid `@interface` syntax: ", fieldtype)
                fielddecl.args[2] = process_anon_interface_def!(toplevelblk, anon_defex, __source__)
            end
        else
            fieldname = fielddecl
        end
        fieldname isa Symbol || error("Invalid `@interface` syntax: ", defex)
        if haskey(extended_fields, fieldname)
            append!(duplicated_fields, extended_fields[fieldname])
        end
        push!(structbody.args, fieldline)
        if extending
            push!(extended_idxs, length(structbody.args))
            extended_fields[fieldname] = copy(extended_idxs)
            empty!(extended_idxs)
        end
    end
    return method
end

function process_anon_interface_def!(toplevelblk::Expr, defex::Expr, __source__::LineNumberNode) # Anonymous @interface
    extended_fields = Dict{Symbol,Vector{Int}}()
    duplicated_fields = Int[]
    res, _ = process_interface_def!(toplevelblk, Expr(:block),
        extended_fields, duplicated_fields, defex, __source__, #=Name=#nothing)
    if !(isempty(extended_fields) && isempty(duplicated_fields))
        error("`Anonymous @interface` does not support extension", defex)
    end
    return res
end
