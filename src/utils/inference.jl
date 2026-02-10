function get_type_for_range(inferred_tree::JL.SyntaxTree, rng::UnitRange{<:Integer})
    typ = Ref{Any}(nothing)
    traverse(inferred_tree) do st5::JL.SyntaxTree
        if is_from_user_ast(JS.flattened_provenance(st5)) && JS.byte_range(st5) == rng
            if hasproperty(st5, :type)
                ntyp = st5.type
                if typ[] === nothing
                    typ[] = ntyp
                else
                    typ[] = CC.tmerge(ntyp, typ[])
                end
            end
        end
    end
    return typ[]
end

function get_type_for_macroexpansion(
        inferred_tree::JL.SyntaxTree, rng::UnitRange{<:Integer}
    )
    typ = Ref{Any}(nothing)
    traverse(inferred_tree) do st5::JL.SyntaxTree
        JS.kind(st5) === JS.K"call" || return
        hasproperty(st5, :type) || return
        provs = JS.flattened_provenance(st5)
        length(provs) >= 2 || return
        fprov = first(provs)
        JS.kind(fprov) === JS.K"macrocall" || return
        JS.byte_range(fprov) == rng || return
        ntyp = st5.type
        ntyp isa Core.Const && return
        typ[] = ntyp
    end
    return typ[]
end

function get_inferrable_tree(
        st0::JS.SyntaxTree, mod::Module;
        caller::AbstractString = "get_inferrable_tree"
    )
    (; ctx3, st3) = try
        jl_lower_for_scope_resolution(mod, st0; trim_error_nodes=false, recover_from_macro_errors=false)
    catch err
        JETLS_DEBUG_LOWERING && @warn "Error in lowering ($caller)" err
        JETLS_DEBUG_LOWERING && Base.show_backtrace(stderr, catch_backtrace())
        return nothing
    end
    return (; ctx3, st3)
end

function select_inferrable_target(st0::JL.SyntaxTree, offset::Int)
    bas = byte_ancestors(st0, offset)
    isempty(bas) && return nothing
    target = first(bas)
    for i = 2:length(bas)
        basᵢ = bas[i]
        if (JS.kind(basᵢ) === JS.K"." && basᵢ[2] === target)
            target = basᵢ
        else
            break
        end
    end
    return target
end
