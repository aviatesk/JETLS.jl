using PrecompileTools

@setup_workload begin
    # Putting some things in `setup` can reduce the size of the
    # precompile file and potentially make loading faster.
    options = Parsers.Options()
    pos = 1
    int_val = "123"
    float_val = "123.45"
    bool_val = "true"
    @compile_workload begin
        # all calls in this block will be precompiled, regardless of whether
        # they belong to your package or not (on Julia 1.8 and higher)
        for (T, val) in ((String, int_val), (Int32, int_val), (Int64, int_val), (Float64, float_val), (Bool, bool_val))
            len = length(val)
            for buf in (codeunits(val), Vector(codeunits(val)))
                Parsers.xparse(T, buf, pos, len, options)
                Parsers.xparse(T, buf, pos, len, options, Any)
            end
        end

        for (T, val) in ((Int32, int_val), (Int64, int_val), (Float64, float_val), (Bool, bool_val))
            for buf in (val, Vector(codeunits(val)))
                try
                    Parsers.parse(T, buf, options)
                catch
                end
                Parsers.tryparse(T, buf, options)
            end
        end
    end
end
