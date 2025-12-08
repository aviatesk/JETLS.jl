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
            │
            return out
        end
    """)
    position = only(positions)
    mktemp() do filename, _
        uri = filepath2uri(filename)
        @compile_workload let
            fi = cache_file_info!(server, uri, #=version=#1, text)
            let items = get_completion_items(server.state, uri, fi, position, nothing)
                any(item->item.label=="out", items) || @warn "completion seems to be broken"
                any(item->item.label=="bar", items) || @warn "completion seems to be broken"
            end

            # compile `LSInterpreter`
            entry = ScriptAnalysisEntry(uri)
            # specify `token::String`?
            request = AnalysisRequest(entry, uri, #=generation=#1, #=token=#nothing, #=notify=#false, #=prev_analysis_result=#nothing)
            interp = LSInterpreter(server, request)
            filepath = normpath(pkgdir(JET), "demo.jl")
            JET.analyze_and_report_file!(interp, filepath;
                virtualize=false,
                context=__demo__,
                toplevel_logger=nothing)

            precompile(main, (Vector{String},))
        end
    end
end
