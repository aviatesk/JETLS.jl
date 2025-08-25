function get_type_for_range(inferred_tree::JL.SyntaxTree, rng::UnitRange{<:Integer})
    typ = nothing
    JETLS.traverse(inferred_tree) do st::JL.SyntaxTree
        if JS.byte_range(st) == rng
            if hasproperty(st, :type)
                if typ === nothing
                    typ = st.type
                else
                    typ = CC.tmerge(st.type, typ)
                end
            else
                return nothing
            end
        end
    end
    return typ
end

function select_inferrable_target(st0::JL.SyntaxTree, offset::Int)
    bas = byte_ancestors(st0, offset)
    isempty(bas) && return nothing
    target = first(bas)
    for i = 2:length(bas)
        basᵢ = bas[i]
        if (JS.kind(basᵢ) === JS.K"." && basᵢ[2] === target) # e.g. don't allow jumps to `tmeet` from `Base.Compi│ler.tmeet`
            target = basᵢ
        else
            break
        end
    end
    return target
end
