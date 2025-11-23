# Glob

[![Build Status](https://github.com/vtjnash/Glob.jl/workflows/CI/badge.svg)](https://github.com/vtjnash/Glob.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![coveralls](https://coveralls.io/repos/github/vtjnash/Glob.jl/badge.svg?label=coveralls)](https://coveralls.io/github/vtjnash/Glob.jl)
[![codecov](https://codecov.io/gh/vtjnash/Glob.jl/branch/master/graph/badge.svg?label=codecov&token=QDfy4Cs9FB)](https://codecov.io/gh/vtjnash/Glob.jl)



This implementation of Glob is based on the IEEE Std 1003.1, 2004 Edition (Open Group Base Specifications Issue 6) for fnmatch and glob. The specification of which can be found online: [fnmatch](http://pubs.opengroup.org/onlinepubs/009696899/functions/fnmatch.html) and [glob](http://pubs.opengroup.org/onlinepubs/009696899/functions/glob.html).

> Note, because this is based on the POSIX specification, the path separator in a glob pattern is always `/` and the escape character is always `\`. However, the returned path string will always contain the system path separator character `Base.path_separator`. Therefore, it may be true that a path returned by `glob` will fail to match a `Glob.FilenameMatch` constructed from the same pattern.

## Usage

Glob is implemented to have both a functional form and an object-oriented form. There is no "correct" choice; you are encouraged to pick whichever is better suited to your application.

* `glob(pattern, [directory::AbstractString])` ::
  * Returns a list of all files matching `pattern` in `directory`.
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

    4. A trailing `/` (or equivalently, a trailing empty string in the vector) will cause glob to only match directories

    5. Attempting to creat a GlobMatch object from a string with a leading `/` or the empty string is an error

* `readdir(pattern::GlobMatch, [directory::AbstractString])` ::
  * alias for `glob()`

* `glob"pattern"` ::
  * Returns a `Glob.GlobMatch` object, which can be used with `glob()` or `readdir()`. See above descriptions.

* `fn"pattern"ipedx` ::
  * Returns a `Glob.FilenameMatch` object, which can be used with `ismatch()` or `occursin()`. Available flags are:
    * `i` = `CASELESS` : Performs case-insensitive matching
    * `p` = `PERIOD` : A leading period (`.`) character must be exactly matched by a period (`.`) character (not a `?`, `*`, or `[]`). A leading period is a period at the beginning of a string, or a period after a slash if PATHNAME is true.
    * `e` = `NOESCAPE` : Do not treat backslash (`\`) as a special character (in extended mode, this only outside of `[]`)
    * `d` = `PATHNAME` : A slash (`/`) character must be exactly matched by a slash (`/`) character (not a `?`, `*`, or `[]`)
    * `x` = `EXTENDED` : Additional features borrowed from newer shells, such as `bash` and `tcsh`
      * Backslash (`\`) characters in `[]` groups escape the next character

## Unimplemented features

 * `[.` collating symbols only accept single characters (the Unicode locale has no collating symbols defined)
 * `[=` equivalence classes only match the exact character specified (the Unicode locale has no equivalence classes defined)
 * Advanced extended features (beyond the POSIX spec) such as `{}` groups, have not yet been implemented
