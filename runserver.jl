@info "Running JETLS with Julia version" VERSION

using Pkg

let old_env = Pkg.project().path
    try
        Pkg.activate(@__DIR__; io=devnull)

        # TODO load Revise only when `JETLS_DEV_MODE` is true
        try
            # load Revise with JuliaInterpreter used by JETLS
            using Revise
        catch err
            @warn "Revise not found"
        end

        @info "Loading JETLS..."

        try
            using JETLS
        catch
            @error "JETLS not found"
            exit(1)
        end
    finally
        Pkg.activate(old_env; io=devnull)
    end
end

let endpoint = Endpoint(stdin, stdout)
    if JETLS.JETLS_DEV_MODE
        server = Server(endpoint) do s::Symbol, x
            @nospecialize x
            # allow Revise to apply changes with the dev mode enabled
            if s === :received
                if !(x isa JETLS.ShutdownRequest || x isa JETLS.ExitNotification)
                    Revise.revise()
                end
            end
        end
        JETLS.currently_running = server
        res = runserver(server)
    else
        res = runserver(endpoint)
    end
    @info "JETLS server stopped" res.exit_code
    exit(res.exit_code)
end
