using PrecompileTools

# Full analysis in this module refers to it by its path `JETLSCore.__demo__` from within it
module __demo__; const JETLSCore = parentmodule(@__MODULE__); end

@setup_workload let
    save_text = """
        struct Foo
            x::Int
            y::Float64
        end
    """
    live_text, positions = get_text_and_positions("""
        struct Foo
            x::Int
            y::Float64
        end
        function getx(foo::Foo)
            out = foo.│
            return out
        end
    """)
    position = only(positions)
    # opened in the language server and checked by `jetls check` below
    script_text = """
        struct Account
            owner::String
            balance::Float64
        end
        deposit(a::Account, amount::Real) = Account(a.owner, a.balance + amount)
        function total(accounts::Vector{Account})
            s = 0.0
            for a in accounts
                s += a.balance
            end
            return s
        end
        unused_arg(x, y) = x
        total([deposit(Account("a", 1.0), 2)]) + undefined_rate
        """
    # A private workspace, since applying the configuration changes below makes the
    # workspace diagnostics worker scan the whole workspace
    mktempdir() do workspace_dir
        filename = joinpath(workspace_dir, "precompile.jl")
        write(filename, script_text)
        @compile_workload let
            # Warm up the `initialize` round-trip: JSON deserialize -> handler ->
            # JSON serialize. Deserializing the deeply nested `InitializeParams`/
            # `ClientCapabilities` dominates time-to-first-response and is otherwise
            # compiled lazily on the first request, which on slow machines can exceed
            # strict client initialize timeouts (e.g. Helix's 20s default). See #784.
            # Clients supporting dynamic registration get most capabilities registered on
            # `initialized` instead of in the `InitializeResponse`, so warm up both kinds.
            # Also warm up loading `.JETLSConfig.toml` on `initialized`, the
            # `workspace/configuration` response, a `.JETLSConfig.toml` change, and
            # publishing the diagnostics of an opened file.
            workspace_uri = string(filepath2uri(dirname(filename)))
            config_path = joinpath(workspace_dir, CONFIG_FILE)
            config_text(name, severity) = """
                [[full_analysis.concretization_patterns]]
                pattern = "$name = x_"
                path = "*.jl"

                [[diagnostic.patterns]]
                pattern = "lowering/unused-argument"
                match_by = "code"
                match_type = "literal"
                severity = "$severity"
                """
            for dynamic_registration in (false, true)
                dynamic = """{"dynamicRegistration": $dynamic_registration}"""
                init_json = """
                    {
                        "jsonrpc": "2.0",
                        "id": 0,
                        "method": "initialize",
                        "params": {
                            "processId": null,
                            "clientInfo": {"name": "precompile"},
                            "rootUri": null,
                            "workspaceFolders": [
                                {
                                    "uri": "$workspace_uri",
                                    "name": "precompile"
                                }
                            ],
                            "capabilities": {
                                "workspace": {
                                    "configuration": true,
                                    "didChangeConfiguration": $dynamic,
                                    "didChangeWatchedFiles": $dynamic,
                                    "symbol": $dynamic
                                },
                                "textDocument": {
                                    "synchronization": $dynamic,
                                    "completion": $dynamic,
                                    "hover": $dynamic,
                                    "signatureHelp": $dynamic,
                                    "declaration": $dynamic,
                                    "definition": $dynamic,
                                    "typeDefinition": $dynamic,
                                    "references": $dynamic,
                                    "documentHighlight": $dynamic,
                                    "documentSymbol": $dynamic,
                                    "codeAction": $dynamic,
                                    "codeLens": $dynamic,
                                    "documentLink": $dynamic,
                                    "formatting": $dynamic,
                                    "rangeFormatting": $dynamic,
                                    "rename": $dynamic,
                                    "inlayHint": $dynamic,
                                    "diagnostic": $dynamic,
                                    "semanticTokens": {
                                        "dynamicRegistration": $dynamic_registration,
                                        "augmentsSyntaxTokens": true,
                                        "requests": {"full": {"delta": true}},
                                        "tokenTypes": [], "tokenModifiers": [], "formats": []
                                    }
                                },
                                "window": {
                                    "workDoneProgress": true
                                },
                                "notebookDocument": {
                                    "synchronization": $dynamic
                                },
                                "general": {
                                    "positionEncodings": ["utf-8"]
                                }
                            }
                        }
                    }
                    """
                init_msg = LSP.to_lsp_object(init_json)
                # Capture the response via the recorder (populated synchronously by `send`)
                # so we can compile `to_lsp_json` on this task; silence the handler's
                # registration/process-id logs that would otherwise leak into precompile output.
                Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                    recorder = ServerMessageRecorder()
                    init_server = Server(; callback=recorder)
                    try
                        write(config_path, config_text("x", "hint"))
                        handle_InitializeRequest(init_server, init_msg)
                        response = take!(recorder.sent_queue)::InitializeResponse
                        LSP.to_lsp_json(response)
                        handle_InitializedNotification(init_server)
                        LoadLSPConfigHandler(init_server, "precompile", true)(init_server,
                            Dict{String,Any}("full_analysis" => Dict{String,Any}("debounce" => 2.0)))
                        write(config_path, config_text("y", "off"))
                        handle_config_file_change!(init_server, config_path, FileChangeType.Changed)
                        handle_DidOpenTextDocumentNotification(init_server,
                            DidOpenTextDocumentNotification(;
                                params = DidOpenTextDocumentParams(;
                                    textDocument = TextDocumentItem(;
                                        uri = filepath2uri(filename), languageId = "julia",
                                        version = 1, text = script_text))))
                        # what the workspace diagnostics worker does after the file is opened
                        publish_workspace_diagnostics!(init_server, CancelFlag(false))
                        while isready(recorder.sent_queue)
                            LSP.to_lsp_json(take!(recorder.sent_queue))
                        end
                    finally
                        stop_analysis_worker(init_server)
                        stop_signature_analysis_workers(init_server)
                        stop_workspace_diagnostics_worker(init_server)
                        close(init_server.endpoint)
                    end
                end
            end

            server = Server()
            uri = filepath2uri(filename)
            entry = ScriptAnalysisEntry(uri)
            request = AnalysisRequest(entry, uri, #=generation=#1, #=token=#nothing, #=notify=#false)
            execution = AnalysisExecution(request, #=prev_result=#nothing)
            interp = LSInterpreter(server, execution)
            JET.analyze_and_report_text!(interp, save_text; virtualize=false, context=__demo__, toplevel_logger=nothing)

            fi = cache_file_info!(server, uri, #=version=#1, live_text)
            snapshot = get_document_snapshot(server.state, uri)::DocumentSnapshot
            (items, _) = get_completion_items(server.state, uri, snapshot, position, nothing; context_module=__demo__)
            any(item->item.label=="x", items) || @warn "textDocument/completion is broken (field x)"
            any(item->item.label=="y", items) || @warn "textDocument/completion is broken (field y)"

            st0 = build_syntax_tree(fi)[2] # getx
            ctx = TypeAnnotation.build_inferred_context(st0, __demo__)
            range = Range(;
                start = offset_to_xy(fi, JS.first_byte(st0)),
                var"end" = offset_to_xy(fi, JS.last_byte(st0) + 1))
            postprocessor = LSPostProcessor(JET.PostProcessor(__demo__=>Main))
            inlay_hints = InlayHint[]
            collect_type_inlay_hints!(inlay_hints, st0, ctx, fi, uri, range, postprocessor)
            isempty(inlay_hints) && @warn "textDocument/inlayHint is broken"

            # Warm up `jetls check`, every run of which pays for the compilation not cached
            # here, including full analysis, which shares most of its code with the
            # analysis of the language server.
            FULL_ANALYSIS_CONTEXT[] = __demo__
            try
                Base.CoreLogging.with_logger(Base.CoreLogging.ConsoleLogger(devnull)) do
                    redirect_stdio(; stdout=devnull, stderr=devnull) do
                        for progress in ("full", "simple") # for terminals and pipes
                            run_command("check", ["--progress=$progress", filename], JETLS_VERSION[], JETLS_MODULE[])
                        end
                    end
                end
            finally
                FULL_ANALYSIS_CONTEXT[] = Main
            end
        end
    end
end
