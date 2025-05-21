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

let res = runserver(stdin, stdout) do state::Symbol, msg
        @nospecialize msg
        if JETLS.JETLS_DEV_MODE
            # allow Revise to apply changes with the dev mode enabled
            if state === :received
                Revise.revise()
            end
        end
    end
    @info "JETLS server stopped" res.exit_code
    exit(res.exit_code)
end
