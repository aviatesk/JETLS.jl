module test_unsaved_buffer

include("setup.jl")

using Test
using JETLS
using JETLS.LSP
using JETLS.URIs2

# Sequential notifications (`didOpen` / `didChange` / `didClose`) are dispatched
# to a separate worker thread, so observable state changes are *not* synchronous
# with `writemsg` returning. These helpers poll until the relevant manager state
# settles before we assert on it.

function wait_until(predicate::Function;
                    timeout::Float64=10.0,
                    what::AbstractString="condition")
    deadline = time() + timeout
    while time() < deadline
        predicate() && return
        sleep(0.01)
    end
    error("Timed out waiting for $what")
end

wait_for_analysis_cached(manager::JETLS.AnalysisManager, uri::URI) =
    wait_until(() -> JETLS.get_analysis_info(manager, uri) isa JETLS.AnalysisResult;
               what="analysis cache for $uri")

wait_for_analysis_uncached(manager::JETLS.AnalysisManager, uri::URI) =
    wait_until(() -> JETLS.get_analysis_info(manager, uri) === nothing;
               what="analysis cache cleared for $uri")

function any_entry_for(manager::JETLS.AnalysisManager, uri::URI, field::Symbol)
    dict = JETLS.load(getfield(manager, field))
    return any(entry -> JETLS.entryuri(entry) == uri, keys(dict))
end

# Exercise diagnostic clearing on close with reporting limited to open files.
const SETTINGS = Dict{String,Any}(
    "diagnostic" => Dict{String,Any}(
        "all_files" => false,
    ),
)

@testset "didOpen + didClose clears analysis state" begin
    untitled_uri = filename2uri("Untitled-basic")

    withserver(; settings=SETTINGS) do (; server, writereadmsg)
        # JET inference reports (e.g. `inference/method-error`) ride on
        # `PublishDiagnosticsNotification`, so a top-level method-error here
        # exercises the clearing-notification path on close (under
        # `diagnostic.all_files=false`).
        let text = "f32(x::Float32) = sin(x); f32(rand())"
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(untitled_uri, text))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == untitled_uri
            @test any(d -> d.code == JETLS.INFERENCE_METHOD_ERROR_CODE,
                      raw_res.params.diagnostics)
        end

        manager = server.state.analysis_manager
        wait_for_analysis_cached(manager, untitled_uri)
        info = JETLS.get_analysis_info(manager, untitled_uri)::JETLS.AnalysisResult
        entry = info.entry
        @test JETLS.entryuri(entry) == untitled_uri
        @test haskey(JETLS.load(manager.analyzed_generations), entry)

        # Closing the buffer clears its previously published inference diagnostic.
        let (; raw_res) = writereadmsg(make_DidCloseTextDocumentNotification(untitled_uri))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == untitled_uri
            @test isempty(raw_res.params.diagnostics)
        end
        wait_for_analysis_uncached(manager, untitled_uri)

        @test JETLS.get_analysis_info(manager, untitled_uri) === nothing
        @test !haskey(JETLS.load(manager.analyzed_generations), entry)
        @test !haskey(JETLS.load(manager.current_generations), entry)
        @test !any_entry_for(manager, untitled_uri, :debounced)
    end
end

@testset "didChange + immediate didClose cancels debounce timer" begin
    untitled_uri = filename2uri("Untitled-debounced")

    withserver(; settings=SETTINGS) do (; server, writemsg, writereadmsg)
        let text = "f(x) = x + 1"
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(untitled_uri, text))
            @test raw_res isa PublishDiagnosticsNotification
            @test isempty(raw_res.params.diagnostics)
        end

        manager = server.state.analysis_manager
        wait_for_analysis_cached(manager, untitled_uri)
        info = JETLS.get_analysis_info(manager, untitled_uri)::JETLS.AnalysisResult
        entry = info.entry

        # The didChange handler schedules a 3.0s debounced reanalysis. The timer
        # is registered synchronously inside the handler; wait for the sequential
        # worker to land it in `manager.debounced` before asserting.
        writemsg(make_DidChangeTextDocumentNotification(untitled_uri, "f(x) = x + 2", 2))
        wait_until(() -> haskey(JETLS.load(manager.debounced), entry);
                   what="debounce timer to be registered")
        @test haskey(JETLS.load(manager.debounced), entry)

        # didClose must cancel the timer along with the rest of the per-entry
        # state. Without the cancellation the timer would fire 3s later and the
        # original "Unsupported URI" error would surface in the analysis worker.
        # An explicit clearing notification is sent even when cached diagnostics are empty.
        let (; raw_res) = writereadmsg(make_DidCloseTextDocumentNotification(untitled_uri))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == untitled_uri
            @test isempty(raw_res.params.diagnostics)
        end
        wait_for_analysis_uncached(manager, untitled_uri)

        @test JETLS.get_analysis_info(manager, untitled_uri) === nothing
        @test !haskey(JETLS.load(manager.debounced), entry)
    end
end

end # module test_unsaved_buffer
