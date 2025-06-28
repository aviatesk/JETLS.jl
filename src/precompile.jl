using PrecompileTools

module __demo__ end

@setup_workload let
    server = Server()
    text, positions = get_text_and_positions("""
        struct Bar
            x::Int
        end
        function getx(bar::Bar)
            out = bar.x
            #=cursor=#
            return out
        end
    """)
    position = only(positions)
    mktemp() do filename, _
        uri = filepath2uri(filename)
        @compile_workload let
            state = server.state
            cache_file_info!(state, uri, #=version=#1, text)
            let comp_params = CompletionParams(;
                    textDocument = TextDocumentIdentifier(; uri),
                    position)
                items = get_completion_items(state, uri, comp_params)
                any(item->item.label=="out", items) || @warn "completion seems to be broken"
                any(item->item.label=="bar", items) || @warn "completion seems to be broken"
            end

            # compile `LSInterpreter`
            entry = ScriptAnalysisEntry(uri)
            # specify `token::String`?
            info = FullAnalysisInfo(entry, nothing, #=reanalyze=#false, #=n_files=#0)
            interp = LSInterpreter(server, info)
            filepath = normpath(pkgdir(JET), "demo.jl")
            JET.analyze_and_report_file!(interp, filepath;
                virtualize=false,
                context=__demo__,
                toplevel_logger=nothing)
        end
    end
end
