# Development notes

## Coding guidelines

This section contains meta-documentation related to development.
For more detailed coding guidelines, please refer to [AGENTS.md](./AGENTS.md),
which has been organized to be easily recognized by AI agents.

## `[sources]` dependencies

In JETLS, since we need to use packages that aren’t yet registered
(e.g., [JuliaLowering.jl](https://github.com/c42f/JuliaLowering.jl)) or
specific branches of [JET.jl](https://github.com/c42f/JuliaLowering.jl) and
[JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl),
the [Project.toml](./Project.toml) includes
[`[sources]` section](https://pkgdocs.julialang.org/v1/toml-files/#The-[sources]-section).
The `[sources]` section allows simply running `Pkg.instantiate()` to install all
the required versions of these packages on any environment, including the CI
setup especially.

On the other hand, it can sometimes be convenient to `Pkg.develop` some of the
packages listed in the `[sources]` section and edit their source code while
developing JETLS. In particular, to have Revise immediately pick up changes made
to those packages, we may need to keep them in locally editable directories.
However, we cannot run `Pkg.develop` directly on packages listed in the
`[sources]` section, e.g.:
```julia-repl
julia> Pkg.develop("JET")
ERROR: `path` and `url` are conflicting specifications
...
```
To work around this, you can temporarily comment out the `[sources]` section and
run `Pkg.develop("JET")`.
This lets you use any local JET implementation. After running `Pkg.develop("JET")`,
you can restore the `[sources]` section, and perform any most of `Pkg`
operations without any issues onward.
The same applies to the other packages listed in `[sources]`.

## When test fails locally

Some of JETLS's test cases depend on specific implementation details of dependency packages
(especially JET and JS/JL), and may fail unless those dependency packages are
from the exact commits specified in [Project.toml](./Project.toml), as mentioned above.

It should be noted that during development, if the versions of those packages
already installed in your locally cloned JETLS environment are not updated to
the latest ones, you may see some tests fail. In such cases, make sure to run
`Pkg.update()` and re-run the tests.

## `JETLS_DEV_MODE`

JETLS has a development mode that can be enabled through the `JETLS_DEV_MODE`
[preference](https://github.com/JuliaPackaging/Preferences.jl).
When this mode is enabled, the language server enables several features to aid
in development:
- Automatic loading of Revise when starting the server, allowing changes to be
  applied without restarting
- Uses `@invokelatest` in message handling to ensure that changes made by Revise
  are reflected without terminating the `runserver` loop

Note that error handling behavior (whether errors are caught or propagated) is
controlled by `JETLS_TEST_MODE`, not `JETLS_DEV_MODE`.
See the "[`JETLS_TEST_MODE`](#jetls_test_mode)" section for details.

You can configure `JETLS_DEV_MODE` using Preferences.jl:
```julia-repl
julia> using Preferences

julia> Preferences.set_preferences!("JETLS", "JETLS_DEV_MODE" => true; force=true) # enable the dev mode
```
Alternatively, you can directly edit the LocalPreferences.toml file.

While `JETLS_DEV_MODE` is disabled by default, we _strongly recommend enabling
it during JETLS development_. For development work, we suggest creating the
following LocalPreferences.toml file in the root directory of this repository:
> LocalPreferences.toml
```toml
[JETLS]
JETLS_DEV_MODE = true # enable the dev mode of JETLS

[JET]
JET_DEV_MODE = true # additionally, allow JET to be loaded on nightly
```

## `JETLS_TEST_MODE`

JETLS has a test mode that controls error handling behavior during testing.
When `JETLS_TEST_MODE` is enabled, the server disables the `try`/`catch` error
recovery in message handling, ensuring that errors are properly raised during
tests rather than being suppressed.

This mode is configured through LocalPreferences.toml and is automatically
enabled in the test environment (see [test/LocalPreferences.toml](./test/LocalPreferences.toml)).

The error handling behavior in `handle_message` follows this logic:
- When `!JETLS_TEST_MODE`: Errors are caught and logged, allowing the server to continue running
- When `!!JETLS_TEST_MODE`: Errors are propagated, ensuring test failures are properly detected

For general users, the server runs with `JETLS_TEST_MODE` disabled by default,
providing error recovery to prevent server crashes during normal use.

## Precompilation

JETLS uses [precompilation](https://julialang.github.io/PrecompileTools.jl/stable/)
to reduce the latency between server startup and the user receiving first
responses.
Once you install the JETLS package and precompile it, the language server will
start up quickly afterward (until you upgrade the JETLS version), providing
significant benefits from the user's perspective.

However, during development, when you're frequently rewriting JETLS code itself,
running time-consuming precompilation after each modification might be a waste
of time. In such cases, you can disable precompilation by adding the following
settings to your LocalPreferences.toml:
> LocalPreferences.toml
```toml
[JETLS]
precompile_workload = false # Disable precompilation for JETLS

[JET]
precompile_workload = false # Optionally disable precompilation for JET if you're developing it simultaneously
```

## Dynamic registration

This language server supports
[dynamic registration](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#client_registerCapability)
of LSP features.

With dynamic registration, for example, the server can switch the formatting
engine when users change their preferred formatter, or disable specific LSP
features upon configuration change, without restarting the server process
(although neither of these features has been implemented yet).

Dynamic registration is also convenient for language server development.
When enabling LSP features, the server needs to send various capabilities and
options to the client during initialization.
With dynamic registration, we can rewrite these activation options and re-enable
LSP features dynamically, i.e. without restarting the server process.

For example, you can dynamically add `,` as a `triggerCharacter` for
"completion" as follows. First, [launch `jetls-client` ](#steps) in VSCode[^vscode],
then add the following diff to unregister the already enabled completion feature.
Make a small edit to the file the language server is currently analyzing to send
some request from the client to the server. This will allow Revise to apply this
diff to the server process via the dev mode callback (see the `JETLS.main` entrypoint),
which should disable the completion feature:
```diff
diff --git a/src/completions.jl b/src/completions.jl
index 29d0db5..728da8f 100644
--- a/src/completions.jl
+++ b/src/completions.jl
@@ -21,6 +21,11 @@ completion_options() = CompletionOptions(;
 const COMPLETION_REGISTRATION_ID = "jetls-completion"
 const COMPLETION_REGISTRATION_METHOD = "textDocument/completion"

+let unreg = Unregistration(COMPLETION_REGISTRATION_ID, COMPLETION_REGISTRATION_METHOD)
+    unregister(currently_running, unreg)
+end
+
 function completion_registration()
     (; triggerCharacters, resolveProvider, completionItem) = completion_options()
     documentSelector = DocumentFilter[
```

> [!tip]
> You can add the diff above anywhere Revise can track and apply changes, i.e.
> any top-level scope in the `JETLS` module namespace or any subroutine
> of `_handle_message` that is reachable upon the request handling.

> [!warning]
> Note that `currently_running::Server` is a global variable that is only
> defined in `JETLS_DEV_MODE`. The use of this global variable should be limited
> to such development purposes and should not be included in normal routines.

[^vscode]: Of course, the hack explained here is only possible with clients that
  support dynamic registration. VSCode is currently one of the frontends that
  best supports dynamic registration.

After that, delete that diff and add the following diff:
```diff
diff --git a/src/completions.jl b/src/completions.jl
index 29d0db5..7609a6a 100644
--- a/src/completions.jl
+++ b/src/completions.jl
@@ -9,6 +9,7 @@ const COMPLETION_TRIGGER_CHARACTERS = [
     "@",  # macro completion
     "\\", # LaTeX completion
     ":",  # emoji completion
+    ",",  # new trigger character
     NUMERIC_CHARACTERS..., # allow these characters to be recognized by `CompletionContext.triggerCharacter`
 ]

@@ -36,6 +37,8 @@ function completion_registration()
             completionItem))
 end

+register(currently_running, completion_registration())
+
 # completion utils
 # ================
```

This should re-enable completion, and now completion will also be triggered when
you type `,`.

For these reasons, when adding new LSP features, check whether the feature
supports dynamic/static registration, and if it does, actively opt-in to use it.
That is, register it via the `client/registerCapability` request in response to
notifications sent from the client, most likely `InitializedNotification`.
The `JETLS.register` utility is especially useful for this purpose.

## Release process

JETLS avoids dependency conflicts with packages being analyzed by rewriting the
UUIDs of its dependencies and vendoring them. This allows JETLS to have its own
isolated copies of dependencies that won't conflict with the packages users are
analyzing.

### Branch strategy

- `master`: Development branch where regular development happens. Dependencies
  keep their original UUIDs.
- `release`: Distribution branch for users. Dependencies are vendored with
  rewritten UUIDs and the `vendor/` directory contains copies of all dependency
  packages.
- `releases/YYYY-MM-DD`: Release preparation branches. These branches are
  created from `release`, merged with `master`, vendored, and then merged back
  into `release` via pull requests on GitHub. These branches must be kept
  (not deleted) because the `release` branch's `[sources]` entries reference
  them by name.

### Release procedure

1. Create a release branch from `release` and merge `master`
   ```bash
   git checkout release
   git pull origin release
   JETLS_VERSION='YYYY-MM-DD'
   git checkout -b releases/$JETLS_VERSION
   git merge master -X theirs
   ```

2. Vendor dependency packages
   ```bash
   julia --startup-file=no --project=. scripts/vendor-deps.jl --source-branch=master
   ```
   This script performs the following:
   - Fetches the latest `Project.toml` from the specified source branch (`master`)
   - Backs it up as `Project.toml.bak`
   - Cleans up `Manifest.toml` and runs `Pkg.update()`
   - Loads JETLS and collects dependency packages from `Base.loaded_modules`
   - Copies each package to `vendor/` and rewrites its UUID
   - Removes unused weakdeps and extensions from vendored packages
   - Updates `Project.toml` with vendored UUIDs and `[sources]` entries
   - Cleans up `Manifest.toml` and runs `Pkg.instantiate()`

3. Commit and push
   ```bash
   git add -A
   git commit -m "release: $JETLS_VERSION"
   git push -u origin releases/$JETLS_VERSION
   ```
   **Important**: The commit message must follow the `release: YYYY-MM-DD` format
   exactly. The documentation CI extracts this date to display in the release
   documentation's index page.

4. Create a pull request from `releases/YYYY-MM-DD` to `release` and merge it
   using "Create a merge commit" (not squash or rebase). This preserves the
   merge history from `master`, allowing you to track which `master` commits
   are included in `release`. The CI will run tests on the vendored environment
   before merging. If merging locally, use `git merge` (not `git merge --squash`
   or `git rebase`).

5. Do NOT delete the `releases/YYYY-MM-DD` branch after merging. These branches
   must be kept because the `release` branch's `[sources]` entries reference
   them by name. Keeping them also allows users to install specific releases
   via the Julia package manager.

To check which `master` commits are not yet included in `release`:
```bash
git log master ^release --oneline
```

Note: `vendor-deps.jl` generates UUIDs using `uuid5(original_uuid, "JETLS-vendor")`.
This is deterministic, so the same vendored UUID is always generated for the same
original UUID, ensuring consistency across multiple vendoring operations.

### Local testing of vendored environment

To test the vendored environment locally without committing:
```bash
julia --startup-file=no --project=. scripts/vendor-deps.jl --source-branch=master --local
```
The `--local` flag uses local path references in `[sources]` instead of GitHub
URLs, allowing you to test with the locally generated `vendor/` directory.

## `jetls-client` development

The [`jetls-client`](./jetls-client) directory contains the VSCode language
client extension for JETLS.

### Development setup

1. Navigate to the `jetls-client` directory:
   ```bash
   cd jetls-client
   ```

2. Install dependencies:
   ```bash
   npm install
   ```

3. Build the extension:
   ```bash
   npm run build
   ```
   Or for development with watch mode:
   ```bash
   npm run build:watch
   ```

### Testing the extension locally

To test the extension locally in VSCode:

1. Open the `jetls-client` directory in VSCode
2. Press F5 to launch the Extension Development Host
3. The extension will be loaded in the new VSCode window

### Publishing

To package the extension for distribution:

```bash
cd jetls-client
vsce publish -m "jetls-client: v0.x.y"
```

This creates a `.vsix` file that can be installed in VSCode and publish it to
the marketplace.
