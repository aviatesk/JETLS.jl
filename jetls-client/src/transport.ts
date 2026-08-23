import * as cp from "child_process";
import * as fs from "fs";
import * as net from "net";
import * as os from "os";
import * as path from "path";

import { createStderrWatcher } from "./preflight";

/** Structurally compatible with vscode-languageclient's `StreamInfo`. */
export interface TransportStreams {
  reader: net.Socket;
  writer: net.Socket;
}

type SpawnProcess = (
  command: string,
  args: readonly string[],
  options: cp.SpawnOptions,
) => cp.ChildProcess;

export interface TransportOptions {
  /** Budget from spawn until the transport connection is established. */
  startTimeoutMs: number;
  /** Replacement budget armed when precompilation output is detected. */
  precompilationTimeoutMs: number;
  spawnProcess?: SpawnProcess;
  appendLine: (message: string) => void;
  onPrecompiling: () => void;
  /** Invoked when the spawned server process emits an `error` event. */
  onProcessError: (error: Error) => void;
  /**
   * Receives a function that cancels the connection attempt: while the
   * transport is still waiting for the server, it kills the spawned process
   * and rejects the attempt; once the server has connected it is a no-op.
   */
  registerCancel?: (cancel: () => void) => void;
}

interface ProcessManager {
  timeoutHandle: NodeJS.Timeout | null;
}

function setupProcessMonitoring(
  juliaProcess: cp.ChildProcess,
  options: TransportOptions,
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
      appendLine: options.appendLine,
      onPrecompiling: () => {
        if (manager.timeoutHandle !== null) {
          clearTimeout(manager.timeoutHandle);
          armTimeout(options.precompilationTimeoutMs);
          options.onPrecompiling();
        }
      },
    }),
  );

  armTimeout(options.startTimeoutMs);
  return manager;
}

function stopProcessMonitoring(manager: ProcessManager): void {
  if (manager.timeoutHandle !== null) {
    clearTimeout(manager.timeoutHandle);
    manager.timeoutHandle = null;
  }
}

// Helper to create timeout handler with cleanup
function createTimeoutHandler(
  juliaProcess: cp.ChildProcess,
  appendLine: (message: string) => void,
  reject: (error: Error) => void,
  handlerOptions: {
    timeoutMessage: string;
    cleanup?: () => void;
  },
): () => void {
  return () => {
    const message = handlerOptions.timeoutMessage;
    appendLine(`[jetls-client] ${message}`);
    juliaProcess.kill();
    if (handlerOptions.cleanup) {
      handlerOptions.cleanup();
    }
    reject(new Error(message));
  };
}

export function connectSocketTransport(
  command: string,
  serveArgs: string[],
  spawnOptions: cp.SpawnOptions,
  port: number, // 0 = auto-assign
  options: TransportOptions,
): Promise<TransportStreams> {
  const spawnProcess = options.spawnProcess ?? cp.spawn;
  return new Promise((resolve, reject) => {
    options.appendLine(
      `[jetls-client] Starting JETLS with TCP socket (port: ${port || "auto-assign"})...`,
    );

    const jetlsProcess = spawnProcess(
      command,
      [...serveArgs, "--socket", port.toString()],
      spawnOptions,
    );

    let actualPort: number | null = null;
    let connected = false;
    let cancelled = false;

    options.registerCancel?.(() => {
      if (connected || cancelled) {
        return;
      }
      cancelled = true;
      options.appendLine(
        "[jetls-client] Cancelling JETLS startup for a new restart request",
      );
      jetlsProcess.kill();
      reject(new Error("JETLS startup was cancelled by a restart request"));
    });

    const timeoutHandler = createTimeoutHandler(
      jetlsProcess,
      options.appendLine,
      reject,
      {
        timeoutMessage: "Timeout waiting for JETLS to provide port number",
      },
    );

    const manager = setupProcessMonitoring(jetlsProcess, options, () => {
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
          options.appendLine(`[JETLS-stdout] ${line}`);

          // Look for the port announcement
          const portMatch = line.match(/<JETLS-PORT>(\d+)<\/JETLS-PORT>/);
          if (portMatch && !actualPort) {
            actualPort = parseInt(portMatch[1]);
            options.appendLine(
              `[jetls-client] JETLS listening on port: ${actualPort}`,
            );

            stopProcessMonitoring(manager);

            // Connect to the server
            const socket = net.createConnection(actualPort, "127.0.0.1", () => {
              options.appendLine(
                `[jetls-client] Connected to JETLS on port ${actualPort}!`,
              );
              connected = true;
              resolve({ reader: socket, writer: socket });
            });

            socket.on("error", (err) => {
              options.appendLine(`[jetls-client] Socket error: ${err.message}`);
              jetlsProcess.kill();
              reject(err);
            });
          }
        });
    });

    jetlsProcess.on("error", (err) => {
      options.onProcessError(err);
      stopProcessMonitoring(manager);
      reject(err);
    });

    jetlsProcess.on("exit", (code, signal) => {
      options.appendLine(
        `[jetls-client] JETLS process exited (code: ${code}, signal: ${signal})`,
      );
      stopProcessMonitoring(manager);
      if (!actualPort) {
        reject(new Error("JETLS exited without providing a port number"));
      }
    });
  });
}

// Pipe communication (Unix domain socket / named pipe): the client listens
// and the spawned server connects back via `--pipe-connect`.
export function connectPipeTransport(
  command: string,
  serveArgs: string[],
  spawnOptions: cp.SpawnOptions,
  options: TransportOptions,
): Promise<TransportStreams> {
  const spawnProcess = options.spawnProcess ?? cp.spawn;
  return new Promise((resolve, reject) => {
    const socketPath =
      process.platform === "win32"
        ? `\\\\.\\pipe\\jetls-${process.pid}-${Date.now()}`
        : path.join(os.tmpdir(), `jetls-${process.pid}-${Date.now()}.sock`);

    if (process.platform !== "win32" && fs.existsSync(socketPath)) {
      fs.unlinkSync(socketPath);
    }

    const server = net.createServer();

    let jetlsProcess: cp.ChildProcess | undefined;
    let connected = false;
    let cancelled = false;

    options.registerCancel?.(() => {
      if (connected || cancelled) {
        return;
      }
      cancelled = true;
      options.appendLine(
        "[jetls-client] Cancelling JETLS startup for a new restart request",
      );
      jetlsProcess?.kill();
      server.close();
      reject(new Error("JETLS startup was cancelled by a restart request"));
    });

    server.once("error", (err) => {
      options.appendLine(
        `[jetls-client] Failed to create server: ${err.message}`,
      );
      reject(err);
    });

    server.listen(socketPath, () => {
      if (cancelled) {
        return;
      }
      const pipeType =
        process.platform === "win32" ? "named pipe" : "Unix domain socket";
      options.appendLine(
        `[jetls-client] Server listening on ${pipeType}: ${socketPath}`,
      );

      options.appendLine(`[jetls-client] Starting JETLS...`);
      jetlsProcess = spawnProcess(
        command,
        [...serveArgs, "--pipe-connect", socketPath],
        spawnOptions,
      );

      // Setup monitoring with timeout
      const manager = setupProcessMonitoring(
        jetlsProcess,
        options,
        createTimeoutHandler(jetlsProcess, options.appendLine, reject, {
          timeoutMessage: "Timeout waiting for JETLS to connect",
          cleanup: () => server.close(),
        }),
      );

      jetlsProcess.stdout?.on("data", (data: Buffer) => {
        data
          .toString()
          .trimEnd()
          .split("\n")
          .forEach((s) => options.appendLine(`[JETLS-stdout] ${s}`));
      });

      jetlsProcess.on("error", (err) => {
        options.onProcessError(err);
        stopProcessMonitoring(manager);
        server.close();
        reject(err);
      });

      jetlsProcess.on("exit", (code, signal) => {
        options.appendLine(
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
        options.appendLine(`[jetls-client] JETLS connected!`);
        connected = true;
        stopProcessMonitoring(manager);

        server.close(); // Stop accepting new connections
        resolve({ reader: socket, writer: socket });
      });
    });
  });
}
