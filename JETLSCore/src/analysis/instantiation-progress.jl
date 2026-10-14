const INSTANTIATION_PROGRESS_INTERVAL = 0.1
const INSTANTIATION_PROGRESS_LINE_LIMIT = 100

mutable struct InstantiationProgressIO <: IO
    const output::IOBuffer
    const pending::IOBuffer
    const lock::ReentrantLock
    latest::String
    reported::String
end

InstantiationProgressIO() =
    InstantiationProgressIO(IOBuffer(), IOBuffer(), ReentrantLock(), "", "")

Base.isopen(io::InstantiationProgressIO) = isopen(io.output)
Base.iswritable(io::InstantiationProgressIO) = iswritable(io.output)
Base.isreadable(::InstantiationProgressIO) = false
Base.lock(io::InstantiationProgressIO) = lock(io.lock)
Base.unlock(io::InstantiationProgressIO) = unlock(io.lock)
Base.flush(::InstantiationProgressIO) = nothing
Base.take!(io::InstantiationProgressIO) = @lock io.lock take!(io.output)

function finish_instantiation_progress_line!(io::InstantiationProgressIO)
    line = String(take!(io.pending))
    # Pkg can emit color/cursor controls (CSI) and hyperlinks (OSC).
    line = replace(line,
        r"\e\][^\a\e]*(?:\a|\e\\)|\e\[[0-?]*[ -/]*[@-~]|\e[@-_]" => "",
        '\t' => ' ')
    line = strip(filter(c -> isvalid(c) && !iscntrl(c), line))
    isempty(line) && return nothing
    limit = INSTANTIATION_PROGRESS_LINE_LIMIT
    io.latest = length(line) > limit ? first(line, limit - 1) * "…" : String(line)
    return nothing
end

function write_instantiation_progress_byte!(io::InstantiationProgressIO, byte::UInt8)
    if byte == UInt8('\r') || byte == UInt8('\n')
        finish_instantiation_progress_line!(io)
    else
        write(io.pending, byte)
    end
    return nothing
end

function Base.write(io::InstantiationProgressIO, byte::UInt8)
    @lock io.lock begin
        write(io.output, byte)
        write_instantiation_progress_byte!(io, byte)
    end
    return 1
end

function Base.unsafe_write(io::InstantiationProgressIO, ptr::Ptr{UInt8}, n::UInt)
    @lock io.lock begin
        Base.unsafe_write(io.output, ptr, n)
        for i in 1:n
            write_instantiation_progress_byte!(io, unsafe_load(ptr, i))
        end
    end
    return Int(n)
end

function instantiation_progress_message!(io::InstantiationProgressIO; finish::Bool=false)
    @lock io.lock begin
        finish && finish_instantiation_progress_line!(io)
        io.latest == io.reported && return nothing
        io.reported = io.latest
        return io.latest
    end
end

function report_instantiation_progress!(
        server::Server, token::ProgressToken, message_path::String,
        io::InstantiationProgressIO; finish::Bool=false
    )
    line = @something instantiation_progress_message!(io; finish) return nothing
    send_progress(server, token,
        WorkDoneProgressReport(; message = message_path * " — " * line, cancellable = false))
    return nothing
end

function with_instantiation_progress(
        f, server::Server, token::ProgressToken, message_path::String
    )
    send_progress(server, token,
        WorkDoneProgressBegin(;
            title = "Instantiating environment",
            message = message_path,
            cancellable = false))
    io = InstantiationProgressIO()
    interval = INSTANTIATION_PROGRESS_INTERVAL
    timer = Timer(interval; interval)
    reporter = Threads.@spawn :default begin
        while true
            try
                wait(timer)
            catch err
                err isa EOFError || rethrow()
                break
            end
            report_instantiation_progress!(server, token, message_path, io)
        end
    end
    try
        return f(io)
    finally
        close(timer)
        try
            # Join before flushing so a queued timer tick cannot report after End.
            wait(reporter)
            report_instantiation_progress!(server, token, message_path, io; finish=true)
        finally
            send_progress(server, token, WorkDoneProgressEnd())
        end
    end
end
