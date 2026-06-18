const DEFAULT_TRUE = "true"
const DEFAULT_FALSE = "false"

@inline function typeparser(::AbstractConf{Bool}, source, pos, len, b, code, pl, options::Options)
    x = false
    trues = options.trues
    falses = options.falses
    if trues === nothing
        check, pos = checktoken(source, pos, len, b, DEFAULT_TRUE)
        if check
            x = true
            code |= OK
            eof(source, pos, len) && (code |= EOF)
            @goto done
        else
            intpos, intcode, intpl, intx = typeparser(DefaultConf{UInt8}(), source, pos, len, b, code, pl, options)
            if ok(intcode) && intx < 0x02
                x = intx == 0x01
                code = intcode
                pos = intpos
                pl = intpl
                @goto done
            end
        end
    else
        check, pos = checktokens(source, pos, len, b, trues, true)
        if check
            x = true
            code |= OK
            eof(source, pos, len) && (code |= EOF)
            @goto done
        end
    end
    if falses === nothing
        check, pos = checktoken(source, pos, len, b, DEFAULT_FALSE)
        if check
            x = false
            code |= OK
            eof(source, pos, len) && (code |= EOF)
            @goto done
        end
    else
        check, pos = checktokens(source, pos, len, b, falses, true)
        if check
            x = false
            code |= OK
            eof(source, pos, len) && (code |= EOF)
            @goto done
        end
    end
    code |= INVALID | (eof(source, pos, len) ? EOF : SUCCESS)

@label done
    return pos, code, PosLen(pl.pos, pos - pl.pos), x
end