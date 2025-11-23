
    #= none:1 =# Base.@kwdef struct ColorScheme
            symbol::Int
            type::Int
            variable::Int
            quoted::Int
            keyword::Int
            number::Int
            string::Int
            comment::Int
            line::Int
            call::Int
            macrocall::Int
            op::Int
        end
    function Monokai256()
        return ColorScheme(; symbol = 141, type = 141, variable = 141, quoted = 141, keyword = 197, number = 141, string = 185, comment = 240, line = 240, call = 81, macrocall = 81, op = 197)
    end
