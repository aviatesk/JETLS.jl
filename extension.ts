"use strict";

import * as vscode from "vscode";
import { ExtensionContext, OutputChannel } from "vscode";

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

let languageClient: LanguageClient;
let outputChannel: OutputChannel;
let statusBarItem: vscode.StatusBarItem;

interface ServerConfig {
  juliaExecutablePath: string;
  jetlsDirectory: string;
  juliaThreads: string;
  communicationChannel: string;
  socketPort: number;
}

let currentServerConfig: ServerConfig | null = null;

interface ProcessManager {
  process: cp.ChildProcess;
  timeoutHandle: NodeJS.Timeout | null;
  isPrecompiling: boolean;
  timeoutDuration: number;
}

// Helper to create timeout handler with precompilation detection
function setupProcessMonitoring(
  juliaProcess: cp.ChildProcess,
  onTimeout: (isPrecompiling: boolean) => void,
  options: { initialTimeout?: number } = {},
): ProcessManager {
  const manager: ProcessManager = {
    process: juliaProcess,
    timeoutHandle: null,
    isPrecompiling: false,
    timeoutDuration: options.initialTimeout || 60000, // Default 60 seconds
  };

  // Monitor stderr for precompilation messages
  juliaProcess.stderr?.on("data", (data: Buffer) =>
    data
      .toString()
      .trimEnd()
      .split("\n")
      .forEach((s) => {
        outputChannel.appendLine(`[JETLS-stderr] ${s}`);

        // Check for precompilation messages
        if (s.includes("Precompiling packages") && !manager.isPrecompiling) {
          manager.isPrecompiling = true;
          manager.timeoutDuration = 300000; // Extend to 300 seconds
          outputChannel.appendLine(
            `[jetls-client] Detected precompilation, extending timeout to 300 seconds`,
          );

          // Reset the timeout with new duration
          if (manager.timeoutHandle) {
            clearTimeout(manager.timeoutHandle);
          }

          manager.timeoutHandle = setTimeout(
            () => onTimeout(true),
            manager.timeoutDuration,
          );
        }
      }),
  );

  manager.timeoutHandle = setTimeout(
    () => onTimeout(manager.isPrecompiling),
    manager.timeoutDuration,
  );

  return manager;
}

// Helper to create timeout handler with cleanup
function createTimeoutHandler(
  juliaProcess: cp.ChildProcess,
  reject: (error: Error) => void,
  options: {
    timeoutMessage: string;
    precompilingMessage: string;
    cleanup?: () => void;
  },
): (isPrecompiling: boolean) => void {
  return (isPrecompiling: boolean) => {
    const message = isPrecompiling
      ? options.precompilingMessage
      : options.timeoutMessage;
    outputChannel.appendLine(`[jetls-client] ${message}`);
    juliaProcess.kill();
    if (options.cleanup) {
      options.cleanup();
    }
    reject(new Error(message));
  };
}

// Helper to spawn Julia process with standard arguments
function spawnJuliaServer(
  juliaExecutable: string,
  serverScript: string,
  extraArgs: string[],
  options: { cwd?: string; projectPath?: string; threads?: string } = {},
): cp.ChildProcess {
  const baseArgs = ["--startup-file=no", "--history-file=no"];

  if (options.projectPath) {
    baseArgs.push(`--project=${options.projectPath}`);
  }

  baseArgs.push(
    `--threads=${options.threads || "auto"}`,
    serverScript,
    ...extraArgs,
  );

  return cp.spawn(juliaExecutable, baseArgs, {
    cwd: options.cwd,
    detached: false,
  });
}

function getServerConfig(): ServerConfig {
  const config = vscode.workspace.getConfiguration("jetls-client");
  return {
    juliaExecutablePath: config.get<string>("juliaExecutablePath", "julia"),
    jetlsDirectory: config.get<string>("jetlsDirectory", ""),
    juliaThreads: config.get<string>("juliaThreads", "auto"),
    communicationChannel: config.get<string>("communicationChannel", "auto"),
    socketPort: config.get<number>("socketPort", 8080),
  };
}

function hasServerConfigChanged(
  oldConfig: ServerConfig | null,
  newConfig: ServerConfig,
): boolean {
  if (!oldConfig) { return true; }
  return (
    oldConfig.juliaExecutablePath !== newConfig.juliaExecutablePath ||
    oldConfig.jetlsDirectory !== newConfig.jetlsDirectory ||
    oldConfig.juliaThreads !== newConfig.juliaThreads ||
    oldConfig.communicationChannel !== newConfig.communicationChannel ||
    oldConfig.socketPort !== newConfig.socketPort
  );
}

async function startLanguageServer(context: ExtensionContext) {
  const serverConfig = getServerConfig();
  currentServerConfig = serverConfig;

  const juliaExecutable = serverConfig.juliaExecutablePath;
  const jetlsDirectory = serverConfig.jetlsDirectory;
  const juliaThreads = serverConfig.juliaThreads;

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

  const serverScript = context.asAbsolutePath("runserver.jl");

  outputChannel.appendLine(
    `[jetls-client] Using communication channel: ${commChannel}`,
  );

  let serverOptions: ServerOptions;

  if (commChannel === "stdio") {
    const baseArgs = ["--startup-file=no", "--history-file=no"];

    if (jetlsDirectory) {
      baseArgs.push(`--project=${jetlsDirectory}`);
    }

    baseArgs.push(`--threads=${juliaThreads}`, serverScript, "--stdio");

    serverOptions = {
      run: { command: juliaExecutable, args: baseArgs },
      debug: { command: juliaExecutable, args: [...baseArgs, "--debug=yes"] },
    };
  } else if (commChannel === "socket") {
    const port = serverConfig.socketPort || 0; // Use 0 for auto-assign

    serverOptions = () => {
      return new Promise((resolve, reject) => {
        outputChannel.appendLine(
          `[jetls-client] Starting JETLS with TCP socket (port: ${port || "auto-assign"})...`,
        );

        const juliaProcess = spawnJuliaServer(
          juliaExecutable,
          serverScript,
          ["--socket", port.toString()],
          {
            projectPath: jetlsDirectory || undefined,
            threads: juliaThreads,
          },
        );

        let actualPort: number | null = null;

        const timeoutHandler = createTimeoutHandler(juliaProcess, reject, {
          timeoutMessage: "Timeout waiting for JETLS to provide port number",
          precompilingMessage:
            "Timeout waiting for JETLS to provide port number (during precompilation)",
        });

        const manager = setupProcessMonitoring(
          juliaProcess,
          (isPrecompiling) => {
            if (!actualPort) {
              timeoutHandler(isPrecompiling);
            }
          },
        );

        // Capture stdout to get the actual port number
        juliaProcess.stdout?.on("data", (data: Buffer) => {
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

                // Clear timeout since we got the port
                if (manager.timeoutHandle) {
                  clearTimeout(manager.timeoutHandle);
                  manager.timeoutHandle = null;
                }

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
                  juliaProcess.kill();
                  reject(err);
                });
              }
            });
        });

        juliaProcess.on("error", (err) => {
          outputChannel.appendLine(
            `[jetls-client] Failed to start JETLS: ${err.message}`,
          );
          if (manager.timeoutHandle) {
            clearTimeout(manager.timeoutHandle);
          }
          reject(err);
        });

        juliaProcess.on("exit", (code) => {
          outputChannel.appendLine(
            `[jetls-client] Julia process exited with code: ${code}`,
          );
          if (manager.timeoutHandle) {
            clearTimeout(manager.timeoutHandle);
          }
          if (!actualPort) {
            reject(new Error("JETLS exited without providing a port number"));
          }
        });
      });
    };

    outputChannel.appendLine(`[jetls-client] Using TCP socket mode`);
  } else {
    // Default: pipe communication (Unix domain socket / named pipe)
    const socketPath =
      process.platform === "win32"
        ? `\\\\.\\pipe\\jetls-${process.pid}-${Date.now()}`
        : path.join(os.tmpdir(), `jetls-${process.pid}-${Date.now()}.sock`);

    // Clean up any existing socket file (Unix only)
    if (process.platform !== "win32" && fs.existsSync(socketPath)) {
      fs.unlinkSync(socketPath);
    }

    serverOptions = () => {
      return new Promise((resolve, reject) => {
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
          const juliaProcess = spawnJuliaServer(
            juliaExecutable,
            serverScript,
            ["--pipe", socketPath],
            {
              projectPath: jetlsDirectory || undefined,
              threads: juliaThreads,
            },
          );

          // Setup monitoring with timeout
          const manager = setupProcessMonitoring(
            juliaProcess,
            createTimeoutHandler(juliaProcess, reject, {
              timeoutMessage: "Timeout waiting for JETLS to connect",
              precompilingMessage:
                "Timeout waiting for JETLS to connect (during precompilation)",
              cleanup: () => server.close(),
            }),
          );

          // Capture stdout for debugging
          juliaProcess.stdout?.on("data", (data: Buffer) => {
            data
              .toString()
              .trimEnd()
              .split("\n")
              .forEach((s) => outputChannel.appendLine(`[JETLS-stdout] ${s}`));
          });

          juliaProcess.on("error", (err) => {
            outputChannel.appendLine(
              `[jetls-client] Failed to start JETLS: ${err.message}`,
            );
            if (manager.timeoutHandle) {
              clearTimeout(manager.timeoutHandle);
            }
            server.close();
            reject(err);
          });

          juliaProcess.on("exit", (code) => {
            outputChannel.appendLine(
              `[jetls-client] Julia process exited with code: ${code}`,
            );
            if (manager.timeoutHandle) {
              clearTimeout(manager.timeoutHandle);
            }
            server.close();
            if (process.platform !== "win32" && fs.existsSync(socketPath)) {
              fs.unlinkSync(socketPath);
            }
          });

          // Wait for JETLS to connect
          server.once("connection", (socket: net.Socket) => {
            outputChannel.appendLine(`[jetls-client] JETLS connected!`);

            // Clear timeout since connection succeeded
            if (manager.timeoutHandle) {
              clearTimeout(manager.timeoutHandle);
              manager.timeoutHandle = null;
            }

            server.close(); // Stop accepting new connections
            resolve({ reader: socket, writer: socket });
          });
        });
      });
    };
  }

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      {
        scheme: "file",
        language: "julia",
      },
      {
        scheme: "untitled",
        language: "julia",
      },
    ],
    outputChannel,
  };

  languageClient = new LanguageClient(
    "jetls-client",
    "JETLS Language Server",
    serverOptions,
    clientOptions,
  );

  statusBarItem.text = "$(sync~spin) Loading JETLS ...";
  statusBarItem.tooltip = "Loading JETLS and attempting to establish communication between client and server.";
  statusBarItem.show();

  languageClient.start().then(() => {
    statusBarItem.hide();
    outputChannel.appendLine("[jetls-client] JETLS is ready!");
  });
}

async function restartLanguageServer(context: ExtensionContext) {
  if (languageClient) {
    try {
      await languageClient.stop();
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      outputChannel.appendLine(
        `[jetls-client] Failed to stop language client: ${message}.`,
      );
    }
  }
  await startLanguageServer(context);
}

export function activate(context: ExtensionContext) {
  statusBarItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    100,
  );
  context.subscriptions.push(statusBarItem);

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (
        event.affectsConfiguration("jetls-client.juliaExecutablePath") ||
        event.affectsConfiguration("jetls-client.jetlsDirectory") ||
        event.affectsConfiguration("jetls-client.juliaThreads") ||
        event.affectsConfiguration("jetls-client.communicationChannel") ||
        event.affectsConfiguration("jetls-client.socketPort")
      ) {
        const newConfig = getServerConfig();
        if (hasServerConfigChanged(currentServerConfig, newConfig)) {
          vscode.window.showInformationMessage(
            "JETLS configuration changed. Restarting language server...",
          );
          restartLanguageServer(context);
        }
      } else if (event.affectsConfiguration("jetls-client.jetlsSettings")) {
        if (languageClient) {
          languageClient.sendNotification("workspace/didChangeConfiguration", {
            settings: vscode.workspace
              .getConfiguration("jetls-client")
              .get("jetlsSettings"),
          });
        }
      }
    }),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "jetls-client.restartLanguageServer",
      () => {
        restartLanguageServer(context);
      },
    ),
  );

  outputChannel = vscode.window.createOutputChannel("JETLS Language Server");

  startLanguageServer(context);
}

export async function deactivate() {
  if (languageClient) {
    await languageClient.stop();
  }
  if (outputChannel) {
    outputChannel.dispose();
  }
  if (statusBarItem) {
    statusBarItem.dispose();
  }
}
