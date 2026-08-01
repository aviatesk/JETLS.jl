@static if v"1.12.2" ≤ VERSION < v"1.13.0-"
    Base.include(Base.__toplevel__, "../snapshots/v1.12/src/Compiler.jl")
elseif v"1.13.0-" ≤ VERSION < v"1.14.0-"
    Base.include(Base.__toplevel__, "../snapshots/v1.13/src/Compiler.jl")
else
    error(
        "Unsupported Julia version $(VERSION); supported ranges: " *
        "[1.12.2, 1.13.0-), " *
        "[1.13.0-, 1.14.0-)",
    )
end
