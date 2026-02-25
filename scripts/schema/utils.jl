function update_msg(file_path::String, update_command::String)
    return """Error: $file_path is out of date
    Run the following command to update it:
      $update_command"""
end

function check_json_file(file_path::String, expected::AbstractDict, update_command::String)
    if !isfile(file_path)
        println("Error: file not found at $file_path", stderr)
        exit(1)
    end
    existing = JSON.parsefile(file_path)
    if expected != existing
        println(update_msg(file_path, update_command), stderr)
        exit(1)
    end
    return println("$file_path is up to date")
end

function write_json_file(file_path::String, content::AbstractDict, success_msg::String)
    open(file_path, "w") do io
        println(io, JSON.json(content, 2))
    end
    return println(success_msg)
end

function parse_check_flag(args::Vector{String})
    check_mode = "--check" in args
    args_filtered = filter(arg -> arg != "--check", args)
    return (check_mode, args_filtered)
end
