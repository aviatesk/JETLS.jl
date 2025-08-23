module test_string

using Test
using JETLS: JETLS, pos_to_utf8_offset, offset_to_xy, xy_to_offset
using JETLS.LSP
using JETLS.LSP.PositionEncodingKind: UTF8, UTF16, UTF32

@testset "pos_to_utf8_offset" begin
    @testset "ASCII (all encodings identical)" begin
        s = "hello"
        # All encodings produce the same results for ASCII
        for ch in UInt(0):UInt(5)
            utf8  = pos_to_utf8_offset(s, ch, UTF8)
            utf16 = pos_to_utf8_offset(s, ch, UTF16)
            utf32 = pos_to_utf8_offset(s, ch, UTF32)
            @test utf8 == utf16 == utf32 == ch + 1
        end
    end

    @testset "BMP characters (UTF-16 = UTF-32)" begin
        s = "café"  # é is 2 bytes in UTF-8, but 1 unit in UTF-16/32
        # UTF-16 and UTF-32 are identical for BMP characters
        for (ch, expected) in [(0, 1), (1, 2), (2, 3), (3, 4), (4, 6)]
            ch = UInt(ch)
            @test pos_to_utf8_offset(s, ch, UTF8) == expected
            @test pos_to_utf8_offset(s, ch, UTF16) == expected
            @test pos_to_utf8_offset(s, ch, UTF32) == expected
        end
    end

    @testset "Emoji with surrogate pairs (UTF-16 differs)" begin
        s = "a😀b"  # 😀 needs 2 UTF-16 units (surrogate pair)

        # Key differences at position 2 and 3
        @test pos_to_utf8_offset(s, UInt(2), UTF8) == 6   # After emoji
        @test pos_to_utf8_offset(s, UInt(2), UTF16) == 2  # Mid-emoji!
        @test pos_to_utf8_offset(s, UInt(2), UTF32) == 6  # After emoji

        @test pos_to_utf8_offset(s, UInt(3), UTF8) == 7   # After 'b'
        @test pos_to_utf8_offset(s, UInt(3), UTF16) == 6  # After emoji
        @test pos_to_utf8_offset(s, UInt(3), UTF32) == 7  # After 'b'
    end

    @testset "ZWJ sequences (complex UTF-16 handling)" begin
        s = "👨‍👩‍👧‍👦"  # Family: 4 emojis + 3 ZWJs = 11 UTF-16 units
        # UTF-8/32 count 7 characters, UTF-16 counts 11 units
        @test pos_to_utf8_offset(s, UInt(7), UTF8) == 26
        @test pos_to_utf8_offset(s, UInt(11), UTF16) == 26
        @test pos_to_utf8_offset(s, UInt(7), UTF32) == 26
    end

    @testset "Edge cases" begin
        # Empty string
        @test pos_to_utf8_offset("", UInt(0), UTF16) == 1
        @test pos_to_utf8_offset("", UInt(10), UTF16) == 1

        # Position beyond string
        @test pos_to_utf8_offset("ab", UInt(10), UTF16) == 3

        # Single emoji - UTF-16 stops mid-emoji at position 1
        @test pos_to_utf8_offset("😀", UInt(1), UTF8) == 5
        @test pos_to_utf8_offset("😀", UInt(1), UTF16) == 1  # Mid-emoji!
        @test pos_to_utf8_offset("😀", UInt(2), UTF16) == 5
    end

    @testset "UTF-16 vs UTF-8 differences" begin
        s = "a😀b"
        # Position 2: UTF-16 stops mid-emoji, UTF-8 goes past it
        @test pos_to_utf8_offset(s, UInt(2), UTF16) == 2  # Mid-emoji
        @test pos_to_utf8_offset(s, UInt(2), UTF8) == 6   # After emoji
        @test pos_to_utf8_offset(s, UInt(2), UTF16) != pos_to_utf8_offset(s, UInt(2), UTF8)
    end
end

@testset "offset_to_xy with different encodings" begin
    @testset "ASCII text" begin
        text = "hello"
        textbuf = Vector{UInt8}(text)

        # All encodings should produce same results for ASCII
        for offset in [1, 3, 6]  # start, middle, end+1
            pos_utf8 = offset_to_xy(textbuf, offset, @__FILE__, UTF8)
            pos_utf16 = offset_to_xy(textbuf, offset, @__FILE__, UTF16)
            pos_utf32 = offset_to_xy(textbuf, offset, @__FILE__, UTF32)

            @test pos_utf8.line == 0
            @test pos_utf8.character == offset - 1
            @test pos_utf8 == pos_utf16 == pos_utf32
        end
    end

    @testset "Multi-line text" begin
        text = "line1\nline2\nline3"
        textbuf = Vector{UInt8}(text)

        # Test line boundaries
        @test offset_to_xy(textbuf, 1, @__FILE__).line == 0  # Start of line 1
        @test offset_to_xy(textbuf, 6, @__FILE__).line == 0  # End of line 1
        @test offset_to_xy(textbuf, 7, @__FILE__).line == 1  # Start of line 2
        @test offset_to_xy(textbuf, 12, @__FILE__).line == 1  # End of line 2
        @test offset_to_xy(textbuf, 13, @__FILE__).line == 2  # Start of line 3

        # Character positions reset on new lines
        @test offset_to_xy(textbuf, 7, @__FILE__).character == 0  # Start of line 2
        @test offset_to_xy(textbuf, 8, @__FILE__).character == 1  # 'i' in line2
    end

    @testset "BMP characters (café)" begin
        text = "café"  # é is 2 bytes, 1 UTF-16 unit
        textbuf = Vector{UInt8}(text)

        # After 'é' at byte 6
        pos_utf8 = offset_to_xy(textbuf, 6, @__FILE__, UTF8)
        pos_utf16 = offset_to_xy(textbuf, 6, @__FILE__, UTF16)
        pos_utf32 = offset_to_xy(textbuf, 6, @__FILE__, UTF32)

        @test pos_utf8.character == 4  # 4 characters
        @test pos_utf16.character == 4  # 4 UTF-16 units
        @test pos_utf32.character == 4  # 4 codepoints
    end

    @testset "Emoji (non-BMP)" begin
        text = "a😀b"  # 😀 is 4 bytes, 2 UTF-16 units
        textbuf = Vector{UInt8}(text)

        # After emoji at byte 6
        pos_utf8 = offset_to_xy(textbuf, 6, @__FILE__, UTF8)
        pos_utf16 = offset_to_xy(textbuf, 6, @__FILE__, UTF16)
        pos_utf32 = offset_to_xy(textbuf, 6, @__FILE__, UTF32)

        @test pos_utf8.character == 2  # 'a' + '😀'
        @test pos_utf16.character == 3  # 'a' + 2 units for '😀'
        @test pos_utf32.character == 2  # 'a' + '😀'
    end

    @testset "Mixed content" begin
        text = "Hi 世界 😊!"  # ASCII + CJK + Emoji
        textbuf = Vector{UInt8}(text)

        # After "Hi " (byte 4)
        @test offset_to_xy(textbuf, 4, @__FILE__, UTF8).character == 3

        # After "世" (byte 7)
        @test offset_to_xy(textbuf, 7, @__FILE__, UTF8).character == 4
        @test offset_to_xy(textbuf, 7, @__FILE__, UTF16).character == 4

        # After "😊" (byte 15)
        @test offset_to_xy(textbuf, 15, @__FILE__, UTF8).character == 7
        @test offset_to_xy(textbuf, 15, @__FILE__, UTF16).character == 8  # Extra unit for emoji
    end

    @testset "Edge cases" begin
        text = "test"
        textbuf = Vector{UInt8}(text)

        # Invalid offset before start
        @test_throws ArgumentError offset_to_xy(textbuf, 0, @__FILE__)

        # Beyond end gets clamped
        pos = offset_to_xy(textbuf, 100, @__FILE__)
        @test pos.line == 0
        @test pos.character == 4

        # Empty string
        empty_buf = Vector{UInt8}("")
        @test offset_to_xy(empty_buf, 1, @__FILE__).character == 0
    end
end

@testset "xy_to_offset with different encodings" begin
    @testset "Single line ASCII" begin
        text = "hello world"
        textbuf = Vector{UInt8}(text)

        # All encodings same for ASCII
        pos = Position(; line=0, character=6)
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF8) == 7
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF16) == 7
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF32) == 7
    end

    @testset "Multi-line navigation" begin
        text = "first\nsecond\nthird"
        textbuf = Vector{UInt8}(text)

        # Line 0, char 0 -> byte 1
        @test xy_to_offset(textbuf, Position(; line=0, character=0), @__FILE__) == 1

        # Line 1, char 0 -> byte 7 (after "first\n")
        @test xy_to_offset(textbuf, Position(; line=1, character=0), @__FILE__) == 7

        # Line 1, char 3 -> byte 10 ("sec" in second)
        @test xy_to_offset(textbuf, Position(; line=1, character=3), @__FILE__) == 10

        # Line 2, char 2 -> byte 16 ("th" in third)
        @test xy_to_offset(textbuf, Position(; line=2, character=2), @__FILE__) == 16
    end

    @testset "BMP characters" begin
        text = "café"
        textbuf = Vector{UInt8}(text)

        # Position after 'é' - all encodings count it as 1 unit
        pos = Position(; line=0, character=4)
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF8) == 6
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF16) == 6
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF32) == 6
    end

    @testset "Emoji with UTF-16 surrogate pairs" begin
        text = "a😀b"
        textbuf = Vector{UInt8}(text)

        # Position 2: UTF-8/32 -> after emoji, UTF-16 -> middle of emoji
        pos = Position(; line=0, character=2)
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF8) == 6   # After emoji
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF16) == 2  # Middle of emoji!
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF32) == 6  # After emoji

        # Position 3: UTF-8/32 -> after 'b', UTF-16 -> after emoji
        pos = Position(; line=0, character=3)
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF8) == 7   # After 'b'
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF16) == 6  # After emoji
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF32) == 7  # After 'b'
    end

    @testset "Complex Unicode" begin
        text = "α⊕😀"  # Greek + math symbol + emoji
        textbuf = Vector{UInt8}(text)

        # After α (2 bytes)
        pos = Position(; line=0, character=1)
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF8) == 3

        # After ⊕ (3 bytes total from start: α=2 + ⊕=3)
        pos = Position(; line=0, character=2)
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF8) == 6

        # After 😀 with UTF-16 (needs 4 character units: α=1 + ⊕=1 + 😀=2)
        pos = Position(; line=0, character=4)
        @test xy_to_offset(textbuf, pos, @__FILE__, UTF16) == 10
    end

    @testset "Beyond line end" begin
        text = "short\nlonger line\nx"
        textbuf = Vector{UInt8}(text)

        # Character position beyond line end
        pos = Position(; line=0, character=100)
        @test xy_to_offset(textbuf, pos, @__FILE__) == 6  # End of "short"

        # Line beyond file
        pos = Position(; line=100, character=0)
        @test xy_to_offset(textbuf, pos, @__FILE__) == sizeof(text)  # End of file
    end

    @testset "Guard against invalid positions" begin
        let code = """
            sin
            @nospecialize
            cos(
            """ |> Vector{UInt8}
            ok = true
            for i = 0:10, j = 0:10
                ok &= xy_to_offset(code, Position(i, j), @__FILE__) isa Int
            end
            @test ok
        end
    end
end

@testset "Round-trip conversions" begin
    # Test that xy_to_offset and offset_to_xy are inverses
    # Note: We must test at valid UTF-8 boundaries
    texts = [
        "hello world",
        "line1\nline2\nline3",
        "café",
        "こんにちは",
        "😀😎🎉",
        "mixed 文字 and 😊 emoji"
    ]

    for text in texts
        textbuf = Vector{UInt8}(text)
        for encoding in [UTF8, UTF16, UTF32]
            # Test at character boundaries (valid UTF-8 positions)
            test_positions = [1]  # Start

            # Add some intermediate positions at character boundaries
            offset = 1
            count = 0
            while offset <= sizeof(text) && count < 3
                offset = nextind(text, offset)
                if offset <= sizeof(text)
                    push!(test_positions, offset)
                    count += 1
                end
            end

            # Add end position
            push!(test_positions, sizeof(text) + 1)

            for byte in test_positions
                pos = offset_to_xy(textbuf, byte, @__FILE__, encoding)
                recovered = xy_to_offset(textbuf, pos, @__FILE__, encoding)
                @test recovered == byte
            end
        end
    end
end

function test_string_positions(s)
    v = Vector{UInt8}(s)
    for b in eachindex(s)
        pos = JETLS.offset_to_xy(v, b, @__FILE__)
        b2 =  JETLS.xy_to_offset(v, pos, @__FILE__)
        @test b === b2
    end
    # One past the last byte is a valid position in an editor
    b = length(v) + 1
    pos = JETLS.offset_to_xy(v, b, @__FILE__)
    b2 =  JETLS.xy_to_offset(v, pos, @__FILE__)
    @test b === b2
end
@testset "Cursor file position <-> byte" begin
    fake_files = [
        "",
        "1",
        "\n\n\n",
        """
        aaa
        b
        ccc
        Αα,Ββ,Γγ,Δδ,Εε,Ζζ,Ηη,Θθ,Ιι,Κκ,Λλ,Μμ,Νν,Ξξ,Οο,Ππ,Ρρ,Σσς,Ττ,Υυ,Φφ,Χχ,Ψψ,Ωω
        """
    ]
    for i in eachindex(fake_files)
        @testset "fake_files[$i]" begin
            test_string_positions(fake_files[i])
        end
    end
end

length_utf16(s::AbstractString) = sum(c::Char -> codepoint(c) < 0x10000 ? 1 : 2, collect(s); init=0)
@testset "`get_text_and_positions`" begin
    # Test with simple ASCII text
    let text = "hello │world"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "hello world"
        @test length(positions) == 1
        @test positions[1] == Position(; line=0, character=length_utf16("hello "))
    end

    # Test with multiple markers on same line
    let text = "a│b│c│d"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "abcd"
        @test length(positions) == 3
        @test positions[1] == Position(; line=0, character=length_utf16("a"))
        @test positions[2] == Position(; line=0, character=length_utf16("ab"))
        @test positions[3] == Position(; line=0, character=length_utf16("abc"))
    end

    # Test with multi-line text
    let text = """
        line1│
        line2
        │line3│
        """
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == """
        line1
        line2
        line3
        """
        @test length(positions) == 3
        @test positions[1] == Position(; line=0, character=length_utf16("line1"))
        @test positions[2] == Position(; line=2, character=length_utf16(""))
        @test positions[3] == Position(; line=2, character=length_utf16("line3"))
    end

    # Test with multi-byte characters (Greek letters)
    let text = "α│β│γ"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "αβγ"
        @test length(positions) == 2
        @test positions[1] == Position(; line=0, character=length_utf16("α"))
        @test positions[2] == Position(; line=0, character=length_utf16("αβ"))
    end

    # Test with mixed ASCII and multi-byte characters
    let text = "hello α│β world │γ"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "hello αβ world γ"
        @test length(positions) == 2
        @test positions[1] == Position(; line=0, character=length_utf16("hello α"))
        @test positions[2] == Position(; line=0, character=length_utf16("hello αβ world "))
    end

    let text = "😀│😎│🎉"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "😀😎🎉"
        @test length(positions) == 2
        # Each emoji is 2 UTF-16 units (default encoding)
        @test positions[1] == Position(; line=0, character=length_utf16("😀"))
        @test positions[2] == Position(; line=0, character=length_utf16("😀😎"))
    end

    # Test with custom marker
    let text = "foo<HERE>bar<HERE>baz"
        clean_text, positions = JETLS.get_text_and_positions(text; matcher=r"<HERE>")
        @test clean_text == "foobarbaz"
        @test length(positions) == 2
        @test positions[1] == Position(; line=0, character=length_utf16("foo"))
        @test positions[2] == Position(; line=0, character=length_utf16("foobar"))
    end

    # Test empty text
    let text = ""
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == ""
        @test isempty(positions)
    end

    # Test text with no markers
    let text = "no markers here"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "no markers here"
        @test isempty(positions)
    end

    # Test markers at beginning and end
    let text = "│start middle end│"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "start middle end"
        @test length(positions) == 2
        @test positions[1] == Position(; line=0, character=0)
        @test positions[2] == Position(; line=0, character=length_utf16("start middle end"))
    end

    # Test complex multi-byte scenario matching our byte_ancestors test
    let text = "α = β + │γ"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "α = β + γ"
        @test length(positions) == 1
        @test positions[1] == Position(; line=0, character=length_utf16("α = β + "))
    end
end

end # module test_string
