# OrderedCollections.jl

This package implements associative containers that preserve the order of insertion:

-   OrderedDict
-   OrderedSet
-   LittleDict


## OrderedSets

`OrderedSets` are sets whose entries have a particular order.
Order refers to *insertion order*, which allows deterministic
iteration over the set:

```julia
using Base.MathConstants
s = OrderedSet((π,e,γ,catalan,φ))
for x in s
   println(x)
end
#> π = 3.1415926535897...
#> ℯ = 2.7182818284590...
#> γ = 0.5772156649015...
#> catalan = 0.9159655941772...
#> φ = 1.6180339887498...
```
All `Set` operations are available for OrderedSets.

Note that to create an OrderedSet of a particular type, you must
specify the type in curly-braces:

```julia
# create an OrderedSet of Strings
strs = OrderedSet{AbstractString}()
```

## OrderedDicts
Similarly, `OrderedDict` are simply dictionaries whose entries have a particular
order.
```julia
d = OrderedDict{Char,Int}()
for c in 'a':'d'
    d[c] = c-'a'+1
end
for x in d
   println(x)
end
#> 'a' => 1
#> 'b' => 2
#> 'c' => 3
#> 'd' => 4
```
The insertion order is conserved when iterating on the dictionary itself,
its keys (through `keys(d)`), or its values (through `values(d)`).
All standard `Associative` and `Dict` functions are available for `OrderedDicts`

## LittleDict
```julia
d = LittleDict{Char,Int}()
for c in 'a':'d'
    d[c] = c-'a'+1
end
for x in d
   println(x)
end
#> 'a' => 1
#> 'b' => 2
#> 'c' => 3
#> 'd' => 4
```
The `LittleDict` acts similarly to the `OrderedDict`.
However for small collections it is much faster.
Indeed the preceeding example (with the io redirected to `devnull`), runs 4x faster in the `LittleDict` version as the earlier `OrderedDict` version.

```@docs
OrderedDict
OrderedSet
LittleDict
LittleSet
freeze
OrderedCollections.isordered
```
