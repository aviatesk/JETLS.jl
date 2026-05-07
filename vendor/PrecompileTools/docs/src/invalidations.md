# Why does Julia invalidate code?

Julia may be unique among computer languages in supporting all four of the following features:

1. interactive development
2. "method overloading" by packages that don't own the function
3. aggressive compilation
4. consistent compilation: same result no matter how you got there

The combination of these features *requires* that you sometimes "throw away" code that you have previously compiled.

To illustrate: suppose you have a function `numchildren` with one method,

```
numchildren(::Any) = 1
```

and then write

```
total_children(list) = sum(numchildren.(list))
```

Now let `list` be a `Vector{Any}`. You can compile a fast `total_children(::Vector{Any})` (*aggressive compilation*) by leveraging the fact that you know there's only one possible method of `numchildren`, and you know that it returns 1
for every input. Thus, `total_children(list)` gives you just `length(list)`, which would indeed be a very highly-optimized implementation!

But now suppose you add a second method (*interactive development* + *method overloading*)

```
numchildren(::BinaryNode) = 2
```

where `BinaryNode` is a new type you've defined (so it's not type-piracy). If you want to get the right answer (*consistent compilation*) from an arbitrary `list::Vector{Any}`, there are only two options:

> **Option A**: plan for this eventuality from the beginning, by making every `numchildren(::Any)` be called by runtime dispatch. But when there is only one method of `numchildren`, forcing runtime dispatch makes the code vastly slower. Thus, this option at least partly violates *aggressive compilation*.

> **Option B**: throw away the code for `total_children` that you created when there was only one method of `numchildren`, and recompile it in this new world where there are two.

Julia does a mix of these: it does **B** up to 3 methods, and then **A** thereafter. (Recent versions of Julia have experimental support for customizing this behavior with `Base.Experimental.@max_methods`.)

This example was framed as an experiment at the REPL, but it is also relevant if you load two packages: `PkgX` might define `numchildren` and `total_children`, and `PkgY` might load `PkgX` and define a second method of `PkgX.numchildren`.
Any precompilation that occurs in `PkgX` doesn't know what's going to happen in `PkgY`.
Therefore, unless you want to defer *all* compilation, including for Julia itself, until the entire session is loaded and then closed to further extension (similar to how compilers for C, Rust, etc. work), you have to make the same choice between options **A** and **B**.

Given that invalidation is necessary if Julia code is to be both fast and deliver the answers you expect, invalidation is a good thing!
But sometimes Julia "defensively" throws out code that might be correct but can't be proved to be correct by Julia's type-inference machinery; such cases of "spurious invalidation" serve to (uselessly) increase latency and worsen the Julia experience.
Except in cases of [piracy](https://docs.julialang.org/en/v1/manual/style-guide/#Avoid-type-piracy), invalidation is a risk
only for poorly-inferred code. With our example of `numchildren` and `total_children` above, the invalidations were necessary because `list` was
a `Vector{Any}`, meaning that the elements might be of `Any` type and therefore Julia can't predict in advance which
method(s) of `numchildren` would be applicable. Were one to create `list` as, say, `list = Union{BinaryNode,TrinaryNode}[]` (where `TrinaryNode` is some other kind of object with children), Julia would know much more
about the types of the objects to which it applies `numchildren`: defining yet another new method like `numchildren(::ArbitraryNode)` would not trigger invalidations of code
that was compiled for a `list::Vector{Union{BinaryNode,TrinaryNode}}`.
