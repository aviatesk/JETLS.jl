macro namespace(exs...)
    nexs = length(exs)
    nexs == 2 || error("`@namespace` expected 2 arguments: ", exs)
    namedecl, defs = exs
    Meta.isexpr(namedecl, :(::)) || error("Invalid `@namespace` syntax: ", namedecl)
    Meta.isexpr(defs, :block) || error("Invalid `@namespace` syntax: ", defs)

    toplevelblk = Expr(:toplevel)
    Name, Type = namedecl.args
    modbody = Expr(:block)
    modex = Expr(:module, false, Name, modbody)
    push!(toplevelblk.args, modex)
    push!(toplevelblk.args, Expr(:macrocall, GlobalRef(Base, Symbol("@__doc__")), __source__, Name))
    curline = __source__
    for def in defs.args
        if def isa LineNumberNode
            push!(modbody.args, def)
            curline = def
            continue
        elseif def isa String
            error("hit")
        end
        doc = nothing
        if Meta.isexpr(def, :macrocall)
            if def.args[1] === GlobalRef(Core, Symbol("@doc"))
                doc = def.args[3]
                doc isa String || error("Invalid `@namespace` syntax: ", def)
                def = def.args[end]
            else
                error("Unsupported syntax found in `@namespace`: ", def)
            end
        end
        Meta.isexpr(def, :(=)) || error("Invalid `@namespace` syntax: ", def)
        name, val = def.args
        name isa Symbol || error("Invalid `@namespace` syntax: ", def)
        push!(modbody.args, :(const $name = $val))
        if doc !== nothing
            push!(modbody.args, Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), curline, doc, name))
        end
    end
    thismodname = nameof(__module__)
    push!(modbody.args, :(using ..$thismodname: $Type))
    push!(modbody.args, :(const Ty = $Type))

    push!(toplevelblk.args, :(push!($(GlobalRef(@__MODULE__, :exports)), $(QuoteNode(Name)))))
    push!(toplevelblk.args, :(return $Name))

    return esc(toplevelblk)
end
