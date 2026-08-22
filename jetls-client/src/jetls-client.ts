"use strict";

import * as vscode from "vscode";
import { ExtensionContext, LogOutputChannel } from "vscode";

import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";
import * as net from "net";
import * as os from "os";
import * as path from "path";
import * as fs from "fs";
import * as cp from "child_process";

import { CoalescingTaskRunner } from "./CoalescingTaskRunner";
import {
  createStderrWatcher,
  ExecutableConfig,
  JETLSCommands,
  resolveJETLSCommands,
  VersionPreflight,
} from "./server-startup";

let languageClient: LanguageClient;
let outputChannel: LogOutputChannel;
let statusBarItem: vscode.StatusBarItem;
let statusBarHideTimer: NodeJS.Timeout | undefined;
let deactivating = false;

type ServerStartupStatus =
  | "checking"
  | "starting"
  | "restarting"
  | "precompiling"
  | "ready"
  | "failed"
  | "restart-failed";

interface ServerConfig {
  executable: ExecutableConfig;
  communicationChannel: string;
  socketPort: number;
}

let currentServerConfig: ServerConfig | null = null;

const JETLS_INSTALL_COMMAND =
  'julia -e \'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")\'';
const JETLS_INSTALL_GUIDE_URL =
  "https://github.com/aviatesk/JETLS.jl/blob/master/jetls-client/README.md#getting-started";
const JETLS_CHANGELOG_URL =
  "https://github.com/aviatesk/JETLS.jl/blob/master/jetls-client/CHANGELOG.md";
const JETLS_MIGRATION_GUIDE_URL = `${JETLS_CHANGELOG_URL}#v020`;
const LANGUAGE_SERVER_STOP_TIMEOUT_MS = 10_000;
const PREFLIGHT_TIMEOUT_MS = 300000;
const PREFLIGHT_TERMINATION_TIMEOUT_MS = 5000;
const SERVER_START_TIMEOUT_MS = 60000;
const SERVER_START_PRECOMPILING_TIMEOUT_MS = 300000;

const versionPreflight = new VersionPreflight({
  timeoutMs: PREFLIGHT_TIMEOUT_MS,
  terminationTimeoutMs: PREFLIGHT_TERMINATION_TIMEOUT_MS,
  platform: process.platform,
  appendLine: (message) => outputChannel.appendLine(message),
  onPrecompiling: () => showServerStartupStatus("precompiling"),
});

function showServerStartupStatus(status: ServerStartupStatus): void {
  if (deactivating) {
    return;
  }
  if (statusBarHideTimer !== undefined) {
    clearTimeout(statusBarHideTimer);
    statusBarHideTimer = undefined;
  }

  statusBarItem.backgroundColor = undefined;
  switch (status) {
    case "checking":
      statusBarItem.text = "$(sync~spin) Checking JETLS...";
      statusBarItem.tooltip = "Checking the JETLS executable and version.";
      break;
    case "starting":
      statusBarItem.text = "$(sync~spin) Starting JETLS...";
      statusBarItem.tooltip = "Starting the JETLS language server.";
      break;
    case "restarting":
      statusBarItem.text = "$(sync~spin) Restarting JETLS...";
      statusBarItem.tooltip = "Restarting the JETLS language server.";
      break;
    case "precompiling":
      statusBarItem.text = "$(sync~spin) Precompiling JETLS...";
      statusBarItem.tooltip =
        "Precompiling JETLS. The first startup may take longer.";
      break;
    case "ready":
      statusBarItem.text = "$(check) JETLS ready";
      statusBarItem.tooltip = "JETLS started successfully.";
      statusBarHideTimer = setTimeout(() => {
        statusBarItem.hide();
        statusBarHideTimer = undefined;
      }, 3000);
      break;
    case "failed":
      statusBarItem.text = "$(error) JETLS failed to start";
      statusBarItem.tooltip =
        "JETLS failed to start. Click to open the JETLS output.";
      statusBarItem.backgroundColor = new vscode.ThemeColor(
        "statusBarItem.errorBackground",
      );
      break;
    case "restart-failed":
      statusBarItem.text = "$(error) JETLS restart failed";
      statusBarItem.tooltip =
        "JETLS could not be stopped for restart. Click to open the JETLS output.";
      statusBarItem.backgroundColor = new vscode.ThemeColor(
        "statusBarItem.errorBackground",
      );
      break;
  }
  statusBarItem.show();
}

interface ProcessManager {
  timeoutHandle: NodeJS.Timeout | null;
}

function setupProcessMonitoring(
  juliaProcess: cp.ChildProcess,
  onTimeout: () => void,
): ProcessManager {
  const manager: ProcessManager = {
    timeoutHandle: null,
  };
  const armTimeout = (timeoutMs: number): void => {
    manager.timeoutHandle = setTimeout(() => {
      manager.timeoutHandle = null;
      onTimeout();
    }, timeoutMs);
  };

  juliaProcess.stderr?.on(
    "data",
    createStderrWatcher({
      logPrefix: "[JETLS-stderr]",
      appendLine: (message) => outputChannel.appendLine(message),
      onPrecompiling: () => {
        if (manager.timeoutHandle !== null) {
          clearTimeout(manager.timeoutHandle);
          armTimeout(SERVER_START_PRECOMPILING_TIMEOUT_MS);
          showServerStartupStatus("precompiling");
        }
      },
    }),
  );

  armTimeout(SERVER_START_TIMEOUT_MS);
  return manager;
}

function stopProcessMonitoring(manager: ProcessManager): void {
  if (manager.timeoutHandle !== null) {
    clearTimeout(manager.timeoutHandle);
    manager.timeoutHandle = null;
  }
}

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

// Helper to create timeout handler with cleanup
function createTimeoutHandler(
  juliaProcess: cp.ChildProcess,
  reject: (error: Error) => void,
  options: {
    timeoutMessage: string;
    cleanup?: () => void;
  },
): () => void {
  return () => {
    const message = options.timeoutMessage;
    outputChannel.appendLine(`[jetls-client] ${message}`);
    juliaProcess.kill();
    if (options.cleanup) {
      options.cleanup();
    }
    reject(new Error(message));
  };
}

function getServerConfig(): ServerConfig {
  const config = vscode.workspace.getConfiguration("jetls-client");
  const defaultExecutable = "jetls";
  const executable = config.get<ExecutableConfig>("executable", {
    path: defaultExecutable,
    threads: "auto",
  });
  return {
    executable,
    communicationChannel: config.get<string>("communicationChannel", "auto"),
    socketPort: config.get<number>("socketPort", 8080),
  };
}

function hasServerConfigChanged(
  oldConfig: ServerConfig | null,
  newConfig: ServerConfig,
): boolean {
  if (!oldConfig) {
    return true;
  }
  return (
    JSON.stringify(oldConfig.executable) !==
      JSON.stringify(newConfig.executable) ||
    oldConfig.communicationChannel !== newConfig.communicationChannel ||
    oldConfig.socketPort !== newConfig.socketPort
  );
}

async function startLanguageServer() {
  if (deactivating) {
    return;
  }
  showServerStartupStatus("checking");

  const serverConfig = getServerConfig();
  currentServerConfig = serverConfig;

  let resolvedCommands: JETLSCommands;
  try {
    resolvedCommands = resolveJETLSCommands(serverConfig.executable);
  } catch (err) {
    const error = err instanceof Error ? err : new Error(String(err));
    if (!deactivating) {
      showServerStartupStatus("failed");
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
      showServerStartupStatus("failed");
      handleSpawnError(error, baseCommand);
    }
    throw error;
  }

  if (deactivating) {
    return;
  }
  showServerStartupStatus("starting");

  let serverOptions: ServerOptions;

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

    serverOptions = () => {
      return new Promise((resolve, reject) => {
        outputChannel.appendLine(
          `[jetls-client] Starting JETLS with TCP socket (port: ${port || "auto-assign"})...`,
        );

        const jetlsProcess = cp.spawn(
          baseCommand,
          [...serveArgs, "--socket", port.toString()],
          spawnOptions,
        );

        let actualPort: number | null = null;

        const timeoutHandler = createTimeoutHandler(jetlsProcess, reject, {
          timeoutMessage: "Timeout waiting for JETLS to provide port number",
        });

        const manager = setupProcessMonitoring(jetlsProcess, () => {
          if (!actualPort) {
            timeoutHandler();
          }
        });

        // Capture stdout to get the actual port number
        jetlsProcess.stdout?.on("data", (data: Buffer) => {
          data
            .toString()
            .trimEnd()
            .split("\n")
            .forEach((line) => {
              outputChannel.appendLine(`[JETLS-stdout] ${line}`);

              // Look for the port announcement
              const portMatch = line.match(/<JETLS-PORT>(\d+)<\/JETLS-PORT>/);
              if (portMatch && !actualPort) {
                actualPort = parseInt(portMatch[1]);
                outputChannel.appendLine(
                  `[jetls-client] JETLS listening on port: ${actualPort}`,
                );

                stopProcessMonitoring(manager);

                // Connect to the server
                const socket = net.createConnection(
                  actualPort,
                  "127.0.0.1",
                  () => {
                    outputChannel.appendLine(
                      `[jetls-client] Connected to JETLS on port ${actualPort}!`,
                    );
                    resolve({ reader: socket, writer: socket });
                  },
                );

                socket.on("error", (err) => {
                  outputChannel.appendLine(
                    `[jetls-client] Socket error: ${err.message}`,
                  );
                  jetlsProcess.kill();
                  reject(err);
                });
              }
            });
        });

        jetlsProcess.on("error", (err) => {
          handleSpawnError(err, baseCommand);
          stopProcessMonitoring(manager);
          reject(err);
        });

        jetlsProcess.on("exit", (code, signal) => {
          outputChannel.appendLine(
            `[jetls-client] JETLS process exited (code: ${code}, signal: ${signal})`,
          );
          stopProcessMonitoring(manager);
          if (!actualPort) {
            reject(new Error("JETLS exited without providing a port number"));
          }
        });
      });
    };

    outputChannel.appendLine(`[jetls-client] Using TCP socket mode`);
  } else {
    // Default: pipe communication (Unix domain socket / named pipe)
    serverOptions = () => {
      return new Promise((resolve, reject) => {
        const socketPath =
          process.platform === "win32"
            ? `\\\\.\\pipe\\jetls-${process.pid}-${Date.now()}`
            : path.join(os.tmpdir(), `jetls-${process.pid}-${Date.now()}.sock`);

        if (process.platform !== "win32" && fs.existsSync(socketPath)) {
          fs.unlinkSync(socketPath);
        }

        const server = net.createServer();

        server.once("error", (err) => {
          outputChannel.appendLine(
            `[jetls-client] Failed to create server: ${err.message}`,
          );
          reject(err);
        });

        server.listen(socketPath, () => {
          const pipeType =
            process.platform === "win32" ? "named pipe" : "Unix domain socket";
          outputChannel.appendLine(
            `[jetls-client] Server listening on ${pipeType}: ${socketPath}`,
          );

          outputChannel.appendLine(`[jetls-client] Starting JETLS...`);
          const jetlsProcess = cp.spawn(
            baseCommand,
            [...serveArgs, "--pipe-connect", socketPath],
            spawnOptions,
          );

          // Setup monitoring with timeout
          const manager = setupProcessMonitoring(
            jetlsProcess,
            createTimeoutHandler(jetlsProcess, reject, {
              timeoutMessage: "Timeout waiting for JETLS to connect",
              cleanup: () => server.close(),
            }),
          );

          jetlsProcess.stdout?.on("data", (data: Buffer) => {
            data
              .toString()
              .trimEnd()
              .split("\n")
              .forEach((s) => outputChannel.appendLine(`[JETLS-stdout] ${s}`));
          });

          jetlsProcess.on("error", (err) => {
            handleSpawnError(err, baseCommand);
            stopProcessMonitoring(manager);
            server.close();
            reject(err);
          });

          let connected = false;

          jetlsProcess.on("exit", (code, signal) => {
            outputChannel.appendLine(
              `[jetls-client] JETLS process exited (code: ${code}, signal: ${signal})`,
            );
            stopProcessMonitoring(manager);
            server.close();
            if (process.platform !== "win32" && fs.existsSync(socketPath)) {
              fs.unlinkSync(socketPath);
            }
            if (!connected) {
              reject(new Error("JETLS exited before connecting to the pipe"));
            }
          });

          server.once("connection", (socket: net.Socket) => {
            outputChannel.appendLine(`[jetls-client] JETLS connected!`);
            connected = true;
            stopProcessMonitoring(manager);

            server.close(); // Stop accepting new connections
            resolve({ reader: socket, writer: socket });
          });
        });
      });
    };
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

  try {
    await languageClient.start();
  } catch (err) {
    const error = err instanceof Error ? err : new Error(String(err));
    if (!deactivating) {
      showServerStartupStatus("failed");
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

  showServerStartupStatus("ready");
}

async function restartLanguageServer() {
  if (deactivating) {
    return;
  }
  // A client that never reached the `Running` state (e.g. `StartFailed`)
  // cannot be stopped: `stop()` would throw and permanently block restarts.
  if (languageClient?.needsStop()) {
    showServerStartupStatus("restarting");
    try {
      await languageClient.stop(LANGUAGE_SERVER_STOP_TIMEOUT_MS);
    } catch (err) {
      showServerStartupStatus("restart-failed");
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

function requestLanguageServerRestart(): void {
  void restartRunner.run().catch((err) => {
    const message = err instanceof Error ? err.message : String(err);
    outputChannel.appendLine(
      `[jetls-client] Failed to restart language server: ${message}.`,
    );
  });
}

async function checkForUpdates(context: ExtensionContext): Promise<void> {
  const currentVersion = vscode.extensions.getExtension("aviatesk.jetls-client")
    ?.packageJSON.version;
  const previousVersion = context.globalState.get<string>("version");

  if (currentVersion && !previousVersion) {
    // First-time installation
    const message =
      "Welcome to JETLS Client! To use this extension, you need to install the JETLS executable. " +
      "Click 'Install JETLS' to get started.";
    const installButton = "Install JETLS";
    const docsButton = "View installation guide";

    const selection = await vscode.window.showInformationMessage(
      message,
      installButton,
      docsButton,
    );

    if (selection === installButton) {
      const terminal = vscode.window.createTerminal("Install JETLS");
      terminal.show();
      terminal.sendText(JETLS_INSTALL_COMMAND, true);
    } else if (selection === docsButton) {
      vscode.env.openExternal(vscode.Uri.parse(JETLS_INSTALL_GUIDE_URL));
    }
  } else if (
    currentVersion &&
    previousVersion &&
    currentVersion !== previousVersion
  ) {
    // Update detected
    if (
      previousVersion.startsWith("0.1.") &&
      currentVersion.startsWith("0.2.")
    ) {
      // Special handling for v0.1.x -> v0.2.0 breaking update
      const message =
        "JETLS Client v0.2.0 requires reinstalling JETLS with the new installation method. " +
        "Click 'Reinstall JETLS' to run the installation command.";
      const reinstallButton = "Reinstall JETLS";
      const migrationGuideButton = "View migration guide";

      const selection = await vscode.window.showWarningMessage(
        message,
        reinstallButton,
        migrationGuideButton,
      );

      if (selection === reinstallButton) {
        const terminal = vscode.window.createTerminal("Reinstall JETLS");
        terminal.show();
        terminal.sendText(JETLS_INSTALL_COMMAND, true);
      } else if (selection === migrationGuideButton) {
        vscode.env.openExternal(vscode.Uri.parse(JETLS_MIGRATION_GUIDE_URL));
      }
    } else {
      // Normal update
      const message =
        "JETLS Client has been updated! Please make sure to update the JETLS server as well.";
      const updateButton = "Update JETLS";
      const changelogButton = "View CHANGELOG.md";

      const selection = await vscode.window.showInformationMessage(
        message,
        updateButton,
        changelogButton,
      );

      if (selection === updateButton) {
        const terminal = vscode.window.createTerminal("Update JETLS");
        terminal.show();
        terminal.sendText(JETLS_INSTALL_COMMAND, true);
      } else if (selection === changelogButton) {
        vscode.env.openExternal(vscode.Uri.parse(JETLS_CHANGELOG_URL));
      }
    }
  }

  if (currentVersion) {
    await context.globalState.update("version", currentVersion);
  }
}

export function activate(context: ExtensionContext) {
  deactivating = false;
  statusBarItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    100,
  );
  statusBarItem.name = "JETLS server startup status";
  statusBarItem.command = {
    command: "jetls-client.showOutput",
    title: "Show JETLS output",
  };
  context.subscriptions.push(statusBarItem);

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (
        event.affectsConfiguration("jetls-client.executable") ||
        event.affectsConfiguration("jetls-client.communicationChannel") ||
        event.affectsConfiguration("jetls-client.socketPort")
      ) {
        const newConfig = getServerConfig();
        if (hasServerConfigChanged(currentServerConfig, newConfig)) {
          vscode.window.showInformationMessage(
            "JETLS configuration changed. Restarting language server...",
          );
          requestLanguageServerRestart();
        }
      }
    }),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("jetls-client.restartLanguageServer", () =>
      requestLanguageServerRestart(),
    ),
  );

  outputChannel = vscode.window.createOutputChannel("JETLS", { log: true });
  context.subscriptions.push(
    vscode.commands.registerCommand("jetls-client.showOutput", () =>
      outputChannel.show(),
    ),
  );

  checkForUpdates(context);

  requestLanguageServerRestart();
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
    void promise.catch(() => undefined).then(() => {
      clearTimeout(timeoutHandle);
      resolve();
    });
  });
}

export async function deactivate() {
  deactivating = true;
  if (statusBarHideTimer !== undefined) {
    clearTimeout(statusBarHideTimer);
    statusBarHideTimer = undefined;
  }
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
  if (outputChannel) {
    outputChannel.dispose();
  }
  if (statusBarItem) {
    statusBarItem.dispose();
  }
}
