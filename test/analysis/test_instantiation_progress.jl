module test_instantiation_progress

using Test
using JETLS: JETLS

include(normpath(pkgdir(JETLS), "test", "setup.jl"))

@testset "InstantiationProgressIO" begin
    @testset "partial lines and finish" begin
        let io = JETLS.InstantiationProgressIO()
            @test io isa IO
            @test JETLS.instantiation_progress_message!(io) === nothing
            @test JETLS.instantiation_progress_message!(io; finish=true) === nothing
            print(io, "Resolving ", 1)
            flush(io)
            @test JETLS.instantiation_progress_message!(io) === nothing
            println(io, " package")
            @test JETLS.instantiation_progress_message!(io) == "Resolving 1 package"
            print(io, "Final output")
            flush(io)
            @test JETLS.instantiation_progress_message!(io) === nothing
            @test JETLS.instantiation_progress_message!(io; finish=true) == "Final output"
            @test JETLS.instantiation_progress_message!(io; finish=true) === nothing
            raw = take!(io)
            @test raw isa Vector{UInt8}
            @test raw == codeunits("Resolving 1 package\nFinal output")
        end
    end

    @testset "coalescing and deduplication" begin
        let io = JETLS.InstantiationProgressIO(), chunks = (
                "old\nnewer\rlatest\r\n\r \t\n\e[0m\n",
                "\e[32mlatest\e[0m\n",
                "intermediate\nlatest\n",
                "next\r",
                "latest\n",
                "latest")
            for (chunk, expected) in zip(chunks,
                    ("latest", nothing, nothing, "next", "latest", nothing))
                @test write(io, chunk) == ncodeunits(chunk)
                @test JETLS.instantiation_progress_message!(io) == expected
                @test JETLS.instantiation_progress_message!(io) === nothing
            end
            @test JETLS.instantiation_progress_message!(io; finish=true) === nothing
            @test take!(io) == codeunits(join(chunks))
        end
    end

    @testset "sanitization" begin
        for (raw, expected) in (
                (" \e[31mResolving\e[0m\tpackages \r\n", "Resolving packages"),
                ("\e[2K\e[1GUpdating \e]8;;https://example.invalid\aPackage\e]8;;\e\\\n",
                    "Updating Package"),
                (" \0\x01ready\b\x7f\u0085\t now \n", "ready  now"),
                (String(UInt8[0x61, 0xff, 0x62, 0xc0, 0x80, 0x63, 0x0a]), "abc"),
                ("\r\n \t\e[0m\0\r\n", nothing))
            io = JETLS.InstantiationProgressIO()
            write(io, raw)
            @test JETLS.instantiation_progress_message!(io) == expected
            @test JETLS.instantiation_progress_message!(io; finish=true) === nothing
            @test take!(io) == codeunits(raw)
        end
        for n in (99, 100, 101)
            io = JETLS.InstantiationProgressIO()
            raw = repeat("🙂", n) * "\n"
            write(io, raw)
            message = JETLS.instantiation_progress_message!(io)
            @test message == (n > 100 ? repeat("🙂", 99) * "…" : repeat("🙂", n))
            @test length(message) == min(n, 100)
            @test take!(io) == codeunits(raw)
        end
    end

    @testset "fragmented UTF-8 and unsafe_write" begin
        let raw = collect(codeunits("λ🙂 ready\n"))
            for split in 1:length(raw)-1
                io = JETLS.InstantiationProgressIO()
                for byte in @view raw[1:split]
                    @test write(io, byte) == 1
                end
                flush(io)
                @test JETLS.instantiation_progress_message!(io) === nothing
                remaining = length(raw) - split
                GC.@preserve raw begin
                    @test Base.unsafe_write(io, pointer(raw, split + 1),
                        UInt(remaining)) == remaining
                end
                @test JETLS.instantiation_progress_message!(io) == "λ🙂 ready"
                @test JETLS.instantiation_progress_message!(io; finish=true) === nothing
                @test take!(io) == raw
            end
        end
    end
end

@testset "with_instantiation_progress" begin
    @testset "$outcome" for outcome in (:return, :throw)
        sent_queue = Channel{Any}(Inf)
        server = JETLS.Server(;
            callback = JETLS.ServerMessageRecorder(Channel{Any}(Inf), sent_queue))
        token = outcome === :return ? "instantiation-stream" : 42
        message_path = "environment/Project.toml"
        expected = outcome === :return ? Ref(:result) : ErrorException("instantiation failed")
        captured_io = Ref{JETLS.InstantiationProgressIO}()
        result = try
            JETLS.with_instantiation_progress(server, token, message_path) do io
                captured_io[] = io
                msg = take_with_timeout!(sent_queue; interval=0.01, limit=500)
                @test msg isa ProgressNotification
                @test msg.params.token == token
                @test msg.params.value isa WorkDoneProgressBegin
                @test msg.params.value.title == "Instantiating environment"
                @test msg.params.value.message == message_path
                @test msg.params.value.cancellable === false

                println(io, "Resolving dependencies")
                # The callback cannot finish until the worker reports this line.
                msg = take_with_timeout!(sent_queue; interval=0.01, limit=500)
                @test msg isa ProgressNotification
                @test msg.params.token == token
                @test msg.params.value isa WorkDoneProgressReport
                @test msg.params.value.message == "$message_path — Resolving dependencies"
                print(io, "Final output")
                outcome === :throw && throw(expected)
                return expected
            end
        catch err
            err
        end
        @test result === expected
        messages = Any[]
        while isready(sent_queue)
            push!(messages, take!(sent_queue))
        end
        @test all(msg -> msg isa ProgressNotification, messages)
        @test all(msg -> msg.params.token == token, messages)
        @test [typeof(msg.params.value) for msg in messages] == [WorkDoneProgressReport, WorkDoneProgressEnd]
        report = only(msg for msg in messages if msg.params.value isa WorkDoneProgressReport)
        @test report.params.value.message == "$message_path — Final output"
        @test take!(captured_io[]) == codeunits("Resolving dependencies\nFinal output")

        println(captured_io[], "After End")
        @test timedwait(() -> isready(sent_queue), 0.3; pollint=0.01) == :timed_out
    end
end

end # module test_instantiation_progress
