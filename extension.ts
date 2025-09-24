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
            manager.timeoutHandle = setTimeout(
              () => onTimeout(true),
              manager.timeoutDuration,
            );
          }
        }
      }),
  );

  manager.timeoutHandle = setTimeout(
    () => onTimeout(manager.isPrecompiling),
    manager.timeoutDuration,
  );

  return manager;
}

// Helper to spawn Julia process with standard arguments
function spawnJuliaServer(
  juliaExecutable: string,
  serverScript: string,
  extraArgs: string[],
  options: { cwd?: string } = {},
): cp.ChildProcess {
  const baseArgs = [
    "--startup-file=no",
    "--history-file=no",
    "--project=.",
    "--threads=auto",
    serverScript,
    ...extraArgs,
  ];

  return cp.spawn(juliaExecutable, baseArgs, {
    cwd: options.cwd || vscode.workspace.rootPath,
    detached: false,
  });
}

async function startLanguageServer(context: ExtensionContext) {
  const config = vscode.workspace.getConfiguration("jetls-client");
  const juliaExecutable = config.get<string>("juliaExecutablePath", "julia");

  let commChannel = config.get<string>("communicationChannel", "auto");
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
    const baseArgs = [
      "--startup-file=no",
      "--history-file=no",
      "--project=.",
      "--threads=auto",
      serverScript,
      "--stdio",
    ];
    serverOptions = {
      run: { command: juliaExecutable, args: baseArgs },
      debug: { command: juliaExecutable, args: [...baseArgs, "--debug=yes"] },
    };
  } else if (commChannel === "socket") {
    const port = config.get<number>("socketPort", 0) || 0; // Use 0 for auto-assign

    serverOptions = () => {
      return new Promise((resolve, reject) => {
        outputChannel.appendLine(
          `[jetls-client] Starting JETLS with TCP socket (port: ${port || "auto-assign"})...`,
        );

        const juliaProcess = spawnJuliaServer(juliaExecutable, serverScript, [
          "--socket",
          port.toString(),
        ]);

        let actualPort: number | null = null;

        const manager = setupProcessMonitoring(
          juliaProcess,
          (isPrecompiling) => {
            if (!actualPort) {
              const message = isPrecompiling
                ? "Timeout waiting for JETLS to provide port number (during precompilation)"
                : "Timeout waiting for JETLS to provide port number";
              reject(new Error(message));
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
          const juliaProcess = spawnJuliaServer(juliaExecutable, serverScript, [
            "--pipe",
            socketPath,
          ]);

          // Setup monitoring with timeout
          const manager = setupProcessMonitoring(
            juliaProcess,
            (isPrecompiling) => {
              server.close();
              const message = isPrecompiling
                ? "Timeout waiting for JETLS to connect (during precompilation)"
                : "Timeout waiting for JETLS to connect";
              outputChannel.appendLine(`[jetls-client] ${message}`);
              reject(new Error(message));
            },
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
            // Clean up socket file on Unix
            if (process.platform !== "win32" && fs.existsSync(socketPath)) {
              fs.unlinkSync(socketPath);
            }
          });
        });

        // Wait for JETLS to connect
        server.once("connection", (socket: net.Socket) => {
          outputChannel.appendLine(`[jetls-client] JETLS connected!`);
          server.close(); // Stop accepting new connections
          resolve({ reader: socket, writer: socket });
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

  languageClient.start();
}

async function restartLanguageServer(context: ExtensionContext) {
  if (languageClient) {
    await languageClient.stop();
  }
  await startLanguageServer(context);
}

export function activate(context: ExtensionContext) {
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (
        event.affectsConfiguration("jetls-client.juliaExecutablePath") ||
        event.affectsConfiguration("jetls-client.communicationChannel") ||
        event.affectsConfiguration("jetls-client.socketPort")
      ) {
        vscode.window.showInformationMessage(
          "JETLS configuration changed. Restarting language server...",
        );
        restartLanguageServer(context);
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
}
