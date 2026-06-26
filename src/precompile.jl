using PrecompileTools

module __demo__ end

@setup_workload let
    server = Server()
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
        uri = filepath2uri(filename)
        @compile_workload let
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
