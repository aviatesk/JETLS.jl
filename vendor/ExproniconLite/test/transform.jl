
    using Test
    using ExproniconLite
    #= none:4 =# @testset "name_only" begin
            #= none:5 =# @test name_only(:(x::Int)) == :x
            #= none:6 =# @test name_only(:(T <: Int)) == :T
            #= none:7 =# @test name_only(:(Foo{T} where T)) == :Foo
            #= none:8 =# @test name_only(:(Foo{T})) == :Foo
            #= none:9 =# @test name_only(:(module Foo
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
                          end)) == :Foo
            #= none:10 =# @test name_only(:(x::Int...)) == :x
            #= none:11 =# @test name_only(:(x...)) == :x
            #= none:12 =# @test_throws ErrorException name_only(Expr(:fake))
        end
    #= none:15 =# @testset "rm_lineinfo" begin
            ex = quote
                    1 + 1
                    2 + 2
                end
            #= none:21 =# @test rm_lineinfo(ex) == Expr(:block, :(1 + 1), :(2 + 2))
            ex = quote
                    #= none:24 =# Base.@kwdef mutable struct D
                            field1::Union{ID, Missing, Nothing} = nothing
                        end
                    StructTypes.StructType(::Type{D}) = begin
                            StructTypes.Mutable()
                        end
                    StructTypes.omitempties(::Type{D}) = begin
                            true
                        end
                end
            #= none:35 =# @test ((rm_lineinfo(ex)).args[1]).args[end] == rm_lineinfo(:(mutable struct D
                              field1::Union{ID, Missing, Nothing} = nothing
                          end))
            #= none:38 =# @test (rm_lineinfo(ex)).args[2] == rm_lineinfo(:(StructTypes.StructType(::Type{D}) = begin
                                  StructTypes.Mutable()
                              end))
            #= none:41 =# @test (rm_lineinfo(ex)).args[3] == rm_lineinfo(:(StructTypes.omitempties(::Type{D}) = begin
                                  true
                              end))
        end
    #= none:46 =# @testset "flatten_blocks" begin
            ex = quote
                    1 + 1
                    begin
                        2 + 2
                    end
                end
            #= none:54 =# @test rm_lineinfo(flatten_blocks(ex)) == Expr(:block, :(1 + 1), :(2 + 2))
        end
    #= none:57 =# @testset "rm_annotations" begin
            ex = quote
                    x::Int
                    begin
                        y::Float64
                    end
                end
            #= none:65 =# @test rm_lineinfo(rm_annotations(ex)) == quote
                            x
                            begin
                                y
                            end
                        end |> rm_lineinfo
            ex = :(sin(::Float64; x::Int = 2))
            ex = rm_annotations(ex)
            #= none:74 =# @test ex.head === :call
            #= none:75 =# @test ex.args[1] === :sin
            #= none:76 =# @test (ex.args[2]).head === :parameters
            #= none:77 =# @test (ex.args[2]).args[1] === :x
            #= none:78 =# @test ex.args[3] isa Symbol
        end
    #= none:81 =# @testset "prettify" begin
            ex = quote
                    x::Int
                    begin
                        y::Float64
                    end
                end
            #= none:89 =# @test prettify(ex) == quote
                            x::Int
                            y::Float64
                        end |> rm_lineinfo
        end
    global_x = 2
    #= none:97 =# @testset "eval_interp" begin
            ex = Expr(:call, :+, Expr(:$, :global_x), 1)
            #= none:99 =# @test eval_interp(Main, ex) == :(2 + 1)
        end
    #= none:102 =# @testset "eval_literal" begin
            ex = :(for i = 1:10
                      1 + 1
                  end)
            #= none:106 =# @test rm_lineinfo(eval_literal(Main, ex)) == rm_lineinfo(:(for i = $(1:10)
                              2
                          end))
        end
    #= none:111 =# @testset "substitute" begin
            #= none:112 =# @test_expr substitute(:(x + 1), :x => :y) == :(y + 1)
            #= none:113 =# @test_expr substitute(:(for i = 1:10
                              x += i
                          end), :x => :y) == :(for i = 1:10
                          y += i
                      end)
        end
    #= none:116 =# @testset "expr_map" begin
            #= none:117 =# @test_expr expr_map(1:10, 2:11) do i, j
                        :(1 + $i + $j)
                    end == quote
                        1 + 1 + 2
                        1 + 2 + 3
                        1 + 3 + 4
                        1 + 4 + 5
                        1 + 5 + 6
                        1 + 6 + 7
                        1 + 7 + 8
                        1 + 8 + 9
                        1 + 9 + 10
                        1 + 10 + 11
                    end
        end
    #= none:133 =# @testset "nexprs" begin
            #= none:134 =# @test_expr nexprs(5) do k
                        :(1 + $k)
                    end == quote
                        1 + 1
                        1 + 2
                        1 + 3
                        1 + 4
                        1 + 5
                    end
        end
