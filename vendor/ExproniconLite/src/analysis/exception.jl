
    struct SyntaxError <: Exception
        msg::AbstractString
        source::Union{Nothing, LineNumberNode}
    end
    SyntaxError(msg::AbstractString; source = nothing) = begin
            SyntaxError(msg, source)
        end
    function Base.showerror(io::IO, err::SyntaxError)
        print(io, "SyntaxError: ", err.msg, " at ", err.source)
    end
    struct AnalysisError <: Exception
        expect::String
        got
    end
    anlys_error(expect, got) = begin
            throw(AnalysisError(expect, got))
        end
    function Base.showerror(io::IO, e::AnalysisError)
        print(io, "expect ", e.expect, " expression, got ", e.got, ".")
    end
    struct ExprNotEqual <: Exception
        lhs
        rhs
    end
    function Base.showerror(io::IO, err::ExprNotEqual)
        printstyled(io, "expression not equal due to:"; color = :red)
        println(io)
        print(io, "  lhs: ")
        show(io, err.lhs)
        print(io)
        err.lhs isa EmptyLine || printstyled(io, "::", typeof(err.lhs); color = :light_black)
        println(io)
        print(io, "  rhs: ")
        show(io, err.rhs)
        printstyled(io, "::", typeof(err.rhs); color = :light_black)
        println(io)
    end
