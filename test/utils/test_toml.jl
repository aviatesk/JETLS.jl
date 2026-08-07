module test_toml

using Test
using JETLS: JETLS, TOML

function array_content_start(text::String)
    open_bracket = findfirst(==('['), text)::Int
    return nextind(text, open_bracket)
end

@testset "format_toml_inline_table" begin
    table = Dict{String,Any}(
        "pattern" => "A\nB\t\u0001\\\"雪",
        "path" => "src/A\nB\t\u0001\\\"雪.jl",
        "enabled" => true)
    text = JETLS.format_toml_inline_table(table)
    @test only(TOML.parse("entries = [$text]")["entries"]) == table
end

@testset "toml_array_entry_insertion" begin
    entry = "{ value = 2 }"

    let text = "entries = []", content_start = array_content_start(text)
        @test JETLS.toml_array_entry_insertion(
            text, content_start, entry, #=isempty_array=#true) ==
            (content_start, entry)
    end

    let text = "entries = [{ value = 1 }]", content_start = array_content_start(text)
        @test JETLS.toml_array_entry_insertion(
            text, content_start, entry, #=isempty_array=#false) ==
            (content_start, entry * ", ")
    end

    let text = "entries = [\n    ]", content_start = array_content_start(text)
        close_bracket = findfirst(==(']'), text)::Int
        @test JETLS.toml_array_entry_insertion(
            text, content_start, entry, #=isempty_array=#true) ==
            (close_bracket, "\n    $entry\n    ")
    end

    let text = "entries = [\r\n\t{ value = 1 },\r\n]",
        content_start = array_content_start(text)
        first_entry = findfirst(==('{'), text)::Int
        @test JETLS.toml_array_entry_insertion(
            text, content_start, entry, #=isempty_array=#false) ==
            (first_entry, "\r\n\t$entry,\r\n\t")
    end
end

end # module test_toml
