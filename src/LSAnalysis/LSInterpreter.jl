using JET: JET
using ..JETLS: ServerState, FileInfo
using ..JETLS.URIs2

struct LSInterpreter <: JET.ConcreteInterpreter
    file_cache::Dict{URI,FileInfo}
    analyzer::LSAnalyzer
    state::JET.InterpretationState
    LSInterpreter(file_cache::Dict{URI,FileInfo}, analyzer::LSAnalyzer) = new(file_cache, analyzer)
    LSInterpreter(file_cache::Dict{URI,FileInfo}, analyzer::LSAnalyzer, state::JET.InterpretationState) = new(file_cache, analyzer, state)
end

# The main constructor
LSInterpreter(state::ServerState) = LSInterpreter(state.file_cache, LSAnalyzer())

# `JET.ConcreteInterpreter` interface
JET.get_state(interp::LSInterpreter) = interp.state
JET.ConcreteInterpreter(interp::LSInterpreter, state::JET.InterpretationState) = LSInterpreter(interp.file_cache, interp.analyzer, state)
JET.AbstractAnalyzer(interp::LSInterpreter) = interp.analyzer

# overloads
# =========

function JET.try_read_file(interp::LSInterpreter, include_context::Module, filepath::AbstractString)
    uri = filepath2uri(filepath)
    if haskey(interp.file_cache, uri)
        return interp.file_cache[uri].text # TODO use `parsed` instead of `text`?
    end
    # fallback to the default file-system-based include
    return read(filepath, String)
end
