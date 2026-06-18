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
                    @test length(raw_res.result) == 1
                    @test raw_res.result[1].newText == text
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
                    @test length(raw_res.result) == 1
                    @test raw_res.result[1].newText == text
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
                    @test length(raw_res.result) == 1
                    @test raw_res.result[1].newText == text
                    @test readlines(args_file) == ["--lines=1:2", "--lines=4:4"]
                end
            end
        end
    end
end

end # module test_formatting
