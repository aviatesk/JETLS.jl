using JET: JET
using ..JETLS: ServerState, FileInfo
using ..JETLS.URIs2

struct JETLSInterpreter <: JET.ConcreteInterpreter
    file_cache::Dict{URI,FileInfo}
    analyzer::JETLSAnalyzer
    state::JET.InterpretationState
    JETLSInterpreter(file_cache::Dict{URI,FileInfo}, analyzer::JETLSAnalyzer) = new(file_cache, analyzer)
    JETLSInterpreter(file_cache::Dict{URI,FileInfo}, analyzer::JETLSAnalyzer, state::JET.InterpretationState) = new(file_cache, analyzer, state)
end

# The main constructor
JETLSInterpreter(state::ServerState) = JETLSInterpreter(state.file_cache, JETLSAnalyzer())

# `JET.ConcreteInterpreter` interface
JET.get_state(interp::JETLSInterpreter) = interp.state
JET.ConcreteInterpreter(interp::JETLSInterpreter, state::JET.InterpretationState) = JETLSInterpreter(interp.file_cache, interp.analyzer, state)
JET.AbstractAnalyzer(interp::JETLSInterpreter) = interp.analyzer

# overloads
# =========

function JET.try_read_file(interp::JETLSInterpreter, include_context::Module, filepath::AbstractString)
    uri = filepath2uri(filepath)
    if haskey(interp.file_cache, uri)
        return interp.file_cache[uri].text # TODO use `parsed` instead of `text`?
    end
    # fallback to the default file-system-based include
    return read(filepath, String)
end
