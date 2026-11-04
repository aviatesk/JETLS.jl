@testset "Floats" begin

res = Parsers.xparse(Float64, "1x")

testcases = [
    (str="", x=0.0, code=(INVALID | EOF), len=0, tot=0),
    (str="-", x=0.0, code=(INVALID | EOF), len=1, tot=1),
    (str=".", x=0.0, code=(INVALID | EOF), len=1, tot=1),
    (str="1", x=1.0, code=(OK | EOF), len=1, tot=1),
    (str="+1", x=1.0, code=(OK | EOF), len=2, tot=2),
    (str="1.1", x=1.1, code=(OK | EOF), len=3, tot=3),
    (str="1.", x=1.0, code=(OK | EOF), len=2, tot=2),
    (str="-1.", x=-1.0, code=(OK | EOF), len=3, tot=3),
    (str="-1. ", x=-1.0, code=(OK | EOF), len=4, tot=4),
    (str="1.a", x=1.0, code=(OK | EOF | INVALID_DELIMITER), len=2, tot=2),
    (str="1.1.", x=1.1, code=(OK | EOF | INVALID_DELIMITER), len=3, tot=3),
    (str="1e23", x=1e23, code=(OK | EOF), len=4, tot=4),
    (str="1E23", x=1e23, code=(OK | EOF), len=4, tot=4),
    (str="1f23", x=1e23, code=(OK | EOF), len=4, tot=4),
    (str="1F23", x=1e23, code=(OK | EOF), len=4, tot=4),
    (str="428.E+03", x=428000.0, code=(OK | EOF), len=8, tot=8),
    (str="1.0e", x=0.0, code=(INVALID | EOF), len=4, tot=4),
    (str="1.0ea", x=0.0, code=(INVALID | EOF | INVALID_DELIMITER), len=5, tot=5),
    (str="100000000000000000000000", x=1e23, code=(OK | EOF), len=24, tot=24),
    (str="1e-100", x=1e-100, code=(OK | EOF), len=6, tot=6),
    (str="123456700", x=1.234567e+08, code=(OK | EOF), len=9, tot=9),
    (str="99999999999999974834176", x=9.999999999999997e+22, code=(OK | EOF), len=23, tot=23),
    (str="100000000000000000000001", x=1.0000000000000001e+23, code=(OK | EOF), len=24, tot=24),
    (str="100000000000000008388608", x=1.0000000000000001e+23, code=(OK | EOF), len=24, tot=24),
    (str="100000000000000016777215", x=1.0000000000000001e+23, code=(OK | EOF), len=24, tot=24),
    (str="100000000000000016777216", x=1.0000000000000003e+23, code=(OK | EOF), len=0, tot=0),

    (str="-1", x=-1.0, code=(OK | EOF), len=0, tot=0),
    (str="-0.1", x=-0.1, code=(OK | EOF), len=0, tot=0),
    (str="-0", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="1e-20", x=1e-20, code=(OK | EOF), len=0, tot=0),
    (str="625e-3", x=0.625, code=(OK | EOF), len=0, tot=0),

    # zeros
    (str="0", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="0e0", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="-0e0", x=-0.0, code=(OK | EOF), len=0, tot=0),
    (str="+0e0", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="0e-0", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="-0e-0", x=-0.0, code=(OK | EOF), len=0, tot=0),
    (str="+0e-0", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="0e+0", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="-0e+0", x=-0.0, code=(OK | EOF), len=0, tot=0),
    (str="+0e+0", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="0e+01234567890123456789", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="0.00e-01234567890123456789", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="-0e+01234567890123456789", x=-0.0, code=(OK | EOF), len=0, tot=0),
    (str="-0.00e-01234567890123456789", x=-0.0, code=(OK | EOF), len=0, tot=0),
    (str="0e291", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="0e292", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="0e347", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="0e348", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="-0e291", x=-0.0, code=(OK | EOF), len=0, tot=0),
    (str="-0e292", x=-0.0, code=(OK | EOF), len=0, tot=0),
    (str="-0e347", x=-0.0, code=(OK | EOF), len=0, tot=0),
    (str="-0e348", x=-0.0, code=(OK | EOF), len=0, tot=0),

    # Infs/invalid NaNs
    (str="n", x=0.0, code=(INVALID | INVALID_DELIMITER | EOF), len=1, tot=1),
    (str="na", x=0.0, code=(INVALID | INVALID_DELIMITER | EOF), len=2, tot=2),
    (str="n", x=0.0, code=(INVALID | INVALID_DELIMITER | EOF), len=1, tot=1),
    (str="inf", x=Inf, code=(OK | SPECIAL_VALUE | EOF), len=0, tot=0),
    (str="infinity", x=Inf, code=(OK | SPECIAL_VALUE | EOF), len=0, tot=0),
    (str="-inf", x=-Inf, code=(OK | SPECIAL_VALUE | EOF), len=0, tot=0),
    (str="-Inf", x=-Inf, code=(OK | SPECIAL_VALUE | EOF), len=0, tot=0),
    (str="-infinity", x=-Inf, code=(OK | SPECIAL_VALUE | EOF), len=0, tot=0),
    (str="-INFINITY", x=-Inf, code=(OK | SPECIAL_VALUE | EOF), len=0, tot=0),
    (str="+inf", x=Inf, code=(OK | SPECIAL_VALUE | EOF), len=0, tot=0),
    (str="i", x=0.0, code=(INVALID | INVALID_DELIMITER | EOF), len=1, tot=1),
    (str="in", x=0.0, code=(INVALID | INVALID_DELIMITER | EOF), len=2, tot=2),
    (str="infi", x=Inf, code=(OK | SPECIAL_VALUE | EOF), len=1, tot=1),
    (str="infin", x=Inf, code=(OK | SPECIAL_VALUE | EOF), len=1, tot=1),
    (str="infini", x=Inf, code=(OK | SPECIAL_VALUE | EOF), len=1, tot=1),
    (str="infinit", x=Inf, code=(OK | SPECIAL_VALUE | EOF), len=1, tot=1),
    (str="i,", x=0.0, code=(INVALID | DELIMITED | INVALID_DELIMITER), len=1, tot=1),
    (str="in,", x=0.0, code=(INVALID | DELIMITED | INVALID_DELIMITER), len=2, tot=2),
    (str="infi,", x=Inf, code=(OK | SPECIAL_VALUE | DELIMITED), len=1, tot=1),
    (str="infin,", x=Inf, code=(OK | SPECIAL_VALUE | DELIMITED), len=1, tot=1),
    (str="infini,", x=Inf, code=(OK | SPECIAL_VALUE | DELIMITED), len=1, tot=1),
    (str="infinit,", x=Inf, code=(OK | SPECIAL_VALUE | DELIMITED), len=1, tot=1),

    # largest float64
    (str="1.7976931348623157e308", x=1.7976931348623157e+308, code=(OK | EOF), len=0, tot=0),
    (str="-1.7976931348623157e308", x=-1.7976931348623157e+308, code=(OK | EOF), len=0, tot=0),
    # next float64 - too large
    (str="1.7976931348623159e308", x=+Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),
    (str="-1.7976931348623159e308", x=-Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),
    # the border is ...158079
    # borderline - okay
    (str="1.7976931348623158e308", x=1.7976931348623157e+308, code=(OK | EOF), len=0, tot=0),
    (str="-1.7976931348623158e308", x=-1.7976931348623157e+308, code=(OK | EOF), len=0, tot=0),
    # borderline - too large
    (str="1.797693134862315808e308", x=+Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),
    (str="-1.797693134862315808e308", x=-Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),

    # a little too large
    (str="1e308", x=1e+308, code=(OK | EOF), len=0, tot=0),
    (str="2e308", x=+Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),
    (str="1e309", x=+Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),

    # way too large
    (str="1e310", x=+Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),
    (str="-1e310", x=-Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),
    (str="1e400", x=+Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),
    (str="-1e400", x=-Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),
    (str="1e400000", x=+Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),
    (str="-1e400000", x=-Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),

    # denormalized
    (str="1e-305", x=1e-305, code=(OK | EOF), len=0, tot=0),
    (str="1e-306", x=1e-306, code=(OK | EOF), len=0, tot=0),
    (str="1e-307", x=1e-307, code=(OK | EOF), len=0, tot=0),
    (str="1e-308", x=1e-308, code=(OK | EOF), len=0, tot=0),
    (str="1e-309", x=1e-309, code=(OK | EOF), len=0, tot=0),
    (str="1e-310", x=1e-310, code=(OK | EOF), len=0, tot=0),
    (str="1e-322", x=1e-322, code=(OK | EOF), len=0, tot=0),
    # smallest denormal
    (str="5e-324", x=5e-324, code=(OK | EOF), len=0, tot=0),
    (str="4e-324", x=5e-324, code=(OK | EOF), len=0, tot=0),
    (str="3e-324", x=5e-324, code=(OK | EOF), len=0, tot=0),
    # too small
    (str="2e-324", x=0.0, code=(OK | EOF), len=0, tot=0),
    # way too small
    (str="1e-350", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="1e-400000", x=0.0, code=(OK | EOF), len=0, tot=0),

    # try to overflow exponent
    (str="1e-4294967296", x=0.0, code=(OK | EOF), len=0, tot=0),
    (str="1e+4294967296", x=+Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),
    (str="1e-18446744073709551616", x=0.0, code=(OK | EOF), len=0, tot=0),

    (str="1e+18446744073709551616", x=+Inf, code=(OK | EOF | SPECIAL_VALUE), len=0, tot=0),

    # Parse errors
    # (str="1e", x=missing, code=(INVALID | EOF), len=0, tot=0),
    # (str="1e-", x=missing, code=(INVALID | EOF), len=0, tot=0),
    # (str=".e-1", x=missing, code=(INVALID | EOF), len=0, tot=0),
    # (str="1\x00.2", x=1.0, code=(OK), len=0, tot=0),

    # http:#www.exploringbinary.com/java-hangs-when-converting-2-2250738585072012e-308/
    (str="2.2250738585072012e-308", x=2.2250738585072014e-308, code=(OK | EOF), len=0, tot=0),
    # http://www.exploringbinary.com/php-hangs-on-numeric-value-2-2250738585072011e-308/
    (str="2.2250738585072011e-308", x=2.225073858507201e-308, code=(OK | EOF), len=0, tot=0),

    # A very large number (initially wrongly parsed by the fast algorithm).
    (str="4.630813248087435e+307", x=4.630813248087435e+307, code=(OK | EOF), len=0, tot=0),

    # A different kind of very large number.
    (str="22.222222222222222", x=22.22222222222222, code=(OK | EOF), len=0, tot=0),
    # A number that overflows `digits` with the last digit before the decimal.
    (str="3402823669209384634.6", x=3.4028236692093844e18, code=(OK | EOF), len=0, tot=0),

    # Exactly halfway between 1 and math.Nextafter(1, 2).
    # Round to even (down).
    (str="1.00000000000000011102230246251565404236316680908203125", x=1.0, code=(OK | EOF), len=0, tot=0),
    # # Slightly lower; still round down.
    (str="1.00000000000000011102230246251565404236316680908203124", x=1.0, code=(OK | EOF), len=0, tot=0),
    # # Slightly higher; round up.
    (str="1.00000000000000011102230246251565404236316680908203126", x=1.0000000000000002, code=(OK | EOF), len=0, tot=0),

    (str="-5.871153289887625082e-01", x=-5.871153289887625082e-01, code=(OK | EOF), len=0, tot=0),
    (str="8.095032986136727615e-01", x=8.095032986136727615e-01, code=(OK | EOF), len=0, tot=0),
    (str="9.900000000000006573e-01", x=9.900000000000006573e-01, code=(OK | EOF), len=0, tot=0),
    (str="9.900000000000006573e-01", x=9.900000000000006573e-01, code=(OK | EOF), len=0, tot=0),
    (str="-9.866066418838319585e-01", x=-9.866066418838319585e-01, code=(OK | EOF), len=0, tot=0),
    (str="-3.138907529596844714e+00", x=-3.138907529596844714e+00, code=(OK | EOF), len=0, tot=0),
    (str="-5.129218106887371675e+00", x=-5.129218106887371675e+00, code=(OK | EOF), len=0, tot=0),
    (str="-4.803915800699462224e+00", x=-4.803915800699462224e+00, code=(OK | EOF), len=0, tot=0),

    # issue #18
    (str=".24409E+03", x=244.09, code=(OK | EOF), len=0, tot=0),
    (str=".24409E+03 ", x=244.09, code=(OK | EOF), len=0, tot=0),
    (str="-.2", x=-0.2, code=(OK | EOF), len=0, tot=0),
    (str=".2", x=0.2, code=(OK | EOF), len=0, tot=0),

    # from https://www.icir.org/vern/papers/testbase-report.pdf
    (str=string(5.0 * exp10(+125)), x=(5.0 * exp10(+125)), code=(OK | EOF), len=0, tot=0),
    (str=string(69.0 * exp10(+267)), x=(69.0 * exp10(+267)), code=(OK | EOF), len=0, tot=0),
    (str=string(999.0 * exp10(-26)), x=(999.0 * exp10(-26)), code=(OK | EOF), len=0, tot=0),
    (str=string(7861.0 * exp10(-34)), x=(7861.0 * exp10(-34)), code=(OK | EOF), len=0, tot=0),
    (str=string(75569.0 * exp10(-254)), x=(75569.0 * exp10(-254)), code=(OK | EOF), len=0, tot=0),
    (str=string(928609.0 * exp10(-261)), x=(928609.0 * exp10(-261)), code=(OK | EOF), len=0, tot=0),
    (str=string(9210917.0 * exp10(+80)), x=(9210917.0 * exp10(+80)), code=(OK | EOF), len=0, tot=0),
    (str=string(84863171.0 * exp10(+114)), x=(84863171.0 * exp10(+114)), code=(OK | EOF), len=0, tot=0),
    (str=string(653777767.0 * exp10(+273)), x=(653777767.0 * exp10(+273)), code=(OK | EOF), len=0, tot=0),
    (str=string(5232604057.0 * exp10(-298)), x=(5232604057.0 * exp10(-298)), code=(OK | EOF), len=0, tot=0),
    (str=string(27235667517.0 * exp10(-109)), x=(27235667517.0 * exp10(-109)), code=(OK | EOF), len=0, tot=0),
    (str=string(653532977297.0 * exp10(-123)), x=(653532977297.0 * exp10(-123)), code=(OK | EOF), len=0, tot=0),
    (str=string(3142213164987.0 * exp10(-294)), x=(3142213164987.0 * exp10(-294)), code=(OK | EOF), len=0, tot=0),
    (str=string(46202199371337.0 * exp10(-72)), x=(46202199371337.0 * exp10(-72)), code=(OK | EOF), len=0, tot=0),
    (str=string(231010996856685.0 * exp10(-73)), x=(231010996856685.0 * exp10(-73)), code=(OK | EOF), len=0, tot=0),
    (str=string(9324754620109615.0 * exp10(+212)), x=(9324754620109615.0 * exp10(+212)), code=(OK | EOF), len=0, tot=0),
    (str=string(78459735791271921.0 * exp10(+49)), x=(78459735791271921.0 * exp10(+49)), code=(OK | EOF), len=0, tot=0),
    (str=string(272104041512242479.0 * exp10(+200)), x=(272104041512242479.0 * exp10(+200)), code=(OK | EOF), len=0, tot=0),
    (str=string(6802601037806061975.0 * exp10(+198)), x=(6802601037806061975.0 * exp10(+198)), code=(OK | EOF), len=0, tot=0),
    (str=string(20505426358836677347.0 * exp10(-221)), x=(20505426358836677347.0 * exp10(-221)), code=(OK | EOF), len=0, tot=0),
    (str=string(836168422905420598437.0 * exp10(-234)), x=(836168422905420598437.0 * exp10(-234)), code=(OK | EOF), len=0, tot=0),
    (str=string(4891559871276714924261.0 * exp10(+222)), x=(4891559871276714924261.0 * exp10(+222)), code=(OK | EOF), len=0, tot=0),

    (str=string(9.0 * exp10(-265)), x=(9.0 * exp10(-265)), code=(OK | EOF), len=0, tot=0),
    (str=string(85.0 * exp10(-037)), x=(85.0 * exp10(-037)), code=(OK | EOF), len=0, tot=0),
    (str=string(623.0 * exp10(+100)), x=(623.0 * exp10(+100)), code=(OK | EOF), len=0, tot=0),
    (str=string(3571.0 * exp10(+263)), x=(3571.0 * exp10(+263)), code=(OK | EOF), len=0, tot=0),
    (str=string(81661.0 * exp10(+153)), x=(81661.0 * exp10(+153)), code=(OK | EOF), len=0, tot=0),
    (str=string(920657.0 * exp10(-023)), x=(920657.0 * exp10(-023)), code=(OK | EOF), len=0, tot=0),
    (str=string(4603285.0 * exp10(-024)), x=(4603285.0 * exp10(-024)), code=(OK | EOF), len=0, tot=0),
    (str=string(87575437.0 * exp10(-309)), x=(87575437.0 * exp10(-309)), code=(OK | EOF), len=0, tot=0),
    (str=string(245540327.0 * exp10(+122)), x=(245540327.0 * exp10(+122)), code=(OK | EOF), len=0, tot=0),
    (str=string(6138508175.0 * exp10(+120)), x=(6138508175.0 * exp10(+120)), code=(OK | EOF), len=0, tot=0),
    (str=string(83356057653.0 * exp10(+193)), x=(83356057653.0 * exp10(+193)), code=(OK | EOF), len=0, tot=0),
    (str=string(619534293513.0 * exp10(+124)), x=(619534293513.0 * exp10(+124)), code=(OK | EOF), len=0, tot=0),
    (str=string(2335141086879.0 * exp10(+218)), x=(2335141086879.0 * exp10(+218)), code=(OK | EOF), len=0, tot=0),
    (str=string(36167929443327.0 * exp10(-159)), x=(36167929443327.0 * exp10(-159)), code=(OK | EOF), len=0, tot=0),
    (str=string(609610927149051.0 * exp10(-255)), x=(609610927149051.0 * exp10(-255)), code=(OK | EOF), len=0, tot=0),
    (str=string(3743626360493413.0 * exp10(-165)), x=(3743626360493413.0 * exp10(-165)), code=(OK | EOF), len=0, tot=0),
    (str=string(94080055902682397.0 * exp10(-242)), x=(94080055902682397.0 * exp10(-242)), code=(OK | EOF), len=0, tot=0),
    (str=string(899810892172646163.0 * exp10(+283)), x=(899810892172646163.0 * exp10(+283)), code=(OK | EOF), len=0, tot=0),
    (str=string(7120190517612959703.0 * exp10(+120)), x=(7120190517612959703.0 * exp10(+120)), code=(OK | EOF), len=0, tot=0),
    (str=string(25188282901709339043.0 * exp10(-252)), x=(25188282901709339043.0 * exp10(-252)), code=(OK | EOF), len=0, tot=0),
    (str=string(308984926168550152811.0 * exp10(-052)), x=(308984926168550152811.0 * exp10(-052)), code=(OK | EOF), len=0, tot=0),
    (str=string(6372891218502368041059.0 * exp10(+064)), x=(6372891218502368041059.0 * exp10(+064)), code=(OK | EOF), len=0, tot=0),

    (str=string(8511030020275656.0 * exp2(-0342)), x=(8511030020275656.0 * exp2(-0342)), code=(OK | EOF), len=0, tot=0),
    (str=string(5201988407066741.0 * exp2(-0824)), x=(5201988407066741.0 * exp2(-0824)), code=(OK | EOF), len=0, tot=0),
    (str=string(6406892948269899.0 * exp2(+0237)), x=(6406892948269899.0 * exp2(+0237)), code=(OK | EOF), len=0, tot=0),
    (str=string(8431154198732492.0 * exp2(+0072)), x=(8431154198732492.0 * exp2(+0072)), code=(OK | EOF), len=0, tot=0),
    (str=string(6475049196144587.0 * exp2(+0099)), x=(6475049196144587.0 * exp2(+0099)), code=(OK | EOF), len=0, tot=0),
    (str=string(8274307542972842.0 * exp2(+0726)), x=(8274307542972842.0 * exp2(+0726)), code=(OK | EOF), len=0, tot=0),
    (str=string(5381065484265332.0 * exp2(-0456)), x=(5381065484265332.0 * exp2(-0456)), code=(OK | EOF), len=0, tot=0),
    (str=string(6761728585499734.0 * exp2(-1057)), x=(6761728585499734.0 * exp2(-1057)), code=(OK | EOF), len=0, tot=0),
    (str=string(7976538478610756.0 * exp2(+0376)), x=(7976538478610756.0 * exp2(+0376)), code=(OK | EOF), len=0, tot=0),
    (str=string(5982403858958067.0 * exp2(+0377)), x=(5982403858958067.0 * exp2(+0377)), code=(OK | EOF), len=0, tot=0),
    (str=string(5536995190630837.0 * exp2(+0093)), x=(5536995190630837.0 * exp2(+0093)), code=(OK | EOF), len=0, tot=0),
    (str=string(7225450889282194.0 * exp2(+0710)), x=(7225450889282194.0 * exp2(+0710)), code=(OK | EOF), len=0, tot=0),
    (str=string(7225450889282194.0 * exp2(+0709)), x=(7225450889282194.0 * exp2(+0709)), code=(OK | EOF), len=0, tot=0),
    (str=string(8703372741147379.0 * exp2(+0117)), x=(8703372741147379.0 * exp2(+0117)), code=(OK | EOF), len=0, tot=0),
    (str=string(8944262675275217.0 * exp2(-1001)), x=(8944262675275217.0 * exp2(-1001)), code=(OK | EOF), len=0, tot=0),
    (str=string(7459803696087692.0 * exp2(-0707)), x=(7459803696087692.0 * exp2(-0707)), code=(OK | EOF), len=0, tot=0),
    (str=string(6080469016670379.0 * exp2(-0381)), x=(6080469016670379.0 * exp2(-0381)), code=(OK | EOF), len=0, tot=0),
    (str=string(8385515147034757.0 * exp2(+0721)), x=(8385515147034757.0 * exp2(+0721)), code=(OK | EOF), len=0, tot=0),
    (str=string(7514216811389786.0 * exp2(-0828)), x=(7514216811389786.0 * exp2(-0828)), code=(OK | EOF), len=0, tot=0),
    (str=string(8397297803260511.0 * exp2(-0345)), x=(8397297803260511.0 * exp2(-0345)), code=(OK | EOF), len=0, tot=0),
    (str=string(6733459239310543.0 * exp2(+0202)), x=(6733459239310543.0 * exp2(+0202)), code=(OK | EOF), len=0, tot=0),
    (str=string(8091450587292794.0 * exp2(-0473)), x=(8091450587292794.0 * exp2(-0473)), code=(OK | EOF), len=0, tot=0),

    (str=string(6567258882077402.0 * exp2(+952)), x=(6567258882077402.0 * exp2(+952)), code=(OK | EOF), len=0, tot=0),
    (str=string(6712731423444934.0 * exp2(+535)), x=(6712731423444934.0 * exp2(+535)), code=(OK | EOF), len=0, tot=0),
    (str=string(6712731423444934.0 * exp2(+534)), x=(6712731423444934.0 * exp2(+534)), code=(OK | EOF), len=0, tot=0),
    (str=string(5298405411573037.0 * exp2(-957)), x=(5298405411573037.0 * exp2(-957)), code=(OK | EOF), len=0, tot=0),
    (str=string(5137311167659507.0 * exp2(-144)), x=(5137311167659507.0 * exp2(-144)), code=(OK | EOF), len=0, tot=0),
    (str=string(6722280709661868.0 * exp2(+363)), x=(6722280709661868.0 * exp2(+363)), code=(OK | EOF), len=0, tot=0),
    (str=string(5344436398034927.0 * exp2(-169)), x=(5344436398034927.0 * exp2(-169)), code=(OK | EOF), len=0, tot=0),
    (str=string(8369123604277281.0 * exp2(-853)), x=(8369123604277281.0 * exp2(-853)), code=(OK | EOF), len=0, tot=0),
    (str=string(8995822108487663.0 * exp2(-780)), x=(8995822108487663.0 * exp2(-780)), code=(OK | EOF), len=0, tot=0),
    (str=string(8942832835564782.0 * exp2(-383)), x=(8942832835564782.0 * exp2(-383)), code=(OK | EOF), len=0, tot=0),
    (str=string(8942832835564782.0 * exp2(-384)), x=(8942832835564782.0 * exp2(-384)), code=(OK | EOF), len=0, tot=0),
    (str=string(8942832835564782.0 * exp2(-385)), x=(8942832835564782.0 * exp2(-385)), code=(OK | EOF), len=0, tot=0),
    (str=string(6965949469487146.0 * exp2(-249)), x=(6965949469487146.0 * exp2(-249)), code=(OK | EOF), len=0, tot=0),
    (str=string(6965949469487146.0 * exp2(-250)), x=(6965949469487146.0 * exp2(-250)), code=(OK | EOF), len=0, tot=0),
    (str=string(6965949469487146.0 * exp2(-251)), x=(6965949469487146.0 * exp2(-251)), code=(OK | EOF), len=0, tot=0),
    (str=string(7487252720986826.0 * exp2(+548)), x=(7487252720986826.0 * exp2(+548)), code=(OK | EOF), len=0, tot=0),
    (str=string(5592117679628511.0 * exp2(+164)), x=(5592117679628511.0 * exp2(+164)), code=(OK | EOF), len=0, tot=0),
    (str=string(8887055249355788.0 * exp2(+665)), x=(8887055249355788.0 * exp2(+665)), code=(OK | EOF), len=0, tot=0),
    (str=string(6994187472632449.0 * exp2(+690)), x=(6994187472632449.0 * exp2(+690)), code=(OK | EOF), len=0, tot=0),
    (str=string(8797576579012143.0 * exp2(+588)), x=(8797576579012143.0 * exp2(+588)), code=(OK | EOF), len=0, tot=0),
    (str=string(7363326733505337.0 * exp2(+272)), x=(7363326733505337.0 * exp2(+272)), code=(OK | EOF), len=0, tot=0),
    (str=string(8549497411294502.0 * exp2(-448)), x=(8549497411294502.0 * exp2(-448)), code=(OK | EOF), len=0, tot=0),

    # from lemire's test suite
    (str="7.3177701707893310e+15", x=7.3177701707893310e+15, code=(OK | EOF), len=0, tot=0),
    (str="9007199254740995", x=9.007199254740996e15, code=(OK | EOF), len=0, tot=0),
    (str="7e23", x=7e23, code=(OK | EOF), len=0, tot=0),
    (str="-65.613616999999977", x=-65.613616999999977, code=(OK | EOF), len=0, tot=0),
    (str="7.2057594037927933e+16", x=7.2057594037927933e+16, code=(OK | EOF), len=0, tot=0),
    (str="0.1e-308", x=0.1e-308, code=(OK | EOF), len=0, tot=0),
    (str="0.01e-307", x=0.01e-307, code=(OK | EOF), len=0, tot=0),
    (str="1.79769e+308", x=1.79769e+308, code=(OK | EOF), len=0, tot=0),
    (str="2.22507e-308", x=2.22507e-308, code=(OK | EOF), len=0, tot=0),
    (str="-1.79769e+308", x=-1.79769e+308, code=(OK | EOF), len=0, tot=0),
    (str="-2.22507e-308", x=-2.22507e-308, code=(OK | EOF), len=0, tot=0),
];

for useio in (false, true)
    for (i, case) in enumerate(testcases)
        # println("testing case = $i, str = $(case.str)")
        res = Parsers.xparse(Float64, useio ? IOBuffer(case.str) : case.str)
        x, code, tlen = res.val, res.code, res.tlen
        if !Parsers.invalid(code)
            @test x == case.x
        end
        @test code == case.code
    end
end

# NaNs
case = (str="nan", x=NaN, code=(OK | SPECIAL_VALUE | EOF), len=3, tot=3)
res = Parsers.xparse(Float64, case.str)
x, code, tlen = res.val, res.code, res.tlen
@test isnan(x)
@test code == case.code
@test tlen == 3
case = (str="NaN", x=NaN, code=(OK | SPECIAL_VALUE | EOF), len=3, tot=3)
res = Parsers.xparse(Float64, case.str)
x, code, tlen = res.val, res.code, res.tlen
@test isnan(x)
@test code == case.code
@test tlen == 3
case = (str="NAN", x=NaN, code=(OK | SPECIAL_VALUE | EOF), len=3, tot=3)
res = Parsers.xparse(Float64, case.str)
x, code, tlen = res.val, res.code, res.tlen
@test isnan(x)
@test code == case.code
@test tlen == 3
case = (str="nAN", x=NaN, code=(OK | SPECIAL_VALUE | EOF), len=3, tot=3)
res = Parsers.xparse(Float64, case.str)
x, code, tlen = res.val, res.code, res.tlen
@test isnan(x)
@test code == case.code
@test tlen == 3
case = (str="nAN,", x=NaN, code=(OK | SPECIAL_VALUE | DELIMITED), len=4, tot=4)
res = Parsers.xparse(Float64, case.str)
x, code, tlen = res.val, res.code, res.tlen
@test isnan(x)
@test code == case.code
@test tlen == 4

# #25
case = (str="74810199.033988851037472901827191090834", x=7.481019903398885e7, code=(OK | EOF))
res = Parsers.xparse(Float64, case.str)
x, code, tlen = res.val, res.code, res.tlen
@test x == case.x
@test code == case.code
@test tlen == 39

# https://github.com/quinnj/JSON3.jl/issues/57: a huge integer part overflows
# like `1e2000` does, and each digit past the first 19 costs O(1)
@test Parsers.parse(Float64, join(rand(1:9, 2000), "")) === Inf
@test Parsers.parse(Float64, "1" * "0"^2000 * "e-2000") === 1.0
@test Parsers.parse(BigFloat, "3.14") == BigFloat("3.14")
@test Parsers.parse(BigFloat, "3.14 ") == BigFloat("3.14")

# https://github.com/JuliaData/Parsers.jl/issues/53
bytes = codeunits("a,b,c\n.,1,3")
res = Parsers.xparse(Float64, bytes, 7, 11)
x, code, tlen = res.val, res.code, res.tlen
@test code == (INVALID | DELIMITED)

# https://github.com/JuliaData/CSV.jl/issues/710
# problematic really small floats on various threshold boundaries
@test Parsers.parse(Float64, "9.88e-324") === 1.0e-323
@test Parsers.parse(Float64, "4.94e-324") === 5.0e-324
@test Parsers.parse(Float64, "8.40e-323") === 8.4e-323
@test Parsers.parse(Float64, "3091.") === 3091.0

# https://github.com/JuliaData/CSV.jl/issues/769
@test Parsers.parse(Float64, "9223372036854775808") === 9.223372036854776e18

# random sampling of Float16 testing
for _ = 1:1000
    x = rand(Float16)
    str = string(x)
    @test Base.parse(Float16, str) === Parsers.parse(Float16, str)
end

# discovered from JSON tests
@test Parsers.tryparse(Float64, "0e+") === nothing

# Mantissas with more than 19 significant digits keep their leading digits and
# re-read the token when the dropped digits decide the rounding.
@testset "long mantissa / negative zero" begin
    oracle(::Type{T}, str) where {T} = setprecision(
        BigFloat, max(512, 4 * sizeof(str) + 256)) do
        T(Base.parse(BigFloat, str))
    end
    # Julia 1.6 converts BigFloat to Float16 through Float64, which double-rounds:
    # pick the nearest Float16 to the high-precision value directly (ties to even).
    oracle(::Type{Float16}, str) = setprecision(
        BigFloat, max(512, 4 * sizeof(str) + 256)) do
        x = Base.parse(BigFloat, str)
        abs(x) >= 65520 && return x < 0 ? -Inf16 : Inf16  # floatmax + ulp/2 rounds to Inf
        best = Float16(Float64(x))                         # within one ulp
        for c in (prevfloat(best), nextfloat(best))
            isfinite(c) || continue
            d, dbest = abs(BigFloat(c) - x), abs(BigFloat(best) - x)
            if d < dbest || (d == dbest && iseven(reinterpret(UInt16, c)))
                best = c
            end
        end
        return best
    end

    function test_float_apis(::Type{T}, str) where {T}
        expected = oracle(T, str)
        eof_code = isinf(expected) ? (OK | SPECIAL_VALUE | EOF) : (OK | EOF)
        delimited_code = isinf(expected) ?
            (OK | SPECIAL_VALUE | DELIMITED) : (OK | DELIMITED)

        @test Parsers.parse(T, str) === expected

        res = Parsers.xparse2(T, str, 1, sizeof(str))
        @test res.val === expected
        @test res.code == eof_code
        @test res.tlen == sizeof(str)

        res = Parsers.xparse(T, Vector{UInt8}(codeunits(str)))
        @test res.val === expected
        @test res.code == eof_code
        @test res.tlen == sizeof(str)

        res = Parsers.xparse(T, str * ",")
        @test res.val === expected
        @test res.code == delimited_code
        @test res.tlen == sizeof(str) + 1
        return nothing
    end

    function terminating_decimal(q::Rational{BigInt})
        # BigInt is mutable, so copy both fields before reducing the denominator.
        numerator = BigInt(Base.numerator(q))
        denominator = BigInt(Base.denominator(q))
        neg = numerator < 0
        numerator = abs(numerator)
        twos = 0
        fives = 0
        while iseven(denominator)
            denominator >>= 1
            twos += 1
        end
        while denominator % 5 == 0
            denominator ÷= 5
            fives += 1
        end
        @assert denominator == 1

        places = max(twos, fives)
        scaled = numerator * BigInt(2)^(places - twos) * BigInt(5)^(places - fives)
        digits = string(scaled)
        body = if places == 0
            digits
        elseif length(digits) <= places
            "0." * repeat("0", places - length(digits)) * digits
        else
            point = length(digits) - places
            digits[1:point] * "." * digits[point+1:end]
        end
        return neg ? "-" * body : body
    end

    float16_digit_limit_case = "-773185451005006305224330936226383685.195e3"
    testcases = [
        # BigInt digits must not be converted back to UInt128 for extreme exponents.
        ("295574326048237151328925.8099133506971425945276929554326e-440", 0.0, (Float16, Float32, Float64)),
        ("-645846793726181672171.9101155724413627413656362746354480124e-379", -0.0, (Float16, Float32, Float64)),
        # A zero scale must not index the power-of-ten table at zero.
        (float16_digit_limit_case, -7.731854510050064e38, (Float32, Float64)),
        # The UInt128 product wrapped when it was computed before the bounds check.
        ("0.72741733550162454424961322208253163690E+61", 7.274173355016246e60, (Float16, Float32, Float64)),
        ("4503599627370496e23", 4.503599627370496e38, (Float16, Float32, Float64)),
        # Fixed 256-bit intermediates can double-round longer values.
        ("100000000000000011102230246251565404236316680908203125000000000000000000000000001e-80", 1.0000000000000002, (Float32, Float64)),
        # Preserve the sign when a zero takes a non-fast scaling path.
        ("-0e291", -0.0, (Float16, Float32, Float64)),
        ("-0e347", -0.0, (Float16, Float32, Float64)),
        ("-0.0e100", -0.0, (Float16, Float32, Float64)),
        ("-0e23", -0.0, (Float16, Float32, Float64)),
        ("-0e-23", -0.0, (Float16, Float32, Float64)),
    ]
    for (str, expected64, types) in testcases
        @test expected64 === oracle(Float64, str)
        for T in types
            test_float_apis(T, str)
        end
    end

    # Float16 has no significant-digit limit (it rejected more than 29 digits).
    test_float_apis(Float16, float16_digit_limit_case)
    test_float_apis(Float16, "1" * "0"^30 * "e-30")

    # Check exact midpoints and one decimal unit on each side. The longest cases
    # reach each parser's significant-digit limit.
    midpoint_cases = (
        (Float16, "1.00048828125", (28,)),
        (Float32, "1.000000059604644775390625", (100, 153)),
        (Float64, "1.00000000000000011102230246251565404236316680908203125", (80, 1078)),
    )
    for (T, midpoint, fractional_lengths) in midpoint_cases
        whole, fraction = split(midpoint, '.')
        midpoint_integer = Base.parse(BigInt, whole * fraction)
        for fractional_length in fractional_lengths
            scaled_midpoint = midpoint_integer * BigInt(10)^(fractional_length - length(fraction))
            for delta in (-1, 0, 1)
                digits = lpad(string(scaled_midpoint + delta), fractional_length + 1, '0')
                test_float_apis(T, string(digits[1], '.', digits[2:end]))
            end
        end
    end

    # Exercise the adaptive BigInt precision at the three IEEE rounding edges.
    @testset "extreme midpoints" begin
        for T in (Float16, Float32, Float64)
            rational(x) = Rational{BigInt}(x)
            zero_midpoint = (rational(zero(T)) + rational(nextfloat(zero(T)))) // 2
            normal_midpoint =
                (rational(prevfloat(floatmin(T))) + rational(floatmin(T))) // 2
            overflow_midpoint = rational(floatmax(T)) +
                rational(floatmax(T) - prevfloat(floatmax(T))) // 2
            for midpoint in (zero_midpoint, normal_midpoint, overflow_midpoint)
                decimal_order = setprecision(BigFloat, 4096) do
                    value = BigFloat(Base.numerator(midpoint)) /
                        BigFloat(Base.denominator(midpoint))
                    floor(Int, log10(value))
                end
                # the old per-type significant-digit limits
                digit_count = T === Float16 ? 29 : T === Float32 ? 154 : 1079
                unit_exponent = decimal_order - digit_count + 1
                unit = unit_exponent < 0 ?
                    1 // BigInt(10)^(-unit_exponent) :
                    BigInt(10)^unit_exponent // 1
                for delta in (-1, 0, 1)
                    test_float_apis(T, terminating_decimal(midpoint + delta * unit))
                end
            end
        end
    end

    # A negative value rounds like its magnitude, also when the token needs more
    # than the default BigFloat precision to tell it from a midpoint of `T`.
    @testset "negative long tokens" begin
        for (T, s) in ((Float16, "65519." * "9"^90), (Float32, "16777218." * "9"^80),
                       (Float64, "9007199254740994." * "9"^80))
            test_float_apis(T, s)
            test_float_apis(T, "-" * s)
            @test Parsers.parse(T, "-" * s) === -Parsers.parse(T, s)
        end
    end

    # Boundaries of the old UInt128 scaling: Clinger's exact range and the
    # largest products that fit in UInt128.
    @testset "UInt128 scale boundaries" begin
        maxsig(::Type{Float16}) = 2048
        maxsig(::Type{Float32}) = 16777216
        maxsig(::Type{Float64}) = 9007199254740992
        for T in (Float16, Float32, Float64)
            sig = UInt128(maxsig(T))
            for v in (sig - 1, sig, sig + 1),
                    exp in (-23, -22, 0, 22, 23), neg in (false, true)
                test_float_apis(T, string(neg ? "-" : "", v, "e", exp))
            end
            for exp in (0, 1, 18, 38)
                p = UInt128(10)^exp
                largest_exact_product = typemax(UInt128) ÷ p
                values = exp == 0 ?
                    (largest_exact_product,) :
                    (largest_exact_product, largest_exact_product + 1)
                for v in values, neg in (false, true)
                    test_float_apis(T, string(neg ? "-" : "", v, "e", exp))
                end
            end
        end
    end

    function random_decimal(rng, digit_range, exponent_range)
        digit_count = rand(rng, digit_range)
        digits = string(
            rand(rng, '1':'9'), join(rand(rng, '0':'9', digit_count - 1)))
        point = rand(rng, 0:digit_count)
        mantissa = point == 0 ?
            "0." * digits : point == digit_count ?
            digits : digits[1:point] * "." * digits[point+1:end]
        return string(
            rand(rng, ("", "-")), mantissa, "e", rand(rng, exponent_range))
    end

    # Keep the fixed-seed regression sample, then extend it past 256 bits.
    rng = Random.MersenneTwister(2024)
    for _ = 1:300
        test_float_apis(Float64, random_decimal(rng, 20:60, -400:400))
    end
    for _ = 1:100
        test_float_apis(Float64, random_decimal(rng, 61:300, -500:500))
    end
end

# Function barrier: `@allocated` at the top level of a large testset compiles it whole.
parse_allocations(::Type{T}, s) where {T} = @allocated Parsers.parse(T, s)

@testset "correctly rounded conversion" begin
    # 17-19 significant digits: Float16/Float32 do not round through Float64 first
    for (T, s, x) in ((Float16, "65519.999999999999", Float16(65504)),
                      (Float16, "14580.00000000000001", Float16(14584)),
                      (Float16, "1035.4999999999999", Float16(1035)),
                      (Float16, "21.35156250000000001", Float16(21.36)),
                      (Float32, "2036288832.0000001", 2.0362889f9),
                      (Float32, "1028510818762751.99", 1.0285108f15))
        @test Parsers.parse(T, s) === x
        @test Parsers.parse(T, "-" * s) === -x
    end
    # exact halfway values round to even
    @test Parsers.parse(Float64, "4503599627370497.5") === 4.503599627370498e15
    @test Parsers.parse(Float64, "-3510816076722765.75") === -3.510816076722766e15
    @test Parsers.parse(Float64, "604312879473319.4375") === 6.043128794733195e14
    # the midpoint between 0 and the smallest Float16 subnormal, and just above it
    @test Parsers.parse(Float16, "2.98023223876953125e-8") === Float16(0)
    @test Parsers.parse(Float16, "2.98023223876953126e-8") === nextfloat(Float16(0))
    # 10^-326 came from the 10^-325 table row, so this was 10 times too large
    @test Parsers.parse(Float64, "5.61951895628169542e-309") === 5.6195189562817e-309
    @test Parsers.parse(Float64, "513947498307927562e-326") === 5.139474983079273e-309
    # exponents of 2^63 or more saturate instead of wrapping around
    @test Parsers.parse(Float64, "1e9223372036854775808") === Inf
    @test Parsers.parse(Float64, "-1e9223372036854775808") === -Inf
    @test Parsers.parse(Float64, "1e-9223372036854775809") === 0.0
    @test Parsers.parse(Float32, "7.4e-9223372036854775808") === 0.0f0
    @test Parsers.parse(Float16, "1e18446744073709551617") === Inf16
    # no significant-digit limit (Float16 rejected integer parts past 29 digits)
    @test Parsers.parse(Float16, "1" * "0"^30 * "e-30") === Float16(1)
    @test Parsers.parse(Float32, "1" * "0"^160 * "e-160") === 1.0f0
    # digits past the first 19 cost O(1) each and allocate nothing (a BigInt
    # accumulator allocated about 1 MB for this token and took quadratic time)
    for T in (Float16, Float32, Float64)
        long = "0." * "1"^100_000
        @test Parsers.parse(T, long) === T(0.1111111111111111)
        parse_allocations(T, long)
        @test parse_allocations(T, long) < 10_000
    end
    # `Number` floats too, once their digits follow a decimal point
    long = "0." * "1"^100_000
    @test Parsers.parse(Number, long) === 0.1111111111111111
    parse_allocations(Number, long)
    @test parse_allocations(Number, long) < 10_000
    @test Parsers.parse(Number, "123456789012345678901234567890." * "9"^50) === 1.2345678901234568e29
    # ...while `Number` integers keep every digit, also next to a delimiter
    for s in ("922337203685477580", "12345678901234567890", "1" * "0"^50)
        @test Parsers.xparse(Number, s * ",").val == Base.parse(BigInt, s)
        @test Parsers.xparse(Number, s * ",").val isa Integer
    end
    # `scale`, the hook that parsers built on `parsedigits` extend, called with
    # exact digits: the conversion re-reads the decimal `v`e`exp` when it must
    for (v, e, T, x) in ((UInt64(45035996273704975), -1, Float64, 4.503599627370498e15),
                         (UInt64(65519999999999999), -12, Float16, Float16(65504)),
                         (big(10)^40 * 3 + 1, -40, Float32, 3.0f0),
                         (UInt64(1), 9223372036854775807, Float64, Inf))
        for neg in (false, true)
            @test Parsers.scale(Parsers.DefaultConf{T}(), Parsers.FLOAT64, v, e, neg,
                                Int16(0), 0, nothing, Parsers.OPTIONS)[1] === (neg ? -x : x)
        end
    end
end

# The midpoint between `x` and the next value up, as an integer `n` scaled by
# 10^-f. Above floatmax the next value is floatmax plus one ulp, the overflow
# threshold.
function sdc_midpoint(x::T) where {T <: AbstractFloat}
    lo = Rational{BigInt}(x)
    hi = isfinite(nextfloat(x)) ? Rational{BigInt}(nextfloat(x)) :
                                  2lo - Rational{BigInt}(prevfloat(x))
    q = (lo + hi) // 2
    f = trailing_zeros(denominator(q))     # q = n / 2^f = n * 5^f / 10^f
    return numerator(q) * big(5)^f, f
end
sdc_decimal(n::BigInt, f::Int) =
    (s = lpad(string(n), f + 1, '0'); s[1:end-f] * "." * s[end-f+1:end])

# Cost of the simple-decimal-conversion tier against the fast path on the same
# digits, measured in one process, so code coverage and the machine slow both
# sides alike. The slow tokens have 22 digits next to a Float64 rounding
# boundary at large exponents; at these smaller exponents Eisel-Lemire decides
# the same digits. Scaling by many bits per pass keeps the ratio in the
# hundreds; one bit per pass puts it above 10,000.
function sdc_cost_ratio()
    slow = ("1.000000000000000126855e300", "1.000000000000000107949e-300",
            "2.500000000000000100292e-200")
    fast = ("1.000000000000000126855e30", "1.000000000000000107949e-30",
            "2.500000000000000100292e-20")
    run(toks, n) = for _ in 1:n, t in toks; Parsers.parse(Float64, t); end
    run(slow, 1); run(fast, 1)
    tslow = minimum(@elapsed(run(slow, 100)) for _ in 1:3) / 100
    tfast = minimum(@elapsed(run(fast, 10_000)) for _ in 1:3) / 10_000
    return tslow / tfast
end

# HPD digits d₁…dₙ and point dp hold 0.d₁…dₙ × 10^dp.
function sdc_hpd(digits::AbstractString, dp::Int)
    d = zeros(UInt8, Parsers.SDC_MAXDIG)
    for (k, c) in enumerate(digits)
        d[k] = UInt8(c - '0')
    end
    return Parsers.HPD(d, length(digits), dp, false)
end
sdc_value(h) = h.n == 0 ? big(0) // 1 :
    parse(BigInt, String(h.d[1:h.n] .+ UInt8('0'))) * (big(10)^max(h.dp, 0) // big(10)^(h.n - min(h.dp, 0)))

@testset "simple decimal conversion: binary shifts" begin
    rng = Random.MersenneTwister(0x5dc)
    for k in 1:Parsers._SDC_MAXSHIFT
        @test Parsers._pow5decimal(k) == reverse(digits(UInt8, big(5)^k))
        # digits equal to, just below and just above those of 5^k decide how many
        # digits a left shift adds
        p = big(5)^k
        for s in (string(p), string(p - 1), string(p + 1), "1", "9",
                  string(rand(rng, 1:9)) * String(rand(rng, '0':'9', rand(rng, 0:60))))
            s = rstrip(s, '0')
            for dp in (-3, 0, 2)
                h = sdc_hpd(s, dp)
                v = sdc_value(h)
                Parsers._hpdleftshift!(h, k)
                @test sdc_value(h) == v * big(2)^k
                @test h.d[1] != 0 && h.d[h.n] != 0 && !h.sticky
                h = sdc_hpd(s, dp)
                Parsers._hpdrightshift!(h, k)
                @test sdc_value(h) == v / big(2)^k
                @test h.d[1] != 0 && h.d[h.n] != 0 && !h.sticky
            end
        end
    end
    # zero stays zero
    h = sdc_hpd("", 0)
    Parsers._hpdrightshift!(h, 7)
    @test h.n == 0 && h.dp == 0
end

@testset "simple decimal conversion tier" begin
    # Midpoints between neighbours that only the exact tier can separate: long
    # tokens (past the 256-bit comparison) and short ones at large exponents.
    for T in (Float16, Float32, Float64)
        for x in (zero(T), nextfloat(zero(T)), prevfloat(floatmin(T)), floatmin(T),
                  T(3) * floatmin(T), floatmax(T) / T(3), prevfloat(floatmax(T)), floatmax(T))
            next = isfinite(nextfloat(x)) ? nextfloat(x) : T(Inf)
            tie = iseven(reinterpret(Unsigned, x)) ? x : next
            n, f = sdc_midpoint(x)
            p = big(10)^100
            cases = [sdc_decimal(n, f) => tie,
                     sdc_decimal(n * p + 1, f + 100) => next,
                     sdc_decimal(n * p - 1, f + 100) => x]
            if T === Float64 && !iszero(x)
                # 22 significant digits, truncated below the midpoint and one unit above it
                digits = string(n)
                cut = parse(BigInt, digits[1:22])
                e = length(digits) - 22 - f
                push!(cases, string(cut, "e", e) => x, string(cut + 1, "e", e) => next)
            end
            for (tok, want) in cases
                buf = Vector{UInt8}(tok)
                @test Parsers.parse(T, tok) === want
                @test Parsers._sdc(T, buf, 1, length(buf), false, UInt8('.')) === want
                @test Parsers._sdc(T, buf, 1, length(buf), true, UInt8('.')) === -want
            end
        end
    end
    # The bound is calibrated on 64-bit hosts.
    Sys.WORD_SIZE == 64 && @test sdc_cost_ratio() < 1000
end

@testset "non-seekable IO sources" begin
    # These need the exact tier. An IO can't be read twice, so the parser keeps
    # the digits of an IO token.
    toks = ("1.00000000000000011102230246251565404236316680908203125",
            "1.00000000000000011102230246251565404236316680908203126",
            "1.000000000000000126855e300", "65519.999999999999",
            "1.000000059604644775390625", "-1.000000059604644775390625" * "0"^300 * "1",
            "0." * "1"^5000, "1" * "0"^400, "4503599627370497.5", "0.1")
    sources = (s -> (io = PipeBuffer(); write(io, s); io),
               s -> (io = Base.BufferStream(); write(io, s); close(io); io),
               s -> IOContext(IOBuffer(s)),
               s -> (io = IOBuffer("xyz" * s); mark(io); skip(io, 3); io))
    for T in (Float16, Float32, Float64, Number), tok in toks, source in sources
        want = Parsers.parse(T, tok)
        @test isequal(Parsers.parse(T, source(tok)), want)
        @test isequal(Parsers.tryparse(T, source(tok)), want)
    end
    # a delimited stream of such values
    io = PipeBuffer()
    write(io, join(toks, ","))
    for tok in toks
        res = Parsers.xparse(Float64, io, 1, 0, Parsers.Options(delim=','))
        @test res.val === Parsers.parse(Float64, tok)
    end
    @test eof(io)
end

# A parser built on `parsedigits` that treats an exponent past 308 as invalid,
# as FixedPointDecimals does. Its value is the scale exponent.
struct ExponentConf <: Parsers.AbstractConf{Int64} end
Parsers.scale(::ExponentConf, FT::Parsers.FloatType, v, exp, neg, code, ndigits,
              f::F, options::Parsers.Options) where {F} = (Int64(exp), code)
Parsers.noscale(::ExponentConf, v::Integer, neg::Bool, code, ndigits, f::F,
                options::Parsers.Options) where {F} = (Int64(0), code)
function exponentcode(s)
    source = codeunits(s)
    return Parsers.parsedigits(ExponentConf(), source, 1, length(source), source[1],
                               Parsers.SUCCESS, Parsers.OPTIONS, UInt64(0), false, 1,
                               true, 0, nothing)[2]
end

@testset "parsedigits return codes for an exponent past 308" begin
    @test exponentcode("1e400") == INVALID      # no EOF, even at the end of input
    @test exponentcode("1e400,") == INVALID
    @test exponentcode("1e5") == OK | EOF
    @test exponentcode("1e5,") == OK
    @test exponentcode("1.5e-5") == OK | EOF
end

@testset "IO tokens keep their digits while the read waits" begin
    # A read from a pipe can wait for more bytes; another parse on the same
    # thread must not change the digits kept so far.
    for (T, head, tail, want) in ((Float64, "1" * "0"^45, "0"^14 * "1", 1.0e60),
                                  (Number, "1." * "0"^45, "0"^14 * "1", 1.0))
        p = Pipe(); Base.link_pipe!(p)
        write(p, head)
        t = @async Parsers.parse(T, p)
        yield(); sleep(0.1)
        Parsers.parse(Number, "7" * "0"^49)
        write(p, tail); close(p.in)
        @test fetch(t) == want
    end
end

@testset "Number integers wider than Int128 are new BigInts" begin
    a = Parsers.parse(Number, "1" * "0"^50)
    b = Parsers.parse(Number, "2" * "0"^50)
    c = Parsers.xparse(Number, "-3" * "0"^50 * ",").val
    @test a !== b
    @test (a, b, c) == (big(10)^50, 2 * big(10)^50, -3 * big(10)^50)
end

@testset "groupmark" begin
    # `parse` is used for parsing inputs with a single value in them,
    # so when delims==groupmarks, we assume what we see are groupmarks
    @testset "Parsers.parse" begin
        groupmark(c::Char) = Parsers._get_default_options(groupmark=UInt8(c))
        @testset "$T" for T in (Float32, Float64)
            # comma
            @test Parsers.parse(T, "1,0,0,0,0,0,0,0,099e-2", groupmark(',')) ≈ 100_000_000.99
            @test Parsers.parse(T, "100,000,00099e-2", groupmark(',')) ≈ 100_000_000.99
            @test Parsers.parse(T, "100,000,000.99", groupmark(',')) ≈ 100_000_000.99
            @test Parsers.parse(T, "100,000,000", groupmark(',')) ≈ 100_000_000
            # space
            @test Parsers.parse(T, "1 0 0 0 0 0 0 0 099e-2", groupmark(' ')) ≈ 100_000_000.99
            @test Parsers.parse(T, "100 000 00099e-2", groupmark(' ')) ≈ 100_000_000.99
            @test Parsers.parse(T, "100 000 000.99", groupmark(' ')) ≈ 100_000_000.99
            @test Parsers.parse(T, "100 000 000", groupmark(' ')) ≈ 100_000_000
        end
    end
    @test Parsers.xparse(Float64, "100_000_000.99"; groupmark='_').val == 100_000_000.99
    @test Parsers.xparse(Float64, "100_000_000"; groupmark='_').val == 100_000_000.0
    @test Parsers.xparse(Float64, "1_0_0_0_0_0_0_0_0.99"; groupmark='_').val == 100_000_000.99

    @test Parsers.xparse(Float64, "1 0 0 0 0 0 0 0 0.99"; groupmark=' ').val == 100_000_000.99
    @test Parsers.xparse(Float64, "100000000.99"; groupmark=',').val == 100_000_000.99
    @test Parsers.xparse(Float64, "100000000.99,aaa"; groupmark=',') == Parsers.Result{Float64}(OK | DELIMITED, 13, 1.0000000099e8)
    @test Parsers.xparse(Float64, "\"100,000,000.99\",100"; groupmark=',', openquotechar='"', closequotechar='"') == Parsers.Result{Float64}(Int16(13), 17, 1.0000000099e8)
    @test Parsers.xparse(Float64, "100,000,000.99,100"; groupmark=',', openquotechar='"', closequotechar='"') == Parsers.Result{Float64}(Int16(9), 4, 100.0)
    @test Parsers.xparse(Float64, "100_000_000.99,100"; groupmark='_', openquotechar='"', closequotechar='"') == Parsers.Result{Float64}(Int16(9), 15, 1.0000000099e8)
    @test Parsers.xparse(Float64, "\"100,000,000\",100"; groupmark=',', openquotechar='"', closequotechar='"') == Parsers.Result{Float64}(Int16(13), 14, 1.0e8)
    res = Parsers.xparse(Float64, "100,000,000,aaa"; groupmark=',')
    @test res.code == OK | DELIMITED
    @test res.tlen == 4
    res = Parsers.xparse(Float64, "100_000_000,aaa"; groupmark='_')
    @test res.code == OK | DELIMITED
    @test res.tlen == 12

    @test Parsers.xparse(Float32, "100_000_000.99"; groupmark='_').val ≈ 100_000_000.99
    @test Parsers.xparse(Float32, "100_000_000"; groupmark='_').val ≈ 100_000_000.0
    @test Parsers.xparse(Float32, "1_0_0_0_0_0_0_0_0.99"; groupmark='_').val ≈ 100_000_000.99
    @test Parsers.xparse(Float32, "1 0 0 0 0 0 0 0 0.99"; groupmark=' ').val ≈ 100_000_000.99
    @test Parsers.xparse(Float32, "100000000.99"; groupmark=',').val ≈ 100_000_000.99
    res = Parsers.xparse(Float32, "100000000.99,aaa"; groupmark=',')
    @test res.code == OK | DELIMITED
    @test res.tlen == 13
    @test res.val ≈ 100_000_000.99
    res = Parsers.xparse(Float32, "100,000,000,aaa"; groupmark=',')
    @test res.code == OK | DELIMITED
    @test res.tlen == 4
    res = Parsers.xparse(Float32, "100_000_000,aaa"; groupmark='_')
    @test res.code == OK | DELIMITED
    @test res.tlen == 12

    @test Parsers.xparse(Float64, "100,000,00099e-2"; groupmark=',').val == 100.0
    @test Parsers.xparse(Float64, "100_000_00099e-2"; groupmark='_').val == 100_000_000.99
    @test Parsers.xparse(Float64, "1,0,0,0,0,0,0,0,099e-2"; groupmark=',').val == 1.0
    @test Parsers.xparse(Float64, "1_0_0_0_0_0_0_0_099e-2"; groupmark='_').val == 100_000_000.99

    @test Parsers.xparse(Float64, "1 0 0 0 0 0 0 0 099e-2"; groupmark=' ').val == 100_000_000.99
    @test Parsers.xparse(Float64, "10000000099e-2"; groupmark=',').val == 100_000_000.99
    @test Parsers.xparse(Float64, "10000000099e-2,aaa"; groupmark=',') == Parsers.Result{Float64}(OK | DELIMITED, 15, 1.0000000099e8)
    @test Parsers.xparse(Float64, "\"10000000099e-2\",100"; groupmark=',', openquotechar='"', closequotechar='"') == Parsers.Result{Float64}(Int16(13), 17, 1.0000000099e8)
    @test Parsers.xparse(Float64, "10000000099e-2,100"; groupmark=',', openquotechar='"', closequotechar='"') == Parsers.Result{Float64}(Int16(9), 15, 1.0000000099e8)

    @test Parsers.xparse(Float32, "100,000,00099e-2"; groupmark=',').val ≈ 100.0
    @test Parsers.xparse(Float32, "100_000_00099e-2"; groupmark='_').val ≈ 100_000_000.99
    @test Parsers.xparse(Float32, "1,0,0,0,0,0,0,0,099e-2"; groupmark=',').val ≈ 1.0
    @test Parsers.xparse(Float32, "1_0_0_0_0_0_0_0_099e-2"; groupmark='_').val ≈ 100_000_000.99

    @test Parsers.xparse(Float32, "1 0 0 0 0 0 0 0 099e-2"; groupmark=' ').val ≈ 100_000_000.99
    @test Parsers.xparse(Float32, "10000000099e-2"; groupmark=',').val ≈ 100_000_000.99
    res = Parsers.xparse(Float32, "10000000099e-2,aaa"; groupmark=',')
    @test res.code == OK | DELIMITED
    @test res.tlen == 15
    @test res.val ≈ 100_000_000.99

    @testset "$T groupmark=$(repr(g))" for g in (',',' '), T in (Float32, Float64)
        xgroupmark(c::Char) = Parsers._get_default_xoptions(groupmark=UInt8(c))
        # Groupmark tests for floats
        for (input, expected_vals) in [
            ("1000,0000,2000,3000" => (1000.0,0.0,2000.0,3000.0,)),
            ("\"1000\",\"0000\",\"2000\",\"3000\"" => (1000.0,0.0,2000.0,3000.0,)),
            ("\"1$(g)0$(g)0$(g)0\",0000,\"2$(g)0$(g)0$(g)0\",3000" => (1000.0,0.0,2000.0,3000.0,)),
            ("1000,\"0$(g)0$(g)0$(g)0\",2000,\"3$(g)0$(g)0$(g)0\"" => (1000.0,0.0,2000.0,3000.0,)),
            ("1000.00,0000.00,2000.00,3000.00" => (1000.0,0.0,2000.0,3000.0,)),
            ("\"1000.00\",\"0000.00\",\"2000.00\",\"3000.00\"" => (1000.0,0.0,2000.0,3000.0,)),
            ("\"1$(g)0$(g)0$(g)0.00\",0000.00,\"2$(g)0$(g)0$(g)0.00\",3000.00" => (1000.0,0.0,2000.0,3000.0,)),
            ("1000,\"0$(g)0$(g)0$(g)0.00\",2000.00,\"3$(g)0$(g)0$(g)0.00\"" => (1000.0,0.0,2000.0,3000.0,)),
            ("1000.00e0,0000.00e0,2000.00e0,3000.00e0" => (1000.0,0.0,2000.0,3000.0,)),
            ("\"1000.00e0\",\"0000.00e0\",\"2000.00e0\",\"3000.00e0\"" => (1000.0,0.0,2000.0,3000.0,)),
            ("\"1$(g)0$(g)0$(g)0.00e0\",0000.00e0,\"2$(g)0$(g)0$(g)0.00e0\",3000.00e0" => (1000.0,0.0,2000.0,3000.0,)),
            ("1000,\"0$(g)0$(g)0$(g)0.00e0\",2000.00e0,\"3$(g)0$(g)0$(g)0.00e0\"" => (1000.0,0.0,2000.0,3000.0,)),
            ("1000e0,0000e0,2000e0,3000e0" => (1000.0,0.0,2000.0,3000.0,)),
            ("\"1000e0\",\"0000e0\",\"2000e0\",\"3000e0\"" => (1000.0,0.0,2000.0,3000.0,)),
            ("\"1$(g)0$(g)0$(g)0e0\",0000e0,\"2$(g)0$(g)0$(g)0e0\",3000e0" => (1000.0,0.0,2000.0,3000.0,)),
            ("1000,\"0$(g)0$(g)0$(g)0e0\",2000e0,\"3$(g)0$(g)0$(g)0e0\"" => (1000.0,0.0,2000.0,3000.0,)),
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
end

@testset "BigFloats" begin
    res = Parsers.xparse(BigFloat, Vector(codeunits("1")), 1, 1)
    @test res.val == BigFloat(1)
    @test res.code == OK
    @test res.tlen == 1

    @test Parsers.parse(BigFloat, Vector(codeunits("12")), Parsers.Options(), 1, 1) == BigFloat(1)
    @test Parsers.parse(BigFloat, codeunits("12"), Parsers.Options(), 1, 1) == BigFloat(1)

    bytes = Vector(codeunits("xx123,yy"))
    res = Parsers.xparse(BigFloat, @view(bytes[3:6]), 1, 4)
    @test res.val == BigFloat(123)
    @test res.code == (OK | DELIMITED)
    @test res.tlen == 4
    @test String(bytes) == "xx123,yy"

    bytes = Vector(codeunits("1x2"))
    res = Parsers.xparse(BigFloat, @view(bytes[1:2:3]), 1, 2)
    @test res.val == BigFloat(12)
    @test res.code == OK
    @test res.tlen == 2

    res = Parsers.xparse(BigFloat, IOBuffer("1,"), 1, 2)
    @test res.val == BigFloat(1)
    @test res.code == (OK | DELIMITED)
    @test res.tlen == 2

    res = Parsers.xparse(BigFloat, IOBuffer("1a,"), 1, 3)
    @test res.val == BigFloat(1)
    @test res.code == (OK | DELIMITED | INVALID_DELIMITER)
    @test res.tlen == 3

    @test Parsers.parse(BigFloat, "1.7976931348623157e308") == Base.parse(BigFloat, "1.7976931348623157e308")
    @test Parsers.parse(BigFloat, "-1.7976931348623157e308") == Base.parse(BigFloat, "-1.7976931348623157e308")
    # next float64 - too large
    @test Parsers.parse(BigFloat, "1.7976931348623159e308") == Base.parse(BigFloat, "1.7976931348623159e308")
    @test Parsers.parse(BigFloat, "-1.7976931348623159e308") == Base.parse(BigFloat, "-1.7976931348623159e308")
    # the border is ...158079
    # borderline - okay
    @test Parsers.parse(BigFloat, "1.7976931348623158e308") == Base.parse(BigFloat, "1.7976931348623158e308")
    @test Parsers.parse(BigFloat, "-1.7976931348623158e308") == Base.parse(BigFloat, "-1.7976931348623158e308")
    # borderline - too large
    @test Parsers.parse(BigFloat, "1.797693134862315808e308") == Base.parse(BigFloat, "1.797693134862315808e308")
    @test Parsers.parse(BigFloat, "-1.797693134862315808e308") == Base.parse(BigFloat, "-1.797693134862315808e308")

    # a little too large
    @test Parsers.parse(BigFloat, "1e308") == Base.parse(BigFloat, "1e308")
    @test Parsers.parse(BigFloat, "2e308") == Base.parse(BigFloat, "2e308")
    @test Parsers.parse(BigFloat, "1e309") == Base.parse(BigFloat, "1e309")

    # way too large
    @test Parsers.parse(BigFloat, "1e310") == Base.parse(BigFloat, "1e310")
    @test Parsers.parse(BigFloat, "-1e310") == Base.parse(BigFloat, "-1e310")
end

# https://github.com/JuliaData/CSV.jl/issues/916
@test  Parsers.parse(Float64, "0.44311945001372019574271437679879349172") === 0.4431194500137202
@test Parsers.parse(BigFloat, "0.44311945001372019574271437679879349172") == BigFloat("0.44311945001372019574271437679879349172")

# https://github.com/JuliaData/Parsers.jl/issues/83
@test Parsers.parse(Float64,"9.3494547075363499E-311") === 9.3494547075363e-311
@test Parsers.parse(Float64,"9.349454707536349999E-311") === 9.3494547075363e-311

# https://github.com/JuliaData/CSV.jl/issues/938
v1 = Parsers.parse(BigFloat, "0.994322841995507271075540969506")
v2 = Parsers.parse(BigFloat, "0.794322841995507271075540969506")
@test v1 !== v2

# parsing larger than Int64 with dangling non-digits
@test_throws Parsers.Error Parsers.parse(Float64, "3130307457683247493156627A")

# https://github.com/JuliaData/CSV.jl/issues/1007
@test Parsers.parse(Float64, "19129370688824811353f0") === 1.912937068882481e19

end # @testset
