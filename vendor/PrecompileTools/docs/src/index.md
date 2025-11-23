# PrecompileTools

## Overview

`PrecompileTools` is designed to help reduce delay on first usage of Julia code.
It can force *precompilation* of specific workloads; particularly with Julia 1.9 and higher,
the precompiled code is automatically saved to disk, so that it doesn't need to be compiled freshly in each Julia session.
You can use `PrecompileTools` as a package developer, to reduce the latency experienced by users of your package for "typical" workloads;
you can also use `PrecompileTools` as a user, creating custom "Startup" package(s) that precompile workloads important for your work.

The main tool in `PrecompileTools` is a macro, `@compile_workload`, which precompiles all the code needed to execute the workload.
It also includes a second macro, `@setup_workload`, which can be used to "mark" a block of code as being relevant only
for precompilation but which does not itself force compilation of `@setup_workload` code. (`@setup_workload` is typically used to generate
test data using functions that you don't need to precompile in your package.)
Finally, `PrecompileTools` includes `@recompile_invalidations` to mitigate the undesirable consequences of *invalidations*.
These different tools are demonstrated below.

!!! note
    The latency reductions from PrecompileTools are maximally effective for Julia versions 1.9 and higher, and intermediate for Julia 1.8. Julia versions 1.7 and earlier may see some limited benefit as well, but have also occasionally been found to suffer from [precompilation-induced runtime performance regressions](https://github.com/JuliaLang/julia/issues/35972). If you wish, you can disable precompilation on older Julia versions by wrapping precompilation statements (see below) with `if Base.VERSION >= v"1.8" ... end`. On older Julia versions, you may wish to test packages for performance regressions when introducing precompilation directives.

## Tutorial: forcing precompilation with workloads

No matter whether you're a package developer or a user looking to make your own workloads start faster,
the basic workflow of `PrecompileTools` is the same.
Here's an illustration of how you might use `@compile_workload` and `@setup_workload`:

```julia
module MyPackage

using PrecompileTools: @setup_workload, @compile_workload    # this is a small dependency

struct MyType
    x::Int
end
struct OtherType
    str::String
end

@setup_workload begin
    # Putting some things in `@setup_workload` instead of `@compile_workload` can reduce the size of the
    # precompile file and potentially make loading faster.
    list = [OtherType("hello"), OtherType("world!")]
    @compile_workload begin
        # all calls in this block will be precompiled, regardless of whether
        # they belong to your package or not (on Julia 1.8 and higher)
        d = Dict(MyType(1) => list)
        x = get(d, MyType(2), nothing)
        last(d[MyType(1)])
    end
end

end
```

!!! warning
    `@compile_workload` should go at "top level," not compiled into a function. A pattern like `withenv(...) do @compile_workload begin ... end end`,
    where `@compile_workload` appears in the anonymous function passed to `withenv`, may defeat some of the value of PrecompileTools.

When you build `MyPackage`, it will precompile the following, *including all their callees*:

- `Pair(::MyPackage.MyType, ::Vector{MyPackage.OtherType})`
- `Dict(::Pair{MyPackage.MyType, Vector{MyPackage.OtherType}})`
- `get(::Dict{MyPackage.MyType, Vector{MyPackage.OtherType}}, ::MyPackage.MyType, ::Nothing)`
- `getindex(::Dict{MyPackage.MyType, Vector{MyPackage.OtherType}}, ::MyPackage.MyType)`
- `last(::Vector{MyPackage.OtherType})`

In this case, the "top level" calls were fully inferrable, so there are no entries on this list
that were called by runtime dispatch. Thus, here you could have gotten the same result with manual
`precompile` directives.
The key advantage of `@compile_workload` is that it works even if the functions you're calling
have runtime dispatch.

Once you set up a block using `PrecompileTools`, try your package and see if it reduces the time to first execution,
using the same workload you put inside the `@compile_workload` block.

If you're happy with the results, you're done! If you want deeper verification of whether it worked as
expected, or if you suspect problems, the [SnoopCompile package](https://github.com/timholy/SnoopCompile.jl) provides diagnostic tools.
Potential sources of trouble include invalidation (diagnosed with `SnoopCompileCore.@snoop_invalidations` and related tools)
and omission of intended calls from inside the `@compile_workload` block (diagnosed with `SnoopCompileCore.@snoop_inference` and related tools).

!!! note
    `@compile_workload` works by monitoring type-inference. If the code was already inferred
    prior to `@compile_workload` (e.g., from prior usage), you might omit any external
    methods that were called via runtime dispatch.

    You can use multiple `@compile_workload` blocks if you need to interleave `@setup_workload` code with
    code that you want precompiled.
    You can use `@snoop_inference` to check for any (re)inference when you use the code in your package.
    To fix any specific problems, you can combine `@compile_workload` with manual `precompile` directives.

## Tutorial: local "Startup" packages

Users who want to precompile workloads that have not been precompiled by the packages they use can follow the recipe
above, creating custom "Startup" packages for each project.
Imagine that you have three different kinds of analyses you do: you could have a folder

```
MyData/
  Project1/
  Project2/
  Project3/
```

From each one of those `Project` folders you could do the following:

```
(@v1.9) pkg> activate .
  Activating new project at `/tmp/Project1`

(Project1) pkg> generate Startup
  Generating  project Startup:
    Startup/Project.toml
    Startup/src/Startup.jl

(Project1) pkg> dev ./Startup
   Resolving package versions...
    Updating `/tmp/Project1/Project.toml`
  [e9c42744] + Startup v0.1.0 `Startup`
    Updating `/tmp/Project1/Manifest.toml`
  [e9c42744] + Startup v0.1.0 `Startup`

(Project1) pkg> activate Startup/
  Activating project at `/tmp/Project1/Startup`

(Startup) pkg> add PrecompileTools LotsOfPackages...
```

In the last step, you add `PrecompileTools` and all the package you'll need for your work on `Project1`
as dependencies of `Startup`.
Then edit the `Startup/src/Startup.jl` file to look similar to the tutorial previous section, e.g.,

```julia
module Startup

using LotsOfPackages...
using PrecompileTools

@compile_workload begin
    # inside here, put a "toy example" of everything you want to be fast
end

end
```

Then when you're ready to start work, from the `Project1` environment just say `using Startup`.
All the packages will be loaded, together with their precompiled code.

!!! tip
    If desired, the [Reexport package](https://github.com/simonster/Reexport.jl) can be used to ensure these packages are also exported by `Startup`.

## Tutorial: "healing" invalidations

Julia sometimes *invalidates* previously compiled code (see [Why does Julia invalidate code?](@ref)).
PrecompileTools provides a mechanism to recompile the invalidated code so that you get the full benefits
of precompilation. This capability can be used in "Startup" packages (like the one described
above), as well as by package developers.

!!! tip
    Excepting [piracy](https://docs.julialang.org/en/v1/manual/style-guide/#Avoid-type-piracy) (which is heavily discouraged),
    *type-stable (i.e., well-inferred) code cannot be invalidated.* If invalidations are a problem, an even better option
    than "healing" the invalidations is improving the inferrability of the "victim": not only will you prevent
    invalidations, you may get faster performance and slimmer binaries. Packages that can help identify
    inference problems and invalidations include [SnoopCompile](https://github.com/timholy/SnoopCompile.jl),
    [JET](https://github.com/aviatesk/JET.jl), and [Cthulhu](https://github.com/JuliaDebug/Cthulhu.jl).

The basic usage is simple: wrap expressions that might invalidate with `@recompile_invalidations`.
Invalidation can be triggered by defining new methods of external functions, including during
package loading. Using the "Startup" package above, you might wrap the `using` statements:

```julia
module Startup

using PrecompileTools
@recompile_invalidations begin
    using LotsOfPackages...
end

# Maybe a @compile_workload here?

end
```

Note that recompiling invalidations can be useful even if you don't add any additional workloads.

Alternatively, if you're a package developer worried about "collateral damage" you may cause by extending functions
owned by Base or other package (i.e., those that require `import` or module-scoping when defining the method),
you can wrap those method definitions:

```julia
module MyContainers

using AnotherPackage
using PrecompileTools

struct Container
    list::Vector{Any}
end

# This is a function created by this package, so it doesn't need to be wrapped
make_container() = Container([])

@recompile_invalidations begin
    # Only those methods extending Base or other packages need to go here
    Base.push!(obj::Container, x) = ...
    function AnotherPackage.foo(obj::Container)
        ⋮
    end
end

end
```

You can have more than one `@recompile_invalidations` block in a module. For example, you might use one to wrap your
`using`s, and a second to wrap your method extensions.

!!! warning
    Package developers should be aware of the tradeoffs in using `@recompile_invalidations` to wrap method extensions:

    - the benefit is that you might deliver a better out-of-the-box experience for your users, without them needing to customize anything
    - the downside is that it will increase the precompilation time for your package. Worse, what can be invalidated once can sometimes be invalidated again by a later package, and if that happens the time spent recompiling is wasted.

    Using `@recompile_invalidations` in a "Startup" package is, in a sense, safer because it waits for all the code to be loaded before recompiling anything. On the other hand, this requires users to implement their own customizations.

    Package developers are encouraged to try to fix "known" invalidations rather than relying reflexively on `@recompile_invalidations`.

## When you can't run a workload

There are cases where you might want to precompile code but cannot safely *execute* that code: for example, you may need to connect to a database, or perhaps this is a plotting package but you may be currently on a headless server lacking a display, etc.
In that case, your best option is to fall back on Julia's own `precompile` function.
However, as explained in [How PrecompileTools works](@ref), there are some differences between `precompile` and `@compile_workload`;
most likely, you may need multiple `precompile` directives.
Analysis with [SnoopCompile](https://github.com/timholy/SnoopCompile.jl) may be required to obtain the results you want;
in particular, combining `@snoop_inference` and `parcel` will allow you to generate a set of `precompile` directives that can be `include`d in your module definition.

Be aware that `precompile` directives are more specific to the Julia version, CPU (integer width), and OS than running a workload.

## Troubleshooting

Ensure your workload "works" (runs without error) when copy/pasted into the REPL.
If it produces an error only when placed inside `@precompile_workload`, check whether your workload runs when wrapped in a

```
let
    # workload goes here
end
```

block.

## Package developers: reducing the cost of precompilation during development

If you're frequently modifying one or more packages, you may not want to spend the extra time precompiling the full set of workloads that you've chosen to make fast for your "shipped" releases.
One can *locally* reduce the cost of precompilation for selected packages using the `Preferences.jl`-based mechanism and the `"precompile_workload"` key: from within your development environment, use

```julia
using MyPackage, Preferences
set_preferences!(MyPackage, "precompile_workload" => false; force=true)
```

This will write the following to LocalPreferences.toml alongside your active environment Project.toml

```
[MyPackage]
precompile_workload = false
```

After restarting julia, the `@compile_workload` and `@setup_workload` workloads will be disabled (locally) for `MyPackage`.
You can also specify additional packages (e.g., dependencies of `MyPackage`) if you're co-developing a suite of packages.  Simply run `set_preferences!` for the additional packages, or edit LocalPreferences.toml directly.

!!! note
    Changing `precompile_workload` will result in a one-time recompilation of all packages that depend on the package(s) from the current environment.
    Package developers may wish to set this preference locally within the "main" package's environment;
    precompilation will be skipped while you're actively developing the project, but not if you use the package
    from an external environment. This will also keep the `precompile_workload` setting independent and avoid needless recompilation
    of large environments.

Finally, it is possible to fully disable PrecompileTools.jl for all packages with

```julia
using PrecompileTools, Preferences
set_preferences!(PrecompileTools, "precompile_workloads" => false; force=true)
```

This can be helpful to reduce the system image size generated when using PackageCompiler.jl by only compiling calls made in a precompilation script.

## Seeing what got precompiled

If you want to see the list of calls that will be precompiled, navigate to the `MyPackage` folder and use

```julia
julia> using PrecompileTools

julia> PrecompileTools.verbose[] = true   # runs the block even if you're not precompiling, and print precompiled calls

julia> include("src/MyPackage.jl");
```

This will only show the direct- or runtime-dispatched method instances that got precompiled (omitting their inferrable callees).
For a more comprehensive list of all items stored in the compile_workload file, see
[PkgCacheInspector](https://github.com/timholy/PkgCacheInspector.jl).
