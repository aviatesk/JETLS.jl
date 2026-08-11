import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { homedir, uptime } from "node:os";
import {
  cp,
  mkdir,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import * as path from "node:path";
import { stripVTControlCharacters } from "node:util";

import which from "which";

// eslint-disable-next-line @typescript-eslint/naming-convention
import JETLS_VERSION from "../JETLS_VERSION.json";

import { TIMEOUTS } from "./constants";
import {
  ProcessSurvivedError,
  SpawnProcess,
  terminateProcess,
} from "./process-termination";

export const JETLS_REPOSITORY = "https://github.com/aviatesk/JETLS.jl";
// The pinned server release and its supported Julia range live in
// `JETLS_VERSION.json` so the server release process can update them as
// structured data; the values are inlined into the bundle at build time.
export const JETLS_REVISION: string = JETLS_VERSION.revision;
const MANAGED_DEPOTS_DIR = "jetls-depots";
const INSTALL_STAMP_FILE = "install-stamp.json";
const JULIA_VERSION_LOWER_BOUND: string = JETLS_VERSION.julia.lower;
const JULIA_VERSION_UPPER_MINOR: string = JETLS_VERSION.julia.upperMinor;

const JULIA_VERSION_SCRIPT = "print(stdout, VERSION)";
// The installation must go through `Pkg.Apps`: JETLS releases pin their
// vendored dependencies via `[sources]`, which Pkg only honors for the
// active project itself. The app environment makes the JETLS project the
// project, so the vendored pins resolve; a plain `Pkg.add` would treat
// JETLS as a dependency and fail resolution on the unregistered vendored
// packages. The generated launcher shim itself stays unused: the server
// is launched as `julia -m JETLS` directly.
const INSTALL_SCRIPT = `using Pkg; Pkg.Apps.add(; url="${JETLS_REPOSITORY}", rev="${JETLS_REVISION}")`;
const GC_SCRIPT = "using Pkg, Dates; Pkg.gc(; collect_delay=Dates.Day(0))";
const JULIA_BASE_ARGS = ["--startup-file=no", "--history-file=no"] as const;
const LOCK_RETRY_DELAY = 100;
const INCOMPLETE_LOCK_GRACE_PERIOD = 30 * 1000;

export interface ProcessResult {
  status: number | null;
  stdout: string;
  stderr: string;
  error?: string;
  /**
   * Set when the process survived every termination attempt: it may still
   * be running, so resources it can touch must not be treated as reusable.
   */
  processMayBeAlive?: boolean;
}

export interface ProcessRunnerOptions {
  env: NodeJS.ProcessEnv;
  shell: boolean;
  timeoutMs: number;
  onStdout?: (chunk: string) => void;
  onStderr?: (chunk: string) => void;
  /** Reports the spawned process id as soon as it is known. */
  onPid?: (pid: number) => void;
}

export type ProcessRunner = (
  command: string,
  args: readonly string[],
  options: ProcessRunnerOptions,
) => Promise<ProcessResult>;

export interface ManagedInstallationOptions {
  storagePath: string;
  environment: NodeJS.ProcessEnv;
  juliaCommand?: string;
  logger?: (message: string) => void;
  progress?: (message: string) => void;
  processRunner?: ProcessRunner;
  platform?: NodeJS.Platform;
}

export interface ManagedJETLSInstallation {
  env: NodeJS.ProcessEnv;
  depotPath: string;
  juliaPath: string;
}

export interface JuliaVersion {
  major: number;
  minor: number;
  patch: number;
}

/** The processing stage a managed-installation failure originated from. */
type ManagedStage =
  | "julia-resolution"
  | "julia-version"
  | "lock"
  | "install"
  | "repair"
  | "verify"
  | "gc"
  | "uninstall";

interface RuntimeContext {
  depotPath: string;
  juliaPath: string;
  juliaVersion: string;
}

type InstallationOperation = "Installing" | "Repairing";

interface ProcessOutputObserver {
  onStdout: (chunk: string) => void;
  onStderr: (chunk: string) => void;
}

class ManagedStepError extends Error {
  readonly stage: ManagedStage;
  readonly processMayBeAlive: boolean;
  /** Overrides the stage-derived retryability default when set. */
  readonly retryable?: boolean;
  /** Overrides the first-line summary default when set. */
  readonly summary?: string;
  /** Overrides the stage-derived recovery guidance when set. */
  readonly recovery?: string;

  constructor(
    message: string,
    stage: ManagedStage,
    options: {
      processMayBeAlive?: boolean;
      retryable?: boolean;
      summary?: string;
      recovery?: string;
      cause?: unknown;
    } = {},
  ) {
    super(message, options.cause === undefined ? undefined : options);
    this.name = "ManagedStepError";
    this.stage = stage;
    this.processMayBeAlive = options.processMayBeAlive === true;
    this.retryable = options.retryable;
    this.summary = options.summary;
    this.recovery = options.recovery;
  }
}

function stepProcessMayBeAlive(error: unknown): boolean {
  return error instanceof ManagedStepError && error.processMayBeAlive;
}

/**
 * Terminal managed-installation failure carrying the facts the UI needs
 * to pick guidance without parsing the message: a one-line `summary` for
 * notifications and the status bar tooltip, whether a retry with the same
 * configuration can help (`retryable`), and whether a surviving process
 * may still be mutating the depot (`processMayBeAlive`). The message
 * carries the human-readable details for the output channel.
 */
export class ManagedJETLSError extends Error {
  readonly summary: string;
  readonly retryable: boolean;
  readonly processMayBeAlive: boolean;

  constructor(
    message: string,
    details: {
      summary: string;
      retryable: boolean;
      processMayBeAlive: boolean;
    },
  ) {
    super(message);
    this.name = "ManagedJETLSError";
    this.summary = details.summary;
    this.retryable = details.retryable;
    this.processMayBeAlive = details.processMayBeAlive;
  }
}

function environmentKeyMatches(
  key: string,
  expected: string,
  platform: NodeJS.Platform,
): boolean {
  return platform === "win32"
    ? key.toLowerCase() === expected.toLowerCase()
    : key === expected;
}

function environmentValue(
  environment: NodeJS.ProcessEnv,
  key: string,
  platform: NodeJS.Platform,
): string | undefined {
  for (const [candidate, value] of Object.entries(environment).reverse()) {
    if (environmentKeyMatches(candidate, key, platform)) {
      return value;
    }
  }
  return undefined;
}

function deleteEnvironmentValue(
  environment: NodeJS.ProcessEnv,
  key: string,
  platform: NodeJS.Platform,
): void {
  for (const candidate of Object.keys(environment)) {
    if (environmentKeyMatches(candidate, key, platform)) {
      delete environment[candidate];
    }
  }
}

function setEnvironmentValue(
  environment: NodeJS.ProcessEnv,
  key: string,
  value: string,
  platform: NodeJS.Platform,
): void {
  deleteEnvironmentValue(environment, key, platform);
  environment[key] = value;
}

function emit(
  callback: ((message: string) => void) | undefined,
  message: string,
): void {
  try {
    callback?.(message);
  } catch {
    return;
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function firstLine(text: string): string {
  const newline = text.indexOf("\n");
  return newline === -1 ? text : text.slice(0, newline);
}

// `which` searches with the host platform's semantics; `platform` only
// selects case-insensitive key matching for the supplied environment.
export async function resolveExecutable(
  command: string,
  environment: NodeJS.ProcessEnv,
  platform: NodeJS.Platform = process.platform,
): Promise<string> {
  if (command.length === 0) {
    throw new Error("The executable command is empty.");
  }
  const pathSpecified = command.includes("/") || command.includes("\\");
  const suppliedPath = environmentValue(environment, "PATH", platform);
  if (!pathSpecified && suppliedPath === undefined) {
    throw new Error(
      `Unable to resolve bare command '${command}': the supplied environment has no PATH.`,
    );
  }
  const resolved = await which(
    pathSpecified ? path.resolve(command) : command,
    {
      nothrow: true,
      path: suppliedPath,
      pathExt: environmentValue(environment, "PATHEXT", platform),
    },
  );
  if (resolved === null) {
    const source = pathSpecified ? "the specified path" : "the supplied PATH";
    throw new Error(`Unable to find executable '${command}' in ${source}.`);
  }
  if (platform === "win32") {
    // `which` embeds the matching `PATHEXT` entry, conventionally uppercase,
    // which Windows's case-insensitive filesystems happily match against
    // lowercase file names; normalize so the resolution result (and the
    // depot key derived from it) is deterministic.
    const extension = path.win32.extname(resolved);
    return path.resolve(
      resolved.slice(0, resolved.length - extension.length) +
        extension.toLowerCase(),
    );
  }
  return path.resolve(resolved);
}

export function parseJuliaVersion(version: string): JuliaVersion | undefined {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:[-+].+)?$/.exec(version.trim());
  if (match === null) {
    return undefined;
  }
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
  };
}

function compareJuliaVersions(left: JuliaVersion, right: JuliaVersion): number {
  if (left.major !== right.major) {
    return left.major - right.major;
  }
  if (left.minor !== right.minor) {
    return left.minor - right.minor;
  }
  return left.patch - right.patch;
}

export function isSupportedJuliaVersion(version: string): boolean {
  const parsed = parseJuliaVersion(version);
  if (parsed === undefined) {
    return false;
  }
  const lower = parseJuliaVersion(JULIA_VERSION_LOWER_BOUND);
  const upperMinor = parseJuliaVersion(`${JULIA_VERSION_UPPER_MINOR}.0`);
  if (lower === undefined || upperMinor === undefined) {
    throw new Error("Invalid Julia version bounds in JETLS_VERSION.json.");
  }
  const firstUnsupported = {
    major: upperMinor.major,
    minor: upperMinor.minor + 1,
    patch: 0,
  };
  return (
    compareJuliaVersions(parsed, lower) >= 0 &&
    compareJuliaVersions(parsed, firstUnsupported) < 0
  );
}

export function juliaMinorVersion(version: string): string {
  const parsed = parseJuliaVersion(version);
  if (parsed === undefined) {
    throw new Error(`Invalid Julia version '${version.trim()}'.`);
  }
  return `${parsed.major}.${parsed.minor}`;
}

export function runtimeKey(juliaPath: string, juliaVersion: string): string {
  const runtime = `${juliaPath}\n${juliaMinorVersion(juliaVersion)}`;
  return createHash("sha256").update(runtime).digest("hex").slice(0, 16);
}

export function managedDepotPath(
  storagePath: string,
  juliaPath: string,
  juliaVersion: string,
): string {
  return path.join(
    path.resolve(storagePath),
    MANAGED_DEPOTS_DIR,
    runtimeKey(juliaPath, juliaVersion),
  );
}

function appsDirectory(depotPath: string): string {
  return path.join(depotPath, "environments", "apps");
}

export function managedEnvironment(depotPath: string): string {
  return path.join(appsDirectory(depotPath), "JETLS");
}

function appsBackupPath(depotPath: string): string {
  return path.join(depotPath, "app-env-backup");
}

export function installPendingPath(depotPath: string): string {
  return path.join(depotPath, "install-pending.json");
}

function managedManifest(depotPath: string): string {
  return path.join(managedEnvironment(depotPath), "Manifest.toml");
}

function platformDelimiter(platform: NodeJS.Platform): string {
  return platform === "win32" ? ";" : ":";
}

function prependPathDirectory(
  environment: NodeJS.ProcessEnv,
  directory: string,
  platform: NodeJS.Platform,
): void {
  const existing = environmentValue(environment, "PATH", platform);
  setEnvironmentValue(
    environment,
    "PATH",
    existing
      ? `${directory}${platformDelimiter(platform)}${existing}`
      : directory,
    platform,
  );
}

// The server launches as `julia -m JETLS` against the managed environment
// with an explicit depot chain: every write stays in the managed depot
// (it comes first), while packages and precompile caches already present
// in the user's own chain stay readable and reused by analysis.
export function serverLaunchEnvironment(
  environment: NodeJS.ProcessEnv,
  depotPath: string,
  platform: NodeJS.Platform = process.platform,
): NodeJS.ProcessEnv {
  const delimiter = platformDelimiter(platform);
  const userChain = environmentValue(environment, "JULIA_DEPOT_PATH", platform);
  const depotChain =
    userChain === undefined || userChain === ""
      ? // The trailing empty entry appends the bundled system depots.
        `${depotPath}${delimiter}${path.join(homedir(), ".julia")}${delimiter}`
      : `${depotPath}${delimiter}${userChain}`;
  const result = { ...environment };
  setEnvironmentValue(result, "JULIA_DEPOT_PATH", depotChain, platform);
  setEnvironmentValue(
    result,
    "JULIA_LOAD_PATH",
    managedEnvironment(depotPath),
    platform,
  );
  return result;
}

export function managedJETLSCommands(
  installation: ManagedJETLSInstallation,
  threads = "auto",
): { command: string; versionArgs: string[]; serveArgs: string[] } {
  return {
    command: installation.juliaPath,
    versionArgs: managedJETLSArgs("version", threads),
    serveArgs: managedJETLSArgs("serve", threads),
  };
}

export function needsWindowsBatchShell(
  command: string,
  platform: NodeJS.Platform = process.platform,
): boolean {
  if (platform !== "win32") {
    return false;
  }
  const extension = path.win32.extname(command).toLowerCase();
  return extension === ".bat" || extension === ".cmd";
}

// The runner retains only a bounded tail of each stream: the full output
// is already streamed to the observers (and thus the output channel),
// while the retained result only feeds version parsing and error
// evidence. This keeps the peak memory of a long `Pkg` process bounded.
const RUNNER_OUTPUT_TAIL_LIMIT = 64 * 1024;

function appendOutputTail(tail: Buffer, chunk: Buffer): Buffer {
  const combined = tail.length === 0 ? chunk : Buffer.concat([tail, chunk]);
  return combined.length <= RUNNER_OUTPUT_TAIL_LIMIT
    ? combined
    : combined.subarray(combined.length - RUNNER_OUTPUT_TAIL_LIMIT);
}

export function createDefaultProcessRunner(
  overrides: {
    spawnProcess?: SpawnProcess;
    platform?: NodeJS.Platform;
    terminationTimeoutMs?: number;
    killProcessGroup?: (pid: number, signal: NodeJS.Signals) => void;
    isProcessGroupAlive?: (pid: number) => boolean;
  } = {},
): ProcessRunner {
  const spawnProcess = overrides.spawnProcess ?? spawn;
  const platform = overrides.platform ?? process.platform;
  const terminationTimeoutMs =
    overrides.terminationTimeoutMs ?? TIMEOUTS.processTermination;
  return async (command, args, options) => {
    return await new Promise<ProcessResult>((resolve) => {
      let stdout: Buffer = Buffer.alloc(0);
      let stderr: Buffer = Buffer.alloc(0);
      let settled = false;
      let timedOut = false;
      let closed = false;
      let closeStatus: number | null = null;
      let resolveClosed!: () => void;
      const closedPromise = new Promise<void>((resolve) => {
        resolveClosed = resolve;
      });
      // Own process group on POSIX, so termination can signal the whole
      // tree (`Pkg` spawns precompile workers that a kill of the direct
      // process alone would leave running against the depot).
      const detached = platform !== "win32";
      const child = spawnProcess(command, [...args], {
        env: options.env,
        shell: options.shell,
        windowsHide: true,
        detached,
      });
      if (child.pid !== undefined) {
        options.onPid?.(child.pid);
      }

      child.stdout?.on("data", (chunk: Buffer) => {
        stdout = appendOutputTail(stdout, chunk);
        options.onStdout?.(chunk.toString());
      });
      child.stderr?.on("data", (chunk: Buffer) => {
        stderr = appendOutputTail(stderr, chunk);
        options.onStderr?.(chunk.toString());
      });

      const finish = (
        status: number | null,
        error?: Error,
        processMayBeAlive = false,
      ): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeoutHandle);
        const timeoutMessage = timedOut
          ? `Process timed out after ${options.timeoutMs} ms.`
          : undefined;
        const processError =
          [timeoutMessage, error?.message].filter(Boolean).join(" ") ||
          undefined;
        resolve({
          status,
          stdout: stdout.toString(),
          stderr: stderr.toString(),
          error: processError,
          ...(processMayBeAlive ? { processMayBeAlive } : {}),
        });
      };

      const timeoutHandle = setTimeout(() => {
        timedOut = true;
        // A process that survives every termination attempt must not leave
        // this promise pending, but the settled result marks the survival
        // so callers keep the depot lock instead of reusing the depot.
        void terminateProcess(
          { process: child, isClosed: () => closed, closedPromise },
          {
            platform,
            terminationTimeoutMs,
            spawnProcess,
            processGroup: detached,
            killProcessGroup: overrides.killProcessGroup,
            isProcessGroupAlive: overrides.isProcessGroupAlive,
            survivalMessage: "The process did not exit after termination.",
          },
        ).then(
          () => finish(closeStatus),
          (error: unknown) => {
            finish(
              null,
              error instanceof Error ? error : new Error(String(error)),
              error instanceof ProcessSurvivedError,
            );
          },
        );
      }, options.timeoutMs);

      child.on("error", (error: Error) => {
        // Signal-delivery failures after the timeout are owned by the
        // termination flow, which settles only once the process state is
        // known.
        if (timedOut) {
          return;
        }
        finish(null, error);
      });
      child.on("close", (status: number | null) => {
        closed = true;
        closeStatus = status;
        resolveClosed();
        // After a timeout only the termination flow settles: the direct
        // process closing says nothing about surviving group members.
        if (timedOut) {
          return;
        }
        finish(status);
      });
    });
  };
}

const defaultProcessRunner: ProcessRunner = createDefaultProcessRunner();

function createLineLogger(
  logger: ((message: string) => void) | undefined,
  prefix: string,
): { write: (chunk: string) => void; flush: () => void } {
  let pending = "";
  const logLine = (line: string): void => {
    if (line !== "") {
      emit(logger, `${prefix}: ${line}`);
    }
  };
  return {
    write: (chunk) => {
      const lines = `${pending}${chunk}`.split(/\r?\n/);
      pending = lines.pop() ?? "";
      lines.forEach(logLine);
    },
    flush: () => {
      logLine(pending);
      pending = "";
    },
  };
}

function createInstallationOutputObserver(
  operation: InstallationOperation,
  progress: ((message: string) => void) | undefined,
): ProcessOutputObserver {
  const phases = [
    {
      message: "Updating registry...",
      pattern: /\b(?:Updating registry|Installing known registries)\b/i,
    },
    {
      message: "Fetching sources...",
      pattern: /\b(?:Cloning|Updating) git-repo\b/i,
    },
    {
      message: "Resolving and installing dependencies...",
      pattern: /\bResolving package versions\b/i,
    },
    {
      message: "Building dependencies...",
      pattern: /\bBuilding(?: packages)?\b/i,
    },
    {
      message: "Precompiling...",
      pattern: /\bPrecompiling\b/i,
    },
  ] as const;
  const reported = new Set<string>();

  const createStreamObserver = (): ((chunk: string) => void) => {
    let recentOutput = "";
    return (chunk: string): void => {
      // Search before truncating, so a marker in the head of an oversized
      // chunk cannot scroll out of the window unseen. `phases` is in
      // pipeline order, so matches report in that order as well.
      const combined = `${recentOutput}${chunk}`;
      const output = stripVTControlCharacters(combined);
      for (const phase of phases) {
        if (!reported.has(phase.message) && phase.pattern.test(output)) {
          reported.add(phase.message);
          emit(progress, `${operation} JETLS: ${phase.message}`);
        }
      }
      recentOutput = combined.slice(-4096);
    };
  };

  return {
    onStdout: createStreamObserver(),
    onStderr: createStreamObserver(),
  };
}

async function runProcess(
  command: string,
  args: readonly string[],
  environment: NodeJS.ProcessEnv,
  description: string,
  timeoutMs: number,
  runner: ProcessRunner,
  platform: NodeJS.Platform,
  logger: ((message: string) => void) | undefined,
  outputObserver?: ProcessOutputObserver,
): Promise<ProcessResult> {
  emit(logger, `${description}: ${JSON.stringify([command, ...args])}`);
  const stdoutLogger = createLineLogger(logger, `${description} stdout`);
  const stderrLogger = createLineLogger(logger, `${description} stderr`);
  let streamedStdout = false;
  let streamedStderr = false;
  let result: ProcessResult;
  try {
    result = await runner(command, args, {
      env: { ...environment },
      shell: needsWindowsBatchShell(command, platform),
      timeoutMs,
      onStdout: (chunk) => {
        streamedStdout = true;
        stdoutLogger.write(chunk);
        outputObserver?.onStdout(chunk);
      },
      onStderr: (chunk) => {
        streamedStderr = true;
        stderrLogger.write(chunk);
        outputObserver?.onStderr(chunk);
      },
    });
  } catch (error) {
    result = {
      status: null,
      stdout: "",
      stderr: errorMessage(error),
      error: errorMessage(error),
    };
  }
  stdoutLogger.flush();
  stderrLogger.flush();
  if (!streamedStdout && result.stdout !== "") {
    emit(logger, `${description} stdout:\n${result.stdout}`);
  }
  if (!streamedStderr && result.stderr !== "") {
    emit(logger, `${description} stderr:\n${result.stderr}`);
  }
  return result;
}

async function runCheckedProcess(
  command: string,
  args: readonly string[],
  environment: NodeJS.ProcessEnv,
  description: string,
  stage: ManagedStage,
  timeoutMs: number,
  runner: ProcessRunner,
  platform: NodeJS.Platform,
  logger: ((message: string) => void) | undefined,
  outputObserver?: ProcessOutputObserver,
): Promise<ProcessResult> {
  const result = await runProcess(
    command,
    args,
    environment,
    description,
    timeoutMs,
    runner,
    platform,
    logger,
    outputObserver,
  );
  if (result.status !== 0 || result.error !== undefined) {
    const status =
      result.status === null ? "unavailable" : String(result.status);
    const suffix = result.error === undefined ? "" : `: ${result.error}`;
    throw new ManagedStepError(
      `${description} failed with status ${status}${suffix}`,
      stage,
      { processMayBeAlive: result.processMayBeAlive === true },
    );
  }
  return result;
}

function juliaScriptArgs(script: string): string[] {
  return [...JULIA_BASE_ARGS, "-e", script];
}

function managedJETLSArgs(subcommand: string, threads?: string): string[] {
  return [
    ...JULIA_BASE_ARGS,
    ...(threads === undefined ? [] : [`--threads=${threads}`]),
    "-m",
    "JETLS",
    subcommand,
  ];
}

async function queryJuliaVersion(
  juliaPath: string,
  environment: NodeJS.ProcessEnv,
  runner: ProcessRunner,
  platform: NodeJS.Platform,
  logger: ((message: string) => void) | undefined,
): Promise<string> {
  const result = await runCheckedProcess(
    juliaPath,
    juliaScriptArgs(JULIA_VERSION_SCRIPT),
    environment,
    "Julia version check",
    "julia-version",
    TIMEOUTS.juliaVersion,
    runner,
    platform,
    logger,
  );
  const version = result.stdout.trim();
  if (parseJuliaVersion(version) === undefined) {
    throw new ManagedStepError(
      `Julia returned an invalid VERSION value '${version}'.`,
      "julia-version",
      { retryable: false },
    );
  }
  return version;
}

// Parses the `jetls version <revision>, julia version <version>` output
// used by JETLS releases since 2026-08-23.
export function isPinnedJETLSVersion(output: string): boolean {
  const matchingLines = output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.startsWith("jetls version "));
  if (matchingLines.length !== 1) {
    return false;
  }
  const match = /^jetls version ([^\s,]+)(?:[\s,].*)?$/.exec(matchingLines[0]);
  return match !== null && match[1] === JETLS_REVISION;
}

async function verifyPinnedJETLS(
  juliaPath: string,
  environment: NodeJS.ProcessEnv,
  runner: ProcessRunner,
  platform: NodeJS.Platform,
  logger: ((message: string) => void) | undefined,
): Promise<void> {
  const result = await runCheckedProcess(
    juliaPath,
    managedJETLSArgs("version"),
    environment,
    "JETLS version check",
    "verify",
    TIMEOUTS.precompilation,
    runner,
    platform,
    logger,
  );
  if (!isPinnedJETLSVersion(result.stdout)) {
    throw new ManagedStepError(
      `Managed JETLS has an unexpected version; expected ${JETLS_REVISION}.`,
      "verify",
    );
  }
}

// The install stamp records the (pin, exact Julia version) pair the depot
// last verified. While it matches, the per-start `jetls version` probe (a
// full JETLS load) is skipped. A pin bump or Julia update flips a recorded
// value; silent depot corruption does not, so managed serve failures drop
// the stamp (`invalidateInstallStamp`) to restore the verify-and-repair
// path on the next start.
export function installStampPath(depotPath: string): string {
  return path.join(depotPath, INSTALL_STAMP_FILE);
}

async function matchesInstallStamp(context: RuntimeContext): Promise<boolean> {
  try {
    const stamp = JSON.parse(
      await readFile(installStampPath(context.depotPath), "utf8"),
    ) as { revision?: unknown; julia?: unknown };
    return (
      stamp.revision === JETLS_REVISION && stamp.julia === context.juliaVersion
    );
  } catch {
    return false;
  }
}

async function writeInstallStamp(
  context: RuntimeContext,
  logger: ((message: string) => void) | undefined,
): Promise<void> {
  const stampPath = installStampPath(context.depotPath);
  const tempPath = `${stampPath}.tmp`;
  try {
    await writeFile(
      tempPath,
      JSON.stringify({ revision: JETLS_REVISION, julia: context.juliaVersion }),
    );
    await rename(tempPath, stampPath);
  } catch (error) {
    emit(
      logger,
      `Failed to write the managed install stamp: ${errorMessage(error)}`,
    );
  }
}

/**
 * Drops the install stamp so the next `ensureManagedJETLS` re-verifies the
 * managed depot and repairs it if broken. Racing a concurrent stamp write is
 * benign: that write records a state that was verified just before.
 */
export async function invalidateInstallStamp(depotPath: string): Promise<void> {
  await rm(installStampPath(depotPath), { force: true });
}

async function isFile(filePath: string): Promise<boolean> {
  try {
    return (await stat(filePath)).isFile();
  } catch {
    return false;
  }
}

function isNodeError(error: unknown, code: string): boolean {
  return (error as NodeJS.ErrnoException).code === code;
}

function processIsRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return isNodeError(error, "EPERM");
  }
}

// The owner file is written through a rename so a concurrent reader never
// sees a torn write. `activeGroup` records the managed process currently
// (or last known to be) operating on the depot: it is detached from the
// extension host, so the host's death alone does not prove the depot is
// no longer being written.
async function writeLockOwner(
  lockPath: string,
  activeGroup?: number,
): Promise<void> {
  const ownerPath = path.join(lockPath, "owner.json");
  const tempPath = `${ownerPath}.tmp`;
  await writeFile(
    tempPath,
    JSON.stringify({
      pid: process.pid,
      createdAt: new Date().toISOString(),
      ...(activeGroup === undefined ? {} : { activeGroup }),
    }),
  );
  await rename(tempPath, ownerPath);
}

// Marks the lock as ceded to the recorded surviving process: the owner
// host no longer claims it, so reclaim judges the recorded process alone
// and a retry — from this host or any other — proceeds as soon as the
// process is confirmed gone. Without a recorded process the mark is not
// written: host-PID liveness is then the only safety signal left, and it
// has to keep blocking until the host exits.
async function abandonLockToSurvivor(lockPath: string): Promise<void> {
  const ownerPath = path.join(lockPath, "owner.json");
  const owner = JSON.parse(await readFile(ownerPath, "utf8")) as {
    activeGroup?: unknown;
  };
  if (typeof owner.activeGroup !== "number") {
    return;
  }
  const tempPath = `${ownerPath}.tmp`;
  await writeFile(tempPath, JSON.stringify({ ...owner, abandoned: true }));
  await rename(tempPath, ownerPath);
}

// Probes the recorded process: a process group on POSIX, the direct
// process on Windows (where the child tree cannot be enumerated).
function activeGroupIsRunning(
  group: number,
  platform: NodeJS.Platform,
): boolean {
  try {
    process.kill(platform === "win32" ? group : -group, 0);
    return true;
  } catch (error) {
    return isNodeError(error, "EPERM");
  }
}

// A reboot is the only event that proves an unconfirmable Windows process
// tree is gone: `taskkill /T` needs a live parent, so a tree whose direct
// process already exited can never be confirmed dead while the system
// stays up.
function predatesBoot(createdAt: unknown): boolean {
  if (typeof createdAt !== "string") {
    return false;
  }
  const created = Date.parse(createdAt);
  return !Number.isNaN(created) && created < Date.now() - uptime() * 1000;
}

type LockReclaimResult = "reclaimed" | "busy" | "windows-unconfirmable";

// Disposing of a stale lock with a plain `rm` would race concurrent
// reclaimers: between judging a lock stale and removing it, another
// waiter can reclaim the lock and re-create it, and the `rm` would then
// destroy the fresh lock. An atomic `rename` first pins the removal to
// the one directory that was judged; `verify` re-examines the stolen
// instance, and a mismatch (a fresh lock created inside the window) is
// moved back into place.
let reclaimSequence = 0;

async function stealStaleLock(
  lockPath: string,
  verify: (stolenPath: string) => Promise<boolean>,
): Promise<boolean> {
  const stolenPath = `${lockPath}.reclaim-${process.pid}-${reclaimSequence++}`;
  try {
    await rename(lockPath, stolenPath);
  } catch {
    // Already released or reclaimed by another waiter.
    return true;
  }
  if (await verify(stolenPath)) {
    await rm(stolenPath, { recursive: true, force: true });
    return true;
  }
  // A failed restore (the path was re-taken inside the window) must not
  // escalate to removing an instance that may be live; leave it aside.
  await rename(stolenPath, lockPath).catch(() => undefined);
  return false;
}

async function reclaimStaleLock(
  lockPath: string,
  platform: NodeJS.Platform = process.platform,
): Promise<LockReclaimResult> {
  const ownerPath = path.join(lockPath, "owner.json");
  try {
    const owner = JSON.parse(await readFile(ownerPath, "utf8")) as {
      pid?: unknown;
      createdAt?: unknown;
      activeGroup?: unknown;
      abandoned?: unknown;
    };
    if (typeof owner.pid === "number") {
      if (processIsRunning(owner.pid) && owner.abandoned !== true) {
        // A live PID is treated as an active owner even though it could
        // be an unrelated process that reused the PID after a crash: the
        // owner's running Pkg processes cannot be fenced, so reclaiming a
        // lock that might still be live risks concurrent depot mutation.
        // The mistaken-identity case instead ends in the lock-wait
        // timeout and a clear failure. An abandoned lock is exempt: its
        // owner host has ceded it to the recorded process, which is
        // judged below.
        return "busy";
      }
      if (typeof owner.activeGroup === "number") {
        if (activeGroupIsRunning(owner.activeGroup, platform)) {
          // The dead host recorded a managed process that may still be
          // writing to the depot after outliving its host.
          return "busy";
        }
        // On Windows the record is only the direct process: its death
        // says nothing about the child tree, so the lock is reclaimed
        // only once the record provably predates the current boot.
        if (platform === "win32" && !predatesBoot(owner.createdAt)) {
          return "windows-unconfirmable";
        }
      }
      const stolen = await stealStaleLock(lockPath, async (stolenPath) => {
        try {
          const current = JSON.parse(
            await readFile(path.join(stolenPath, "owner.json"), "utf8"),
          ) as { pid?: unknown; createdAt?: unknown };
          return (
            current.pid === owner.pid && current.createdAt === owner.createdAt
          );
        } catch {
          return false;
        }
      });
      return stolen ? "reclaimed" : "busy";
    }
  } catch {
    // No readable owner; fall through to the incomplete-lock handling.
  }
  try {
    const metadata = await stat(lockPath);
    if (Date.now() - metadata.mtimeMs > INCOMPLETE_LOCK_GRACE_PERIOD) {
      const stolen = await stealStaleLock(lockPath, async (stolenPath) => {
        try {
          await readFile(path.join(stolenPath, "owner.json"), "utf8");
          // The instance gained an owner inside the window: not the
          // judged one.
          return false;
        } catch {
          // `rename` preserves the directory's own mtime, so the age
          // judgment can be repeated on the stolen instance.
          const current = await stat(stolenPath).catch(() => undefined);
          return (
            current === undefined ||
            Date.now() - current.mtimeMs > INCOMPLETE_LOCK_GRACE_PERIOD
          );
        }
      });
      return stolen ? "reclaimed" : "busy";
    }
  } catch {
    return "reclaimed";
  }
  return "busy";
}

export async function removeStaleLock(
  lockPath: string,
  platform: NodeJS.Platform = process.platform,
): Promise<boolean> {
  return (await reclaimStaleLock(lockPath, platform)) === "reclaimed";
}

async function survivorHint(lockPath: string): Promise<string> {
  try {
    const owner = JSON.parse(
      await readFile(path.join(lockPath, "owner.json"), "utf8"),
    ) as { activeGroup?: unknown };
    if (typeof owner.activeGroup === "number") {
      return (
        " A JETLS process from a previous session may still be running " +
        `(process group ${owner.activeGroup}).`
      );
    }
  } catch {
    // No readable owner; nothing to add.
  }
  return "";
}

interface DepotLockHandle {
  release: () => Promise<void>;
  abandon: () => Promise<void>;
}

async function acquireDepotLock(
  depotPath: string,
  progress: ((message: string) => void) | undefined,
  platform: NodeJS.Platform,
): Promise<DepotLockHandle> {
  const lockPath = `${depotPath}.lock`;
  await mkdir(path.dirname(lockPath), { recursive: true });
  // The lock holder is at worst running a full installation, so reuse its
  // budget for the wait.
  const deadline = Date.now() + TIMEOUTS.install;
  let reportedWait = false;

  while (true) {
    try {
      await mkdir(lockPath);
      await writeLockOwner(lockPath);
      return {
        release: async () => {
          // Only the recorded owner removes the directory: if a mistaken
          // reclaim raced this operation, the path may already hold
          // another host's lock.
          try {
            const owner = JSON.parse(
              await readFile(path.join(lockPath, "owner.json"), "utf8"),
            ) as { pid?: unknown };
            if (owner.pid !== process.pid) {
              return;
            }
          } catch {
            // Missing or unreadable owner: still ours to remove.
          }
          await rm(lockPath, { recursive: true, force: true });
        },
        abandon: () => abandonLockToSurvivor(lockPath),
      };
    } catch (error) {
      if (!isNodeError(error, "EEXIST")) {
        throw error;
      }
      const reclaimResult = await reclaimStaleLock(lockPath, platform);
      if (reclaimResult === "reclaimed") {
        continue;
      }
      if (reclaimResult === "windows-unconfirmable") {
        throw new ManagedStepError(
          `The managed depot lock ${lockPath} belongs to a Windows process ` +
            "tree whose exit cannot be confirmed during the current boot.",
          "lock",
          {
            processMayBeAlive: true,
            retryable: true,
            summary: "Restart Windows before retrying managed JETLS.",
            recovery:
              "Recovery: restart Windows, then restart the language server. " +
              "Retry and Reinstall cannot safely reclaim this lock during " +
              "the current boot.",
            cause: error,
          },
        );
      }
      if (!reportedWait) {
        emit(progress, "Waiting for another JETLS operation...");
        reportedWait = true;
      }
      if (Date.now() >= deadline) {
        throw new Error(
          `Timed out waiting for managed depot lock ${lockPath}.` +
            (await survivorHint(lockPath)),
          { cause: error },
        );
      }
      await new Promise((resolve) => setTimeout(resolve, LOCK_RETRY_DELAY));
    }
  }
}

async function withDepotLock<T>(
  depotPath: string,
  progress: ((message: string) => void) | undefined,
  platform: NodeJS.Platform,
  operation: () => Promise<T>,
): Promise<T> {
  let lock: DepotLockHandle;
  try {
    lock = await acquireDepotLock(depotPath, progress, platform);
  } catch (error) {
    if (error instanceof ManagedStepError) {
      throw error;
    }
    throw new ManagedStepError(errorMessage(error), "lock", { cause: error });
  }
  let result: T;
  try {
    result = await operation();
  } catch (error) {
    // A process that survived termination may still be mutating the
    // depot. The lock is not released but ceded to that process — it was
    // registered at spawn as the owner's `activeGroup` — so it stays in
    // force, even after this host exits, exactly until the process is
    // confirmed gone; then any host, including this one on a retry, can
    // reclaim it.
    if (stepProcessMayBeAlive(error)) {
      await lock.abandon().catch(() => undefined);
    } else {
      await lock.release();
    }
    throw error;
  }
  await lock.release();
  return result;
}

// Registers each spawned process in the lock owner file while it may be
// operating on the depot, so a host that dies mid-operation leaves the
// next host enough information not to reclaim the lock from under a
// still-running process. The record is cleared only once the process is
// confirmed gone; registration is best-effort, degrading to the
// host-PID-only safety level when the owner file cannot be written.
function registerLockProcesses(
  runner: ProcessRunner,
  lockPath: string,
): ProcessRunner {
  return async (command, args, options) => {
    let registered: Promise<void> = Promise.resolve();
    const result = await runner(command, args, {
      ...options,
      onPid: (pid) => {
        registered = writeLockOwner(lockPath, pid).catch(() => undefined);
      },
    });
    await registered;
    if (result.processMayBeAlive !== true) {
      await writeLockOwner(lockPath).catch(() => undefined);
    }
    return result;
  };
}

function repairFailure(
  verificationError: unknown,
  installationError: unknown,
): ManagedStepError {
  return new ManagedStepError(
    `The cached managed JETLS installation failed verification:\n${errorMessage(verificationError)}\n` +
      `Failed to repair the managed JETLS installation:\n${errorMessage(installationError)}`,
    "repair",
    {
      processMayBeAlive:
        stepProcessMayBeAlive(installationError) ||
        stepProcessMayBeAlive(verificationError),
      summary: "Failed to repair the managed JETLS installation.",
    },
  );
}

async function directoryExists(candidate: string): Promise<boolean> {
  try {
    return (await stat(candidate)).isDirectory();
  } catch {
    return false;
  }
}

async function backupAppEnvironments(depotPath: string): Promise<boolean> {
  if (!(await directoryExists(appsDirectory(depotPath)))) {
    return false;
  }
  // A leftover backup without a pending marker belongs to a transaction
  // whose environment was verified afterwards; it is safe to discard.
  const backupPath = appsBackupPath(depotPath);
  await rm(backupPath, { recursive: true, force: true });
  await cp(appsDirectory(depotPath), backupPath, { recursive: true });
  // The marker is written only once the backup is complete: while it
  // exists, the environments are suspect and the backup is authoritative.
  await writeFile(
    installPendingPath(depotPath),
    JSON.stringify({ revision: JETLS_REVISION }),
  );
  return true;
}

// Throws when the restore cannot be completed; the pending marker and
// the backup are removed only on success, so a later start retries the
// recovery instead of trusting a half-restored state.
async function restoreAppEnvironments(
  depotPath: string,
  logger: ((message: string) => void) | undefined,
): Promise<void> {
  try {
    await rm(appsDirectory(depotPath), { recursive: true, force: true });
    await rename(appsBackupPath(depotPath), appsDirectory(depotPath));
    await rm(installPendingPath(depotPath), { force: true });
    emit(
      logger,
      "Restored the app environments after the failed installation.",
    );
  } catch (error) {
    throw new ManagedStepError(
      `Failed to restore the app environments backup: ${errorMessage(error)}`,
      "install",
      { cause: error },
    );
  }
}

// Recovers from an installation a previous host never finished: the
// pending marker means the environments may hold a partial write, while
// the backup still holds the pre-installation state. Restoring first
// keeps a crashed or surviving-then-killed update from destroying the
// last known state, which taking a fresh backup would otherwise
// overwrite.
async function recoverPendingInstallation(
  depotPath: string,
  logger: ((message: string) => void) | undefined,
): Promise<void> {
  if (!(await isFile(installPendingPath(depotPath)))) {
    return;
  }
  if (await directoryExists(appsBackupPath(depotPath))) {
    await restoreAppEnvironments(depotPath, logger);
  } else {
    // An interrupted restore already consumed the backup, so the
    // environments hold the restored state.
    await rm(installPendingPath(depotPath), { force: true });
  }
}

async function ensureInstallation(
  context: RuntimeContext,
  baseEnvironment: NodeJS.ProcessEnv,
  launchEnvironment: NodeJS.ProcessEnv,
  runner: ProcessRunner,
  platform: NodeJS.Platform,
  logger: ((message: string) => void) | undefined,
  progress: ((message: string) => void) | undefined,
): Promise<void> {
  await recoverPendingInstallation(context.depotPath, logger);
  const lockedRunner = registerLockProcesses(
    runner,
    `${context.depotPath}.lock`,
  );
  const installed = await isFile(managedManifest(context.depotPath));
  if (installed && (await matchesInstallStamp(context))) {
    return;
  }
  let verificationError: unknown;

  if (installed) {
    emit(progress, "Verifying JETLS...");
    try {
      await verifyPinnedJETLS(
        context.juliaPath,
        launchEnvironment,
        lockedRunner,
        platform,
        logger,
      );
      await writeInstallStamp(context, logger);
      return;
    } catch (error) {
      verificationError = error;
      emit(
        logger,
        `The cached managed JETLS installation needs repair: ${errorMessage(error)}`,
      );
    }
  }

  const operation: InstallationOperation = installed
    ? "Repairing"
    : "Installing";
  emit(progress, `${operation} JETLS...`);
  await mkdir(context.depotPath, { recursive: true });
  // The app environments directory (the JETLS environment and Pkg.Apps's
  // `AppManifest.toml` under `environments/apps`) is the only state a
  // failed `Pkg.Apps.add` can corrupt: `packages/` is content-addressed
  // and append-only, and only the post-verify `Pkg.gc` deletes from it.
  // Backing it up keeps a failed update or repair from changing the
  // previous known state; the old package bodies it references are still
  // in the depot, so a restored environment stays startable. The pending
  // marker makes the transaction crash-safe: the recovery above restores
  // this backup before anything could overwrite it.
  const backedUp = await backupAppEnvironments(context.depotPath);
  const privateEnvironment = { ...baseEnvironment };
  setEnvironmentValue(
    privateEnvironment,
    "JULIA_DEPOT_PATH",
    // The trailing empty entry appends the bundled system depots so stdlib
    // caches are reused, while the user depot stays out of the chain so
    // the managed manifest only references packages that the user's own
    // `Pkg.gc` cannot collect.
    `${context.depotPath}${platformDelimiter(platform)}`,
    platform,
  );
  // `Pkg.Apps.add` warns about an "app collision" when `which("jetls")`
  // does not resolve to the shim it just generated (e.g. a manual install
  // put `~/.julia/bin/jetls` on `PATH`); putting the depot's `bin` first
  // silences the warning.
  prependPathDirectory(
    privateEnvironment,
    path.join(context.depotPath, "bin"),
    platform,
  );

  try {
    try {
      await runCheckedProcess(
        context.juliaPath,
        juliaScriptArgs(INSTALL_SCRIPT),
        privateEnvironment,
        "Managed JETLS installation",
        installed ? "repair" : "install",
        TIMEOUTS.install,
        lockedRunner,
        platform,
        logger,
        createInstallationOutputObserver(operation, progress),
      );
    } catch (error) {
      if (verificationError !== undefined) {
        throw repairFailure(verificationError, error);
      }
      throw error;
    }

    emit(progress, "Verifying installed JETLS...");
    await verifyPinnedJETLS(
      context.juliaPath,
      launchEnvironment,
      lockedRunner,
      platform,
      logger,
    );
  } catch (error) {
    // A surviving process may still be writing to the environments; leave
    // the depot alone (the retained lock blocks concurrent use anyway, and
    // the kept pending marker sends the next start through the recovery).
    if (backedUp && !stepProcessMayBeAlive(error)) {
      try {
        await restoreAppEnvironments(context.depotPath, logger);
      } catch (restoreError) {
        // The installation error stays the surfaced one; the marker and
        // the backup remain, so a later start retries the recovery.
        emit(logger, errorMessage(restoreError));
      }
    }
    throw error;
  }
  // The marker leaves first: the environments were just verified, so a
  // crash from here on must not send the next start back to the backup.
  await rm(installPendingPath(context.depotPath), { force: true });
  await writeInstallStamp(context, logger);
  // The verified installation must start regardless of backup cleanup.
  try {
    await rm(appsBackupPath(context.depotPath), {
      recursive: true,
      force: true,
    });
  } catch (error) {
    emit(
      logger,
      `Failed to remove the app environments backup: ${errorMessage(error)}`,
    );
  }

  emit(progress, "Cleaning up the JETLS depot...");
  try {
    await runCheckedProcess(
      context.juliaPath,
      juliaScriptArgs(GC_SCRIPT),
      privateEnvironment,
      "Managed JETLS depot garbage collection",
      "gc",
      TIMEOUTS.gc,
      lockedRunner,
      platform,
      logger,
    );
  } catch (error) {
    // A gc process that survived termination may still be deleting from the
    // depot; only failures of a completed process are ignorable.
    if (stepProcessMayBeAlive(error)) {
      throw error;
    }
    emit(
      logger,
      `Managed JETLS depot garbage collection failed and was ignored: ${errorMessage(error)}`,
    );
  }
}

function managedError(
  error: unknown,
  juliaCommand: string,
  depotPath: string | undefined,
  fallbackStage: ManagedStage,
): ManagedJETLSError {
  if (error instanceof ManagedJETLSError) {
    return error;
  }
  const step = error instanceof ManagedStepError ? error : undefined;
  const stage = step?.stage ?? fallbackStage;
  const processMayBeAlive = step?.processMayBeAlive === true;
  // A retry with the same configuration can help everywhere except when
  // the configured Julia command itself cannot be resolved; deterministic
  // per-error exceptions (e.g. an unsupported Julia version) override the
  // default at the throw site.
  const retryable = step?.retryable ?? stage !== "julia-resolution";
  const mayRequireNetwork = stage === "install" || stage === "repair";
  const summary = step?.summary ?? firstLine(errorMessage(error));
  // A surviving process may still mutate the depot and the depot lock is
  // deliberately kept, so a reinstall (which waits on that lock) or a
  // manual deletion would not help until the process is gone. A
  // non-retryable failure is a configuration problem that a reinstall
  // would not fix either, so its hint points at the settings only. The
  // process output itself is not embedded: the output channel has already
  // streamed the full log.
  const recovery =
    step?.recovery ??
    (processMayBeAlive
      ? "Recovery: a managed Julia process may still be running and keeps " +
        "the depot locked; end that process (or reboot) and retry — the " +
        "lock is reclaimed once the process is confirmed gone."
      : retryable
        ? "Recovery: " +
          (mayRequireNetwork ? "this step may need network access; " : "") +
          "retry by restarting the language server. If the managed depot " +
          "itself is broken, run the 'JETLS Client: Reinstall Server' " +
          "command, or configure a self-managed server via the " +
          "`jetls-client.executable` setting."
        : "Recovery: adjust the `jetls-client.executable` setting (its " +
          "`env`, or the `julia` installation it resolves) so a supported " +
          "Julia is found, or point its `path` at a self-managed JETLS " +
          "executable.");
  return new ManagedJETLSError(
    `${errorMessage(error)}\n` +
      `Julia command: ${juliaCommand}\n` +
      (depotPath === undefined ? "" : `Managed depot: ${depotPath}\n`) +
      recovery,
    { summary, retryable, processMayBeAlive },
  );
}

function configuredJuliaCommand(options: ManagedInstallationOptions): string {
  return (
    options.juliaCommand ??
    environmentValue(
      options.environment,
      "JULIA_APPS_JULIA_CMD",
      options.platform ?? process.platform,
    ) ??
    "julia"
  );
}

async function ensureRuntime(
  options: ManagedInstallationOptions,
  storagePath: string,
  juliaPath: string,
  platform: NodeJS.Platform,
  runner: ProcessRunner,
): Promise<RuntimeContext> {
  let depotPath: string | undefined;
  try {
    emit(options.progress, "Checking Julia version...");
    const juliaVersion = await queryJuliaVersion(
      juliaPath,
      options.environment,
      runner,
      platform,
      options.logger,
    );
    depotPath = managedDepotPath(storagePath, juliaPath, juliaVersion);
    if (!isSupportedJuliaVersion(juliaVersion)) {
      throw new ManagedStepError(
        `JETLS requires Julia ${JULIA_VERSION_LOWER_BOUND} through ` +
          `${JULIA_VERSION_UPPER_MINOR}.x; found Julia ${juliaVersion}.`,
        "julia-version",
        { retryable: false },
      );
    }

    const launchEnvironment = serverLaunchEnvironment(
      options.environment,
      depotPath,
      platform,
    );
    const context = { depotPath, juliaPath, juliaVersion };
    await withDepotLock(depotPath, options.progress, platform, async () => {
      await ensureInstallation(
        context,
        options.environment,
        launchEnvironment,
        runner,
        platform,
        options.logger,
        options.progress,
      );
    });
    return context;
  } catch (error) {
    // Untagged errors here come from filesystem steps of the installation
    // machinery itself.
    throw managedError(error, juliaPath, depotPath, "install");
  }
}

interface ManagedRuntimeSelection {
  platform: NodeJS.Platform;
  runner: ProcessRunner;
  storagePath: string;
  juliaPath: string;
}

async function resolveManagedRuntime(
  options: ManagedInstallationOptions,
): Promise<ManagedRuntimeSelection> {
  if (options.storagePath.length === 0) {
    throw new Error("storagePath must not be empty.");
  }
  const platform = options.platform ?? process.platform;
  const runner = options.processRunner ?? defaultProcessRunner;
  const storagePath = path.resolve(options.storagePath);
  const requestedJuliaCommand = configuredJuliaCommand(options);
  try {
    const juliaPath = await resolveExecutable(
      requestedJuliaCommand,
      options.environment,
      platform,
    );
    return { platform, runner, storagePath, juliaPath };
  } catch (error) {
    throw managedError(
      error,
      requestedJuliaCommand,
      undefined,
      "julia-resolution",
    );
  }
}

export async function ensureManagedJETLS(
  options: ManagedInstallationOptions,
): Promise<ManagedJETLSInstallation> {
  emit(options.progress, "Resolving Julia...");
  const { platform, runner, storagePath, juliaPath } =
    await resolveManagedRuntime(options);

  const context = await ensureRuntime(
    options,
    storagePath,
    juliaPath,
    platform,
    runner,
  );
  return {
    env: serverLaunchEnvironment(
      options.environment,
      context.depotPath,
      platform,
    ),
    depotPath: context.depotPath,
    juliaPath: context.juliaPath,
  };
}

/**
 * Removes the managed depot of the current Julia runtime. When `confirm`
 * is given it runs with the resolved depot path before anything is
 * touched (the server processes launched from the depot may still be
 * running at that point); returning `false` cancels the uninstall and
 * the function resolves to `undefined`.
 */
export async function uninstallManagedJETLS(
  options: ManagedInstallationOptions,
  confirm?: (depotPath: string) => boolean | Promise<boolean>,
): Promise<string | undefined> {
  const { platform, runner, storagePath, juliaPath } =
    await resolveManagedRuntime(options);

  let depotPath: string | undefined;
  try {
    const juliaVersion = await queryJuliaVersion(
      juliaPath,
      options.environment,
      runner,
      platform,
      options.logger,
    );
    const resolvedDepot = managedDepotPath(
      storagePath,
      juliaPath,
      juliaVersion,
    );
    depotPath = resolvedDepot;
    if (confirm !== undefined && !(await confirm(resolvedDepot))) {
      return undefined;
    }
    await withDepotLock(resolvedDepot, options.progress, platform, async () => {
      await rm(resolvedDepot, { recursive: true, force: true });
    });
    emit(options.logger, `Removed managed JETLS depot: ${resolvedDepot}`);
    return resolvedDepot;
  } catch (error) {
    throw managedError(error, juliaPath, depotPath, "uninstall");
  }
}
