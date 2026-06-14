module test_text_document_content

using Test
using JETLS
using JETLS.LSP
using JETLS.LSP.URIs2

@testset "parse_text_document_content_query" begin
    # a URI with no query yields no parameters
    let uri = URI(; scheme = "jetls-x", path = "/p")
        @test isempty(JETLS.parse_text_document_content_query(uri))
    end

    # multiple `&`-separated parameters are decoded
    let uri = URI(; scheme = "jetls-x", path = "/p", query = "a=1&b=two")
        params = JETLS.parse_text_document_content_query(uri)
        @test params["a"] == "1"
        @test params["b"] == "two"
    end

    # percent-escaped values round-trip (e.g. a source URI stored as a value)
    let value = "file:///tmp/a b.jl?x=1",
        uri = URI(; scheme = "jetls-x", path = "/p",
                    query = "source=$(URIs2.escapeuri(value))")
        params = JETLS.parse_text_document_content_query(uri)
        @test params["source"] == value
    end

    # only the first `=` splits key/value, and parts without `=` are skipped
    let uri = URI(; scheme = "jetls-x", path = "/p", query = "k=a=b&bogus&c=3")
        params = JETLS.parse_text_document_content_query(uri)
        @test params["k"] == "a=b"
        @test params["c"] == "3"
        @test !haskey(params, "bogus")
    end
end

end # module test_text_document_content
