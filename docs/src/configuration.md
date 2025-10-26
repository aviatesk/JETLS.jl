# Configuration

JETLS supports various configuration options.
This documentation uses TOML format to describe the configuration schema.

## Available configurations

### `[full_analysis] debounce`

- **Type**: number (seconds)
- **Default**: `1.0`

Debounce time in seconds before triggering full analysis after a document
change. JETLS performs type-aware analysis using
[JET.jl](https://github.com/aviatesk/JET.jl) to detect potential errors.
Higher values reduce analysis frequency (saving CPU) but may feel less
responsive.

```toml
[full_analysis]
debounce = 2.0  # Wait 2 seconds after typing stops before analyzing
```

### `formatter`

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

### `[testrunner] executable`

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

### Method 1: Project-specific configuration file

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

1. Project-specific `.JETLSConfig.toml`
2. Editor configuration via LSP
3. Built-in defaults

The `.JETLSConfig.toml` file takes precedence, since it provides a
**client-agnostic** way to configure JETLS that works consistently across
all editors.
