# CodeTracking

[![Build status](https://github.com/timholy/CodeTracking.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/timholy/CodeTracking.jl/actions/workflows/ci.yml)
[![Coverage](https://codecov.io/gh/timholy/CodeTracking.jl/branch/master/graph/badge.svg?token=bBzCYyj19O)](https://codecov.io/gh/timholy/CodeTracking.jl)

CodeTracking can be thought of as an extension of Julia's
[InteractiveUtils library](https://docs.julialang.org/en/v1/stdlib/InteractiveUtils/).
It provides an interface for obtaining:

- the strings and expressions of method definitions
- the method signatures (and their corresponding method table) at a specific file & line number
- location information for "dynamic" code that might have moved since it was first loaded
- a list of files that comprise a particular package.

CodeTracking is a minimal package designed to work with
[Revise.jl](https://github.com/timholy/Revise.jl) (for versions v1.1.0 and higher).
CodeTracking is a very lightweight dependency.

## Examples

### `@code_string` and `@code_expr`

```julia
julia> using CodeTracking, Revise

julia> print(@code_string sum(1:5))
function sum(r::AbstractRange{<:Real})
    l = length(r)
    # note that a little care is required to avoid overflow in l*(l-1)/2
    return l * first(r) + (iseven(l) ? (step(r) * (l-1)) * (l>>1)
                                     : (step(r) * l) * ((l-1)>>1))
end

julia> @code_expr sum(1:5)
[ Info: tracking Base
quote
    #= toplevel:977 =#
    function sum(r::AbstractRange{<:Real})
        #= /home/tim/src/julia-1/base/range.jl:978 =#
        l = length(r)
        #= /home/tim/src/julia-1/base/range.jl:980 =#
        return l * first(r) + if iseven(l)
                    (step(r) * (l - 1)) * l >> 1
                else
                    (step(r) * l) * (l - 1) >> 1
                end
    end
end
```

`@code_string` succeeds in that case even if you are not using Revise, but `@code_expr` always requires Revise.
(If you must live without Revise, you can use `Meta.parse(@code_string(...))` as a fallback.)

"Difficult" methods are handled more accurately with `@code_expr` and Revise.
Here's one that's defined via an `@eval` statement inside a loop:

```julia
julia> @code_expr Float16(1) + Float16(2)
:(a::Float16 + b::Float16 = begin
          #= /home/tim/src/julia-1/base/float.jl:398 =#
          Float16(Float32(a) + Float32(b))
      end)
```

whereas `@code_string` cannot return a useful result:

```
julia> @code_string Float16(1) + Float16(2)
"# This file is a part of Julia. License is MIT: https://julialang.org/license\n\nconst IEEEFloat = Union{Float16, Float32, Float64}"
```
Consequently it's recommended to use `@code_expr` in preference to `@code_string` wherever possible.

`@code_expr` and `@code_string` have companion functional variants, `code_expr` and `code_string`, which accept the function and a `Tuple{T1, T2, ...}` of types.

`@code_expr` and `@code_string` are based on the lower-level function `definition`;
you can read about it with `?definition`.

### Location information

```julia
julia> using CodeTracking, Revise

julia> m = @which sum([1,2,3])
sum(a::AbstractArray) in Base at reducedim.jl:648

julia> Revise.track(Base)  # also edit reducedim.jl

julia> file, line = whereis(m)
("/home/tim/src/julia-1/usr/share/julia/base/reducedim.jl", 642)

julia> m.line
648
```

In this (ficticious) example, `sum` moved because I deleted a few lines higher in the file;
these didn't affect the functionality of `sum` (so we didn't need to redefine and recompile it),
but it does change the starting line number of the file at which this method appears.
`whereis` reports the current line number, and `m.line` the old line number. (For technical reasons, it is important that `m.line` remain at the value it had when the code was lowered.)

Other methods of `whereis` allow you to obtain the current position corresponding to a single
statement inside a method; see `?whereis` for details.

CodeTracking can also be used to find out what files define a particular package:

```julia
julia> using CodeTracking, Revise, ColorTypes

julia> pkgfiles(ColorTypes)
PkgFiles(ColorTypes [3da002f7-5984-5a60-b8a6-cbb66c0b333f]):
  basedir: /home/tim/.julia/packages/ColorTypes/BsAWO
  files: ["src/ColorTypes.jl", "src/types.jl", "src/traits.jl", "src/conversions.jl", "src/show.jl", "src/operations.jl"]
```


You can also find the method signatures at a particular location:

```julia
julia> signatures_at(ColorTypes, "src/traits.jl", 14)
1-element Vector{Pair{Union{Nothing, Core.MethodTable}, Type}}:
 nothing => Tuple{typeof(red),AbstractRGB}

julia> signatures_at("/home/tim/.julia/packages/ColorTypes/BsAWO/src/traits.jl", 14)
1-element Vector{Pair{Union{Nothing, Core.MethodTable}, Type}}:
 nothing => Tuple{typeof(red),AbstractRGB}
```

with the first element being the method table for which the method was added (a value of `nothing` denotes the default method table).

CodeTracking also helps correcting for [Julia issue #26314](https://github.com/JuliaLang/julia/issues/26314):

```julia
julia> @which uuid1()
uuid1() in UUIDs at C:\cygwin\home\Administrator\buildbot\worker\package_win64\build\usr\share\julia\stdlib\v1.1\UUIDs\src\UUIDs.jl:50

julia> CodeTracking.whereis(@which uuid1())
("C:\\Users\\SomeOne\\AppData\\Local\\Julia-1.1.0\\share\\julia\\stdlib\\v1.1\\UUIDs\\src\\UUIDs.jl", 50)
```

## A few details

CodeTracking has limited functionality unless the user is also running Revise,
because Revise populates CodeTracking's internal variables.
(Using `whereis` as an example, CodeTracking will just return the
file/line info in the method itself if Revise isn't running.)

CodeTracking is perhaps best thought of as the "query" part of Revise.jl,
providing a lightweight and stable API for gaining access to information it maintains internally.

## Limitations (without Revise)

- parsing sometimes starts on the wrong line. Line numbers are determined by counting `'\n'` in the source file, without parsing the contents. Consequently quoted- or in-code `'\n'` can mess up CodeTracking's notion of line numbering
- default constructor methods for `struct`s are not found
