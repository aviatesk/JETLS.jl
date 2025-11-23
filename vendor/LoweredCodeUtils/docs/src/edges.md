# Edges

Edges here are a graph-theoretic concept relating the connections between individual statements in the source code.
For example, consider

```julia
julia> ex = quote
           s = 0
           k = 5
           for i = 1:3
               global s, k
               s += rand(1:5)
               k += i
           end
       end
quote
    #= REPL[2]:2 =#
    s = 0
    #= REPL[2]:3 =#
    k = 5
    #= REPL[2]:4 =#
    for i = 1:3
        #= REPL[2]:5 =#
        global s, k
        #= REPL[2]:6 =#
        s += rand(1:5)
        #= REPL[2]:7 =#
        k += i
    end
end

julia> eval(ex)

julia> s
10    # random

julia> k
11    # reproducible
```

We lower it,

```
julia> lwr = Meta.lower(Main, ex)
:($(Expr(:thunk, CodeInfo(
    @ REPL[2]:2 within `top-level scope'
1 ─       s = 0
│   @ REPL[2]:3 within `top-level scope'
│         k = 5
│   @ REPL[2]:4 within `top-level scope'
│   %3  = 1:3
│         #s1 = Base.iterate(%3)
│   %5  = #s1 === nothing
│   %6  = Base.not_int(%5)
└──       goto #4 if not %6
2 ┄ %8  = #s1
│         i = Core.getfield(%8, 1)
│   %10 = Core.getfield(%8, 2)
│   @ REPL[2]:5 within `top-level scope'
│         global k
│         global s
│   @ REPL[2]:6 within `top-level scope'
│   %13 = 1:5
│   %14 = rand(%13)
│   %15 = s + %14
│         s = %15
│   @ REPL[2]:7 within `top-level scope'
│   %17 = k + i
│         k = %17
│         #s1 = Base.iterate(%3, %10)
│   %20 = #s1 === nothing
│   %21 = Base.not_int(%20)
└──       goto #4 if not %21
3 ─       goto #2
4 ┄       return
))))
```

and then extract the edges:

```julia
julia> edges = CodeEdges(lwr.args[1])
CodeEdges:
  s: assigned on [1, 16], depends on [15], and used by [12, 15]
  k: assigned on [2, 18], depends on [17], and used by [11, 17]
  statement  1 depends on [15, 16] and is used by [12, 15, 16]
  statement  2 depends on [17, 18] and is used by [11, 17, 18]
  statement  3 depends on ∅ and is used by [4, 19]
  statement  4 depends on [3, 10, 19] and is used by [5, 8, 19, 20]
  statement  5 depends on [4, 19] and is used by [6]
  statement  6 depends on [5] and is used by [7]
  statement  7 depends on [6] and is used by ∅
  statement  8 depends on [4, 19] and is used by [9, 10]
  statement  9 depends on [8] and is used by [17]
  statement 10 depends on [8] and is used by [4, 19]
  statement 11 depends on [2, 18] and is used by ∅
  statement 12 depends on [1, 16] and is used by ∅
  statement 13 depends on ∅ and is used by [14]
  statement 14 depends on [13] and is used by [15]
  statement 15 depends on [1, 14, 16] and is used by [1, 16]
  statement 16 depends on [1, 15] and is used by [1, 12, 15]
  statement 17 depends on [2, 9, 18] and is used by [2, 18]
  statement 18 depends on [2, 17] and is used by [2, 11, 17]
  statement 19 depends on [3, 4, 10] and is used by [4, 5, 8, 20]
  statement 20 depends on [4, 19] and is used by [21]
  statement 21 depends on [20] and is used by [22]
  statement 22 depends on [21] and is used by ∅
  statement 23 depends on ∅ and is used by ∅
  statement 24 depends on ∅ and is used by ∅
```

This shows the dependencies of each line as well as the "named
variables" `s` and `k`.  It's worth looking specifically to see how the
slot-variable `#s1` gets handled, as you'll notice there is no mention
of this in the "variables" section at the top.  You can see that
`#s1` first gets assigned on line 4 (the `iterate` statement),
which you'll notice depends on 3 (via the SSAValue printed as `%3`).
But that line 4 also is shown as depending on 10 and 19.
You can see that line 19 is the 2-argument call to `iterate`,
and that this line depends on SSAValue `%10` (the state variable).
Consequently all the line-dependencies of this slot variable have
been aggregated into a single list by determining the "global"
influences on that slot variable.

An even more useful output can be obtained from the following:
```
julia> LoweredCodeUtils.print_with_code(stdout, lwr.args[1], edges)
Names:
s: assigned on [1, 16], depends on [15], and used by [12, 15]
k: assigned on [2, 18], depends on [17], and used by [11, 17]
Code:
1 ─       s = 0
│             # preds: [15, 16], succs: [12, 15, 16]
│         k = 5
│             # preds: [17, 18], succs: [11, 17, 18]
│   %3  = 1:3
│             # preds: ∅, succs: [4, 19]
│         _1 = Base.iterate(%3)
│             # preds: [3, 10, 19], succs: [5, 8, 19, 20]
│   %5  = _1 === nothing
│             # preds: [4, 19], succs: [6]
│   %6  = Base.not_int(%5)
│             # preds: [5], succs: [7]
└──       goto #4 if not %6
              # preds: [6], succs: ∅
2 ┄ %8  = _1
│             # preds: [4, 19], succs: [9, 10]
│         _2 = Core.getfield(%8, 1)
│             # preds: [8], succs: [17]
│   %10 = Core.getfield(%8, 2)
│             # preds: [8], succs: [4, 19]
│         global k
│             # preds: [2, 18], succs: ∅
│         global s
│             # preds: [1, 16], succs: ∅
│   %13 = 1:5
│             # preds: ∅, succs: [14]
│   %14 = rand(%13)
│             # preds: [13], succs: [15]
│   %15 = s + %14
│             # preds: [1, 14, 16], succs: [1, 16]
│         s = %15
│             # preds: [1, 15], succs: [1, 12, 15]
│   %17 = k + _2
│             # preds: [2, 9, 18], succs: [2, 18]
│         k = %17
│             # preds: [2, 17], succs: [2, 11, 17]
│         _1 = Base.iterate(%3, %10)
│             # preds: [3, 4, 10], succs: [4, 5, 8, 20]
│   %20 = _1 === nothing
│             # preds: [4, 19], succs: [21]
│   %21 = Base.not_int(%20)
│             # preds: [20], succs: [22]
└──       goto #4 if not %21
              # preds: [21], succs: ∅
3 ─       goto #2
              # preds: ∅, succs: ∅
4 ┄       return
              # preds: ∅, succs: ∅
```

Here the edges are printed right after each line.

!!! note
    "Nice" output from `print_with_code` requires at least version 1.6.0-DEV.95 of Julia.

Suppose we want to evaluate just the lines needed to compute `s`.
We can find out which lines these are with

```julia
julia> isrequired = lines_required(:s, lwr.args[1], edges)
24-element BitArray{1}:
 1
 0
 1
 1
 1
 1
 1
 1
 0
 1
 0
 0
 1
 1
 1
 1
 0
 0
 1
 1
 1
 1
 1
 0
```

and display them with

```
julia> LoweredCodeUtils.print_with_code(stdout, lwr.args[1], isrequired)
 1 t 1 ─       s = 0
 2 f │         k = 5
 3 t │   %3  = 1:3
 4 t │         _1 = Base.iterate(%3)
 5 t │   %5  = _1 === nothing
 6 t │   %6  = Base.not_int(%5)
 7 t └──       goto #4 if not %6
 8 t 2 ┄ %8  = _1
 9 f │         _2 = Core.getfield(%8, 1)
10 t │   %10 = Core.getfield(%8, 2)
11 f │         global k
12 f │         global s
13 t │   %13 = 1:5
14 t │   %14 = rand(%13)
15 t │   %15 = s + %14
16 t │         s = %15
17 f │   %17 = k + _2
18 f │         k = %17
19 t │         _1 = Base.iterate(%3, %10)
20 t │   %20 = _1 === nothing
21 t │   %21 = Base.not_int(%20)
22 t └──       goto #4 if not %21
23 t 3 ─       goto #2
24 f 4 ┄       return
```

We can test this with the following:

```julia
julia> using JuliaInterpreter

julia> frame = Frame(Main, lwr.args[1])
Frame for Main
   1 2  1 ─       s = 0
   2 3  │         k = 5
   3 4  │   %3  = 1:3
⋮

julia> k
11

julia> k = 0
0

julia> selective_eval_fromstart!(frame, isrequired, true)

julia> k
0

julia> s
12     # random

julia> selective_eval_fromstart!(frame, isrequired, true)

julia> k
0

julia> s
9      # random
```

You can see that `k` was not reset to its value of 11 when we ran this code selectively,
but that `s` was updated (to a random value) each time.
