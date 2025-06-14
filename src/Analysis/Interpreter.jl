module Interpreter

export LSInterpreter

using JET: JET
using ..JETLS: AnalysisEntry, SavedFileInfo, ServerState
using ..JETLS.URIs2
using ..JETLS.Analyzer

struct LSInterpreter <: JET.ConcreteInterpreter
    file_cache::Dict{URI,SavedFileInfo}
    analyzer::LSAnalyzer
    state::JET.InterpretationState
    LSInterpreter(file_cache::Dict{URI,SavedFileInfo}, analyzer::LSAnalyzer) = new(file_cache, analyzer)
    LSInterpreter(file_cache::Dict{URI,SavedFileInfo}, analyzer::LSAnalyzer, state::JET.InterpretationState) = new(file_cache, analyzer, state)
end

# The main constructor
LSInterpreter(state::ServerState, entry::AnalysisEntry) = LSInterpreter(state.saved_file_cache, LSAnalyzer(entry))

# `JET.ConcreteInterpreter` interface
JET.InterpretationState(interp::LSInterpreter) = interp.state
function JET.ConcreteInterpreter(interp::LSInterpreter, state::JET.InterpretationState)
    # add `state` to `interp`, and update `interp.analyzer.cache`
    initialize_cache!(interp.analyzer, state.res.analyzed_files)
    return LSInterpreter(interp.file_cache, interp.analyzer, state)
end
JET.ToplevelAbstractAnalyzer(interp::LSInterpreter) = interp.analyzer

# overloads
# =========

function JET.try_read_file(interp::LSInterpreter, include_context::Module, filepath::AbstractString)
    uri = filepath2uri(filepath)
    if haskey(interp.file_cache, uri)
        return interp.file_cache[uri].text # TODO use `parsed_stream` instead of `text`?
    end
    # fallback to the default file-system-based include
    return read(filepath, String)
end

end # module Interpreter
