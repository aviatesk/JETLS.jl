using Aqua
using Configurations
Aqua.test_all(Configurations)

include("test_utils.jl")
include("test_basic.jl")
include("test_error.jl")
include("test_from_dict.jl")
include("test_parametric.jl")
include("test_reflection.jl")
include("test_issue50.jl")
include("test_reflected.jl")
include("test_auto_maybe_default.jl")
include("test_partial.jl")
include("test_empty_dict.jl")
include("test_issue82.jl")