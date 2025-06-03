@info "Running JETLS with Julia version" VERSION

using Pkg

let old_env = Pkg.project().path
    try
        Pkg.activate(@__DIR__)

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
        Pkg.activate(old_env)
    end
end

let endpoint = JETLS.Endpoint(stdin, stdout)
    server = JETLS.Server(endpoint) do s::Symbol, x
        @nospecialize x
        if JETLS.JETLS_DEV_MODE
            # allow Revise to apply changes with the dev mode enabled
            if s === :received
                Revise.revise()
            end
        end
    end
    if JETLS.JETLS_DEV_MODE
        JETLS.currently_running = server
    end
    res = runserver(server)
    @info "JETLS server stopped" res.exit_code
    exit(res.exit_code)
end
