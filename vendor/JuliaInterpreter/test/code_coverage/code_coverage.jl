function cleanup_coverage_files(pid)
    # clean up coverage files for source code
    dir, _, files = first(walkdir(normpath(@__DIR__, "..", "..", "src")))
    for file in files
        reg = Regex(string(".+\\.jl\\.$pid\\.cov"))
        if occursin(reg, file)
            rm(joinpath(dir, file))
        end
    end

    # clean up coverage files for this file
    dir, _, files = first(walkdir(@__DIR__))
    for file in files
        reg = Regex(string("coverage_example\\.jl\\.$pid\\.cov"))
        if occursin(reg, file)
            rm(joinpath(dir, file))
        end
    end
end

# using DiffUtils

let
    local pid
    try
        @testset "code coverage" begin
            io = Base.PipeEndpoint()
            filepath = normpath(@__DIR__, "coverage_example.jl")
            cmd = `$(Base.julia_cmd()) --startup=no --project=$(dirname(dirname(@__DIR__)))
                --code-coverage=user $filepath`
            p = run(cmd, devnull, io, stderr; wait=false)
            pid = Libc.getpid(p)
            @test read(io, String) == "1 2 fizz 4 "
            @test success(p)

            dir, _, files = first(walkdir(@__DIR__))
            i = findfirst(contains(r"coverage_example\.jl\.\d+\.cov"), files)
            i === nothing && error("no coverage files found in $dir: $files")
            cov_file = joinpath(dir, files[i])
            cov_data = read(cov_file, String)
            expected = "coverage_example.jl.cov"
            expected = read(joinpath(dir, expected), String)
            if Sys.iswindows()
                cov_data = replace(cov_data, "\r\n" => "\n")
                expected = replace(cov_data, "\r\n" => "\n")
            end

            # if cov_data != expected
            #     DiffUtils.diff(cov_data, expected)
            # end
            @test cov_data == expected
        end
    finally
        if @isdefined(pid)
            # clean up generated files
            cleanup_coverage_files(pid)
        end
    end
end
