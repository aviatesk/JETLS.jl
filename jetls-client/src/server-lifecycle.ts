import * as vscode from "vscode";
import { LogOutputChannel } from "vscode";

import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  State,
} from "vscode-languageclient/node";

import { CoalescingTaskRunner } from "./coalescing-task-runner";
import { JETLS_CLIENT_SETTINGS_SECTION, TIMEOUTS } from "./constants";
import {
  ensureManagedJETLS,
  invalidateInstallStamp,
  LAST_USED_REFRESH_INTERVAL,
  ManagedInstallationCancelledError,
  ManagedJETLSError,
  managedJETLSCommands,
  touchManagedInstallation,
} from "./managed-installation";
import {
  getServerConfig,
  hasServerConfigChanged,
  isManagedExecutable,
  ServerConfig,
} from "./server-config";
import {
  JETLSCommands,
  resolveJETLSCommands,
  VersionPreflight,
} from "./preflight";
import { StartupStatusBar } from "./status-bar";
import {
  connectPipeTransport,
  connectSocketTransport,
  TransportOptions,
} from "./transport";

let languageClient: LanguageClient;
let outputChannel: LogOutputChannel;
let statusBar: StartupStatusBar;
let deactivating = false;
let currentServerConfig: ServerConfig | null = null;
let cancelServerStartup: (() => void) | undefined;
let managedStoragePath: string;

export function activateServerLifecycle(
  channel: LogOutputChannel,
  bar: StartupStatusBar,
  context: vscode.ExtensionContext,
): void {
  outputChannel = channel;
  statusBar = bar;
  managedStoragePath = context.globalStorageUri.fsPath;
  deactivating = false;
}

function executableEnvironment(executable: {
  env?: Record<string, string>;
}): NodeJS.ProcessEnv {
  return {
    ...process.env,
    ...executable.env,
  };
}

const versionPreflight = new VersionPreflight({
  timeoutMs: TIMEOUTS.precompilation,
  terminationTimeoutMs: TIMEOUTS.processTermination,
  platform: process.platform,
  appendLine: (message) => outputChannel.appendLine(message),
  onPrecompiling: () => statusBar.show("precompiling"),
});

// The one-line notification and tooltip text; the full failure details
// stay in the output channel. Setup failures always arrive as
// `ManagedJETLSError`, so the fallback prefix only describes failures of
// the spawned server itself.
function managedFailureSummary(err: Error): string {
  if (err instanceof ManagedJETLSError) {
    return err.summary;
  }
  const newline = err.message.indexOf("\n");
  const line = newline === -1 ? err.message : err.message.slice(0, newline);
  return `Failed to start the managed JETLS server: ${line}`;
}

function showManagedFailureNotification(err: Error): void {
  const details = err instanceof ManagedJETLSError ? err : undefined;
  const retryButton = "Retry";
  const outputButton = "Show JETLS output";
  const settingsButton = "Open settings";
  const buttons: string[] = [];
  // A configuration problem needs a settings change before a retry can
  // help.
  if (details === undefined || details.retryable) {
    buttons.push(retryButton);
  }
  buttons.push(outputButton);
  if (details !== undefined && !details.retryable) {
    buttons.push(settingsButton);
  }
  vscode.window
    .showErrorMessage(managedFailureSummary(err), ...buttons)
    .then((selection) => {
      if (selection === retryButton) {
        requestLanguageServerRestart();
      } else if (selection === outputButton) {
        void vscode.commands.executeCommand("jetls-client.showOutput");
      } else if (selection === settingsButton) {
        void vscode.commands.executeCommand(
          "workbench.action.openSettings",
          "jetls-client.executable",
        );
      }
    });
}

// Managed failures take two distinct paths. A setup failure happens before
// `ensureManagedJETLS` produced a verified installation: nothing new is
// known about any generation's verified state, so no install stamp is
// touched. A server failure comes from a process launched out of a
// verified generation and is the one corruption signal the install stamp
// cannot see, so the stamp of the generation this lifecycle actually used
// is dropped: the next start then re-verifies that generation and
// replaces it with a fresh one if broken.
function handleManagedSetupFailure(err: Error): void {
  outputChannel.appendLine(
    `[jetls-client] Failed to set up the managed JETLS: ${err.message}`,
  );
  showManagedFailureNotification(err);
}

function handleManagedServerFailure(err: Error, depotPath: string): void {
  outputChannel.appendLine(
    `[jetls-client] Failed to start the managed JETLS: ${err.message}`,
  );
  void invalidateInstallStamp(depotPath).catch((err) => {
    const message = err instanceof Error ? err.message : String(err);
    outputChannel.appendLine(
      `[jetls-client] Failed to invalidate the managed install stamp: ${message}.`,
    );
  });
  showManagedFailureNotification(err);
}

// Handles spawn errors of custom executable configurations.
function handleSpawnError(err: Error, command: string): void {
  const errno = err as NodeJS.ErrnoException;
  if (errno.code === "ENOENT") {
    outputChannel.appendLine(
      `[jetls-client] Failed to start JETLS: Command not found: ${command}`,
    );
    outputChannel.appendLine(`[jetls-client] PATH: ${process.env.PATH}`);
    void vscode.window.showErrorMessage(
      `JETLS executable not found: "${command}". Check the ` +
        "`jetls-client.executable` setting, or remove its `path`/command to " +
        "use the managed installation. If the command was just installed, " +
        "restart VS Code to refresh the PATH.",
    );
  } else {
    outputChannel.appendLine(
      `[jetls-client] Failed to start JETLS: ${err.message}`,
    );
  }
}

// The stdio channel has no process-level startup monitoring (the language
// client library owns the spawned process), so bound `start()` itself and
// force-dispose the client on expiry.
function startWithTimeout(
  client: LanguageClient,
  timeoutMs: number,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const timeoutHandle = setTimeout(() => {
      void client.dispose().catch(() => undefined);
      reject(new Error("Timeout waiting for JETLS to start"));
    }, timeoutMs);
    client.start().then(
      () => {
        clearTimeout(timeoutHandle);
        resolve();
      },
      (err) => {
        clearTimeout(timeoutHandle);
        reject(err);
      },
    );
  });
}

async function startLanguageServer() {
  if (deactivating) {
    return;
  }
  // The previous server (whose installation the refresh kept alive) is
  // already stopped by the time a new start runs.
  stopManagedLastUsedRefresh();
  statusBar.show("checking");

  const serverConfig = getServerConfig();
  currentServerConfig = serverConfig;
  const managed = isManagedExecutable(serverConfig.executable);

  let resolvedCommands: JETLSCommands;
  let spawnEnv: NodeJS.ProcessEnv;
  let managedDepotPath: string | undefined;
  if (managed) {
    const executable = serverConfig.executable as {
      threads?: string;
      env?: Record<string, string>;
    };
    let installation;
    const setupAbort = new AbortController();
    managedSetupAbort = setupAbort;
    let installProgress: vscode.Progress<{ message?: string }> | undefined;
    try {
      installation = await ensureManagedJETLS({
        storagePath: managedStoragePath,
        environment: executableEnvironment(executable),
        logger: (message) =>
          outputChannel.appendLine(`[jetls-client] ${message}`),
        progress: (message) => {
          statusBar.showManagedProgress(message);
          installProgress?.report({
            message: message.startsWith("Installing JETLS: ")
              ? message.slice("Installing JETLS: ".length)
              : message,
          });
        },
        forceInstall: forceManagedInstall,
        signal: setupAbort.signal,
        // Live output lines make a long installation visibly alive: the
        // status bar keeps the coarse phase while its tooltip and the
        // progress notification tick with the latest line.
        onInstallOutput: (line) => {
          statusBar.showManagedProgressDetail(line);
          installProgress?.report({ message: line });
        },
        // The actual installation (the only open-ended long step) gets a
        // cancellable progress notification for its duration; routine
        // starts stay on the status bar alone.
        onInstallStep: () => {
          let end!: () => void;
          const done = new Promise<void>((resolve) => {
            end = resolve;
          });
          void vscode.window.withProgress(
            {
              location: vscode.ProgressLocation.Notification,
              title: "Installing JETLS",
              cancellable: true,
            },
            (progress, token) => {
              installProgress = progress;
              token.onCancellationRequested(() => setupAbort.abort());
              return done;
            },
          );
          return () => {
            installProgress = undefined;
            end();
          };
        },
      });
      forceManagedInstall = false;
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      if (
        !deactivating &&
        !restartRunner.pending &&
        !(error instanceof ManagedInstallationCancelledError)
      ) {
        statusBar.showManagedFailure(managedFailureSummary(error));
        handleManagedSetupFailure(error);
      } else if (!deactivating && !restartRunner.pending) {
        // Cancelled from the installation notification (a restart or
        // deactivation would have set the flags above): no failure UI,
        // but the status bar must not keep showing progress, and the
        // notification offers the way back in.
        statusBar.showManagedFailure("The JETLS installation was cancelled.");
        const retryButton = "Retry";
        const outputButton = "Show JETLS output";
        void vscode.window
          .showInformationMessage(
            "The JETLS installation was cancelled.",
            retryButton,
            outputButton,
          )
          .then((choice) => {
            if (choice === retryButton) {
              requestLanguageServerRestart();
            } else if (choice === outputButton) {
              void vscode.commands.executeCommand("jetls-client.showOutput");
            }
          });
      }
      throw error;
    } finally {
      if (managedSetupAbort === setupAbort) {
        managedSetupAbort = undefined;
      }
    }
    outputChannel.appendLine(
      `[jetls-client] Using managed JETLS from ${installation.depotPath}`,
    );
    managedDepotPath = installation.depotPath;
    resolvedCommands = managedJETLSCommands(installation, executable.threads);
    spawnEnv = installation.env;
  } else {
    try {
      resolvedCommands = resolveJETLSCommands(serverConfig.executable);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      if (!deactivating) {
        statusBar.show("failed");
        outputChannel.appendLine(`[jetls-client] ${error.message}`);
        vscode.window.showErrorMessage(error.message);
      }
      throw error;
    }
    spawnEnv = Array.isArray(serverConfig.executable)
      ? { ...process.env }
      : executableEnvironment(serverConfig.executable);
  }
  const { command: baseCommand, versionArgs, serveArgs } = resolvedCommands;

  let commChannel = serverConfig.communicationChannel;
  if (commChannel === "auto") {
    // Auto-detect best default based on environment
    commChannel = "pipe";
    if (vscode.env.remoteName) {
      // We're in a remote environment (SSH, WSL, Container, etc.)
      outputChannel.appendLine(
        `[jetls-client] Detected remote environment: ${vscode.env.remoteName}`,
      );

      // For WSL and SSH, pipe still works well
      // For containers, stdio might be safer
      if (
        vscode.env.remoteName === "dev-container" ||
        vscode.env.remoteName === "attached-container"
      ) {
        commChannel = "stdio";
        outputChannel.appendLine(
          `[jetls-client] Using stdio for container environment`,
        );
      }
    }
    outputChannel.appendLine(
      `[jetls-client] Auto-selected communication channel: ${commChannel}`,
    );
  }

  outputChannel.appendLine(
    `[jetls-client] Using communication channel: ${commChannel}`,
  );

  // On Windows, custom commands may resolve to batch files (e.g. the
  // `Pkg.Apps` launcher shim), which must be spawned with shell: true. The
  // managed server spawns the Julia executable directly and never needs
  // the shell.
  const useShell = !managed && process.platform === "win32";
  const spawnOptions: { env: NodeJS.ProcessEnv; shell?: boolean } = {
    env: spawnEnv,
    ...(useShell ? { shell: true } : {}),
  };

  // `ensureManagedJETLS` already validates the managed installation
  // (existence on every start, pinned version via verification or the
  // install stamp), so the version preflight would only repeat a full JETLS
  // load. Run it for custom executables only, where nothing else has
  // checked the command.
  if (!managed) {
    try {
      await versionPreflight.run(baseCommand, versionArgs, spawnOptions);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      // If a restart request is queued, this failure is most likely the
      // deliberate kill from `requestLanguageServerRestart`; skip the error
      // surface here and let the rerun repaint the status from "checking".
      if (!deactivating && !restartRunner.pending) {
        statusBar.show("failed");
        handleSpawnError(error, baseCommand);
      }
      throw error;
    }
  }

  if (deactivating) {
    return;
  }
  statusBar.show("starting");

  let serverOptions: ServerOptions;

  const transportOptions: TransportOptions = {
    startTimeoutMs: TIMEOUTS.serverStart,
    precompilationTimeoutMs: TIMEOUTS.precompilation,
    appendLine: (message) => outputChannel.appendLine(message),
    onPrecompiling: () => statusBar.show("precompiling"),
    onProcessError: (error) => {
      if (deactivating || restartRunner.active !== undefined) {
        return;
      }
      if (managedDepotPath === undefined) {
        handleSpawnError(error, baseCommand);
      } else {
        handleManagedServerFailure(error, managedDepotPath);
      }
    },
    registerCancel: (cancel) => {
      cancelServerStartup = cancel;
    },
  };

  if (commChannel === "stdio") {
    serverOptions = {
      run: {
        command: baseCommand,
        args: [...serveArgs, "--stdio"],
        options: spawnOptions,
      },
      debug: {
        command: baseCommand,
        args: [...serveArgs, "--stdio"],
        options: spawnOptions,
      },
    };
  } else if (commChannel === "socket") {
    const port = serverConfig.socketPort || 0; // Use 0 for auto-assign
    serverOptions = () =>
      connectSocketTransport(
        baseCommand,
        serveArgs,
        spawnOptions,
        port,
        transportOptions,
      );
    outputChannel.appendLine(`[jetls-client] Using TCP socket mode`);
  } else {
    // Default: pipe communication (Unix domain socket / named pipe)
    serverOptions = () =>
      connectPipeTransport(
        baseCommand,
        serveArgs,
        spawnOptions,
        transportOptions,
      );
  }

  const initializationOptions = {
    ...serverConfig.initializationOptions,
    // Declare the section this extension stores server settings under; the
    // server registers `workspace/didChangeConfiguration` with it so the
    // configuration sync feature only sends the notification when that
    // section actually changes. This requires a server that understands the
    // `configuration_section` initialization option, which the managed
    // installation guarantees.
    configuration_section: JETLS_CLIENT_SETTINGS_SECTION,
  };

  const clientOptions: LanguageClientOptions = {
    // Keep this selector as a static-registration fallback while jetls-client can
    // connect to independently installed JETLS versions. Once the extension manages
    // the `jetls` binary, rely only on server-side dynamic registration and remove it.
    documentSelector: [
      {
        scheme: "file",
        language: "julia",
      },
      {
        scheme: "untitled",
        language: "julia",
      },
      {
        notebook: { notebookType: "jupyter-notebook" },
        language: "julia",
      },
      // Sync the server-provided virtual documents (`jetls-*` schemes, e.g.
      // TestRunner logs) so the server is notified when they are opened/closed.
      // Language features are registered separately (see `DEFAULT_DOCUMENT_SELECTOR`)
      // and do not target these schemes; this only drives document synchronization.
      // Each new view's scheme must be listed here to receive sync notifications.
      {
        scheme: "jetls-testrunner-logs",
      },
    ],
    middleware: {
      workspace: {
        // The server registers `workspace/didChangeConfiguration` with the
        // section declared via `configuration_section` above, so the
        // configuration sync feature only fires when `jetls-client.settings`
        // changes. Still skip the send when the same change has queued a
        // restart or shutdown is underway: it would race the client teardown,
        // and the replacement server pulls fresh configuration on initialize
        // anyway.
        didChangeConfiguration: (sections, next) => {
          if (deactivating || restartRunner.pending) {
            return Promise.resolve();
          }
          return next(sections);
        },
      },
      // `editor.action.showReferences` is a built-in VSCode command that
      // requires actual `vscode.Uri`/`vscode.Position`/`vscode.Location`
      // instances, but server-sent command arguments arrive as plain JSON.
      // Convert them here before VSCode dispatches the command.
      resolveCodeLens: async (codeLens, token, next) => {
        const resolved = await next(codeLens, token);
        if (
          resolved?.command?.command === "editor.action.showReferences" &&
          Array.isArray(resolved.command.arguments) &&
          resolved.command.arguments.length === 3
        ) {
          const [uriString, pos, locs] = resolved.command.arguments as [
            string,
            { line: number; character: number },
            {
              uri: string;
              range: {
                start: { line: number; character: number };
                end: { line: number; character: number };
              };
            }[],
          ];
          resolved.command.arguments = [
            vscode.Uri.parse(uriString),
            new vscode.Position(pos.line, pos.character),
            locs.map(
              (loc) =>
                new vscode.Location(
                  vscode.Uri.parse(loc.uri),
                  new vscode.Range(
                    loc.range.start.line,
                    loc.range.start.character,
                    loc.range.end.line,
                    loc.range.end.character,
                  ),
                ),
            ),
          ];
        }
        return resolved;
      },
    },
    initializationOptions,
    outputChannel,
  };

  languageClient = new LanguageClient(
    "jetls-client",
    "JETLS Language Server",
    serverOptions,
    clientOptions,
  );

  // Surface server crashes and vscode-languageclient's automatic restarts in
  // the status bar. This fires for every state transition, but while the
  // extension runs its own start/restart/shutdown flow (runner active, or
  // deactivating) the startup code sets the status directly, so those
  // transitions are skipped: what remains are the transitions
  // vscode-languageclient initiated on its own, i.e. a crash-triggered stop
  // and the restart its error handler performs afterwards.
  languageClient.onDidChangeState((event) => {
    if (deactivating || restartRunner.active !== undefined) {
      return;
    }
    switch (event.newState) {
      case State.Stopped:
        statusBar.show("crashed");
        break;
      case State.Starting:
        statusBar.show("restarting");
        break;
      case State.Running:
        statusBar.show("ready");
        break;
    }
  });

  try {
    if (commChannel === "stdio") {
      await startWithTimeout(languageClient, TIMEOUTS.serverStart);
    } else {
      await languageClient.start();
    }
  } catch (err) {
    const error = err instanceof Error ? err : new Error(String(err));
    // If a restart request is queued, this failure is most likely the
    // deliberate cancellation from `requestLanguageServerRestart`; skip the
    // error surface here and let the rerun repaint the status from "checking".
    if (!deactivating && !restartRunner.pending) {
      if (managedDepotPath !== undefined) {
        statusBar.showManagedFailure(managedFailureSummary(error));
        handleManagedServerFailure(error, managedDepotPath);
      } else {
        statusBar.show("failed");
        handleSpawnError(error, baseCommand);
      }
    }
    throw error;
  } finally {
    cancelServerStartup = undefined;
  }

  if (deactivating) {
    return;
  }
  const serverInfo = languageClient.initializeResult?.serverInfo;
  if (serverInfo) {
    outputChannel.appendLine(
      `[jetls-client] JETLS is ready! (${serverInfo.name} [version: ${serverInfo.version ?? "unknown"}])`,
    );
  } else {
    outputChannel.appendLine("[jetls-client] JETLS is ready!");
  }

  if (managedDepotPath !== undefined) {
    const depotPath = managedDepotPath;
    managedLastUsedRefresh = setInterval(() => {
      void touchManagedInstallation(depotPath);
    }, LAST_USED_REFRESH_INTERVAL);
  }

  // Register handler for workspace/configuration requests after client starts
  languageClient.onRequest(
    "workspace/configuration",
    (params: { items: { scopeUri?: string; section?: string | null }[] }) => {
      const items = params.items || [];
      const results = items.map((item) => {
        const section = JETLS_CLIENT_SETTINGS_SECTION;
        const scope = item.scopeUri
          ? vscode.Uri.parse(item.scopeUri)
          : undefined;
        return vscode.workspace.getConfiguration(section, scope);
      });
      return results;
    },
  );

  statusBar.show("ready");
}

async function restartLanguageServer() {
  if (deactivating) {
    return;
  }
  // A client that never reached the `Running` state (e.g. `StartFailed`)
  // cannot be stopped: `stop()` would throw and permanently block restarts.
  if (languageClient?.needsStop()) {
    statusBar.show("restarting");
    try {
      await languageClient.stop(TIMEOUTS.serverStop);
    } catch (err) {
      statusBar.show("restart-failed");
      const message = err instanceof Error ? err.message : String(err);
      outputChannel.appendLine(
        `[jetls-client] Failed to stop language client: ${message}.`,
      );
      throw err;
    }
  }
  await startLanguageServer();
}

const restartRunner = new CoalescingTaskRunner(restartLanguageServer);

export function requestLanguageServerRestart(): void {
  const lifecycle = restartRunner.run();
  // Kill an in-flight version preflight so the rerun queued above can start
  // immediately; otherwise the rerun would wait for the preflight to finish,
  // which can take up to `TIMEOUTS.precompilation` while precompiling.
  void versionPreflight.terminate().catch((err) => {
    const message = err instanceof Error ? err.message : String(err);
    outputChannel.appendLine(
      `[jetls-client] Failed to terminate JETLS version check: ${message}.`,
    );
  });
  // Likewise kill a spawned server still waiting for its transport
  // connection; the transport turns this into a no-op once connected.
  cancelServerStartup?.();
  // And cancel an in-flight managed installation, which can run for
  // minutes: the rerun queued above starts over from the current state.
  managedSetupAbort?.abort();
  void lifecycle.catch((err) => {
    const message = err instanceof Error ? err.message : String(err);
    outputChannel.appendLine(
      `[jetls-client] Failed to restart language server: ${message}.`,
    );
  });
}

// Set by `reinstallServer` and consumed by the next managed setup; it
// stays set until an installation succeeds, so a Retry after a failed
// reinstall still installs from scratch.
let forceManagedInstall = false;

// Aborts the in-flight managed setup, so a restart or deactivation does
// not wait behind a long installation; the cancelled installation only
// strands its unpublished generation.
let managedSetupAbort: AbortController | undefined;

// Re-touches the running managed server's last-used markers: cleanup in
// other windows judges liveness by them, and they otherwise only record
// starts, which a long-lived session outlives.
let managedLastUsedRefresh: NodeJS.Timeout | undefined;

function stopManagedLastUsedRefresh(): void {
  if (managedLastUsedRefresh !== undefined) {
    clearInterval(managedLastUsedRefresh);
    managedLastUsedRefresh = undefined;
  }
}

/**
 * Reinstalls the managed JETLS from scratch: after a modal confirmation
 * the server restarts with the next managed setup forced to install a
 * fresh generation, ignoring the verified current one. Nothing is
 * deleted up front — superseded generations are cleaned up later — so a
 * failed reinstall leaves the previous installation in place and
 * surfaces the ordinary failure UI.
 */
export async function reinstallServer(): Promise<void> {
  if (deactivating) {
    return;
  }
  const serverConfig = getServerConfig();
  if (!isManagedExecutable(serverConfig.executable)) {
    void vscode.window.showInformationMessage(
      "JETLS managed installation is disabled by the executable setting.",
    );
    return;
  }
  const reinstallButton = "Reinstall";
  const choice = await vscode.window.showWarningMessage(
    "Reinstall the JETLS language server?",
    {
      modal: true,
      detail:
        "This reinstalls the pinned JETLS release into fresh managed " +
        "storage, which may require network access. The previous " +
        "installation is cleaned up automatically later.",
    },
    reinstallButton,
  );
  if (choice !== reinstallButton) {
    return;
  }
  forceManagedInstall = true;
  requestLanguageServerRestart();
}

export function restartOnServerConfigChange(): void {
  const newConfig = getServerConfig();
  if (hasServerConfigChanged(currentServerConfig, newConfig)) {
    vscode.window.showInformationMessage(
      "JETLS configuration changed. Restarting language server...",
    );
    requestLanguageServerRestart();
  }
}

/** Resolves to `false` when the wait timed out before the promise settled. */
function awaitWithTimeout(
  promise: Promise<void> | undefined,
  timeoutMs: number,
): Promise<boolean> {
  if (promise === undefined) {
    return Promise.resolve(true);
  }
  return new Promise((resolve) => {
    const timeoutHandle = setTimeout(() => resolve(false), timeoutMs);
    void promise
      .catch(() => undefined)
      .then(() => {
        clearTimeout(timeoutHandle);
        resolve(true);
      });
  });
}

export async function shutdownServerLifecycle(): Promise<void> {
  deactivating = true;
  stopManagedLastUsedRefresh();
  managedSetupAbort?.abort();
  cancelServerStartup?.();
  try {
    await versionPreflight.terminate();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    outputChannel?.appendLine(
      `[jetls-client] Failed to terminate JETLS version check: ${message}`,
    );
  }
  await awaitWithTimeout(restartRunner.active, TIMEOUTS.serverStop);
  if (languageClient?.needsStop()) {
    try {
      await languageClient.stop(TIMEOUTS.serverStop);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      outputChannel?.appendLine(
        `[jetls-client] Failed to stop language client: ${message}.`,
      );
    }
  }
}
