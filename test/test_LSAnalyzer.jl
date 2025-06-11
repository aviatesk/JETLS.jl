module test_LSAnalyzer

using Test
include("interactive_utils.jl")
using JETLS.JET: get_reports
using JETLS.Analyzer: UndefVarErrorReport

# test basic analysis abilities of `LSAnalyzer`
function report_undef()
    return sin(undefvar)
end
@testset "LSAnalyzer" begin
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

end # module test_LSAnalyzer
