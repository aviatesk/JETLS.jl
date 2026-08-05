OrderedCollections.jl
=====================

[![CI](https://github.com/JuliaCollections/OrderedCollections.jl/workflows/CI/badge.svg)](https://github.com/JuliaCollections/OrderedCollections.jl/actions?query=workflow%3ACI)
[![Test Coverage](https://codecov.io/github/JuliaCollections/OrderedCollections.jl/coverage.svg?branch=master)](https://codecov.io/github/JuliaCollections/OrderedCollections.jl?branch=master)
[![Documentation (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://juliacollections.github.io/OrderedCollections.jl/dev)
[![Documentation (stable)](https://img.shields.io/badge/docs-stable-blue.svg)](https://juliacollections.github.io/OrderedCollections.jl/stable)

This package implements OrderedDicts and OrderedSets, which are similar to containers in base Julia.
However, during iteration the Ordered* containers return items in the order in which they were added to the collection.
It also implements `LittleDict` which is a ordered dictionary, that is much faster than any other `AbstractDict` (ordered or not) for small collections.

This package was split out from [DataStructures.jl](https://github.com/JuliaCollections/DataStructures.jl).
