/**
 * VS Code configuration section served to the server as its workspace
 * configuration (`workspace/configuration`), and therefore the only section
 * whose changes need announcing via `workspace/didChangeConfiguration`.
 */
export const JETLS_CLIENT_SETTINGS_SECTION = "jetls-client.settings";

/** Julia stderr substring that signals package precompilation has started. */
export const PRECOMPILING_MARKER = "Precompiling packages";

/**
 * Cap on accumulated version preflight stdout, which is only ever surfaced
 * as a single log line.
 */
export const PREFLIGHT_STDOUT_LIMIT = 64 * 1024;

/** Time budgets, in milliseconds. */
export const TIMEOUTS = {
  /**
   * Budget for Julia precompilation: bounds the whole version preflight,
   * re-arms the serve startup countdown when precompilation is detected, and
   * bounds the managed installation's post-install `jetls version` pin check,
   * which loads from the caches the installation just precompiled.
   */
  precompilation: 5 * 60 * 1000,
  /**
   * How long to wait for a spawned server or managed process to close after
   * each termination attempt (`kill()`, SIGKILL escalation, or `taskkill`).
   */
  processTermination: 5 * 1000,
  /**
   * Budget for server startup without precompilation. For the socket and pipe
   * channels this spans spawn until the transport connection is established;
   * for stdio it bounds the whole `LanguageClient.start()` call.
   */
  serverStart: 60 * 1000,
  /**
   * Grace period for `LanguageClient.stop()`. Also bounds how long
   * `deactivate` waits for an in-flight startup/restart lifecycle.
   */
  serverStop: 10 * 1000,
  /**
   * Budget for the managed installation's Julia version query
   * (`print(VERSION)`), which never legitimately runs long and so fails
   * fast when it hangs.
   */
  juliaVersion: 1 * 60 * 1000,
  /**
   * Budget for installing the pinned JETLS release, which downloads and
   * fully precompiles the JETLS dependency tree. Also bounds the
   * re-verification of an existing generation after an install-stamp
   * mismatch (e.g. a Julia patch update), which may re-precompile that tree
   * from scratch, and is reused as the install-lock wait budget.
   */
  install: 15 * 60 * 1000,
} as const;
