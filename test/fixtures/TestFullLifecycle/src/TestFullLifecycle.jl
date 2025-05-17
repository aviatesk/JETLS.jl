module TestFullLifecycle

"""greetings"""
function hello(x)
    "hello, $x"
end

function targetfunc(x)
    #=cursor=#
end

sin(42) # TODO remove this line when the correct implementation of https://github.com/aviatesk/JET.jl/pull/707 is available

end # module TestFullLifecycle
