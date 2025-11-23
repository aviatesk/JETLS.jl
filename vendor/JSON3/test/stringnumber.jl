using JSON3
using StructTypes
using Test

struct StringNumber
    value::String
end

@inline Base.getindex(x::StringNumber) = x.value::String

@inline StructTypes.StructType(::Type{StringNumber}) = JSON3.RawType()
@inline StructTypes.construct(::Type{StringNumber}, x::JSON3.RawValue) = StringNumber(unsafe_string(pointer(x.bytes, x.pos), x.len))
@inline JSON3.rawbytes(x::StringNumber) = codeunits(x.value)

@inline function test_roundtrip(json::String, object, ::Type{T}) where T
    # starting with object
    a = JSON3.write(object)
    @test typeof(a) === String
    b = JSON3.read(a, T)
    @test typeof(b) === typeof(object)
    c = JSON3.write(b)
    @test typeof(c) === String
    @test a === c

    # starting with json
    a = JSON3.read(json, T)
    @test typeof(a) == T
    @test typeof(a) == typeof(object)
    mutable_struct_equality(a, object)
    b = JSON3.write(a)
    @test typeof(b) === String
    @test b === json

    # @test false

    return nothing
end

@inline function mutable_struct_equality(a::T, b::T)::Bool where T
    if isstructtype(T) && ismutable(a)
        T_fieldnames = fieldnames(T)
        T_num_fieldnames = length(T_fieldnames)
        temp_vector = Vector{Bool}(undef, T_num_fieldnames)
        for i in 1:T_num_fieldnames
            name_i = T_fieldnames[i]
            temp_vector[i] = mutable_struct_equality(getfield(a, name_i), getfield(b, name_i))
        end
        return all(temp_vector)
    else
        return a == b
    end
end

mutable struct StringNumberTests_A{S}
    entries::Vector{S}
    StringNumberTests_A{S}()        where {S} = new{S}()
    StringNumberTests_A{S}(entries) where {S} = new{S}(entries)
end
mutable struct StringNumberTests_B{T}
    foo::T
    StringNumberTests_B{T}()    where {T} = new{T}()
    StringNumberTests_B{T}(foo) where {T} = new{T}(foo)
end
mutable struct StringNumberTests_C
    bar::StringNumber
    StringNumberTests_C() = new()
    StringNumberTests_C(bar) = new(bar)
end
StructTypes.StructType(::Type{<:StringNumberTests_A}) = StructTypes.Mutable()
StructTypes.StructType(::Type{<:StringNumberTests_B}) = StructTypes.Mutable()
StructTypes.StructType(::Type{<:StringNumberTests_C}) = StructTypes.Mutable()

@testset "JSON3.RawType: StringNumber" begin
    @testset "Basic tests" begin
        test_cases = ["1.2", "1.20", "1.200", "1.2000", "1.20000"]
        @testset "Reading" begin
            for a in test_cases
                b = JSON3.read(a, StringNumber)
                @test typeof(b) === StringNumber
                @test typeof(b[]) === String
                @test b[] === a
            end
        end
        @testset "Writing" begin
            for c in test_cases
                d = StringNumber(c)
                e = JSON3.write(d)
                @test typeof(e) === String
                @test e === c
            end
        end
        @testset "Roundtrip" begin
            for json in test_cases
                object = StringNumber(json)
                test_roundtrip(json, object, StringNumber)
            end
        end
    end
    @testset "More complex test" begin
        a = StringNumber("1.20")
        b = StringNumber("34.5600")
        c = StringNumberTests_C(a)
        d = StringNumberTests_C(b)
        e = StringNumberTests_B{StringNumberTests_C}(c)
        f = StringNumberTests_B{StringNumberTests_C}(d)
        g = [e, f]
        object = StringNumberTests_A{StringNumberTests_B{StringNumberTests_C}}(g)
        json = "{\"entries\":[{\"foo\":{\"bar\":1.20}},{\"foo\":{\"bar\":34.5600}}]}"
        T = StringNumberTests_A{StringNumberTests_B{StringNumberTests_C}}
        test_roundtrip(json, object, T)
    end
end
