module test_general

using Test
using JETLS
using JETLS: Markdown

@testset "format_duration" begin
    # Test milliseconds formatting (< 1 second)
    @test JETLS.format_duration(0.0) == "0.0ms"
    @test JETLS.format_duration(0.001) == "1.0ms"
    @test JETLS.format_duration(0.0005) == "0.5ms"
    @test JETLS.format_duration(0.1234) == "123.4ms"
    @test JETLS.format_duration(0.999) == "999.0ms"
    @test JETLS.format_duration(0.9999) == "999.9ms"

    # Test seconds formatting (1 second to < 60 seconds)
    @test JETLS.format_duration(1.0) == "1.0s"
    @test JETLS.format_duration(1.5) == "1.5s"
    @test JETLS.format_duration(10.0) == "10.0s"
    @test JETLS.format_duration(59.99) == "59.99s"
    @test JETLS.format_duration(30.123) == "30.12s"
    @test JETLS.format_duration(45.678) == "45.68s"

    # Test minutes formatting (>= 60 seconds)
    @test JETLS.format_duration(60.0) == "1m 0.0s"
    @test JETLS.format_duration(61.5) == "1m 1.5s"
    @test JETLS.format_duration(90.0) == "1m 30.0s"
    @test JETLS.format_duration(120.0) == "2m 0.0s"
    @test JETLS.format_duration(150.7) == "2m 30.7s"
    @test JETLS.format_duration(3661.2) == "61m 1.2s"

    # Test edge cases and rounding
    @test JETLS.format_duration(0.9995) == "999.5ms"  # Should round to 999.5ms, not 1000.0ms
    @test JETLS.format_duration(59.999) == "60.0s"    # Should round to 60.0s
    @test JETLS.format_duration(119.99) == "1m 60.0s" # 119.99s = 1m 59.99s, rounds to 60.0s
end

@testset "Markdown rendering" begin
    let text = """
        # Head
        # Head 2

        The base library of Julia.
        `Base` is a module that contains basic functionality
        (the contents of `base/`).
        All modules implicitly contain `using Base`,
        since **this is needed** *in the vast* majority of cases.

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

end # module test_general
