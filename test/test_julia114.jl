module test_julia114

include("setup.jl")

using Test
using JETLS
using JETLS.LSP
using JETLS.URIs2

@testset "JETLS boots and handshakes on $(VERSION)" begin
    @test withserver(Returns(true))
end

@testset "JETLS analyzes and publishes diagnostics on $(VERSION)" begin
    scriptcode = """
    include("nonexistent_jetls_114_probe.jl")
    """
    withscript(scriptcode) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, scriptcode))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri
            found = false
            for diag in raw_res.params.diagnostics
                if diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE && diag.range.start.line == 0
                    found = true
                    break
                end
            end
            @test found
        end
    end
end

end # module test_julia114
