module test_Analyzer

using Test
include("interactive-utils.jl")
using JETLS.JET: get_reports
using JETLS.Analyzer: UndefVarErrorReport

# test basic analysis abilities of `LSAnalyzer`
function report_global_undef()
    return sin(undefvar)
end
@noinline callfunc(f) = f()

@testset "LSAnalyzer" begin
    # global undef variables
    let result = analyze_call() do
            sin(undefvar)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(@__MODULE__, :undefvar)
    end
    let result = @analyze_call report_global_undef()
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(@__MODULE__, :undefvar)
    end

    # local undef variables
    let result = analyze_call() do
            local x
            sin(x)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var === :x && !r.maybeundef
    end
    let result = analyze_call((Bool,Float64)) do c, x
            if c
                y = x
            end
            return sin(y)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var === :y && r.maybeundef
    end
    let result = analyze_call((Any,)) do x
            local y = x
            callfunc() do
                identity(y)
            end
        end
        @test isempty(get_reports(result))
    end
end

end # module test_LSAnalyzer
