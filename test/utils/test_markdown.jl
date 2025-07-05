module test_markdown

using Test
using JETLS
using JETLS: JL, JS, Markdown

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
        result = JETLS.lsrender(md)
        @test result == Markdown.plain(md)
    end

    let md = Markdown.MD()
        result = JETLS.lsrender(md)
        @test result == ""
    end

    let md = Markdown.parse("\n"^10)
        result = JETLS.lsrender(md)
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
            result = JETLS.lsrender(md)
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
        result = JETLS.lsrender(md)
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

end # module test_markdown
