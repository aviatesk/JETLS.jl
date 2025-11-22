#!/usr/bin/env julia

# Migration message for users still using runserver.jl
println(stderr, """
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WARNING: runserver.jl is deprecated and will be removed in a future release.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Please use the `jetls` executable app instead.

Installation:
  julia -e 'using Pkg; Pkg.Apps.add("https://github.com/aviatesk/JETLS.jl#release")'

Migration:
  Old: julia --project=/path/to/JETLS runserver.jl --socket=8080
  New: jetls --socket=8080

For local JETLS development:
  julia --project=/path/to/JETLS -m JETLS [OPTIONS]

Read https://aviatesk.github.io/JETLS.jl/dev/#JETLS.jl-documentation for more details.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")

exit(1)
