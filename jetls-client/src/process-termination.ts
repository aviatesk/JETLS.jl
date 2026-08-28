import type * as cp from "child_process";

export type SpawnProcess = (
  command: string,
  args: readonly string[],
  options: cp.SpawnOptions,
) => cp.ChildProcess;

/**
 * Thrown when a process survives every termination attempt. The process may
 * still be running, so callers must not treat the resources it can touch
 * (e.g. a managed depot) as safe to reuse.
 */
export class ProcessSurvivedError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "ProcessSurvivedError";
  }
}

export interface ProcessTerminationTarget {
  process: cp.ChildProcess;
  isClosed: () => boolean;
  closedPromise: Promise<void>;
}

export interface ProcessTerminationOptions {
  platform: NodeJS.Platform;
  /** Bound for each wait on the process exiting between attempts. */
  terminationTimeoutMs: number;
  /** Used to run `taskkill` on Windows. */
  spawnProcess: SpawnProcess;
  /**
   * Signal the process's own process group instead of the single process,
   * so child workers (e.g. `Pkg` precompile processes) terminate with it.
   * Only safe when the process was spawned `detached`, making it its own
   * group leader; otherwise the signals would hit the caller's group.
   */
  processGroup?: boolean;
  killProcessGroup?: (pid: number, signal: NodeJS.Signals) => void;
  /**
   * Reports whether any member of the process group is still running.
   * The default probes with signal 0 and treats `EPERM` (present but not
   * signalable) as alive.
   */
  isProcessGroupAlive?: (pid: number) => boolean;
  /** Message for the error thrown when the process survives every attempt. */
  survivalMessage: string;
}

function waitForClose(
  target: ProcessTerminationTarget,
  terminationTimeoutMs: number,
): Promise<boolean> {
  if (target.isClosed()) {
    return Promise.resolve(true);
  }
  return new Promise((resolve) => {
    const timeoutHandle = setTimeout(
      () => resolve(false),
      terminationTimeoutMs,
    );
    void target.closedPromise.then(() => {
      clearTimeout(timeoutHandle);
      resolve(true);
    });
  });
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Terminates a spawned process with escalation: `taskkill /T /F` on Windows
 * (falling back to `kill()` when it fails), SIGTERM then SIGKILL elsewhere,
 * waiting a bounded time for the process to exit between attempts. The
 * direct process closing is not taken as tree exit, even when it had
 * already closed before termination started: with `processGroup`,
 * success additionally requires the whole group to be gone, and the
 * Windows `taskkill` fallback path cannot confirm the tree at all.
 * Throws `ProcessSurvivedError` when the process (or its group) may have
 * survived every attempt, so callers always settle without mistaking a
 * live tree for a finished one.
 */
export async function terminateProcess(
  target: ProcessTerminationTarget,
  options: ProcessTerminationOptions,
): Promise<void> {
  const pid = target.process.pid;
  const killProcessGroup =
    options.killProcessGroup ??
    ((groupPid: number, signal: NodeJS.Signals) =>
      process.kill(-groupPid, signal));
  const isProcessGroupAlive =
    options.isProcessGroupAlive ??
    ((groupPid: number): boolean => {
      try {
        process.kill(-groupPid, 0);
        return true;
      } catch (error) {
        return (error as NodeJS.ErrnoException).code === "EPERM";
      }
    });
  const sendSignal = (signal: NodeJS.Signals): void => {
    if (options.processGroup === true && pid !== undefined) {
      try {
        killProcessGroup(pid, signal);
        return;
      } catch {
        // The group may already be gone; fall through to the direct kill.
      }
    }
    target.process.kill(signal);
  };
  const groupAlive = (): boolean =>
    options.processGroup === true &&
    pid !== undefined &&
    isProcessGroupAlive(pid);
  // One escalation stage: the direct process must close and, when a group
  // is being terminated, the rest of the group must be gone as well.
  const stageExited = async (): Promise<boolean> => {
    const deadline = Date.now() + options.terminationTimeoutMs;
    if (!(await waitForClose(target, options.terminationTimeoutMs))) {
      return false;
    }
    while (groupAlive()) {
      if (Date.now() >= deadline) {
        return false;
      }
      await delay(25);
    }
    return true;
  };

  // A direct process that closed before termination started says nothing
  // about its tree: on POSIX the group is probed and surviving members
  // still get the escalation below, while on Windows the closed parent
  // can no longer anchor a `taskkill /T`, so the tree is unconfirmable
  // and the process must be reported as possibly surviving.
  if (target.isClosed()) {
    if (options.platform === "win32" && pid !== undefined) {
      throw new ProcessSurvivedError(options.survivalMessage);
    }
    if (!groupAlive()) {
      return;
    }
  }

  if (options.platform === "win32" && pid !== undefined) {
    let terminationError: Error | undefined;
    try {
      await new Promise<void>((resolve, reject) => {
        const taskkill = options.spawnProcess(
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
        }, options.terminationTimeoutMs);
      });
    } catch (err) {
      terminationError = err instanceof Error ? err : new Error(String(err));
      target.process.kill();
    }
    if (await waitForClose(target, options.terminationTimeoutMs)) {
      if (terminationError === undefined) {
        // `taskkill /T` terminated the whole tree.
        return;
      }
      // The fallback `kill()` only reached the direct process; its child
      // tree cannot be confirmed dead.
      throw new ProcessSurvivedError(
        `${options.survivalMessage} ${terminationError.message}`,
        { cause: terminationError },
      );
    }
    throw new ProcessSurvivedError(
      terminationError
        ? `${options.survivalMessage} ${terminationError.message}`
        : options.survivalMessage,
      { cause: terminationError },
    );
  }

  sendSignal("SIGTERM");
  if (await stageExited()) {
    return;
  }
  sendSignal("SIGKILL");
  if (await stageExited()) {
    return;
  }
  throw new ProcessSurvivedError(options.survivalMessage);
}
