module UsesPreferences
using Preferences

function set_backend(new_backend::String)
    if !(new_backend in ("OpenCL", "CUDA", "jlFPGA"))
        throw(ArgumentError("Invalid backend: \"$(new_backend)\""))
    end

    # Set it in our runtime values, as well as saving it to disk
    @set_preferences!("backend" => new_backend, "extra" => "tada")
    @info("New backend set; restart your Julia session for this change to take effect!")
end

function clear_backend()
    @set_preferences!("backend" => nothing, "extra" => nothing)
    @info("Backend cleared; restart your Julia session for this change to take effect!")
end

const backend = @load_preference("backend", "OpenCL")

# An example that helps us to prove that things are happening at compile-time
function do_computation()
    @static if backend == "OpenCL"
        return "OpenCL is the best!"
    elseif backend == "CUDA"
        return "CUDA; so fast, so fresh!"
    elseif backend == "jlFPGA"
        return "The Future is Now, jlFPGA online!"
    else
        return nothing
    end
end


# A non-compiletime preference
function set_username(username::String)
    @set_preferences!("username" => username)
end
function get_username()
    return @load_preference("username")
end
function has_username()
    return @has_preference("username")
end
function delete_username()
    @delete_preferences!("username")
end

end # module UsesPreferences
