# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- links start -->
[Unreleased]: https://github.com/JuliaDebug/JuliaInterpreter.jl/compare/v0.12.0...HEAD
[0.12.0]: https://github.com/JuliaDebug/JuliaInterpreter.jl/compare/v0.11.6...v0.12.0
[0.11.6]: https://github.com/JuliaDebug/JuliaInterpreter.jl/compare/v0.11.5...v0.11.6
[0.11.5]: https://github.com/JuliaDebug/JuliaInterpreter.jl/compare/v0.11.4...v0.11.5
[0.11.4]: https://github.com/JuliaDebug/JuliaInterpreter.jl/compare/v0.11.3...v0.11.4
[0.11.3]: https://github.com/JuliaDebug/JuliaInterpreter.jl/compare/v0.11.2...v0.11.3
[0.11.2]: https://github.com/JuliaDebug/JuliaInterpreter.jl/compare/v0.11.1...v0.11.2
[0.11.1]: https://github.com/JuliaDebug/JuliaInterpreter.jl/compare/v0.11.0...v0.11.1
[0.11.0]: https://github.com/JuliaDebug/JuliaInterpreter.jl/compare/v0.10.12...v0.11.0
<!-- links end -->

## [Unreleased]

## [0.12.0]

### Added
- `RecursiveInterpreter` interprets the code passed to `Core.eval`, also through
  `Base.eval`, `@eval`, and `include`, in top-level frames linked to the
  calling frame, so breakpoints, stepping, and exception handling extend into
  it. To evaluate it natively, use `NonRecursiveInterpreter` or add the method
  of `Core.eval` to `JuliaInterpreter.compiled_methods`
  (JuliaDebug/JuliaInterpreter.jl#783).

### Changed
- **Breaking**: `Frame(mod, ex)` now evaluates `:module` expressions as native
  evaluation does: each evaluation creates a fresh module instead of re-entering
  an existing one of the same name, `__init__` runs (natively) after the body,
  and the statement evaluates to the module, also when the module expression
  comes from a macro. `Frame(mod, :(module X end))` no longer creates `X` when
  the frame is constructed, and returns a frame in `mod`. `ExprSplitter` keeps
  re-entering existing modules and does not run `__init__`. On Julia 1.10–1.12,
  `__init__` may run out of order or twice when the parent module is itself
  being evaluated natively, e.g. from a package's top-level code
  (JuliaDebug/JuliaInterpreter.jl#782).
- **Breaking**: On Julia 1.12 and later, top-level frames advance their world
  only at `:latestworld` statements, as native evaluation does, rather than
  before every statement, and `Frame(mod, ex)` and `Frame(mod, src::CodeInfo)`
  start in the latest world by default. Code that evaluates top-level frames
  selectively must still advance the world at the `:latestworld` statements it
  skips (JuliaDebug/JuliaInterpreter.jl#783).
- A top-level statement driven by `Frame(mod, ex)` that fails to lower throws
  the error of native evaluation (e.g. `syntax: invalid assignment location`)
  instead of an `ArgumentError` (JuliaDebug/JuliaInterpreter.jl#783).
- `:s` on a top-level statement driven by `Frame(mod, ex)` enters the lowered
  frame of the statement like a callee and stops at its first call, instead of
  entering the callee of the surface call expression, which failed when the
  call's arguments contained calls and skipped the rest of the statement, such
  as the assignment of `x = f(1)` (JuliaDebug/JuliaInterpreter.jl#784).

### Fixed
- The frame of a nested `:thunk` in top-level code, as lowered for closures, is
  linked to its caller, so breakpoints, errors, and its value propagate
  (JuliaDebug/JuliaInterpreter.jl#783).

## [0.11.6]

### Changed
- Added this changelog (JuliaDebug/JuliaInterpreter.jl#780).

### Fixed
- `@cfunction` and top-level `ccall`s run through compiled wrappers instead of
  being compiled on every execution, and top-level `@cfunction` no longer
  errors (JuliaDebug/JuliaInterpreter.jl#773).
- A `throw(nothing)` inside a `catch` block is no longer mistaken for a
  `rethrow()` (JuliaDebug/JuliaInterpreter.jl#774).
- Updated the builtins for Julia 1.14, and `Core.arraysize` is evaluated by the
  interpreter on Julia 1.10 instead of falling back to a native call
  (JuliaDebug/JuliaInterpreter.jl#778, JuliaDebug/JuliaInterpreter.jl#779).
- Frames built with `optimize=false` can run methods that contain an `llvmcall`.
  `optimize=false` now skips only the optimizations (folding `const` globals and
  compiling `ccall`s and `@cfunction`s into wrappers), not the compilation of
  `llvmcall`s, which cannot be interpreted (JuliaDebug/JuliaInterpreter.jl#781).

## [0.11.5]

### Changed
- Improved interpretation performance by reusing cached frames for interpreted
  calls, tracking frame recycling more cheaply, and optimizing global reference
  lookups again (JuliaDebug/JuliaInterpreter.jl#759,
  JuliaDebug/JuliaInterpreter.jl#761, JuliaDebug/JuliaInterpreter.jl#770).
- Stepping avoids stopping at internal-looking positions
  (JuliaDebug/JuliaInterpreter.jl#760).

### Fixed
- Fixed compiled `:foreigncall` wrappers for parametric argument types and
  nested `UnionAll` types (JuliaDebug/JuliaInterpreter.jl#767,
  JuliaDebug/JuliaInterpreter.jl#769).
- Every handler that catches a rethrown exception now clears the rethrow marker
  (JuliaDebug/JuliaInterpreter.jl#772).

## [0.11.4]

### Added
- Interpreted code can create and call opaque closures.

### Fixed
- Fixed a large number of divergences from native execution, found by an audit
  and a triage of the issue backlog (JuliaDebug/JuliaInterpreter.jl#751,
  JuliaDebug/JuliaInterpreter.jl#752, JuliaDebug/JuliaInterpreter.jl#753,
  JuliaDebug/JuliaInterpreter.jl#755). Notably:
  - The active-exception stack (`rethrow()`, `current_exceptions()`,
    `:pop_exception`) and dynamic scopes now match native execution when
    exceptions unwind, including through the debugger.
  - Builtins that take callbacks, `invoke`, and `applicable` run in the
    frame's world.
  - Fixes to breakpoints, `eval_code`, `ExprSplitter`, and stepping: e.g.
    `next_line!` stops on assignment-only lines, and `:sg` enters generators
    with argument types.
  - Nested `@interpret` works, since the interpreter's own methods run compiled.
- Re-interpreting a module with itself as the parent context re-enters it
  instead of creating a nested module (JuliaDebug/JuliaInterpreter.jl#758).

## [0.11.3]

### Added
- Added support for the `Core.define_method` builtin of Julia 1.14
  (JuliaDebug/JuliaInterpreter.jl#748).

### Changed
- A nested `module X` resolves to a fresh local module, unless it is evaluated
  into `Base.__toplevel__` (a package loading itself) or `X` is already a
  submodule of the parent (JuliaDebug/JuliaInterpreter.jl#740,
  timholy/Revise.jl#747).

### Fixed
- Recycled frames are pooled at most once (JuliaDebug/JuliaInterpreter.jl#749).

## [0.11.2]

### Added
- Added support for Julia 1.14 lowering and runtime changes: `Expr(:foreignglobal)`,
  envout markers, and new builtins (JuliaDebug/JuliaInterpreter.jl#742,
  JuliaDebug/JuliaInterpreter.jl#747).

### Fixed
- Extensions of different packages sharing a name now resolve to the right
  module (JuliaDebug/JuliaInterpreter.jl#743).

## [0.11.1]

### Fixed
- `Core._apply_iterate` runs in the frame's world
  (JuliaDebug/JuliaInterpreter.jl#741).

## [0.11.0]

### Added
- Added support for Julia 1.13 (JuliaDebug/JuliaInterpreter.jl#737).

### Changed
- **Breaking**: Interpretation respects world age. A frame captures a world
  when it is constructed and dispatches and reads globals in it. By default
  this is the caller's task world, as for compiled code, rather than the latest
  world. Top-level frames still advance to the latest world for each statement.
  `@interpret` accepts `world=:latest` or a world number to reach newer
  definitions (JuliaDebug/JuliaInterpreter.jl#715,
  JuliaDebug/JuliaInterpreter.jl#732, JuliaDebug/JuliaInterpreter.jl#738).
- `Frame(mod, ex)` interprets a whole `:toplevel` or `:module` expression
  directly as a single frame tree, instead of relying on `ExprSplitter` to
  return to the actual top level. `ExprSplitter` remains available
  (JuliaDebug/JuliaInterpreter.jl#719).
- The interpreter's caches are invalidated by world age, and are no longer
  cleared on every entry (JuliaDebug/JuliaInterpreter.jl#721,
  JuliaDebug/JuliaInterpreter.jl#733).
- `invokelatest` calls expanded by the recursive interpreter run in the latest
  world (JuliaDebug/JuliaInterpreter.jl#729).
