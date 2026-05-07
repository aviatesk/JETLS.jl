# must be outermost layer
function Result(parser)
    function(conf::AbstractConf{T}, source, pos, len, ::Type{RT}=T) where {T, RT}
        startpos = pos
        code = SUCCESS
        b = eof(source, pos, len) ? 0x00 : peekbyte(source, pos)
        # For almost all RTs, poslen(RT, ...) will return a Parsers.PosLen. For non-string
        # types, this pl is only used for internal bookkeeping, for strings however
        # we allow the user to provide a custom PosLen type (like PosLen31) in which case
        # they need to overload this method to get the instance here.
        pl = poslen(RT, pos, 0)
        pos, code, pl, x = parser(conf, source, pos, len, b, code, pl)
        tlen = pos - startpos
        if valueok(code)
            y = x::RT
            return Result{RT}(code, tlen, y)
        elseif isgreedy(T)
            z = x::RT
            return Result{RT}(code, tlen, z)
        else
            return Result{RT}(code, tlen)
        end
    end
end

# Component design:
  # ComponentFunction: innermost layer/function; f(T, source, pos, len, b, code, pl) -> pos, code, pl, x
    # arguments are all dynamic, runtime parameters
  # ParserFunction: next innermost layer; f(::ComponentFunction) -> ComponentFunction
    # this layer allows "chaining" together however many ComponentFunctions as desired
  # ParserModifyingFunction: outermost layer; f(args...) -> ParserFunction
    # allows passing Options-time/static parameters down to customize the ComponentFunction behavior

emptysentinel(opts::Options) = emptysentinel(opts.flags.checksentinel && isempty(opts.sentinel))
function emptysentinel(checksent::Bool)
    function(parser)
        function checkemptysentinel(conf::AbstractConf{T}, source, pos, len, b, code, pl) where {T}
            pos, code, pl, x = parser(conf, source, pos, len, b, code, pl)
            if checksent && pl.len == 0 && (!isgreedy(T) || !quoted(code))
                code &= ~(OK | INVALID)
                code |= SENTINEL
                pl = withmissing(pl)
            end
            return pos, code, pl, x
        end
    end
end

# just ' ' and '\t'
iswh(b) = b == UInt8(' ') || b == UInt8('\t')
iswh(b, spacedelim, tabdelim) = (!spacedelim && b == UInt8(' ')) || (!tabdelim && b == UInt8('\t'))

whitespace(opts::Options) = whitespace(opts.flags.spacedelim, opts.flags.tabdelim, opts.flags.stripquoted, opts.flags.stripwhitespace)
function whitespace(spacedelim, tabdelim, stripquoted, stripwh)
    function(parser)
        function stripwhitespace(conf::AbstractConf{T}, source, pos, len, b, code, pl) where {T}
            # strip leading whitespace
            if !eof(source, pos, len) && (
                # pre-quotes, if delim is not whitespace
                # note that we strip even if user didn't ask in order to consume any whitespace
                # that might be present before the oq; we just need to take care when resetting
                # the pl to account for whether the user actually asked to strip or not
                !quoted(code) ||
                # within quotes, if non-string or user asked to strip quoted
                (quoted(code) && (!isgreedy(T) || stripquoted))
            )
                while iswh(b, spacedelim, tabdelim)
                    pos += 1
                    incr!(source)
                    if eof(source, pos, len)
                        code |= EOF
                        break
                    end
                    b = peekbyte(source, pos)
                end
                # for greedy, reset poslen if we're stripping whitespace
                if isgreedy(T) && (
                    # pre-quotes, if user asked to strip
                    (!quoted(code) && stripwh) ||
                    # within quotes, if user asked to strip quoted
                    (quoted(code) && stripquoted)
                )
                    pl = poslen(typeof(pl), pos, 0)
                end
            end
            pos, code, pl, x = parser(conf, source, pos, len, b, code, pl)
            # strip trailing whitespace
            if !eof(source, pos, len) && (
                # post non-quoted value, if delim is not whitespace, and non-string
                # (string already stripped in finddelimiter or findeof)
                (!quoted(code) && !isgreedy(T)) ||
                # post-quoted value, if delim is not whitespace
                quoted(code)
            )
                b = peekbyte(source, pos)
                while iswh(b, spacedelim, tabdelim)
                    pos += 1
                    incr!(source)
                    if eof(source, pos, len)
                        code |= EOF
                        return pos, code, pl, x
                    end
                    b = peekbyte(source, pos)
                end
            end
            return pos, code, pl, x
        end
    end
end

function findendquoted(::Type{T}, source, pos, len, b, code, pl, isquoted, cq, e, stripquoted) where {T}
    # for quoted fields, find the closing quote character
    # we should be positioned at the correct place to find the closing quote character if everything is as it should be
    # if we don't find the quote character immediately, something's wrong, so mark INVALID
    # for greedy (strings), we're positioned at the first byte after opening quote token.
    # we need to account for stripquoted by keeping track of lastnonwhitepos
    if isquoted
        lastnonwhitepos = pos
        same = cq == e
        first = true
        while true
            match, pos = checktoken(source, pos, len, b, e)
            if same && match
                # cq = '"', e = '"', and b = '"', so we might be done
                # e is either followed by cq or it *is* cq
                # checktoken already incremented pos for us
                if eof(source, pos, len)
                    # we're done! cq was last possible byte
                    code |= EOF
                    if !first && !isgreedy(T)
                        # this means we've parsed something like a number,
                        # then immediately expected to find the closing quote
                        # character, but didn't (!first), so something's wrong
                        code |= INVALID
                    end
                    pl = withlen(pl, lastnonwhitepos - pl.pos)
                    break
                end
                # check if next byte is cq
                b = peekbyte(source, pos)
                match, pos = checktoken(source, pos, len, b, cq)
                if !match
                    # we're done! e wasn't followed by cq
                    if !first && !isgreedy(T)
                        code |= INVALID
                    end
                    pl = withlen(pl, lastnonwhitepos - pl.pos)
                    break
                end
                # this means we had e followed by cq
                # so the next byte is escaped
                code |= ESCAPED_STRING
                pl = withescaped(pl)
            elseif match
                # e, so next byte is escaped
                code |= ESCAPED_STRING
                pl = withescaped(pl)
                if eof(source, pos, len)
                    code |= EOF | INVALID_QUOTED_FIELD
                    break
                end
                pos += 1
                incr!(source)
            else
                if !same
                    # not e, so check for cq
                    match, pos = checktoken(source, pos, len, b, cq)
                    if match
                        # we're done! found cq
                        if eof(source, pos, len)
                            code |= EOF
                        end
                        if !first && !isgreedy(T)
                            code |= INVALID
                        end
                        pl = withlen(pl, lastnonwhitepos - pl.pos)
                        break
                    end
                end
                # we didn't match e or cq, so we're not done
                pos += 1
                incr!(source)
            end
            wh = iswh(b)
            lastnonwhitepos = stripquoted ? (wh ? lastnonwhitepos : pos) : pos
            if eof(source, pos, len)
                code |= EOF | INVALID_QUOTED_FIELD
                pl = withlen(pl, lastnonwhitepos - pl.pos)
                break
            end
            first = false
            b = peekbyte(source, pos)
        end
    end
    return pos, code, pl, pl
end

quoted(opts::Options) = quoted(opts.flags.checkquoted, opts.oq, opts.cq, opts.e, opts.flags.stripquoted)
function quoted(checkquoted, oq, cq, e, stripquoted)
    function(parser)
        function findquoted(conf::AbstractConf{T}, source, pos, len, b, code, pl) where {T}
            isquoted = false
            if checkquoted && !eof(source, pos, len)
                isquoted, pos = checktoken(source, pos, len, b, oq)
            end
            if isquoted
                code |= QUOTED
                pl = poslen(typeof(pl), pos, 0)
                if eof(source, pos, len)
                    # "dangling" oq, not valid
                    code |= INVALID_QUOTED_FIELD | EOF
                else
                    b = peekbyte(source, pos)
                end
            end
            pos, code, pl, x = parser(conf, source, pos, len, b, code, pl)
            if isgreedy(T) && isquoted
                return pos, code, pl, x
            end
            if eof(source, pos, len)
                if isquoted
                    # if we detected a quote character, it's an invalid quoted field due to eof in the middle
                    code |= INVALID_QUOTED_FIELD | EOF
                end
                return pos, code, pl, x
            end
            b = peekbyte(source, pos)
            pos, code, pl, _ = findendquoted(T, source, pos, len, b, code, pl, isquoted, cq, e, stripquoted)
            return pos, code, pl, x
        end
    end
end

sentinel(opts::Options) = sentinel(opts.flags.checksentinel, opts.sentinel)
function sentinel(chcksentinel, sentinel)
    function(parser)
        function checkforsentinel(conf::AbstractConf{T}, source, pos, len, b, code, pl) where {T}
            match, sentinelpos = (!chcksentinel || isempty(sentinel) || eof(source, pos, len)) ? (false, 0) : checktokens(source, pos, len, b, sentinel)
            pos, code, pl, x = parser(conf, source, pos, len, b, code, pl)
            # @show match, sentinelpos, pos, pl
            if match && sentinelpos > (pl.pos + pl.len - 1)
                # if we matched a sentinel value that was as long or longer than our type value
                code &= ~OK
                if isgreedy(T)
                    pl = withlen(pl, sentinelpos - pl.pos)
                else
                    code &= ~(INVALID | EOF | OVERFLOW | INEXACT)
                    pos = sentinelpos
                    fastseek!(source, pos - 1)
                end
                code |= SENTINEL
                pl = withmissing(pl)
                if eof(source, pos, len)
                    code |= EOF
                end
            end
            return pos, code, pl, x
        end
    end
end

function finddelimiter(::Type{T}, source, pos, len, b, code, pl, delim, ignorerepeated, cmt, ignoreemptylines, stripwhitespace) where {T}
    # now we check for a delimiter; if we don't find it, keep parsing until we do
    # for greedy strings, we need to keep track of the last non-whitespace character
    # if we're stripping whitespace, but note we've already skipped leading whitespace
    lastnonwhitepos = pos
    while true
        if eof(source, pos, len)
            code |= EOF
            break
        end
        if !ignorerepeated
            # we're checking for a single appearance of a delimiter
            match, pos = checktoken(source, pos, len, b, delim)
            if match
                code |= DELIMITED
                break
            end
        else
            # keep parsing as long as we keep matching delims/newlines
            matched = false
            matchednewline = false
            while true
                match, pos = checktoken(source, pos, len, b, delim)
                if match
                    matched = true
                    code |= DELIMITED
                elseif !matchednewline && b == UInt8('\n')
                    matchednewline = matched = true
                    pos += 1
                    incr!(source)
                    pos = checkcmtemptylines(source, pos, len, cmt, ignoreemptylines)
                    code |= NEWLINE | ifelse(eof(source, pos, len), EOF, SUCCESS)
                elseif !matchednewline && b == UInt8('\r')
                    matchednewline = matched = true
                    pos += 1
                    incr!(source)
                    if !eof(source, pos, len) && peekbyte(source, pos) == UInt8('\n')
                        pos += 1
                        incr!(source)
                    end
                    pos = checkcmtemptylines(source, pos, len, cmt, ignoreemptylines)
                    code |= NEWLINE | ifelse(eof(source, pos, len), EOF, SUCCESS)
                else
                    break
                end
                if eof(source, pos, len)
                    if matched && !matchednewline
                        code |= EOF
                    end
                    break
                end
                b = peekbyte(source, pos)
            end
            if matched || eof(source, pos, len)
                break
            end
        end
        # didn't find delimiter, but let's check for a newline character
        if b == UInt8('\n')
            pos += 1
            incr!(source)
            pos = checkcmtemptylines(source, pos, len, cmt, ignoreemptylines)
            code |= NEWLINE | ifelse(eof(source, pos, len), EOF, SUCCESS)
            break
        elseif b == UInt8('\r')
            pos += 1
            incr!(source)
            if !eof(source, pos, len) && peekbyte(source, pos) == UInt8('\n')
                pos += 1
                incr!(source)
            end
            pos = checkcmtemptylines(source, pos, len, cmt, ignoreemptylines)
            code |= NEWLINE | ifelse(eof(source, pos, len), EOF, SUCCESS)
            break
        end
        if !isgreedy(T) || quoted(code)
            # didn't find delimiter or newline, so we're invalid, keep parsing until we find delimiter, newline, or len
            code |= INVALID_DELIMITER
        end
        pos += 1
        incr!(source)
        if !quoted(code)
            lastnonwhitepos = stripwhitespace ? (iswh(b) ? lastnonwhitepos : pos) : pos
        end
        if eof(source, pos, len)
            code |= EOF
            break
        end
        b = peekbyte(source, pos)
    end
    if !quoted(code)
        pl = withlen(pl, lastnonwhitepos - pl.pos)
    end
    return pos, code, pl, pl
end

delimiter(opts::Options) = delimiter(opts.flags.checkdelim, opts.delim, opts.flags.ignorerepeated, opts.cmt, opts.flags.ignoreemptylines, opts.flags.stripwhitespace)
function delimiter(checkdelim, delim, ignorerepeated, cmt, ignoreemptylines, stripwhitespace)
    function(parser)
        function _finddelimiter(conf::AbstractConf{T}, source, pos, len, b, code, pl) where {T}
            pos, code, pl, x = parser(conf, source, pos, len, b, code, pl)
            if eof(source, pos, len) || !checkdelim || delimited(code) || newline(code) # greedy case
                return pos, code, pl, x
            end
            b = peekbyte(source, pos)
            pos, code, pl, _ = finddelimiter(T, source, pos, len, b, code, pl, delim, ignorerepeated, cmt, ignoreemptylines, stripwhitespace)
            return pos, code, pl, x
        end
    end
end

function typeparser(opts::Options)
    function(conf::AbstractConf{T}, source, pos, len, b, code, pl) where {T}
        return typeparser(conf, source, pos, len, b, code, pl, opts)
    end
end

# backwards compat
function typeparser(conf, source, pos, len, b, code, opts::Options)
    pos, code, pl, x = typeparser(conf, source, pos, len, b, code, poslen(pos, 0), opts)
    return x, code, pos
end

function typeparser(::Type{T}, source, pos, len, b, code, opts::Options) where {T}
    pos, code, pl, x = typeparser(DefaultConf{T}(), source, pos, len, b, code, poslen(pos, 0), opts)
    return x, code, pos
end

typeparser(::Type{T}, source, pos, len, b, code, pl) where {T} =
    typeparser(DefaultConf{T}(), source, pos, len, b, code, pl, Options())