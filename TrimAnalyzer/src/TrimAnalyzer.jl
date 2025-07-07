module TrimAnalyzer

export report_trim, @report_trim

include("TrimAnalyzerImpl.jl")
using .TrimAnalyzerImpl: TrimAnalyzerImpl

# Entry points
# ============

using InteractiveUtils: InteractiveUtils
using JET: JET

function report_trim(args...; jetconfigs...)
    analyzer = TrimAnalyzerImpl.TrimAnalyzer(; jetconfigs...)
    return JET.analyze_and_report_call!(analyzer, args...; jetconfigs...)
end
macro report_trim(ex0...)
    return InteractiveUtils.gen_call_with_extracted_types_and_kwargs(__module__, :report_trim, ex0)
end

include("app.jl")
using .TrimAnalyzerApp: main

end # module TrimAnalyzer
