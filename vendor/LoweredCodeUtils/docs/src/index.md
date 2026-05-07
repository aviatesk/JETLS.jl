# LoweredCodeUtils.jl

This package performs operations on Julia's [lowered AST](https://docs.julialang.org/en/latest/devdocs/ast/).
An introduction to this representation can be found at [JuliaInterpreter](https://juliadebug.github.io/JuliaInterpreter.jl/stable/).

Lowered AST (like other ASTs, type-inferred AST and SSA IR form) is generally more amenable to analysis than "surface" Julia expressions.
However, sophisticated analyses can nevertheless require a fair bit of infrastructure.
The purpose of this package is to standardize a few operations that are important in some applications.

Currently there are two major domains of this package: the "signatures" domain and the "edges" domain.

## Signatures

A major role of this package is to support extraction of method signatures, in particular to provide strong support for relating keyword-method "bodies" to their parent methods.
The central challenge this addresses is the lowering of keyword-argument functions and the fact that the "gensymmed" names are different each time you lower the code, and therefore you don't recover the actual (running) keyword-body method.
The technical details are described in [this Julia issue](https://github.com/JuliaLang/julia/issues/30908) and on the next page.
This package provides a workaround to rename gensymmed variables in newly-lowered code to match the name of the running keyword-body method, and provides a convenience function, `bodymethod`, to
obtain that otherwise difficult-to-discover method.



## Edges

Sometimes you want to run only a selected subset of code. For instance, Revise tracks methods
by their signatures, and therefore needs to compute signatures from the lowered representation of code.
Doing this robustly (including for `@eval`ed methods, etc.) requires running module top-level
code through the interpreter.
For reasons of performance and safety, it is important to minimize the amount of code that gets executed when extracting the signature.

This package provides a general framework for computing dependencies in code, through the `CodeEdges` constructor. It allows you to determine the lines on which any given statement depends, the lines which "consume" the result of the current line, and any "named" dependencies (`Symbol` and `GlobalRef` dependencies).
In particular, this resolves the line-dependencies of all `SlotNumber` variables so that their own dependencies will be handled via the code-line dependencies.
