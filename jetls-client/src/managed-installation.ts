import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { homedir } from "node:os";
import {
  mkdir,
  readdir,
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
const CURRENT_POINTER_FILE = "current";
const INSTALL_LOCK_DIR = "install.lock";
const INSTALL_STAMP_FILE = "install-stamp.json";
const LAST_USED_FILE = "last-used";
const JULIA_VERSION_LOWER_BOUND: string = JETLS_VERSION.julia.lower;
const JULIA_VERSION_UPPER_BOUND: string = JETLS_VERSION.julia.upper;

const JULIA_VERSION_SCRIPT = "print(stdout, VERSION)";
// The installation must go through `Pkg.Apps`: JETLS releases pin their
// vendored dependencies via `[sources]`, which Pkg only honors for the
// active project itself. The app environment makes the JETLS project the
// project, so the vendored pins resolve; a plain `Pkg.add` would treat
// JETLS as a dependency and fail resolution on the unregistered vendored
// packages. The generated launcher shim itself stays unused: the server
// is launched as `julia -m JETLS` directly.
const INSTALL_SCRIPT = `using Pkg; Pkg.Apps.add(; url="${JETLS_REPOSITORY}", rev="${JETLS_REVISION}")`;
const JULIA_BASE_ARGS = ["--startup-file=no", "--history-file=no"] as const;
const LOCK_RETRY_DELAY = 100;
// A lock older than the whole installation budget belongs to a dead
// host; a margin absorbs clock skew between hosts.
const LOCK_STALE_AGE = TIMEOUTS.install + 60 * 1000;
// An unpublished generation may hold an installation still in progress
// (including one whose process outlived its host), so it is only removed
// well past any plausible installation lifetime.
const UNPUBLISHED_GENERATION_GRACE = 24 * 60 * 60 * 1000;
// A published but unreferenced generation may still be running a server
// in another window; it is removed only after it has gone unused long
// enough that no live window plausibly resolved it.
const GENERATION_RETENTION = 7 * 24 * 60 * 60 * 1000;
// A whole runtime container goes stale when the user switches Julia
// (another executable, or another minor version): no start resolves it
// anymore, so nothing inside it can be in use. The retention is long
// because reclaiming a runtime the user switches back to costs a full
// reinstall.
const RUNTIME_RETENTION = 30 * 24 * 60 * 60 * 1000;

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
  /** Set when the process was terminated by the caller's abort signal. */
  cancelled?: boolean;
}

export interface ProcessRunnerOptions {
  env: NodeJS.ProcessEnv;
  shell: boolean;
  timeoutMs: number;
  onStdout?: (chunk: string) => void;
  onStderr?: (chunk: string) => void;
  /** Terminates the process (with escalation) when aborted. */
  signal?: AbortSignal;
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
  /**
   * Installs a fresh generation even when the current one is verified,
   * for recovering from corruption the verification cannot see.
   */
  forceInstall?: boolean;
  /**
   * Cancels the setup when aborted: running managed processes are
   * terminated and the whole call rejects with
   * `ManagedInstallationCancelledError`. An installation cancelled
   * mid-flight only strands its unpublished generation, which cleanup
   * removes later.
   */
  signal?: AbortSignal;
  /**
   * Called when the long installation step begins; the returned
   * callback fires when it ends, regardless of outcome. Lets the UI
   * scope install-only affordances (e.g. a cancellable notification)
   * without parsing progress messages.
   */
  onInstallStep?: () => () => void;
  /**
   * Receives each completed stderr line of the installation process,
   * sanitized and truncated for direct display, so the UI can show live
   * evidence of progress alongside the coarse phase messages.
   */
  onInstallOutput?: (line: string) => void;
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
type ManagedStage = "julia-resolution" | "julia-version" | "install" | "verify";

interface RuntimeContext {
  containerPath: string;
  juliaPath: string;
  juliaVersion: string;
}

interface ProcessOutputObserver {
  onStdout: (chunk: string) => void;
  onStderr: (chunk: string) => void;
}

class ManagedStepError extends Error {
  readonly stage: ManagedStage;
  readonly processMayBeAlive: boolean;
  /** Overrides the stage-derived retryability default when set. */
  readonly retryable?: boolean;

  constructor(
    message: string,
    stage: ManagedStage,
    options: {
      processMayBeAlive?: boolean;
      retryable?: boolean;
      cause?: unknown;
    } = {},
  ) {
    super(message, options.cause === undefined ? undefined : options);
    this.name = "ManagedStepError";
    this.stage = stage;
    this.processMayBeAlive = options.processMayBeAlive === true;
    this.retryable = options.retryable;
  }
}

/**
 * Deliberate cancellation of a managed setup (a restart superseding it,
 * or the extension deactivating). Not a failure: callers suppress the
 * failure UI for it.
 */
export class ManagedInstallationCancelledError extends Error {
  constructor() {
    super("The managed JETLS setup was cancelled.");
    this.name = "ManagedInstallationCancelledError";
  }
}

function throwIfCancelled(signal: AbortSignal | undefined): void {
  if (signal?.aborted) {
    throw new ManagedInstallationCancelledError();
  }
}

/**
 * Terminal managed-installation failure carrying the facts the UI needs
 * to pick guidance without parsing the message: a one-line `summary` for
 * notifications and the status bar tooltip, and whether a retry with the
 * same configuration can help (`retryable`). The message carries the
 * human-readable details for the output channel.
 */
export class ManagedJETLSError extends Error {
  readonly summary: string;
  readonly retryable: boolean;

  constructor(
    message: string,
    details: {
      summary: string;
      retryable: boolean;
    },
  ) {
    super(message);
    this.name = "ManagedJETLSError";
    this.summary = details.summary;
    this.retryable = details.retryable;
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

interface JuliaVersionBound {
  major: number;
  minor?: number;
  patch?: number;
}

function parseJuliaVersionBound(bound: string): JuliaVersionBound | undefined {
  const match = /^(\d+)(?:\.(\d+)(?:\.(\d+))?)?$/.exec(bound.trim());
  if (match === null) {
    return undefined;
  }
  return {
    major: Number(match[1]),
    ...(match[2] === undefined ? {} : { minor: Number(match[2]) }),
    ...(match[3] === undefined ? {} : { patch: Number(match[3]) }),
  };
}

// The bounds carry Julia's `"<lower> - <upper>"` hyphen-range compat
// semantics: components omitted from the lower bound default to zero,
// while components omitted from the upper bound act as wildcards, so an
// upper bound of `1.13` admits every `1.13.x` whereas `1.13.1` rejects
// `1.13.2`.
export function isSupportedJuliaVersion(
  version: string,
  lowerBound: string = JULIA_VERSION_LOWER_BOUND,
  upperBound: string = JULIA_VERSION_UPPER_BOUND,
): boolean {
  const parsed = parseJuliaVersion(version);
  if (parsed === undefined) {
    return false;
  }
  const lower = parseJuliaVersionBound(lowerBound);
  const upper = parseJuliaVersionBound(upperBound);
  if (lower === undefined || upper === undefined) {
    throw new Error("Invalid Julia version bounds in JETLS_VERSION.json.");
  }
  const lowerVersion = {
    major: lower.major,
    minor: lower.minor ?? 0,
    patch: lower.patch ?? 0,
  };
  const firstUnsupported =
    upper.minor === undefined
      ? { major: upper.major + 1, minor: 0, patch: 0 }
      : upper.patch === undefined
        ? { major: upper.major, minor: upper.minor + 1, patch: 0 }
        : { major: upper.major, minor: upper.minor, patch: upper.patch + 1 };
  return (
    compareJuliaVersions(parsed, lowerVersion) >= 0 &&
    compareJuliaVersions(parsed, firstUnsupported) < 0
  );
}

function supportedJuliaRangeDescription(): string {
  const upper = parseJuliaVersionBound(JULIA_VERSION_UPPER_BOUND);
  const upperDescription =
    upper?.patch === undefined
      ? `${JULIA_VERSION_UPPER_BOUND}.x`
      : JULIA_VERSION_UPPER_BOUND;
  return `${JULIA_VERSION_LOWER_BOUND} through ${upperDescription}`;
}

export function juliaMinorVersion(version: string): string {
  const parsed = parseJuliaVersion(version);
  if (parsed === undefined) {
    throw new Error(`Invalid Julia version '${version.trim()}'.`);
  }
  return `${parsed.major}.${parsed.minor}`;
}

// The key spells out the Julia minor version and hashes the executable
// path: different installations of the same Julia version are different
// builds, whose precompile caches must not share a depot, and the path
// itself cannot be embedded in a directory name safely. The patch
// version stays out deliberately: package resolution is stable within a
// minor, so a patch update only costs a re-verification of the current
// generation (the install stamp tracks the exact version) instead of a
// full reinstall into a fresh container.
export function runtimeKey(juliaPath: string, juliaVersion: string): string {
  const pathHash = createHash("sha256")
    .update(juliaPath)
    .digest("hex")
    .slice(0, 8);
  return `v${juliaMinorVersion(juliaVersion)}-${pathHash}`;
}

/**
 * The per-runtime container. Each installation lives in its own
 * immutable generation depot directly inside the container, and the
 * `current` pointer file names the generation launches resolve.
 */
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

export function currentPointerPath(containerPath: string): string {
  return path.join(containerPath, CURRENT_POINTER_FILE);
}

// The generation directory is never renamed once the installation ran:
// precompile caches record absolute source paths, so publication happens
// by pointing `current` at the directory, not by moving it.
function newGenerationId(): string {
  return `${JETLS_REVISION}-${randomBytes(4).toString("hex")}`;
}

export async function readCurrentGeneration(
  containerPath: string,
): Promise<string | undefined> {
  try {
    const pointer = JSON.parse(
      await readFile(currentPointerPath(containerPath), "utf8"),
    ) as { generation?: unknown };
    if (
      typeof pointer.generation !== "string" ||
      pointer.generation !== path.basename(pointer.generation) ||
      pointer.generation.startsWith(".")
    ) {
      return undefined;
    }
    const generationPath = path.join(containerPath, pointer.generation);
    return (await directoryExists(generationPath)) ? generationPath : undefined;
  } catch {
    return undefined;
  }
}

// Written through a rename so a concurrent reader never sees a torn
// pointer; the last concurrent publisher wins, and every published
// generation is complete, so either winner is valid.
async function writeCurrentGeneration(
  containerPath: string,
  generationId: string,
): Promise<void> {
  const pointerPath = currentPointerPath(containerPath);
  const tempPath = `${pointerPath}.tmp`;
  await writeFile(tempPath, JSON.stringify({ generation: generationId }));
  await rename(tempPath, pointerPath);
}

export function lastUsedPath(basePath: string): string {
  return path.join(basePath, LAST_USED_FILE);
}

// Records that a start resolved this generation (or runtime container),
// so cleanup keeps what a still-open window may be running a server
// from.
async function touchLastUsed(basePath: string): Promise<void> {
  await writeFile(lastUsedPath(basePath), "").catch(() => undefined);
}

function appsDirectory(depotPath: string): string {
  return path.join(depotPath, "environments", "apps");
}

export function managedEnvironment(depotPath: string): string {
  return path.join(appsDirectory(depotPath), "JETLS");
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
      const signal = options.signal;
      if (signal?.aborted) {
        resolve({
          status: null,
          stdout: "",
          stderr: "",
          error: "The process was cancelled.",
          cancelled: true,
        });
        return;
      }
      let stdout: Buffer = Buffer.alloc(0);
      let stderr: Buffer = Buffer.alloc(0);
      let settled = false;
      let timedOut = false;
      let aborted = false;
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
        signal?.removeEventListener("abort", onAbort);
        const timeoutMessage = timedOut
          ? `Process timed out after ${options.timeoutMs} ms.`
          : undefined;
        const cancelMessage = aborted
          ? "The process was cancelled."
          : undefined;
        const processError =
          [timeoutMessage, cancelMessage, error?.message]
            .filter(Boolean)
            .join(" ") || undefined;
        resolve({
          status,
          stdout: stdout.toString(),
          stderr: stderr.toString(),
          error: processError,
          ...(processMayBeAlive ? { processMayBeAlive } : {}),
          ...(aborted ? { cancelled: true } : {}),
        });
      };

      // A process that survives every termination attempt must not leave
      // this promise pending, but the settled result marks the survival
      // so failure guidance can note the possibly-live process.
      const terminateAndFinish = (): void => {
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
      };

      const timeoutHandle = setTimeout(() => {
        timedOut = true;
        terminateAndFinish();
      }, options.timeoutMs);

      const onAbort = (): void => {
        if (settled || timedOut) {
          return;
        }
        aborted = true;
        terminateAndFinish();
      };
      signal?.addEventListener("abort", onAbort, { once: true });

      child.on("error", (error: Error) => {
        // Signal-delivery failures after a timeout or abort are owned by
        // the termination flow, which settles only once the process state
        // is known.
        if (timedOut || aborted) {
          return;
        }
        finish(null, error);
      });
      child.on("close", (status: number | null) => {
        closed = true;
        closeStatus = status;
        resolveClosed();
        // After a timeout or abort only the termination flow settles: the
        // direct process closing says nothing about surviving group
        // members.
        if (timedOut || aborted) {
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

const INSTALL_OUTPUT_LINE_LIMIT = 100;

// Assembles display-ready lines out of raw output chunks: `\r` counts
// as a line break so in-place progress redraws (e.g. Pkg's precompile
// bar) surface as fresh lines instead of piling up in one.
function createInstallOutputLineEmitter(
  onLine: (line: string) => void,
): (chunk: string) => void {
  let pending = "";
  return (chunk) => {
    const lines = `${pending}${chunk}`.split(/\r\n|\r|\n/);
    pending = lines.pop() ?? "";
    for (const line of lines) {
      const cleaned = stripVTControlCharacters(line).trim();
      if (cleaned === "") {
        continue;
      }
      onLine(
        cleaned.length > INSTALL_OUTPUT_LINE_LIMIT
          ? `${cleaned.slice(0, INSTALL_OUTPUT_LINE_LIMIT - 1)}…`
          : cleaned,
      );
    }
  };
}

function createInstallationOutputObserver(
  progress: ((message: string) => void) | undefined,
  onOutputLine: ((line: string) => void) | undefined,
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
          emit(progress, `Installing JETLS: ${phase.message}`);
        }
      }
      recentOutput = combined.slice(-4096);
    };
  };

  const stderrObserver = createStreamObserver();
  const lineEmitter =
    onOutputLine === undefined
      ? undefined
      : createInstallOutputLineEmitter(onOutputLine);
  return {
    onStdout: createStreamObserver(),
    onStderr: (chunk) => {
      stderrObserver(chunk);
      lineEmitter?.(chunk);
    },
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
  if (result.cancelled === true) {
    throw new ManagedInstallationCancelledError();
  }
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

// The install stamp records the (pin, exact Julia version) pair the
// generation last verified, and marks the generation complete for
// cleanup. While it matches, the per-start `jetls version` probe (a full
// JETLS load) is skipped. A pin bump or Julia update flips a recorded
// value; silent corruption does not, so managed serve failures drop the
// stamp (`invalidateInstallStamp`) to restore the verify path on the
// next start.
export function installStampPath(generationPath: string): string {
  return path.join(generationPath, INSTALL_STAMP_FILE);
}

async function matchesInstallStamp(
  generationPath: string,
  juliaVersion: string,
): Promise<boolean> {
  try {
    const stamp = JSON.parse(
      await readFile(installStampPath(generationPath), "utf8"),
    ) as { revision?: unknown; julia?: unknown };
    return stamp.revision === JETLS_REVISION && stamp.julia === juliaVersion;
  } catch {
    return false;
  }
}

async function writeInstallStamp(
  generationPath: string,
  juliaVersion: string,
  logger: ((message: string) => void) | undefined,
): Promise<void> {
  const stampPath = installStampPath(generationPath);
  const tempPath = `${stampPath}.tmp`;
  try {
    await writeFile(
      tempPath,
      JSON.stringify({ revision: JETLS_REVISION, julia: juliaVersion }),
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
 * Drops the install stamp so the next `ensureManagedJETLS` re-verifies
 * the current generation and replaces it if broken. Racing a concurrent
 * stamp write is benign: that write records a state that was verified
 * just before.
 */
export async function invalidateInstallStamp(
  generationPath: string,
): Promise<void> {
  await rm(installStampPath(generationPath), { force: true });
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

async function pathAgeMs(candidate: string): Promise<number | undefined> {
  try {
    return Date.now() - (await stat(candidate)).mtimeMs;
  } catch {
    return undefined;
  }
}

// The install lock only keeps concurrent hosts from duplicating a long
// installation; it is not a safety boundary. Generations are immutable
// and published through an atomic pointer update, so hosts installing
// concurrently at worst waste work. That tolerance is what keeps the
// lock simple: staleness is judged by age alone, `poll` lets a waiter
// adopt a result published by the lock holder, and a waiter that
// exhausts its budget proceeds without the lock.
async function withInstallLock<T>(
  containerPath: string,
  logger: ((message: string) => void) | undefined,
  progress: ((message: string) => void) | undefined,
  signal: AbortSignal | undefined,
  poll: () => Promise<T | undefined>,
  operation: () => Promise<T>,
): Promise<T> {
  const lockPath = path.join(containerPath, INSTALL_LOCK_DIR);
  await mkdir(containerPath, { recursive: true });
  const deadline = Date.now() + TIMEOUTS.install;
  let reportedWait = false;
  let locked = false;
  while (!locked && Date.now() < deadline) {
    throwIfCancelled(signal);
    try {
      await mkdir(lockPath);
      locked = true;
    } catch (error) {
      if (!isNodeError(error, "EEXIST")) {
        throw error;
      }
      const age = await pathAgeMs(lockPath);
      if (age === undefined) {
        continue;
      }
      if (age > LOCK_STALE_AGE) {
        await rm(lockPath, { recursive: true, force: true });
        continue;
      }
      const adopted = await poll();
      if (adopted !== undefined) {
        return adopted;
      }
      if (!reportedWait) {
        emit(progress, "Waiting for another JETLS installation...");
        reportedWait = true;
      }
      await new Promise((resolve) => setTimeout(resolve, LOCK_RETRY_DELAY));
    }
  }
  if (!locked) {
    emit(
      logger,
      "Proceeding without the managed install lock after waiting out its budget.",
    );
  }
  try {
    return await operation();
  } finally {
    if (locked) {
      await rm(lockPath, { recursive: true, force: true }).catch(
        () => undefined,
      );
    }
  }
}

async function directoryExists(candidate: string): Promise<boolean> {
  try {
    return (await stat(candidate)).isDirectory();
  } catch {
    return false;
  }
}

// Removes what no start can need anymore: unpublished generations old
// enough that no installation can still be producing them, published
// generations that have gone unresolved for longer than any live window
// plausibly stays open, and sibling runtime containers (other Julia
// executables or minor versions) that no start has resolved for the
// runtime retention. A container entry that is not a control file is
// judged as a generation, which also ages out leftovers from older
// layouts. The current generation and the active container are never
// touched. Best-effort: a failure only defers cleanup.
async function cleanupManagedStorage(
  containerPath: string,
  logger: ((message: string) => void) | undefined,
): Promise<void> {
  try {
    const currentGeneration = await readCurrentGeneration(containerPath);
    for (const entry of await readdir(containerPath)) {
      if (
        entry === CURRENT_POINTER_FILE ||
        entry === INSTALL_LOCK_DIR ||
        entry === LAST_USED_FILE
      ) {
        continue;
      }
      const generationPath = path.join(containerPath, entry);
      if (generationPath === currentGeneration) {
        continue;
      }
      const published = await isFile(installStampPath(generationPath));
      const age =
        (await pathAgeMs(lastUsedPath(generationPath))) ??
        (await pathAgeMs(generationPath));
      const grace = published
        ? GENERATION_RETENTION
        : UNPUBLISHED_GENERATION_GRACE;
      if (age !== undefined && age > grace) {
        await rm(generationPath, { recursive: true, force: true });
        emit(logger, `Removed old managed JETLS generation: ${generationPath}`);
      }
    }
    const depotsPath = path.dirname(containerPath);
    for (const entry of await readdir(depotsPath)) {
      const runtimePath = path.join(depotsPath, entry);
      if (runtimePath === containerPath) {
        continue;
      }
      const age =
        (await pathAgeMs(lastUsedPath(runtimePath))) ??
        (await pathAgeMs(runtimePath));
      if (age !== undefined && age > RUNTIME_RETENTION) {
        await rm(runtimePath, { recursive: true, force: true });
        emit(
          logger,
          `Removed managed JETLS storage of an unused Julia runtime: ${runtimePath}`,
        );
      }
    }
  } catch (error) {
    emit(logger, `Managed storage cleanup was skipped: ${errorMessage(error)}`);
  }
}

async function stampedCurrentGeneration(
  context: RuntimeContext,
): Promise<string | undefined> {
  const generation = await readCurrentGeneration(context.containerPath);
  if (
    generation !== undefined &&
    (await matchesInstallStamp(generation, context.juliaVersion))
  ) {
    return generation;
  }
  return undefined;
}

async function installGeneration(
  context: RuntimeContext,
  baseEnvironment: NodeJS.ProcessEnv,
  runner: ProcessRunner,
  platform: NodeJS.Platform,
  logger: ((message: string) => void) | undefined,
  progress: ((message: string) => void) | undefined,
  onInstallOutput: ((line: string) => void) | undefined,
): Promise<string> {
  const generationId = newGenerationId();
  const generationPath = path.join(context.containerPath, generationId);
  emit(progress, "Installing JETLS...");
  await mkdir(generationPath, { recursive: true });
  const privateEnvironment = { ...baseEnvironment };
  setEnvironmentValue(
    privateEnvironment,
    "JULIA_DEPOT_PATH",
    // The trailing empty entry appends the bundled system depots so
    // stdlib caches are reused, while the user depot stays out of the
    // chain: the generation stays self-contained, so cleanup can delete
    // it whole and the user's own `Pkg.gc` cannot collect anything it
    // references.
    `${generationPath}${platformDelimiter(platform)}`,
    platform,
  );
  // `Pkg.Apps.add` warns about an "app collision" when `which("jetls")`
  // does not resolve to the shim it just generated (e.g. a manual install
  // put `~/.julia/bin/jetls` on `PATH`); putting the depot's `bin` first
  // silences the warning.
  prependPathDirectory(
    privateEnvironment,
    path.join(generationPath, "bin"),
    platform,
  );
  await runCheckedProcess(
    context.juliaPath,
    juliaScriptArgs(INSTALL_SCRIPT),
    privateEnvironment,
    "Managed JETLS installation",
    "install",
    TIMEOUTS.install,
    runner,
    platform,
    logger,
    createInstallationOutputObserver(progress, onInstallOutput),
  );
  emit(progress, "Verifying installed JETLS...");
  await verifyPinnedJETLS(
    context.juliaPath,
    serverLaunchEnvironment(baseEnvironment, generationPath, platform),
    runner,
    platform,
    logger,
  );
  await writeInstallStamp(generationPath, context.juliaVersion, logger);
  await writeCurrentGeneration(context.containerPath, generationId);
  return generationPath;
}

// Resolves the generation to launch: the stamped current generation when
// it matches, a re-verified current generation after a stamp mismatch
// (e.g. a Julia patch update or a dropped stamp), and a freshly
// installed generation otherwise. A failed or crashed installation
// leaves the previous current generation untouched — even a process that
// outlives its host only ever writes to the unpublished generation it
// was producing, which cleanup eventually removes — so nothing needs
// backups or restore transactions, and a retry can start immediately.
async function resolveGeneration(
  context: RuntimeContext,
  baseEnvironment: NodeJS.ProcessEnv,
  runner: ProcessRunner,
  platform: NodeJS.Platform,
  logger: ((message: string) => void) | undefined,
  progress: ((message: string) => void) | undefined,
  forceInstall: boolean,
  signal: AbortSignal | undefined,
  onInstallStep: (() => () => void) | undefined,
  onInstallOutput: ((line: string) => void) | undefined,
): Promise<string> {
  const settle = async (generationPath: string): Promise<string> => {
    await touchLastUsed(generationPath);
    // The container-level marker is what keeps the whole runtime alive
    // against the stale-runtime sweep.
    await touchLastUsed(context.containerPath);
    await cleanupManagedStorage(context.containerPath, logger);
    return generationPath;
  };
  if (!forceInstall) {
    const stamped = await stampedCurrentGeneration(context);
    if (stamped !== undefined) {
      return await settle(stamped);
    }
  }
  return await withInstallLock(
    context.containerPath,
    logger,
    progress,
    signal,
    // Adopt a generation published by the lock holder instead of
    // duplicating its installation.
    async () =>
      forceInstall ? undefined : await stampedCurrentGeneration(context),
    async () => {
      if (!forceInstall) {
        const stamped = await stampedCurrentGeneration(context);
        if (stamped !== undefined) {
          return await settle(stamped);
        }
        const current = await readCurrentGeneration(context.containerPath);
        if (current !== undefined && (await isFile(managedManifest(current)))) {
          emit(progress, "Verifying JETLS...");
          try {
            await verifyPinnedJETLS(
              context.juliaPath,
              serverLaunchEnvironment(baseEnvironment, current, platform),
              runner,
              platform,
              logger,
            );
            await writeInstallStamp(current, context.juliaVersion, logger);
            return await settle(current);
          } catch (error) {
            if (error instanceof ManagedInstallationCancelledError) {
              throw error;
            }
            emit(
              logger,
              "The current managed JETLS installation failed verification " +
                `and will be replaced: ${errorMessage(error)}`,
            );
          }
        }
      }
      const endInstallStep = onInstallStep?.();
      try {
        return await settle(
          await installGeneration(
            context,
            baseEnvironment,
            runner,
            platform,
            logger,
            progress,
            onInstallOutput,
          ),
        );
      } finally {
        endInstallStep?.();
      }
    },
  );
}

function managedError(
  error: unknown,
  juliaCommand: string,
  containerPath: string | undefined,
  fallbackStage: ManagedStage,
): ManagedJETLSError {
  if (error instanceof ManagedJETLSError) {
    return error;
  }
  const step = error instanceof ManagedStepError ? error : undefined;
  const stage = step?.stage ?? fallbackStage;
  // A retry with the same configuration can help everywhere except when
  // the configured Julia command itself cannot be resolved; deterministic
  // per-error exceptions (e.g. an unsupported Julia version) override the
  // default at the throw site.
  const retryable = step?.retryable ?? stage !== "julia-resolution";
  const mayRequireNetwork = stage === "install";
  const summary = firstLine(errorMessage(error));
  // A process that survived termination only ever writes to the
  // unpublished generation it was producing, so it cannot affect a
  // retry; the note is purely informational. A non-retryable failure is
  // a configuration problem that a reinstall would not fix either, so
  // its hint points at the settings only. The process output itself is
  // not embedded: the output channel has already streamed the full log.
  const survivorNote =
    step?.processMayBeAlive === true
      ? "A managed Julia process may still be running in the background; " +
        "it cannot affect a new installation attempt, though ending it " +
        "(or rebooting) frees its resources.\n"
      : "";
  const recovery = retryable
    ? "Recovery: " +
      (mayRequireNetwork ? "this step may need network access; " : "") +
      "retry by restarting the language server. If the managed " +
      "installation itself is broken, run the 'JETLS Client: Reinstall " +
      "Server' command, or configure a self-managed server via the " +
      "`jetls-client.executable` setting."
    : "Recovery: adjust the `jetls-client.executable` setting (its " +
      "`env`, or the `julia` installation it resolves) so a supported " +
      "Julia is found, or point its `path` at a self-managed JETLS " +
      "executable.";
  return new ManagedJETLSError(
    `${errorMessage(error)}\n` +
      `Julia command: ${juliaCommand}\n` +
      (containerPath === undefined
        ? ""
        : `Managed storage: ${containerPath}\n`) +
      survivorNote +
      recovery,
    { summary, retryable },
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
): Promise<string> {
  let containerPath: string | undefined;
  try {
    throwIfCancelled(options.signal);
    emit(options.progress, "Checking Julia version...");
    const juliaVersion = await queryJuliaVersion(
      juliaPath,
      options.environment,
      runner,
      platform,
      options.logger,
    );
    containerPath = managedDepotPath(storagePath, juliaPath, juliaVersion);
    if (!isSupportedJuliaVersion(juliaVersion)) {
      throw new ManagedStepError(
        `JETLS requires Julia ${supportedJuliaRangeDescription()}; ` +
          `found Julia ${juliaVersion}.`,
        "julia-version",
        { retryable: false },
      );
    }
    return await resolveGeneration(
      { containerPath, juliaPath, juliaVersion },
      options.environment,
      runner,
      platform,
      options.logger,
      options.progress,
      options.forceInstall === true,
      options.signal,
      options.onInstallStep,
      options.onInstallOutput,
    );
  } catch (error) {
    // A cancellation is not a failure; it passes through unclassified so
    // callers can suppress the failure UI.
    if (error instanceof ManagedInstallationCancelledError) {
      throw error;
    }
    // Untagged errors here come from filesystem steps of the installation
    // machinery itself.
    throw managedError(error, juliaPath, containerPath, "install");
  }
}

interface ManagedRuntimeSelection {
  platform: NodeJS.Platform;
  runner: ProcessRunner;
  storagePath: string;
  juliaPath: string;
}

// Every managed process observes the setup's abort signal; attaching it
// to the runner here spares each step from threading it through.
function attachAbortSignal(
  runner: ProcessRunner,
  signal: AbortSignal | undefined,
): ProcessRunner {
  if (signal === undefined) {
    return runner;
  }
  return (command, args, options) =>
    runner(command, args, { ...options, signal });
}

async function resolveManagedRuntime(
  options: ManagedInstallationOptions,
): Promise<ManagedRuntimeSelection> {
  if (options.storagePath.length === 0) {
    throw new Error("storagePath must not be empty.");
  }
  const platform = options.platform ?? process.platform;
  const runner = attachAbortSignal(
    options.processRunner ?? defaultProcessRunner,
    options.signal,
  );
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

/**
 * Resolves (installing or verifying as needed) the managed JETLS
 * installation and returns the launch configuration; `depotPath` is the
 * generation depot the server launches from.
 */
export async function ensureManagedJETLS(
  options: ManagedInstallationOptions,
): Promise<ManagedJETLSInstallation> {
  emit(options.progress, "Resolving Julia...");
  const { platform, runner, storagePath, juliaPath } =
    await resolveManagedRuntime(options);

  const generationPath = await ensureRuntime(
    options,
    storagePath,
    juliaPath,
    platform,
    runner,
  );
  return {
    env: serverLaunchEnvironment(options.environment, generationPath, platform),
    depotPath: generationPath,
    juliaPath,
  };
}
