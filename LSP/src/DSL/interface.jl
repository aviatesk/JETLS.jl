const _interface_defs_ = Dict{Symbol,Expr}()

const _debug_ = Dict{Symbol,Pair{Expr,Dict{Symbol,Union{Nothing,Pair{Expr,Any}}}}}()

"""
    @interface InterfaceName [@extends ParentInterface] begin
        field::Type
        optionalField::Union{Nothing, Type} = nothing
        ...
    end

Creates a Julia struct with keyword constructor that mirrors TypeScript interface
definitions from the LSP specification, featuring:
- Keyword constructor: All structs are created with `@kwdef`, enabling keyword-based construction
- Optional fields: Use `Union{Nothing, Type} = nothing` to represent TypeScript's optional properties (`field?: Type`)
- Interface inheritance: Use `@extends` to compose interfaces from parent interfaces (similar to TypeScript's `extends`)
- Anonymous interfaces: Can be used inline within field type declarations (e.g., `Union{Nothing, @interface begin ... end}`)
- JSON serialization: Integrates with JSON.jl v1 and StructUtils.jl for automatic JSON serialization/deserialization
- Automatic type choosing: For fields with `Union` types, automatically generates `StructUtils.fieldtags` implementations
  that inspect the JSON structure to determine the correct type during deserialization
- Method dispatching: For interfaces extending `RequestMessage` or `NotificationMessage`,
  automatically registers the message type in the `method_dispatcher` dictionary for LSP message routing

# Field declarations

Fields can be declared with type annotations and optional default values:

```julia
@interface Example begin
    "Required field"
    requiredField::String

    "Optional field that can be omitted"
    optionalField::Union{Nothing, Bool} = nothing

    "Field with default value"
    fieldWithDefault::Int = 0
end
```

# Anonymous interfaces

Anonymous interfaces can be used within field type declarations for inline type specifications:

```julia
@interface Outer begin
    nested::Union{Nothing, @interface begin
        innerField::String
    end} = nothing
end
```

# Inheritance

The `@extends` syntax allows composing interfaces from one or more parent interfaces:

```julia
@interface Child @extends Parent begin
    childField::String
end

@interface MultipleInheritance @extends (Parent1, Parent2) begin
    additionalField::Int
end
```

When a child interface defines a field with the same name as a parent interface, the child's definition takes precedence.

# Automatic type choosing for JSON deserialization

For fields with `Union` types, `@interface` automatically generates `StructUtils.fieldtags`
implementations that analyze the JSON structure to determine the correct type during
deserialization. This enables automatic conversion of polymorphic fields common in the LSP
specification, e.g.:
```julia
@interface Hover begin
    contents::Union{MarkedString, Vector{MarkedString}, MarkupContent}
    range::Union{Nothing, Range} = nothing
end

@interface WorkspaceEdit begin
    documentChanges::Union{Nothing, Vector{Union{TextDocumentEdit, CreateFile, RenameFile, DeleteFile}}} = nothing
end
```

# LSP message dispatching

For interfaces that extend `RequestMessage` or `NotificationMessage`, a `method::String`
field must be defined:
```julia
@interface MyRequest @extends RequestMessage begin
    method::String = "textDocument/myRequest"
    params::MyParams
end
```

This automatically registers the interface in `method_dispatcher["textDocument/myRequest"]`,
enabling routing of incoming LSP messages to the appropriate handler.

See also: [`@namespace`](@ref)
"""
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
                                    __module__,
                                    __source__)
        end
    end
    _, method = process_interface_def!(toplevelblk, structbody,
                                       extended_fields,
                                       duplicated_fields,
                                       defex,
                                       __module__,
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
                                __module__::Module,
                                __source__::LineNumberNode,
                                Name::Union{Symbol,Nothing})
    is_anon = Name === nothing
    if is_anon
        # Name = Symbol("AnonymousInterface", string(__source__)) # XXX this doesn't work probably due to Julia internal bug
        Name = Symbol("AnonymousInterface", gensym())
    end
    method, fieldtags_ex = _process_interface_def!(
        toplevelblk, structbody, extended_fields,
        duplicated_fields, defex, __module__, __source__;
        struct_name = Name)
    deleteat!(structbody.args, duplicated_fields)
    structdef = Expr(:struct, false, Name, structbody)
    # TODO Use `StructUtils.@defaults` here?
    kwdef = Expr(:macrocall, GlobalRef(Base, Symbol("@kwdef")), __source__, structdef) # `@kwdef` will attach `Core.__doc__` automatically
    push!(toplevelblk.args, kwdef)
    if is_anon
        push!(toplevelblk.args, :(Base.convert(::Type{$Name}, nt::NamedTuple) = $Name(; nt...)))
    end
    push!(toplevelblk.args, :($(GlobalRef(@__MODULE__, :_interface_defs_))[$(QuoteNode(Name))] = $(QuoteNode(structbody))))
    if fieldtags_ex !== nothing
        push!(toplevelblk.args, fieldtags_ex)
    end
    return Name, method
end

function add_extended_interface!(
        toplevelblk::Expr, structbody::Expr, extended_fields::Dict{Symbol,Vector{Int}},
        duplicated_fields::Vector{Int}, extend::Symbol, __module__::Module, __source__::LineNumberNode
    )
    _process_interface_def!(
        toplevelblk, structbody, extended_fields,
        duplicated_fields, _interface_defs_[extend], __module__, __source__;
        extending = true)
    nothing
end

function _process_interface_def!(
        toplevelblk::Expr, structbody::Expr, extended_fields::Dict{Symbol,Vector{Int}},
        duplicated_fields::Vector{Int}, defex::Expr, __module__::Module, __source__::LineNumberNode;
        extending::Bool = false, struct_name::Union{Nothing,Symbol} = nothing,
    )
    @assert Meta.isexpr(defex, :block)
    extended_idxs = Int[]
    method = nothing
    for i = 1:length(defex.args)
        fieldline = defex.args[i]
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
            fdecl, default = fieldline.args
            if Meta.isexpr(fdecl, :(::))
                fname = fdecl.args[1]
            else
                fname = fdecl
            end
            fname isa Symbol || error("Invalid `@interface` syntax: ", defex)
            if fname === :method
                default isa String || error("Invalid message definition: ", defex)
                method isa String && error("Duplicated method definition: ", defex)
                method = default
            end
        else
            fdecl = fieldline
        end
        if Meta.isexpr(fdecl, :(::))
            fname = fdecl.args[1]
            ftype = fdecl.args[2]
            if Meta.isexpr(ftype, :curly)
                for i = 1:length(ftype.args)
                    ufty = ftype.args[i]
                    if Meta.isexpr(ufty, :macrocall) && ufty.args[1] === Symbol("@interface")
                        anon_defex = ufty.args[end]
                        Meta.isexpr(anon_defex, :block) || error("Invalid `@interface` syntax: ", ufty)
                        ftype.args[i] = process_anon_interface_def!(toplevelblk, anon_defex, __module__, __source__)
                    end
                end
            elseif Meta.isexpr(ftype, :macrocall) && ftype.args[1] === Symbol("@interface")
                anon_defex = ftype.args[end]
                Meta.isexpr(anon_defex, :block) || error("Invalid `@interface` syntax: ", ftype)
                fdecl.args[2] = process_anon_interface_def!(toplevelblk, anon_defex, __module__, __source__)
            end
        else
            fname = fdecl
        end
        fname isa Symbol || error("Invalid `@interface` syntax: ", defex)
        if haskey(extended_fields, fname)
            append!(duplicated_fields, extended_fields[fname])
        end
        push!(structbody.args, fieldline)
        if extending
            push!(extended_idxs, length(structbody.args))
            extended_fields[fname] = copy(extended_idxs)
            empty!(extended_idxs)
        end
    end
    if struct_name !== nothing
        fieldtags_ex = :(let
            ntparams = Expr(:parameters)
            body = Expr(:tuple, ntparams)
            choosetypes = Dict{Symbol,Union{Nothing,Pair{Expr,Any}}}()
            for fname in fieldnames($struct_name)
                choosetype_name = gensym(:choosetype)
                choosefunc_ex = $gen_choosetype_impl($struct_name, fname)
                if choosefunc_ex !== nothing
                    choosetypefunc = Core.eval($__module__, choosefunc_ex)
                    push!(ntparams.args, Expr(:kw, fname, :((; json = (; choosetype = $choosetypefunc)))))
                    choosetypes[fname] = Pair{Expr,Any}(choosefunc_ex, choosetypefunc)
                else
                    choosetypes[fname] = nothing
                end
            end
            if !isempty(ntparams.args)
                Core.eval($__module__, :($StructUtils.fieldtags(::$StructUtils.StructStyle, ::Type{$$struct_name}) = $body))
            end
            if $LSP_DEV_MODE
                $_debug_[$(QuoteNode(struct_name))] = body => choosetypes
            end
        end)
    else
        fieldtags_ex = nothing
    end
    return method, fieldtags_ex
end

# This function is executed _after_ the type definition generated using `@interface`, and
# generatesan implementation of `StructUtils.choose_type` for custom type JSON
# deserialization for the fields of that type definition. Therefore, the code generated by
# `@interface` contains not the code generated by this function itself, but the call to this
# function (and also includes `Core.eval` which is the driver for code execution using it).
# This design is intentional, as accurate type dispatch generation requires the use of
# reflection such as `fieldtype`, and also needs to handle anonymous interface types
# that are potentially included in `@interface` definitions, making it difficult to perform
# this transformation completely symbolically, leading to the design of calling this
# function after the actual type definition.
function gen_choosetype_impl(StructType::Type, fname::Symbol)
    ftyp = fieldtype(StructType, fname)
    ftyp isa Union || return nothing
    choosetypebody = Expr(:block)
    lvname = gensym(:lv)
    vname = gensym(:x)
    push!(choosetypebody.args, :($vname = $lvname[]))
    cond_and_rets = Pair{Any,Any}[]
    res = add_choosetype_branch!(cond_and_rets, vname, ftyp)
    iszero(res & REQUIRES_CHOOSETYPE) && return nothing # JSON.jl shuold handle this field automatically
    errmsg = "Uncovered field type: $fname::$ftyp in $StructType"
    for (cond, ret) in cond_and_rets
        push!(choosetypebody.args, Expr(:(&&), cond, ret))
    end
    push!(choosetypebody.args, :(error($errmsg)))
    return Expr(:->, :($lvname::JSON.LazyValue), choosetypebody)
end

const JSONJL_NOTHING = 1<<0
const JSONJL_PRIMITIVE = 1<<1
const REQUIRES_CHOOSETYPE_IF_UNION = 1<<2
const REQUIRES_CHOOSETYPE = 1<<3
const CONTAINS_PARAMETRIC_DICT = 1<<4

function add_choosetype_branch!(cond_and_rets, vname::Symbol, @nospecialize ftyp)
    if ftyp isa Union
        abit = add_choosetype_branch!(cond_and_rets, vname, ftyp.a)
        bbit = add_choosetype_branch!(cond_and_rets, vname, ftyp.b)
        if !iszero(abit & CONTAINS_PARAMETRIC_DICT) && !iszero(bbit & CONTAINS_PARAMETRIC_DICT)
            error("`@interface` declaration with multiple Dict types unsupported")
        end
        abbit = abit | bbit
        if !iszero(abit & REQUIRES_CHOOSETYPE_IF_UNION) && !iszero(bbit & REQUIRES_CHOOSETYPE_IF_UNION)
            # e.g. require `choosetype` for `Union{MyType1,MyType2}`, `Union{Union{Nothing,MyType1},MyType2}`
            abbit |= REQUIRES_CHOOSETYPE
        end
        if (abbit & (JSONJL_PRIMITIVE | REQUIRES_CHOOSETYPE_IF_UNION)) == (JSONJL_PRIMITIVE | REQUIRES_CHOOSETYPE_IF_UNION)
            # e.g. require `choosetype` for `Union{String,MyType2}`
            abbit |= REQUIRES_CHOOSETYPE
        end
        return abbit
    end
    if ftyp <: Vector
        ftyp = ftyp::DataType
        cond_and_rets′ = Pair{Any,Any}[]
        a1name = gensym(:a1)
        eltype = ftyp.parameters[1]
        add_choosetype_branch!(cond_and_rets′, a1name, eltype)
        elcond = reduce(cond_and_rets′; init=false) do @nospecialize(acc), (cond, _)::Pair{Any,Any}
            Expr(:(||), acc, cond)
        end
        elcond === false && error(lazy"Unexpected parameterized vector type found in field declaration: $ftyp")
        push!(cond_and_rets, Pair{Any,Any}(
            :($vname isa Vector{Any} &&
                (isempty($vname) || let $a1name = first($vname); $elcond; end)),
            :(return $ftyp)))
        return REQUIRES_CHOOSETYPE_IF_UNION
    elseif ftyp <: Dict
        push!(cond_and_rets, Pair{Any,Any}(:($vname isa JSON.Object), :(return $ftyp)))
        return REQUIRES_CHOOSETYPE_IF_UNION | CONTAINS_PARAMETRIC_DICT
    elseif ftyp === Nothing
        push!(cond_and_rets, Pair{Any,Any}(:($vname isa Nothing), :(return Nothing)))
        return JSONJL_NOTHING
    elseif ftyp in (Any, Bool, Int, UInt, String)
        push!(cond_and_rets, Pair{Any,Any}(:($vname isa $ftyp), :(return $ftyp)))
        return JSONJL_PRIMITIVE
    elseif ftyp === Null
        # NOTE This should be `pushfirst!` to consider the case where `Nothing` is in a `Union`.
        # When `Nothing` and `Null` coexist, at the point this callback is called, it is confirmed
        # that `null` has been explicitly called as the field value, and in that case we should return `null`
        pushfirst!(cond_and_rets, Pair{Any,Any}(:($vname isa Nothing), :(return $Null)))
        return REQUIRES_CHOOSETYPE_IF_UNION
    elseif ftyp === URI
        # NOTE This should be `pushfirst!` to consider the case where `Nothing` is in a `Union`.
        # When `Nothing` and `Null` coexist, at the point this callback is called, it is confirmed
        # that `null` has been explicitly called as the field value, and in that case we should return `null`
        pushfirst!(cond_and_rets, Pair{Any,Any}(:($vname isa String), :(return $URI)))
        return REQUIRES_CHOOSETYPE_IF_UNION
    end
    condex = reduce(fieldnames(ftyp); init=true) do @nospecialize(acc), fname::Symbol
        if typeintersect(fieldtype(ftyp, fname), Nothing) === Nothing
            return acc # omittable
        end
        Expr(:(&&), acc, :(haskey($vname, $(QuoteNode(fname)))))
    end
    push!(cond_and_rets, Pair{Any,Any}(:($vname isa JSON.Object && $condex), :(return $ftyp)))
    return REQUIRES_CHOOSETYPE_IF_UNION
end

function process_anon_interface_def!( # Anonymous @interface
        toplevelblk::Expr, defex::Expr, __module__::Module, __source__::LineNumberNode
    )
    extended_fields = Dict{Symbol,Vector{Int}}()
    duplicated_fields = Int[]
    res, _ = process_interface_def!(toplevelblk, Expr(:block),
        extended_fields, duplicated_fields, defex, __module__, __source__, #=Name=#nothing)
    if !(isempty(extended_fields) && isempty(duplicated_fields))
        error("`Anonymous @interface` does not support extension", defex)
    end
    return res
end
