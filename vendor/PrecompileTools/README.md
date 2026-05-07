# PrecompileTools

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaLang.github.io/PrecompileTools.jl/stable/)
[![Build Status](https://github.com/JuliaLang/PrecompileTools.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/JuliaLang/PrecompileTools.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/JuliaLang/PrecompileTools.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaLang/PrecompileTools.jl)

PrecompileTools allows you to reduce the latency of the first execution of Julia code.
**It is applicable for package developers and for "ordinary users" in their personal workflows.**

To learn how to use PrecompileTools, see the [documentation](https://JuliaLang.github.io/PrecompileTools.jl/stable/).

## PrecompileTools and PackageCompiler

Particularly on Julia 1.9 and higher, PrecompileTools allows dramatic reduction in "time to first execution" (TTFX) without the need for user-customization.
In this respect, it shares goals with (and performs similarly to) [PackageCompiler](https://github.com/JuliaLang/PackageCompiler.jl).

Nevertheless, the two are not identical:

- only PrecompileTools can be used by *package developers* to ensure a better out-of-box experience for your users
- only PrecompileTools allows you to update your packages without needing to rebuild Julia
- only PackageCompiler dramatically speeds up loading time (i.e., `using ...`) for all the packages

Here is a table summarizing the information.

| Task | Julia 1.9 + PrecompileTools | PackageCompiler |
|:----- | ---:| ---:|
| Developers can reduce out-of-box TTFX for their users | ✔️ | ❌ |
| Users can reduce TTFX for custom tasks | ✔️ | ✔️ |
| Packages can be updated without rebuilding system image | ✔️ | ❌ |
| Reduces time to load (TTL) | ❌ | ✔️ |

The difference in time to load arises because the system image can safely skip all the code-validation checks that are necessary when loading packages. Examples of the reduction in time to first execution and time to load can be found in the [Julia 1.9 highlights blog post](https://julialang.org/blog/2023/04/julia-1.9-highlights/#caching_of_native_code).

## Inspecting the package precompile files 

[PkgCacheInspector](https://github.com/timholy/PkgCacheInspector.jl) provides insight about what's stored in Julia's package precompile files.

## History (origins as SnoopPrecompile)

PrecompileTools is the successor to [SnoopPrecompile](https://github.com/timholy/SnoopCompile.jl/tree/master/SnoopPrecompile).
PrecompileTools differs in naming and in how one disables precompilation, but is otherwise a drop-in replacement.

This new package was created for several reasons:

- PrecompileTools has become (directly or indirectly) a dependency of much of the Julia ecosystem, a trend that seems likely to grow with time.
    Therefore, this package is now hosted in the JuliaLang GitHub organization.
- As Julia's own stdlibs migrate to become independently updateable (true for DelimitedFiles in Julia 1.9, with others anticipated for Julia 1.10), several of them would like to use PrecompileTools for high-quality precompilation. That requires making PrecompileTools its own "upgradable stdlib."
- This package introduces the [use of Preferences](https://github.com/timholy/SnoopCompile.jl/issues/356) to make packages more independent of one another. Since this would have been a breaking change, it seemed like a good opportunity to fix other issues, too.

For more information and discussion, see the [Discourse announcement post](https://discourse.julialang.org/t/ann-snoopprecompile-precompiletools/97882).
