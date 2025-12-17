using JETLS: JET, JETLS
using JETLS.Analyzer
using InteractiveUtils: InteractiveUtils

# interactive entry points for LSAnalyzer

function analyze_call(
        args...;
        report_target_modules = nothing,
        jetconfigs...
    )
    analyzer = JETLS.LSAnalyzer(; report_target_modules, jetconfigs...)
    return JET.analyze_and_report_call!(analyzer, args...; jetconfigs...)
end
macro analyze_call(ex0...)
    return InteractiveUtils.gen_call_with_extracted_types_and_kwargs(__module__, :analyze_call, ex0)
end
