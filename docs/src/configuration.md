# JETLS configuration

JETLS supports various configuration options.
This documentation uses TOML format to describe the configuration schema.

## Available configurations

### [`[full_analysis] debounce`](@id config/full_analysis-debounce)

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

### [`[diagnostics]`](@id config/diagnostics)

Configure how JETLS reports diagnostic messages (errors, warnings, infos, hints)
in your editor. JETLS uses hierarchical diagnostic codes in the format
`"category/kind"` (following the [LSP specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnostic))
to allow fine-grained control over which diagnostics to show and at what
severity level.

See the [Diagnostics](@ref) section for complete diagnostic reference
including all available codes, their meanings, and examples.

#### [`[diagnostics] enabled`](@id config/diagnostics-enabled)

- **Type**: boolean
- **Default**: `true`

Enable or disable all JETLS diagnostics. When set to `false`, no diagnostic
messages will be shown.

```toml
[diagnostics]
enabled = false  # Disable all diagnostics
```

#### [`[diagnostics.codes]`](@id config/diagnostics-codes)

Fine-grained control over individual diagnostic codes or categories. Each
diagnostic in JETLS has a hierarchical code in the format `"category/kind"`
(e.g., `"lowering/unused-argument"`, `"inference/undef-global-var"`).

See the [Diagnostic reference](diagnostics.md#Diagnostic-reference) section for
a complete list of all available diagnostic codes, their default severity
levels, and detailed explanations with examples.

##### Configuration syntax

Each diagnostic code is configured by assigning a severity value directly:

```toml
[diagnostics.codes]
"diagnostic-code" = "severity-value"
```

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
- `"error"` or `1`: Error
- `"warning"` or `"warn"` or `2`: Warning
- `"information"` or `"info"` or `3`: Information
- `"hint"` or `4`: Hint
- `"off"` or `0`: Disabled

##### Pattern matching and priority

You can configure diagnostics at three levels, with more specific configurations
overriding less specific ones:

1. **Specific code** (highest priority): Applies to a single diagnostic (e.g., `"lowering/unused-argument"`)
2. **Category pattern**: Applies to all diagnostics in a category (e.g., `"lowering/*"`, `"inference/*"`)
3. **Wildcard (`"*"`)** (lowest priority): Applies to all diagnostics

Example showing priority:

```toml
[diagnostics.codes]
"*" = "hint"                        # All diagnostics shown as hints
"lowering/*" = "error"              # Lowering diagnostics shown as errors (overrides "*")
"lowering/unused-argument" = "off"  # This specific diagnostic disabled (overrides "lowering/*")
```

!!! note
    When [`diagnostics.enabled`](@ref config/diagnostics-enabled) is `false`,
    all diagnostics are disabled regardless of these settings.
    Also note that `diagnostics.enabled = false` is equivalent to setting:
    ```toml
    [diagnostics.code]
    "*" = "off"
    ```

#### `[diagnostics]` configuration examples

```toml
[diagnostics]
enabled = true

[diagnostics.codes]
# Make all lowering diagnostics warnings
"lowering/*" = "warning"

# Disable inference diagnostics entirely
"inference/*" = "off"

# Show unused arguments as hints (overrides category setting)
"lowering/unused-argument" = "hint"

# Completely disable unused local variable diagnostics
"lowering/unused-local" = 0

# Use integer severity values
"syntax/parse-error" = 1  # Error

# Set baseline for all diagnostics with specific overrides
"*" = "hint"
"syntax/*" = "error"
```

See the [Configuring diagnostics](@ref) section for additional examples and common use cases.

### [`[testrunner] executable`](@id config/testrunner-executable)

- **Type**: string (path)
- **Default**: `"testrunner"` (or `"testrunner.bat"` on Windows)

Path to the [TestRunner.jl](https://github.com/aviatesk/TestRunner.jl)
executable for running individual `@testset` blocks and `@test` cases. If not
specified, JETLS looks for `testrunner` in your `PATH` (typically
`~/.julia/bin/testrunner`).

```toml
[testrunner]
executable = "/custom/path/to/testrunner"
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

[testrunner]
executable = "/custom/path/to/testrunner"

# Use JuliaFormatter instead of Runic
formatter = "JuliaFormatter"
```

### Method 2: Editor configuration via LSP

If your client supports [`workspace/configuration`](#workspace-configuration-support),
you can configure JETLS in a client-specific manner.
As examples, we show the configuration methods for the VSCode extension
`jetls-client`, and the Zed extension
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
    "testrunner": {
      "executable": "/custom/path/to/testrunner"
    },
    "formatter": "JuliaFormatter"
  }
}
```

See [`package.json`](https://github.com/aviatesk/JETLS.jl/blob/master/package.json)
for the complete list of available VSCode settings and their descriptions.

#### Zed ([`aviatesk/zed-julia#avi/JETLS`](https://github.com/aviatesk/zed-julia/tree/avi/JETLS) extension)

Configure JETLS in Zed's settings.json file with the `lsp.JETLS.settings`
section:

> Example `.zed/settings.json`:

```json
{
  "lsp": {
    "JETLS": {
      // Required configuration items for starting the server
      "binary": {
        // ...
      },
      // JETLS configurations
      "settings": {
        "full_analysis": {
          "debounce": 2.0
        },
        "testrunner": {
          "executable": "/custom/path/to/testrunner"
        },
        "formatter": "JuliaFormatter"
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
