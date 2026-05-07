module AutoMaybeDefault

using Test
using Configurations: Configurations, @option, Maybe, is_maybe_type_expr

@option struct AutoMaybeDefault1
    a::Maybe{Int} = 2
    b::Maybe{Int}
end

@option struct AutoMaybeDefault2
    a::Configurations.Maybe{Int} = 2
    b::Configurations.Maybe{Int}
end

@testset "auto maybe default" begin
    @test AutoMaybeDefault1() == AutoMaybeDefault1(2, nothing)
    @test AutoMaybeDefault2() == AutoMaybeDefault2(2, nothing)
end

module NoMaybe
using Test
using Configurations: Configurations, @option, is_maybe_type_expr
struct Maybe{T} end
end # NoMaybe

@testset "is_maybe_type_expr" begin
    @test is_maybe_type_expr(AutoMaybeDefault, Maybe)
    @test is_maybe_type_expr(AutoMaybeDefault, :Maybe)
    @test is_maybe_type_expr(AutoMaybeDefault, :(Maybe{Int}))
    @test is_maybe_type_expr(AutoMaybeDefault, :($Maybe{Int}))
    @test is_maybe_type_expr(AutoMaybeDefault, :($(Maybe{Int})))
    @test is_maybe_type_expr(AutoMaybeDefault, Maybe{Int})

    @test is_maybe_type_expr(AutoMaybeDefault, :(Configurations.Maybe))
    @test is_maybe_type_expr(AutoMaybeDefault, :(Configurations.Maybe{Int}))
    @test is_maybe_type_expr(AutoMaybeDefault, :(Configurations.$Maybe{Int}))
    @test is_maybe_type_expr(AutoMaybeDefault, :(Configurations.$(Maybe{Int})))

    @test is_maybe_type_expr(AutoMaybeDefault, :($Configurations.Maybe))
    @test is_maybe_type_expr(AutoMaybeDefault, :($Configurations.Maybe{Int}))
    @test is_maybe_type_expr(AutoMaybeDefault, :($Configurations.$Maybe{Int}))
    @test is_maybe_type_expr(AutoMaybeDefault, :($Configurations.$(Maybe{Int})))

    gref = GlobalRef(Configurations, :Maybe)
    @test is_maybe_type_expr(AutoMaybeDefault, gref)
    @test is_maybe_type_expr(AutoMaybeDefault, :($gref{Int}))

    @test !is_maybe_type_expr(NoMaybe, :(1 + 1))

    @test !is_maybe_type_expr(NoMaybe, NoMaybe.Maybe)
    @test !is_maybe_type_expr(NoMaybe, :Maybe)
    @test !is_maybe_type_expr(NoMaybe, :(Maybe{Int}))
    @test !is_maybe_type_expr(NoMaybe, :($Maybe{Int}))
    @test !is_maybe_type_expr(NoMaybe, :($(NoMaybe.Maybe{Int})))
    @test !is_maybe_type_expr(NoMaybe, NoMaybe.Maybe{Int})

    @test is_maybe_type_expr(NoMaybe, :(Configurations.Maybe))
    @test is_maybe_type_expr(NoMaybe, :(Configurations.Maybe{Int}))
    @test is_maybe_type_expr(NoMaybe, :(Configurations.$Maybe{Int}))
    @test is_maybe_type_expr(NoMaybe, :(Configurations.$(Maybe{Int})))

    @test is_maybe_type_expr(NoMaybe, :($Configurations.Maybe))
    @test is_maybe_type_expr(NoMaybe, :($Configurations.Maybe{Int}))
    @test is_maybe_type_expr(NoMaybe, :($Configurations.$Maybe{Int}))
    @test is_maybe_type_expr(NoMaybe, :($Configurations.$(Maybe{Int})))

    gref = GlobalRef(Configurations, :Maybe)
    @test is_maybe_type_expr(NoMaybe, gref)
    @test is_maybe_type_expr(NoMaybe, :($gref{Int}))
end

end
