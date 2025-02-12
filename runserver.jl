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

function in_callback(@nospecialize msg)
    revise() # TODO only in debug mode
end
runserver(stdin, stdout; in_callback)
