module test_markdown

using Test
using JETLSCore
using JETLSCore: JL, JS, Markdown

@testset "Better Markdown Appearance" begin
    let text = """
        # Head
        # Head 2

        The base library of Julia.
        `Base` is a module that contains basic functionality
        (the contents of `base/`).
        All modules implicitly contain `using Base`,
        since **this is needed** *in the vast* majority of cases.

        [normal not @ref link](https://julialang.org)

        ```python3
        def f(x):
            return x + 1
        ```
        """
        md = Markdown.parse(text)
        result = JETLSCore.lsrender(md)
        @test result == Markdown.plain(md)
    end

    let md = Markdown.MD()
        result = JETLSCore.lsrender(md)
        @test result == ""
    end

    let md = Markdown.parse("\n"^10)
        result = JETLSCore.lsrender(md)
        @test result == ""
    end

    # Julia-like languages should be converted to "julia"
    let languages = ["julia", "julia-repl", "jldoctest"]
        for lang in languages
            text = """
            ```$lang
            julia> x = 1
            1
            ```
            """
            md = Markdown.parse(text)
            result = JETLSCore.lsrender(md)
            expected = """
            ```julia
            julia> x = 1
            1
            ```
            """
            @test result == expected
        end
    end

    let text = """
        ```julia
        x = 1
        ```

        ```python
        y = 2
        ```

        ```jldoctest
        julia> z = 3
        3
        ```
        """
        md = Markdown.parse(text)
        result = JETLSCore.lsrender(md)
        expected = """
        ```julia
        x = 1
        ```

        ```python
        y = 2
        ```

        ```julia
        julia> z = 3
        3
        ```
        """
        @test result == expected
    end
end

@testset "Documenter admonitions rendered as blockquotes" begin
    # Default category title → emoji + capitalized category
    let input = """
        !!! tip
            Body text.
        """
        expected = """
        > **💡 Tip**
        >
        > Body text.
        """
        @test JETLSCore.lsrender(Markdown.parse(input)) == expected
    end

    # Custom title overrides the default
    let input = """
        !!! warning "Watch out"
            Be careful.
        """
        expected = """
        > **⚠️ Watch out**
        >
        > Be careful.
        """
        @test JETLSCore.lsrender(Markdown.parse(input)) == expected
    end

    # Multiple paragraphs are separated by `>` lines
    let input = """
        !!! info
            First.

            Second.
        """
        expected = """
        > **ℹ️ Info**
        >
        > First.
        >
        > Second.
        """
        @test JETLSCore.lsrender(Markdown.parse(input)) == expected
    end

    # Code block nested in an admonition stays a fenced block under `>`
    let input = """
        !!! note
            See:

            ```julia
            x = 1
            ```
        """
        expected = """
        > **📝 Note**
        >
        > See:
        >
        > ```julia
        > x = 1
        > ```
        """
        @test JETLSCore.lsrender(Markdown.parse(input)) == expected
    end

    # `jldoctest` inside an admonition is also normalized to `julia`
    let input = """
        !!! note
            ```jldoctest
            julia> 1 + 1
            2
            ```
        """
        expected = """
        > **📝 Note**
        >
        > ```julia
        > julia> 1 + 1
        > 2
        > ```
        """
        @test JETLSCore.lsrender(Markdown.parse(input)) == expected
    end

    # Unknown category falls back to the generic marker
    let input = """
        !!! custom "My Admonition"
            Body.
        """
        expected = """
        > **💬 My Admonition**
        >
        > Body.
        """
        @test JETLSCore.lsrender(Markdown.parse(input)) == expected
    end

    # Admonition mixed with surrounding content
    let input = """
        Hello.

        !!! danger "!!"
            Boom.

        After.
        """
        expected = """
        Hello.

        > **🚨 !!**
        >
        > Boom.

        After.
        """
        @test JETLSCore.lsrender(Markdown.parse(input)) == expected
    end

    # All known categories resolve to their dedicated marker
    let categories = [
            ("note",    "📝"),
            ("info",    "ℹ️"),
            ("tip",     "💡"),
            ("warning", "⚠️"),
            ("danger",  "🚨"),
            ("compat",  "⬆️"),
        ]
        for (cat, marker) in categories
            @test JETLSCore.admonition_marker(cat) == marker
            @test JETLSCore.admonition_marker(uppercase(cat)) == marker
        end
        @test JETLSCore.admonition_marker("something-else") == "💬"
    end
end

@testset "Documenter @ref links stripped" begin
    # `[label](@ref)` → bare `label`
    let md = Markdown.parse("See [foo](@ref) for details.")
        @test JETLSCore.lsrender(md) == "See foo for details.\n"
    end

    # `[label](@ref target)` with explicit target also stripped
    let md = Markdown.parse("Refer to [Foo](@ref bar) instead.")
        @test JETLSCore.lsrender(md) == "Refer to Foo instead.\n"
    end

    # Code-formatted labels preserve their backticks
    let md = Markdown.parse("Use [`f`](@ref) and [`g`](@ref baz) here.")
        @test JETLSCore.lsrender(md) == "Use `f` and `g` here.\n"
    end

    # Multiple refs on the same line
    let md = Markdown.parse("[a](@ref), [b](@ref), and [c](@ref).")
        @test JETLSCore.lsrender(md) == "a, b, and c.\n"
    end

    # Non-@ref links are left untouched
    let md = Markdown.parse("See [the docs](https://example.com) and [`f`](@ref).")
        @test JETLSCore.lsrender(md) ==
            "See [the docs](https://example.com) and `f`.\n"
    end

    # `@reference` (not a Documenter ref) must not be stripped
    let md = Markdown.parse("[link](@reference)")
        @test JETLSCore.lsrender(md) == "[link](@reference)\n"
    end
end

end # module test_markdown
