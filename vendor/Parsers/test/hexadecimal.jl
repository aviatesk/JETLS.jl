using Test
using UUIDs
using Parsers


@testset "Hexadecimal" begin
    _OPTIONS = Parsers.Options(delim=',', quoted=true)

    swapchar(s, i, c) = s[1:i-1] * c * s[i+1:end]

    @testset "UUID" begin
        us = "01234567-abcd-ef01-2345-6789ABCDEF01"
        u = UUID(us)
        for i in 1:35
            res = Parsers.xparse(UUID, us, 1, i, _OPTIONS)
            @test Parsers.invalid(res.code)

            res = Parsers.xparse(UUID, IOBuffer(us), 1, i, _OPTIONS)
            @test Parsers.invalid(res.code)

            res = Parsers.xparse(UUID, view(us, 1:i), 1, i, _OPTIONS)
            @test Parsers.invalid(res.code)

            res = Parsers.xparse(UUID, IOBuffer(view(us, 1:i)), 1, i, _OPTIONS)
            @test Parsers.invalid(res.code)
        end
        res = Parsers.xparse(UUID, us, 1, 36, _OPTIONS)
        @test Parsers.ok(res.code)
        @test res.val == u

        res = Parsers.xparse(UUID, IOBuffer(us), 1, 36, _OPTIONS)
        @test Parsers.ok(res.code)
        @test res.val == u

        for i in 1:36
            bad_input = swapchar(us, i, 'g')
            res = Parsers.xparse(UUID, bad_input, 1, 36, _OPTIONS)
            @test Parsers.invalid(res.code)
            res = Parsers.xparse(UUID, IOBuffer(bad_input), 1, 36, _OPTIONS)
            @test Parsers.invalid(res.code)
        end

        res = Parsers.xparse(UUID, us * "1", 1, 37, _OPTIONS)
        @test Parsers.invalid(res.code)
        res = Parsers.xparse(UUID, IOBuffer(us * "1"), 1, 37, _OPTIONS)
        @test Parsers.invalid(res.code)
    end

    @testset "SHA1" begin
        ss = "0123456789abcdef0123456789ABCDEF01234567"
        s = Parsers.SHA1((0x01234567, 0x89abcdef, 0x01234567, 0x89abcdef, 0x01234567))

        @test string(s) == lowercase(ss)

        for i in 1:39
            res = Parsers.xparse(Parsers.SHA1, ss, 1, i, _OPTIONS)
            @test Parsers.invalid(res.code)

            res = Parsers.xparse(Parsers.SHA1, IOBuffer(ss), 1, i, _OPTIONS)
            @test Parsers.invalid(res.code)

            res = Parsers.xparse(Parsers.SHA1, view(ss, 1:i), 1, i, _OPTIONS)
            @test Parsers.invalid(res.code)

            res = Parsers.xparse(Parsers.SHA1, IOBuffer(view(ss, 1:i)), 1, i, _OPTIONS)
            @test Parsers.invalid(res.code)
        end
        res = Parsers.xparse(Parsers.SHA1, ss, 1, 40, _OPTIONS)
        @test Parsers.ok(res.code)
        @test res.val == s

        res = Parsers.xparse(Parsers.SHA1, IOBuffer(ss), 1, 40, _OPTIONS)
        @test Parsers.ok(res.code)
        @test res.val == s

        for i in 1:40
            bad_input = swapchar(ss, i, 'g')
            res = Parsers.xparse(Parsers.SHA1, bad_input, 1, 40, _OPTIONS)
            @test Parsers.invalid(res.code)

            res = Parsers.xparse(Parsers.SHA1, IOBuffer(bad_input), 1, 40, _OPTIONS)
            @test Parsers.invalid(res.code)
        end

        res = Parsers.xparse(Parsers.SHA1, ss * "1", 1, 41, _OPTIONS)
        @test Parsers.invalid(res.code)
        res = Parsers.xparse(Parsers.SHA1, IOBuffer(ss * "1"), 1, 41, _OPTIONS)
        @test Parsers.invalid(res.code)
    end
end
