
    using Test
    using ExproniconLite
    #= none:4 =# @testset "one line expression" begin
            #= none:5 =# @test sprint_expr(:(name::type)) == "name::type"
            #= none:6 =# @test sprint_expr(:("abc $(name)")) == "\"abc \$name\""
            #= none:7 =# @test sprint_expr(:(compare_expr(lhs, rhs::Int))) == "compare_expr(lhs, rhs::Int)"
            #= none:8 =# @test sprint_expr(:(compare_expr(lhs, rhs::Int; a = "c"))) == "compare_expr(lhs, rhs::Int; a = \"c\")"
            #= none:9 =# @test sprint_expr(:(return (a, b, c))) == "return a, b, c"
            #= none:10 =# @test sprint_expr(:(a = b)) == "a = b"
            #= none:11 =# @test sprint_expr(Expr(:kw, :a, :b)) == "a = b"
            #= none:12 =# @test sprint_expr(:(!x)) == "!x"
            #= none:13 =# @test sprint_expr(:(x + 1)) == "x + 1"
            #= none:14 =# @test sprint_expr(:(x * 1)) == "x * 1"
            str = sprint_expr(:(f(x) = begin
                              x
                          end))
            #= none:16 =# @test occursin("f(x) = x", str)
            str = sprint_expr(:((x->begin
                              2x
                          end)))
            #= none:18 =# @test occursin("x -> 2 * x", str)
            #= none:19 =# @test sprint_expr(:(Type{T <: Real})) == "Type{T <: Real}"
        end
    print_expr(:(let x, y
              x + 1
              y + 1
          end))
    print_expr(:(if x > 0
              x + 1
          end))
    print_expr(quote
            x < 0
        end)
    print_expr(:(if x > 0
              x + 1
          elseif x > 1
              x + 2
          elseif x < 0
              x + 3
          else
              x + 4
          end))
    print_expr(:(function foo(x, y::T; z::Int = 1) where {N, T <: Real}
              x + 1
          end))
    ex = #= none:49 =# @expr(struct Foo <: Super
                x::Int
                Foo(x::Int) = begin
                        new(x)
                    end
                Foo(x::Int) = begin
                        new(x)
                    end
            end)
    print_expr(ex)
    ex = #= none:57 =# @expr(mutable struct Goo <: Super
                x::Int
                Foo(x::Int) = begin
                        new(x)
                    end
                Foo(x::Int) = begin
                        new(x)
                    end
            end)
    print_expr(ex)
    ex = :(function compare_expr(lhs, rhs)
              #= none:66 =# @switch (lhs, rhs) begin
                      #= none:67 =# @case (::Symbol, ::Symbol)
                      lhs === rhs
                      #= none:69 =# @case (Expr(:curly, name, lhs_vars...), Expr(:curly, &name, rhs_vars...))
                      all(map(compare_vars, lhs_vars, rhs_vars))
                      #= none:71 =# @case (Expr(:where, lbody, lparams...), Expr(:where, rbody, rparams...))
                      compare_expr(lbody, rbody) && all(map(compare_vars, lparams, rparams))
                      #= none:74 =# @case (Expr(head, largs...), Expr(&head, rargs...))
                      isempty(largs) && isempty(rargs) || length(largs) == length(rargs) && all(map(compare_expr, largs, rargs))
                      #= none:78 =# @case (::LineNumberNode, ::LineNumberNode)
                      true
                      #= none:80 =# @case _
                      lhs == rhs
                  end
          end)
    print_expr(ex)
    ex = :(try
              1 + 1
          catch e
              rethrow(ex)
          end)
    print_expr(ex)
    ex = :(try
              1 + 1
          finally
              rethrow(ex)
          end)
    print_expr(ex)
    ex = :(try
              1 + 1
          catch e
              rethrow(ex)
          finally
              1 + 2
          end)
    print_expr(ex)
    def = #= none:113 =# @expr(JLFunction, function foo(x, y)
                1 + 1
            end)
    print_expr(def)
    def = #= none:119 =# @expr(JLKwStruct, struct Moo
                x::Int = 1
            end)
    print_expr(def)
    ex = #= none:125 =# @expr(for i = 1:10, j = 1:10
                M[i, j] += 1
            end)
    print_expr(ex)
    ex = #= none:131 =# @expr(function foo(i, j)
                for i = 1:10
                    M[i, j] += 1
                end
            end)
    print_expr(ex)
    ex = quote
            #= none:139 =# Core.@doc "    foo(i, j)\n\ntest function. test function.\ntest function. test function.\n" function foo(i, j)
                    for i = 1:10
                        M[i, j] += 1
                    end
                end
        end
    print_expr(ex)
    ex = quote
            #= none:155 =# Core.@doc "    foo(i, j)\n\ntest function. test function.\ntest function. test function.\n" function foo(i, j)
                    function goo(x)
                        return x
                    end
                end
        end
    print_expr(ex)
    function broutine2x2_m_kernel_expr(idx_1, idx_2)
        return quote
                ST1 = U11 * st[b, $idx_1] + U12 * st[b, $idx_2]
                ST2 = U21 * st[b, $idx_1] + U22 * st[b, $idx_2]
                st[b, $idx_1] = ST1
                st[b, $idx_2] = ST2
            end
    end
    ex = quote
            #= none:181 =# Base.Cartesian.@nexprs 16 (k->begin
                        $(broutine2x2_m_kernel_expr(:(i + k), :(i + step_1 + k)))
                    end)
        end
    print_expr(ex)
    ex = quote
            try
                ex = include_string(mod, "quote $(code) end", path)
                mod.eval(mod.eval(ex))
                return nothing
            finally
                if prev === nothing
                    delete!(tls, :SOURCE_PATH)
                else
                    tls[:SOURCE_PATH] = prev
                end
            end
        end
    print_expr(ex)
