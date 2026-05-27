using Glob
using Test

macro test_types(arr, types)
    return quote
        @test length($arr) == length($types)
        for i in 1:length($arr)
            @test isa($arr[i], $types[i])
        end
    end
end

# various unit tests, in no particular order

@test !occursin(fn"abc*", "ABXABXAB")
@test occursin(fn"AB*AB*AB", "ABXABXAB")
@test occursin(fn"AB*AB*AB", "ABXABAB")
@test !occursin(fn"AB*AB*AB", "AABAB")
@test occursin(fn"AB*AB*AB", "ABABAB")
@test occursin(fn"AB*AB*B", "ABABAB")
@test occursin(fn"AB*AB*", "ABABAB")
@test occursin(fn"AB*AB*??", "ABABAB")
@test !occursin(fn"AB*AB*???", "ABABAB")
@test occursin(fn"AB*AB*??***", "ABABAB")
@test occursin(fn"AB*AB*??***", "ABABABC")
@test occursin(fn"AB*AB*??***", "ABABABCDEFG")
@test occursin(fn"?AB*AB*??***", ".ABABABCDEFG")
@test !occursin(fn"?AB*AB*??***"p, ".ABABABCDEFG")
@test_throws ErrorException Glob.FilenameMatch("?AB*AB*??***","z")
@test occursin(fn"[abc]", "a")
@test !occursin(fn"[abc]", "A")
@test occursin(fn"[abc]"i, "A")
@test occursin(fn"[abc]", "b")
@test occursin(fn"[abc]", "c")
@test !occursin(fn"[abc]", "x")
@test !occursin(fn"[a-d]", "x")
@test occursin(fn"[a-d]", "a")
@test occursin(fn"[a-d]", "d")
@test !occursin(fn"[a--]", "e")
@test occursin(fn"[--e]", "e")
@test !occursin(fn"[f-e]", "e")
@test !occursin(fn"[g-e]", "e")
@test !occursin(fn"[g-f]", "e")
@test occursin(fn"[a-f]", "e")
@test occursin(fn"[a-e]", "e")
@test occursin(fn"[f-ee]", "e")
@test !occursin(fn"[A-Z]", "e")
@test occursin(fn"[A-z]", "e")
@test occursin(fn"[\]", "\\")
@test_throws ErrorException occursin(fn"[[:a:]]", "e")
@test_throws ErrorException !occursin(fn"[\[:a:]]", "e")
@test !occursin(fn"[\[:a:]]"x, "e")
@test_throws ErrorException occursin(fn"[\\[:a:]]", "e")
@test occursin(fn"[\[:a-e:]]"x, "e]")
@test occursin(fn"[\[:a-e:]"x, "e")
@test !occursin(fn"[\[:a-e:xxxx"x, "e")
@test occursin(fn"[\[:a-e:xxxx-]"x, "e")
@test occursin(fn"[a-]", "a")
@test occursin(fn"[a-]", "-")
@test !occursin(fn"[a-]", "b")
@test !occursin(fn"[a-", "x")       # nothing after - in range: invalid, bracket treated as literal
@test !occursin(fn"[[", "a")        # inner [ with nothing after it in _match_bracket
@test !occursin(fn"[[:", "a")       # bracket class content truncated immediately
@test !occursin(fn"[[:a", "a")      # bracket class content truncated mid-name
@test !occursin(fn"[a-[:", "a")     # invalid range endpoint (bracket class truncated)
@test !occursin(fn"[\\"x, "a")      # extended \\ at end of bracket expression
@test !occursin(fn"[a-\\"x, "a")    # extended \\ at end of range endpoint
@test !occursin(fn"[!", "a")        # negated bracket with no content
@test !occursin(fn"[!]", "a")       # negated bracket with no content
@test occursin(fn"[!a-]", "b")
@test !occursin(fn"[!a-]", "a")
@test occursin(fn"[!a]", "!")
@test !occursin(fn"[!!]", "!")
@test !occursin(fn"[!a]", "a")
@test occursin(fn"[!a]", "b")
@test !occursin(fn"[!]a-z]", "a")
@test occursin(fn"[!]a-z]", "A")
@test !occursin(fn"[!]a-z]", "]")
@test !occursin(fn"[][]", "")
@test occursin(fn"[]", "[]")
@test occursin(fn"[][]", "[")
@test occursin(fn"[][]", "]")
@test !occursin(fn"[][]", "x")
@test !occursin(fn"[]-[]", "x")
@test !occursin(fn"[]-[]", "-")
@test !occursin(fn"[]-[]", "\\")
@test occursin(fn"[\[-\]]*"x, "][")
@test occursin(fn"[\]]*"x, "][")
@test occursin(fn"[\[-\]]*"x, "][")
@test occursin(fn"[[-\]]*"x, "][")
@test occursin(fn"base/[\[-\]]*"dpx,"base/][x")
@test occursin(fn"[\[-\]]"x, "\\")
@test occursin(fn"[[-\]]"x, "\\")
@test occursin(fn"[---]", "-")
@test !occursin(fn"[!---]", "-")
@test occursin(fn"[!---]", "0")
@test !occursin(fn"[---a-zA-Z]", "0")
@test !occursin(fn"[---a-zA-Z:]", "0")
@test !occursin(fn"[---!]", "0")
@test occursin(fn"[---!]", "!")
@test !occursin(fn"[---!]", "a")
@test !occursin(fn"[---!]", "\0")
@test occursin(fn"ab/c/d"dp, "ab/c/d")
@test !occursin(fn"ab/c/d"dp, "ab/c?d")
@test !occursin(fn"ab/./d"dp, "ab/?/d")
@test !occursin(fn"ab*d"dp, "aba/d")
@test !occursin(fn"ab*d"dp, "ab/d")
@test occursin(fn"ab*d", "ab/d")
@test !occursin(fn"[/]"d, "/") # bracket expression matching / is blocked in PATHNAME mode
@test occursin(fn"ab*d", "aba/d")
@test occursin(fn"[a-z]"i, "B")
@test !occursin(fn"[a-z]"i, "_")
@test occursin(fn"[A-z]"i, "_")
@test !occursin(fn"[a-Z]"i, "_")
@test !occursin(fn"#[a-Z]%", "#A%")
@test !occursin(fn"#[a-Z]%", "#a%")
@test occursin(fn"#[a-Z]%"i, "#a%")
@test occursin(fn"#[α-ω]%"i, "#Γ%")
@test !occursin(fn"#[α-ω]%", "#Γ%")
@test occursin(fn"#[α-ω]%", "#γ%")
@test !occursin(fn"a?b"d, "a/b")
@test occursin(fn"a?b", "a/b")
@test !occursin(fn"?b"p, ".b")
@test occursin(fn"?b", ".b")
@test occursin(fn"?/?b", "./.b")
@test !occursin(fn"?/?b"p, "./.b")
@test occursin(fn"./?b"p, "./.b")
@test !occursin(fn"./?b"pd, "./.b")
@test occursin(fn"./.b"pd, "./.b")
@test !occursin(fn"?/.b"pd, "./.b")
@test occursin(fn"""./.b"""pd, "./.b")
@test !occursin(fn"""?/.b"""pd, "./.b")
@test occursin(fn"_[[:blank:][.a.]-c]_", "_b_")
@test !occursin(fn"_[[:blank:][.a.]-c]_", "_-_")
@test occursin(fn"_[[:blank:][.a.]-c]_", "_ _")
@test occursin(fn"_[[:alnum:]]_", "_a_")
@test !occursin(fn"_[[:alnum:]]_", "_[_")
@test !occursin(fn"_[[:alnum:]]_", "_]_")
@test !occursin(fn"_[[:alnum:]]_", "_:_")
@test occursin(fn"_[[:alpha:]]_", "_z_")
@test !occursin(fn"_[[:alpha:]]_", "_[_")
@test occursin(fn"_[[:cntrl:]]_", "_\0_")
@test occursin(fn"_[[:cntrl:]]_", "_\b_")
@test !occursin(fn"_[[:cntrl:]]_", "_:_")
@test !occursin(fn"_[[:cntrl:]]_", "_ _")
@test occursin(fn"_[[:digit:]]_", "_0_")
@test !occursin(fn"_[[:digit:]]_", "_:_")
@test occursin(fn"_[[:graph:]]_", "_._")
@test !occursin(fn"_[[:graph:]]_", "_ _")
@test occursin(fn"_[[:lower:]]_", "_a_")
@test !occursin(fn"_[[:lower:]]_"i, "_A_")
@test !occursin(fn"_[[:lower:]]_", "_A_")
@test !occursin(fn"_[[:lower:]]_", "_:_")
@test occursin(fn"_[[:print:]]_", "_a_")
@test !occursin(fn"_[[:print:]]_", "_\7_")
@test occursin(fn"_[[:punct:]]_", "_:_")
@test !occursin(fn"_[[:punct:]]_", "_p_")
@test occursin(fn"_[[:space:]]_", "_\f_")
@test !occursin(fn"_[[:space:]]_", "_:_")
@test !occursin(fn"_[[:space:]]_", "_\r\n_")
@test occursin(fn"_[[:upper:]]_", "_A_")
@test !occursin(fn"_[[:upper:]]_"i, "_a_")
@test !occursin(fn"_[[:upper:]]_", "_a_")
@test !occursin(fn"_[[:upper:]]_", "_:_")
@test occursin(fn"_[[:xdigit:]]_", "_a_")
@test !occursin(fn"_[[:xdigit:]]_", "_:_")
@test occursin(fn"_[[.a.]-[.z.]]_", "_c_")
@test !occursin(fn"_[[.a.]-[.z.]]_", "_-_")
@test !occursin(fn"_[[.a.]-[.z.]]_", "_]_")
@test !occursin(fn"_[[.a.]-[.z.]]_", "_[_")
@test occursin(fn"_[[=a=]]_", "_a_")
@test !occursin(fn"_[[=a=]]_", "_=_")
@test !occursin(fn"_[[=a=]]_", "_á_")
@test occursin(fn"[[=a=]-z]", "-")
@test_throws ErrorException occursin(fn"[a-[=z=]]", "e")
@test_throws ErrorException occursin(fn"[[.ab.]]", "a")  # multi-char collating symbol
@test_throws ErrorException occursin(fn"[[=ab=]]", "a")  # multi-char character equivalent
@test_throws ErrorException !occursin(fn"_[[:UPPER:]]_"i, "_A_")
@test_throws ErrorException occursin(fn"_[[:UPPER:]]_"i, "_p_")
@test_throws ErrorException occursin(fn"_[[:UPPER:]]_"i, "_:_")
@test occursin(fn"_[![:upper:]]_"i, "_:_")
@test occursin(fn"_[![:upper:]]_"i, "_a_")
@test !occursin(fn"_[![:upper:]]_"i, "_A_")

@test !occursin(fn"\?", "\\?")
@test occursin(fn"\?", "?")
@test occursin(fn"\?"e, "\\!")
@test !occursin(fn"\?"e, "?")

@testset "FilenameMatch with ** globstar" begin
    # Basic **/ patterns
    @test occursin(fn"**/*.png"d, "c.png")
    @test occursin(fn"**/*.png"d, "a/c.png")
    @test occursin(fn"**/*.png"d, "a/b/c.png")

    # Absolute paths with **/
    @test occursin(fn"/**/*.png"d, "/c.png")
    @test occursin(fn"/**/*.png"d, "/a/c.png")
    @test occursin(fn"/**/*.png"d, "/a/b/c.png")

    @test occursin(fn"**/*.png"d, "/c.png")
    @test occursin(fn"**/*.png"d, "/a/c.png")
    @test occursin(fn"**/*.png"d, "/a/b/c.png")

    @test !occursin(fn"/**/*.png"d, "c.png")
    @test !occursin(fn"/**/*.png"d, "a/c.png")
    @test !occursin(fn"/**/*.png"d, "a/b/c.png")

    # ** without trailing /
    @test occursin(fn"**.png"d, "c.png")
    @test !occursin(fn"**.png"d, "a/b/c.png")

    # ** alone
    @test occursin(fn"**"d, "c.png")
    @test occursin(fn"**"d, "a/c.png")
    @test occursin(fn"**"d, "/a/c.png")
    @test occursin(fn"/**"d, "/a/c.png")
    @test occursin(fn"/a/**"d, "/a/c.png")
    @test !occursin(fn"/b/**"d, "/a/c.png")
    @test !occursin(fn"/**"d, "a/c.png")

    # Complex patterns with multiple **/
    @test occursin(fn"**/c/**/*"d, "a/b/c/d/e/test.png")
    @test !occursin(fn"**/c/*/*"d, "a/b/c/d/e/test.png")
    @test occursin(fn"**/c/**/*.png"d, "a/b/c/d/e/test.png")
    @test !occursin(fn"**/c/**/*.png"d, "a/b/c/d/e/test.gif")

    # PERIOD flag tests
    @test occursin(fn"**/c/**/*.png"d, "a/b/c/d/e/.png")
    @test occursin(fn"**/c/**/*png"d, "a/b/c/d/e/.png")
    @test occursin(fn"**/c/**/?png"d, "a/b/c/d/e/.png")

    @test !occursin(fn"**/c/**/?png"dp, "a/b/c/d/e/.png")
    @test !occursin(fn"**/c/**/*png"dp, "a/b/c/d/e/.png")

    @test !occursin(fn"**/c/**/?png"dp, "a/.b/c/d/e/apng")
    @test !occursin(fn"**/c/**/?png"dp, ".a/b/c/d/e/apng")
    @test !occursin(fn"**/c/**/?png"dp, "a/b/c/d/e/.png")
    @test !occursin(fn"*/**/*.png"d, "c.png")
    @test !occursin(fn"**/*/*.png"d, "c.png")

    @test occursin(fn"**/c/**/*png"dp, "a/b/c/d/e/*png")
    @test occursin(fn"**/c/**/*png"d, "a/b/c/d/e/.png")
    @test !occursin(fn"**/c/**/*png"dp, "a/b/c/d/e/.png")

    # Wildcards combined with **/
    @test occursin(fn"a*/**/c/test.gif"d, "ab/b/c/test.gif")
    @test occursin(fn"a*/**/test.gif"d, "ab/b/c/test.gif")
    @test !occursin(fn"a**/test.gif"d, "ab/b/h/test.gif")

    # Test wildcards appearing both before and after **/
    @test occursin(fn"a*/**/*b"d, "ax/y/z/wb")
    @test occursin(fn"a*/**/*b"d, "ax/y/wb")
    @test occursin(fn"a*/**/*b"d, "ax/wb")
    @test occursin(fn"a*/**/*b"d, "a/wb")
    @test !occursin(fn"a*/**/*b"d, "ax/y/z/w")
    @test !occursin(fn"a*/**/*b"d, "x/y/z/wb")
    @test occursin(fn"*a/**/*b"d, "xa/y/zb")
    @test occursin(fn"*a/**/*b"d, "xa/zb")
    @test occursin(fn"*a*/**/*b"d, "xaay/m/nb")
    @test occursin(fn"a*x/**/*b"d, "ayx/z/wb")
    @test occursin(fn"a*x/**/*b"d, "ayxx/z/wb")
    @test occursin(fn"a*/**/b"d, "ax/y/b")
    @test occursin(fn"a*/**/b"d, "ax/b")
    @test !occursin(fn"a*/**/b"d, "ax/y/c")

    # Test ** without / (in non-pathname mode, matches any character including /)
    @test occursin(fn"a/**test.jl", "a/test.jl")
    @test occursin(fn"a/**test.jl", "a/b/test.jl")

    # Test **/ matching zero or more directories
    @test occursin(fn"a/**/b"d, "a/b")
    @test occursin(fn"a/**/b"d, "a/x/b")
    @test occursin(fn"a/**/b"d, "a/x/y/b")
    @test occursin(fn"a/**/b"d, "a/x/y/z/b")
    @test !occursin(fn"a/**/b"d, "a/b/c")
    @test !occursin(fn"a/**/b"d, "x/a/b")

    # Dotfile patterns with ** and PERIOD flag
    @test !occursin(fn".a/**/"xpd, ".a/.b/.c/")
    @test occursin(fn".a/**/"xd, ".a/.b/.c/")
    @test occursin(fn".a/**/.d"xdp, ".a/b/.d")
    @test occursin(fn".a/**/.d"xdp, ".a/b/.d")
    @test occursin(fn"a/**"dp, "a/b/c")
    @test !occursin(fn"a/**"dp, "a/b/.c")
    @test !occursin(fn"a/**"dp, "a/.b/c")

    # Trailing ** patterns
    @test occursin(fn".a/**/**"pdx, ".a/")
    @test occursin(fn".a/**/**/"pdx, ".a/")
    @test !occursin(fn".a/**/**"pdx, ".a")
    @test occursin(fn"**/**/**/"pdx, "")

    # In pathname mode, a trailing * cannot match an empty filename component
    # (i.e. the empty string after a trailing slash, or the empty string at the start)
    @test !occursin(fn"abc/*"d, "abc/")   # * cannot match "" after /
    @test !occursin(fn"abc/*"dp, "abc/")
    @test !occursin(fn"abc/***"d, "abc/") # *** is not a globstar
    @test !occursin(fn"*"d, "")           # * cannot match "" at start
    @test !occursin(fn"***"d, "")         # *** is not a globstar
    # ** (globstar) still matches the empty tail after a trailing slash
    @test occursin(fn"abc/**"d, "abc/")
    @test occursin(fn"abc/**"dp, "abc/")
    # Without PATHNAME, trailing * may still match ""
    @test occursin(fn"abc/*", "abc/")
    @test occursin(fn"*", "")
end

@test_types glob"ab/?/d".pattern (AbstractString, Glob.FilenameMatch, AbstractString)
@test_types glob"""ab/*/d""".pattern (AbstractString, Glob.FilenameMatch, AbstractString)
@test length(glob"ab/[/d".pattern) == 3
@test length(glob"ab/[/]d".pattern) == 3
@test_types glob"ab/[/]d".pattern (AbstractString, AbstractString, AbstractString)
@test_types glob"ab/[/d".pattern (AbstractString, AbstractString, AbstractString)
@test_types glob"ab/[]/d".pattern (AbstractString, AbstractString, AbstractString)
@test_types glob"ab/[]]/d".pattern (AbstractString, Glob.FilenameMatch, AbstractString)

# Tests run from any directory, so use dirname(@__DIR__) to get project root
const root = dirname(@__DIR__)

cd(root) do
    @testset "regular glob readdir" begin
        @test glob("*") == filter(x->!startswith(x, '.'), readdir()) == readdir(glob"*")
        @test glob(".*") == filter(x->startswith(x, '.'), readdir()) == readdir(glob".*")
        @test isempty(Glob.glob("[.]*"))
        @test glob([r".*"]) == readdir()
        @test glob([".", r".*"]) == map(x->joinpath(".", x), readdir())
        @test all([!startswith(x, '.') for x in Glob.glob("*.*")])
        # Empty prefix: join=true and join=false should be equivalent
        @test glob("src/*.jl"; join=true) == glob("src/*.jl"; join=false)

        # join=false returns paths relative to prefix
        @test glob("*.jl", joinpath(root, "src"); join=false) == ["Glob.jl"]
        @test glob("src/*.jl"; join=true) ==
              glob("src/*.jl"; join=false) ==
              glob("src/*.jl", root; join=false) ==
              [joinpath("src", "Glob.jl")]

        # These are written such that even if `root` has meta-characters, the test will still pass
        slashroot = replace(root, Base.Filesystem.path_separator_re => '/')
        prefix, rest = Glob.splitabspath(slashroot)
        normroot = joinpath(prefix, split(rest, '/')...)
        @test normroot in glob(slashroot; join=false)
        @test joinpath(normroot, "src", "Glob.jl") in glob(slashroot * "/src/*.jl"; join=false)
    end
end

@testset "glob with **" begin
    @test glob("**/*.jl", root) == [joinpath(root, "src", "Glob.jl"), joinpath(root, "test", "runtests.jl")]
    @test glob("src/**", root) == [joinpath(root, "src"), joinpath(root, "src", "Glob.jl")]
    @test joinpath(root, "src", "Glob.jl") in glob("**/Glob.jl", root)
    @test joinpath(root, "src", "Glob.jl") in glob("src/**/**/Glob.jl", root)

    # Basic ** matches everything
    all_files = glob("**", root)
    @test !(root in all_files)
    @test joinpath(root, "src") in all_files
    @test joinpath(root, "test") in all_files
    @test joinpath(root, "README.md") in all_files

    # Basic **/ matches folders
    @test glob("**/", root) == [joinpath(root, "src", ""), joinpath(root, "test", "")]
    @test glob("**/**/**/", root) == [joinpath(root, "src", ""), joinpath(root, "test", "")]
    @test glob("src/**/**", root) == [joinpath(root, "src"), joinpath(root, "src", "Glob.jl")]
    @test glob("src/**/**/", root) == [joinpath(root, "src", "")]

    # ** in current directory
    cd(root) do
        @test glob("**/*.jl") == [joinpath("src", "Glob.jl"), joinpath("test", "runtests.jl")]
        @test glob("**/") == [joinpath("src", ""), joinpath("test", "")]
        @test glob("**/*.jl"; join=true) == glob("**/*.jl"; join=false)
        local all_files = glob("**")
        @test !(root in all_files)
        @test !("/" in all_files)
        @test !("" in all_files)
        @test "src" in all_files
        @test joinpath("src", "Glob.jl") in all_files
        @test "test" in all_files
        @test "README.md" in all_files
    end

    # join=false returns paths relative to prefix
    @test glob("**/*.jl", root; join=false) == [joinpath("src", "Glob.jl"), joinpath("test", "runtests.jl")]
    @test glob("src/**", root; join=false) == ["src", joinpath("src", "Glob.jl")]
    @test glob("**/", root; join=false) == [joinpath("src", ""), joinpath("test", "")]
    @test glob("**/src", root; join=false) == ["src"]
    @test glob("**/src/", root; join=false) == [joinpath("src", "")]
    @test glob("**/src/*", root; join=false) == [joinpath("src", "Glob.jl")]
    @test glob("**/src/**", root; join=false) == ["src", joinpath("src", "Glob.jl")]
    @test glob("**/src/**/", root; join=false) == [joinpath("src", "")]

    # glob with a non-String AbstractString prefix (SubString) should convert to String
    @test isempty(glob("__nonexistent__*", SubString(root, 1, lastindex(root)); join=false)::Vector{String})
    @test glob("src/*", SubString(root, 1, lastindex(root)); join=false)::Vector{String} == [joinpath("src", "Glob.jl")]
end

function test_string(x1)
    x2 = string(eval(Meta.parse(x1)))
    x1 == x2 ? nothing : error(string(
        "string test failed:",
        "\noriginal: ", x1,
        "\n\nstringify: ", x2))
end

test_string("""Glob.GlobMatch(Any["base", r"h\\.+"])""")
test_string("""glob"base/*/a/[b]\"""")
test_string("""fn"base/*/a/[b]\"ipedx""")
test_string("""fn"base/*/a/[b]\"""")

@test_throws ErrorException Glob.GlobMatch("")
@test_throws ErrorException Glob.GlobMatch("/a/b/c")

@testset "occursin(GlobMatch, Array)" begin
    # Basic string matching
    @test occursin(glob"src/foo/test.jl", ["src", "foo", "test.jl"])
    @test !occursin(glob"src/foo/test.jl", ["src", "bar", "test.jl"])  # mismatch
    @test !occursin(glob"src/foo/test.jl", ["src", "foo"])  # too short
    @test !occursin(glob"src/foo/test.jl", ["src", "foo", "test.jl", "extra"])  # too long
    @test !occursin(glob"src/foo", String[])  # empty array

    # FilenameMatch patterns
    @test occursin(glob"src/*.jl", ["src", "foo.jl"])
    @test !occursin(glob"src/*.jl", ["src", "foo.txt"])

    # Regex patterns
    @test occursin(Glob.GlobMatch([r"^src$", fn"*.jl"]), ["src", "test.jl"])
    @test !occursin(Glob.GlobMatch([r"^src$", fn"*.jl"]), ["SRC", "test.jl"])
end

@testset "GlobStar type" begin
    # occursin returns true for non-dotfiles
    @test occursin(Glob.GlobStar(), "anything")
    @test occursin(Glob.GlobStar(), "")

    # occursin returns false for dotfiles
    @test !occursin(Glob.GlobStar(), ".hidden")
    @test !occursin(Glob.GlobStar(), ".git")
    @test !occursin(Glob.GlobStar(), ".")
    @test !occursin(Glob.GlobStar(), "..")

    # show method
    @test endswith(string(Glob.GlobStar()), "GlobStar()")
end

@testset "GlobMatch ** parsing" begin
    # ** in middle becomes GlobStar
    gm = glob"src/**/test.jl"
    @test gm.pattern[2] isa Glob.GlobStar
    @test gm.pattern[3] == "test.jl"  # no wildcards = string literal

    # ** with wildcard
    gm2 = glob"src/**/*.jl"
    @test gm2.pattern[2] isa Glob.GlobStar
    @test gm2.pattern[3] isa Glob.FilenameMatch

    # ** at start and end
    gm3 = glob"**/src/**"
    @test gm3.pattern[1] isa Glob.GlobStar
    @test gm3.pattern[3] isa Glob.GlobStar

    # Trailing slash: **/ parses to [GlobStar(), ""]
    # This differs from splitpath but agrees with joinpath(splitdir("**/")...)
    gm_trail = glob"**/"
    @test length(gm_trail.pattern) == 2
    @test gm_trail.pattern[1] isa Glob.GlobStar
    @test gm_trail.pattern[2] == ""
    @test occursin(gm_trail, ["src", ""])              # matches with trailing empty
    @test !occursin(gm_trail, ["src"])                 # no trailing empty = no match

    # show roundtrip
    @test string(glob"src/**/*.jl") == "glob\"src/**/*.jl\""
end

@testset "match with GlobStar" begin
    # GlobStar matching zero/one/many elements (middle position)
    gm = glob"src/**/*.jl"
    @test occursin(gm, ["src", "foo.jl"])                    # zero
    @test occursin(gm, ["src", "a", "foo.jl"])               # one
    @test occursin(gm, ["src", "a", "b", "c", "foo.jl"])     # many
    @test !occursin(gm, ["src", "foo.txt"])                  # pattern mismatch
    @test !occursin(gm, ["other", "foo.jl"])                 # prefix mismatch

    # GlobStar at end
    gm_end = glob"src/**"
    @test occursin(gm_end, ["src"])                          # zero
    @test occursin(gm_end, ["src", "a", "b", "c"])           # many

    # GlobStar at beginning
    gm_start = glob"**/*.jl"
    @test occursin(gm_start, ["foo.jl"])                     # zero
    @test occursin(gm_start, ["a", "b", "foo.jl"])           # many
    @test !occursin(gm_start, ["foo.txt"])                   # pattern mismatch

    # Multiple GlobStars (only last matters for backtracking)
    gm_multi = glob"**/middle/**"
    @test occursin(gm_multi, ["middle"])                     # both zero
    @test occursin(gm_multi, ["a", "middle"])                # first consumes, second zero
    @test occursin(gm_multi, ["middle", "b"])                # first zero, second consumes
    @test occursin(gm_multi, ["a", "b", "middle", "c", "d"]) # both consume
    @test !occursin(gm_multi, ["no_middle_here"])

    # Backtracking: pattern after GlobStar appears multiple times
    gm_bt = glob"**/b/c"
    @test occursin(gm_bt, ["b", "c"])                        # zero - first occurrence
    @test occursin(gm_bt, ["x", "b", "c"])                   # one element before
    @test occursin(gm_bt, ["b", "x", "b", "c"])              # must skip first "b", find second
    @test occursin(gm_bt, ["a", "b", "b", "c"])              # "b" appears twice, use second
    @test !occursin(gm_bt, ["b", "c", "x"])                  # pattern must match at end
    @test !occursin(gm_bt, ["b", "x"])                       # no "c" after "b"

    # Backtracking: longer pattern after GlobStar
    gm_bt2 = glob"**/a/b/c"
    @test occursin(gm_bt2, ["a", "b", "c"])                  # exact match, zero consumed
    @test occursin(gm_bt2, ["a", "b", "a", "b", "c"])        # must backtrack past first "a","b"
    @test occursin(gm_bt2, ["a", "a", "b", "c"])             # backtrack past first "a"
    @test !occursin(gm_bt2, ["a", "b", "c", "d"])            # extra element at end

    # Two GlobStars: first must not consume too much
    gm_two = glob"**/c/**/end"
    @test occursin(gm_two, ["c", "end"])                     # both zero
    @test occursin(gm_two, ["a", "c", "end"])                # first consumes "a"
    @test occursin(gm_two, ["c", "x", "end"])                # second consumes "x"
    @test occursin(gm_two, ["a", "c", "x", "end"])           # both consume one
    @test occursin(gm_two, ["a", "c", "c", "end"])           # first GlobStar stops at first "c"
    @test occursin(gm_two, ["c", "c", "end"])                # tricky: first "c" is literal, second consumed by GlobStar
    @test !occursin(gm_two, ["c", "x"])                      # missing "end"
    @test !occursin(gm_two, ["a", "b", "end"])               # missing "c"

    # Only GlobStar (matches anything including empty, but not dotfiles)
    gm_only = glob"**"
    @test occursin(gm_only, String[])
    @test occursin(gm_only, ["a", "b", "c"])
    @test !occursin(gm_only, [".hidden"])
    @test !occursin(gm_only, ["a", ".hidden", "b"])

    # GlobStar skips dotfiles during backtracking
    gm_dot = glob"**/test.jl"
    @test occursin(gm_dot, ["test.jl"])
    @test occursin(gm_dot, ["src", "test.jl"])
    @test !occursin(gm_dot, [".git", "test.jl"])        # .git blocks GlobStar
    @test !occursin(gm_dot, ["src", ".hidden", "test.jl"])  # .hidden blocks GlobStar

    # Dotfiles can still be matched explicitly
    gm_explicit = Glob.GlobMatch([Glob.GlobStar(), ".git", "config"])
    @test occursin(gm_explicit, [".git", "config"])     # GlobStar matches zero, .git matched literally
    @test occursin(gm_explicit, ["a", ".git", "config"])
    @test !occursin(gm_explicit, [".other", ".git", "config"])  # .other blocks GlobStar
end

@testset "splitprefix" begin
    sep_re = r"/+"sa # Base.Filesystem.path_separator_re on unix
    @test Glob.splitprefix("/foo/bar", sep_re) == ("/", "foo/bar")
    @test Glob.splitprefix("foo/bar", sep_re) == ("", "foo/bar")
    @test Glob.splitprefix("", sep_re) == ("", "")
    @test Glob.splitprefix("///foo", sep_re) == ("///", "foo")
    @test Glob.splitprefix("abcdef", r"[a-c]+") == ("abc", "def")
    @test Glob.splitprefix("xyz", r"[a-c]+") == ("", "xyz")
    @test Glob.splitprefix("xabc", r"[a-c]+") == ("", "xabc")
end

@testset "splitabspath" begin
    @test Glob.splitabspath("") == ("", "")
    @test Glob.splitabspath("foo") == ("", "foo")
    @test Glob.splitabspath("foo/bar") == ("", "foo/bar")
    @test Glob.splitabspath("/") == ("/", "")
    @test Glob.splitabspath("/foo") == ("/", "foo")
    @test Glob.splitabspath("/foo/bar") == ("/", "foo/bar")
    @test Glob.splitabspath("///foo/bar") == ("///", "foo/bar")
    r, p = Glob.splitabspath("/foo")
    @test r isa String
    @test p isa String
    r2, p2 = Glob.splitabspath("foo")
    @test r2 isa String
    @test p2 isa String
end

if Sys.iswindows()
    @testset "splitabspath (Windows)" begin
        @test Glob.splitabspath("C:\\foo\\bar") == ("C:\\", "foo\\bar")
        @test Glob.splitabspath("C:/foo/bar")   == ("C:/",  "foo/bar")
        @test Glob.splitabspath("C:\\")         == ("C:\\", "")
        @test Glob.splitabspath("C:/")          == ("C:/",  "")
        @test Glob.splitabspath("C:\\\\foo")    == ("C:\\\\", "foo")
        @test Glob.splitabspath("\\\\server\\share\\path") == ("\\\\server\\share\\", "path")
        @test Glob.splitabspath("\\\\server\\share\\")     == ("\\\\server\\share\\", "")
        @test Glob.splitabspath("\\foo\\bar")   == ("\\", "foo\\bar")
        @test Glob.splitabspath("/foo/bar")     == ("/",  "foo/bar")
        @test Glob.splitabspath("C:foo")        == ("C:", "foo")
        @test Glob.splitabspath("C:foo/bar")    == ("C:", "foo/bar")
        @test Glob.splitabspath("foo\\bar")     == ("", "foo\\bar")
    end
end

@testset "glob(\"/\") and glob(\"\")" begin
    # glob("/") returns the root string directly (not a Vector), since the
    # pattern after splitting off the abspath prefix is empty
    @test glob("/")::Vector{String} == ["/"]
    @test_throws ErrorException glob("")
end
