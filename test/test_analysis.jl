module test_analysis

using Test
include("interactive_utils.jl")
using JETLS.JET: get_reports
using JETLS.Analysis: UndefVarErrorReport

# test basic analysis abilities of `JETLSAnalyzer`
function report_undef()
    return sin(undefvar)
end
@testset "JETLSAnalyzer" begin
    let result = analyze_call() do
            sin(undefvar)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(@__MODULE__, :undefvar)
    end
    let result = @analyze_call report_undef()
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(@__MODULE__, :undefvar)
    end
end

end # module test_analysis
