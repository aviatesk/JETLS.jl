export const JETLS_INSTALL_COMMAND =
  'julia -e \'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")\'';
export const JETLS_INSTALL_GUIDE_URL =
  "https://github.com/aviatesk/JETLS.jl/blob/master/jetls-client/README.md#getting-started";
export const JETLS_CHANGELOG_URL =
  "https://github.com/aviatesk/JETLS.jl/blob/master/jetls-client/CHANGELOG.md";
export const JETLS_MIGRATION_GUIDE_URL = `${JETLS_CHANGELOG_URL}#v020`;

/**
 * VS Code configuration section served to the server as its workspace
 * configuration (`workspace/configuration`), and therefore the only section
 * whose changes need announcing via `workspace/didChangeConfiguration`.
 */
export const JETLS_CLIENT_SETTINGS_SECTION = "jetls-client.settings";

/** Julia stderr substring that signals package precompilation has started. */
export const PRECOMPILING_MARKER = "Precompiling packages";

/**
 * Budget for Julia precompilation: bounds the whole version preflight and
 * re-arms the serve startup countdown when precompilation is detected.
 */
export const PRECOMPILATION_TIMEOUT_MS = 300000;

/**
 * How long to wait for the version preflight process to close after each
 * termination attempt (`kill()`, SIGKILL escalation, or `taskkill`).
 */
export const PREFLIGHT_TERMINATION_TIMEOUT_MS = 5000;

/**
 * Cap on accumulated version preflight stdout, which is only ever surfaced
 * as a single log line.
 */
export const PREFLIGHT_STDOUT_LIMIT = 64 * 1024;

/**
 * Budget for server startup without precompilation. For the socket and pipe
 * channels this spans spawn until the transport connection is established;
 * for stdio it bounds the whole `LanguageClient.start()` call.
 */
export const SERVER_START_TIMEOUT_MS = 60000;

/**
 * Grace period for `LanguageClient.stop()`. Also bounds how long
 * `deactivate` waits for an in-flight startup/restart lifecycle.
 */
export const LANGUAGE_SERVER_STOP_TIMEOUT_MS = 10_000;
