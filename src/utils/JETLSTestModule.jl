# HACK: This module is a temporary, JETLS-test-suite-specific workaround, not
# a general solution. It exists so that test files matched by an
# `analysis_overrides` entry with `module_name = "JETLSTestModule"` can have
# their `@testset`/`@test` macros and references like `JETLS.foo` /
# `JS.kind(...)` resolved during lowering analysis without running JET's
# full toplevel analysis (which is too slow for our test files today).
#
# The set of `using`s below mirrors the imports that JETLS's own tests rely
# on, so the lowering context this module provides only really fits this
# repository. The proper fix is to make full analysis fast enough to apply
# to test files directly; this module should be removed once that lands.
module JETLSTestModule
    using Test
    using JuliaSyntax: JuliaSyntax as JS
    using JuliaLowering: JuliaLowering as JL
    using LSP
    using LSP: LSP
    using LSP.URIs2
    using ..JETLS: JETLS
end
