# Function reference

## Running the interpreter

```@docs
@interpret
```

## Interpreter

```@docs
JuliaInterpreter.Interpreter
JuliaInterpreter.RecursiveInterpreter
JuliaInterpreter.NonRecursiveInterpreter
JuliaInterpreter.Compiled
JuliaInterpreter.method_table
```

## Frame creation

```@docs
Frame(mod::Module, ex::Expr)
ExprSplitter
JuliaInterpreter.enter_call
JuliaInterpreter.enter_call_expr
JuliaInterpreter.prepare_frame
JuliaInterpreter.determine_method_for_expr
JuliaInterpreter.prepare_args
JuliaInterpreter.prepare_call
JuliaInterpreter.get_call_framecode
JuliaInterpreter.optimize!
```

## Frame traversal

```@docs
root
leaf
```

## Frame execution

```@docs
JuliaInterpreter.step_expr!
JuliaInterpreter.finish!
JuliaInterpreter.finish_and_return!
JuliaInterpreter.finish_stack!
JuliaInterpreter.get_return
JuliaInterpreter.next_until!
JuliaInterpreter.maybe_next_until!
JuliaInterpreter.through_methoddef_or_done!
JuliaInterpreter.evaluate_call!
JuliaInterpreter.evaluate_foreigncall
JuliaInterpreter.maybe_evaluate_builtin
JuliaInterpreter.next_call!
JuliaInterpreter.maybe_next_call!
JuliaInterpreter.next_line!
JuliaInterpreter.until_line!
JuliaInterpreter.maybe_reset_frame!
JuliaInterpreter.maybe_step_through_wrapper!
JuliaInterpreter.maybe_step_through_kwprep!
JuliaInterpreter.handle_err
JuliaInterpreter.debug_command
```

## Breakpoints

```@docs
@breakpoint
@bp
breakpoint
enable
disable
remove
toggle
break_on
break_off
breakpoints
JuliaInterpreter.BreakOnCall
```

## Types

```@docs
Frame
JuliaInterpreter.FrameCode
JuliaInterpreter.FrameData
JuliaInterpreter._INACTIVE_EXCEPTION
JuliaInterpreter.FrameInstance
JuliaInterpreter.BreakpointState
JuliaInterpreter.BreakpointRef
JuliaInterpreter.AbstractBreakpoint
JuliaInterpreter.BreakpointSignature
JuliaInterpreter.BreakpointFileLocation
```

## Internal storage

```@docs
JuliaInterpreter.framedict
JuliaInterpreter.genframedict
JuliaInterpreter.compiled_methods
JuliaInterpreter.compiled_modules
JuliaInterpreter.interpreted_methods
```

## Utilities

```@docs
JuliaInterpreter.eval_code
JuliaInterpreter.lookup
JuliaInterpreter.is_wrapper_call
JuliaInterpreter.is_doc_expr
JuliaInterpreter.is_global_ref
CodeTracking.whereis
JuliaInterpreter.linenumber
JuliaInterpreter.Variable
JuliaInterpreter.locals
JuliaInterpreter.whichtt
```

## Hooks
```@docs
JuliaInterpreter.on_breakpoints_updated
JuliaInterpreter.firehooks
```
