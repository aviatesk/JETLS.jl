# Glob

[![Build Status](https://github.com/vtjnash/Glob.jl/workflows/CI/badge.svg)](https://github.com/vtjnash/Glob.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![coveralls](https://coveralls.io/repos/github/vtjnash/Glob.jl/badge.svg?label=coveralls)](https://coveralls.io/github/vtjnash/Glob.jl)
[![codecov](https://codecov.io/gh/vtjnash/Glob.jl/branch/master/graph/badge.svg?label=codecov&token=QDfy4Cs9FB)](https://codecov.io/gh/vtjnash/Glob.jl)



This implementation of Glob is based on the IEEE Std 1003.1, 2004 Edition (Open Group Base Specifications Issue 6) for fnmatch and glob. The specification of which can be found online: [fnmatch](http://pubs.opengroup.org/onlinepubs/009696899/functions/fnmatch.html) and [glob](http://pubs.opengroup.org/onlinepubs/009696899/functions/glob.html).

> Note, because this is based on the POSIX specification, the path separator in a glob pattern is always `/` and the escape character is always `\`. However, the returned path string will always contain the system path separator character `Base.path_separator`. Therefore, it may be true that a path returned by `glob` will fail to match a `Glob.FilenameMatch` constructed from the same pattern.

## Usage

Glob is implemented to have both a functional form and an object-oriented form. There is no "correct" choice; you are encouraged to pick whichever is better suited to your application.

* `glob(pattern, [directory::AbstractString]; join::Bool=true, sort::Bool=true)` ::
  * Returns a list of all files matching `pattern` in `directory`.
  * Never returns `directory`, even if it would match.
  * If directory is not specified, it defaults to the current working directory.
  * If directory is given and `join` is `true` (default), the results are joined with the directory path. If `false`, only the matched paths relative to the directory are returned.
  * If `sort` is `true` (default), the results are sorted lexicographically.
  * Pattern can be any of:
    1. A `Glob.GlobMatch` object:

            glob"a/?/c"

        Attempting to create a GlobMatch object from a string with a leading `/` or the empty string is an error.

    2. A string, which will be converted into a GlobMatch expression:

            "a/?/c" # equivalent to 1, above

        As an interactive convenience, an absolute path is allowed here if directory is not specified, and will be split into drive and path (pattern) components.
        For script usage, it is strongly recommended to keep the pattern and directory prefix separate to avoid mistakes with escaping special characters.

    3. A vector of strings and/or objects which implement `occursin`, including `Regex` and `Glob.FilenameMatch` objects

            ["a", r".", fn"c"] # again, equivalent to 1, above

        * Each element of the vector will be used to match another level in the file hierarchy.
        * No conversion of strings to `Glob.FilenameMatch` objects or directory splitting on `/` will occur.

    4. A trailing `/` (or equivalently, a trailing empty string in the vector) will cause glob to only match directories,
       and will be returned in the results if it was required to be matched explicitly.

* `readdir(pattern::GlobMatch, [directory::AbstractString]; join::Bool=true, sort::Bool=true)` ::
  * alias for `glob()`

* `glob"pattern"` ::
  * Returns a `Glob.GlobMatch` object, which can be used with `glob()` or `readdir()`. See above descriptions.

* `fn"pattern"ipedx` ::
  * Returns a `Glob.FilenameMatch` object, which can be used with `occursin()`. Available flags are:
    * `i` = `CASELESS` : Performs case-insensitive matching by converting to uppercase.
    * `p` = `PERIOD` : A leading period (`.`) character must be exactly matched by a period (`.`) character (not a `?`, `*`, or `[]`). A leading period is a period at the beginning of a string, or a period after a slash if PATHNAME is true.
    * `e` = `NOESCAPE` : Do not treat backslash (`\`) as a special character (in extended mode, this only outside of `[]`)
    * `d` = `PATHNAME` : A slash (`/`) character must be exactly matched by a slash (`/`) character (not a `?`, `*`, or `[]`). When this flag is set, `**/` is treated as a globstar pattern that matches zero or more directories (see below).
    * `x` = `EXTENDED` : Additional features borrowed from newer shells, such as `bash` and `tcsh`:
      * Backslash (`\`) characters in `[]` groups escape the next character

The `CASELESS` mode is similar to [non-unicode regex canonicalization](https://tc39.es/ecma262/multipage/text-processing.html#sec-runtime-semantics-canonicalize-ch).
However, character ranges are checked both before and after uppercasing (for both pattern and string) and
character class names (such as `[:lower:]` and `[:upper:]`) must still be specified with lowercase in the pattern and will apply only to the original character before uppercasing the string.

## Globstar (`**`)

When the `PATHNAME` flag (`d`) is enabled, `**/` is treated as a **globstar** pattern that matches zero or more directory components. This follows [zsh-style recursive globbing](https://zsh.sourceforge.io/Doc/Release/Expansion.html#Recursive-Globbing) semantics, not [bash's globstar](https://www.gnu.org/software/bash/manual/html_node/The-Shopt-Builtin.html).

Notes:
- `**/` matches zero or more directories, including none (e.g., `a/**/b` matches both `a/b` and `a/x/y/b`)
- `**` at the end of a pattern matches everything remaining, including zero remaining components (e.g. `a/**` matches `a/`)
- `**` not followed by `/` or at the end of a string is treated as a regular `*` wildcard
- `**` not preceded by `/` or at the start of a string is treated as a regular `*` wildcard
- A trailing `*` cannot match an empty filename component: `abc/*` does not match `abc/`, but `abc/**` (globstar) still does
- `***` (three or more stars) is not a globstar, but rather behaves identically to `*`

Examples:
```julia
occursin(fn"**/*.png"d, "a/b/c.png")                # true - matches files in any subdirectory
occursin(fn"**/*.png"d, "c.png")                    # true - **/ can match zero directories
occursin(fn"a/**/b"d, "a/b")                        # true - zero directories between a and b
occursin(fn"a/**/b"d, "a/x/y/z/b")                  # true - multiple directories
occursin(fn"**/c/**/*.png"d, "a/b/c/d/e/test.png")  # true - multiple globstars
```

## Matching against arrays

The `occursin(::GlobMatch, ::AbstractVector)` function allows matching a glob pattern against an array of path components:

```julia
gm = glob"src/*/test.jl"
occursin(gm, ["src", "foo", "test.jl"])  # true
occursin(gm, ["src", "bar", "test.jl"])  # true
occursin(gm, ["src", "test.jl"])         # false - wrong length
```

Each element of the pattern is matched against the corresponding element of the array:
- String literals require exact equality
- `FilenameMatch` patterns (from `fn"..."` or wildcards in `glob"..."`) use `occursin` for matching
- `Regex` patterns also work via `occursin`

### GlobStar for array matching

The `GlobStar()` singleton can be used in patterns to match zero or more array elements, similar to `**/` in pathname glob patterns. When parsing a string pattern with `glob"..."` or `GlobMatch(str)`, `**` path segments are automatically converted to `GlobStar()`:

```julia
# String patterns with ** are automatically parsed to GlobStar
gm = glob"src/**/test.jl"
occursin(gm, ["src", "test.jl"])              # true - GlobStar matches zero elements
occursin(gm, ["src", "a", "test.jl"])         # true - GlobStar matches "a"
occursin(gm, ["src", "a", "b", "c", "test.jl"]) # true - GlobStar matches "a", "b", "c"

# Equivalent to manually constructing with GlobStar()
gm = GlobMatch(["src", GlobStar(), fn"*.jl"])
occursin(gm, ["src", "foo.jl"])           # true
occursin(gm, ["src", "a", "b", "foo.jl"]) # true

# GlobStar at the end matches any remaining elements
gm = glob"src/**"
occursin(gm, ["src"])                     # true
occursin(gm, ["src", "foo", "bar"])       # true

# Multiple GlobStars
gm = glob"**/middle/**"
occursin(gm, ["a", "b", "middle", "c"])   # true
```

`GlobStar()` also implements `occursin`, always returning `true` for any string, so it can be used with the `glob()` function as well (matching any single file/directory name).

## Unimplemented features

 * `[.` collating symbols only accept single characters (the Unicode locale has no collating symbols defined)
 * `[=` equivalence classes only match the exact character specified (the Unicode locale has no equivalence classes defined)
 * Advanced extended features (beyond the POSIX spec) such as `{}` groups, have not yet been implemented
