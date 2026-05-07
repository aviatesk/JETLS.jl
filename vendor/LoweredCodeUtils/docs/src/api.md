# API

## Signatures

```@docs
signature
methoddef!
rename_framemethods!
bodymethod
```

## Edges

```@docs
CodeEdges
lines_required
lines_required!
selective_eval!
selective_eval_fromstart!
```

## Interpreter

```@docs
LoweredCodeUtils.SelectiveInterpreter
```

## Internal utilities

```@docs
LoweredCodeUtils.print_with_code
LoweredCodeUtils.next_or_nothing
LoweredCodeUtils.skip_until
LoweredCodeUtils.MethodInfo
LoweredCodeUtils.identify_framemethod_calls
LoweredCodeUtils.iscallto
LoweredCodeUtils.getcallee
LoweredCodeUtils.find_name_caller_sig
LoweredCodeUtils.replacename!
LoweredCodeUtils.Variable
```
