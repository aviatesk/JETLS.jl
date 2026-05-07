
# JSON3.jl

[![Build Status](https://travis-ci.com/quinnj/JSON3.jl.svg?branch=master)](https://travis-ci.com/quinnj/JSON3.jl)
[![codecov](https://codecov.io/gh/quinnj/JSON3.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/quinnj/JSON3.jl)

### Documentation

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://quinnj.github.io/JSON3.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://quinnj.github.io/JSON3.jl/dev)

*Yet another JSON package for Julia; this one is for speed and slick struct mapping*

### TL;DR

#### Basic

```julia
# builtin reading/writing
JSON3.read(json_string)
JSON3.write(x)

# custom types
JSON3.read(json_string, T; kw...)
JSON3.write(x)
```

#### More complicated

```julia
# custom types: incrementally update a mutable struct
x = T()
JSON3.read!(json_string, x; kw...)
JSON3.write(x)

# read from file
json_string = read("my.json", String)
JSON3.read(json_string)
JSON3.read(json_string, T; kw...)

# write to file
open("my.json", "w") do f
    JSON3.write(f, x)
    println(f)
end

# write a pretty file
open("my.json", "w") do f
    JSON3.pretty(f, JSON3.write(x))
    println(f)
end

# generate a type from json
using StructTypes
JSON3.@generatetypes json_string_sample
JSON3.read(json_string, JSONTypes.Root)
```
