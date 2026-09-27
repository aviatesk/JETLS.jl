using Test

s = "julia"

@test startswith(s, "julia")  # line 5

@test startswith(s, "julia")  # line 7 - not intended to be selected
