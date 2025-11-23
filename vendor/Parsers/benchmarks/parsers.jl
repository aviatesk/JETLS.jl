using BenchmarkTools, Parsers, Dates

# tryparse
@benchmark Parsers.parse(Int64, "-86706967560385154")
@benchmark Parsers.tryparse(Int64, "-86706967560385154")

# xparse
@benchmark Parsers.xparse(Int64, "\"-86706967560385154\",", 1, 21)
@benchmark Parsers.xparse(Int64, "-86706967560385154", 1, 18, Parsers.XOPTIONS, Int64)

const ff = Parsers.Result(Parsers.emptysentinel(options)(Parsers.delimiter(options)(Parsers.whitespace(options)(
    Parsers.quoted(options)(Parsers.whitespace(options)(Parsers.sentinel(options)(Parsers.typeparser(options)
)))))))
const buf = Vector{UInt8}("\"-86706967560385154\",")
@benchmark ff(String, buf, 1, 21, Parsers.PosLen)

# String
@benchmark Parsers.xparse(String, "\"-86706967560385154\",", 1, 21)
@benchmark Parsers.xparse(String, "-86706967560385154", 1, 18, Parsers.XOPTIONS, Parsers.PosLen)

# Int
@benchmark Parsers.parse(Int64, "10")
@benchmark Base.parse(Int64, "10")
@benchmark Parsers.parse(Int64, "-86706967560385154")
@benchmark Base.parse(Int64, "-86706967560385154")

# Float64
@benchmark Parsers.parse(Float64, "10")
@benchmark Base.parse(Float64, "10")
@benchmark Parsers.parse(Float64, "-86706967560385154")
@benchmark Base.parse(Float64, "-86706967560385154")
@benchmark Parsers.parse(Float64, "NaN")
@benchmark Base.parse(Float64, "NaN")
@benchmark Parsers.parse(Float64, "0.0017138347201173243")
@benchmark Base.parse(Float64, "0.0017138347201173243")
@benchmark Parsers.parse(Float64, "2.2250738585072011e-308")
@benchmark Base.parse(Float64, "2.2250738585072011e-308")

# Date
#TODO
const ffff = Parsers.Result(Parsers.typeparser(Parsers.OPTIONS))
const src = Vector{UInt8}("2019-01-01")
@benchmark ffff(Date, src, 1, 10, Date)
@benchmark Parsers._xparse2(Date, src, 1, 10, Parsers.OPTIONS, Date)
@benchmark Parsers.parse(Date, "2019-01-01")
@benchmark Base.parse(Date, "2019-01-01")

@benchmark Parsers.parse(DateTime, "2019-01-01")
@benchmark Base.parse(DateTime, "2019-01-01")

@benchmark Parsers.parse(DateTime, "2019-01-01T01:02:03")
@benchmark Base.parse(DateTime, "2019-01-01T01:02:03")
