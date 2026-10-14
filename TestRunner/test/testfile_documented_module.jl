"""
Documented test module.
"""
module testfile_documented_module

using Test
@test sin(0) == 0
@test cos(0) == 1

end # testfile_documented_module
