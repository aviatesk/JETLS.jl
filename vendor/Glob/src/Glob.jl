__precompile__()

module Glob

import Base: readdir, show, occursin

export glob, @fn_str, @fn_mstr, @glob_str, @glob_mstr

if !@isdefined(var"@something")
macro something(args...)
    noth = GlobalRef(Base, :nothing)
    something = GlobalRef(Base, :something)
    expr = :($something($noth))
    for arg in reverse(args)
        val = gensym()
        expr = quote
            $val = $(esc(arg))
            if !isnothing($val)
                $something($val)
            else
                $expr
            end
        end
    end
    return expr
end
end

const CASELESS = 1 << 0 # i -- Do case-insensitive matching
const PERIOD   = 1 << 1 # p -- A leading period (.) character must be exactly matched by a period (.) character
const NOESCAPE = 1 << 2 # e -- Do not treat backslash (\) as a special character
const PATHNAME = 1 << 3 # d -- Slash (/) character must be exactly matched by a slash (/) character
const EXTENDED = 1 << 4 # x -- Support extended (bash-like) features

struct FilenameMatch{S<:AbstractString}
    pattern::S
    options::UInt32
    FilenameMatch{S}(pattern, options) where {S} = new{S}(pattern, options)
end
function FilenameMatch(pattern::S, options::Integer=0) where {S<:AbstractString}
    return FilenameMatch{S}(pattern, options)
end
function FilenameMatch(pattern::AbstractString, flags::AbstractString)
    options = 0
    for f in flags
        options |= (f == 'i') ? CASELESS :
                   (f == 'p') ? PERIOD   :
                   (f == 'e') ? NOESCAPE :
                   (f == 'd') ? PATHNAME :
                   (f == 'x') ? EXTENDED :
                   error("unknown Filename Matcher flag: $f")
    end
    return FilenameMatch(pattern, options)
end

"""
    fn"pattern"ipedx

Returns a `Glob.FilenameMatch` object, which can be used with `ismatch()` or `occursin()`. Available flags are:

* `i` = `CASELESS` : Performs case-insensitive matching
* `p` = `PERIOD` : A leading period (`.`) character must be exactly matched by a period (`.`) character (not a `?`, `*`, or `[]`). A leading period is a period at the beginning of a string, or a period after a slash if PATHNAME is true.
* `e` = `NOESCAPE` : Do not treat backslash (`\`) as a special character (in extended mode, this only outside of `[]`)
* `d` = `PATHNAME` : A slash (`/`) character must be exactly matched by a slash (`/`) character (not a `?`, `*`, or `[]`), "**/" matches zero or more directories (globstar)
* `x` = `EXTENDED` : Additional features borrowed from newer shells, such as `bash` and `tcsh`
    * Backslash (`\``) characters in `[]` groups escape the next character
"""
macro fn_str(pattern, flags...) FilenameMatch(pattern, flags...) end
macro fn_mstr(pattern, flags...) FilenameMatch(pattern, flags...) end

function show(io::IO, fn::FilenameMatch)
    print(io, "fn\"", fn.pattern, '"')
    (fn.options & CASELESS) != 0 && print(io, 'i')
    (fn.options & PERIOD  ) != 0 && print(io, 'p')
    (fn.options & NOESCAPE) != 0 && print(io, 'e')
    (fn.options & PATHNAME) != 0 && print(io, 'd')
    (fn.options & EXTENDED) != 0 && print(io, 'x')
    nothing
end

function occursin(fn::FilenameMatch, s::AbstractString)
    pattern = fn.pattern
    caseless = (fn.options & CASELESS) != 0
    periodfl = (fn.options & PERIOD  ) != 0
    noescape = (fn.options & NOESCAPE) != 0
    pathname = (fn.options & PATHNAME) != 0
    extended = (fn.options & EXTENDED) != 0

    mi = firstindex(pattern) # current index into pattern
    i = firstindex(s) # current index into s
    starmatch = i
    star = 0
    globstarmatch = 0  # Track globstar match position for directory-level backtracking
    globstar_mi = 0    # Pattern index after globstar
    globstar_period = false  # Track if period was encountered during globstar
    globstar_star = 0  # Saved star state when entering globstar
    globstar_starmatch = i  # Saved starmatch state when entering globstar
    period = periodfl
    after_slash = true  # Track if previous pattern char was '/' (or at start)
    while true
        matchnext = iterate(s, i)
        matchnext === nothing && break
        patnext = iterate(pattern, mi)
        if patnext === nothing
            # String characters left to match, but no pattern left
            match = false
        else
            mc, mi = patnext
            if mc == '*'
                # Check if this is a **/ globstar pattern
                # Conditions: after '/' (or at start), followed by '*/'
                # Use iterate to peek ahead without string allocation
                if pathname && after_slash
                    peek1_c, peek1_s = @something iterate(pattern, mi) @goto no_globstar
                    if peek1_c == '*'
                        peek2_c, peek2_s = @something iterate(pattern, peek1_s) return true # this is trailing_globstar
                        if peek2_c == '/'
                            # This is **/ globstar pattern - use directory-level backtracking
                            mi = peek2_s  # Skip past **/
                            globstarmatch = i
                            globstar_mi = mi
                            # Save current star state for restoration on globstar backtrack
                            globstar_star = star
                            globstar_starmatch = starmatch
                            after_slash = true  # After **/, we're effectively after a /
                            c = '/'  # Fake previous character as /
                            match = true
                            continue
                        end
                    end
                end
                @label no_globstar
                # Not a globstar pattern - treat as regular *
                # Even if it's **, each * will be processed separately
                starmatch = i # backup the current search index
                star = mi
                c, _ = matchnext # peek-ahead
                if period & (c == '.')
                    return false # * does not match leading .
                end
                after_slash = false
                match = true
            else
                c, i = matchnext
                if mc == '['
                    mi, valid, match = _match(pattern, mi, c, caseless, extended)
                    if pathname & valid & match & (c == '/')
                        match = false
                    end
                    if period & valid & match & (c == '.')
                        match = false
                    end
                elseif mc == '?'
                    if pathname & (c == '/')
                        return false # ? does not match /
                    end
                    if period & (c == '.')
                        return false # ? does not match leading .
                    end
                    match = true
                else
                    if (!noescape) & (mc == '\\') # escape the next character after backslash, unless it is the last character
                        patnext = iterate(pattern, mi)
                        if patnext !== nothing
                            mc, mi = patnext
                        end
                    end
                    match = ((c == mc) || (caseless && uppercase(c)==uppercase(mc)))
                end
                # Track if we're matching a . during globstar
                if globstarmatch > 0 && period && (c == '.')
                    globstar_period = true
                end
                # Update after_slash for next iteration (track if pattern char was '/')
                after_slash = (mc == '/')
                if match && after_slash && pathname
                    # in pathname mode, once matching a / explicitly, backtracking to starmatch will not be necessary
                    star = 0
                end
            end
        end
        if !match # try to backtrack
            # Try * backtracking first
            if star != 0
                c, i = something(iterate(s, starmatch))
                if !(pathname & (c == '/'))
                    mi = star
                    starmatch = i
                    continue
                end
            end
            # Then try **/ backtracking
            if globstarmatch > 0
                nextslash = findnext('/', s, globstarmatch)
                if nextslash !== nothing && !globstar_period
                    i = nextind(s, nextslash)
                    globstarmatch = i
                    mi = globstar_mi
                    star = globstar_star
                    starmatch = globstar_starmatch
                    period = periodfl
                    continue
                end
                globstarmatch = 0
            end
            return false
        end
        period = (periodfl & pathname & (c == '/'))
    end
    while true # allow trailing *'s and **'s
        patnext = iterate(pattern, mi)
        patnext === nothing && break
        mc, mi = patnext
        mc == '*' || return false # pattern characters left to match, but no string left
    end
    return true
end

@deprecate ismatch(fn::FilenameMatch, s::AbstractString) occursin(fn, s)

filter!(fn::FilenameMatch, v) = filter!(x -> occursin(fn, x), v)
filter(fn::FilenameMatch, v)  = filter(x -> occursin(fn, x), v)
filter!(fn::FilenameMatch, d::Dict) = filter!(((k, _),) -> occursin(fn, k), d)
filter(fn::FilenameMatch, d::Dict) = filter!(fn, copy(d))

function _match_bracket(pat::AbstractString, mc::Char, i, cl::Char, cu::Char) # returns (mc, i, valid, match)
    next = iterate(pat, i)
    if next === nothing
        return (mc, i, false, false)
    end
    mc2, j = next
    if (mc2 != ':') & (mc2 != '.') & (mc2 != '=')
        return (mc, i, false, true)
    end
    mc3 = mc4 = '\0'
    k0 = k1 = k2 = k3 = j
    next = iterate(pat, k3)
    while mc3 != mc2 && mc4 != ']'
        if next === nothing
            return (mc, i, false, false)
        end
        mc3 = mc4
        k0 = k1
        k1 = k2
        k2 = k3
        next = iterate(pat, k3)
        if next === nothing
            return (mc, i, false, false)
        end
        mc4, k3 = next
    end
    if mc2 == ':'
        phrase = SubString(pat, j, k0)
        match = (
            if phrase == "alnum"
                isletter(cl) || isnumeric(cl)
            elseif phrase == "alpha"
                isletter(cl)
            elseif phrase == "blank"
                (cl == ' ' || cl == '\t')
            elseif phrase == "cntrl"
                iscntrl(cl)
            elseif phrase == "digit"
                isdigit(cl)
            elseif phrase == "graph"
                isprint(cl) && !isspace(cl)
            elseif phrase == "lower"
                islowercase(cl) | islowercase(cu)
            elseif phrase == "print"
                isprint(cl)
            elseif phrase == "punct"
                ispunct(cl)
            elseif phrase == "space"
                isspace(cl)
            elseif phrase == "upper"
                isuppercase(cl) | isuppercase(cu)
            elseif phrase == "xdigit"
                isxdigit(cl)
            else
                error(string("invalid character expression [:",phrase,":]"))
            end)
        return (mc, k3, true, match)
    elseif mc2 == '.'
        if j != k0
            error(string("only single characters are currently supported as collating symbols, got [.", SubString(pat, j, k0), ".]"))
            #match = (pat[j:k0] == s[ci:ci+(k0-j)])
            #return (mc, k3, true, match)
        end
        mc, j = something(iterate(pat, j))
        return (mc, k3, false, true)
    else #if mc2 == '='
        if j != k0
            error(string("only single characters are currently supported as character equivalents, got [=", SubString(pat, j, k0), "=]"))
        end
        mc, j = something(iterate(pat, j))
        match = (cl==mc) | (cu==mc)
        return (mc, k3, true, match)
    end
end

function _match(pat::AbstractString, i0, c::Char, caseless::Bool, extended::Bool) # returns (i, valid, match)
    if caseless
        cl = lowercase(c)
        cu = uppercase(c)
    else
        cl = cu = c
    end
    i = i0
    next = iterate(pat, i)
    if next === nothing
        return (i0, false, c=='[')
    end
    mc, j = next
    negate = false
    if mc == '!'
        negate = true
        i = j
    end
    match = false
    notfirst = false
    while true
        next = iterate(pat, i)
        next === nothing && break
        mc, i = next
        if (mc == ']') & notfirst
            return (i, true, match ⊻ negate)
        end
        notfirst = true
        if (mc == '[')
            mc, i, valid, match2 = _match_bracket(pat, mc, i, cl, cu)
            if valid
                match |= match2
                continue
            elseif !match2
                return (i0, false, c=='[')
            end
        elseif extended & (mc == '\\')
            next = iterate(pat, i)
            if next === nothing
                return (i0, false, c=='[')
            end
            mc, i = next
        end
        next = iterate(pat, i)
        if next === nothing
            return (i0, false, c=='[')
        end
        mc2, j = next
        if mc2 == '-'
            next = iterate(pat, j)
            if next === nothing
                return (i0, false, c=='[')
            end
            mc2, j = next
            if mc2 == ']'
                match |= ((cl == mc) | (cu == mc) | (c == '-'))
                return (j, true, match ⊻ negate)
            end
            if mc2 == '['
                mc2, j, valid, match2 = _match_bracket(pat, mc2, j, cl, cu)
                if valid
                    error("[: and [= are not valid range endpoints")
                elseif !match2
                    return (i0, false, c=='[')
                end
            elseif extended & (mc2 == '\\')
                next = iterate(pat, j)
                if next === nothing
                    return (i0, false, c=='[')
                end
                mc2, j = next
            end
            match |= (mc <= cl <= mc2)
            match |= (mc <= cu <= mc2)
            i = j
        else
            match |= ((cl == mc) | (cu == mc))
        end
    end
    return (i0, false, c=='[')
end

"""
    glob"pattern"

Returns a `Glob.GlobMatch` object, which can be used with `glob()` or `readdir()`.
"""
macro glob_str(pattern) GlobMatch(pattern) end
macro glob_mstr(pattern) GlobMatch(pattern) end

struct GlobMatch
    pattern::Vector
    GlobMatch(pattern) = isempty(pattern) ? error("GlobMatch pattern cannot be an empty vector") : new(pattern)
end
GlobMatch(gm::GlobMatch) = gm
function GlobMatch(pattern::AbstractString)
    if isempty(pattern) || first(pattern) == '/'
        error("Glob pattern cannot be empty or start with a / character")
    end
    pat = split(pattern, '/')
    S = eltype(pat)
    if !isconcretetype(S)
        S = Any
    else
        S = Union{S, FilenameMatch{S}}
    end
    glob = Array{S}(undef, length(pat))
    extended = false
    for i = 1:length(pat)
        p = pat[i]
        next = iterate(p)
        ispattern = false
        while next !== nothing
            c, j = next
            next = iterate(p, j)
            if extended & (c == '\\')
                if next === nothing
                    break
                end
                next = iterate(p, j)
            elseif (c == '*') | (c == '?') |
                    (c == '[' && _match(p, j, '\0', false, extended)[2])
                ispattern = true
                break
            end
        end
        if ispattern
            glob[i] = FilenameMatch(p, PERIOD|PATHNAME)
        else
            glob[i] = p
        end
    end
    return GlobMatch(glob)
end

function show(io::IO, gm::GlobMatch)
    for pat in gm.pattern
        if !isa(pat, AbstractString) && !isa(pat, FilenameMatch)
            print(io, "Glob.GlobMatch(")
            show(io, gm.pattern)
            print(io, ')')
            return
        end
    end
    print(io, "glob\"")
    notfirst = false
    for pat in gm.pattern
        notfirst && print(io, '/')
        notfirst = true
        if isa(pat, FilenameMatch)
            print(io, pat.pattern)
        else
            print(io, pat)
        end
    end
    print(io, '"')
end

"""
    readdir(pattern::GlobMatch, [directory::AbstractString])

Alias for [`glob()`](@ref).
"""
readdir(pattern::GlobMatch, prefix::AbstractString="") = glob(pattern, prefix)

"""
    glob(pattern, [directory::AbstractString])

Returns a list of all files matching `pattern` in `directory`.

* If directory is not specified, it defaults to the current working directory.
* Pattern can be any of:
    1. A `Glob.GlobMatch` object:

            glob"a/?/c"

    2. A string, which will be converted into a GlobMatch expression:

            "a/?/c" # equivalent to 1, above

    3. A vector of strings and/or objects which implement `occursin`, including `Regex` and `Glob.FilenameMatch` objects

            ["a", r".", fn"c"] # again, equivalent to 1, above

        * Each element of the vector will be used to match another level in the file hierarchy
        * no conversion of strings to `Glob.FilenameMatch` objects or directory splitting on `/` will occur.

A trailing `/` (or equivalently, a trailing empty string in the vector) will cause glob to only match directories.

Attempting to use a pattern with a leading `/` or the empty string is an error; use the `directory` argument to specify the absolute path to the directory in such a case.
"""
function glob(pattern, prefix::AbstractString="")
    matches = String[prefix]
    for pat in GlobMatch(pattern).pattern
        matches = _glob!(matches, pat)
    end
    return matches
end

function _glob!(matches, pat::AbstractString)
    i = 1
    last = length(matches)
    while i <= last
        path = joinpath(matches[i], pat)
        if ispath(path)
            matches[i] = path
            i += 1
        else
            matches[i] = matches[last]
            last -= 1
        end
    end
    resize!(matches, last)
    return matches
end

function _glob!(matches, pat)
    m2 = String[]
    for m in matches
        if isempty(m)
            for d in readdir()
                if occursin(pat, d)
                    push!(m2, d)
                end
            end
        elseif isdir(m)
            for d in readdir(m)
                if occursin(pat, d)
                    push!(m2, joinpath(m, d))
                end
            end
        end
    end
    return m2
end

end # module
