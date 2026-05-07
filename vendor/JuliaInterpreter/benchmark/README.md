The benchmarks are recommended to be run using PkgBenchmark.jl as:

```
using PkgBenchmark
results = benchmarkpkg("JuliaInterpreter")
```

See the [PkgBenchmark](https://juliaci.github.io/PkgBenchmark.jl/stable/index.html) documentation for what
analysis is possible on `result`.