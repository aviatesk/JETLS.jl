using JETLS: JET, JETLS
using InteractiveUtils: InteractiveUtils

# interactive entry points for LSAnalyzer

function analyze_call(args...; jetconfigs...)
    analyzer = JETLS.LSAnalyzer(; jetconfigs...)
    return JET.analyze_and_report_call!(analyzer, args...; jetconfigs...)
end
macro analyze_call(ex0...)
    return InteractiveUtils.gen_call_with_extracted_types_and_kwargs(__module__, :analyze_call, ex0)
end
