using LSP
using LSP.URIs2
using LSP: to_lsp_json, test_roundtrip
using Test

@testset "LSP" begin
    # De/serializing complex LSP objects
    uri = filename2uri(@__FILE__)

    test_roundtrip("""{
            "jsonrpc": "2.0",
            "id": 0,
            "result": null
        }""", DefinitionResponse) do res
        @test res isa DefinitionResponse
        @test res.result === null # this null should be preserved through the roundtrip
    end
    test_roundtrip("""{
            "jsonrpc": "2.0",
            "id": 0,
            "result": {
                "uri": "$uri",
                "range": {
                    "start": {
                        "line": 0,
                        "character": 0
                    },
                    "end": {
                        "line": 0,
                        "character": 5
                    }
                }
            }
        }""", DefinitionResponse) do res
        @test res isa DefinitionResponse
        @test res.result isa Location
    end
    test_roundtrip("""{
            "jsonrpc": "2.0",
            "id": 0,
            "result": [{
                "uri": "$uri",
                "range": {
                    "start": {
                        "line": 0,
                        "character": 0
                    },
                    "end": {
                        "line": 0,
                        "character": 5
                    }
                }
            }]
        }""", DefinitionResponse) do res
        @test res isa DefinitionResponse
        @test res.result isa Vector{Location}
    end
    test_roundtrip("""{
            "jsonrpc": "2.0",
            "id": 0,
            "result": [{
                "targetUri": "$uri",
                "targetRange": {
                    "start": {
                        "line": 0,
                        "character": 0
                    },
                    "end": {
                        "line": 0,
                        "character": 5
                    }
                },
                "targetSelectionRange": {
                    "start": {
                        "line": 0,
                        "character": 0
                    },
                    "end": {
                        "line": 0,
                        "character": 5
                    }
                }
            }]
        }""", DefinitionResponse) do res
        @test res isa DefinitionResponse
        @test res.result isa Vector{LocationLink}
    end
    test_roundtrip("""{
            "jsonrpc": "2.0",
            "id": 0,
            "error": {
                "code": $(ErrorCodes.InvalidRequest),
                "message": "Test message"
            }
        }""", DefinitionResponse) do res
        @test res isa DefinitionResponse
        @test res.result === nothing
        @test res.error isa ResponseError
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
        @test req isa CompletionResolveRequest
        @test req.params.textEdit isa TextEdit
    end
    test_roundtrip("""{
            "jsonrpc": "2.0",
            "id": 0,
            "method": "completionItem/resolve",
            "params": {
                "label": "label",
                "textEdit": {
                    "newText": "newText",
                    "insert": {
                        "start": {
                            "line": 0,
                            "character": 0
                        },
                        "end": {
                            "line": 0,
                            "character": 0
                        }
                    },
                    "replace": {
                        "start": {
                            "line": 0,
                            "character": 0
                        },
                        "end": {
                            "line": 0,
                            "character": 6
                        }
                    }
                }
            }
        }""", CompletionResolveRequest) do req
        @test req isa CompletionResolveRequest
        @test req.params.textEdit isa InsertReplaceEdit
    end
    test_roundtrip("""{
            "jsonrpc": "2.0",
            "id": 0,
            "method": "completionItem/resolve",
            "params": {
                "label": "label",
                "documentation": "documentation"
            }
        }""", CompletionResolveRequest) do req
        @test req isa CompletionResolveRequest
        @test req.params.documentation isa String
    end
    test_roundtrip("""{
            "jsonrpc": "2.0",
            "id": 0,
            "method": "completionItem/resolve",
            "params": {
                "label": "label",
                "documentation": {
                    "kind": "markdown",
                    "value": "value"
                }
            }
        }""", CompletionResolveRequest) do req
        @test req isa CompletionResolveRequest
        @test req.params.documentation isa MarkupContent
    end

    test_roundtrip("""
        {
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": {
                "processId": 42,
                "clientInfo": {
                    "name": "Test client",
                    "version": "1.0"
                },
                "capabilities": {},
                "workspaceFolders": []
            }
        }
        """) do init_req
        @test init_req isa InitializeRequest
        @test init_req.jsonrpc == "2.0"
        @test init_req.id == 0
        @test init_req.method == "initialize"
        @test init_req.params.processId == 42
        @test init_req.params.clientInfo.name == "Test client"
        @test init_req.params.clientInfo.version == "1.0"
        @test init_req.params.capabilities == ClientCapabilities()
        @test init_req.params.workspaceFolders isa Vector{WorkspaceFolder} && isempty(init_req.params.workspaceFolders)
    end

    # ResponseMessage should omit the `error` field on success, and omit `result` an error
    @testset "ResponseMessage result field" begin
        success_res = ResponseMessage(;
            id = "id",
            result = null)
        success_res_s = to_lsp_json(success_res)
        @test occursin("\"result\"", success_res_s) && occursin("null", success_res_s)
        @test !occursin("\"error\"", success_res_s)
    end
    @testset "ResponseMessage error field" begin
        error_res = ResponseMessage(;
            id = "id",
            result = nothing,
            error = ResponseError(;
                code = ErrorCodes.RequestFailed,
                message = "test message",
                data = :test_data))
        error_res_s = to_lsp_json(error_res)
        @test !occursin("\"result\"", error_res_s)
        @test occursin("\"error\"", error_res_s)
    end
end
