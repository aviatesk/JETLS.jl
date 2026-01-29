function get_type_for_range(inferred_tree::JL.SyntaxTree, rng::UnitRange{<:Integer})
    typ = Ref{Any}(nothing)
    traverse(inferred_tree) do st::JL.SyntaxTree
        if JS.byte_range(st) == rng
            if hasproperty(st, :type)
                ntyp = st.type
                if typ[] === nothing
                    typ[] = ntyp
                else
                    typ[] = CC.tmerge(ntyp, typ[])
                end
            else
                return nothing
            end
        end
    end
    return typ[]
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
