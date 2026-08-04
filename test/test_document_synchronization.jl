module test_document_synchronization

using Test
using JETLS
using JETLS.LSP
using JETLS.LSP.URIs2: filepath2uri

@testset "unsupported text documents are ignored" begin
    mktempdir() do dir
        server = JETLS.Server()
        state = server.state
        uri = filepath2uri(joinpath(dir, "Manifest.toml"))

        open_notification = DidOpenTextDocumentNotification(;
            params = DidOpenTextDocumentParams(;
                textDocument = TextDocumentItem(;
                    uri, languageId="toml", version=1, text="[deps]\n")))
        @test JETLS.handle_DidOpenTextDocumentNotification(server, open_notification) === nothing
        @test !JETLS.is_synchronized(state, uri)
        @test !haskey(JETLS.load(state.saved_file_cache), uri)

        change_notification = DidChangeTextDocumentNotification(;
            params = DidChangeTextDocumentParams(;
                textDocument = VersionedTextDocumentIdentifier(; uri, version=2),
                contentChanges = TextDocumentContentChangeEvent[
                    TextDocumentContentChangeEvent(; text="[compat]\n")]))
        @test JETLS.handle_DidChangeTextDocumentNotification(server, change_notification) === nothing
        @test !JETLS.is_synchronized(state, uri)

        save_notification = DidSaveTextDocumentNotification(;
            params = DidSaveTextDocumentParams(;
                textDocument = TextDocumentIdentifier(; uri), text="[compat]\n"))
        @test JETLS.handle_DidSaveTextDocumentNotification(server, save_notification) === nothing
        @test !haskey(JETLS.load(state.saved_file_cache), uri)

        close_notification = DidCloseTextDocumentNotification(;
            params = DidCloseTextDocumentParams(;
                textDocument = TextDocumentIdentifier(; uri)))
        @test JETLS.handle_DidCloseTextDocumentNotification(server, close_notification) === nothing
        @test !JETLS.is_synchronized(state, uri)
    end
end

end # module test_document_synchronization
