# Read from the partitions, since `getglobal` of a deprecated binding warns, or throws with
# `--depwarn=error`
function global_const_value(b::Core.Binding, world::UInt)
    while true
        bpart = Base.lookup_binding_partition(world, b)
        kind = Base.binding_kind(bpart)
        if Base.is_defined_const_binding(kind)
            return Base.partition_restriction(bpart)
        elseif Base.is_some_binding_imported(kind)
            b = Base.partition_restriction(bpart)::Core.Binding
        else
            return nothing
        end
    end
end

# The functions with more methods are not checked, since enumerating all methods of e.g. `+`
# is far more expensive than finding out that there are more of them
const DEPRECATED_FUNCTION_MAX_METHODS = 8

# The message of the deprecation of `f` in `world` when all of its methods are defined by
# `@deprecate`, or `nothing`
function deprecated_function_message(f::Function, world::UInt)
    matches = @something Base._methods_by_ftype(
        Tuple{typeof(f),Vararg{Any}}, DEPRECATED_FUNCTION_MAX_METHODS, world) return nothing
    isempty(matches) && return nothing
    messages = String[]
    for match in matches
        m = (match::Core.MethodMatch).method
        message = @something deprecated_method_message(m, world) return nothing
        message in messages || push!(messages, message)
    end
    length(messages) == 1 && return only(messages)
    summary = "All methods of `$(parentmodule(f)).$(nameof(f))` are deprecated:"
    return join((summary, messages...), '\n')::String
end

# The message of the deprecation warning that `m` prints first thing, as the methods defined
# by `@deprecate` do, or `nothing`. The roots of `m` are checked first, so that the code of
# other `@noinline` methods is not decompressed.
function deprecated_method_message(m::Method, world::UInt)
    # `@deprecate` marks its methods `@noinline`, which is checked without decompression
    CC.is_declared_noinline(m) || return nothing
    has_depwarn_root(m) && return depwarn_message(Base.uncompressed_ast(m))
    message = kwbody_depwarn_message(m, world)
    message === nothing || return message
    return default_args_depwarn_message(m, world)
end

# The methods that `@deprecate` defines for default arguments call the method that prints
# the warning, which is defined at the same location
function default_args_depwarn_message(m::Method, world::UInt)
    sig = Base.unwrap_unionall(m.sig)
    sig isa DataType || return nothing
    params = sig.parameters
    # the method that takes the default arguments as well
    tt = Base.isvarargtype(params[end]) ? sig : Tuple{params...,Vararg{Any}}
    matches = @something Base._methods_by_ftype(
        Base.rewrap_unionall(tt, m.sig), DEPRECATED_FUNCTION_MAX_METHODS, world) return nothing
    for match in matches
        other = (match::Core.MethodMatch).method
        other !== m && other.file === m.file && other.line == m.line || continue
        CC.is_declared_noinline(other) || continue
        message = if has_depwarn_root(other)
            depwarn_message(Base.uncompressed_ast(other))
        else
            kwbody_depwarn_message(other, world)
        end
        message === nothing || return message
    end
    return nothing
end

# The roots of a method hold the literals of its compressed code, such as the name `depwarn`
# of `Base.depwarn` and the message passed to it
has_depwarn_root(m::Method) =
    isdefined(m, :roots) && any(@nospecialize(root) -> root === :depwarn, m.roots)

# A method that `@deprecate` defines with keyword arguments, as it does without a signature,
# prints the warning in its body function `#name#N`, whose name is in the roots of the method,
# and so does the method of `Core.kwcall` that passes keyword arguments to it
function kwbody_depwarn_message(m::Method, world::UInt)
    isdefined(m, :roots) || return nothing
    name = m.name === :kwcall ? @something(kwcall_function_name(m), return nothing) : m.name
    prefix = string('#', name, '#')
    for root in m.roots
        root isa Symbol && startswith(String(root), prefix) || continue
        Base.invoke_in_world(world, isdefinedglobal, m.module, root)::Bool || continue
        bodyf = global_const_value(convert(Core.Binding, GlobalRef(m.module, root)), world)
        bodyf isa Function || continue
        matches = @something Base._methods_by_ftype(
            Tuple{typeof(bodyf),Vararg{Any}}, 1, world) return nothing
        length(matches) == 1 || return nothing
        body = (only(matches)::Core.MethodMatch).method
        CC.is_declared_noinline(body) && has_depwarn_root(body) || return nothing
        return depwarn_message(Base.uncompressed_ast(body))
    end
    return nothing
end

# The name of the function that a method of `Core.kwcall` passes keyword arguments to
function kwcall_function_name(m::Method)
    sig = Base.unwrap_unionall(m.sig)
    sig isa DataType && length(sig.parameters) ≥ 3 || return nothing
    ft = sig.parameters[3]
    ft isa DataType && isdefined(ft, :instance) || return nothing
    return ft.name.singletonname
end

# The message of the deprecation warning that `src` prints first thing, as the methods
# defined by `@deprecate` do, or `nothing`
function depwarn_message(src::Core.CodeInfo)
    for stmt in src.code
        if stmt isa Core.GotoNode || stmt isa Core.GotoIfNot || stmt isa Core.ReturnNode ||
           stmt isa Core.EnterNode
            return nothing
        elseif Meta.isexpr(stmt, :call) && length(stmt.args) ≥ 2
            callee = stmt.args[1]
            callee isa Core.SSAValue && (callee = src.code[callee.id])
            callee isa GlobalRef && callee.mod === Base && callee.name === :depwarn || continue
            message = stmt.args[2]
            return message isa String ? message : nothing
        end
    end
    return nothing
end
