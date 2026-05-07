using PrecompileTools

@setup_workload begin
    # Putting some things in `setup` can reduce the size of the
    # precompile file and potentially make loading faster.
    options = Parsers.Options()
    pos = 1
    val = "123"
    len = length(val)
    @compile_workload begin
        # all calls in this block will be precompiled, regardless of whether
        # they belong to your package or not (on Julia 1.8 and higher)
        for T in (String, Int32, Int64, Float64, BigFloat, Dates.Date, Dates.DateTime, Dates.Time, Bool)
            for buf in (codeunits(val), Vector(codeunits(val)))
                Parsers.xparse(T, buf, pos, len, options)
                Parsers.xparse(T, buf, pos, len, options, Any)
            end
        end

        for T in (Int32, Int64, Float64, BigFloat, Dates.Date, Dates.DateTime, Dates.Time, Bool)
            for buf in (val, SubString(val, 1:3), Vector(codeunits(val)), view(Vector(codeunits(val)), 1:3))
                try
                    Parsers.parse(T, buf, options)
                catch
                end
                Parsers.tryparse(T, buf, options)
            end
        end
    end
end
