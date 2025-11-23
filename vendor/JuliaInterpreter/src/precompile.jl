module var"#Internal"
public_fn(x::String) = false
end

function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    @interpret sum(rand(10))
    expr = quote
        public_fn(x::Integer) = true
        module Private
            private(y::String) = false
        end
        const threshold = 0.1
    end
    for (mod, ex) in ExprSplitter(var"#Internal", expr)
        frame = Frame(mod, ex)
        debug_command(frame, :c, true)
    end
end
