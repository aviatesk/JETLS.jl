import * as cp from "child_process";

export type ExecutableConfig =
  | { path?: string; threads?: string }
  | string[];

export interface JETLSCommands {
  command: string;
  versionArgs: string[];
  serveArgs: string[];
}

export function resolveJETLSCommands(
  executable: ExecutableConfig,
): JETLSCommands {
  if (Array.isArray(executable)) {
    const [command, ...args] = executable;
    return {
      command,
      versionArgs: [...args, "version"],
      serveArgs: args,
    };
  }

  const command = executable.path || "jetls";
  const threads = executable.threads || "auto";
  const juliaArgs = [`--threads=${threads}`, "--"];
  return {
    command,
    versionArgs: [...juliaArgs, "version"],
    serveArgs: [...juliaArgs, "serve"],
  };
}

interface ActivePreflightProcess {
  process: cp.ChildProcess;
  closed: boolean;
  closedPromise: Promise<void>;
  terminationPromise: Promise<void> | undefined;
}

type SpawnProcess = (
  command: string,
  args: readonly string[],
  options: cp.SpawnOptions,
) => cp.ChildProcess;

export interface VersionPreflightOptions {
  timeoutMs: number;
  terminationTimeoutMs: number;
  platform: NodeJS.Platform;
  spawnProcess?: SpawnProcess;
  appendLine: (message: string) => void;
  onPrecompiling: () => void;
}

export class VersionPreflight {
  private activeProcess: ActivePreflightProcess | undefined;
  private readonly spawnProcess: SpawnProcess;

  constructor(private readonly options: VersionPreflightOptions) {
    this.spawnProcess = options.spawnProcess ?? cp.spawn;
  }

  private waitForClose(
    preflight: ActivePreflightProcess,
  ): Promise<boolean> {
    if (preflight.closed) {
      return Promise.resolve(true);
    }
    return new Promise((resolve) => {
      const timeoutHandle = setTimeout(
        () => resolve(false),
        this.options.terminationTimeoutMs,
      );
      void preflight.closedPromise.then(() => {
        clearTimeout(timeoutHandle);
        resolve(true);
      });
    });
  }

  private async terminateProcessImpl(
    preflight: ActivePreflightProcess,
  ): Promise<void> {
    if (preflight.closed) {
      return;
    }

    let terminationError: Error | undefined;
    const pid = preflight.process.pid;
    if (this.options.platform === "win32" && pid !== undefined) {
      try {
        await new Promise<void>((resolve, reject) => {
          const taskkill = this.spawnProcess(
            "taskkill",
            ["/PID", pid.toString(), "/T", "/F"],
            { stdio: "ignore", windowsHide: true },
          );
          let settled = false;
          const finish = (error?: Error): void => {
            if (settled) {
              return;
            }
            settled = true;
            clearTimeout(timeoutHandle);
            if (error === undefined) {
              resolve();
            } else {
              reject(error);
            }
          };
          taskkill.once("error", finish);
          taskkill.once("close", (code) => {
            if (code === 0) {
              finish();
            } else {
              finish(new Error(`taskkill exited with code ${code}.`));
            }
          });
          const timeoutHandle = setTimeout(() => {
            taskkill.kill();
            finish(new Error("taskkill timed out."));
          }, this.options.terminationTimeoutMs);
        });
      } catch (err) {
        terminationError = err instanceof Error ? err : new Error(String(err));
      }
    } else {
      preflight.process.kill();
    }

    if (await this.waitForClose(preflight)) {
      return;
    }
    if (this.options.platform !== "win32") {
      preflight.process.kill("SIGKILL");
      if (await this.waitForClose(preflight)) {
        return;
      }
    }

    throw (
      terminationError ??
      new Error("JETLS version check did not exit after termination.")
    );
  }

  private terminateProcess(
    preflight: ActivePreflightProcess,
  ): Promise<void> {
    if (preflight.terminationPromise === undefined) {
      preflight.terminationPromise = this.terminateProcessImpl(preflight);
    }
    return preflight.terminationPromise;
  }

  terminate(): Promise<void> {
    const preflight = this.activeProcess;
    return preflight === undefined
      ? Promise.resolve()
      : this.terminateProcess(preflight);
  }

  async run(
    command: string,
    args: string[],
    spawnOptions: cp.SpawnOptions,
  ): Promise<void> {
    if (this.activeProcess !== undefined) {
      throw new Error("A previous JETLS version check is still running.");
    }
    this.options.appendLine(
      `[jetls-client] JETLS version check: ${JSON.stringify([command, ...args])}`,
    );

    await new Promise<void>((resolve, reject) => {
      const versionProcess = this.spawnProcess(command, args, spawnOptions);
      let resolveClosed!: () => void;
      const preflight: ActivePreflightProcess = {
        process: versionProcess,
        closed: false,
        closedPromise: new Promise((resolve) => {
          resolveClosed = resolve;
        }),
        terminationPromise: undefined,
      };
      this.activeProcess = preflight;

      let stdout = "";
      let stderr = "";
      let settled = false;
      let timedOut = false;
      let processError: Error | undefined;
      let precompilationDetected = false;

      const finish = (error?: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeoutHandle);
        if (error === undefined) {
          resolve();
        } else {
          reject(error);
        }
      };

      versionProcess.stdout?.on("data", (data: Buffer) => {
        if (!settled) {
          stdout += data.toString();
        }
      });
      versionProcess.stderr?.on("data", (data: Buffer) => {
        if (settled) {
          return;
        }
        const text = data.toString();
        stderr += text;
        text
          .trimEnd()
          .split("\n")
          .forEach((line) =>
            this.options.appendLine(`[JETLS-version-stderr] ${line}`),
          );
        if (
          !precompilationDetected &&
          stderr.includes("Precompiling packages")
        ) {
          precompilationDetected = true;
          this.options.onPrecompiling();
        }
      });
      versionProcess.once("error", (err) => {
        processError = err;
      });
      versionProcess.once("close", (code, signal) => {
        preflight.closed = true;
        resolveClosed();
        if (this.activeProcess === preflight) {
          this.activeProcess = undefined;
        }
        if (timedOut || settled) {
          return;
        }
        const output = stdout.trim();
        if (output) {
          this.options.appendLine(
            `[jetls-client] JETLS version check stdout:\n${output}`,
          );
        }
        if (processError !== undefined) {
          finish(processError);
        } else if (code === 0) {
          finish();
        } else if (signal !== null) {
          finish(
            new Error(`JETLS version check exited with signal ${signal}.`),
          );
        } else {
          finish(new Error(`JETLS version check exited with code ${code}.`));
        }
      });

      const timeoutHandle = setTimeout(() => {
        timedOut = true;
        const timeoutError = new Error(
          `JETLS version check timed out after ${this.options.timeoutMs / 1000} seconds.`,
        );
        this.options.appendLine(`[jetls-client] ${timeoutError.message}`);
        void this.terminateProcess(preflight).then(
          () => finish(timeoutError),
          (err) => {
            const terminationError =
              err instanceof Error ? err : new Error(String(err));
            finish(
              new Error(`${timeoutError.message} ${terminationError.message}`),
            );
          },
        );
      }, this.options.timeoutMs);
    });
  }
}
