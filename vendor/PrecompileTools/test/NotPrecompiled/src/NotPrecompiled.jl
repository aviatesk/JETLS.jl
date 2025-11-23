module NotPrecompiled

# This module can be a dependency of others to check
# caching: call `call_isa_bool(x::T)` for some `T` and
# then check for `isa_bool(::T)` specializations.

isa_bool(x) = isa(x, Bool)
call_isa_bool(x) = isa_bool(Base.inferencebarrier(x))

const themethod = only(methods(isa_bool))

end # module NotPrecompiled
