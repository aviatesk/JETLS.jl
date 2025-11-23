# backward compatibilty

@static if VERSION < v"1.1"
    function fieldtypes(T::Type)
        ntuple(fieldcount(T)) do idx
            fieldtype(T, idx)
        end
    end
end

# NOTE: for 1.0 compat
@static if !@isdefined(hasfield)
    function hasfield(T::Type, name::Symbol)
        return fieldindex(T, name, false) > 0
    end
end
