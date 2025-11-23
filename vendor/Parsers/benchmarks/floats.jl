nums = rand(100000)


for i = 1:length(nums)
    r = rand(rng)
    nums[i] *= exp10(r)
end

open("testfloats", "w") do f
    for num in nums
        println(f, num)
    end
end

function strtod()
    for line in eachline("testfloats")
        parse(Float64, line)
    end
end

using Mmap
function xparse()
    io = IOBuffer(Mmap.mmap("testfloats"))
    for i = 1:100_000
        Main.Parsers.xparse(io, Float64)
        Main.Parsers.readbyte(io)
    end
end

function bench(n=100_000)
    open("results", "w") do f
        println(f, "exp,float,strtod,xparse")
        rng = -322:307
        for i = 1:n
            exp = rand(rng)
            r = string(exp10(exp) * round(rand(), digits=rand(1:9)))
            strtod = @elapsed begin
                a1 = parse(Float64, r)
            end
            io = IOBuffer(r)
            xparse = @elapsed begin
                a2 = Main.Parsers.xparse(io, Float64)
            end
            if a1 != a2.result
                @warn "a1: $a1, a2: $a2"
            end
            println(f, exp, ',', r, ',', strtod, ',', xparse)
        end
    end
end


function prof(str, n)
    io = IOBuffer(str)
    res = Parsers.Result(Float64)
    for i = 1:n
        seekstart(io)
        r = Parsers.defaultparser(io, res)
    end
end