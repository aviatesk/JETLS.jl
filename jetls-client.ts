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

type ExecutableConfig = { path?: string; threads?: string } | string[];

interface ServerConfig {
  executable: ExecutableConfig;
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

function getServerConfig(): ServerConfig {
  const config = vscode.workspace.getConfiguration("jetls-client");
  const defaultExecutable = process.platform === "win32" ? "jetls.exe" : "jetls";
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
  const serverConfig = getServerConfig();
  currentServerConfig = serverConfig;

  let baseCommand: string;
  let baseArgs: string[];

  if (Array.isArray(serverConfig.executable)) {
    const [cmd, ...args] = serverConfig.executable;
    baseCommand = cmd;
    baseArgs = args;
  } else {
    const defaultExecutable = process.platform === "win32" ? "jetls.exe" : "jetls";
    baseCommand = serverConfig.executable.path || defaultExecutable;
    const threads = serverConfig.executable.threads || "auto";
    baseArgs = [`--threads=${threads}`, "--"];
  }

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

  let serverOptions: ServerOptions;

  if (commChannel === "stdio") {
    serverOptions = {
      run: {
        command: baseCommand,
        args: [...baseArgs, "--stdio"],
      },
      debug: {
        command: baseCommand,
        args: [...baseArgs, "--stdio"],
      },
    };
  } else if (commChannel === "socket") {
    const port = serverConfig.socketPort || 0; // Use 0 for auto-assign

    serverOptions = () => {
      return new Promise((resolve, reject) => {
        outputChannel.appendLine(
          `[jetls-client] Starting JETLS with TCP socket (port: ${port || "auto-assign"})...`,
        );

        const jetlsProcess = cp.spawn(baseCommand, [
          ...baseArgs,
          "--socket",
          port.toString(),
        ]);

        let actualPort: number | null = null;

        const timeoutHandler = createTimeoutHandler(jetlsProcess, reject, {
          timeoutMessage: "Timeout waiting for JETLS to provide port number",
          precompilingMessage:
            "Timeout waiting for JETLS to provide port number (during precompilation)",
        });

        const manager = setupProcessMonitoring(
          jetlsProcess,
          (isPrecompiling) => {
            if (!actualPort) {
              timeoutHandler(isPrecompiling);
            }
          },
        );

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
                  jetlsProcess.kill();
                  reject(err);
                });
              }
            });
        });

        jetlsProcess.on("error", (err) => {
          outputChannel.appendLine(
            `[jetls-client] Failed to start JETLS: ${err.message}`,
          );
          if (manager.timeoutHandle) {
            clearTimeout(manager.timeoutHandle);
          }
          reject(err);
        });

        jetlsProcess.on("exit", (code) => {
          outputChannel.appendLine(
            `[jetls-client] JETLS process exited with code: ${code}`,
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
          const jetlsProcess = cp.spawn(baseCommand, [
            ...baseArgs,
            "--pipe-connect",
            socketPath,
          ]);

          // Setup monitoring with timeout
          const manager = setupProcessMonitoring(
            jetlsProcess,
            createTimeoutHandler(jetlsProcess, reject, {
              timeoutMessage: "Timeout waiting for JETLS to connect",
              precompilingMessage:
                "Timeout waiting for JETLS to connect (during precompilation)",
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
            outputChannel.appendLine(
              `[jetls-client] Failed to start JETLS: ${err.message}`,
            );
            if (manager.timeoutHandle) {
              clearTimeout(manager.timeoutHandle);
            }
            server.close();
            reject(err);
          });

          jetlsProcess.on("exit", (code) => {
            outputChannel.appendLine(
              `[jetls-client] JETLS process exited with code: ${code}`,
            );
            if (manager.timeoutHandle) {
              clearTimeout(manager.timeoutHandle);
            }
            server.close();
            if (process.platform !== "win32" && fs.existsSync(socketPath)) {
              fs.unlinkSync(socketPath);
            }
          });

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
  statusBarItem.tooltip =
    "Loading JETLS and attempting to establish communication between client and server.";
  statusBarItem.show();

  languageClient.start().then(() => {
    statusBarItem.hide();
    outputChannel.appendLine("[jetls-client] JETLS is ready!");

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
  });
}

async function restartLanguageServer() {
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
  await startLanguageServer();
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
        event.affectsConfiguration("jetls-client.executable") ||
        event.affectsConfiguration("jetls-client.communicationChannel") ||
        event.affectsConfiguration("jetls-client.socketPort")
      ) {
        const newConfig = getServerConfig();
        if (hasServerConfigChanged(currentServerConfig, newConfig)) {
          vscode.window.showInformationMessage(
            "JETLS configuration changed. Restarting language server...",
          );
          restartLanguageServer();
        }
      }
    }),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "jetls-client.restartLanguageServer",
      () => {
        restartLanguageServer();
      },
    ),
  );

  outputChannel = vscode.window.createOutputChannel("JETLS Language Server");

  startLanguageServer();
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
