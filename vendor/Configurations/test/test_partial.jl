module TestPartial
using Test
using Configurations

@option struct MyOption
    x::Int
    y::Int = x + 1
end

@test from_dict(MyOption, Dict("x"=>1)) == MyOption(1, 2)

end