using JETLS.LSAnalysis: LSAnalyzer
using JETLS.JET: analyze_and_report_call!
using InteractiveUtils: gen_call_with_extracted_types_and_kwargs

# interactive entry points for LSAnalyzer

function analyze_call(args...; jetconfigs...)
    analyzer = LSAnalyzer(; jetconfigs...)
    return analyze_and_report_call!(analyzer, args...; jetconfigs...)
end
macro analyze_call(ex0...)
    return gen_call_with_extracted_types_and_kwargs(__module__, :analyze_call, ex0)
end
