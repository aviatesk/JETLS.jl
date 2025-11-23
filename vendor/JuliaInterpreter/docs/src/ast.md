!!! note
    This page and the next are designed to teach a little more about the internals.
    Depending on your interest, you may be able to skip them.

# Lowered representation

JuliaInterpreter uses the lowered representation of code.
The key advantage of lowered representation is that it is fairly well circumscribed:

- There are only a limited number of legal statements that can appear in lowered code
- Each statement is "unpacked" to essentially do one thing
- Scoping of variables is simplified via the slot mechanism, described below
- Names are fully resolved by module
- Macros are expanded

[Julia AST](https://docs.julialang.org/en/v1/devdocs/ast/) describes the kinds of
objects that can appear in lowered code.

Let's start with a demonstration on a simple function:

```julia
function summer(A::AbstractArray{T}) where T
    s = zero(T)
    for a in A
        s += a
    end
    return s
end

A = [1, 2, 5]
```

To interpret lowered representation, it maybe be useful to rewrite the body of `summer` in the following ways.
First let's use an intermediate representation that expands the `for a in A ... end` loop:

```julia
    s = zero(T)
    temp = iterate(A)         # `for` loops get lowered to `iterate/while` loops
    while temp !== nothing
        a, state = temp
        s += a
        temp = iterate(A, state)
    end
    return s
```

The lowered code takes the additional step of resolving the names by module and turning all the
branching into `@goto/@label` equivalents:

```julia
    # Code starting at line 2 (the first line of the body)
    s = Main.zero(T)       # T corresponds to the first parameter, i.e., $(Expr(:static_parameter, 1))

    # Code starting at line 3
    temp = Base.iterate(A) # here temp = @_4
    if temp === nothing    # this comparison gets stored as %4, and %5 stores !(temp===nothing)
        @goto block4
    end

    @label block2
        ## BEGIN block2
        a, state = temp[1], temp[2]  # these correspond to the `getfield` calls, state is %9

        # Code starting at line 4
        s = s + a

        # Code starting at line 5
        temp = iterate(A, state)     # A is also %2
        if temp === nothing
            @goto block4             # the `while` condition was false
        end
        ## END block2

    @goto block2           # here the `while` condition is still true

    # Code starting at line 6
    @label block4
        ## BEGIN block4
        return s
        ## END block4
```

This has very close correspondence to the lowered representation:

```julia
julia> code = @code_lowered debuginfo=:source summer(A)
CodeInfo(
    @ REPL[1]:2 within `summer'
1 ─       s = Main.zero($(Expr(:static_parameter, 1)))
│   @ REPL[1]:3 within `summer'
│   %2  = A
│         @_4 = Base.iterate(%2)
│   %4  = @_4 === nothing
│   %5  = Base.not_int(%4)
└──       goto #4 if not %5
2 ┄ %7  = @_4
│         a = Core.getfield(%7, 1)
│   %9  = Core.getfield(%7, 2)
│   @ REPL[1]:4 within `summer'
│         s = s + a
│         @_4 = Base.iterate(%2, %9)
│   %12 = @_4 === nothing
│   %13 = Base.not_int(%12)
└──       goto #4 if not %13
3 ─       goto #2
    @ REPL[1]:6 within `summer'
4 ┄       return s
)
```
!!! note
    Not all Julia versions support `debuginfo`. If the command above fails for you,
    just omit the `debuginfo=:source` portion.

To understand this package's internals, you need to familiarize yourself with these
`CodeInfo` objects.
The lines that start with `@ REPL[1]:n` indicate the source line of the succeeding
block of statements; here we defined this method in the REPL, so the source file is `REPL[1]`;
the number after the colon is the line number.

The numbers on the left correspond to [basic blocks](https://en.wikipedia.org/wiki/Basic_block),
as we annotated with `@label block2` above.
When used in statements these are printed with a hash, e.g., in `goto #4 if not %5`, the
`#4` refers to basic block 4.
The numbers in the next column--e.g., `%2`, refer to
[single static assignment (SSA) values](https://en.wikipedia.org/wiki/Static_single_assignment_form).
Each statement (each line of this printout) corresponds to a single SSA value,
but only those used later in the code are printed using assignment syntax.
Wherever a previous SSA value is used, it's referenced by an `SSAValue` and printed as `%5`;
for example, in `goto #4 if not %5`, the `%5` is the result of evaluating the 5th statement,
which is `(Base.not_int)(%4)`, which in turn refers to the result of statement 4.
Finally, temporary variables here are shown as `@_4`; the `_` indicates a *slot*, either
one of the input arguments or a local variable, and the 4 means the 4th one.
Together lines 4 and 5 correspond to `!(@_4 === nothing)`, where `@_4` has been assigned the
result of the call to `iterate` occurring on line 3. (In some Julia versions, this may be printed as `#temp#`,
similar to how we named it in our alternative implementation above.)

Let's look at a couple of the fields of the `CodeInfo`. First, the statements themselves:

```julia
julia> code.code
16-element Array{Any,1}:
 :(_3 = Main.zero($(Expr(:static_parameter, 1))))
 :(_2)
 :(_4 = Base.iterate(%2))
 :(_4 === nothing)
 :(Base.not_int(%4))
 :(unless %5 goto %16)
 :(_4)
 :(_5 = Core.getfield(%7, 1))
 :(Core.getfield(%7, 2))
 :(_3 = _3 + _5)
 :(_4 = Base.iterate(%2, %9))
 :(_4 === nothing)
 :(Base.not_int(%12))
 :(unless %13 goto %16)
 :(goto %7)
 :(return _3)
```

You can see directly that the SSA assignments are implicit; they are not directly
present in the statement list.
The most noteworthy change here is the appearance of more objects like `_3`, which are
references that index into local variable slots:

```julia
julia> code.slotnames
5-element Array{Any,1}:
 Symbol("#self#")
 :A
 :s
 Symbol("")
 :a
```

When printing the whole `CodeInfo` object, these `slotnames` are substituted in
(unless they are empty, as was the case for `@_4` above).
