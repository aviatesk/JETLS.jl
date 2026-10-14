# Entry point for the `jetls` commands that need this package; the `JETLS` app package
# handles the others and all help messages without loading it.
function run_command(command::String, args::Vector{String}, version::String, mdl::Module)
    JETLS_VERSION[] = version
    JETLS_MODULE[] = mdl
    if command == "check"
        return run_check(args)
    elseif command == "serve"
        return run_serve(args)
    elseif command == "test"
        return run_test(args)
    end
    throw(ArgumentError(lazy"Unknown command: $command"))
end

# HACK: Set `LOAD_PATH` to the same state as during normal Julia script execution.
# JETLS internally uses `Pkg.activate` on user package environments and may actually load them,
# so this replacement is necessary.
macro with_cli_LOAD_PATH(ex)
    :(let old_LOAD_PATH = copy(LOAD_PATH)
        try
            empty!(LOAD_PATH)
            push!(LOAD_PATH, "@", "@v$(VERSION.major).$(VERSION.minor)", "@stdlib")
            $(esc(ex))
        finally
            empty!(LOAD_PATH)
            append!(LOAD_PATH, old_LOAD_PATH)
        end
    end)
end
