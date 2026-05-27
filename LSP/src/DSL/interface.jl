const _interface_defs_ = Dict{Symbol,Expr}()

# Register a fallback docstring (with field docs) for `name`, unless a top-level docstring
# is already registered (e.g. via an outer `@doc`). Without it an `@interface` carrying
# only field docstrings produces no `MultiDoc` entry at all, so `REPL.fielddoc(T, field)`
# and JETLS's `lookup_field_doc` — which both read field docs out of
# `MultiDoc.docs[Union{}].data[:fields]` — can't surface them, and `REPL.fielddoc` falls
# back to the noisy `` `T` has fields ... `` placeholder.
# The body roughly mirrors `REPL.summarize` so `?T` keeps producing a Julia-base-like summary.
#
# `fielddocs` is typed `Dict{Symbol,Any}` to match Julia base's docsystem convention
# (`Base.Docs.fielddocs` itself builds `:fields` as `Dict{Symbol,Any}).
function attach_fallback_doc!(__module__::Module, name::Symbol,
                              fielddocs::Dict{Symbol,Any},
                              linenumber::Int, path::AbstractString)
    binding = Base.Docs.Binding(__module__, name)
    md = Base.Docs.meta(__module__)
    if haskey(md, binding) && !isempty(md[binding].docs)
        return nothing
    end
    data = Dict{Symbol,Any}(
        :module => __module__,
        :linenumber => linenumber,
        :path => path,
        :binding => binding,
        :typesig => Union{},
        :fields => fielddocs,
    )
    summary = build_struct_summary(__module__, name)
    str = Base.Docs.docstr(Core.svec(summary), data)
    Base.Docs.doc!(__module__, binding, str, Union{})
    return nothing
end

function build_struct_summary(__module__::Module, name::Symbol)
    isdefinedglobal(__module__, name) || return ""
    T = getglobal(__module__, name)
    T isa DataType || return ""
    io = IOBuffer()
    println(io, "# Summary")
    println(io, "```")
    print(io, Base.isabstracttype(T) ? "abstract type " :
              Base.ismutabletype(T)  ? "mutable struct " :
              Base.isstructtype(T)   ? "struct " : "primitive type ")
    println(io, T)
    println(io, "```")
    if !Base.isabstracttype(T) && !isempty(fieldnames(T))
        println(io, "# Fields")
        println(io, "```")
        pad = maximum(length(string(f)) for f in fieldnames(T))
        for (f, t) in zip(fieldnames(T), fieldtypes(T))
            println(io, rpad(f, pad), " :: ", t)
        end
        println(io, "```")
    end
    if supertype(T) !== Any
        println(io, "# Supertype Hierarchy")
        println(io, "```")
        Base.show_supertypes(io, T)
        println(io)
        println(io, "```")
    end
    return String(take!(io))
end

function collect_field_docs(structbody::Expr)
    fielddocs = Dict{Symbol,Any}()
    last_doc = nothing
    for arg in structbody.args
        if arg isa String
            last_doc = arg
        elseif arg isa LineNumberNode
            continue
        else
            fname = extract_fieldname(arg)
            if fname !== nothing && last_doc !== nothing
                fielddocs[fname] = last_doc
                last_doc = nothing
            end
        end
    end
    return fielddocs
end

function extract_fieldname(@nospecialize(arg))
    if arg isa Symbol
        return arg
    elseif Meta.isexpr(arg, :(::))
        cand = arg.args[1]
        cand isa Symbol && return cand
    elseif Meta.isexpr(arg, :(=))
        decl = arg.args[1]
        if decl isa Symbol
            return decl
        elseif Meta.isexpr(decl, :(::))
            cand = decl.args[1]
            cand isa Symbol && return cand
        end
    end
    return nothing
end

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
    omittable_fields = Set{Symbol}()
    extended_fields = Dict{Symbol,Vector{Int}}()
    duplicated_fields = Int[]
    if extends !== nothing
        for extend in extends
            is_method_dispatchable |= extend === :RequestMessage || extend === :NotificationMessage
            add_extended_interface!(toplevelblk, structbody,
                                    omittable_fields,
                                    extended_fields,
                                    duplicated_fields,
                                    extend,
                                    __source__)
        end
    end
    _, method = process_interface_def!(toplevelblk, structbody,
                                       omittable_fields,
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
                                omittable_fields::Set{Symbol},
                                extended_fields::Dict{Symbol,Vector{Int}},
                                duplicated_fields::Vector{Int},
                                defex::Expr,
                                __source__::LineNumberNode,
                                Name::Union{Symbol,Nothing})
    method = _process_interface_def!(toplevelblk, structbody, omittable_fields, extended_fields, duplicated_fields, defex, __source__)
    deleteat!(structbody.args, duplicated_fields)
    is_anon = Name === nothing
    if is_anon
        # Name = Symbol("AnonymousInterface", string(__source__)) # XXX this doesn't work probably due to Julia internal bug
        Name = Symbol("AnonymousInterface", gensym())
    end
    structdef = Expr(:struct, false, Name, structbody)
    kwdef = Expr(:macrocall, GlobalRef(Base, Symbol("@kwdef")), __source__, structdef) # `@kwdef` will attach `Core.__doc__` automatically
    push!(toplevelblk.args, kwdef)
    fielddocs = collect_field_docs(structbody)
    if !isempty(fielddocs)
        fielddocs_ex = Expr(:call, :($Dict{$Symbol,$Any}))
        for (k, v) in fielddocs
            push!(fielddocs_ex.args, :($(QuoteNode(k)) => $v))
        end
        srcfile = string(something(__source__.file, "none"))
        push!(toplevelblk.args,
            :($(GlobalRef(@__MODULE__, :attach_fallback_doc!))(
                @__MODULE__, $(QuoteNode(Name)), $fielddocs_ex,
                $(__source__.line), $srcfile)))
    end
    if !isempty(omittable_fields)
        omitempties = Tuple(omittable_fields)
        push!(toplevelblk.args, :(StructTypes.omitempties(::Type{$Name}) = $omitempties))
        # Restrict the omitempties check to `=== nothing`. StructTypes' default
        # `isempty` also drops empty `Vector`/`String`/`Dict`, which would erase a
        # legitimate `result = T[]` from a response and produce a JSON object with
        # neither `result` nor `error` — VSCode rejects that shape.
        push!(toplevelblk.args,
            :(@inline StructTypes.isempty(::Type{$Name}, x) = x === nothing))
    end
    if is_anon
        push!(toplevelblk.args, :(Base.convert(::Type{$Name}, nt::NamedTuple) = $Name(; nt...)))
    end
    if !is_anon
        push!(toplevelblk.args, :($(GlobalRef(@__MODULE__, :_interface_defs_))[$(QuoteNode(Name))] = $(QuoteNode(structbody))))
    end
    return Name, method
end

function add_extended_interface!(toplevelblk::Expr, structbody::Expr,
                                 omittable_fields::Set{Symbol},
                                 extended_fields::Dict{Symbol,Vector{Int}},
                                 duplicated_fields::Vector{Int},
                                 extend::Symbol,
                                __source__::LineNumberNode)
    return _process_interface_def!(toplevelblk, structbody,
                                   omittable_fields,
                                   extended_fields,
                                   duplicated_fields,
                                   _interface_defs_[extend],
                                   __source__;
                                   extending = true)
end

function _process_interface_def!(toplevelblk::Expr, structbody::Expr,
                                 omittable_fields::Set{Symbol},
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
        omittable = false
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
            if Meta.isexpr(fieldtype, :curly) && fieldtype.args[1] === :Union
                for i = 2:length(fieldtype.args)
                    ufty = fieldtype.args[i]
                    if ufty === :Nothing
                        omittable = true
                    end
                end
            end
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
        if omittable
            push!(omittable_fields, fieldname)
        end
        if haskey(extended_fields, fieldname)
            append!(duplicated_fields, extended_fields[fieldname])
            omittable || delete!(omittable_fields, fieldname)
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
    omittable_fields = Set{Symbol}()
    extended_fields = Dict{Symbol,Vector{Int}}()
    duplicated_fields = Int[]
    res, _ = process_interface_def!(toplevelblk, Expr(:block),
        omittable_fields, extended_fields, duplicated_fields, defex, __source__, #=Name=#nothing)
    if !(isempty(extended_fields) && isempty(duplicated_fields))
        error("`Anonymous @interface` does not support extension", defex)
    end
    return res
end
