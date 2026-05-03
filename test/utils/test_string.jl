module test_string

using Test
using JETLS: JETLS, apply_text_change, encoded_length, offset_to_xy, xy_to_offset
using JETLS.LSP
using JETLS.LSP.PositionEncodingKind: UTF16, UTF32, UTF8

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

        @test pos_utf8.character == 5  # Byte offset 5 (0-based)
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

        @test pos_utf8.character == 5  # Byte offset 5 (0-based)
        @test pos_utf16.character == 3  # 'a' + 2 units for '😀'
        @test pos_utf32.character == 2  # 'a' + '😀'
    end

    @testset "Mixed content" begin
        text = "Hi 世界 😊!"  # ASCII + CJK + Emoji
        textbuf = Vector{UInt8}(text)

        # After "Hi " (byte 4)
        @test offset_to_xy(textbuf, 4, @__FILE__, UTF8).character == 3  # Byte offset 3

        # After "世" (byte 7) - 世 is 3 bytes
        @test offset_to_xy(textbuf, 7, @__FILE__, UTF8).character == 6  # Byte offset 6
        @test offset_to_xy(textbuf, 7, @__FILE__, UTF16).character == 4

        # After "😊" (byte 15)
        @test offset_to_xy(textbuf, 15, @__FILE__, UTF8).character == 14  # Byte offset 14
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

        # Position after 'é' - UTF-8 uses byte offset, UTF-16/32 use character count
        pos_utf8 = Position(; line=0, character=5)  # Byte offset 5
        pos_utf16 = Position(; line=0, character=4)  # Character 4
        @test xy_to_offset(textbuf, pos_utf8, @__FILE__, UTF8) == 6
        @test xy_to_offset(textbuf, pos_utf16, @__FILE__, UTF16) == 6
        @test xy_to_offset(textbuf, pos_utf16, @__FILE__, UTF32) == 6
    end

    @testset "Emoji with UTF-16 surrogate pairs" begin
        text = "a😀b"  # a=1 byte, 😀=4 bytes, b=1 byte
        textbuf = Vector{UInt8}(text)

        # UTF-8: character is byte offset
        # UTF-16: character is UTF-16 code unit count
        # UTF-32: character is character count

        # Position 2 in UTF-8 = byte 2
        pos_utf8 = Position(; line=0, character=2)
        @test xy_to_offset(textbuf, pos_utf8, @__FILE__, UTF8) == 3  # Byte 2+1

        # Position 2 in UTF-16 = after 'a', in middle of emoji
        pos_utf16 = Position(; line=0, character=2)
        @test xy_to_offset(textbuf, pos_utf16, @__FILE__, UTF16) == 2  # Middle of emoji!

        # Position 2 in UTF-32 = after emoji
        pos_utf32 = Position(; line=0, character=2)
        @test xy_to_offset(textbuf, pos_utf32, @__FILE__, UTF32) == 6  # After emoji

        # Position 5 in UTF-8 = byte 5 (after emoji)
        pos_utf8_5 = Position(; line=0, character=5)
        @test xy_to_offset(textbuf, pos_utf8_5, @__FILE__, UTF8) == 6

        # Position 3 in UTF-16 = after emoji
        pos_utf16_3 = Position(; line=0, character=3)
        @test xy_to_offset(textbuf, pos_utf16_3, @__FILE__, UTF16) == 6  # After emoji
    end

    @testset "Complex Unicode" begin
        text = "α⊕😀"  # α=2 bytes, ⊕=3 bytes, 😀=4 bytes
        textbuf = Vector{UInt8}(text)

        # UTF-8: After α (byte offset 2)
        pos_utf8 = Position(; line=0, character=2)
        @test xy_to_offset(textbuf, pos_utf8, @__FILE__, UTF8) == 3

        # UTF-8: After ⊕ (byte offset 5 = 2+3)
        pos_utf8_5 = Position(; line=0, character=5)
        @test xy_to_offset(textbuf, pos_utf8_5, @__FILE__, UTF8) == 6

        # UTF-16: After 😀 (needs 4 character units: α=1 + ⊕=1 + 😀=2)
        pos_utf16 = Position(; line=0, character=4)
        @test xy_to_offset(textbuf, pos_utf16, @__FILE__, UTF16) == 10
    end

    # Each grapheme is a non-BMP emoji (4 UTF-8 bytes / 2 UTF-16 units) joined
    # by ZWJ (3 UTF-8 bytes / 1 UTF-16 unit / 1 UTF-32 char). Code-unit counts
    # diverge sharply across encodings, which is where unit accumulation bugs
    # tend to surface.
    @testset "ZWJ sequences" begin
        text = "👨‍👩‍👧‍👦" # Family: 4 emojis + 3 ZWJs = 25 bytes UTF-8 / 11 UTF-16 / 7 UTF-32
        textbuf = Vector{UInt8}(text)
        @test xy_to_offset(textbuf, Position(; line=0, character=25), @__FILE__, UTF8) == 26
        @test xy_to_offset(textbuf, Position(; line=0, character=11), @__FILE__, UTF16) == 26
        @test xy_to_offset(textbuf, Position(; line=0, character=7), @__FILE__, UTF32) == 26
    end

    # `≈\` is a real input shape from LaTeX-symbol completion (`\approx\<TAB>`):
    # `≈` is a 3-byte BMP char (1 UTF-16 unit) followed by a 1-byte `\`. Regression
    # guard for the off-by-one that earlier completion code hit here.
    @testset "LaTeX symbol completion shape (≈\\\\)" begin
        text = "≈\\"
        textbuf = Vector{UInt8}(text)
        @test xy_to_offset(textbuf, Position(; line=0, character=3), @__FILE__, UTF8) == 4   # after ≈
        @test xy_to_offset(textbuf, Position(; line=0, character=4), @__FILE__, UTF8) == 5   # after \
        @test xy_to_offset(textbuf, Position(; line=0, character=1), @__FILE__, UTF16) == 4  # after ≈
        @test xy_to_offset(textbuf, Position(; line=0, character=2), @__FILE__, UTF16) == 5  # after \
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

    # Mid-char input does NOT round-trip (snap loses information), but the
    # snap is idempotent: byte → Position → byte_start → Position → same
    # byte_start. Cross-direction guard against accidentally flipping snap
    # direction in only one of the two functions.
    @testset "Mid-char snap is idempotent" begin
        # "café": é spans bytes 4-5; mid-char byte=5 should snap to byte=4
        let textbuf = Vector{UInt8}("café")
            for encoding in (UTF16, UTF32)
                pos1 = offset_to_xy(textbuf, 5, @__FILE__, encoding)
                byte1 = xy_to_offset(textbuf, pos1, @__FILE__, encoding)
                @test byte1 == 4 # snapped to start of é, not original 5
                pos2 = offset_to_xy(textbuf, byte1, @__FILE__, encoding)
                @test xy_to_offset(textbuf, pos2, @__FILE__, encoding) == byte1
            end
        end
        # "😀b": emoji spans bytes 1-4; any mid-emoji byte snaps to byte=1
        let textbuf = Vector{UInt8}("😀b")
            for encoding in (UTF16, UTF32), b in 2:4
                pos1 = offset_to_xy(textbuf, b, @__FILE__, encoding)
                byte1 = xy_to_offset(textbuf, pos1, @__FILE__, encoding)
                @test byte1 == 1
                pos2 = offset_to_xy(textbuf, byte1, @__FILE__, encoding)
                @test xy_to_offset(textbuf, pos2, @__FILE__, encoding) == byte1
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

@testset "apply_text_change" begin
    # Insert at beginning
    let text = "hello"
        range = Range(; start=Position(; line=0, character=0), var"end"=Position(; line=0, character=0))
        @test apply_text_change(text, range, "world ", UTF16) == "world hello"
    end

    # Insert at end
    let text = "hello"
        range = Range(; start=Position(; line=0, character=5), var"end"=Position(; line=0, character=5))
        @test apply_text_change(text, range, " world", UTF16) == "hello world"
    end

    # Replace in middle
    let text = "hello world"
        range = Range(; start=Position(; line=0, character=6), var"end"=Position(; line=0, character=11))
        @test apply_text_change(text, range, "there", UTF16) == "hello there"
    end

    # Delete (replace with empty)
    let text = "hello world"
        range = Range(; start=Position(; line=0, character=5), var"end"=Position(; line=0, character=11))
        @test apply_text_change(text, range, "", UTF16) == "hello"
    end

    # Multi-line: insert newline
    let text = "ab"
        range = Range(; start=Position(; line=0, character=1), var"end"=Position(; line=0, character=1))
        @test apply_text_change(text, range, "\n", UTF16) == "a\nb"
    end

    # Multi-line: replace across lines
    let text = "line1\nline2\nline3"
        range = Range(; start=Position(; line=0, character=5), var"end"=Position(; line=2, character=0))
        @test apply_text_change(text, range, "\n", UTF16) == "line1\nline3"
    end

    # Non-BMP character (emoji)
    let text = "a😀b"
        # After emoji: UTF-16 position is 3 (a=1 + 😀=2)
        range = Range(; start=Position(; line=0, character=3), var"end"=Position(; line=0, character=3))
        @test apply_text_change(text, range, "x", UTF16) == "a😀xb"
    end

    # BMP multi-byte character
    let text = "café"
        # Replace é (UTF-16 position 3, byte position 4-5)
        range = Range(; start=Position(; line=0, character=3), var"end"=Position(; line=0, character=4))
        @test apply_text_change(text, range, "e", UTF16) == "cafe"
    end
end

@testset "encoded_length" begin
    # ASCII: all encodings equal sizeof
    @test encoded_length("hello", UTF8) == 5
    @test encoded_length("hello", UTF16) == 5
    @test encoded_length("hello", UTF32) == 5

    # BMP characters (日本語): UTF-8 > UTF-16 = UTF-32
    @test encoded_length("日本語", UTF8) == 9   # 3 bytes each
    @test encoded_length("日本語", UTF16) == 3  # 1 unit each
    @test encoded_length("日本語", UTF32) == 3  # 1 char each

    # Non-BMP (emoji): UTF-8 > UTF-16 > UTF-32
    @test encoded_length("😀", UTF8) == 4   # 4 bytes
    @test encoded_length("😀", UTF16) == 2  # surrogate pair
    @test encoded_length("😀", UTF32) == 1  # 1 char

    # Mixed: ASCII + BMP + non-BMP
    s = "a日😀"
    @test encoded_length(s, UTF8) == 1 + 3 + 4  # 8
    @test encoded_length(s, UTF16) == 1 + 1 + 2 # 4
    @test encoded_length(s, UTF32) == 1 + 1 + 1 # 3
end

end # module test_string
