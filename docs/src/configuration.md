# JETLS configuration

JETLS supports various configuration options.
This documentation uses TOML format to describe the configuration schema.

## [Configuration schema](@id config/schema)

```toml
[full_analysis]
debounce = 1.0             # number (seconds), default: 1.0
auto_instantiate = true    # boolean, default: true

formatter = "Runic"        # String preset: "Runic" (default) or "JuliaFormatter"

[formatter.custom]         # Or custom formatter configuration
executable = ""            # string (path), optional
executable_range = ""      # string (path), optional

[diagnostic]
enabled = true             # boolean, default: true

[[diagnostic.patterns]]
pattern = ""               # string, required
match_by = ""              # string, required, "code" or "message"
match_type = ""            # string, required, "literal" or "regex"
severity = ""              # string or number, required, "error"/"warning"/"warn"/"information"/"info"/"hint"/"off" or 0/1/2/3/4
path = ""                  # string (optional), glob pattern for file paths

[testrunner]
executable = "testrunner"  # string, default: "testrunner" (or "testrunner.bat" on Windows)
```

## [Configuration reference](@id config/reference)

- [`[full_analysis]`](@ref config/full_analysis)
    - [`[full_analysis] debounce`](@ref config/full_analysis-debounce)
    - [`[full_analysis] auto_instantiate`](@ref config/full_analysis-auto_instantiate)
- [`formatter`](@ref config/formatter)
- [`[diagnostic]`](@ref config/diagnostic)
    - [`[diagnostic] enabled`](@ref config/diagnostic-enabled)
    - [`[[diagnostic.patterns]]`](@ref config/diagnostic-patterns)
- [`[testrunner]`](@ref config/testrunner)
    - [`[testrunner] executable`](@ref config/testrunner-executable)

### [`[full_analysis]`](@id config/full_analysis)

#### [`[full_analysis] debounce`](@id config/full_analysis-debounce)

- **Type**: number (seconds)
- **Default**: `1.0`

Debounce time in seconds before triggering full analysis after a file save.
JETLS performs type-aware analysis using [JET.jl](https://github.com/aviatesk/JET.jl)
to detect potential errors. The debounce prevents excessive analysis when you
save files frequently. Higher values reduce analysis frequency (saving CPU) but
may delay diagnostic updates.

```toml
[full_analysis]
debounce = 2.0  # Wait 2 seconds after save before analyzing
```

#### [`[full_analysis] auto_instantiate`](@id config/full_analysis-auto_instantiate)

- **Type**: boolean
- **Default**: `true`

When enabled, JETLS automatically runs `Pkg.instantiate()` for packages that have
not been instantiated yet (e.g., freshly cloned repositories). This allows full
analysis to work immediately upon opening such packages. Note that this will
automatically create a `Manifest.toml` file when the package has not been
instantiated yet.

```toml
[full_analysis]
auto_instantiate = false  # Disable automatic instantiation
```

### [`formatter`](@id config/formatter)

- **Type**: string or table
- **Default**: `"Runic"`

Formatter configuration. Can be a preset name or a custom formatter object.

Preset options:

- `"Runic"` (default): Uses [Runic.jl](https://github.com/fredrikekre/Runic.jl)
  (`"runic"` or `"runic.bat"` on Windows)
- `"JuliaFormatter"`: Uses [JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl)
  (`"jlfmt"` or `"jlfmt.bat"` on Windows)

Custom formatter configuration:

- `formatter.custom.executable` (string, optional): Path to custom formatter
  executable for document formatting. The formatter should read Julia code from
  stdin and output formatted code to stdout.
- `formatter.custom.executable_range` (string, optional): Path to custom
  formatter executable for range formatting. Should accept `--lines=START:END`
  argument.

Examples:

```toml
# Use JuliaFormatter preset
formatter = "JuliaFormatter"

# Or use custom formatter (both fields optional)
[formatter.custom]
executable = "/path/to/custom-formatter"
executable_range = "/path/to/custom-range-formatter"
```

See [Formatting](@ref) for detailed configuration instructions and setup requirements.

### [`[diagnostic]`](@id config/diagnostic)

Configure how JETLS reports diagnostic messages (errors, warnings, infos, hints)
in your editor. JETLS uses hierarchical diagnostic codes in the format
`"category/kind"` (following the [LSP specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnostic))
to allow fine-grained control over which diagnostics to show and at what
severity level.

See the [Diagnostic](@ref) section for complete diagnostic reference
including all available codes, their meanings, and examples.

#### [`[diagnostic] enabled`](@id config/diagnostic-enabled)

- **Type**: boolean
- **Default**: `true`

Enable or disable all JETLS diagnostics. When set to `false`, no diagnostic
messages will be shown.

```toml
[diagnostic]
enabled = false  # Disable all diagnostics
```

#### [`[[diagnostic.patterns]]`](@id config/diagnostic-patterns)

Fine-grained control over diagnostics through pattern matching against either
[diagnostic codes](@ref diagnostic-code) or messages.

See the [diagnostic reference](@ref diagnostic-reference) section for
a complete list of all available diagnostic codes, their default severity
levels, and detailed explanations with examples.

##### Configuration syntax

Each pattern is defined as a table array entry with the following fields:

```toml
[[diagnostic.patterns]]
pattern = "pattern-value"  # string: the pattern to match
match_by = "code"          # string: "code" or "message"
match_type = "literal"     # string: "literal" or "regex"
severity = "hint"          # string or number: severity level
path = "src/**/*.jl"       # string (optional): restrict to specific files
```

- `pattern` (**Type**: string): The pattern to match. For code matching, use diagnostic
  codes like `"lowering/unused-argument"`. For message matching, use text
  patterns like `"Macro name .* not found"`.
- `match_by` (**Type**: string): What to match against
  - `"code"`: Match against [diagnostic code](@ref diagnostic-code) (e.g., `"lowering/unused-argument"`)
  - `"message"`: Match against diagnostic message text
- `match_type` (**Type**: string): How to interpret the pattern
  - `"literal"`: Exact string match
  - `"regex"`: Regular expression match
- `severity` (**Type**: string or number): Severity level to apply
- `path` (**Type**: string, optional): Glob pattern to restrict this
  configuration to specific files.
  Patterns are matched against _file paths relative to the workspace root_.
  Supports globstar (`**`) for matching directories recursively.
  If omitted, the pattern applies to all files.

##### Severity values

[Severity level](@ref diagnostic-severity) to apply.
Can be specified using either string or number values:

- `"error"` or `1`: Critical issues that prevent code from working correctly
- `"warning"` or `"warn"` or `2`: Potential problems that should be reviewed
- `"information"` or `"info"` or `3`: Informational messages about code that may benefit from attention
- `"hint"` or `4`: Suggestions for improvements or best practices
- `"off"` or `0`: Disable the diagnostic

String values are case-insensitive. The numeric values correspond to the
[LSP specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnosticSeverity),
while `"off"`/`0` is a JETLS-specific extension for disabling diagnostics.

##### Pattern matching priority

When multiple patterns match the same diagnostic, more specific patterns take
precedence. The priority order (highest to lowest) is:

1. `message` literal match
2. `message` regex match
3. `code` literal match
4. `code` regex match

This priority strategy allows message-based patterns to override code-based
patterns, enabling fine-grained control for specific diagnostic instances.

Example showing priority:

```toml
# Lower priority: matches all lowering diagnostics
[[diagnostic.patterns]]
pattern = "lowering/.*"
match_by = "code"
match_type = "regex"
severity = "error"

# Higher priority: matches specific message
[[diagnostic.patterns]]
pattern = "Unused argument `x`"
match_by = "message"
match_type = "literal"
severity = "off"

# Highest priority among code patterns: exact code match
[[diagnostic.patterns]]
pattern = "lowering/unused-argument"
match_by = "code"
match_type = "literal"
severity = "hint"
```

!!! note
    When [`diagnostic.enabled`](@ref config/diagnostic-enabled) is `false`,
    all diagnostics are disabled regardless of pattern settings.

#### `[diagnostic]` configuration examples

```toml
[diagnostic]
enabled = true

# Pattern matching against diagnostic code
[[diagnostic.patterns]]
pattern = "lowering/.*"
match_by = "code"
match_type = "regex"
severity = "warning"

# Disable inference diagnostic entirely
[[diagnostic.patterns]]
pattern = "inference/.*"
match_by = "code"
match_type = "regex"
severity = "off"

# Show unused arguments as hints (overrides category setting)
[[diagnostic.patterns]]
pattern = "lowering/unused-argument"
match_by = "code"
match_type = "literal"
severity = "hint"

# Completely disable unused local variable diagnostics using integer value
[[diagnostic.patterns]]
pattern = "lowering/unused-local"
match_by = "code"
match_type = "literal"
severity = 0

# Pattern matching against diagnostic message
[[diagnostic.patterns]]
pattern = "Macro name `@interface` not found"
match_by = "message"
match_type = "literal"
severity = "off"

# Suppress all macro not found errors using regex
[[diagnostic.patterns]]
pattern = "Macro name `.*` not found"
match_by = "message"
match_type = "regex"
severity = "off"

# File path-based filtering: downgrade unused arguments in test files
[[diagnostic.patterns]]
pattern = "lowering/unused-argument"
match_by = "code"
match_type = "literal"
severity = "hint"
path = "test/**/*.jl"

# Disable all diagnostics for generated files
[[diagnostic.patterns]]
pattern = ".*"
match_by = "code"
match_type = "regex"
severity = "off"
path = "gen/**/*.jl"
```

See the [configuring diagnostics](@ref configuring-diagnostic) section for
additional examples and common use cases.

### [`[testrunner]`](@id config/testrunner)

#### [`[testrunner] executable`](@id config/testrunner-executable)

- **Type**: string
- **Default**: `"testrunner"` or `"testrunner.bat"` on Windows

Path to the [TestRunner.jl](https://github.com/aviatesk/TestRunner.jl)
executable for running individual `@testset` blocks and `@test` cases.

```toml
[testrunner]
executable = "/path/to/custom/testrunner"
```

See [TestRunner integration](@ref) for setup instructions.

## How to configure JETLS

### [Method 1: File-based configuration](@id config/file-based-config)

Create a `.JETLSConfig.toml` file in your project root.
This configuration method works client-agnostically, thus allows projects to
commit configuration to VCS without writing JETLS configurations in various
formats that each client can understand.

> Example `.JETLSConfig.toml`:

```toml
[full_analysis]
debounce = 2.0

# Use JuliaFormatter instead of Runic
formatter = "JuliaFormatter"

# Suppress unused argument warnings
[[diagnostic.patterns]]
pattern = "lowering/unused-argument"
match_by = "code"
match_type = "literal"
severity = "off"

[testrunner]
executable = "/path/to/custom/testrunner"
```

### [Method 2: Editor configuration via LSP](@id config/lsp-config)

If your client supports [`workspace/configuration`](#workspace-configuration-support),
you can configure JETLS in a client-specific manner.
As examples, we show the configuration methods for the VSCode extension
[`jetls-client`](https://marketplace.visualstudio.com/items?itemName=aviatesk.jetls-client), and the Zed extension
[`aviatesk/zed-julia#avi/JETLS`](https://github.com/aviatesk/zed-julia/tree/avi/JETLS).

#### [VSCode (`jetls-client` extension)](@id config/lsp-config/vscode)

Configure JETLS in VSCode's settings.json file with `jetls-client.settings`
section:

> Example `.vscode/settings.json`:

```json
{
  "jetls-client.settings": {
    "full_analysis": {
      "debounce": 2.0
    },
    // Use JuliaFormatter instead of Runic
    "formatter": "JuliaFormatter",
    "diagnostic": {
      "patterns": [
        // Suppress toplevel/inference warnings in test folder
        {
          "pattern": "(toplevel|inference)/.*",
          "match_by": "code",
          "match_type": "regex",
          "severity": "off",
          "path": "test/**/*.jl"
        }
      ]
    },
    "testrunner": {
      "executable": "/path/to/custom/testrunner"
    }
  }
}
```

See [`package.json`](https://github.com/aviatesk/JETLS.jl/blob/master/package.json)
for the complete list of available VSCode settings and their descriptions.

#### [Zed (`aviatesk/zed-julia#avi/JETLS` extension)](@id config/lsp-config/zed)

Configure JETLS in Zed's settings.json file with the `lsp.JETLS.settings`
section:

> Example `.zed/settings.json`:

```json
{
  "lsp": {
    "JETLS": {
      "settings": {
        "full_analysis": {
          "debounce": 2.0
        },
        // Use JuliaFormatter instead of Runic
        "formatter": "JuliaFormatter",
        "diagnostic": {
          "patterns": [
            // Suppress toplevel/inference warnings in test folder
            {
              "pattern": "(toplevel|inference)/.*",
              "match_by": "code",
              "match_type": "regex",
              "severity": "off",
              "path": "test/**/*.jl"
            }
          ]
        },
        "testrunner": {
          "executable": "/path/to/custom/testrunner"
        }
      }
    }
  }
}
```

## Configuration priority

When multiple configuration sources are present, they are merged in priority
order (highest first):

1. File-based configuration (`.JETLSConfig.toml`)
2. Editor configuration via LSP (`workspace/configuration`)
3. Built-in defaults

File-based configuration (`.JETLSConfig.toml`) takes precedence as it provides
a **client-agnostic** way to configure JETLS that works consistently across all
editors.
