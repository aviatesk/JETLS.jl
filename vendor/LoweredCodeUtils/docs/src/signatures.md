# Signatures and renaming

We can demonstrate some of this package's functionality with the following simple example:

```julia
julia> ex = :(f(x; color::Symbol=:green) = 2x)
:(f(x; color::Symbol = :green) = begin
          #= REPL[1]:1 =#
          2x
      end)

julia> eval(ex)
f (generic function with 1 method)

julia> f(3)
6
```

Things get more interesting (and complicated) when we examine the lowered code:

```julia
julia> lwr = Meta.lower(Main, ex)
:($(Expr(:thunk, CodeInfo(
    @ none within `top-level scope'
1 ─       $(Expr(:thunk, CodeInfo(
    @ none within `top-level scope'
1 ─     return $(Expr(:method, :f))
)))
│         $(Expr(:thunk, CodeInfo(
    @ none within `top-level scope'
1 ─     return $(Expr(:method, Symbol("#f#2")))
)))
│         $(Expr(:method, :f))
│         $(Expr(:method, Symbol("#f#2")))
│   %5  = Core.typeof(var"#f#2")
│   %6  = Core.Typeof(f)
│   %7  = Core.svec(%5, Symbol, %6, Core.Any)
│   %8  = Core.svec()
│   %9  = Core.svec(%7, %8, $(QuoteNode(:(#= REPL[1]:1 =#))))
│         $(Expr(:method, Symbol("#f#2"), :(%9), CodeInfo(quote
    $(Expr(:meta, :nkw, 1))
    2 * x
    return %2
end)))
│         $(Expr(:method, :f))
│   %12 = Core.Typeof(f)
│   %13 = Core.svec(%12, Core.Any)
│   %14 = Core.svec()
│   %15 = Core.svec(%13, %14, $(QuoteNode(:(#= REPL[1]:1 =#))))
│         $(Expr(:method, :f, :(%15), CodeInfo(quote
    var"#f#2"(:green, #self#, x)
    return %1
end)))
│         $(Expr(:method, :f))
│   %18 = Core.Typeof(f)
│   %19 = Core.kwftype(%18)
│   %20 = Core.Typeof(f)
│   %21 = Core.svec(%19, Core.Any, %20, Core.Any)
│   %22 = Core.svec()
│   %23 = Core.svec(%21, %22, $(QuoteNode(:(#= REPL[1]:1 =#))))
│         $(Expr(:method, :f, :(%23), CodeInfo(quote
    Base.haskey(@_2, :color)
    unless %1 goto %11
    Base.getindex(@_2, :color)
    %3 isa Symbol
    unless %4 goto %7
    goto %9
    %new(Core.TypeError, Symbol("keyword argument"), :color, Symbol, %3)
    Core.throw(%7)
    @_6 = %3
    goto %12
    @_6 = :green
    color = @_6
    Core.tuple(:color)
    Core.apply_type(Core.NamedTuple, %13)
    Base.structdiff(@_2, %14)
    Base.pairs(%15)
    Base.isempty(%16)
    unless %17 goto %20
    goto %21
    Base.kwerr(@_2, @_3, x)
    var"#f#2"(color, @_3, x)
    return %21
end)))
│   %25 = f
│   %26 = Core.ifelse(false, false, %25)
└──       return %26
))))
```

This reveals the *three* methods actually got defined:
- one method of `f` with a single positional argument (this is the second 3-argument `:method` expression)
- a keyword-handling method that checks the names of supplied keyword arguments and fills in defaults (this is the third 3-argument `:method` expression).  This method can be obtained from `Core.kwfunc(f)`, which returns a function named `f##kw`.
- a "keyword-body" method that actually does the work specifies by our function definition. This method gets called by the other two. (This is the first 3-argument `:method` expression.)

From examining the lowered code we might guess that this function is called `#f#2`.
What happens if we try to get it?

```julia
julia> fbody = var"#f#2"
ERROR: UndefVarError: #f#2 not defined
Stacktrace:
 [1] top-level scope at REPL[6]:1
```

Curiously, however, there is a closely-related function, and looking at its body code we see it is the one we wanted:

```julia
julia> fbody = var"#f#1"
#f#1 (generic function with 1 method)

julia> mbody = first(methods(fbody))
#f#1(color::Symbol, ::typeof(f), x) in Main at REPL[1]:1

julia> Base.uncompressed_ast(mbody)
CodeInfo(
    @ REPL[1]:1 within `#f#1'
1 ─      nothing
│   %2 = 2 * x
└──      return %2
)
```

It's named `#f#1`, rather than `#f#2`, because it was actually defined by that `eval(ex)` command at the top of this page. That `eval` caused it to be lowered once, and calling `Meta.lower` causes it to be lowered a second time, with different generated names.

We can obtain the running version more directly (without having to guess) via the following:

```julia
julia> m = first(methods(f))
f(x; color) in Main at REPL[1]:1

julia> using LoweredCodeUtils

julia> bodymethod(m)
#f#1(color::Symbol, ::typeof(f), x) in Main at REPL[1]:1
```

We can also rename these methods, if we first turn it into a `frame`:

```julia
julia> using JuliaInterpreter

julia> frame = Frame(Main, lwr.args[1])
Frame for Main
   1 0  1 ─       $(Expr(:thunk, CodeInfo(
   2 0  1 ─     return $(Expr(:method, :f))
   3 0  )))
⋮

julia> rename_framemethods!(frame)
Dict{Symbol,LoweredCodeUtils.MethodInfo} with 3 entries:
  :f             => MethodInfo(11, 24, [1])
  Symbol("#f#2") => MethodInfo(4, 10, [2])
  Symbol("#f#1") => MethodInfo(4, 10, [2])

julia> frame.framecode.src
CodeInfo(
    @ none within `top-level scope'
1 ─     $(Expr(:thunk, CodeInfo(
    @ none within `top-level scope'
1 ─     return $(Expr(:method, :f))
)))
│       $(Expr(:thunk, CodeInfo(
    @ none within `top-level scope'
1 ─     return $(Expr(:method, Symbol("#f#1")))
)))
│       $(Expr(:method, :f))
│       $(Expr(:method, Symbol("#f#1")))
│       ($(QuoteNode(typeof)))(var"#f#1")
│       ($(QuoteNode(Core.Typeof)))(f)
│       ($(QuoteNode(Core.svec)))(%J5, Symbol, %J6, $(QuoteNode(Any)))
│       ($(QuoteNode(Core.svec)))()
│       ($(QuoteNode(Core.svec)))(%J7, %J8, $(QuoteNode(:(#= REPL[1]:1 =#))))
│       $(Expr(:method, Symbol("#f#1"), %J9, CodeInfo(quote
    $(Expr(:meta, :nkw, 1))
    2 * x
    return %2
end)))
│       $(Expr(:method, :f))
│       ($(QuoteNode(Core.Typeof)))(f)
│       ($(QuoteNode(Core.svec)))(%J12, $(QuoteNode(Any)))
│       ($(QuoteNode(Core.svec)))()
│       ($(QuoteNode(Core.svec)))(%J13, %J14, $(QuoteNode(:(#= REPL[1]:1 =#))))
│       $(Expr(:method, :f, %J15, CodeInfo(quote
    var"#f#1"(:green, #self#, x)
    return %1
end)))
│       $(Expr(:method, :f))
│       ($(QuoteNode(Core.Typeof)))(f)
│       ($(QuoteNode(Core.kwftype)))(%J18)
│       ($(QuoteNode(Core.Typeof)))(f)
│       ($(QuoteNode(Core.svec)))(%J19, $(QuoteNode(Any)), %J20, $(QuoteNode(Any)))
│       ($(QuoteNode(Core.svec)))()
│       ($(QuoteNode(Core.svec)))(%J21, %J22, $(QuoteNode(:(#= REPL[1]:1 =#))))
│       $(Expr(:method, :f, %J23, CodeInfo(quote
    Base.haskey(@_2, :color)
    unless %1 goto %11
    Base.getindex(@_2, :color)
    %3 isa Symbol
    unless %4 goto %7
    goto %9
    %new(Core.TypeError, Symbol("keyword argument"), :color, Symbol, %3)
    Core.throw(%7)
    @_6 = %3
    goto %12
    @_6 = :green
    color = @_6
    Core.tuple(:color)
    Core.apply_type(Core.NamedTuple, %13)
    Base.structdiff(@_2, %14)
    Base.pairs(%15)
    Base.isempty(%16)
    unless %17 goto %20
    goto %21
    Base.kwerr(@_2, @_3, x)
    var"#f#1"(color, @_3, x)
    return %21
end)))
│       f
│       ($(QuoteNode(ifelse)))(false, false, %J25)
└──     return %J26
)
```

While there are a few differences in representation stemming from converting it to a frame, you can see that the `#f#2`s have been changed to `#f#1`s to match the currently-running names.
