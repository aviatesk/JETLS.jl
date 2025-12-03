using Profile: Profile

struct ProfileProgressCaller <: RequestCaller
    trigger_path::String
    token::ProgressToken
end
cancellable_token(caller::ProfileProgressCaller) = caller.token

function trigger_profile!(server::Server, trigger_path::String)
    if supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_profile))
        token = String(gensym(:ProfileProgress))
        addrequest!(server, id => ProfileProgressCaller(trigger_path, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_profile(server, trigger_path)
    end
end

function handle_profile_progress_response(
        server::Server, msg::Dict{Symbol,Any}, request_caller::ProfileProgressCaller
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; trigger_path, token) = request_caller
    do_profile_with_progress(server, trigger_path, token)
end

function do_profile_with_progress(server::Server, trigger_path::String, token::ProgressToken)
    send_progress(server, token,
        WorkDoneProgressBegin(; title="Taking heap snapshot"))
    completed = false
    try
        do_profile(server, trigger_path)
        completed = true
    finally
        send_progress(server, token,
            WorkDoneProgressEnd(;
                message = "Heap snapshot " * (completed ? "completed" : "failed")))
    end
end

function do_profile(server::Server, trigger_path::String)
    root_path = server.state.root_path
    timestamp = Libc.strftime("%Y%m%d_%H%M%S", time())
    output_path = joinpath(root_path, "JETLS_$timestamp")

    assembled_path = output_path * ".heapsnapshot"
    try
        Profile.take_heap_snapshot(output_path; streaming=true)
        Profile.HeapSnapshot.assemble_snapshot(output_path, assembled_path)
        show_info_message(server, "Heap snapshot saved to: $assembled_path")
    catch e
        @error "Failed to take heap snapshot" trigger_path
        Base.showerror(stderr, e, catch_backtrace())
        println(stderr)
        show_error_message(server, "Failed to take heap snapshot. See server log for details.")
    finally
        cleanup_streaming_files(output_path)
    end

    request_delete_file(server, filepath2uri(trigger_path))
end

function cleanup_streaming_files(base_path::String)
    for suffix in (".nodes", ".edges", ".strings", ".metadata.json")
        path = base_path * suffix
        isfile(path) && rm(path)
    end
end
