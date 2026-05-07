fizz() = print("fizz ")
buzz() = print("buzz ")

function fizzbuzz(n)
    for i in 1:n
        if i % 3 == 0 || i % 5 == 0
            i % 3 == 0 && fizz()
            i % 5 == 0 && buzz()
        else
            print(i, " ")
        end
    end
    return n
end

using JuliaInterpreter
@interpret fizzbuzz(4)
