@info "Running JETLS with Julia version" VERSION

using Pkg

let old_env = Pkg.project().path
    try
        Pkg.activate(@__DIR__)

        # load Revise with JuliaInterpreter used by JETLS
        try
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

function in_callback(@nospecialize msg)
    revise() # TODO only in debug mode
end
runserver(stdin, stdout; in_callback)
