# JuliaInterpreter

This package implements an [interpreter](https://en.wikipedia.org/wiki/Interpreter_(computing)) for Julia code.
Normally, Julia compiles your code when you first execute it; using JuliaInterpreter you can
avoid compilation and execute the expressions that define your code directly.
Interpreters have a number of applications, including support for stepping debuggers.

## Use as an interpreter

Using this package as an interpreter is straightforward:

```@repl index
using JuliaInterpreter

list = [1, 2, 5]

sum(list)

@interpret sum(list)
```

## Breakpoints

You can interrupt execution by setting breakpoints.
You can set breakpoints via packages that explicitly target debugging,
like [Juno](https://junolab.org/), [Debugger](https://github.com/JuliaDebug/Debugger.jl), and
[Rebugger](https://github.com/timholy/Rebugger.jl).
But all of these just leverage the core functionality defined in JuliaInterpreter,
so here we'll illustrate it without using any of these other packages.

Let's set a conditional breakpoint, to be triggered any time one of the elements in the
argument to `sum` is bigger than 4:

```@repl index
bp = @breakpoint sum([1, 2]) any(x->x>4, a);
```

Note that in writing the condition, we used `a`, the name of the argument to the relevant
method of `sum`. Conditionals should be written using a combination of argument and parameter
names of the method into which you're inserting a breakpoint; you can also use any
globally-available name (as used here with the `any` function).

Now let's see what happens:

```@repl index
@interpret sum([1,2,3])  # no element bigger than 4, breakpoint should not trigger

frame, bpref = @interpret sum([1,2,5])  # should trigger breakpoint
```

`frame` is described in more detail on the next page; for now, suffice it to say
that the `c` in the leftmost column indicates the presence of a conditional breakpoint
upon entry to `sum`. `bpref` is a reference to the breakpoint of type [`BreakpointRef`](@ref).
The breakpoint `bp` we created can be manipulated at the command line

```@repl index
disable(bp)

@interpret sum([1,2,5])

enable(bp)

@interpret sum([1,2,5])
```

[`disable`](@ref) and [`enable`](@ref) allow you to turn breakpoints off and on without losing any
conditional statements you may have provided; [`remove`](@ref) allows a permanent removal of
the breakpoint. You can use `remove()` to remove all breakpoints in all methods.

[`@breakpoint`](@ref) allows you to optionally specify a line number at which the breakpoint
is to be set. You can also use a functional form, [`breakpoint`](@ref), to specify file/line
combinations or that you want to break on entry to *any* method of a particular function.
At present, note that some of this functionality requires that you be running
[Revise.jl](https://github.com/timholy/Revise.jl).

It is, in addition, possible to halt execution when otherwise an error would be thrown.
This functionality is enabled using [`break_on`](@ref) and disabled with [`break_off`](@ref):

```@repl index
function f_outer()
    println("before error")
    f_inner()
    println("after error")
end;

f_inner() = error("inner error");

break_on(:error)

fr, pc = @interpret f_outer()

leaf(fr)

typeof(pc)

pc.err

break_off(:error)

@interpret f_outer()
```

Finally, you can set breakpoints using [`@bp`](@ref):

```@repl index
function myfunction(x, y)
    a = 1
    b = 2
    x > 3 && @bp
    return a + b + x + y
end;

@interpret myfunction(1, 2)

@interpret myfunction(5, 6)
```

Here the breakpoint is marked with a `b` indicating that it is an unconditional breakpoint.
Because we placed it inside the condition `x > 3`, we've achieved a conditional outcome.

When using `@bp` in source-code files, the use of Revise is recommended,
since it allows you to add breakpoints, test code, and then remove the breakpoints from the
code without restarting Julia.

## `debug_command`

You can control execution of frames via [`debug_command`](@ref).
Authors of debugging applications should target `debug_command` for their interaction
with JuliaInterpreter.

## Hooks
Consider if you were building a debugging application with a GUI component which displays a dot in the text editor margin where a breakpoint is.
If a user creates a breakpoint not via your GUI, but rather via a command in the REPL etc.
then you still wish to keep your GUI up to date.
How to do this? The answer is hooks.


JuliaInterpreter has experimental support for having  a hook, or callback function invoked
whenever the set of all breakpoints is changed.
Hook functions are setup by invoking the [`JuliaInterpreter.on_breakpoints_updated`](@ref) function.

To return to our example of keeping GUI up to date, the hooks would look something like this:
```julia
using JuliaInterpreter
using JuliaInterpreter: AbstractBreakpoint, update_states!, on_breakpoints_updated

breakpoint_gui_elements = Dict{AbstractBreakpoint, MarginDot}()
# ...
function breakpoint_gui_hook(::typeof(breakpoint), bp::AbstractBreakpoint)
    bp_dot = MarginDot(bp)
    draw(bp_dot)
    breakpoint_gui_elements[bp] = bp_dot
end

function breakpoint_gui_hook(::typeof(remove), bp::AbstractBreakpoint)
    bp_dot = pop!(breakpoint_gui_elements, bp)
    undraw(bp_dot)
end

function breakpoint_gui_hook(::typeof(update_states!), bp::AbstractBreakpoint)
    is_enabled = bp.enabled[]
    bp_dot = breakpoint_gui_elements[bp]
    set_fill!(bp_dot, is_enabled ? :blue : :grey)
end

on_breakpoints_updated(breakpoint_gui_hook)
```
