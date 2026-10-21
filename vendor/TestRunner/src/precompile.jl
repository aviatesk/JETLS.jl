module Precompile

using ..TestRunner: TestRunner, runtest
using ..App: app_runner_module, main

using PrecompileTools

module PrecompileModule1 end
module PrecompileModule2 end
module PrecompileModule3 end
module PrecompileModule4 end
module PrecompileModule5 end
module PrecompileModule6 end
module PrecompileModule7 end
module PrecompileModule8 end
module PrecompileModule9 end
module PrecompileModule10 end

@setup_workload let
    demo_file = pkgdir(TestRunner, "demo.jl")
    include_dependency(demo_file)
    @compile_workload redirect_stdout(devnull) do
        runtest(demo_file, ["basic tests"]; topmodule=PrecompileModule1);
        runtest(demo_file, [:(@test process(s_) == n_)]; topmodule=PrecompileModule2);
        runtest(demo_file, [r".*tests"]; topmodule=PrecompileModule3);
        runtest(demo_file, ["inner tests 1"]; topmodule=PrecompileModule4);
        runtest(demo_file, [:(@test startswith(s_, prefix_))]; topmodule=PrecompileModule5);

        main(String["--help"])
        app_runner_module[] = PrecompileModule6
        main(String[demo_file, "basic tests"]); # Run "basic tests" including @test_broken
        app_runner_module[] = PrecompileModule7
        main(String[demo_file, "--verbose", ":(@test process(s_) == n_)"]); # Run tests that call the process function
        app_runner_module[] = PrecompileModule8
        main(String[demo_file, "r\".*tests\""]);
        app_runner_module[] = PrecompileModule9
        mktempdir() do dir
            main(String[demo_file, "--json-file=$(joinpath(dir, "result.json"))", "inner tests 1"]);
        end
        app_runner_module[] = PrecompileModule10
        main(String[demo_file, ":(@test startswith(s_, prefix_))", "--filter-lines=43"]);
    end
    app_runner_module[] = nothing
end

end # module Precompile
