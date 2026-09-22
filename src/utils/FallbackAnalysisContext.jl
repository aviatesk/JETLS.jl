# Supply the supported Test macros without pretending to know the file's other imports.
# This context is only used for full-analysis overrides without an explicit module.
module FallbackAnalysisContext
    using Test
end
