using JETLSCore: JETLSCore, JS
using JETLSCore.LSP
using JETLSCore.LSP.URIs2

const LOWERING_DIAGNOSTICS_URI =
    filepath2uri(joinpath(@__DIR__, "testfile_lowering_diagnostics.jl"))

# Compute the lowering diagnostics of `text` as a single-file analysis unit at
# `LOWERING_DIAGNOSTICS_URI`, running the per-statement and cross-file phases that
# `toplevel_lowering_diagnostics!` runs. `context_module` defaults to the
# `lowering_module` of the including test module, and `kwargs` are passed to
# `per_stmt_diagnostics!`.
function get_lowering_diagnostics(
        text::AbstractString;
        code::Union{AbstractString,Nothing} = nothing,
        context_module::Module = lowering_module,
        world::UInt = Base.get_world_counter(),
        kwargs...
    )
    uri = LOWERING_DIAGNOSTICS_URI
    server = JETLSCore.Server()
    fi = JETLSCore.cache_file_info!(server, uri, 1, text)
    # Tie the file to `context_module` so that the cross-file phase, which resolves the
    # context of this file through `analysis_manager`, collects definitions and imports
    # under the same module as the per-statement phase.
    JETLSCore.cache_out_of_scope!(
        server.state.analysis_manager, uri, JETLSCore.OutOfScope(context_module))
    st0_top = JETLSCore.build_syntax_tree(fi)
    @assert JS.head(st0_top) === :toplevel
    diagnostics = LSP.Diagnostic[]
    candidates = JETLSCore.UndefGlobalCandidate[]
    def_used_names = Dict{Module,JETLSCore.DefUsedNames}()
    JETLSCore.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        JETLSCore.per_stmt_diagnostics!(diagnostics, candidates, uri, fi,
            st0, context_module, world, #=analyzer=#nothing, JETLSCore.LSPostProcessor();
            kwargs...)
        binding_occurrences = JETLSCore.get_binding_occurrences!(server.state, uri, fi, st0)
        binding_occurrences !== nothing &&
            JETLSCore.update_def_used_names!(def_used_names, context_module, binding_occurrences)
    end
    explicit_imports = JETLSCore.collect_explicit_imports_by_module(server.state, uri, fi, st0_top)
    # Mirror the cross-file phase. `skip_context_check=true` because the test server
    # has no analysis result — we want this single file to count as part of its own
    # unit anyway.
    per_file = JETLSCore.PerFileDiagnosticsResult(
        diagnostics, candidates, def_used_names, explicit_imports)
    JETLSCore.cross_file_diagnostics!(diagnostics, JETLSCore.DefUsedNamesCache(),
        server, uri, #=snapshot=#nothing, per_file; skip_context_check=true)
    if code !== nothing
        filter!(d -> d.code == code, diagnostics)
    end
    return diagnostics
end
