function uri2filename(uri::URI)
    if uri.scheme == "file"
        return uri2filepath(uri)::String
    elseif uri.scheme == "untitled"
        return uri.path
    else
        error(lazy"Unsupported uri: $uri")
    end
end

function uri2filepath(uri::URI)
    if uri.scheme != "file"
        return nothing
    end

    path = uri.path
    host = uri.authority

    if host!==nothing && host != "" && length(path) > 1
        # unc path: file://shares/c$/far/boo
        value = "//$host$path"
    elseif length(path) >= 3 &&
            path[1] == '/' &&
            isascii(path[2]) && isletter(path[2]) &&
            path[3] == ':'
        # windows drive letter: file:///c:/far/boo
        value = lowercase(path[2]) * path[3:end]
    else
        # other path
        value = path
    end

    if Sys.iswindows()
        value = replace(value, '/' => '\\')
    end

    return value
end

function filename2uri(filename::String)
    if startswith(filename, "Untitled")
        return URI(scheme="untitled", path=filename)
    end
    return filepath2uri(filename)
end

function filepath2uri(path::String)
    isabspath(path) || error("Non-absolute path `$path` is not supported.")

    path = normpath(path)

    @static if Sys.iswindows()
        path = replace(path, "\\" => "/")
    end

    authority = ""

    if startswith(path, "//")
        # UNC path //foo/bar/foobar
        idx = findnext("/", path, 3)
        if idx===nothing
            authority = path[3:end]
            path = "/"
        else
            authority = path[3:idx.start-1]
            path = path[idx.start:end]
        end
    elseif length(path)>=2 && isascii(path[1]) && isletter(path[1]) && path[2]==':'
        path = string('/', lowercase(path[1]), SubString(path, 2))
    end

    return URI(scheme="file", authority=authority, path=path)
end
