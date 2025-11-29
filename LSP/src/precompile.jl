function test_roundtrip(f, s::AbstractString, Typ)
    x = JSON3.read(s, Typ)
    f(x)
    s′ = to_lsp_json(x)
    x′ = JSON3.read(s′, Typ)
    f(x′)
end

function test_roundtrip(f, s::AbstractString)
    x = to_lsp_object(s)
    f(x)
    s′ = to_lsp_json(x)
    x′ = to_lsp_object(s′)
    f(x′)
end

using PrecompileTools

@setup_workload let
    uri = LSP.URIs2.filepath2uri(abspath(@__FILE__))
    @compile_workload let
        test_roundtrip("""{
                "jsonrpc": "2.0",
                "id": 0,
                "method": "textDocument/completion",
                "params": {
                    "textDocument": {
                        "uri": "$uri"
                    },
                    "position": {
                        "line": 0,
                        "character": 0
                    },
                    "workDoneToken": "workDoneToken",
                    "partialResultToken": "partialResultToken"
                }
            }""") do req
            @assert req isa CompletionRequest
        end
        test_roundtrip("""{
                "jsonrpc": "2.0",
                "id": 0,
                "method": "completionItem/resolve",
                "params": {
                    "label": "label",
                    "textEdit": {
                        "range": {
                            "start": {
                                "line": 0,
                                "character": 0
                            },
                            "end": {
                                "line": 0,
                                "character": 0
                            }
                        },
                        "newText": "newText"
                    }
                }
            }""") do req
            @assert req isa CompletionResolveRequest
            @assert req.params.textEdit isa TextEdit
        end
    end
end
