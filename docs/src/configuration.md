# JETLS configuration

JETLS supports various configuration options.
This documentation uses TOML format to describe the configuration schema.

## Available configurations

- [`[full_analysis]`](@ref config/full_analysis)
    - [`[full_analysis] debounce`](@ref config/full_analysis-debounce)
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

### [`formatter`](@id config/formatter)

- **Type**: string or table
- **Default**: `"Runic"`

Configures the formatter backend for document and range formatting. Accepts
either a preset formatter name or a custom formatter configuration.

Preset options:

- `"Runic"` (default): Uses [Runic.jl](https://github.com/fredrikekre/Runic.jl)
- `"JuliaFormatter"`: Uses [JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl)

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
pattern = "pattern-value"  # the pattern to match
match_by = "code"          # "code" or "message"
match_type = "literal"     # "literal" or "regex"
severity = "hint"          # severity level
```

- `pattern`: The pattern to match (string)
- `match_by`: What to match against
  - `"code"`: Match against [diagnostic code](@ref diagnostic-code) (e.g., `"lowering/unused-argument"`)
  - `"message"`: Match against diagnostic message text
- `match_type`: How to interpret the pattern
  - `"literal"`: Exact string match
  - `"regex"`: Regular expression match
- `severity`: Severity level to apply (see below)

##### Severity values

JETLS supports four severity levels defined by the [LSP specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnosticSeverity):
- `Error` (`1`): Critical issues that prevent code from working correctly
- `Warning` (`2`): Potential problems that should be reviewed
- `Information` (`3`): Informational messages about code that may benefit from attention
- `Hint` (`4`): Suggestions for improvements or best practices

Additionally, JETLS defines a special severity value `"off"` (or `0`) for disabling
diagnostics entirely. This is a JETLS-specific extension not defined in the LSP
specification.

You can specify severity using either string or integer values (case-insensitive for strings):
- `"error"` or `1` for `Error`
- `"warning"` or `"warn"` or `2` for `Warning`
- `"information"` or `"info"` or `3` for `Information`
- `"hint"` or `4` for `Hint`
- `"off"` or `0` for `Disabled`

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
```

See the [configuring diagnostics](@ref configuring-diagnostic) section for
additional examples and common use cases.

### [`[testrunner]`](@id config/testrunner)

#### [`[testrunner] executable`](@id config/testrunner-executable)

- **Type**: string (path)
- **Default**: `"testrunner"` (or `"testrunner.bat"` on Windows)

Path to the [TestRunner.jl](https://github.com/aviatesk/TestRunner.jl)
executable for running individual `@testset` blocks and `@test` cases. If not
specified, JETLS looks for `testrunner` in your `PATH` (typically
`~/.julia/bin/testrunner`).

```toml
[testrunner]
executable = "/path/to/custom/testrunner"
```

See [TestRunner integration](@ref) for setup instructions.

## How to configure JETLS

### Method 1: File-based configuration

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

### Method 2: Editor configuration via LSP

If your client supports [`workspace/configuration`](#workspace-configuration-support),
you can configure JETLS in a client-specific manner.
As examples, we show the configuration methods for the VSCode extension
[`jetls-client`](https://marketplace.visualstudio.com/items?itemName=aviatesk.jetls-client), and the Zed extension
[`aviatesk/zed-julia#avi/JETLS`](https://github.com/aviatesk/zed-julia/tree/avi/JETLS).

#### VSCode (`jetls-client` extension)

Configure JETLS in VSCode's settings.json file with `jetls-client.jetlsSettings`
section:

> Example `.vscode/settings.json`:

```json
{
  "jetls-client.jetlsSettings": {
    "full_analysis": {
      "debounce": 2.0
    },
    // Use JuliaFormatter instead of Runic
    "formatter": "JuliaFormatter",
    // Suppress unused argument warnings
    "diagnostic": {
      "patterns": [
        {
          "pattern": "lowering/unused-argument",
          "match_by": "code",
          "match_type": "literal",
          "severity": "off"
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

#### Zed (`aviatesk/zed-julia#avi/JETLS` extension)

Configure JETLS in Zed's settings.json file with the `lsp.JETLS.settings`
section:

> Example `.zed/settings.json`:

```json
{
  "lsp": {
    "JETLS": {
      // Required configuration items for starting the server
      "binary": {
        "path": "/path/to/julia/executable",
        "env": {
          "JETLS_DIRECTORY": "/path/to/JETLS/directory/"
        }
      },
      // JETLS configurations
      "settings": {
        "full_analysis": {
          "debounce": 2.0
        },
        // Use JuliaFormatter instead of Runic
        "formatter": "JuliaFormatter",
        // Suppress unused argument warnings
        "diagnostic": {
          "patterns": [
            {
              "pattern": "lowering/unused-argument",
              "match_by": "code",
              "match_type": "literal",
              "severity": "off"
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
