
    using ExproniconLite: @expr, print_inline
    print_inline(:(1 + 1))
    print_inline(:(-((1 + 1))))
    print_inline(:(-(1 * 1)))
    print_inline(:(-1 * 1))
    print_inline(:(2 * 2 - 1 * 1))
    print_inline(:(var"##step_1_l#259" = 1 << (var"##plain_locs#258"[1] - 1)))
    print_inline(:(module A
          begin
              #= /Users/roger/Code/Julia/Expronicon/lib/ZhanKai/src/process.jl:221 =# @static if !(isdefined(#= /Users/roger/Code/Julia/Expronicon/lib/ZhanKai/src/process.jl:221 =# @__MODULE__(), :include_generated))
                      function __include_generated__(_path::String)
                          #= /Users/roger/Code/Julia/Expronicon/lib/ZhanKai/src/process.jl:223 =# Base.@_noinline_meta
                          mod = #= /Users/roger/Code/Julia/Expronicon/lib/ZhanKai/src/process.jl:224 =# @__MODULE__()
                          (path, prev) = Base._include_dependency(mod, _path)
                          code = read(path, String)
                          tls = task_local_storage()
                          tls[:SOURCE_PATH] = path
                          try
                              ex = include_string(mod, "quote $(code) end", path)
                              mod.eval(mod.eval(ex))
                              return
                          finally
                              if prev === nothing
                                  delete!(tls, :SOURCE_PATH)
                              else
                                  tls[:SOURCE_PATH] = prev
                              end
                          end
                      end
                  end
          end
          end))
    print_inline(:(using A, B))
    print_inline(:(using A: a, b))
    print_inline(:(import A, B))
    print_inline(:(import A: a, b as c))
    print_inline(:(import A as B))
    print_inline(:(A.B))
    print_inline(:(export a, b))
    print_inline("aaaa")
    print_inline("aa\"a")
    print_inline(:("aaaa" * "bbbb"))
    print_inline(:(A{T} where T <: B))
    print_inline(:(A{T} where {T <: B, T2 <: C}))
    print_inline(:(Tuple{var1, var2} where {var1, var2 <: AbstractArray}))
    print_inline(:(A::B))
    print_inline(:(print_expr(:(function foo(x, y::T; z::Int = 1) where {N, T <: Real}
                    x + 1
                end))))
    print_inline(:(struct ABC
              a::Int
          end))
    print_inline(:(mutable struct ABC
              a::Int
          end))
    print_inline(:(struct ABC
              a::Int
              b::Int
          end))
    print_inline(:(primitive type ABC 32 end))
    print_inline(:(abstract type ABC end))
    print_inline(:(abstract type ABC <: BCD end))
    print_inline(:(break))
    print_inline(:(foo(x, y, z)))
    print_inline(:(foo(x, y, z...)))
    print_inline(:(foo(x, y, z; a, b = 2)))
    print_inline(:(#= none:39 =# @mymacro(begin
                  x + 1
                  x + 2
              end, y, z + 1)))
    print_inline(:((a in b) .+ 1))
    print_inline(:(1:10))
    print_inline(:((p::InlinePrinter)(x, xs...; delim = ", ")))
    print_inline(:(Base.:(==)(a::Variant, b::Variant)))
    print_inline(:(foo() do 
          end))
    print_inline(:(foo() do x
          end))
    print_inline(:(foo() do x, y, z
          end))
    print_inline(:(foo() do x, y, z
              1 + 1
              2 + 2
          end))
    print_inline(:(foo() do x, y, z...
              1 + 1
              2 + 2
          end))
    print_inline(:((x->begin
                  x + 1
              end)))
    print_inline(:((x, (y->begin
                      x + 1
                  end))))
    print_inline(:(((x, y)->begin
                  x + 1
                  y + 1
              end)))
    print_inline(:(1 + x + y + z))
    print_inline(:(+z))
    print_inline(:(-z))
    print_inline(:((1, 2, x)))
    print_inline(:(SubArray(var"##8070", (1:length(var"##8070"),))))
    print_inline(:([1, 2, x]))
    print_inline(:([1 2 x]))
    print_inline(:([1; 2; x]))
    print_inline(:([1;; 2;; x]))
    print_inline(:(Float64[1, 2, x]))
    print_inline(:(Float64[1 2 x]))
    print_inline(:([[line] for line = eachsplit(ex, '\n')]))
    print_inline(:(Any[[line] for line = eachsplit(ex, '\n')]))
    print_inline(quote
            x + 1
            y + 1
        end)
    print_inline(#= none:72 =# @expr(:($(Expr(:using, :($(Expr(:., :($(Expr(:$, :(&name))))))))))))
    print_inline(Expr(:string, "aaa", :x, "bbb"))
    print_inline(:(:x))
    print_inline(:(quote
              1 + 1
              2 + x
          end))
    print_inline(quote
            1 + 1
            2 + x
        end)
    print_inline(:(let x = 1
              y + 1
          end))
    print_inline(:(let x = 1, y
              x + 1
              y + 1
          end))
    print_inline(:(for i = 1:10
              x + 1
              y + 1
          end))
    print_inline(:(while x < 10
              x + 1
              y + 1
          end))
    print_inline(:(if x < 10
              x + 1
              y + 1
          end))
    print_inline(:(if x < 10
              x + 1
              y + 1
          else
              x + 1
              y + 1
          end))
    print_inline(:(if x < 10
              x + 1
              y + 1
          elseif x < 10
              x + 1
              y + 1
          else
              x + 1
              y + 1
          end))
    print_inline(:(try
              x + 1
              y + 1
          catch
              1 + 1
          end))
    print_inline(:(try
              x + 1
              y + 1
          catch e
              1 + 1
          end))
    print_inline(:(try
              x + 1
              y + 1
          catch e
              1 + 1
          finally
              2 + 2
          end))
    print_inline(Expr(:$, :(1 + 2)))
    print_inline(Expr(:meta, :aa, 2))
    print_inline(:($(Symbol("##a#112")) + 1))
    print_inline(:(::$(Symbol("##a#112")) + 1))
    print_inline(:((a, b, c)))
    print_inline(:((; a, b, c = 2)))
    print_inline(:(return (; a, b, c = 2)))
    print_inline(Expr(:meta, :inline))
    print_inline(Expr(:symbolicgoto, :abc))
    print_inline(Expr(:symboliclabel, :abc))
    print_inline(Expr(:block, LineNumberNode(0), LineNumberNode(0)); line = true)
    print_inline(Expr(:block, LineNumberNode(0), :a); line = true)
    print_inline(Expr(:block, :a, LineNumberNode(0)); line = true)
    print_inline(Expr(:block, :a, :b); line = true)
    print_inline(Expr(:continue))
