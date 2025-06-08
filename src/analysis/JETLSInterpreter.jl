using JET

struct JETLSInterpreter <: JET.ConcreteInterpreter
    analyzer::JETLSAnalyzer
    state::JET.InterpretationState
    JETLSInterpreter(analyzer::JETLSAnalyzer) = new(analyzer)
    JETLSInterpreter(analyzer::JETLSAnalyzer, state::JET.InterpretationState) = new(analyzer, state)
end
JETLSInterpreter() = JETLSInterpreter(JETLSAnalyzer())

# The required interface for `JET.ConcreteInterpreter`
JET.get_state(interp::JETLSInterpreter) = interp.state
JET.ConcreteInterpreter(interp::JETLSInterpreter, state::JET.InterpretationState) = JETLSInterpreter(interp.analyzer, state)
JET.AbstractAnalyzer(interp::JETLSInterpreter) = interp.analyzer
