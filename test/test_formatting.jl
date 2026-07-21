module test_formatting

include("setup.jl")

using Test
using JETLS
using JETLS.LSP
using JETLS.URIs2

function make_range(
        start_line::Int, start_character::Int, end_line::Int, end_character::Int
    )
    return Range(;
        start = Position(; line = start_line, character = start_character),
        var"end" = Position(; line = end_line, character = end_character))
end

function formatting_options()
    return FormattingOptions(; tabSize = 4, insertSpaces = true)
end

function ranges_formatting_capabilities()
    return ClientCapabilities(;
        textDocument = TextDocumentClientCapabilities(;
            rangeFormatting = DocumentRangeFormattingClientCapabilities(;
                rangesSupport = true)))
end

function store_lsp_config!(server::JETLS.Server, config::JETLS.JETLSConfig)
    JETLS.store!(server.state.config_manager) do old_data::JETLS.ConfigManagerData
        new_data = JETLS.ConfigManagerData(old_data; lsp_config = config)
        return new_data, nothing
    end
end

function write_passthrough_formatter(tempdir::AbstractString)
    exe = joinpath(tempdir, "passthrough-formatter")
    args_file = joinpath(tempdir, "formatter-args.txt")
    write(exe,
        "#!/bin/sh\n" *
        ": > \"\$JETLS_TEST_FORMATTER_ARGS\"\n" *
        "for arg do\n" *
        "    printf '%s\\n' \"\$arg\" >> \"\$JETLS_TEST_FORMATTER_ARGS\"\n" *
        "done\n" *
        "cat\n")
    chmod(exe, 0o755)
    return (; exe, args_file)
end

function with_passthrough_formatter(f, tempdir::AbstractString)
    (; exe, args_file) = write_passthrough_formatter(tempdir)
    return withenv("JETLS_TEST_FORMATTER_ARGS" => args_file) do
        f(exe, args_file)
    end
end

function configure_formatter!(server::JETLS.Server, exe::AbstractString)
    return store_lsp_config!(server, JETLS.JETLSConfig(;
        formatter = JETLS.CustomFormatterConfig(exe, exe)))
end

function cache_test_file!(server::JETLS.Server, uri::URI, text::AbstractString)
    return JETLS.cache_file_info!(server, uri, 1, text)
end

function write_fixed_output_formatter(tempdir::AbstractString)
    exe = joinpath(tempdir, "fixed-output-formatter")
    output_file = joinpath(tempdir, "formatter-output.txt")
    write(exe,
        "#!/bin/sh\n" *
        "cat > /dev/null\n" *
        "cat \"\$JETLS_TEST_FORMATTER_OUTPUT\"\n")
    chmod(exe, 0o755)
    return (; exe, output_file)
end

function apply_text_edits(text::AbstractString, edits::Vector{TextEdit}, encoding)
    result = String(text)
    for edit in sort(edits; by = e -> (e.range.start.line, e.range.start.character), rev = true)
        result = JETLS.apply_text_change(result, edit.range, edit.newText, encoding)
    end
    return result
end

const FORMATTING_EDIT_FIXTURES = Tuple{String,String,String}[
    ("identical",         "a = 1\nb = 2\n",   "a = 1\nb = 2\n"),
    ("middle line",       "a=1\nb=2\nc=3\n",  "a=1\nb = 2\nc=3\n"),
    ("first line",        "a=1\nb=2\nc=3\n",  "a = 1\nb=2\nc=3\n"),
    ("last line",         "a=1\nb=2\nc=3\n",  "a=1\nb=2\nc = 3\n"),
    ("insert line",       "a=1\nc=3\n",       "a=1\nb=2\nc=3\n"),
    ("delete line",       "a=1\nb=2\nc=3\n",  "a=1\nc=3\n"),
    ("whole document",    "a=1\nb=2\n",       "x=9\ny=8\n"),
    ("gain trailing nl",  "a=1\nb=2",         "a=1\nb=2\n"),
    ("drop trailing nl",  "a=1\nb=2\n",       "a=1\nb=2"),
    ("empty to text",     "",                 "a=1\n"),
    ("text to empty",     "a=1\n",            ""),
    ("multibyte middle",  "α=1\nβ=2\nγ=3\n",  "α=1\nβ = 2\nγ=3\n"),
]

@testset "textDocument/formatting handler" begin
    @static if Sys.iswindows()
        @test_skip "shell-script-backed formatter test is Unix-only"
    else
        mktempdir() do tempdir
            text = "a=1\nb=2\n"
            uri = filepath2uri(joinpath(tempdir, "test.jl"))

            with_passthrough_formatter(tempdir) do exe, args_file
                withserver() do (; server, writereadmsg, id_counter)
                    configure_formatter!(server, exe)
                    cache_test_file!(server, uri, text)

                    request = DocumentFormattingRequest(;
                        id = id_counter[] += 1,
                        params = DocumentFormattingParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            options = formatting_options()))
                    (; raw_res) = writereadmsg(request)

                    @test raw_res isa DocumentFormattingResponse
                    @test raw_res.result isa Vector{TextEdit}
                    @test isempty(raw_res.result)
                    @test readlines(args_file) == String[]
                end
            end
        end
    end
end

@testset "textDocument/rangeFormatting handler" begin
    @static if Sys.iswindows()
        @test_skip "shell-script-backed formatter test is Unix-only"
    else
        mktempdir() do tempdir
            text = "a=1\nb=2\nc=3\n"
            uri = filepath2uri(joinpath(tempdir, "test.jl"))
            range = make_range(1, 0, 2, 3)

            with_passthrough_formatter(tempdir) do exe, args_file
                withserver() do (; server, writereadmsg, id_counter)
                    configure_formatter!(server, exe)
                    cache_test_file!(server, uri, text)

                    request = DocumentRangeFormattingRequest(;
                        id = id_counter[] += 1,
                        params = DocumentRangeFormattingParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            range,
                            options = formatting_options()))
                    (; raw_res) = writereadmsg(request)

                    @test raw_res isa DocumentRangeFormattingResponse
                    @test raw_res.result isa Vector{TextEdit}
                    @test isempty(raw_res.result)
                    @test readlines(args_file) == ["--lines=2:3"]
                end
            end
        end
    end
end

@testset "textDocument/rangesFormatting handler" begin
    @static if Sys.iswindows()
        @test_skip "shell-script-backed formatter test is Unix-only"
    else
        mktempdir() do tempdir
            text = "a=1\nb=2\nc=3\nd=4\n"
            uri = filepath2uri(joinpath(tempdir, "test.jl"))
            ranges = Range[
                make_range(0, 0, 1, 3),
                make_range(3, 0, 3, 3),
            ]

            with_passthrough_formatter(tempdir) do exe, args_file
                withserver(; capabilities = ranges_formatting_capabilities()) do argnt
                    (; server, writereadmsg, id_counter) = argnt
                    configure_formatter!(server, exe)
                    cache_test_file!(server, uri, text)

                    request = DocumentRangesFormattingRequest(;
                        id = id_counter[] += 1,
                        params = DocumentRangesFormattingParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            ranges,
                            options = formatting_options()))
                    (; raw_res) = writereadmsg(request)

                    @test raw_res isa DocumentRangesFormattingResponse
                    @test raw_res.result isa Vector{TextEdit}
                    @test isempty(raw_res.result)
                    @test readlines(args_file) == ["--lines=1:2", "--lines=4:4"]
                end
            end
        end
    end
end

@testset "textDocument/formatting minimal edits reproduce formatter output" begin
    @static if Sys.iswindows()
        @test_skip "shell-script-backed formatter test is Unix-only"
    else
        mktempdir() do tempdir
            (; exe, output_file) = write_fixed_output_formatter(tempdir)
            withenv("JETLS_TEST_FORMATTER_OUTPUT" => output_file) do
                withserver() do (; server, writereadmsg, id_counter)
                    configure_formatter!(server, exe)
                    encoding = server.state.encoding
                    for (i, (name, original, formatted)) in enumerate(FORMATTING_EDIT_FIXTURES)
                        write(output_file, formatted)
                        uri = filepath2uri(joinpath(tempdir, "fixture_$i.jl"))
                        cache_test_file!(server, uri, original)

                        request = DocumentFormattingRequest(;
                            id = id_counter[] += 1,
                            params = DocumentFormattingParams(;
                                textDocument = TextDocumentIdentifier(; uri),
                                options = formatting_options()))
                        (; raw_res) = writereadmsg(request)

                        @test raw_res isa DocumentFormattingResponse
                        edits = raw_res.result
                        @test edits isa Vector{TextEdit}
                        if original == formatted
                            @test isempty(edits)
                        else
                            @test !isempty(edits)
                        end
                        @test apply_text_edits(original, edits, encoding) == formatted
                    end
                end
            end
        end
    end
end

@testset "textDocument/formatting minimal edit excludes untouched lines" begin
    @static if Sys.iswindows()
        @test_skip "shell-script-backed formatter test is Unix-only"
    else
        mktempdir() do tempdir
            (; exe, output_file) = write_fixed_output_formatter(tempdir)
            original = "a=1\nb=2\nc=3\nd=4\n"
            formatted = "a=1\nb=2\nc = 3\nd=4\n"
            write(output_file, formatted)
            withenv("JETLS_TEST_FORMATTER_OUTPUT" => output_file) do
                withserver() do (; server, writereadmsg, id_counter)
                    configure_formatter!(server, exe)
                    uri = filepath2uri(joinpath(tempdir, "middle.jl"))
                    cache_test_file!(server, uri, original)

                    request = DocumentFormattingRequest(;
                        id = id_counter[] += 1,
                        params = DocumentFormattingParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            options = formatting_options()))
                    (; raw_res) = writereadmsg(request)

                    @test raw_res isa DocumentFormattingResponse
                    edits = raw_res.result
                    @test edits isa Vector{TextEdit}
                    @test length(edits) == 1
                    edit = only(edits)
                    @test edit.range.start.line == 2
                    @test edit.range.start.character == 0
                    @test edit.range.var"end".line == 3
                    @test edit.range.var"end".character == 0
                    @test edit.newText == "c = 3\n"
                    @test apply_text_edits(original, edits, server.state.encoding) == formatted
                end
            end
        end
    end
end

end # module test_formatting
