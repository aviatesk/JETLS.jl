using LSP
using JSON
using Test

function readlsp(msg_str::AbstractString)
    lazyjson = JSON.lazy(msg_str)
    if hasproperty(lazyjson, :method)
        method = lazyjson.method[]
        if haskey(LSP.method_dispatcher, method)
            return JSON.parse(lazyjson, LSP.method_dispatcher[method])
        end
        return JSON.parse(lazyjson, Dict{Symbol,Any})
    else # TODO parse to ResponseMessage?
        return JSON.parse(lazyjson, Dict{Symbol,Any})
    end
end

writelsp(x) = JSON.json(x; omit_null=true)

@testset "LSP" begin
    @test isempty(JSON.parse(writelsp(ClientCapabilities())))

    let init_req_s = """
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
        """
        init_req = readlsp(init_req_s)
        @test init_req isa InitializeRequest
        @test init_req.jsonrpc == "2.0"
        @test init_req.id == 0
        @test init_req.method == "initialize"
        @test init_req.params.processId == 42
        @test init_req.params.clientInfo.name == "Test client"
        @test init_req.params.clientInfo.version == "1.0"
        @test init_req.params.capabilities == ClientCapabilities()
        @test init_req.params.workspaceFolders isa Vector{WorkspaceFolder} && isempty(init_req.params.workspaceFolders)

        init_req_s′ = writelsp(init_req)
        init_req′ = readlsp(init_req_s′)
        @test init_req′ isa InitializeRequest
        @test init_req′.params.workspaceFolders isa Vector{WorkspaceFolder} && isempty(init_req.params.workspaceFolders)
    end

    # ResponseMessage should omit the `error` field on success, and omit `result` an error
    @testset "ResponseMessage result field" begin
        success_res = ResponseMessage(;
            id = "id",
            result = null)
        success_res_s = writelsp(success_res)
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
        error_res_s = writelsp(error_res)
        @test !occursin("\"result\"", error_res_s)
        @test occursin("\"error\"", error_res_s)
    end
end
