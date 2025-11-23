
    using ExproniconLite: @expr, Printer, InlinePrinter, print_inline, print_expr
    print_expr(quote
            1 + 2
            2 + x
        end)
    print_expr(:(quote
              1 + 2
              2 + x
          end))
    print_expr(:(:(quote
                1 + 2
                2 + x
            end)))
    print_expr(:(:(:(quote
                  1 + 2
                  2 + x
              end))))
    print_expr(quote
            1 + 2
            2 + x
        end; always_begin_end = true)
    ex = quote
            quote
                quote
                    1 + 2
                    2 + x
                end
            end
        end
    print_expr(ex; always_begin_end = true)
    ex = quote
            quote
                quote
                    1 + 2
                    2 + x
                end
            end
            begin
                quote
                    1 + 2
                    2 + x
                end
            end
        end
    print_expr(ex)
    print_expr(ex; always_begin_end = true)
    ex = :(let x = 1, y
              x + 1
          end)
    print_expr(ex)
    print_expr(ex; always_begin_end = true)
    ex = #= none:44 =# @expr(if a == 1
                1 + 1
                2 + 2
            elseif a == 2
                3 + 3
                4 + 4
            elseif a == 3
                5 + 5
            else
                5 + 5
                6 + 6
            end)
    print_expr(ex)
    ex = #= none:59 =# @expr(if a == 1
                1 + 1
                2 + 2
            else
                5 + 5
                6 + 6
            end)
    print_expr(ex)
    ex = #= none:69 =# @expr(if a == 1
                1 + 1
                2 + 2
            end)
    print_expr(ex)
    ex = #= none:76 =# @expr(if a == 1
                if a == 1
                    1 + 1
                    2 + 2
                else
                    1 + 1
                end
            else
                5 + 5
                6 + 6
            end)
    print_expr(ex)
    ex = Expr(:if, :(a == 1), :(1 + 1), :(5 + 5))
    print_expr(ex)
    ex = Expr(:if, :(a == 1), :(1 + 1), Expr(:elseif, :(a == 2), :(3 + 3), Expr(:elseif, :(a == 3), :(5 + 5), :(7 + 7))))
    print_expr(ex)
    ex = Expr(:if, :(a == 1), :(1 + 1), Expr(:elseif, :(a == 2), :(3 + 3), Expr(:elseif, :(a == 3), :(5 + 5))))
    print_expr(ex)
    ex = #= none:100 =# @expr(for i = 1:10
                1 + i
            end)
    print_expr(ex)
    print_expr(ex; line = true)
    ex = #= none:107 =# @expr(for (i, j) = zip(1:10, 1:5)
                1 + i
            end)
    print_expr(ex; line = true)
    ex = #= none:113 =# @expr(while a < 10
                1 + a
            end)
    print_expr(ex)
    print_expr(ex; line = true)
    ex = #= none:120 =# @expr(function foo(a, b; c)
                1 + 1
            end)
    print_expr(ex)
    print_expr(ex; line = true)
    ex = Expr(:function, :(foo(a, b; c)), :(1 + 1))
    print_expr(ex)
    print_expr(ex; line = true)
    ex = #= none:130 =# @expr(foo(a, b; c) = begin
                    1 + 1
                end)
    print_expr(ex)
    ex = #= none:133 =# @expr(macro foo(x, y::Int)
                1 + 1
            end)
    print_expr(ex)
    ex = #= none:139 =# @expr(#= none:139 =# @expr(begin
                    1 + 1
                end, begin
                    1 + 1
                end))
    print_expr(ex)
    ex = #= none:147 =# @expr(#= none:147 =# @__MODULE__())
    print_expr(ex)
    ex = #= none:150 =# @expr(begin
                quote
                    #= none:152 =# Core.@doc "aaaa\n" sin(x) = begin
                                x
                            end
                end
            end)
    print_expr(ex)
    ex = #= none:161 =# @expr(begin
                quote
                    #= none:163 =# Core.@doc "aaaa $(aaa)\n" sin(x) = begin
                                x
                            end
                end
            end)
    print_expr(ex)
    ex = #= none:172 =# @expr(#= none:172 =# @__MODULE__())
    print_expr(ex)
    print_expr(ex; line = true)
    ex = #= none:176 =# @expr(struct Foo{T} <: Goo
                a
                b::Int
                c::T
                Foo(x) = begin
                        new(x)
                    end
                Foo(x, y) = begin
                        if x + 1 == y
                            new(x, y)
                        else
                            new(x, y, 1)
                        end
                    end
            end)
    print_expr(ex)
    print_expr(ex)
    ex = #= none:192 =# @expr(foo(x, y) = begin
                    x + y
                end)
    print_expr(ex)
    ex = #= none:195 =# @expr(try
                1 + 1
            catch
                2 + 2
            end)
    print_expr(ex)
    ex = #= none:203 =# @expr(try
                1 + 1
            catch e
                2 + 2
            end)
    print_expr(ex)
    ex = #= none:211 =# @expr(try
                1 + 1
            finally
                2 + 2
            end)
    print_expr(ex)
    ex = #= none:219 =# @expr(try
                1 + 1
            catch e
                2 + 2
            finally
                2 + 2
            end)
    print_expr(ex)
    ex = #= none:229 =# @expr(module ABC
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
            1 + 1
            2 + 2
            end)
    print_expr(ex)
    ex = #= none:236 =# @expr(const X = if a == 1
                        1 + 1
                        2 + 2
                    else
                        3 + 3
                        4 + 4
                    end)
    print_expr(ex)
    ex = #= none:247 =# @expr(if x > 100
                x + 1
            elseif x > 90
                x + 2
            elseif x > 80
                x + 3
            else
                error("some error msg")
            end)
    print_expr(ex)
    print_expr(:(foo() do 
          end))
    print_expr(:(foo() do x
          end))
    print_expr(:(foo() do x, y, z
          end))
    print_expr(:(foo() do x, y, z
              1 + 1
              2 + 2
          end))
    print_expr(:(foo() do x, y, z...
              1 + 1
              2 + 2
          end))
    ex = #= none:265 =# @expr(function (p::InlinePrinter)(x, xs...; delim = ", ")
                p(x)
                for x = xs
                    printstyled(p.io, delim; color = p.color.keyword)
                    p(x)
                end
            end)
    print_expr(ex)
    ex = #= none:275 =# @expr(function InlinePrinter(io::IO; color::ColorScheme = Monokai256(), line::Bool = false)
                InlinePrinter(io, color, line, InlinePrinterState())
            end)
    print_expr(ex)
    print_expr(:(#= none:281 =# @foo("aaaaa", a, b, c)))
    print_expr(:(#= none:282 =# @foo("aaaaa\naaaaa", a, b, c)))
    ex = quote
            function foo()
                msg = :("expect $($nargs) arguments, got $(length(args)) arguments")
            end
        end
    print_expr(ex)
    ex = quote
            function foo()
                msg = :("expect $($nargs) arguments\n, got $(length(args)) arguments")
            end
        end
    print_expr(ex)
    ex = quote
            function split_lines(ex)::Vector{Any}
                ex isa AbstractString && return Any[[line] for line = eachsplit(ex, '\n')]
            end
        end
    print_expr(ex)
