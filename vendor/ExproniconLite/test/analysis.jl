
    using Test
    using ExproniconLite
    using ExproniconLite: assert_equal_expr, ExprNotEqual, empty_line, guess_module, is_valid_typevar
    #= none:6 =# @testset "is_function" begin
            #= none:7 =# @test is_function(:(foo(x) = begin
                              x
                          end))
            #= none:8 =# @test is_function(:((x->begin
                              2x
                          end)))
        end
    #= none:11 =# @testset "is_datatype_expr" begin
            #= none:12 =# @test is_datatype_expr(:name)
            #= none:13 =# @test is_datatype_expr(GlobalRef(Main, :name))
            #= none:14 =# @test is_datatype_expr(:(Main.Reflected.OptionA))
            #= none:15 =# @test is_datatype_expr(Expr(:curly, :(Main.Reflected.OptionC), :(Core.Int64)))
            #= none:16 =# @test is_datatype_expr(:(struct Foo
                          end)) == false
            #= none:17 =# @test is_datatype_expr(:(Foo{T} where T)) == false
        end
    #= none:20 =# @testset "uninferrable_typevars" begin
            def = #= none:21 =# @expr(JLKwStruct, struct Inferable1{T}
                        x::Constaint{T, (<)(2)}
                    end)
            #= none:25 =# @test uninferrable_typevars(def) == []
            def = #= none:27 =# @expr(JLKwStruct, struct Inferable2{T}
                        x::Constaint{Float64, (<)(2)}
                    end)
            #= none:31 =# @test uninferrable_typevars(def) == [:T]
            def = #= none:33 =# @expr(JLKwStruct, struct Inferable3{T, N}
                        x::Int
                        y::N
                    end)
            #= none:37 =# @test uninferrable_typevars(def) == [:T]
            def = #= none:40 =# @expr(JLKwStruct, struct Inferable4{T, N}
                        x::T
                        y::N
                    end)
            #= none:44 =# @test uninferrable_typevars(def) == []
            def = #= none:46 =# @expr(JLKwStruct, struct Inferable5{T, N}
                        x::T
                        y::Float64
                    end)
            #= none:51 =# @test uninferrable_typevars(def) == [:T, :N]
            #= none:52 =# @test uninferrable_typevars(def; leading_inferable = false) == [:N]
        end
    #= none:55 =# @testset "has_plain_constructor" begin
            def = #= none:56 =# @expr(JLKwStruct, struct Foo1{T, N}
                        x::Int
                        y::N
                        (Foo1{T, N}(x, y) where {T, N}) = begin
                                new{T, N}(x, y)
                            end
                    end)
            #= none:62 =# @test has_plain_constructor(def) == true
            def = #= none:64 =# @expr(JLKwStruct, struct Foo2{T, N}
                        x::T
                        y::N
                        Foo2(x, y) = begin
                                new{typeof(x), typeof(y)}(x, y)
                            end
                    end)
            #= none:70 =# @test has_plain_constructor(def) == false
            def = #= none:72 =# @expr(JLKwStruct, struct Foo3{T, N}
                        x::Int
                        y::N
                        (Foo3{T}(x, y) where T) = begin
                                new{T, typeof(y)}(x, y)
                            end
                    end)
            #= none:78 =# @test has_plain_constructor(def) == false
            def = #= none:80 =# @expr(JLKwStruct, struct Foo4{T, N}
                        x::T
                        y::N
                        (Foo4{T, N}(x::T, y::N) where {T, N}) = begin
                                new{T, N}(x, y)
                            end
                    end)
            #= none:86 =# @test has_plain_constructor(def) == false
        end
    #= none:89 =# @testset "is_kw_function" begin
            #= none:90 =# @test is_kw_function(:(function foo(x::Int; kw = 1)
                      end))
            ex = :(function (x::Int,; kw = 1)
                  end)
            #= none:96 =# @test is_kw_function(ex)
            #= none:97 =# @test !(is_kw_function(true))
            #= none:99 =# @test !(is_kw_function(:(function foo(x::Int)
                          end)))
            #= none:104 =# @test !(is_kw_function(:(function (x::Int,)
                          end)))
        end
    #= none:110 =# @testset "JLCall(ex)" begin
            def = #= none:111 =# @expr(JLCall, 1 + 1)
            #= none:112 =# @test_expr codegen_ast(def) == :(1 + 1)
        end
    #= none:115 =# @testset "JLFunction(ex)" begin
            jlfn = JLFunction()
            #= none:117 =# @test jlfn.name === nothing
            #= none:119 =# @test_expr JLFunction function foo(x::Int, y::Type{T}) where T <: Real
                    return x
                end
            def = #= none:123 =# @test_expr(JLFunction, function (x, y)
                        return 2
                    end)
            #= none:126 =# @test is_kw_function(def) == false
            def = #= none:128 =# @test_expr(JLFunction, function (x, y; kw = 2)
                        return "aaa"
                    end)
            #= none:131 =# @test is_kw_function(def) == true
            #= none:133 =# @test_expr JLFunction ((x, y)->begin
                        sin(x)
                    end)
            #= none:136 =# @test_expr JLFunction function (x::Int,; kw = 1)
                end
            ex = :(struct Foo
                  end)
            #= none:139 =# @test_throws SyntaxError JLFunction(ex)
            ex = :(#= none:140 =# @foo(2, 3))
            #= none:141 =# @test_throws SyntaxError split_function_head(ex)
            ex = :((foo(bar)->begin
                          bar
                      end))
            #= none:144 =# @test_throws SyntaxError JLFunction(ex)
            ex = :(Foo(; a = 1) = begin
                          new(a)
                      end)
            #= none:147 =# @test (JLFunction(ex)).kwargs[1] == Expr(:kw, :a, 1)
            #= none:149 =# @test_expr JLFunction function (f(x::T; a = 10)::Int) where T
                    return x
                end
            #= none:153 =# @test_expr JLFunction f(x::Int)::Int = begin
                        x
                    end
            ex = :((x->begin
                          x
                      end))
            #= none:156 =# @test (JLFunction(ex)).args == Any[:x]
            ex = :((x->begin
                          2x
                      end))
            #= none:159 =# @test (JLFunction(ex)).args == Any[:x]
            ex = :((x::Int->begin
                          2x
                      end))
            #= none:162 =# @test (JLFunction(ex)).args == Any[:(x::Int)]
            ex = :((::Int->begin
                          0
                      end))
            #= none:165 =# @test (JLFunction(ex)).args == Any[:(::Int)]
            ex = :(((x, y)::T->begin
                          x
                      end))
            jlf = JLFunction(ex)
            #= none:169 =# @test jlf.args == Any[:x, :y]
            #= none:170 =# @test jlf.rettype == :T
            ex = :((((x::T, y) where T)::T->begin
                          x
                      end))
            jlf = JLFunction(ex)
            #= none:174 =# @test jlf.whereparams == Any[:T]
            #= none:175 =# @test jlf.args == Any[:(x::T), :y]
            #= none:176 =# @test jlf.rettype == :T
            ex = quote
                    #= none:180 =# Core.@doc "foo $(bar)" f(x) = begin
                                x + 1
                            end
                end
            jlf = JLFunction(ex)
            #= none:185 =# @test jlf.doc == Expr(:string, "foo ", :bar)
        end
    #= none:188 =# @testset "JLStruct(ex)" begin
            #= none:189 =# @test (JLField(; name = :x)).name === :x
            #= none:190 =# @test (JLField(; name = :x)).type === Any
            #= none:191 =# @test (JLStruct(; name = :Foo)).name === :Foo
            ex = :(struct Foo
                      x::Int
                  end)
            jlstruct = JLStruct(ex)
            println(jlstruct)
            #= none:199 =# @test jlstruct.name === :Foo
            #= none:200 =# @test jlstruct.ismutable === false
            #= none:201 =# @test length(jlstruct.fields) == 1
            #= none:202 =# @test (jlstruct.fields[1]).name === :x
            #= none:203 =# @test (jlstruct.fields[1]).type === :Int
            #= none:204 =# @test (jlstruct.fields[1]).line isa LineNumberNode
            #= none:205 =# @test codegen_ast(jlstruct) == ex
            ex = :(mutable struct Foo{T, S <: Real} <: AbstractArray
                      a::Float64
                      function foo(x, y, z)
                          new(1)
                      end
                  end)
            jlstruct = JLStruct(ex)
            println(jlstruct)
            #= none:217 =# @test jlstruct.ismutable == true
            #= none:218 =# @test jlstruct.name === :Foo
            #= none:219 =# @test jlstruct.typevars == Any[:T, :(S <: Real)]
            #= none:220 =# @test jlstruct.supertype == :AbstractArray
            #= none:221 =# @test jlstruct.misc[1] == (ex.args[3]).args[end]
            #= none:222 =# @test rm_lineinfo(codegen_ast(jlstruct)) == rm_lineinfo(ex)
            ex = quote
                    #= none:225 =# Core.@doc "Foo\n" struct Foo
                            "xyz"
                            x::Int
                            y
                            Foo(x) = begin
                                    new(x)
                                end
                            1 + 1
                        end
                end
            ex = ex.args[2]
            jlstruct = JLStruct(ex)
            #= none:239 =# @test jlstruct.doc == "Foo\n"
            #= none:240 =# @test (jlstruct.fields[1]).doc == "xyz"
            #= none:241 =# @test (jlstruct.fields[2]).type === Any
            #= none:242 =# @test (jlstruct.constructors[1]).name === :Foo
            #= none:243 =# @test (jlstruct.constructors[1]).args[1] === :x
            #= none:244 =# @test jlstruct.misc[1] == :(1 + 1)
            ast = codegen_ast(jlstruct)
            #= none:246 =# @test ast.args[1] == GlobalRef(Core, Symbol("@doc"))
            #= none:247 =# @test ast.args[3] == "Foo\n"
            #= none:248 =# @test (ast.args[4]).head === :struct
            #= none:249 =# @test is_function(((ast.args[4]).args[end]).args[end - 1])
            println(jlstruct)
            #= none:252 =# @test_throws SyntaxError split_struct_name(:(function Foo end))
        end
    #= none:255 =# @testset "JLKwStruct" begin
            def = #= none:256 =# @expr(JLKwStruct, struct Trait
                    end)
            #= none:257 =# @test_expr codegen_ast_kwfn(def) == quote
                        nothing
                    end
            #= none:261 =# @test (JLKwField(; name = :x)).name === :x
            #= none:262 =# @test (JLKwField(; name = :x)).type === Any
            #= none:263 =# @test (JLKwStruct(; name = :Foo)).name === :Foo
            def = #= none:265 =# @expr(JLKwStruct, struct ConvertOption
                        include_defaults::Bool = false
                        exclude_nothing::Bool = false
                    end)
            #= none:270 =# @test_expr codegen_ast_kwfn(def, :create) == quote
                        function create(::Type{S}; include_defaults = false, exclude_nothing = false) where S <: ConvertOption
                            ConvertOption(include_defaults, exclude_nothing)
                        end
                        nothing
                    end
            def = #= none:277 =# @expr(JLKwStruct, struct Foo1{N, T}
                        x::T = 1
                    end)
            println(def)
            #= none:282 =# @test_expr codegen_ast_kwfn(def, :create) == quote
                        function create(::Type{S}; x = 1) where {N, T, S <: Foo1{N, T}}
                            Foo1{N, T}(x)
                        end
                        function create(::Type{S}; x = 1) where {N, S <: Foo1{N}}
                            Foo1{N}(x)
                        end
                    end
            #= none:291 =# @test_expr codegen_ast(def) == quote
                        struct Foo1{N, T}
                            x::T
                        end
                        function Foo1{N, T}(; x = 1) where {N, T}
                            Foo1{N, T}(x)
                        end
                        function Foo1{N}(; x = 1) where N
                            Foo1{N}(x)
                        end
                        nothing
                    end
            def = #= none:304 =# @expr(JLKwStruct, struct Foo2 <: AbstractFoo
                        x = 1
                        y::Int
                    end)
            #= none:309 =# @test_expr codegen_ast(def) == quote
                        struct Foo2 <: AbstractFoo
                            x
                            y::Int
                        end
                        function Foo2(; x = 1, y)
                            Foo2(x, y)
                        end
                        nothing
                    end
            ex = quote
                    #= none:321 =# Core.@doc "Foo\n" mutable struct Foo
                            "abc"
                            a::Int = 1
                            b
                            Foo(x) = begin
                                    new(x)
                                end
                            1 + 1
                        end
                end
            ex = ex.args[2]
            jlstruct = JLKwStruct(ex)
            #= none:335 =# @test jlstruct.doc == "Foo\n"
            #= none:336 =# @test (jlstruct.fields[1]).doc == "abc"
            #= none:337 =# @test (jlstruct.fields[2]).name === :b
            #= none:338 =# @test (jlstruct.constructors[1]).name === :Foo
            #= none:339 =# @test jlstruct.misc[1] == :(1 + 1)
            println(jlstruct)
            def = #= none:342 =# @expr(JLKwStruct, struct Foo3
                        a::Int = 1
                        Foo3(; a = 1) = begin
                                new(a)
                            end
                    end)
            #= none:347 =# @test_expr codegen_ast(def) == quote
                        struct Foo3
                            a::Int
                            Foo3(; a = 1) = begin
                                    new(a)
                                end
                        end
                        nothing
                    end
            def = #= none:355 =# @expr(JLKwStruct, struct Potts{Q}
                        L::Int
                        beta::Float64 = 1.0
                        neighbors::Neighbors = square_lattice_neighbors(L)
                    end)
            #= none:361 =# @test_expr codegen_ast_kwfn(def, :create) == quote
                        function create(::Type{S}; L, beta = 1.0, neighbors = square_lattice_neighbors(L)) where {Q, S <: Potts{Q}}
                            Potts{Q}(L, beta, neighbors)
                        end
                        nothing
                    end
            def = #= none:368 =# @expr(JLKwStruct, struct Flatten
                        x = 1
                        begin
                            y = 1
                        end
                    end)
            #= none:375 =# @test (def.fields[1]).name === :x
            #= none:376 =# @test (def.fields[2]).name === :y
        end
    #= none:379 =# @test sprint(showerror, AnalysisError("a", "b")) == "expect a expression, got b."
    #= none:381 =# @testset "JLIfElse" begin
            jl = JLIfElse()
            jl[:(foo(x))] = :(x = 1 + 1)
            jl[:(goo(x))] = :(y = 1 + 2)
            jl.otherwise = :(error("abc"))
            println(jl)
            ex = codegen_ast(jl)
            dst = JLIfElse(ex)
            #= none:390 =# @test_expr dst[:(foo(x))] == :(x = 1 + 1)
            #= none:391 =# @test_expr dst[:(goo(x))] == :(y = 1 + 2)
            #= none:392 =# @test_expr dst.otherwise == :(error("abc"))
        end
    #= none:395 =# @testset "JLFor" begin
            ex = :(for i = 1:10, j = 1:20, k = 1:10
                      1 + 1
                  end)
            jl = JLFor(ex)
            println(jl)
            #= none:402 =# @test codegen_ast(jl) == ex
            jl = JLFor(; vars = [:x], iterators = [:itr], kernel = :(x + 1))
            ex = codegen_ast(jl)
            #= none:406 =# @test ex.head === :for
            #= none:407 =# @test (ex.args[1]).args[1] == :(x = itr)
            #= none:408 =# @test ex.args[2] == :(x + 1)
            ex = :(for i = 1:10
                      1 + 1
                  end)
            jl = JLFor(ex)
            println(jl)
            #= none:415 =# @test jl.vars == [:i]
            #= none:416 =# @test jl.iterators == [:(1:10)]
        end
    #= none:419 =# @testset "is_matrix_expr" begin
            ex = #= none:420 =# @expr([1 2; 3 4])
            #= none:421 =# @test is_matrix_expr(ex) == true
            ex = #= none:422 =# @expr([1 2 3 4])
            #= none:423 =# @test is_matrix_expr(ex) == true
            ex = #= none:425 =# @expr(Float64[1 2; 3 4])
            #= none:426 =# @test is_matrix_expr(ex) == true
            ex = #= none:427 =# @expr([1 2 3 4])
            #= none:428 =# @test is_matrix_expr(ex) == true
            for ex = [#= none:432 =# @expr([1, 2, 3, 4]), #= none:433 =# @expr([1, 2, 3, 4]), #= none:434 =# @expr(Float64[1, 2, 3, 4])]
                #= none:436 =# @test is_matrix_expr(ex) == false
            end
            for ex = [#= none:440 =# @expr([1 2;;; 3 4;;; 4 5]), #= none:441 =# @expr(Float64[1 2;;; 3 4;;; 4 5])]
                #= none:443 =# @static if VERSION > v"1.7-"
                        #= none:444 =# @test is_matrix_expr(ex) == false
                    else
                        #= none:446 =# @test is_matrix_expr(ex) == true
                    end
            end
        end
    #= none:451 =# @testset "assert_equal_expr" begin
            lhs = quote
                    function foo(x)
                        x + 1
                    end
                end
            rhs = quote
                    function foo(x)
                        x + 1
                    end
                    nothing
                end
            #= none:465 =# @test_throws ExprNotEqual assert_equal_expr(Main, lhs, rhs)
            #= none:467 =# @test sprint(showerror, ExprNotEqual(Int64, :Int)) == "expression not equal due to:\n  lhs: Int64::DataType\n  rhs: :Int::Symbol\n"
            #= none:473 =# @test sprint(showerror, ExprNotEqual(empty_line, :Int)) == "expression not equal due to:\n  lhs: <empty line>\n  rhs: :Int::Symbol\n"
        end
    #= none:480 =# @testset "compare_expr" begin
            #= none:481 =# @test compare_expr(:(Vector{Int}), Vector{Int})
            #= none:482 =# @test compare_expr(:(Vector{Int}), :(Vector{$(nameof(Int))}))
            #= none:483 =# @test compare_expr(:(NotDefined{Int}), :(NotDefined{$(nameof(Int))}))
            #= none:484 =# @test compare_expr(:(NotDefined{Int, Float64}), :(NotDefined{$(nameof(Int)), Float64}))
            #= none:485 =# @test compare_expr(LineNumberNode(1, :foo), LineNumberNode(1, :foo))
        end
    #= none:488 =# @testset "guess_module" begin
            #= none:489 =# @test guess_module(Main, Base) === Base
            #= none:490 =# @test guess_module(Main, :Base) === Base
            #= none:491 =# @test guess_module(Main, :(1 + 1)) == :(1 + 1)
        end
    #= none:494 =# @testset "guess_type" begin
            #= none:495 =# @test guess_type(Main, Int) === Int
            #= none:496 =# @test guess_type(Main, :Int) === Int
            #= none:497 =# @test guess_type(Main, :Foo) === :Foo
            #= none:498 =# @test guess_type(Main, :(Array{Int, 1})) === Array{Int, 1}
            #= none:500 =# @test guess_type(Main, :(Array{<:Real, 1})) == :(Array{<:Real, 1})
        end
    #= none:503 =# @testset "split_signature" begin
            #= none:504 =# @test_expr split_signature(:(foo(x::Int, y::Float64))) == :(($Base).Tuple{($Base).typeof(foo), Int, Float64})
            #= none:505 =# @test_expr split_signature(:(foo(x::Int, y::Float64...))) == :(($Base).Tuple{($Base).typeof(foo), Int, ($Base).Vararg{Float64}})
            #= none:506 =# @test_expr split_signature(:(foo(x::Int, y...))) == :(($Base).Tuple{($Base).typeof(foo), Int, ($Base).Vararg{$Any}})
            #= none:507 =# @test_expr split_signature(:(foo(x::Int, y::T...) where T)) == :(($Base).Tuple{($Base).typeof(foo), Int, ($Base).Vararg{T}} where T)
            #= none:508 =# @test_expr split_signature(:(foo(x::Int, y::T = 2) where T)) == :(($Base).Tuple{($Base).typeof(foo), Int, T} where T)
        end
    #= none:511 =# @static if VERSION > v"1.8-"
            #= none:512 =# @testset "const <field> = <value>" begin
                    include("analysis/const.jl")
                end
        end
    #= none:517 =# @testset "check" begin
            include("analysis/check.jl")
        end
    #= none:521 =# @testset "compare" begin
            include("analysis/compare.jl")
        end
    #= none:525 =# @testset "generated" begin
            include("analysis/generated.jl")
        end
