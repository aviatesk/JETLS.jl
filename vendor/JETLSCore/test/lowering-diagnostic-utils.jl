using JETLSCore: JETLSCore
using JETLSCore.LSP
using JETLSCore.LSP.URIs2

const LOWERING_DIAGNOSTICS_URI =
    filepath2uri(joinpath(@__DIR__, "testfile_lowering_diagnostics.jl"))

# Compute the lowering diagnostics of `text` through `toplevel_lowering_diagnostics!`, as
# a single-file analysis unit at `LOWERING_DIAGNOSTICS_URI` whose context module is
# `context_module` (the `lowering_module` of the including test module by default).
# `context_module = nothing` gives the file no analysis information, as before full
# analysis completes.
function get_lowering_diagnostics(
        text::AbstractString;
        code::Union{AbstractString,Nothing} = nothing,
        context_module::Union{Module,Nothing} = lowering_module,
        allow_unused_underscore::Union{Bool,Nothing} = nothing,
    )
    uri = LOWERING_DIAGNOSTICS_URI
    server = JETLSCore.Server()
    fi = JETLSCore.cache_file_info!(server, uri, 1, text)
    if context_module !== nothing
        JETLSCore.cache_out_of_scope!(
            server.state.analysis_manager, uri, JETLSCore.OutOfScope(context_module))
    end
    if allow_unused_underscore !== nothing
        config = JETLSCore.JETLSConfig(;
            diagnostic = JETLSCore.DiagnosticConfig(; allow_unused_underscore))
        JETLSCore.store!(server.state.config_manager) do data::JETLSCore.ConfigManagerData
            return JETLSCore.ConfigManagerData(data; lsp_config = config), nothing
        end
    end
    diagnostics = JETLSCore.toplevel_lowering_diagnostics!(
        JETLSCore.DefUsedNamesCache(), server, uri, fi, #=snapshot=#nothing,
        JETLSCore.DUMMY_CANCEL_FLAG)
    if code !== nothing
        filter!(d -> d.code == code, diagnostics)
    end
    return diagnostics
end
