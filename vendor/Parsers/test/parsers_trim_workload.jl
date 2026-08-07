# Trim-compile workload: exercises the float parse paths, in particular every
# rung of the overflow-widening ladder (UInt64 → UInt128 → BigInt) that the
# trim fix makes statically reachable — under the old Base.inferencebarrier
# form these calls were verifier errors AND the widened instances were absent
# from trimmed binaries (wide-mantissa parses would fail at runtime). Compiled
# by test/trim_compile_tests.jl with `juliac --trim=safe` (error budget zero),
# then executed so the value assertions prove runtime rounding too.
using Parsers

function _assert_float_basics()::Nothing
    Parsers.parse(Float64, "1.5") === 1.5 || error("float basic")
    Parsers.parse(Float64, "-2.25e3") === -2250.0 || error("float exponent")
    Parsers.parse(Float64, "0.1") === 0.1 || error("float rounding")
    Parsers.parse(Float64, "0") === 0.0 || error("float zero")
    Parsers.parse(Float32, "1.5") === 1.5f0 || error("float32")
    Parsers.parse(Float16, "0.5") === Float16(0.5) || error("float16")
    return nothing
end

# the widening ladder itself: mantissas that overflow UInt64 (first rung) and
# UInt128 (second rung, into BigInt). Expected values are Base.parse results —
# Parsers must agree bit-for-bit.
function _assert_widening_ladder()::Nothing
    # 21 significant digits: overflows UInt64 accumulation -> UInt128
    Parsers.parse(Float64, "123456789012345678901.5") === 1.234567890123456789015e20 ||
        error("UInt128 rung")
    # 45 significant digits: overflows UInt128 -> BigInt
    Parsers.parse(Float64, "123456789012345678901234567890123456789012345.0") ===
        1.2345678901234567e44 || error("BigInt rung")
    # wide fractional digits take the _parsefrac widening path
    Parsers.parse(Float64, "0.123456789012345678901234567890123456789012345") ===
        0.12345678901234568 || error("frac widening")
    # widening in the presence of an exponent (_parseexp path)
    Parsers.parse(Float64, "123456789012345678901234567890e-10") ===
        1.2345678901234568e19 || error("exp widening")
    return nothing
end

function _assert_float_edges()::Nothing
    Parsers.parse(Float64, "1e310") === Inf || error("overflow Inf")
    Parsers.parse(Float64, "-1e310") === -Inf || error("overflow -Inf")
    Parsers.parse(Float64, "5e-324") === 5.0e-324 || error("denormal")
    Parsers.parse(Float64, "1.7976931348623157e308") === floatmax(Float64) || error("floatmax")
    isnan(Parsers.parse(Float64, "NaN")) || error("nan")
    Parsers.parse(Float64, "Inf") === Inf || error("inf literal")
    return nothing
end

function _assert_non_floats()::Nothing
    Parsers.parse(Int, "12345") === 12345 || error("int")
    Parsers.parse(Int, "-7") === -7 || error("negative int")
    Parsers.tryparse(Float64, "abc") === nothing || error("tryparse miss")
    t = Parsers.tryparse(Float64, "2.5")
    (t isa Float64 && t === 2.5) || error("tryparse hit")
    Parsers.parse(Bool, "true") === true || error("bool")
    return nothing
end

function run_parsers_trim_workload()::Nothing
    _assert_float_basics()
    _assert_widening_ladder()
    _assert_float_edges()
    _assert_non_floats()
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_parsers_trim_workload()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
