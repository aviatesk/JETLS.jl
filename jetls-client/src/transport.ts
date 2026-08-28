import * as cp from "child_process";
import * as net from "net";

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

// Helper to create timeout handler
function createTimeoutHandler(
  juliaProcess: cp.ChildProcess,
  appendLine: (message: string) => void,
  reject: (error: Error) => void,
  timeoutMessage: string,
): () => void {
  return () => {
    appendLine(`[jetls-client] ${timeoutMessage}`);
    juliaProcess.kill();
    reject(new Error(timeoutMessage));
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
      "Timeout waiting for JETLS to provide port number",
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
