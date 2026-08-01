using PrecompileTools

module __demo__ end

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
    mktemp() do filename, _
        @compile_workload let
            # Warm up the `initialize` round-trip: JSON deserialize -> handler ->
            # JSON serialize. Deserializing the deeply nested `InitializeParams`/
            # `ClientCapabilities` dominates time-to-first-response and is otherwise
            # compiled lazily on the first request, which on slow machines can exceed
            # strict client initialize timeouts (e.g. Helix's 20s default). See #784.
            init_json = """
                {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{"textDocument":{"completion":{"dynamicRegistration":true},"hover":{"dynamicRegistration":true}},"general":{"positionEncodings":["utf-8"]}}}}
                """
            init_msg = LSP.to_lsp_object(init_json)
            # Capture the response via the recorder (populated synchronously by `send`)
            # so we can compile `to_lsp_json` on this task; silence the handler's
            # registration/process-id logs that would otherwise leak into precompile output.
            Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                recorder = ServerMessageRecorder()
                init_server = Server(; callback=recorder)
                handle_InitializeRequest(init_server, init_msg)
                LSP.to_lsp_json(take!(recorder.sent_queue))
                close(init_server.endpoint)
            end

            server = Server()
            uri = filepath2uri(filename)
            entry = ScriptAnalysisEntry(uri)
            request = AnalysisRequest(entry, uri, #=generation=#1, #=token=#nothing, #=notify=#false)
            execution = AnalysisExecution(request, #=prev_result=#nothing)
            interp = LSInterpreter(server, execution)
            JET.analyze_and_report_text!(interp, save_text; virtualize=false, context=__demo__, toplevel_logger=nothing)

            fi = cache_file_info!(server, uri, #=version=#1, live_text)
            (items, _) = get_completion_items(server.state, uri, fi, position, nothing; context_module=__demo__)
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

            precompile(main, (Vector{String},))
        end
    end
end
