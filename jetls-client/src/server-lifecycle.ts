import * as vscode from "vscode";
import { LogOutputChannel } from "vscode";

import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  State,
} from "vscode-languageclient/node";

import { CoalescingTaskRunner } from "./coalescing-task-runner";
import {
  JETLS_INSTALL_COMMAND,
  JETLS_INSTALL_GUIDE_URL,
  LANGUAGE_SERVER_STOP_TIMEOUT_MS,
  PRECOMPILATION_TIMEOUT_MS,
  PREFLIGHT_TERMINATION_TIMEOUT_MS,
  SERVER_START_TIMEOUT_MS,
} from "./constants";
import {
  getServerConfig,
  hasServerConfigChanged,
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

export function activateServerLifecycle(
  channel: LogOutputChannel,
  bar: StartupStatusBar,
): void {
  outputChannel = channel;
  statusBar = bar;
  deactivating = false;
}

const versionPreflight = new VersionPreflight({
  timeoutMs: PRECOMPILATION_TIMEOUT_MS,
  terminationTimeoutMs: PREFLIGHT_TERMINATION_TIMEOUT_MS,
  platform: process.platform,
  appendLine: (message) => outputChannel.appendLine(message),
  onPrecompiling: () => statusBar.show("precompiling"),
});

// Helper to handle spawn errors with user-friendly messages
function handleSpawnError(err: Error, command: string): void {
  const errno = err as NodeJS.ErrnoException;
  if (errno.code === "ENOENT") {
    outputChannel.appendLine(
      `[jetls-client] Failed to start JETLS: Command not found: ${command}`,
    );
    outputChannel.appendLine(`[jetls-client] PATH: ${process.env.PATH}`);
    outputChannel.appendLine(
      `[jetls-client] Please install JETLS using: ${JETLS_INSTALL_COMMAND}`,
    );
    outputChannel.appendLine(
      `[jetls-client] If JETLS is already installed, try restarting VS Code to refresh the PATH.`,
    );

    const installButton = "Install JETLS";
    const docsButton = "View installation guide";
    vscode.window
      .showErrorMessage(
        `JETLS executable not found: "${command}". Please install JETLS or configure the executable path. If you have already installed JETLS, try restarting VS Code to refresh the PATH.`,
        installButton,
        docsButton,
      )
      .then((selection) => {
        if (selection === installButton) {
          const terminal = vscode.window.createTerminal("Install JETLS");
          terminal.show();
          terminal.sendText(JETLS_INSTALL_COMMAND, true);
        } else if (selection === docsButton) {
          vscode.env.openExternal(vscode.Uri.parse(JETLS_INSTALL_GUIDE_URL));
        }
      });
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
  statusBar.show("checking");

  const serverConfig = getServerConfig();
  currentServerConfig = serverConfig;

  let resolvedCommands: JETLSCommands;
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

  // On Windows, batch files must be spawned with shell: true
  const spawnOptions = process.platform === "win32" ? { shell: true } : {};

  try {
    await versionPreflight.run(baseCommand, versionArgs, spawnOptions);
  } catch (err) {
    const error = err instanceof Error ? err : new Error(String(err));
    if (!deactivating) {
      statusBar.show("failed");
      handleSpawnError(error, baseCommand);
    }
    throw error;
  }

  if (deactivating) {
    return;
  }
  statusBar.show("starting");

  let serverOptions: ServerOptions;

  const transportOptions: TransportOptions = {
    startTimeoutMs: SERVER_START_TIMEOUT_MS,
    precompilationTimeoutMs: PRECOMPILATION_TIMEOUT_MS,
    appendLine: (message) => outputChannel.appendLine(message),
    onPrecompiling: () => statusBar.show("precompiling"),
    onProcessError: (error) => handleSpawnError(error, baseCommand),
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

  const initializationOptions = vscode.workspace
    .getConfiguration("jetls-client")
    .get("initializationOptions", {});

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
      await startWithTimeout(languageClient, SERVER_START_TIMEOUT_MS);
    } else {
      await languageClient.start();
    }
  } catch (err) {
    const error = err instanceof Error ? err : new Error(String(err));
    if (!deactivating) {
      statusBar.show("failed");
      handleSpawnError(error, baseCommand);
    }
    throw error;
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

  // Register handler for workspace/configuration requests after client starts
  languageClient.onRequest(
    "workspace/configuration",
    (params: { items: { scopeUri?: string; section?: string | null }[] }) => {
      const items = params.items || [];
      const results = items.map((item) => {
        const section = "jetls-client.settings";
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
      await languageClient.stop(LANGUAGE_SERVER_STOP_TIMEOUT_MS);
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
  void restartRunner.run().catch((err) => {
    const message = err instanceof Error ? err.message : String(err);
    outputChannel.appendLine(
      `[jetls-client] Failed to restart language server: ${message}.`,
    );
  });
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

function awaitWithTimeout(
  promise: Promise<void> | undefined,
  timeoutMs: number,
): Promise<void> {
  if (promise === undefined) {
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    const timeoutHandle = setTimeout(resolve, timeoutMs);
    void promise
      .catch(() => undefined)
      .then(() => {
        clearTimeout(timeoutHandle);
        resolve();
      });
  });
}

export async function shutdownServerLifecycle(): Promise<void> {
  deactivating = true;
  try {
    await versionPreflight.terminate();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    outputChannel?.appendLine(
      `[jetls-client] Failed to terminate JETLS version check: ${message}`,
    );
  }
  await awaitWithTimeout(restartRunner.active, LANGUAGE_SERVER_STOP_TIMEOUT_MS);
  if (languageClient?.needsStop()) {
    try {
      await languageClient.stop(LANGUAGE_SERVER_STOP_TIMEOUT_MS);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      outputChannel?.appendLine(
        `[jetls-client] Failed to stop language client: ${message}.`,
      );
    }
  }
}
