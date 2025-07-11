module test_lsp

using Test
using JETLS: JETLS
using JETLS.LSP
using JETLS.LSP.URIs2

@testset "create_source_location_link" begin
    uri = URI("file:///path/to/file.jl")
    @test JETLS.create_source_location_link(uri) == "[/path/to/file.jl](file:///path/to/file.jl)"
    @test JETLS.create_source_location_link(uri; line=42) == "[/path/to/file.jl:42](file:///path/to/file.jl#L42)"
    @test JETLS.create_source_location_link(uri; line=42, character=10) == "[/path/to/file.jl:42](file:///path/to/file.jl#L42C10)"
    @test JETLS.create_source_location_link(uri, "file.jl") == "[file.jl](file:///path/to/file.jl)"
    @test JETLS.create_source_location_link(uri, "file.jl:42"; line=42) == "[file.jl:42](file:///path/to/file.jl#L42)"
    @test JETLS.create_source_location_link(uri, "file.jl:42:10"; line=42, character=10) == "[file.jl:42:10](file:///path/to/file.jl#L42C10)"
    @test JETLS.create_source_location_link(uri; character=10) == "[/path/to/file.jl](file:///path/to/file.jl)"

    http_uri = URI("http://example.com/file.jl")
    @test JETLS.create_source_location_link(http_uri, "remote file"; line=5) == "[remote file](http://example.com/file.jl#L5)"
end

@testset "Position comparison" begin
    pos1 = Position(; line=0, character=0)
    pos2 = Position(; line=0, character=5)
    pos3 = Position(; line=1, character=0)
    pos4 = Position(; line=1, character=5)

    # Test basic < operator from isless implementation
    @test pos1 < pos2
    @test pos2 < pos3
    @test pos3 < pos4
    @test pos1 < pos4
    @test !(pos1 < pos1)
    @test !(pos1 > pos1)
    @test pos1 < pos2 && pos2 < pos3 && pos1 < pos3

    # Test <= operator (derived from isless)
    @test pos1 <= pos1
    @test pos1 <= pos2
    @test pos1 <= pos3
    @test pos1 <= pos4
    @test !(pos2 <= pos1)
    @test !(pos3 <= pos2)

    # Test >= operator (derived from isless)
    @test pos1 >= pos1
    @test pos2 >= pos1
    @test pos3 >= pos2
    @test pos4 >= pos1
    @test !(pos1 >= pos2)
    @test !(pos2 >= pos3)

    # Test == operator
    pos1_copy = Position(; line=0, character=0)
    @test pos1 == pos1_copy
    @test pos1 == pos1
    @test !(pos1 == pos2)
    @test !(pos2 == pos3)

    # Test transitivity
    @test pos1 <= pos2 && pos2 <= pos3 && pos1 <= pos3
    @test pos4 >= pos3 && pos3 >= pos2 && pos4 >= pos2

    # Test positions on same line
    pos_same_line_1 = Position(; line=5, character=10)
    pos_same_line_2 = Position(; line=5, character=20)
    pos_same_line_3 = Position(; line=5, character=20)

    @test pos_same_line_1 < pos_same_line_2
    @test pos_same_line_1 <= pos_same_line_2
    @test pos_same_line_2 > pos_same_line_1
    @test pos_same_line_2 >= pos_same_line_1
    @test pos_same_line_2 == pos_same_line_3
    @test pos_same_line_2 <= pos_same_line_3
    @test pos_same_line_2 >= pos_same_line_3

    # Test `pos::Position ∈ rng::Range`
    let rng1 = Range(;
            start = Position(; line=1, character=5),
            var"end" = Position(; line=3, character=10))

        # Positions inside the range
        @test Position(; line=2, character=0) ∈ rng1
        @test Position(; line=2, character=7) ∈ rng1
        @test Position(; line=1, character=10) ∈ rng1

        # Positions at the boundaries (inclusive)
        @test Position(; line=1, character=5) ∈ rng1   # start position
        @test Position(; line=3, character=10) ∈ rng1  # end position

        # Positions outside the range
        @test Position(; line=0, character=0) ∉ rng1    # before start line
        @test Position(; line=1, character=4) ∉ rng1    # same line, before start character
        @test Position(; line=3, character=11) ∉ rng1   # same line, after end character
        @test Position(; line=4, character=0) ∉ rng1    # after end line
    end
    # Test with zero-width range
    let zero_width_rng = Range(;
            start = Position(; line=2, character=5),
            var"end" = Position(; line=2, character=5))

        @test Position(; line=2, character=5) ∈ zero_width_rng
        @test !(Position(; line=2, character=4) ∈ zero_width_rng)
        @test !(Position(; line=2, character=6) ∈ zero_width_rng)

        # Test with single-line range
        single_line_rng = Range(;
            start = Position(; line=5, character=10),
            var"end" = Position(; line=5, character=20))

        @test Position(; line=5, character=10) ∈ single_line_rng
        @test Position(; line=5, character=15) ∈ single_line_rng
        @test Position(; line=5, character=20) ∈ single_line_rng
        @test Position(; line=5, character=9) ∉ single_line_rng
        @test Position(; line=5, character=21) ∉ single_line_rng
        @test Position(; line=4, character=15) ∉ single_line_rng
        @test Position(; line=6, character=15) ∉ single_line_rng
    end
end

@testset "Range containment (∈)" begin
    outer = Range(;
        start = Position(; line=1, character=0),
        var"end" = Position(; line=5, character=10))
    inner = Range(;
        start = Position(; line=2, character=5),
        var"end" = Position(; line=4, character=8))
    overlapping = Range(;
        start = Position(; line=0, character=0),
        var"end" = Position(; line=3, character=5))
    disjoint = Range(;
        start = Position(; line=10, character=0),
        var"end" = Position(; line=12, character=0))

    # Test containment
    @test inner ∈ outer
    @test !(outer ∈ inner)
    @test !(overlapping ∈ outer)
    @test !(disjoint ∈ outer)

    # Test self-containment
    @test outer ∈ outer
    edge_start = Range(;
        start = Position(; line=1, character=0),
        var"end" = Position(; line=2, character=0))
    @test edge_start ∈ outer
    edge_end = Range(;
        start = Position(; line=4, character=0),
        var"end" = Position(; line=5, character=10))
    @test edge_end ∈ outer
end

@testset "Range overlap" begin
    range1 = Range(;
        start = Position(; line=1, character=0),
        var"end" = Position(; line=3, character=10))
    range2 = Range(;
        start = Position(; line=2, character=5),
        var"end" = Position(; line=4, character=15))
    range3 = Range(;
        start = Position(; line=4, character=0),
        var"end" = Position(; line=5, character=0))
    range4 = Range(;
        start = Position(; line=10, character=0),
        var"end" = Position(; line=12, character=0))

    # Test overlapping ranges
    @test JETLS.overlap(range1, range2)
    @test JETLS.overlap(range2, range1)  # Symmetric

    # Test adjacent ranges (touching at boundary)
    @test JETLS.overlap(range2, range3)
    @test JETLS.overlap(range3, range2)  # Symmetric

    # Test disjoint ranges
    @test !JETLS.overlap(range1, range4)
    @test !JETLS.overlap(range4, range1)  # Symmetric

    # Test self-overlap
    @test JETLS.overlap(range1, range1)

    # Test zero-width ranges
    zero_width = Range(;
        start = Position(; line=2, character=7),
        var"end" = Position(; line=2, character=7))
    @test JETLS.overlap(zero_width, range1)
    @test JETLS.overlap(range1, zero_width)

    # Test ranges that touch at a single point
    touch_start = Range(;
        start = Position(; line=0, character=0),
        var"end" = Position(; line=1, character=0))
    touch_end = Range(;
        start = Position(; line=1, character=0),
        var"end" = Position(; line=2, character=0))
    @test JETLS.overlap(touch_start, touch_end)
end

end # module test_lsp
