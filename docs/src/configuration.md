# JETLS configuration

JETLS supports various configuration options.
This documentation uses TOML format to describe the configuration schema.

A [JSON Schema](https://json-schema.org/) for `.JETLSConfig.toml` is available:
[jetls-config.schema.json](https://github.com/aviatesk/JETLS.jl/releases/latest/download/jetls-config.schema.json)

## [Configuration schema](@id config/schema)

```toml
formatter = "Runic"                # String preset: "Runic" (default) or "JuliaFormatter"

[full_analysis]
debounce = 1.0                     # number (seconds), default: 1.0
auto_instantiate = true            # boolean, default: true

[formatter.custom]                 # Or custom formatter configuration
executable = ""                    # string (path), optional
executable_range = ""              # string (path), optional

[diagnostic]
enabled = true                     # boolean, default: true
all_files = true                   # boolean, default: true
allow_unused_underscore = false    # boolean, default: false

[[diagnostic.patterns]]
pattern = ""                       # string, required
match_by = ""                      # string, required, "code" or "message"
match_type = ""                    # string, required, "literal" or "regex"
severity = ""                      # string or number, required, "error"/"warning"/"warn"/"information"/"info"/"hint"/"off" or 0/1/2/3/4
path = ""                          # string (optional), glob pattern for file paths

[completion.latex_emoji]
strip_prefix = false               # boolean, default: (unset) auto-detect

[completion.method_signature]
prepend_inference_result = false   # boolean, default: (unset) auto-detect

[code_lens]
references = false                 # boolean, default: false
testrunner = true                  # boolean, default: true

[inlay_hint]
block_end_min_lines = 25           # integer, default: 25

[testrunner]
executable = "testrunner"          # string, default: "testrunner" (or "testrunner.bat" on Windows)
```

## [Configuration reference](@id config/reference)

- [`[full_analysis]`](@ref config/full_analysis)
    - [`[full_analysis] debounce`](@ref config/full_analysis-debounce)
    - [`[full_analysis] auto_instantiate`](@ref config/full_analysis-auto_instantiate)
- [`formatter`](@ref config/formatter)
- [`[diagnostic]`](@ref config/diagnostic)
    - [`[diagnostic] enabled`](@ref config/diagnostic-enabled)
    - [`[diagnostic] all_files`](@ref config/diagnostic-all_files)
    - [`[diagnostic] allow_unused_underscore`](@ref config/diagnostic-allow_unused_underscore)
    - [`[[diagnostic.patterns]]`](@ref config/diagnostic-patterns)
- [`[completion]`](@ref config/completion)
    - [`[completion.latex_emoji] strip_prefix`](@ref config/completion-latex_emoji-strip_prefix)
    - [`[completion.method_signature] prepend_inference_result`](@ref config/completion-method_signature-prepend_inference_result)
- [`[code_lens]`](@ref config/code_lens)
    - [`[code_lens] references`](@ref config/code_lens-references)
    - [`[code_lens] testrunner`](@ref config/code_lens-testrunner)
- [`[inlay_hint]`](@ref config/inlay_hint)
    - [`[inlay_hint] block_end_min_lines`](@ref config/inlay_hint-block_end_min_lines)
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

When enabled, JETLS automatically runs `Pkg.resolve()` and `Pkg.instantiate()` for
packages that have not been instantiated yet (e.g., freshly cloned repositories).
This allows full analysis to work immediately upon opening such packages.
When no manifest file exists, JETLS first creates a
[versioned manifest](https://pkgdocs.julialang.org/v1/toml-files/#Different-Manifests-for-Different-Julia-versions)
(e.g., `Manifest-v1.12.toml`).

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

See the [Diagnostic](@ref diagnostic) section for complete diagnostic reference
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

#### [`[diagnostic] all_files`](@id config/diagnostic-all_files)

- **Type**: boolean
- **Default**: `true`

Enable or disable diagnostics for unopened files. When enabled, JETLS reports
diagnostics for all Julia files in the workspace. When disabled, diagnostics
are only reported for files currently open in the editor.

This setting affects both [`JETLS/live` and `JETLS/save`](@ref diagnostic/source)
diagnostics. For `JETLS/live`, lowering-based analysis for unopened files is
skipped when disabled (though the performance impact is minimal since lowering
analysis is usually pretty fast). For `JETLS/save`, full analysis still runs;
only reporting is suppressed. Disabling this can be useful to reduce noise when
there are many warnings across the workspace.

```toml
[diagnostic]
all_files = false  # Disable diagnostics for unopened files
```

#### [`[diagnostic] allow_unused_underscore`](@id config/diagnostic-allow_unused_underscore)

- **Type**: boolean
- **Default**: `true`

When enabled, unused variable diagnostics
([`lowering/unused-argument`](@ref diagnostic/reference/lowering/unused-argument) and
[`lowering/unused-local`](@ref diagnostic/reference/lowering/unused-local)) are suppressed
for names starting with `_` (underscore). This follows the common convention
in many programming languages where `_`-prefixed names indicate intentionally
unused variables.

```toml
[diagnostic]
allow_unused_underscore = false  # Report all unused variables
```

#### [`[[diagnostic.patterns]]`](@id config/diagnostic-patterns)

Fine-grained control over diagnostics through pattern matching against either
[diagnostic codes](@ref diagnostic/code) or messages.

See the [diagnostic reference](@ref diagnostic/reference) section for
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
  patterns like `"Macro name .* not found"`. This value is also used as the key
  when [merging configurations](@ref config/merge) from different sources.
- `match_by` (**Type**: string): What to match against
  - `"code"`: Match against [diagnostic code](@ref diagnostic/code) (e.g., `"lowering/unused-argument"`)
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

[Severity level](@ref diagnostic/severity) to apply.
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

See the [configuring diagnostics](@ref diagnostic/configuring) section for
additional examples and common use cases.

### [`[completion]`](@id config/completion)

Configure completion behavior.

#### [`[completion.latex_emoji] strip_prefix`](@id config/completion-latex_emoji-strip_prefix)

- **Type**: boolean
- **Default**: (unset) auto-detect based on client

Controls whether to strip the `\` or `:` prefix from LaTeX/emoji completion item
labels.

Some editors (e.g., Zed) don't handle backslash characters in the LSP `sortText`
field, falling back to sorting by `label`. This can cause the expected completion
item to not appear at the top when typing sequences like `\le` for `≤`.

When set to `true`, JETLS strips the prefix from the label (e.g., `\le` becomes
`le`), allowing these editors to sort completions correctly.

When set to `false`, JETLS keeps the full label with the prefix, which works
correctly in editors (e.g., VSCode) that properly handle backslash characters
in the `sortText` field.

When not set (default), JETLS auto-detects based on the client name and applies
the appropriate behavior. Note that the auto-detection only covers a limited set
of known clients, so if you experience LaTeX/emoji completion sorting issues
(e.g., expected items not appearing at the top), try explicitly setting this
option.

```toml
[completion.latex_emoji]
strip_prefix = true  # Force prefix stripping for clients with sortText issues
```

!!! tip "Help improve auto-detection"
    If explicitly setting this option clearly improves behavior for your client,
    consider submitting a PR to add your client to the [auto-detection](https://github.com/aviatesk/JETLS.jl/blob/14fdc847252579c27e41cd50820aee509f8fd7bd/src/completions.jl#L386) logic.

#### [`[completion.method_signature] prepend_inference_result`](@id config/completion-method_signature-prepend_inference_result)

- **Type**: boolean
- **Default**: (unset) auto-detect based on client

Controls whether to prepend inferred return type information to the documentation
of method signature completion items.

In some editors (e.g., Zed), additional information like inferred return type
displayed when an item is selected may be cut off in the UI when the method
signature text is long.

When set to `true`, JETLS prepends the return type as a code block to the
documentation, ensuring it is always visible.

When set to `false`, the return type is only shown alongside the completion item
(as `CompletionItem.detail` in LSP terms, which may be cut off in some editors).

When not set (default), JETLS auto-detects based on the client name and applies
the appropriate behavior. Note that the auto-detection only covers a limited set
of known clients, so if you experience issues with return type visibility, try
explicitly setting this option.

```toml
[completion.method_signature]
prepend_inference_result = true  # Show return type in documentation
```

!!! tip "Help improve auto-detection"
    If explicitly setting this option clearly improves behavior for your client,
    consider submitting a PR to add your client to the [auto-detection](https://github.com/aviatesk/JETLS.jl/blob/14fdc847252579c27e41cd50820aee509f8fd7bd/src/completions.jl#L386) logic.

### [`[code_lens]`](@id config/code_lens)

Configure code lens behavior.

#### [`[code_lens] references`](@id config/code_lens-references)

- **Type**: boolean
- **Default**: `false`

Show reference counts for top-level symbols (functions, structs, constants,
abstract types, primitive types, modules). When enabled, JETLS displays a code
lens above each symbol showing how many times it is referenced in the codebase.
Clicking the code lens opens the references panel.

```toml
[code_lens]
references = true  # Enable reference count code lenses
```

#### [`[code_lens] testrunner`](@id config/code_lens-testrunner)

- **Type**: boolean
- **Default**: `true`

Enable or disable [TestRunner code lenses](@ref testrunner/features/code-lens).
When enabled, JETLS shows "Run" and "Debug" code lenses above `@testset` blocks
for running individual tests.

Some editors (e.g., Zed[^zed_code_lens_testrunner]) display code lenses as code actions, which can cause
duplication when both code lenses and code actions are shown for the same
functionality. In such cases, you may want to disable this setting.

[^zed_code_lens_testrunner]: The [aviatesk/zed-julia](https://github.com/aviatesk/zed-julia) extension defaults this setting to `false` unless explicitly configured.

```toml
[code_lens]
testrunner = false  # Disable TestRunner code lenses
```

### [`[inlay_hint]`](@id config/inlay_hint)

Configure inlay hint behavior.

#### [`[inlay_hint] block_end_min_lines`](@id config/inlay_hint-block_end_min_lines)

- **Type**: integer
- **Default**: `25`

Minimum number of lines a block must span before JETLS displays an inlay hint
at its `end` keyword. Inlay hints show what construct is ending, such as
`module Foo`, `function foo` or `@testset "foo"`, helping navigate long blocks.

Supported block types include `module`, `function`, `macro`, `struct`,
`if`/`@static if`, `let`, `for`, `while`, and `@testset`.

```toml
[inlay_hint]
block_end_min_lines = 10  # Show hints for blocks with 10+ lines
```

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

See [TestRunner integration](@ref testrunner) for setup instructions.

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

#### [Server-agnostic clients (e.g., neovim, emacs lsp-mode, helix)](@id config/lsp-config/server-agnostic)

Settings should be placed under the `"jetls"` key, such that a request for the
`"jetls"` section produces an instance of the JETLS configuration
[schema](@ref config/schema). For example, neovim's built-in LSP client may be
configured as follows:

```lua
vim.lsp.config("jetls", {
  settings = {
    jetls = {
      full_analysis = {
        debounce = 2.0,
      },
      -- Use JuliaFormatter instead of Runic
      formatter = "JuliaFormatter",
      diagnostic = {
        patterns = [
          -- Suppress toplevel/inference warnings in test folder
          {
            pattern = "(toplevel|inference)/.*",
            match_by = "code",
            match_type = "regex",
            severity = "off",
            path = "test/**/*.jl",
          },
        ],
      },
      testrunner = {
        executable = "/path/to/custom/testrunner"
      },
    },
  },
})
```

## [Configuration priority](@id config/priority)

When multiple configuration sources are present, they are merged in priority
order (highest first):

1. File-based configuration (`.JETLSConfig.toml`)
2. Editor configuration via LSP (`workspace/configuration`)
3. Built-in defaults

File-based configuration (`.JETLSConfig.toml`) takes precedence as it provides
a **client-agnostic** way to configure JETLS that works consistently across all
editors.

### [Configuration merging](@id config/merge)

For array-type configuration fields (such as [`diagnostic.patterns`](@ref config/diagnostic-patterns)),
entries from both LSP config and file config are merged rather than one
completely overriding the other. Entries with same keys are merged with file
config taking precedence, while entries unique to either source are preserved.
