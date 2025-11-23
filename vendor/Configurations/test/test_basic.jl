module Basic

using Configurations
using ExproniconLite
using Configurations:
    to_dict,
    from_kwargs,
    from_dict,
    from_toml,
    no_default,
    field_defaults,
    field_default,
    PartialDefault,
    field_keywords,
    has_duplicated_reflect_type
using OrderedCollections
using Test
using TOML

"Option A"
@option "option_a" struct OptionA
    name::String
    int::Int = 1
end

"Option B"
@option "option_b" struct OptionB
    opt::OptionA = OptionA(; name="Sam")
    float::Float64 = 0.3
end

@option struct OptionC
    num::Float64

    function OptionC(num::Float64)
        num > 0 || error("not positive")
        return new(num)
    end
end

@option struct OptionD
    opt::Union{OptionA,OptionB}
end

@option struct OptionE
    field::Union{Nothing,OptionA} = nothing
end

@option struct OptionF
    name::Union{Nothing,String} = nothing
    int::Int = 1
end

@option struct OptionG
    opt::OptionF = OptionF()
    name::String = "ABC"
end

dict1 = OrderedDict{String,Any}(
    "opt" => OrderedDict{String,Any}("name" => "Roger", "int" => 2), "float" => 0.33
)

dict2 = OrderedDict{String,Any}("float" => 0.33)

dict3 = OrderedDict{String,Any}(
    "opt" => OrderedDict{String,Any}("name" => "Roger", "int" => 2), "float" => 0.3
)

dict4 = OrderedDict{String,Any}(
    "opt" => OrderedDict{String,Any}("name" => "Roger", "int" => 2)
)

option = from_dict(OptionB, dict1)
option3 = from_dict(OptionB, dict3)

@static if VERSION < v"1.1"
    @test Configurations.fieldtypes(OptionA) == (String, Int)
end

@testset "printing" begin
    println(PartialDefault(x -> x + 1, [:x], :(x + 1)))
    showerror(stdout, InvalidKeyError(:name, [:a, :b, :c, :d]))
    showerror(stdout, InvalidKeyError(:name, [Symbol(:a, idx) for idx in 1:10]))
    showerror(stdout, DuplicatedFieldError(:name, OptionA))
    showerror(stdout, DuplicatedAliasError("alias"))
    showerror(stdout, FieldTypeConversionError(Float64, :field, String, OptionA))
end

@testset "options" begin
    @test option == OptionB(; opt=OptionA(; name="Roger", int=2), float=0.33)

    @test from_toml(OptionB, "option.toml") == option
    @test from_toml_if_exists(OptionB, "option.toml") == option
    @test from_toml_if_exists(
        OptionB, "not_exist.toml"; opt_name="Roger", opt_int=2, float=0.33
    ) == option
end

@testset "to_dict" begin
    @test_throws ErrorException to_dict("aaa")
    @test to_dict(option) == dict1
    @test to_dict(from_dict(OptionB, dict2); include_defaults=false) == dict2
    @test to_dict(from_dict(OptionB, dict3); include_defaults=true) == dict3
    @test to_dict(from_dict(OptionB, dict3); include_defaults=false) == dict4
    @test to_dict(OptionF(); include_defaults=true, exclude_nothing=true) ==
          OrderedDict{String,Any}("int" => 1)
    @test to_dict(OptionF(); include_defaults=true, exclude_nothing=false) ==
          OrderedDict{String,Any}("name" => nothing, "int" => 1)
end

@testset "to_toml" begin
    @test to_toml(option; include_defaults=false) ==
          "float = 0.33\n\n[opt]\nname = \"Roger\"\nint = 2\n"
    to_toml("test.toml", option; include_defaults=false)
    @test read("test.toml", String) == "float = 0.33\n\n[opt]\nname = \"Roger\"\nint = 2\n"
    @test to_toml(option3; include_defaults=false) == "[opt]\nname = \"Roger\"\nint = 2\n"
    @test to_toml(option3; include_defaults=true) ==
          "float = 0.3\n\n[opt]\nname = \"Roger\"\nint = 2\n"
end

@testset "default reflection" begin
    @test field_defaults(OptionA) == [no_default, 1]
    @test field_defaults(OptionB) == [OptionA("Sam", 1), 0.3]
    @test field_default(OptionA, :name) === no_default
    @test field_default(OptionA, :int) == 1
end

@testset "from_kwargs" begin
    @test Configurations.from_kwargs(OptionB; opt_name="Roger", opt_int=2, float=0.33) ==
          option

    @test Configurations.from_kwargs(OptionG; name="AAA", opt_name="Roger") ==
          OptionG(; opt=OptionF(; name="Roger"), name="AAA")

    d = Configurations.from_kwargs!(
        OrderedDict{String,Any}(), OptionG; name="AAA", opt_name="Roger"
    )
    @test d["name"] == "AAA"
    @test d["opt"]["name"] == "Roger"

    @testset "from_field_kwargs" begin
        # error for ambiguious keyword
        @test_throws DuplicatedFieldError Configurations.from_field_kwargs(
            OptionG; name="AAA"
        )

        @test Configurations.from_field_kwargs(OptionB; name="AAA") ==
              OptionB(; opt=OptionA(; name="AAA"))
    end
end

@testset "inside constructor" begin
    @test_throws ErrorException OptionC(-1.0)
end

@testset "test multi option type" begin
    d1 = OrderedDict{String,Any}("opt" => OrderedDict{String,Any}("option_b" => dict1))

    @test from_dict(OptionD, d1).opt isa OptionB

    d2 = OrderedDict{String,Any}(
        "opt" => OrderedDict{String,Any}(
            "option_a" => OrderedDict{String,Any}("name" => "Roger", "int" => 2)
        ),
    )

    @test from_dict(OptionD, d2).opt isa OptionA

    d3 = OrderedDict{String,Any}(
        "opt" =>
            OrderedDict{String,Any}(OrderedDict{String,Any}("name" => "Roger", "int" => 2)),
    )

    @test_throws ErrorException from_dict(OptionD, d3)
end

@testset "optional field" begin
    d = OrderedDict{String,Any}("float" => 0.33)

    @test from_dict(OptionB, d) == OptionB(; opt=OptionA(; name="Sam", int=1), float=0.33)

    @test from_kwargs(OptionE) == OptionE(; field=nothing)
end

@option struct VectorOfOptions
    options::Vector{OptionA}
end

@option struct VectorOfNumbers
    list::Vector{Int}
end

@option struct VectorOfUnions
    list::Vector{Union{OptionA,OptionB}}
end

@testset "vector of options" begin
    d = Dict{String,Any}(
        "options" => [
            Dict{String,Any}("name" => "a", "int" => 1),
            Dict{String,Any}("name" => "b", "int" => 2),
            Dict{String,Any}("name" => "c", "int" => 3),
        ],
    )

    option = from_dict(VectorOfOptions, d)
    @test option.options[1] == OptionA("a", 1)
    @test option.options[2] == OptionA("b", 2)
    @test option.options[3] == OptionA("c", 3)

    @test to_dict(option; include_defaults=false) == OrderedDict{String,Any}(
        "options" => OrderedDict{String,Any}[
            OrderedDict("name" => "a"),
            OrderedDict("name" => "b", "int" => 2),
            OrderedDict("name" => "c", "int" => 3),
        ],
    )

    to_dict(VectorOfNumbers([1, 2, 3]); include_defaults=false) ==
    OrderedDict{String,Any}("list" => [1, 2, 3])

    d = Dict{String,Any}(
        "list" => [
            Dict{String,Any}("option_a" => Dict{String,Any}("name" => "A", "int" => 1)),
            Dict{String,Any}("option_a" => Dict{String,Any}("name" => "B", "int" => 2)),
            Dict{String,Any}(
                "option_b" => Dict{String,Any}(
                    "opt" => Dict{String,Any}("name" => "Sam", "int" => 1),
                    "float" => 0.3,
                ),
            ),
        ],
    )

    @test from_dict(VectorOfUnions, d) == VectorOfUnions(
        Union{OptionA,OptionB}[
            OptionA("A", 1), OptionA("B", 2), OptionB(OptionA("Sam", 1), 0.3)
        ],
    )

    opt = VectorOfUnions([OptionA("A", 1), OptionA("B", 2), OptionB()])
    @test from_dict(VectorOfUnions, to_dict(opt)) == opt
end

@option struct LongValidateErrorHint
    x1
    x2
    x3
    x4
    x5
    x6
    x7
    x8
    x9
end

@testset "validate keys" begin
    @test_throws InvalidKeyError Configurations.validate_keywords(OptionA; abc=2)
    @test_throws InvalidKeyError Configurations.validate_keywords(
        LongValidateErrorHint; abc=2
    )
    @test Configurations.validate_keywords(OptionB; opt_name="AAA") === nothing
    @test_throws InvalidKeyError Configurations.validate_keywords(OptionB; opt_abc="AAA")
end

@testset "dict override" begin
    d = OrderedDict{String,Any}(
        "opt" => OrderedDict{String,Any}("name" => "Roger", "int" => 2), "float" => 0.33
    )

    @test from_dict(OptionB, d; opt_name="AAA") ==
          OptionB(; opt=OptionA(; name="AAA", int=2), float=0.33)
end

@option mutable struct Julia
    active::Union{String,Nothing} = nothing
    stable::Union{String,Nothing} = nothing
    # NOTE: we store nightly here too
    versions::Dict{VersionNumber,String} = Dict{VersionNumber,String}()
end

@option mutable struct Ion
    julia::Julia = Julia()
end

@option struct BuiltinVersionConvert
    version::VersionNumber
end

@testset "non-dict value conversion" begin
    d = Dict{String,Any}(
        "julia" => Dict{String,Any}(
            "active" => "some/path/to/active",
            "stable" => "1.5.3",
            "versions" => Dict{String,String}("1.5.3" => "some/path/to/1.5.3"),
        ),
    )

    # @test_throws MethodError from_dict(Ion, d)
    @test_throws FieldTypeConversionError from_dict(Ion, d)

    function Configurations.convert_to_option(
        ::Type{Julia}, ::Type{Dict{VersionNumber,String}}, x::Dict{String,String}
    )
        d = Dict{VersionNumber,String}()
        for (k, v) in x
            d[VersionNumber(k)] = v
        end
        return d
    end

    @test from_dict(Ion, d) == Ion(;
        julia=Julia(;
            active="some/path/to/active",
            stable="1.5.3",
            versions=Dict(v"1.5.3" => "some/path/to/1.5.3"),
        ),
    )

    @test from_kwargs(BuiltinVersionConvert; version="1.2.1").version == v"1.2.1"
end

@testset "to_dict nothing conversion" begin
    d = to_dict(Julia(); include_defaults=false)
    @test !haskey(d, "versions")
    @test !haskey(d, "active")
end

function foo(::Type{T}) where {T}
    return 1
end

function foo(::Type{Int})
    return 2.0
end

@option struct Inferrable{A,B}
    a::A
    b::B = 1.0
end

@option struct NotInferrable1{T}
    a::Float64
    b::Int
end

@option struct NotInferrable2{T}
    a::Float64 = foo(T)
    b::Int
end

@testset "parametric types" begin
    @test Inferrable(; a=1) == Inferrable(1, 1.0)
    # NOTE: we probably should just let this work
    # @test_throws ErrorException field_defaults(Inferrable)
    @test field_defaults(Inferrable{Float64,Float64}) == Any[no_default, 1.0]
    @test field_default(Inferrable{Float64,Float64}, :a) === no_default
    # @test_throws ErrorException field_default(Inferrable, :a) === no_default
    # @test_throws ErrorException field_default(Inferrable, :a)
    @test_throws MethodError NotInferrable1(; a=1.0, b=1)
    @test NotInferrable1{Int}(; a=1.0, b=1) == NotInferrable1{Int64}(1.0, 1)

    @test_throws MethodError NotInferrable2(; a=1.0, b=1)
    @test field_default(NotInferrable2{Int}, :a) == 2
    @test field_default(NotInferrable2{Float64}, :a) == 1.0
    @test NotInferrable2{Int}(; b=2) == NotInferrable2{Int}(2.0, 2)
    @test NotInferrable2{Float64}(; b=2) == NotInferrable2{Float64}(; b=2.0)
end

@option struct Empty end

@testset "emptry struct" begin
    @test_throws ErrorException field_default(Empty, :name)
end

@option struct CustomKwFn
    a::Float64

    CustomKwFn(a) = new(a)

    function CustomKwFn(; a=1.0, b=2.0)
        @test b == 2.0
        return new(a)
    end
end

@testset "custom kwfn" begin
    @test CustomKwFn() == CustomKwFn(1.0)
end

@option struct ExtraKwFn
    a::Int = 2

    ExtraKwFn(a) = new(a)

    function ExtraKwFn(; extra=true, kwargs...)
        @test extra
        return Configurations.create(ExtraKwFn; kwargs...)
    end
end

@testset "kwargs forward" begin
    @test ExtraKwFn(; a=3) == ExtraKwFn(3)
end

@option struct DefaultResolve
    a::Int = 1
    b::Float64 = sin(a)
end

@testset "default resolve" begin
    @test field_default(DefaultResolve, :b)(1) == sin(1)
end

@testset "non-option type handling" begin
    @test_throws ErrorException field_default(Int, :a)
    # @test_throws ErrorException field_alias(Int, :a)
    @test_throws ErrorException type_alias(Int)
end

@option struct UnionToDict
    option::Union{Nothing,OptionA,OptionB} = nothing
end

@option struct MultipleUnion
    data::Union{String,Int,Float64}
end

@testset "multi-union to_dict/from_dict" begin
    d = OrderedDict{String,Any}(
        "option" => OrderedDict{String,Any}("option_a" => to_dict(OptionA(; name="Name")))
    )

    @test from_dict(UnionToDict, d) == UnionToDict(; option=OptionA(; name="Name"))

    d = OrderedDict{String,Any}("option" => OrderedDict{String,Any}())

    @test from_dict(UnionToDict, d) == UnionToDict()

    x = UnionToDict(; option=OptionA(; name="Name"))
    d = to_dict(x)
    @test from_dict(UnionToDict, d) == x

    d = Dict("data" => 1.2)
    @test from_dict(MultipleUnion, d) == MultipleUnion(1.2)
end

@option struct MacroExpand
    x = 1
    @static if true
        y = 2
    end
end

@testset "macroexpand (#39)" begin
    @test fieldnames(MacroExpand) == (:x, :y)
end

@option "A" struct UnionConvertA
    a::Int
end

@option "B" struct UnionConvertB
    b::String
end

@option struct UnionConvertError
    b::String
end

@option mutable struct UnionNothing
    info::Maybe{UnionConvertA} = nothing
end

@option mutable struct UnionConvertAB
    info::Maybe{Union{UnionConvertA,UnionConvertB}} = nothing
end

@option mutable struct UnionConvertABError
    info::Maybe{Union{UnionConvertA,UnionConvertB,UnionConvertError}} = nothing
end

@testset "Dict convertion for Union{Nothing, OptionType}" begin
    @test to_dict(UnionNothing(); include_defaults=false) == OrderedDict{String,Any}()
    @test to_dict(UnionNothing(UnionConvertA(1))) ==
          OrderedDict{String,Any}("info" => OrderedDict{String,Any}("a" => 1))
    @test to_dict(UnionConvertAB(UnionConvertA(1))) == OrderedDict{String,Any}(
        "info" => OrderedDict{String,Any}("A" => OrderedDict{String,Any}("a" => 1))
    )
    @test to_dict(UnionConvertAB(UnionConvertB("a.b.c"))) == OrderedDict{String,Any}(
        "info" => OrderedDict{String,Any}("B" => OrderedDict{String,Any}("b" => "a.b.c"))
    )

    @test_throws ErrorException to_dict(UnionConvertABError(UnionConvertError("a.b.c")))
end

@option struct DefaultFunction
    a::Float64
    b::Float64 = sin(a)
end

@testset "partial default" begin
    x = DefaultFunction(; a=1.0, b=2.0)
    @test field_default(DefaultFunction, :b)(1.0) == sin(1.0)
end

@option struct CustomTypeConvert
    a::Int
    b::Symbol
end

@testset "custom/contextual type convert" begin
    d = Dict{String,Any}("a" => 1, "b" => "ccc")

    function Configurations.convert_to_option(::Type{CustomTypeConvert}, ::Type{Symbol}, s)
        return Symbol(s)
    end
    @test from_dict(CustomTypeConvert, d) == CustomTypeConvert(1, :ccc)
end

@option struct DuplicatedFieldA
    name::String
end

@option struct DuplicatedFieldB
    name::String
end

@option struct DuplicatedFields
    a::DuplicatedFieldA
    b::DuplicatedFieldB
end

@testset "duplicated field check" begin
    @test_throws Configurations.DuplicatedFieldError field_keywords(DuplicatedFields)
end

@test_throws ErrorException Configurations.create(Float64; name="abc")

@testset "compare options" begin
    @test Configurations.compare_options(1, 2.0) == false
    @test Configurations.compare_options(1, 1) == true

    @test Configurations.compare_options(
        from_dict(OptionB, dict1), from_dict(OptionB, dict1)
    ) == true

    @test Configurations.compare_options(
        from_dict(OptionB, dict1), from_dict(OptionB, dict3)
    ) == false

    @test Configurations.compare_options(
        from_dict(OptionB, dict1), from_dict(OptionB, dict1), from_dict(OptionB, dict1)
    ) == true

    @test Configurations.compare_options(
        from_dict(OptionB, dict1), from_dict(OptionB, dict3), from_dict(OptionB, dict1)
    ) == false

    @test Configurations.compare_options(
        from_dict(OptionB, dict1), from_dict(OptionB, dict1), from_dict(OptionB, dict3)
    ) == false
end

@option "duplicated" struct DuplicatedAliasA
    a::Int
end

@option "duplicated" struct DuplicatedAliasB
    a::Int
end

@option struct DuplicatedAlias
    option::Union{DuplicatedAliasA,DuplicatedAliasB}
end

@testset "duplicated alias check" begin
    d = Dict{String,Any}(
        "option" => Dict{String,Any}("duplicated" => Dict{String,Any}("a" => 1))
    )

    @test_throws DuplicatedAliasError from_dict(DuplicatedAlias, d)
end

end # Basic
