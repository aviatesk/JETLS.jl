module test_string

using Test
using JETLS: pos_to_utf8_offset, offset_to_xy, xy_to_offset
using JETLS.LSP

@testset "pos_to_utf8_offset" begin
    @testset "ASCII (all encodings identical)" begin
        s = "hello"
        # All encodings produce the same results for ASCII
        for ch in UInt(0):UInt(5)
            utf8  = pos_to_utf8_offset(s, ch, PositionEncodingKind.UTF8)
            utf16 = pos_to_utf8_offset(s, ch, PositionEncodingKind.UTF16)
            utf32 = pos_to_utf8_offset(s, ch, PositionEncodingKind.UTF32)
            @test utf8 == utf16 == utf32 == ch + 1
        end
    end

    @testset "BMP characters (UTF-16 = UTF-32)" begin
        s = "café"  # é is 2 bytes in UTF-8, but 1 unit in UTF-16/32
        # UTF-16 and UTF-32 are identical for BMP characters
        for (ch, expected) in [(0, 1), (1, 2), (2, 3), (3, 4), (4, 6)]
            ch = UInt(ch)
            @test pos_to_utf8_offset(s, ch, PositionEncodingKind.UTF8) == expected
            @test pos_to_utf8_offset(s, ch, PositionEncodingKind.UTF16) == expected
            @test pos_to_utf8_offset(s, ch, PositionEncodingKind.UTF32) == expected
        end
    end

    @testset "Emoji with surrogate pairs (UTF-16 differs)" begin
        s = "a😀b"  # 😀 needs 2 UTF-16 units (surrogate pair)

        # Key differences at position 2 and 3
        @test pos_to_utf8_offset(s, UInt(2), PositionEncodingKind.UTF8) == 6   # After emoji
        @test pos_to_utf8_offset(s, UInt(2), PositionEncodingKind.UTF16) == 2  # Mid-emoji!
        @test pos_to_utf8_offset(s, UInt(2), PositionEncodingKind.UTF32) == 6  # After emoji

        @test pos_to_utf8_offset(s, UInt(3), PositionEncodingKind.UTF8) == 7   # After 'b'
        @test pos_to_utf8_offset(s, UInt(3), PositionEncodingKind.UTF16) == 6  # After emoji
        @test pos_to_utf8_offset(s, UInt(3), PositionEncodingKind.UTF32) == 7  # After 'b'
    end

    @testset "ZWJ sequences (complex UTF-16 handling)" begin
        s = "👨‍👩‍👧‍👦"  # Family: 4 emojis + 3 ZWJs = 11 UTF-16 units
        # UTF-8/32 count 7 characters, UTF-16 counts 11 units
        @test pos_to_utf8_offset(s, UInt(7), PositionEncodingKind.UTF8) == 26
        @test pos_to_utf8_offset(s, UInt(11), PositionEncodingKind.UTF16) == 26
        @test pos_to_utf8_offset(s, UInt(7), PositionEncodingKind.UTF32) == 26
    end

    @testset "Edge cases" begin
        # Empty string
        @test pos_to_utf8_offset("", UInt(0), PositionEncodingKind.UTF16) == 1
        @test pos_to_utf8_offset("", UInt(10), PositionEncodingKind.UTF16) == 1

        # Position beyond string
        @test pos_to_utf8_offset("ab", UInt(10), PositionEncodingKind.UTF16) == 3

        # Single emoji - UTF-16 stops mid-emoji at position 1
        @test pos_to_utf8_offset("😀", UInt(1), PositionEncodingKind.UTF8) == 5
        @test pos_to_utf8_offset("😀", UInt(1), PositionEncodingKind.UTF16) == 1  # Mid-emoji!
        @test pos_to_utf8_offset("😀", UInt(2), PositionEncodingKind.UTF16) == 5
    end

    @testset "UTF-16 vs UTF-8 differences" begin
        s = "a😀b"
        # Position 2: UTF-16 stops mid-emoji, UTF-8 goes past it
        @test pos_to_utf8_offset(s, UInt(2), PositionEncodingKind.UTF16) == 2  # Mid-emoji
        @test pos_to_utf8_offset(s, UInt(2), PositionEncodingKind.UTF8) == 6   # After emoji
        @test pos_to_utf8_offset(s, UInt(2), PositionEncodingKind.UTF16) != pos_to_utf8_offset(s, UInt(2), PositionEncodingKind.UTF8)
    end
end

@testset "offset_to_xy with different encodings" begin
    @testset "ASCII text" begin
        text = "hello"
        textbuf = Vector{UInt8}(text)

        # All encodings should produce same results for ASCII
        for offset in [1, 3, 6]  # start, middle, end+1
            pos_utf8 = offset_to_xy(textbuf, offset, PositionEncodingKind.UTF8)
            pos_utf16 = offset_to_xy(textbuf, offset, PositionEncodingKind.UTF16)
            pos_utf32 = offset_to_xy(textbuf, offset, PositionEncodingKind.UTF32)

            @test pos_utf8.line == 0
            @test pos_utf8.character == offset - 1
            @test pos_utf8 == pos_utf16 == pos_utf32
        end
    end

    @testset "Multi-line text" begin
        text = "line1\nline2\nline3"
        textbuf = Vector{UInt8}(text)

        # Test line boundaries
        @test offset_to_xy(textbuf, 1).line == 0  # Start of line 1
        @test offset_to_xy(textbuf, 6).line == 0  # End of line 1
        @test offset_to_xy(textbuf, 7).line == 1  # Start of line 2
        @test offset_to_xy(textbuf, 12).line == 1  # End of line 2
        @test offset_to_xy(textbuf, 13).line == 2  # Start of line 3

        # Character positions reset on new lines
        @test offset_to_xy(textbuf, 7).character == 0  # Start of line 2
        @test offset_to_xy(textbuf, 8).character == 1  # 'i' in line2
    end

    @testset "BMP characters (café)" begin
        text = "café"  # é is 2 bytes, 1 UTF-16 unit
        textbuf = Vector{UInt8}(text)

        # After 'é' at byte 6
        pos_utf8 = offset_to_xy(textbuf, 6, PositionEncodingKind.UTF8)
        pos_utf16 = offset_to_xy(textbuf, 6, PositionEncodingKind.UTF16)
        pos_utf32 = offset_to_xy(textbuf, 6, PositionEncodingKind.UTF32)

        @test pos_utf8.character == 4  # 4 characters
        @test pos_utf16.character == 4  # 4 UTF-16 units
        @test pos_utf32.character == 4  # 4 codepoints
    end

    @testset "Emoji (non-BMP)" begin
        text = "a😀b"  # 😀 is 4 bytes, 2 UTF-16 units
        textbuf = Vector{UInt8}(text)

        # After emoji at byte 6
        pos_utf8 = offset_to_xy(textbuf, 6, PositionEncodingKind.UTF8)
        pos_utf16 = offset_to_xy(textbuf, 6, PositionEncodingKind.UTF16)
        pos_utf32 = offset_to_xy(textbuf, 6, PositionEncodingKind.UTF32)

        @test pos_utf8.character == 2  # 'a' + '😀'
        @test pos_utf16.character == 3  # 'a' + 2 units for '😀'
        @test pos_utf32.character == 2  # 'a' + '😀'
    end

    @testset "Mixed content" begin
        text = "Hi 世界 😊!"  # ASCII + CJK + Emoji
        textbuf = Vector{UInt8}(text)

        # After "Hi " (byte 4)
        @test offset_to_xy(textbuf, 4, PositionEncodingKind.UTF8).character == 3

        # After "世" (byte 7)
        @test offset_to_xy(textbuf, 7, PositionEncodingKind.UTF8).character == 4
        @test offset_to_xy(textbuf, 7, PositionEncodingKind.UTF16).character == 4

        # After "😊" (byte 15)
        @test offset_to_xy(textbuf, 15, PositionEncodingKind.UTF8).character == 7
        @test offset_to_xy(textbuf, 15, PositionEncodingKind.UTF16).character == 8  # Extra unit for emoji
    end

    @testset "Edge cases" begin
        text = "test"
        textbuf = Vector{UInt8}(text)

        # Invalid offset before start
        @test_throws ArgumentError offset_to_xy(textbuf, 0)

        # Beyond end gets clamped
        pos = offset_to_xy(textbuf, 100)
        @test pos.line == 0
        @test pos.character == 4

        # Empty string
        empty_buf = Vector{UInt8}("")
        @test offset_to_xy(empty_buf, 1).character == 0
    end
end

@testset "xy_to_offset with different encodings" begin
    @testset "Single line ASCII" begin
        text = "hello world"
        textbuf = Vector{UInt8}(text)

        # All encodings same for ASCII
        pos = Position(; line=0, character=6)
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF8) == 7
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF16) == 7
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF32) == 7
    end

    @testset "Multi-line navigation" begin
        text = "first\nsecond\nthird"
        textbuf = Vector{UInt8}(text)

        # Line 0, char 0 -> byte 1
        @test xy_to_offset(textbuf, Position(; line=0, character=0)) == 1

        # Line 1, char 0 -> byte 7 (after "first\n")
        @test xy_to_offset(textbuf, Position(; line=1, character=0)) == 7

        # Line 1, char 3 -> byte 10 ("sec" in second)
        @test xy_to_offset(textbuf, Position(; line=1, character=3)) == 10

        # Line 2, char 2 -> byte 16 ("th" in third)
        @test xy_to_offset(textbuf, Position(; line=2, character=2)) == 16
    end

    @testset "BMP characters" begin
        text = "café"
        textbuf = Vector{UInt8}(text)

        # Position after 'é' - all encodings count it as 1 unit
        pos = Position(; line=0, character=4)
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF8) == 6
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF16) == 6
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF32) == 6
    end

    @testset "Emoji with UTF-16 surrogate pairs" begin
        text = "a😀b"
        textbuf = Vector{UInt8}(text)

        # Position 2: UTF-8/32 -> after emoji, UTF-16 -> middle of emoji
        pos = Position(; line=0, character=2)
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF8) == 6   # After emoji
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF16) == 2  # Middle of emoji!
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF32) == 6  # After emoji

        # Position 3: UTF-8/32 -> after 'b', UTF-16 -> after emoji
        pos = Position(; line=0, character=3)
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF8) == 7   # After 'b'
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF16) == 6  # After emoji
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF32) == 7  # After 'b'
    end

    @testset "Complex Unicode" begin
        text = "α⊕😀"  # Greek + math symbol + emoji
        textbuf = Vector{UInt8}(text)

        # After α (2 bytes)
        pos = Position(; line=0, character=1)
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF8) == 3

        # After ⊕ (3 bytes total from start: α=2 + ⊕=3)
        pos = Position(; line=0, character=2)
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF8) == 6

        # After 😀 with UTF-16 (needs 4 character units: α=1 + ⊕=1 + 😀=2)
        pos = Position(; line=0, character=4)
        @test xy_to_offset(textbuf, pos, PositionEncodingKind.UTF16) == 10
    end

    @testset "Beyond line end" begin
        text = "short\nlonger line\nx"
        textbuf = Vector{UInt8}(text)

        # Character position beyond line end
        pos = Position(; line=0, character=100)
        @test xy_to_offset(textbuf, pos) == 6  # End of "short"

        # Line beyond file
        pos = Position(; line=100, character=0)
        @test xy_to_offset(textbuf, pos) == sizeof(text)  # End of file
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
        for encoding in [PositionEncodingKind.UTF8, PositionEncodingKind.UTF16, PositionEncodingKind.UTF32]
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
                pos = offset_to_xy(textbuf, byte, encoding)
                recovered = xy_to_offset(textbuf, pos, encoding)
                @test recovered == byte
            end
        end
    end
end

end # module test_string
