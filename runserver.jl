try
    using Revise
catch err
    @info "Revise not found"
end

@info "Loading JETLS..."

try
    using JETLS
catch
    @info "JETLS not found"
    exit(1)
end

runserver(stdin, stdout) do msg, res
    # TODO only in debug mode
    revise()
end
