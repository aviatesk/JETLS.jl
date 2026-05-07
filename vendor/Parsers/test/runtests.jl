using Parsers, Test, Dates

import Parsers: INVALID, OK, SENTINEL, QUOTED, DELIMITED, NEWLINE, EOF, INVALID_QUOTED_FIELD, INVALID_DELIMITER, OVERFLOW, ESCAPED_STRING, SPECIAL_VALUE, INEXACT
import Aqua
import Serialization
struct CustomType
    x::String
end

Base.tryparse(::Type{CustomType}, x::String) = CustomType(x)

@testset "Parsers" begin

@testset "Core Parsers.xparse" begin

sentinels = ["NANA", "NAN", "NA"]

testcases = [
    (str="", kwargs=(), x=0, code=(INVALID | EOF), vpos=1, vlen=0, tlen=0),
    (str="", kwargs=(sentinel=missing,), x=0, code=(SENTINEL | EOF), vpos=1, vlen=0, tlen=0),
    (str=" ", kwargs=(), x=0, code=(INVALID | EOF), vpos=1, vlen=1, tlen=1),
    (str=" ", kwargs=(sentinel=missing,), x=0, code=(INVALID | EOF), vpos=1, vlen=1, tlen=1),
    (str=" -", kwargs=(sentinel=missing,), x=0, code=(INVALID | EOF), vpos=1, vlen=2, tlen=2),
    (str=" +", kwargs=(sentinel=missing,), x=0, code=(INVALID | EOF), vpos=1, vlen=2, tlen=2),
    (str="-", kwargs=(sentinel=missing,), x=0, code=(INVALID | EOF), vpos=1, vlen=1, tlen=1),
    (str=" {-", kwargs=(sentinel=missing,), x=0, code=(QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=3, vlen=1, tlen=3),
    (str="{+", kwargs=(sentinel=missing,), x=0, code=(QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=2, vlen=1, tlen=2),
    (str=" {+,", kwargs=(sentinel=missing,), x=0, code=(QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=3, vlen=1, tlen=4),
    (str="{-,", kwargs=(sentinel=missing,), x=0, code=(QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=2, vlen=1, tlen=3),
    (str="+,", kwargs=(sentinel=missing,), x=0, code=(INVALID | DELIMITED), vpos=1, vlen=1, tlen=2),
    (str="-,", kwargs=(sentinel=missing,), x=0, code=(INVALID | DELIMITED), vpos=1, vlen=1, tlen=2),
    (str="t,", kwargs=(sentinel=missing,), x=0, code=(INVALID | INVALID_DELIMITER | DELIMITED), vpos=1, vlen=1, tlen=2),
    (str=" {-},", kwargs=(sentinel=missing,), x=0, code=(INVALID | QUOTED | DELIMITED), vpos=3, vlen=1, tlen=5),
    (str="{+} ,", kwargs=(sentinel=missing,), x=0, code=(INVALID | QUOTED | DELIMITED), vpos=2, vlen=1, tlen=5),
    (str="{}", kwargs=(sentinel=missing,), x=0, code=(SENTINEL | QUOTED | EOF), vpos=2, vlen=0, tlen=2),
    (str="{},", kwargs=(sentinel=missing,), x=0, code=(SENTINEL | QUOTED | DELIMITED), vpos=2, vlen=0, tlen=3),
    (str="{a},", kwargs=(sentinel=missing,), x=0, code=(INVALID | QUOTED | DELIMITED), vpos=2, vlen=1, tlen=4),
    (str="{", kwargs=(), x=0, code=(QUOTED | INVALID_QUOTED_FIELD | EOF), vpos=2, vlen=-1, tlen=1),
    (str="{}", kwargs=(), x=0, code=(INVALID | QUOTED | EOF), vpos=2, vlen=0, tlen=2),
    (str=" {", kwargs=(), x=0, code=(QUOTED | INVALID_QUOTED_FIELD | EOF), vpos=3, vlen=-2, tlen=2),
    (str=" {\\\\", kwargs=(), x=0, code=(QUOTED | INVALID_QUOTED_FIELD | ESCAPED_STRING | EOF), vpos=3, vlen=0, tlen=4),
    (str=" {\\}} ", kwargs=(), x=0, code=(QUOTED | INVALID | ESCAPED_STRING | EOF), vpos=3, vlen=2, tlen=6),
    (str=" {\\\\}", kwargs=(), x=0, code=(INVALID | QUOTED | ESCAPED_STRING | EOF), vpos=3, vlen=2, tlen=5),

    (str=" {}", kwargs=(), x=0, code=(INVALID | QUOTED | EOF), vpos=3, vlen=0, tlen=3),
    (str=" { }", kwargs=(), x=0, code=(INVALID | QUOTED | EOF), vpos=3, vlen=1, tlen=4),
    (str=" {,} ", kwargs=(), x=0, code=(INVALID | QUOTED | EOF), vpos=3, vlen=1, tlen=5),
    (str=" { } ", kwargs=(), x=0, code=(INVALID | QUOTED | EOF), vpos=3, vlen=1, tlen=5),
    (str=" {\t", kwargs=(), x=0, code=(INVALID_QUOTED_FIELD | QUOTED | EOF), vpos=3, vlen=-2, tlen=3),

    (str="NA", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | EOF), vpos=1, vlen=2, tlen=2),
    (str="£", kwargs=(sentinel=["£"],), x=0, code=(SENTINEL | EOF), vpos=1, vlen=2, tlen=2),
    (str="NA2", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | EOF | INVALID_DELIMITER), vpos=1, vlen=3, tlen=3),
    (str="NAN", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | EOF), vpos=1, vlen=3, tlen=3),
    (str="NANA", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | EOF), vpos=1, vlen=4, tlen=4),
    (str=" NA", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | EOF), vpos=1, vlen=3, tlen=3),
    (str="{NAN", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=2, vlen=3, tlen=4),
    (str="{NANA}", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | QUOTED | EOF), vpos=2, vlen=4, tlen=6),
    (str=" {NA", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=3, vlen=2, tlen=4),
    (str=" {NANA}", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | QUOTED | EOF), vpos=3, vlen=4, tlen=7),
    (str=" { NAN}", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | QUOTED | EOF), vpos=3, vlen=4, tlen=7),
    (str=" {NAN }", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | QUOTED | EOF), vpos=3, vlen=4, tlen=7),
    (str=" {NA} ", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | QUOTED | EOF), vpos=3, vlen=2, tlen=6),
    (str=" { NANA} ", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | QUOTED | EOF), vpos=3, vlen=5, tlen=9),
    (str=" {\tNA", kwargs=(sentinel=sentinels,), x=0, code=(SENTINEL | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=3, vlen=3, tlen=5),

    (str="-", kwargs=(sentinel=["-"],), x=0, code=(SENTINEL | EOF), vpos=1, vlen=1, tlen=1),
    (str=" +", kwargs=(sentinel=["+"],), x=0, code=(SENTINEL | EOF), vpos=1, vlen=2, tlen=2),
    (str="+1 ", kwargs=(sentinel=["+1"],), x=1, code=(SENTINEL | EOF), vpos=1, vlen=3, tlen=3),
    (str=" -1 ", kwargs=(sentinel=["-1"],), x=-1, code=(SENTINEL | EOF), vpos=1, vlen=4, tlen=4),
    (str="{1", kwargs=(sentinel=["1"],), x=1, code=(SENTINEL | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=2, vlen=1, tlen=2),
    (str="{1 ", kwargs=(sentinel=["1"],), x=1, code=(SENTINEL | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=2, vlen=2, tlen=3),
    (str="{-1}", kwargs=(sentinel=["-1"],), x=-1, code=(SENTINEL | QUOTED | EOF), vpos=2, vlen=2, tlen=4),
    (str=" {+1", kwargs=(sentinel=["+1"],), x=1, code=(SENTINEL | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=3, vlen=2, tlen=4),
    (str=" {-}", kwargs=(sentinel=["-"],), x=0, code=(SENTINEL | QUOTED | EOF), vpos=3, vlen=1, tlen=4),
    (str=" { +}", kwargs=(sentinel=["+"],), x=0, code=(SENTINEL | QUOTED | EOF), vpos=3, vlen=2, tlen=5),
    (str=" {-1 }", kwargs=(sentinel=["-1"],), x=-1, code=(SENTINEL | QUOTED | EOF), vpos=3, vlen=3, tlen=6),
    (str=" {+1} ", kwargs=(sentinel=["+1"],), x=1, code=(SENTINEL | QUOTED | EOF), vpos=3, vlen=2, tlen=6),
    (str=" { 1} ", kwargs=(sentinel=["1"],), x=1, code=(SENTINEL | QUOTED | EOF), vpos=3, vlen=2, tlen=6),
    (str=" {\t-", kwargs=(sentinel=["-"],), x=0, code=(SENTINEL | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=3, vlen=2, tlen=4),

    (str="+a ", kwargs=(sentinel=["+1"],), x=0, code=(INVALID | EOF | INVALID_DELIMITER), vpos=1, vlen=3, tlen=3),
    (str=" -a ", kwargs=(sentinel=["-1"],), x=0, code=(INVALID | EOF | INVALID_DELIMITER), vpos=1, vlen=4, tlen=4),
    (str="{a", kwargs=(sentinel=["1"],), x=0, code=(INVALID | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=2, vlen=0, tlen=2),
    (str="{-a}", kwargs=(sentinel=["-1"],), x=0, code=(INVALID | EOF | QUOTED), vpos=2, vlen=2, tlen=4),
    (str=" {+1a", kwargs=(sentinel=["+1"],), x=1, code=(SENTINEL | QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=3, vlen=3, tlen=5),
    (str=" {-1a }", kwargs=(sentinel=["-1"],), x=-1, code=(SENTINEL | QUOTED | INVALID | EOF), vpos=3, vlen=4, tlen=7),
    (str=" {+a} ", kwargs=(sentinel=["+1"],), x=0, code=(INVALID | QUOTED | EOF), vpos=3, vlen=2, tlen=6),
    (str=" { a} ", kwargs=(sentinel=["1"],), x=0, code=(INVALID | QUOTED | EOF), vpos=3, vlen=2, tlen=6),

    (str="-", kwargs=(), x=0, code=(INVALID | EOF), vpos=1, vlen=1, tlen=1),
    (str="0", kwargs=(), x=0, code=(OK | EOF), vpos=1, vlen=1, tlen=1),
    (str=" +", kwargs=(), x=0, code=(INVALID | EOF), vpos=1, vlen=2, tlen=2),
    (str=" +1", kwargs=(), x=1, code=(OK | EOF), vpos=1, vlen=3, tlen=3),
    (str="-1 ", kwargs=(), x=-1, code=(OK | EOF), vpos=1, vlen=3, tlen=3),
    (str=" +1 ", kwargs=(), x=1, code=(OK | EOF), vpos=1, vlen=4, tlen=4),
    (str="{1", kwargs=(), x=1, code=(OK | QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=2, vlen=1, tlen=2),
    (str="{1 ", kwargs=(), x=1, code=(OK | QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=2, vlen=2, tlen=3),
    (str="{-1}", kwargs=(), x=-1, code=(OK | QUOTED | EOF), vpos=2, vlen=2, tlen=4),
    (str=" {+1", kwargs=(), x=1, code=(OK | QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=3, vlen=2, tlen=4),
    (str=" {-}", kwargs=(), x=0, code=(INVALID | QUOTED | EOF), vpos=3, vlen=1, tlen=4),
    (str=" { +}", kwargs=(), x=0, code=(INVALID | QUOTED | EOF), vpos=3, vlen=2, tlen=5),
    (str=" {-1 }", kwargs=(), x=-1, code=(OK | QUOTED | EOF), vpos=3, vlen=3, tlen=6),
    (str=" {+1} ", kwargs=(), x=1, code=(OK | QUOTED | EOF), vpos=3, vlen=2, tlen=6),
    (str=" { 1} ", kwargs=(), x=1, code=(OK | QUOTED | EOF), vpos=3, vlen=2, tlen=6),
    (str=" {\t-", kwargs=(), x=0, code=(QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=3, vlen=2, tlen=4),
    (str="{1ab\\\\c}", kwargs=(), x=1, code=(OK | QUOTED | ESCAPED_STRING | EOF | INVALID), vpos=2, vlen=6, tlen=8),
    (str="{1\\\\abc,", kwargs=(), x=1, code=(OK | QUOTED | ESCAPED_STRING | EOF | INVALID_QUOTED_FIELD), vpos=2, vlen=6, tlen=8),
    (str="{1abc},", kwargs=(sentinel=["1abc"],), x=1, code=(SENTINEL | QUOTED | DELIMITED), vpos=2, vlen=4, tlen=7),
    (str="{1abc", kwargs=(sentinel=["1abc"],), x=1, code=(SENTINEL | QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=2, vlen=4, tlen=5),

    (str="922337203,", kwargs=(sentinel=["92233"],), x=922337203, code=(OK | DELIMITED), vpos=1, vlen=9, tlen=10),
    (str="92233,", kwargs=(sentinel=["92233"],), x=92233, code=(SENTINEL | DELIMITED), vpos=1, vlen=5, tlen=6),
    (str="92233  ", kwargs=(sentinel=["92233"],), x=92233, code=(SENTINEL | EOF), vpos=1, vlen=7, tlen=7),
    (str="{92233  ,", kwargs=(sentinel=["92233"],), x=92233, code=(SENTINEL | QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=2, vlen=7, tlen=9),
    (str="{92233} ,", kwargs=(sentinel=["92233"],), x=92233, code=(SENTINEL | QUOTED | DELIMITED), vpos=2, vlen=5, tlen=9),
    (str=" { 92233 },", kwargs=(sentinel=["92233"],), x=92233, code=(SENTINEL | QUOTED | DELIMITED), vpos=3, vlen=7, tlen=11),
    (str="922337203685477580", kwargs=(), x=922337203685477580, code=(OK | EOF), vpos=1, vlen=18, tlen=18),
    (str="9223372036854775808", kwargs=(), x=-9223372036854775808, code=(OVERFLOW | EOF), vpos=1, vlen=19, tlen=19),
    (str="9223372036854775808a", kwargs=(sentinel=["9223372036854775808a"],), x=-9223372036854775808, code=(SENTINEL | EOF), vpos=1, vlen=20, tlen=20),
    (str="{9223372036854775808a", kwargs=(sentinel=["9223372036854775808a"],), x=-9223372036854775808, code=(SENTINEL | QUOTED | EOF | INVALID_QUOTED_FIELD), vpos=2, vlen=20, tlen=21),

    (str="{9223372036854775808", kwargs=(), x=-9223372036854775808, code=(OVERFLOW | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=2, vlen=19, tlen=20),
    (str="{9223372036854775807", kwargs=(), x=9223372036854775807, code=(OK | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=2, vlen=19, tlen=20),
    (str="{9223372036854775807a", kwargs=(), x=9223372036854775807, code=(OK | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=2, vlen=19, tlen=21),
    (str="9223372036854775807a", kwargs=(), x=9223372036854775807, code=(OK | EOF | INVALID_DELIMITER), vpos=1, vlen=20, tlen=20),
    (str="9223372036854775807,", kwargs=(), x=9223372036854775807, code=(OK | DELIMITED), vpos=1, vlen=19, tlen=20),
    (str="9223372036854775807", kwargs=(sentinel=["9223372036854775807"],), x=9223372036854775807, code=(SENTINEL | EOF), vpos=1, vlen=19, tlen=19),
    (str="{9223372036854775807a", kwargs=(sentinel=["9223372036854775807a"],), x=9223372036854775807, code=(SENTINEL | EOF | QUOTED | INVALID_QUOTED_FIELD), vpos=2, vlen=20, tlen=21),

    (str="9223372036854775808", kwargs=(sentinel=["92233"],), x=-9223372036854775808, code=(OVERFLOW | EOF), vpos=1, vlen=19, tlen=19),
    (str="922337203685477580", kwargs=(sentinel=["92233"],), x=922337203685477580, code=(OK | EOF), vpos=1, vlen=18, tlen=18),
    (str="922337203685477580,", kwargs=(), x=922337203685477580, code=(OK | DELIMITED), vpos=1, vlen=18, tlen=19),
    (str="922337203685477580,", kwargs=(sentinel=["92233"],), x=922337203685477580, code=(OK | DELIMITED), vpos=1, vlen=18, tlen=19),
    (str="9223372036854775800000,", kwargs=(sentinel=["92233"],), x=-80, code=(DELIMITED | INVALID_DELIMITER | OVERFLOW), vpos=1, vlen=22, tlen=23),

    (str="1;", kwargs=(), x=1, code=(OK | EOF | INVALID_DELIMITER), vpos=1, vlen=2, tlen=2),
    (str="1;", kwargs=(delim=UInt8(';'),), x=1, code=(OK | DELIMITED), vpos=1, vlen=1, tlen=2),
    (str="1abc;", kwargs=(delim=UInt8(';'),), x=1, code=(OK | DELIMITED | INVALID_DELIMITER), vpos=1, vlen=4, tlen=5),
    (str="1\n", kwargs=(), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=2),
    (str="1\r", kwargs=(), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=2),
    (str="1\r\n", kwargs=(), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=3),
    (str="1\n2", kwargs=(), x=1, code=(OK | NEWLINE), vpos=1, vlen=1, tlen=2),
    (str="1\r2", kwargs=(), x=1, code=(OK | NEWLINE), vpos=1, vlen=1, tlen=2),
    (str="1\r\n2", kwargs=(), x=1, code=(OK | NEWLINE), vpos=1, vlen=1, tlen=3),
    (str="1a\n", kwargs=(), x=1, code=(OK | NEWLINE | EOF | INVALID_DELIMITER), vpos=1, vlen=2, tlen=3),
    (str="1a\r", kwargs=(), x=1, code=(OK | NEWLINE | EOF | INVALID_DELIMITER), vpos=1, vlen=2, tlen=3),
    (str="1a\r\n", kwargs=(), x=1, code=(OK | NEWLINE | EOF | INVALID_DELIMITER), vpos=1, vlen=2, tlen=4),
    (str="1a\n2", kwargs=(), x=1, code=(OK | NEWLINE | INVALID_DELIMITER), vpos=1, vlen=2, tlen=3),
    (str="1a\r2", kwargs=(), x=1, code=(OK | NEWLINE | INVALID_DELIMITER), vpos=1, vlen=2, tlen=3),
    (str="1a\r\n2", kwargs=(), x=1, code=(OK | NEWLINE | INVALID_DELIMITER), vpos=1, vlen=2, tlen=4),

    (str="1,,,2,null,4", kwargs=(), x=1, code=(OK | DELIMITED), vpos=1, vlen=1, tlen=2),
    (str="1,,,2,null,4", kwargs=(ignorerepeated=true,), x=1, code=(OK | DELIMITED), vpos=1, vlen=1, tlen=4),
    (str="1,", kwargs=(ignorerepeated=true,), x=1, code=(OK | DELIMITED | EOF), vpos=1, vlen=1, tlen=2),
    (str="1,,", kwargs=(ignorerepeated=true,), x=1, code=(OK | DELIMITED | EOF), vpos=1, vlen=1, tlen=3),
    (str="1,,,", kwargs=(ignorerepeated=true,), x=1, code=(OK | DELIMITED | EOF), vpos=1, vlen=1, tlen=4),
    (str="1::2", kwargs=(delim="::",), x=1, code=(OK | DELIMITED), vpos=1, vlen=1, tlen=3),
    (str="1::::2", kwargs=(ignorerepeated=true, delim="::"), x=1, code=(OK | DELIMITED), vpos=1, vlen=1, tlen=5),
    (str="1a::::2", kwargs=(ignorerepeated=true, delim="::"), x=1, code=(OK | DELIMITED | INVALID_DELIMITER), vpos=1, vlen=2, tlen=6),
    (str="1[][]", kwargs=(delim="[]", ignorerepeated = true), x = 1, code=(OK | DELIMITED | EOF), vpos=1, vlen=1, tlen=5),
    (str="1a[][]", kwargs=(delim="[]", ignorerepeated = true), x = 1, code=(OK | DELIMITED | INVALID_DELIMITER | EOF), vpos=1, vlen=2, tlen=6),
    (str="1a[][]", kwargs=(delim="[]",), x = 1, code=(OK | DELIMITED | INVALID_DELIMITER), vpos=1, vlen=2, tlen=4),
    # ignorerepeated
    (str="1a,,", kwargs=(ignorerepeated=true,), x=1, code=(OK | DELIMITED | INVALID_DELIMITER | EOF), vpos=1, vlen=2, tlen=4),
    (str="1a,,2", kwargs=(ignorerepeated=true,), x=1, code=(OK | DELIMITED | INVALID_DELIMITER), vpos=1, vlen=2, tlen=4),
    (str="1,\n", kwargs=(ignorerepeated=true, delim=UInt8(',')), x=1, code=(OK | DELIMITED | NEWLINE | EOF), vpos=1, vlen=1, tlen=3),
    (str="1,\n,", kwargs=(ignorerepeated=true, delim=UInt8(',')), x=1, code=(OK | DELIMITED | NEWLINE), vpos=1, vlen=1, tlen=4),
    (str="1,\n,\n", kwargs=(ignorerepeated=true, delim=UInt8(',')), x=1, code=(OK | DELIMITED | NEWLINE), vpos=1, vlen=1, tlen=4),
    (str="1::\n::", kwargs=(ignorerepeated=true, delim="::"), x=1, code=(OK | DELIMITED | NEWLINE), vpos=1, vlen=1, tlen=6),
    (str="1::\n::\n", kwargs=(ignorerepeated=true, delim="::"), x=1, code=(OK | DELIMITED | NEWLINE), vpos=1, vlen=1, tlen=6),
    (str="1,\r\n,", kwargs=(ignorerepeated=true, delim=UInt8(',')), x=1, code=(OK | DELIMITED | NEWLINE), vpos=1, vlen=1, tlen=5),
    (str="1,\r\n,\r\n", kwargs=(ignorerepeated=true, delim=UInt8(',')), x=1, code=(OK | DELIMITED | NEWLINE), vpos=1, vlen=1, tlen=5),
    (str="1::\r\n::", kwargs=(ignorerepeated=true, delim="::"), x=1, code=(OK | DELIMITED | NEWLINE), vpos=1, vlen=1, tlen=7),
    (str="1::\r\n::\r\n", kwargs=(ignorerepeated=true, delim="::"), x=1, code=(OK | DELIMITED | NEWLINE), vpos=1, vlen=1, tlen=7),
    # invalid
    (str="1a,\n,", kwargs=(ignorerepeated=true, delim=UInt8(',')), x=1, code=(OK | INVALID_DELIMITER | DELIMITED | NEWLINE), vpos=1, vlen=2, tlen=5),
    (str="1a,\n,\n", kwargs=(ignorerepeated=true, delim=UInt8(',')), x=1, code=(OK | INVALID_DELIMITER | DELIMITED | NEWLINE), vpos=1, vlen=2, tlen=5),
    (str="1a::\n::", kwargs=(ignorerepeated=true, delim="::"), x=1, code=(OK | INVALID_DELIMITER | DELIMITED | NEWLINE), vpos=1, vlen=2, tlen=7),
    (str="1a::\n::\n", kwargs=(ignorerepeated=true, delim="::"), x=1, code=(OK | INVALID_DELIMITER | DELIMITED | NEWLINE), vpos=1, vlen=2, tlen=7),
    (str="1a,\r\n,", kwargs=(ignorerepeated=true, delim=UInt8(',')), x=1, code=(OK | INVALID_DELIMITER | DELIMITED | NEWLINE), vpos=1, vlen=2, tlen=6),
    (str="1a,\r\n,\r\n", kwargs=(ignorerepeated=true, delim=UInt8(',')), x=1, code=(OK | INVALID_DELIMITER | DELIMITED | NEWLINE), vpos=1, vlen=2, tlen=6),
    (str="1a::\r\n::", kwargs=(ignorerepeated=true, delim="::"), x=1, code=(OK | INVALID_DELIMITER | DELIMITED | NEWLINE), vpos=1, vlen=2, tlen=8),
    (str="1a::\r\n::\r\n", kwargs=(ignorerepeated=true, delim="::"), x=1, code=(OK | INVALID_DELIMITER | DELIMITED | NEWLINE), vpos=1, vlen=2, tlen=8),
    # ignoreemptylines
    (str="1\n\n", kwargs=(ignoreemptylines=true,), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=3),
    (str="1\n\n\n", kwargs=(ignoreemptylines=true,), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=4),
    (str="1,\n\n\n,", kwargs=(ignorerepeated=true, ignoreemptylines=true, delim=UInt8(',')), x=1, code=(OK | NEWLINE | DELIMITED), vpos=1, vlen=1, tlen=6),
    (str="1::\n\n\n::", kwargs=(ignorerepeated=true, ignoreemptylines=true, delim="::"), x=1, code=(OK | NEWLINE | DELIMITED), vpos=1, vlen=1, tlen=8),
    (str="1\r\n\r\n", kwargs=(ignoreemptylines=true,), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=5),
    (str="1\r\n\r\n\r\n", kwargs=(ignoreemptylines=true,), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=7),
    (str="1,\r\n\r\n\r\n,", kwargs=(ignorerepeated=true, ignoreemptylines=true, delim=UInt8(',')), x=1, code=(OK | NEWLINE | DELIMITED), vpos=1, vlen=1, tlen=9),
    (str="1::\r\n\r\n\r\n::", kwargs=(ignorerepeated=true, ignoreemptylines=true, delim="::"), x=1, code=(OK | NEWLINE | DELIMITED), vpos=1, vlen=1, tlen=11),
    # comments
    (str="1\n#\n", kwargs=(comment="#",), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=4),
    (str="1\n#   \n", kwargs=(comment="#",), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=7),
    (str="1,\n#  \n\n,", kwargs=(ignorerepeated=true, ignoreemptylines=true, comment="#", delim=UInt8(',')), x=1, code=(OK | NEWLINE | DELIMITED), vpos=1, vlen=1, tlen=9),
    (str="1::\n#  \n\n::", kwargs=(ignorerepeated=true, ignoreemptylines=true, comment="#", delim="::"), x=1, code=(OK | NEWLINE | DELIMITED), vpos=1, vlen=1, tlen=11),
    (str="1\r\n#  \r\n", kwargs=(ignoreemptylines=true, comment="#",), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=8),
    (str="1\r\n#  \r\n\r\n", kwargs=(ignoreemptylines=true, comment="#",), x=1, code=(OK | NEWLINE | EOF), vpos=1, vlen=1, tlen=10),
    (str="1,\r\n#  \r\n\r\n,", kwargs=(ignorerepeated=true, ignoreemptylines=true, comment="#", delim=UInt8(',')), x=1, code=(OK | NEWLINE | DELIMITED), vpos=1, vlen=1, tlen=12),
    (str="1::\r\n#  \r\n\r\n::", kwargs=(ignorerepeated=true, ignoreemptylines=true, comment="#", delim="::"), x=1, code=(OK | NEWLINE | DELIMITED), vpos=1, vlen=1, tlen=14),
    # stripquoted
    (str=" 1", kwargs=(stripquoted=true,), x=1, code=(OK | EOF), vpos=2, vlen=1, tlen=2),
    (str="{ 1}", kwargs=(stripquoted=true,), x=1, code=(OK | QUOTED | EOF), vpos=3, vlen=1, tlen=4),
    (str="{1 }", kwargs=(stripquoted=true,), x=1, code=(OK | QUOTED | EOF), vpos=2, vlen=1, tlen=4),
    (str="1 ", kwargs=(stripquoted=true,), x=1, code=(OK | EOF), vpos=1, vlen=1, tlen=2),
    (str="1 ,", kwargs=(stripquoted=true,delim=UInt8(',')), x=1, code=(OK | DELIMITED), vpos=1, vlen=1, tlen=3),
    (str="{1 } ,", kwargs=(stripquoted=true,delim=UInt8(',')), x=1, code=(OK | DELIMITED | QUOTED), vpos=2, vlen=1, tlen=6),
];

chars(s) = Char(s)
chars(s::AbstractString) = s
for useio in (false, true)
    for (oq, cq, e) in (
        (UInt8('"'), UInt8('"'), UInt8('"')),
        (UInt8('"'), UInt8('"'), UInt8('\\')),
        (UInt8('{'), UInt8('}'), UInt8('\\')),
        ("#=", "=#", UInt8('\\')),
    )
        for (i, case) in enumerate(testcases)
            # println("testing int case i = $i, case = $case, useio = $useio, oq = `$(chars(oq))`, cq = `$(chars(cq))`, e = `$(chars(e))`")
            str = replace(replace(replace(case.str, '{'=>chars(oq)), '}'=>chars(cq)), '\\'=>chars(e))
            source = useio ? IOBuffer(str) : str
            res = Parsers.xparse(Int64, source; openquotechar=oq, closequotechar=cq, escapechar=e, case.kwargs...)
            x, code, tlen = res.val, res.code, res.tlen
            if !Parsers.invalid(code) && !Parsers.sentinel(code)
                @test x == case.x
            end
            @test code == case.code
            if Parsers.quoted(code)
                # Above we may have `replace`d quote chars, so original `case.tlen` may no longer hold.
                # Assume `str` had no chars after delim, and whole input should have been consumed.
                @test tlen == ncodeunits(str)
            else
                @test tlen == case.tlen
            end
        end
    end
end

# strings
for useio in (false, true)
    for (oq, cq, e) in ((UInt8('"'), UInt8('"'), UInt8('"')), (UInt8('"'), UInt8('"'), UInt8('\\')), (UInt8('{'), UInt8('}'), UInt8('\\')))
        for (i, case) in enumerate(testcases)
            for S in (Parsers.PosLen, Parsers.PosLen31)
                # println("testing string case i = $i, case = $case, useio = $useio, oq = `$(Char(oq))`, cq = `$(Char(cq))`, e = `$(Char(e))`")
                str = replace(replace(replace(case.str, '{'=>Char(oq)), '}'=>Char(cq)), '\\'=>Char(e))
                source = useio ? IOBuffer(str) : str
                res = Parsers.xparse(String, source, S; openquotechar=oq, closequotechar=cq, escapechar=e, case.kwargs...)
                x, code, tlen = res.val, res.code, res.tlen
                if !Parsers.invalidquotedfield(code)
                    @test x.pos == case.vpos
                    @test x.len == case.vlen
                    @test tlen == case.tlen
                end
            end
        end
    end
end

# escaped value
res = Parsers.xparse(String, "\"123 \\\\ 456\""; escapechar=UInt8('\\'))
@test res.val.pos == 2
@test res.val.escapedvalue
res = Parsers.xparse(String, "\"123 \\\\ 456\"", Parsers.PosLen31; escapechar=UInt8('\\'))
@test res.val.pos == 2
@test res.val.escapedvalue

# tab delim, still strip whitespace
res = Parsers.xparse(Int64, " 123 \t 456 "; delim=UInt8('\t'))
@test res.val == 123
@test res.tlen == 6
@test res.code == (OK | DELIMITED)

# multiple space sentinels
res = Parsers.xparse(Int64, "1\n"; sentinel=["", " ", "  "])
@test res.val == 1
@test res.tlen == 2
@test res.code == (OK | EOF | NEWLINE)

# #140, #142
res = Parsers.xparse(String, "NA"; sentinel=["NA"])
@test res.code == (SENTINEL | EOF)
res = Parsers.xparse(String, "NA", Parsers.PosLen31; sentinel=["NA"])
@test res.code == (SENTINEL | EOF)

# stripwhitespace
for S in (Parsers.PosLen, Parsers.PosLen31)
    res = Parsers.xparse(String, "{{hey there}}", S; openquotechar="{{", closequotechar="}}", stripwhitespace=true)
    @test res.val.pos == 3 && res.val.len == 9
    res = Parsers.xparse(String, "{hey there}", S; openquotechar='{', closequotechar='}', stripwhitespace=true)
    @test res.val.pos == 2 && res.val.len == 9
    res = Parsers.xparse(String, "{{hey there }}", S; openquotechar="{{", closequotechar="}}", stripwhitespace=true)
    @test res.val.pos == 3 && res.val.len == 10
    res = Parsers.xparse(String, "{hey there }", S; openquotechar='{', closequotechar='}', stripwhitespace=true)
    @test res.val.pos == 2 && res.val.len == 10
    res = Parsers.xparse(String, "{hey there },", S; openquotechar='{', closequotechar='}', delim=',', stripwhitespace=true)
    @test res.val.pos == 2 && res.val.len == 10
    res = Parsers.xparse(String, "{hey there } ,", S; openquotechar='{', closequotechar='}', delim=',', stripwhitespace=true)
    @test res.val.pos == 2 && res.val.len == 10
    res = Parsers.xparse(String, "{hey there } a,", S; openquotechar='{', closequotechar='}', delim=',', stripwhitespace=true)
    @test res.val.pos == 2 && res.val.len == 10 && Parsers.invaliddelimiter(res.code)
    res = Parsers.xparse(String, "{hey there } a ", S; openquotechar='{', closequotechar='}', delim=nothing, stripwhitespace=true)
    @test res.val.pos == 2 && res.val.len == 10 && res.tlen == 13
    res = Parsers.xparse(String, "hey there ,", S; delim=',', stripwhitespace=true)
    @test res.val.pos == 1 && res.val.len == 9
    res = Parsers.xparse(String, " hey there ", S; stripwhitespace=true)
    @test res.val.pos == 2 && res.val.len == 9
    res = Parsers.xparse(String, " hey there ", S; delim=nothing, stripwhitespace=true)
    @test res.val.pos == 2 && res.val.len == 9

    res = Parsers.xparse(String, "{{hey there}}", S; openquotechar="{{", closequotechar="}}", stripquoted=true)
    @test res.val.pos == 3 && res.val.len == 9
    res = Parsers.xparse(String, "{hey there}", S; openquotechar='{', closequotechar='}', stripquoted=true)
    @test res.val.pos == 2 && res.val.len == 9
    res = Parsers.xparse(String, "{{hey there }}", S; openquotechar="{{", closequotechar="}}", stripquoted=true)
    @test res.val.pos == 3 && res.val.len == 9
    res = Parsers.xparse(String, "{hey there }", S; openquotechar='{', closequotechar='}', stripquoted=true)
    @test res.val.pos == 2 && res.val.len == 9
    res = Parsers.xparse(String, "{hey there },", S; openquotechar='{', closequotechar='}', delim=',', stripquoted=true)
    @test res.val.pos == 2 && res.val.len == 9
    res = Parsers.xparse(String, "{hey there } ,", S; openquotechar='{', closequotechar='}', delim=',', stripquoted=true)
    @test res.val.pos == 2 && res.val.len == 9
    res = Parsers.xparse(String, "{hey there } a,", S; openquotechar='{', closequotechar='}', delim=',', stripquoted=true)
    @test res.val.pos == 2 && res.val.len == 9 && Parsers.invaliddelimiter(res.code)
    res = Parsers.xparse(String, "{hey there } a ", S; openquotechar='{', closequotechar='}', delim=nothing, stripquoted=true)
    @test res.val.pos == 2 && res.val.len == 9 && res.tlen == 13
    res = Parsers.xparse(String, "hey there ,", S; delim=',', stripquoted=true)
    @test res.val.pos == 1 && res.val.len == 9
    res = Parsers.xparse(String, " hey there ", S; stripquoted=true)
    @test res.val.pos == 2 && res.val.len == 9
    res = Parsers.xparse(String, " hey there ", S; delim=nothing, stripquoted=true)
    @test res.val.pos == 2 && res.val.len == 9
    # `stripquoted=true` should always override `stripwhitespace` to `true`
    res = Parsers.xparse(String, " hey there ", S; delim=nothing, stripquoted=true, stripwhitespace=false)
    @test res.val.pos == 2 && res.val.len == 9

    # https://github.com/JuliaData/Parsers.jl/issues/115
    res = Parsers.xparse(String, "{hey there } ", S; openquotechar='{', closequotechar='}', stripquoted=true, delim=' ')
    @test res.val.pos == 2 && res.val.len == 9
    @test Parsers.delimited(res.code)
    @test res.tlen == 13
end
end # @testset "Core Parsers.xparse"

@testset "ints" begin

@testset "groupmark" begin
    # `parse` is used for parsing inputs with a single value in them,
    # so when delims==groupmarks, we assume what we see are groupmarks
    @testset "Parsers.parse" begin
        groupmark(c::Char) = Parsers._get_default_options(groupmark=UInt8(c))
        @testset "$T" for T in (Int32, Int64)
            # comma
            @test Parsers.parse(T, "100,000,000", groupmark(',')) == 100_000_000
            @test Parsers.parse(T, "1,0,0,0,0,0,0,0,0", groupmark(',')) == 100_000_000
            @test Parsers.parse(T, "2,1,4,7,4,8,3,6,4,7", groupmark(',')) == 2147483647
            if T == Int64
                @test Parsers.parse(T, "9,2,2,3,3,7,2,0,3,6,8,5,4,7,7,5,8,0,7", groupmark(',')) == 9223372036854775807
            end
            # space
            @test Parsers.parse(T, "100 000 000", groupmark(' ')) == 100_000_000
            @test Parsers.parse(T, "1 0 0 0 0 0 0 0 0", groupmark(' ')) == 100_000_000
            @test Parsers.parse(T, "2 1 4 7 4 8 3 6 4 7", groupmark(' ')) == 2147483647
            if T == Int64
                @test Parsers.parse(T, "9 2 2 3 3 7 2 0 3 6 8 5 4 7 7 5 8 0 7", groupmark(' ')) == 9223372036854775807
            end
        end
    end
    ### NOTE: for `xparse` by default `delim=','`, so when we also test `groupmark=','`
    ### we are testing the case where `delim==groupmark`.
    ### In these cases `,` is interpreted as `groupmark` only appear inside a quoted value.
    @testset "Int64" begin
    @test Parsers.xparse(Int64, "100,000,000"; groupmark=',').val == 100
    @test Parsers.xparse(Int64, "\"100,000,000\""; groupmark=',').val == 100_000_000
    @test Parsers.xparse(Int64, "100_000_000"; groupmark='_').val == 100_000_000
    @test Parsers.xparse(Int64, "1_0_0_0_0_0_0_0_0"; groupmark='_').val == 100_000_000
    @test Parsers.xparse(Int64, "100000000"; groupmark=',').val == 100_000_000
    @test Parsers.xparse(Int64, "100000000"; groupmark='_').val == 100_000_000

    @test Parsers.xparse(Int64, "9223372036854775807"; groupmark=',').val == 9223372036854775807
    @test Parsers.xparse(Int64, "9,2,2,3,3,7,2,0,3,6,8,5,4,7,7,5,8,0,7"; groupmark=',').val == 9
    @test Parsers.xparse(Int64, "9_2_2_3_3_7_2_0_3_6_8_5_4_7_7_5_8_0_7"; groupmark='_').val == 9223372036854775807
    @test Parsers.xparse(Int64, "9 2 2 3 3 7 2 0 3 6 8 5 4 7 7 5 8 0 7"; groupmark=' ').val == 9223372036854775807

    @test Parsers.xparse(Int64, "\"100,000,000\",100"; groupmark=',', openquotechar='"', closequotechar='"') == Parsers.Result{Int64}(Int16(13), 14, 100_000_000)
    @test Parsers.xparse(Int32, "\"100_000_000\",100"; groupmark='_', openquotechar='"', closequotechar='"') == Parsers.Result{Int32}(Int16(13), 14, 100_000_000)
    @test Parsers.xparse(Int64, "100,000,000,aaa"; groupmark=',').val == 100
    @test Parsers.xparse(Int64, "100_000_000,aaa"; groupmark='_').val == 100_000_000
    res = Parsers.xparse(Int64, "100_000_000_aaa"; groupmark='_')
    @test res.code == EOF | INVALID | INVALID_DELIMITER
    @test res.tlen == 15
    end # Int64

    @testset "Int32" begin
    @test Parsers.xparse(Int32, "100_000_000"; groupmark='_').val == 100_000_000
    @test Parsers.xparse(Int32, "1_0_0_0_0_0_0_0_0"; groupmark='_').val == 100_000_000
    @test Parsers.xparse(Int32, "100000000"; groupmark='_').val == 100_000_000

    @test Parsers.xparse(Int32, "2147483647"; groupmark='_').val == 2147483647
    @test Parsers.xparse(Int32, "2_1_4_7_4_8_3_6_4_7"; groupmark='_').val == 2147483647
    @test Parsers.xparse(Int32, "2 1 4 7 4 8 3 6 4 7"; groupmark=' ').val == 2147483647

    @test Parsers.xparse(Int32, "\"100,000,000\",100"; groupmark=',', openquotechar='"', closequotechar='"') == Parsers.Result{Int32}(Int16(13), 14, 100_000_000)
    @test Parsers.xparse(Int32, "\"100_000_000\",100"; groupmark='_', openquotechar='"', closequotechar='"') == Parsers.Result{Int32}(Int16(13), 14, 100_000_000)
    @test Parsers.xparse(Int64, "100,000,000,aaa"; groupmark=',').val == 100
    @test Parsers.xparse(Int64, "100_000_000,aaa"; groupmark='_').val == 100_000_000
    res = Parsers.xparse(Int64, "100_000_000_aaa"; groupmark='_')
    @test res.code == EOF | INVALID | INVALID_DELIMITER
    @test res.tlen == 15
    res = Parsers.xparse(Int32, "100_000_000_aaa"; groupmark='_')
    @test res.code == EOF | INVALID | INVALID_DELIMITER
    @test res.tlen == 15
    end # Int32

    @testset "$T error cases" for T in (Int32, Int64)
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark=',', quoted=false, delim=',')
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark=',', quoted=false, delim=UInt8(','))
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark=',', decimal=',')
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark=',', decimal=UInt8(','))
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark='0')
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark=UInt8('0'))
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark='9')
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark='"', openquotechar='"')
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark='"', openquotechar=UInt8('"'))
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark='"', closequotechar='"')
        @test_throws ArgumentError Parsers.xparse(T, "42"; groupmark='"', closequotechar=UInt8('"'))
    end

    @testset "$T groupmark=$(repr(g))" for g in (',',' '), T in (Int32, Int64)
        xgroupmark(c::Char) = Parsers._get_default_xoptions(groupmark=UInt8(c))
        for (input, expected_vals) in [
            ("1000,0000,2000,3000" => (1000,0,2000,3000,)),
            ("\"1000\",\"0000\",\"2000\",\"3000\"" => (1000,0,2000,3000,)),
            ("\"1$(g)0$(g)0$(g)0\",0000,\"2$(g)0$(g)0$(g)0\",3000" => (1000,0,2000,3000,)),
            ("1000,\"0$(g)0$(g)0$(g)0\",2000,\"3$(g)0$(g)0$(g)0\"" => (1000,0,2000,3000,)),
        ]
            pos = 1
            len = length(input)
            local res
            for expected in expected_vals
                res = Parsers.xparse(T, input, pos, len, xgroupmark(g))
                @test res.val == expected
                @test Parsers.ok(res.code)
                pos += res.tlen
            end
            @test Parsers.ok(res.code)
            @test Parsers.eof(res.code)
        end
    end

    # #168
    res = Parsers.parse(Int, "1,729", Parsers._get_default_options(groupmark=UInt8(',')))
    @test res == 1729

    @test_throws ArgumentError Parsers.xparse(Int, "3.14", groupmark='.', decimal=UInt8('.'), quoted=false)
    @test_throws ArgumentError Parsers.xparse(Int, "3.14", groupmark=UInt8('.'), decimal='.', quoted=false)
    @test_throws ArgumentError Parsers.xparse(Int, "3.14", groupmark=UInt8('.'), decimal=UInt8('.'), quoted=false)
    @test_throws ArgumentError Parsers.xparse(Int, "3.14", groupmark='.', decimal='.', quoted=false)
end

# test lots of ints
@time for i in typemin(Int64):100_000_000_000_000:typemax(Int64)
    str = string(i)
    res = Parsers.xparse(Int64, str)
    x, code, tlen = res.val, res.code, res.tlen
    @test string(x) == str
    @test code == OK | EOF
    @test tlen == length(str)
end

# test some critical ints Issue #44
for i in [typemin(Int64):typemin(Int64)+20; typemax(Int)-20:typemax(Int)]
    str = string(i)
    res = Parsers.xparse(Int64, str)
    x, code, tlen = res.val, res.code, res.tlen
    @test string(x) == str
    @test code == OK | EOF
    @test tlen == length(str)
end

end # @testset "ints"

@testset "bools" begin

trues1 = ["T"]
falses1 = ["F"]
trues2 = ["truthy"]
falses2 = ["falsy"]

testcases = [
    (str="", kwargs=(), x=false, code=(INVALID | EOF), tlen=0),
    (str="t", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | EOF), tlen=1),
    (str="tr", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | EOF), tlen=2),
    (str="tru", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | EOF), tlen=3),
    (str="true", kwargs=(), x=true, code=(OK | EOF), tlen=4),

    (str="f", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | EOF), tlen=1),
    (str="fa", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | EOF), tlen=2),
    (str="fal", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | EOF), tlen=3),
    (str="fals", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | EOF), tlen=4),
    (str="false", kwargs=(), x=false, code=(OK | EOF), tlen=5),

    (str="t,", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | DELIMITED), tlen=2),
    (str="tr,", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | DELIMITED), tlen=3),
    (str="tru,", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | DELIMITED), tlen=4),
    (str="true,", kwargs=(), x=true, code=(OK | DELIMITED), tlen=5),

    (str="f,", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | DELIMITED), tlen=2),
    (str="fa,", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | DELIMITED), tlen=3),
    (str="fal,", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | DELIMITED), tlen=4),
    (str="fals,", kwargs=(), x=false, code=(INVALID | INVALID_DELIMITER | DELIMITED), tlen=5),
    (str="false,", kwargs=(), x=false, code=(OK | DELIMITED), tlen=6),

    (str="0", kwargs=(), x=false, code=(OK | EOF), tlen=1),
    (str="1", kwargs=(), x=true, code=(OK | EOF), tlen=1),
    (str="001", kwargs=(), x=true, code=(OK | EOF), tlen=3),
    (str="2", kwargs=(), x=false, code=(INVALID | EOF | INVALID_DELIMITER), tlen=1),

    (str="t", kwargs=(trues=trues1, falses=falses1,), x=false, code=(INVALID | EOF | INVALID_DELIMITER), tlen=1),
    (str="T", kwargs=(trues=trues1, falses=falses1,), x=true, code=(OK | EOF), tlen=1),
    (str="T,", kwargs=(trues=trues1, falses=falses1,), x=true, code=(OK | DELIMITED), tlen=2),
    (str="Tr", kwargs=(trues=trues1, falses=falses1,), x=true, code=(OK | EOF | INVALID_DELIMITER), tlen=2),
    (str="F", kwargs=(trues=trues1, falses=falses1,), x=false, code=(OK | EOF), tlen=1),
    (str="truthy", kwargs=(trues=trues2, falses=falses2,), x=true, code=(OK | EOF), tlen=6),
    (str="truthyfalsy", kwargs=(trues=trues2, falses=falses2,), x=true, code=(OK | EOF | INVALID_DELIMITER), tlen=11),
    (str="falsytruthy", kwargs=(trues=trues2, falses=falses2,), x=false, code=(OK | EOF | INVALID_DELIMITER), tlen=11),
];

for useio in (false, true)
    for (i, case) in enumerate(testcases)
        # println("testing bool case i = $i, case = $case")
        res = Parsers.xparse(Bool, useio ? IOBuffer(case.str) : case.str; case.kwargs...)
        x, code, tlen = res.val, res.code, res.tlen
        if !Parsers.invalid(code) && !Parsers.sentinel(code)
            @test x == case.x
        end
        @test code == case.code
        @test tlen == case.tlen
    end
end

res = Parsers.xparse(Bool, "\"\""; sentinel=missing)
@test Parsers.sentinel(res.code)
res = Parsers.xparse(Bool, "\"\","; sentinel=missing)
@test Parsers.sentinel(res.code)
res = Parsers.xparse(Bool, "t,"; sentinel=missing)
@test !Parsers.sentinel(res.code)

end # @testset "bools"

@testset "regex delim" begin
    res = Parsers.xparse(Int, "123,456"; delim=r",")
    @test res.val == 123
    @test res.code == (OK | DELIMITED)
    @test res.tlen == 4
end

@testset "misc" begin

# additional tests for full xparse branch coverage
oq = UInt8('{')
cq = UInt8('}')
e = UInt8('\\')
str=" {\\"
res = Parsers.xparse(Int64, str; openquotechar=oq, closequotechar=cq, escapechar=e)
x, code, tlen = res.val, res.code, res.tlen
@test code == QUOTED | ESCAPED_STRING | EOF | INVALID_QUOTED_FIELD
@test tlen == 3

@test Parsers.parse(Int, "101") === 101
@test Parsers.parse(Float64, "101,101", Parsers.Options(decimal=',')) === 101.101
@test Parsers.parse(Bool, IOBuffer("true")) === true
@test_throws Parsers.Error Parsers.parse(Int, "abc")

@test Parsers.tryparse(Int, "abc") === nothing
@test Parsers.tryparse(Float32, IOBuffer("101,101"), Parsers.Options(decimal=',')) === Float32(101.101)
@test Parsers.parse(Date, "01/20/2018", Parsers.Options(dateformat="mm/dd/yyyy")) === Date(2018, 1, 20)

# https://github.com/JuliaData/CSV.jl/issues/345
res = Parsers.xparse(String, "\"DALLAS BLACK DANCE THEATRE\",")
x, code, tlen = res.val, res.code, res.tlen
@test x.pos == 2
@test x.len == 26
@test tlen == 29
@test code == OK | QUOTED | DELIMITED

# https://github.com/JuliaData/CSV.jl/issues/344
str = "1,2,null,4"
pos = 1
res = Parsers.xparse(Int, str; pos=pos, sentinel=["null"])
x, code, tlen = res.val, res.code, res.tlen
pos += tlen
@test x === 1
@test code === OK | DELIMITED
@test pos == 3
res = Parsers.xparse(Int, str; pos=pos, sentinel=["null"])
x, code, tlen = res.val, res.code, res.tlen
pos += tlen
@test x === 2
@test code === OK | DELIMITED
@test pos == 5
res = Parsers.xparse(Int, str; pos=pos, sentinel=["null"])
x, code, tlen = res.val, res.code, res.tlen
pos += tlen
@test code === SENTINEL | DELIMITED
@test pos == 10
res = Parsers.xparse(Int, str; pos=pos, sentinel=["null"])
x, code, tlen = res.val, res.code, res.tlen
pos += tlen
@test x === 4
@test code === OK | EOF
@test pos == 11

@test Parsers.parse(Int, SubString("101")) === 101
@test Parsers.parse(Float64, SubString("101,101"), Parsers.Options(decimal=',')) === 101.101

@test Parsers.asciival(' ')

@test_throws ArgumentError Parsers.Options(sentinel=[" "], stripwhitespace=true)
@test_throws ArgumentError Parsers.Options(sentinel=["\""])
@test_throws ArgumentError Parsers.Options(sentinel=[","], delim=',')
@test_throws ArgumentError Parsers.Options(sentinel=[","], delim=",")
@test_throws ArgumentError Parsers.Options(delim=r"\"")
@test_throws ArgumentError Parsers.Options(openquotechar="aaa", delim=r"a+")
@test_throws ArgumentError Parsers.Options(openquotechar=r"a+", delim="aaa")
@test_throws ArgumentError Parsers.Options(escapechar=UInt8('a'), delim="a")
@test_throws ArgumentError Parsers.Options(escapechar='a', delim=r"a")
@test_throws ArgumentError Parsers.Options(decimal='α')
@test_throws ArgumentError Parsers.Options(decimal='1')
@test_throws ArgumentError Parsers.Options(groupmark='α')
@test_throws ArgumentError Parsers.Options(groupmark='1')
@test_throws ArgumentError Parsers.Options(groupmark='α')
@test_throws ArgumentError Parsers.Options(groupmark=' ', decimal=' ')

@test Parsers.checkdelim!(UInt8[], 1, 0, Parsers.OPTIONS) == 1
@test Parsers.checkdelim!(codeunits(","), 1, 1, Parsers.XOPTIONS) == 2
@test Parsers.checkdelim!(codeunits("::"), 1, 2, Parsers.Options(delim="::")) == 3
@test Parsers.checkdelim!(codeunits(",,"), 1, 2, Parsers.Options(ignorerepeated=true, delim=',')) == 3
@test Parsers.checkdelim!(codeunits("::::"), 1, 4, Parsers.Options(delim="::", ignorerepeated=true)) == 5

e = Parsers.Error(Vector{UInt8}("hey"), Int64, INVALID | EOF, 1, 3)
io = IOBuffer()
showerror(io, e)
@test String(take!(io)) == "Parsers.Error (INVALID: EOF ):\ninitial value parsing failed, reached EOF\nattempted to parse Int64 from: \"hey\"\n"
e2 = Parsers.Error(IOBuffer("hey"), Int64, INVALID | EOF, 1, 3)
showerror(io, e2)
@test String(take!(io)) == "Parsers.Error (INVALID: EOF ):\ninitial value parsing failed, reached EOF\nattempted to parse Int64 from: \"hey\"\n"

@test Parsers.invalid(INVALID_DELIMITER)
@test Parsers.sentinel(SENTINEL)
@test !Parsers.sentinel(OK)
@test Parsers.quoted(QUOTED)
@test !Parsers.quoted(INVALID_DELIMITER)
@test Parsers.delimited(DELIMITED)
@test !Parsers.delimited(OK)
@test Parsers.newline(NEWLINE)
@test !Parsers.newline(DELIMITED)
@test Parsers.escapedstring(ESCAPED_STRING)
@test !Parsers.escapedstring(OK)
@test Parsers.invalidquotedfield(INVALID_QUOTED_FIELD)
@test !Parsers.invalidquotedfield(INVALID_DELIMITER)
@test Parsers.invaliddelimiter(INVALID_DELIMITER)
@test !Parsers.invaliddelimiter(INVALID_QUOTED_FIELD)
@test Parsers.overflow(OVERFLOW)
@test !Parsers.overflow(OK)
@test Parsers.quotednotescaped(QUOTED)
@test !Parsers.quotednotescaped(QUOTED | ESCAPED_STRING)

# https://github.com/JuliaData/CSV.jl/issues/454
res = Parsers.xparse(Float64, "\"\"", 1, 2)
@test Parsers.sentinel(res.code)

# #138
res = Parsers.xparse(String, "\"\"", 1, 2)
@test !Parsers.sentinel(res.code)

# #38
@test Parsers.parse(Date, "25JUL1985", Parsers.Options(dateformat="dduuuyyyy")) == Date(1985, 7, 25)

# https://github.com/JuliaIO/JSON.jl/issues/296
@test Parsers.parse(Float64, "99233885.0302231276962159466369304902338091026") === 9.923388503022313e7

# Int8 -1 parsed as UInt8 0xff
@test Parsers.parse(Int8, "-1") === Int8(-1)

# parsing am/pm issue
@test Parsers.parse(DateTime, "7/22/1998 4:37:01.500 PM", Parsers.Options(dateformat="m/d/yyyy I:M:S.s p")) == DateTime(1998, 7, 22, 16, 37, 1, 500)

# #55
# Parsers.parse must consume entire string
@test_throws Parsers.Error Parsers.parse(Int, "10a")
# but with IO will just consume until non digit
@test Parsers.parse(Int, IOBuffer("10a")) == 10

# #65
@test Parsers.parse(Char, "a") === 'a'
@test Parsers.parse(Char, "漢") === '漢'
@test Parsers.parse(Symbol, "a") === :a
@test Parsers.parse(Symbol, "漢") === :漢

res = Parsers.xparse(Char, codeunits("a"), 1, 1, Parsers.XOPTIONS)
@test res.code == (Parsers.EOF | Parsers.OK)
@test res.val == 'a'
res = Parsers.xparse(Char, codeunits("漢"))
@test res.code == (Parsers.EOF | Parsers.OK)
@test res.val == '漢'
res = Parsers.xparse(Symbol, codeunits("a"), 1, 1, Parsers.XOPTIONS)
@test res.code == (Parsers.EOF | Parsers.OK)
@test res.val == :a
res = Parsers.xparse(Symbol, IOBuffer("a"), 1, 1, Parsers.XOPTIONS)
@test res.code == (Parsers.EOF | Parsers.OK)
@test res.val == :a
res = Parsers.xparse(CustomType, codeunits("a"), 1, 1, Parsers.XOPTIONS)
@test res.code == (Parsers.EOF | Parsers.OK)
@test res.val == CustomType("a")
res = Parsers.xparse(CustomType, IOBuffer("a"), 1, 1, Parsers.XOPTIONS)
@test res.code == (Parsers.EOF | Parsers.OK)
@test res.val == CustomType("a")

# 67
@test Parsers.parse(CustomType, "hey there", Parsers.XOPTIONS) == CustomType("hey there")

# https://github.com/JuliaData/CSV.jl/issues/780
missings = ["na"]
opts = Parsers.Options(sentinel=missings, trues=["true"])
@test missings == ["na"]

# reported from Slack via CSV.jl
res = Parsers.xparse(String, ""; sentinel=["NULL"])
@test res == Parsers.Result{PosLen}(OK | EOF, 0, Base.bitcast(PosLen, 0x0000000000100000))
res = Parsers.xparse(String, "", Parsers.PosLen31; sentinel=["NULL"])
@test res == Parsers.Result{Parsers.PosLen31}(OK | EOF, 0, Base.bitcast(Parsers.PosLen31, 0x0000000080000000))

# Parsers.getstring
@test Parsers.getstring(b"hey there", Parsers.PosLen(5, 5), 0x00) == "there"
@test Parsers.getstring(IOBuffer("hey there"), Parsers.PosLen(5, 5), 0x00) == "there"
@test Parsers.getstring("hey there", Parsers.PosLen(5, 5), 0x00) == "there"
@test Parsers.getstring("hey \"\" there", Parsers.PosLen(1, 12, false, true), UInt8('"')) == "hey \" there"
@test Parsers.getstring(IOBuffer("hey \"\" there"), Parsers.PosLen(1, 12, false, true), UInt8('"')) == "hey \" there"
@test Parsers.getstring(b"hey there", Parsers.PosLen31(5, 5), 0x00) == "there"
@test Parsers.getstring(IOBuffer("hey there"), Parsers.PosLen31(5, 5), 0x00) == "there"
@test Parsers.getstring("hey there", Parsers.PosLen31(5, 5), 0x00) == "there"
@test Parsers.getstring("hey \"\" there", Parsers.PosLen31(1, 12, false, true), UInt8('"')) == "hey \" there"
@test Parsers.getstring(IOBuffer("hey \"\" there"), Parsers.PosLen31(1, 12, false, true), UInt8('"')) == "hey \" there"

# PosLen
@test_throws ArgumentError Parsers.PosLen(Parsers._max_pos(Parsers.PosLen) + 1, 0)
@test_throws ArgumentError Parsers.PosLen(1, Parsers._max_len(Parsers.PosLen) + 1)
@test_throws ArgumentError Parsers.PosLen(1, 1).invalidproperty
@test_throws ArgumentError Parsers.PosLen31(Parsers._max_pos(Parsers.PosLen31) + 1, 0)
@test_throws ArgumentError Parsers.PosLen31(1, Parsers._max_len(Parsers.PosLen31) + 1)
@test_throws ArgumentError Parsers.PosLen31(1, 1).invalidproperty
# TODO: validate withlen and poslen

# test invalid fallback parsing
@test_throws Parsers.Error Parsers.parse(Complex{Float64}, "NaN+NaN*im")
@test Parsers.tryparse(Complex{Float64}, "NaN+NaN*im") === nothing

# test we parse and return the correct value up to an invalid delimiter
# https://github.com/JuliaData/Parsers.jl/issues/93
for (T, str, val) in (
    (Float64, "1.0 /", 1.0),
    (Float64, "1.0 /[ 2.0 ]/", 1.0),
    (Int, "2 _", 2),
    (Date, "2021-10-20 *", Date("2021-10-20")),
    (Bool, "false^", false),
)
    res = Parsers.xparse(T, str)
    @test Parsers.invaliddelimiter(res.code)
    @test res.val === val
end

# test `getstring` does not change the position of a stream
source = IOBuffer("\"str1\" \"str2\"")
opt = Parsers.Options(; delim=nothing, quoted=true)
res = Parsers.xparse(String, source, 1, 0, opt)
@test Parsers.getstring(source, res.val, opt.e) == "str1"
res = Parsers.xparse(String, source, 1 + res.tlen, 0, opt)
@test Parsers.getstring(source, res.val, opt.e) == "str2"
source = IOBuffer("\"str1\" \"str2\"")
opt = Parsers.Options(; delim=nothing, quoted=true)
res = Parsers.xparse(String, source, 1, 0, opt, Parsers.PosLen31)
@test Parsers.getstring(source, res.val, opt.e) == "str1"
res = Parsers.xparse(String, source, 1 + res.tlen, 0, opt, Parsers.PosLen31)
@test Parsers.getstring(source, res.val, opt.e) == "str2"

# checkdelim!
buf = UInt8[0x20, 0x20, 0x41, 0x20, 0x20, 0x42, 0x0a, 0x20, 0x20, 0x31, 0x20, 0x20, 0x32, 0x0a, 0x20, 0x20, 0x31, 0x31, 0x20, 0x32, 0x32]
@test Parsers.checkdelim!(buf, 1, 21, Parsers.Options(delim=' ', ignorerepeated=true)) == 3

# #150
@test 0x22 == Parsers.Token(0x22)
@test 0x22 != Parsers.Token(0x00)
@test Parsers.Token(0x22) == 0x22
@test Parsers.Token(0x22) != 0x00

# Char doesn't match delim
for delim in (',', ",", r",")
    res = Parsers.xparse(Char, ",,345", 1, 5, Parsers.Options(sentinel=missing, delim=delim))
    @test res.code == Parsers.SENTINEL | Parsers.DELIMITED
    @test res.tlen == 1
    if !isa(delim, Regex) # Regex matching not supported on IOBuffer
        res = Parsers.xparse(Char, IOBuffer(",,345"), 1, 5, Parsers.Options(sentinel=missing, delim=delim))
        @test res.code == Parsers.SENTINEL | Parsers.DELIMITED
        @test res.tlen == 1
    end
    res = Parsers.xparse(Char, ",,", 2, 2, Parsers.Options(sentinel=missing, delim=delim))
    @test res.code == Parsers.SENTINEL | Parsers.DELIMITED
    @test res.tlen == 1
    res = Parsers.xparse(Char, ",,", 3, 2, Parsers.Options(sentinel=missing, delim=delim))
    @test res.code == Parsers.SENTINEL | Parsers.EOF
    @test res.tlen == 0
end

end # @testset "misc"

include("floats.jl")
include("dates.jl")
include("hexadecimal.jl")


@testset "Aqua.jl" begin
    Aqua.test_all(Parsers)
end

@testset "parse(Number, x)" begin
    @test Parsers.parse(Number, "1") === Int64(1)
    @test Parsers.parse(Number, "1.0") === 1.0
    @test Parsers.parse(Number, "1.0f0") === 1.0f0
    @test Parsers.parse(Number, "1.0e0") === 1.0e0
    @test Parsers.parse(Number, "1.") === 1.0
    @test Parsers.parse(Number, "-1.") === -1.0
    @test Parsers.parse(Number, "9223372036854775807") === 9223372036854775807
    @test Parsers.parse(Number, "170141183460469231731687303715884105727") === 170141183460469231731687303715884105727
    @test Parsers.parse(Number, "0e348") == big"0.0"
    # Int128 literal
    @test Parsers.parse(Number, "9223372036854775808") === 9223372036854775808
    # BigInt
    @test Parsers.parse(Number, "170141183460469231731687303715884105728") == 170141183460469231731687303715884105728
    # BigFloat promotion
    @test Parsers.parse(Number, "1e310") == Base.parse(BigFloat, "1e310")
    @test Parsers.parse(Number, "1.7976931348623157e310") == big"1.7976931348623157e310"
    # error case
    @test_throws Parsers.Error Parsers.parse(Number, "-")
end

# https://github.com/JuliaData/CSV.jl/issues/1063
@testset "Serialization" begin
    tempfile = tempname()
    Serialization.serialize(tempfile, Parsers.Options())
    @test Serialization.deserialize(tempfile).flags == Parsers.Options().flags
end

end # @testset "Parsers"
