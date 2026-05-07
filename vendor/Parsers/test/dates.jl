using Dates

@testset "Date.TimeTypes" begin

res = Parsers.xparse(Date, "")
x, code = res.val, res.code
@test code == INVALID | EOF
res = Parsers.xparse(Date, "2018-01-01")
x, code = res.val, res.code
@test x === Date(2018, 1, 01)
@test code == OK | EOF
res = Parsers.xparse(DateTime, "2018-01-01")
x, code = res.val, res.code
@test x === DateTime(2018, 1, 01)
@test code == OK | EOF
res = Parsers.xparse(Time, "01:02:03")
x, code = res.val, res.code
@test x === Time(1, 2, 3)
@test code == OK | EOF

res = Parsers.xparse(Time, codeunits("01:02:03"), 1, 8, Parsers.XOPTIONS)
x, code = res.val, res.code
@test x === Time(1, 2, 3)
@test code == OK | EOF

res = Parsers.xparse(Date, "")
x, code = res.val, res.code
@test code == INVALID | EOF
res = Parsers.xparse(Date, "\"\"")
x, code = res.val, res.code
@test code == QUOTED | INVALID | EOF
res = Parsers.xparse(Date, "2018-01-01")
x, code = res.val, res.code
@test x === Date(2018, 1, 01)
@test code == OK | EOF
res = Parsers.xparse(Date, "\"2018-01-01\"")
x, code = res.val, res.code
@test x === Date(2018, 1, 01)
@test code == QUOTED | OK | EOF
res = Parsers.xparse(DateTime, "\"2018-01-01")
x, code = res.val, res.code
@test code == OK | QUOTED | EOF | INVALID_QUOTED_FIELD
res = Parsers.xparse(Date, "\"abcd\"")
x, code = res.val, res.code
@test code == QUOTED | INVALID | EOF

res = Parsers.xparse(Date, "NA", sentinel=["NA"])
x, code = res.val, res.code
@test code === SENTINEL | EOF
res = Parsers.xparse(Date, "\\N", sentinel=["\\N"])
x, code = res.val, res.code
@test code === SENTINEL | EOF
res = Parsers.xparse(Date, "NA2", sentinel=["NA"])
x, code = res.val, res.code
@test code === SENTINEL | INVALID_DELIMITER | EOF
res = Parsers.xparse(Date, "-", sentinel=["-"])
x, code = res.val, res.code
@test code === SENTINEL | EOF
res = Parsers.xparse(Date, "£", sentinel=["£"])
x, code = res.val, res.code
@test code === SENTINEL | EOF
res = Parsers.xparse(Date, "null")
x, code = res.val, res.code
@test code === INVALID_DELIMITER | EOF
res = Parsers.xparse(Date, ",")
x, code = res.val, res.code
@test code === INVALID | DELIMITED
res = Parsers.xparse(Date, "1,")
x, code = res.val, res.code
@test x === Date(1)
@test code === OK | DELIMITED

res = Parsers.xparse(Date, "\"\""; sentinel=missing)
@test Parsers.sentinel(res.code)
res = Parsers.xparse(Date, "\"\","; sentinel=missing)
@test Parsers.sentinel(res.code)
res = Parsers.xparse(Date, "abc,"; sentinel=missing)
@test !Parsers.sentinel(res.code)

@test Parsers.parse(DateTime, "1996/Feb/15", Parsers.Options(dateformat="yy/uuu/dd")) === DateTime(1996, 2, 15)
@test Parsers.parse(DateTime, "1996, Jan, 15", Parsers.Options(dateformat="yyyy, uuu, dd")) === DateTime(1996, 1, 15)

@test_throws Parsers.Error Parsers.parse(Date, "2020-05-32")
@test_throws Parsers.Error Parsers.parse(DateTime, "2020-05-32")
@test_throws Parsers.Error Parsers.parse(Time, "25:00:00")
@test_throws Parsers.Error Parsers.parse(DateTime, "2020-05-05T00:00:60")

end

@testset "Date.TimeTypes IO" begin

    res = Parsers.xparse(Date, IOBuffer(""))
    x, code = res.val, res.code

    @test code == INVALID | EOF
    res = Parsers.xparse(Date, IOBuffer("2018-01-01"))
    x, code = res.val, res.code
    @test x === Date(2018, 1, 01)
    @test code == OK | EOF
    res = Parsers.xparse(DateTime, IOBuffer("2018-01-01"))
    x, code = res.val, res.code
    @test x === DateTime(2018, 1, 01)
    @test code == OK | EOF
    res = Parsers.xparse(Time, IOBuffer("01:02:03"))
    x, code = res.val, res.code
    @test x === Time(1, 2, 3)
    @test code == OK | EOF

    res = Parsers.xparse(Date, IOBuffer("\"\""))
    x, code = res.val, res.code

    @test code == QUOTED | INVALID | EOF
    res = Parsers.xparse(Date, IOBuffer("\"2018-01-01\""))
    x, code = res.val, res.code
    @test x === Date(2018, 1, 01)
    @test code == QUOTED | OK | EOF
    res = Parsers.xparse(DateTime, IOBuffer("\"2018-01-01"))
    x, code = res.val, res.code
    @test code == OK | QUOTED | EOF | INVALID_QUOTED_FIELD
    res = Parsers.xparse(Date, IOBuffer("\"abcd\""))
    x, code = res.val, res.code

    @test code == QUOTED | INVALID | EOF

    res = Parsers.xparse(Date, IOBuffer("NA"), sentinel=["NA"])
    x, code = res.val, res.code

    @test code === SENTINEL | EOF
    res = Parsers.xparse(Date, IOBuffer("\\N"), sentinel=["\\N"])
    x, code = res.val, res.code

    @test code === SENTINEL | EOF
    res = Parsers.xparse(Date, IOBuffer("NA2"), sentinel=["NA"])
    x, code = res.val, res.code

    @test code === SENTINEL | INVALID_DELIMITER | EOF
    res = Parsers.xparse(Date, IOBuffer("-"), sentinel=["-"])
    x, code = res.val, res.code

    @test code === SENTINEL | EOF
    res = Parsers.xparse(Date, IOBuffer("£"), sentinel=["£"])
    x, code = res.val, res.code

    @test code === SENTINEL | EOF
    res = Parsers.xparse(Date, IOBuffer("null"))
    x, code = res.val, res.code

    @test code === INVALID_DELIMITER | EOF
    res = Parsers.xparse(Date, IOBuffer(","))
    x, code = res.val, res.code

    @test code === INVALID | DELIMITED
    res = Parsers.xparse(Date, IOBuffer("1,"))
    x, code = res.val, res.code
    @test x === Date(1)
    @test code === OK | DELIMITED

    @test Parsers.parse(DateTime, IOBuffer("1996/Feb/15"), Parsers.Options(dateformat="yy/uuu/dd")) === DateTime(1996, 2, 15)
    @test Parsers.parse(DateTime, IOBuffer("1996, Jan, 15"), Parsers.Options(dateformat="yyyy, uuu, dd")) === DateTime(1996, 1, 15)

    @test_throws Parsers.Error Parsers.parse(Date, IOBuffer("2020-05-32"))
    @test_throws Parsers.Error Parsers.parse(DateTime, IOBuffer("2020-05-32"))
    @test_throws Parsers.Error Parsers.parse(Time, IOBuffer("25:00:00"))
    @test_throws Parsers.Error Parsers.parse(DateTime, IOBuffer("2020-05-05T00:00:60"))

end

@test_throws Parsers.Error Parsers.parse(DateTime, "a02/15/1996 25:00", Parsers.Options(dateformat=Parsers.Format("mm/dd/yyyy HH:MM")))
@test_throws Parsers.Error Parsers.parse(DateTime, "02/15/1996 25:00", Parsers.Options(dateformat=Parsers.Format("mm/dd/yyyy HH:MM")))
@test_throws Parsers.Error Parsers.parse(DateTime, "1996-Jan-15", Parsers.Options(dateformat="yy-mm-dd"))
@test_throws Parsers.Error Parsers.parse(DateTime, "96/2/15", Parsers.Options(dateformat="yy/uuu/dd"))
@test_throws Parsers.Error Parsers.parse(DateTime, "2017-Mar-17 00:00:00.1234", Parsers.Options(dateformat="y-u-d H:M:S.s"))
@test_throws Parsers.Error Parsers.parse(DateTime, "96/2/15", Parsers.Options(dateformat="yy𒀱uuu/dd"))

@test_throws Parsers.Error Parsers.parse(Time, "24:00")  # invalid hours
@test_throws Parsers.Error Parsers.parse(Time, "00:60")  # invalid minutes
@test_throws Parsers.Error Parsers.parse(Time, "00:00:60")  # invalid seconds
@test_throws Parsers.Error Parsers.parse(Time, "20:03:20", Parsers.Options(dateformat="HH:MM"))  # too much precision
@test_throws Parsers.Error Parsers.parse(Time, "10:33:51", Parsers.Options(dateformat="yyyy-mm-dd HH:MM:SS"))  # Time can't hold year/month/day
@test Parsers.parse(Time, "2021-06-26 10:33:51", Parsers.Options(dateformat="yyyy-mm-dd HH:MM:SS")) == Time(10, 33, 51)

Dates.LOCALES["french"] = Dates.DateLocale(
    ["janvier", "février", "mars", "avril", "mai", "juin",
        "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
    ["janv", "févr", "mars", "avril", "mai", "juin",
        "juil", "août", "sept", "oct", "nov", "déc"],
    ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"],
    [""],
)

Dates.LOCALES["gobblygook"] = Dates.DateLocale(
    ["𒀱"],
    ["𒀱"],
    [""],
    [""],
)

testcases = [
    ("yy-mm-dd", "96-01-15", Dates.DateTime(96, 1, 15)),
    ("yy-mm-dd", "96-1-15", Dates.DateTime(96, 1, 15)),
    ("yy-mm-dd", "96-1-1", Dates.DateTime(96, 1, 1)),
    ("yy-mm-dd", "1996-1-15", Dates.DateTime(1996, 1, 15)),
    ("yy/uuu/dd", "96/Feb/15", Dates.DateTime(96, 2, 15)),
    ("yy/uuu/dd", "1996/Feb/15", Dates.DateTime(1996, 2, 15)),
    ("yy/uuu/dd", "96/Feb/1", Dates.DateTime(96, 2, 1)),

    ("yyyy, uuu, dd", "1996, Jan, 15", Dates.DateTime(1996, 1, 15)),
    ("yyyy.U.dd", "1996.February.15", Dates.DateTime(1996, 2, 15)),
    ("yyyymmdd", "19960315", Dates.DateTime(1996, 3, 15)),
    ("yyyy-mm-dd HH:MM:SS", "1996-12-15 10:00:00", Dates.DateTime(1996, 12, 15, 10)),
    ("ymd", "999", Dates.DateTime(9, 9, 9)),
    ("/yyyy/m/d", "/1996/5/15", Dates.DateTime(1996, 5, 15)),
    ("yyyy年mm月dd日", "2009年12月01日", Dates.DateTime(2009, 12, 1)),
    ("yyyy𒀱mm𒀱dd", "2021𒀱6𒀱28", Dates.Date(2021, 6, 28)),

    (Parsers.Format("dd uuuuu YYYY", "french"), "28 mai 2014", Dates.DateTime(2014, 5, 28)),
    (Parsers.Format("dd uuuuu yyyy", "french"), "28 févr 2014", Dates.DateTime(2014, 2, 28)),
    (Parsers.Format("dd uuuuu yyyy", "french"), "28 août 2014", Dates.DateTime(2014, 8, 28)),
    (Parsers.Format("dd u yyyy", "french"), "28 avril 2014", Dates.DateTime(2014, 4, 28)),
    (Parsers.Format("dduuuuyyyy", "french"), "28mai2014", Dates.DateTime(2014, 5, 28)),
    (Parsers.Format("dduuuuyyyy", "french"), "28août2014", Dates.DateTime(2014, 8, 28)),
    (Parsers.Format("dd uuuuu YYYY", "gobblygook"), "28 𒀱 2014", Dates.DateTime(2014, 1, 28)),

    ("[HH:MM:SS.sss]", "[14:51:00.118]", Dates.DateTime(1, 1, 1, 14, 51, 0, 118)),
    ("HH:MM:SS.sss", "14:51:00.118", Dates.DateTime(1, 1, 1, 14, 51, 0, 118)),
    ("[HH:MM:SS.sss?", "[14:51:00.118?", Dates.DateTime(1, 1, 1, 14, 51, 0, 118)),
    ("?HH:MM:SS.sss?", "?14:51:00.118?", Dates.DateTime(1, 1, 1, 14, 51, 0, 118)),
    ("xHH:MM:SS.sss]", "x14:51:00.118]", Dates.DateTime(1, 1, 1, 14, 51, 0, 118)),
    ("HH:MM:SS.sss]", "14:51:00.118]", Dates.DateTime(1, 1, 1, 14, 51, 0, 118)),

    (Dates.RFC1123Format, "Sat, 23 Aug 2014 17:22:15", Dates.DateTime(2014, 8, 23, 17, 22, 15)),
    ("E, dd u yyyy HH:MM:SS", "Saturday, 23 Aug 2014 17:22:15", Dates.DateTime(2014, 8, 23, 17, 22, 15)),
    # milliseconds
    ("y-u-d H:M:S.s", "2017-Mar-17 00:00:00.0000", Dates.DateTime(2017, 3, 17, 0, 0, 0, 0)),
    ("y-u-d H:M:S.s", "2017-Mar-17 00:00:00.1", Dates.DateTime(2017, 3, 17, 0, 0, 0, 100)),
    ("y-u-d H:M:S.s", "2017-Mar-17 00:00:00.12", Dates.DateTime(2017, 3, 17, 0, 0, 0, 120)),
    ("y-u-d H:M:S.s", "2017-Mar-17 00:00:00.123", Dates.DateTime(2017, 3, 17, 0, 0, 0, 123)),
    ("y-u-d H:M:S.s", "2017-Mar-17 00:00:00.1230", Dates.DateTime(2017, 3, 17, 0, 0, 0, 123)),
]

for useio in (true, false)
    for case in testcases
        fmt, str, dt = case
        @test Parsers.parse(typeof(dt), useio ? IOBuffer(str) : str, Parsers.Options(dateformat=fmt)) == dt
    end
end

res = Parsers.xparse(DateTime, "2017-Mar-17 00:00:00.1231", dateformat="y-u-d H:M:S.s", rounding=nothing)
@test res.code == EOF | INEXACT
res = Parsers.xparse(DateTime, "2017-Mar-17 00:00:00.1231", dateformat="y-u-d H:M:S.s", rounding=RoundNearest)
@test res.code == EOF | OK
@test res.val == Dates.DateTime(2017, 3, 17, 0, 0, 0, 123)
res = Parsers.xparse(DateTime, "2017-Mar-17 00:00:00.1231", dateformat="y-u-d H:M:S.s", rounding=RoundUp)
@test res.code == EOF | OK
@test res.val == Dates.DateTime(2017, 3, 17, 0, 0, 0, 124)

@static if VERSION >= v"1.3-DEV"
@testset "AM/PM" begin
    for (t12,t24) in (("12:00am","00:00"), ("12:07am","00:07"), ("01:24AM","01:24"),
                    ("12:00pm","12:00"), ("12:15pm","12:15"), ("11:59PM","23:59"))
        d = DateTime("2018-01-01T$t24:00")
        t = Time("$t24:00")
        for HH in ("HH","II")
            @test Parsers.parse(DateTime, "2018-01-01 $t12", Parsers.Options(dateformat="yyyy-mm-dd $HH:MMp")) == d
            @test Parsers.parse(Time, "$t12", Parsers.Options(dateformat="$HH:MMp")) == t
        end
    end
    for bad in ("00:24am", "00:24pm", "13:24pm", "2pm", "12:24p.m.", "12:24 pm", "12:24pµ")
        @test_throws Parsers.Error Parsers.parse(Time, bad, Parsers.Options(dateformat="II:MMp"))
    end
    # if am/pm is missing, defaults to 24-hour clock
    @test Parsers.parse(Time, "13:24", Parsers.Options(dateformat="II:MMp")) == Parsers.parse(Time, "13:24", Parsers.Options(dateformat="HH:MM"))
end
end
