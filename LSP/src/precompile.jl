function readlsp(msg_str::AbstractString)
    lazyjson = JSON.lazy(msg_str)
    if hasproperty(lazyjson, :method)
        method = lazyjson.method[]
        if haskey(method_dispatcher, method)
            return JSON.parse(lazyjson, method_dispatcher[method])
        end
        return JSON.parse(lazyjson, Dict{Symbol,Any})
    else # TODO parse to ResponseMessage?
        return JSON.parse(lazyjson, Dict{Symbol,Any})
    end
end
writelsp(x) = JSON.json(x; omit_null=true)

function test_roundtrip(f, s::AbstractString, Typ)
    x = JSON.parse(s, Typ)
    f(x)
    s′ = writelsp(x)
    x′ = JSON.parse(s′, Typ)
    f(x′)
end

using PrecompileTools

@setup_workload let
    uri = LSP.URIs2.filepath2uri(abspath(@__FILE__))
    @compile_workload let
        test_roundtrip("""{
                "jsonrpc": "2.0",
                "id":0, "method":"textDocument/completion",
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
            }""", CompletionRequest) do req
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
            }""", CompletionResolveRequest) do req
            @assert req isa CompletionResolveRequest
            @assert req.params.textEdit isa TextEdit
        end
    end
end
