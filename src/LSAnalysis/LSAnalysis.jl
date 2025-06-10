module LSAnalysis

export LSAnalyzer, LSInterpreter, inference_error_report_stack, resolve_node

include("LSAnalyzer.jl")
include("LSInterpreter.jl")
include("resolver.jl")

end # LSAnalysis
