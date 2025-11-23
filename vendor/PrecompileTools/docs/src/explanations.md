# How PrecompileTools works

Julia itself has a function `precompile`, to which you can pass specific signatures to force precompilation.
For example, `precompile(foo, (ArgType1, ArgType2))` will precompile `foo(::ArgType1, ::ArgType2)` *and all of its inferrable callees*.
Alternatively, you can just execute some code at "top level" within the module, and during precompilation any method or signature "owned" by your package will also be precompiled.
Thus, base Julia itself has substantial facilities for precompiling code.

## The `workload` macros

`@compile_workload` adds one key feature: the *non-inferrable callees* (i.e., those called via runtime dispatch) that get
made inside the `@compile_workload` block will also be cached, *regardless of module ownership*. In essence, it's like you're adding
an explicit `precompile(noninferrable_callee, (OtherArgType1, ...))` for every runtime-dispatched call made inside `@compile_workload`.

These `workload` macros add other features as well:

- Statements that occur inside a `@compile_workload` block are executed only if the package is being actively precompiled; it does not run when the package is loaded, nor if you're running Julia with `--compiled-modules=no`.
- Compared to just running some workload at top-level, `@compile_workload` ensures that your code will be compiled (it disables the interpreter inside the block)
- PrecompileTools also defines `@setup_workload`, which you can use to create data for use inside a `@compile_workload` block. Like `@compile_workload`, this code only runs when you are precompiling the package, but it does not necessarily result in the `@setup_workload` code being stored in the package precompile file.

## `@recompile_invalidations`

`@recompile_invalidations` activates logging of invalidations before executing code in the block.
It then parses the log to extract the "leaves" of the trees of invalidations, which generally represent
the top-level calls (typically made by runtime dispatch). It then triggers their recompilation.
Note that the recompiled code may return different results than the original (this possibility is
why the code had to be invalidated in the first place).
