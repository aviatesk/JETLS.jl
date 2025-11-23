using Test, PTest, Preferences

uuid = Base.UUID("8789f892-390a-4776-818f-b9c2b248add9")
set_preferences!(uuid, "set_by_runtests" => "This was set by runtests.jl")
uuid = Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76")
set_preferences!((uuid, "TOML"), "set_by_runtests" => "This was set by runtests.jl")
PTest.do_test()
