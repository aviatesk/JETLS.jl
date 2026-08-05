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
        @test JETLS.is_rejected_text_document(state, uri)
        @test !JETLS.may_have_file_info(state, uri)

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

        delayed_uri = filepath2uri(joinpath(dir, "Project.toml"))
        waiter = Threads.@spawn JETLS.get_file_info(
            state, delayed_uri, JETLS.CancelFlag(false); timeout=5.0)
        @test timedwait(() -> istaskstarted(waiter), 1.0) == :ok
        sleep(0.1)
        @test !istaskdone(waiter)
        delayed_open = DidOpenTextDocumentNotification(;
            params = DidOpenTextDocumentParams(;
                textDocument = TextDocumentItem(;
                    uri = delayed_uri,
                    languageId = "toml",
                    version = 1,
                    text = "[deps]\n")))
        JETLS.handle_DidOpenTextDocumentNotification(server, delayed_open)
        @test timedwait(() -> istaskdone(waiter), 1.0) == :ok
        @test istaskdone(waiter) && fetch(waiter) === nothing

        close_notification = DidCloseTextDocumentNotification(;
            params = DidCloseTextDocumentParams(;
                textDocument = TextDocumentIdentifier(; uri)))
        @test JETLS.handle_DidCloseTextDocumentNotification(server, close_notification) === nothing
        @test !JETLS.is_synchronized(state, uri)
        @test !JETLS.is_rejected_text_document(state, uri)
    end
end

end # module test_document_synchronization
