import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  stat,
  utimes,
  writeFile,
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import * as path from "node:path";
import * as assert from "node:assert/strict";
import { test } from "node:test";

import jetlsVersion from "../JETLS_VERSION.json";

import {
  JETLS_REPOSITORY,
  JETLS_REVISION,
  ManagedJETLSError,
  createDefaultProcessRunner,
  currentPointerPath,
  ensureManagedJETLS,
  installStampPath,
  invalidateInstallStamp,
  isPinnedJETLSVersion,
  isSupportedJuliaVersion,
  lastUsedPath,
  managedEnvironment,
  managedDepotPath,
  managedJETLSCommands,
  needsWindowsBatchShell,
  parseJuliaVersion,
  readCurrentGeneration,
  resolveExecutable,
  runtimeKey,
  serverLaunchEnvironment,
  type ManagedInstallationOptions,
  type ProcessResult,
  type ProcessRunner,
  type ProcessRunnerOptions,
} from "../src/managed-installation";
import {
  ProcessSurvivedError,
  terminateProcess,
} from "../src/process-termination";
import { FakeChildProcess, SpawnCall } from "./fake-child-process";

interface ProcessCall {
  command: string;
  args: string[];
  options: ProcessRunnerOptions;
}

interface Fixture {
  root: string;
  storagePath: string;
  juliaPath: string;
  environment: NodeJS.ProcessEnv;
}

function success(stdout = "", stderr = ""): ProcessResult {
  return { status: 0, stdout, stderr };
}

function failure(status: number, stdout = "", stderr = ""): ProcessResult {
  return { status, stdout, stderr };
}

function fakeRunner(
  handler: (
    call: ProcessCall,
    index: number,
  ) => ProcessResult | Promise<ProcessResult>,
): { calls: ProcessCall[]; runner: ProcessRunner } {
  const calls: ProcessCall[] = [];
  const runner: ProcessRunner = async (command, args, options) => {
    const call = {
      command,
      args: [...args],
      options: {
        env: { ...options.env },
        shell: options.shell,
        timeoutMs: options.timeoutMs,
        onStdout: options.onStdout,
        onStderr: options.onStderr,
      },
    };
    calls.push(call);
    return await handler(call, calls.length - 1);
  };
  return { calls, runner };
}

function scriptFor(call: ProcessCall): string | undefined {
  const expressionIndex = call.args.indexOf("-e");
  return expressionIndex === -1 ? undefined : call.args[expressionIndex + 1];
}

function callsWithScript(calls: ProcessCall[], text: string): ProcessCall[] {
  return calls.filter((call) => scriptFor(call)?.includes(text));
}

async function withFixture(
  run: (fixture: Fixture) => Promise<void>,
): Promise<void> {
  const root = await mkdtemp(
    path.join(tmpdir(), "jetls-managed-installation-"),
  );
  const binPath = path.join(root, "runtime", "bin");
  const juliaPath = path.join(
    binPath,
    process.platform === "win32" ? "julia.exe" : "julia",
  );
  const storagePath = path.join(root, "storage");
  await mkdir(binPath, { recursive: true });
  await writeFile(juliaPath, "");
  await chmod(juliaPath, 0o755);
  try {
    await run({
      root,
      storagePath,
      juliaPath,
      environment: {
        PATH: `${binPath}${path.delimiter}${path.join(root, "other-bin")}`,
      },
    });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

function standardRunner(
  juliaPath: string,
  options: {
    jetlsVersions?: ProcessResult[];
    installDelay?: number;
    installOutput?: (call: ProcessCall) => void;
    onInstallOutput?: () => void;
  } = {},
): { calls: ProcessCall[]; runner: ProcessRunner } {
  let jetlsVersionIndex = 0;
  return fakeRunner(async (call) => {
    const script = scriptFor(call);
    if (call.command === juliaPath && script?.includes("Pkg.Apps.add")) {
      if (options.installOutput === undefined) {
        call.options.onStderr?.("Precompiling packages...\n");
      } else {
        options.installOutput(call);
      }
      options.onInstallOutput?.();
      if (options.installDelay !== undefined) {
        await new Promise((resolve) =>
          setTimeout(resolve, options.installDelay),
        );
      }
      return success("installed\n");
    }
    if (call.command === juliaPath && script !== undefined) {
      return success("1.12.2\n");
    }
    if (isJETLSVersionCall(call)) {
      const result = options.jetlsVersions?.[jetlsVersionIndex];
      jetlsVersionIndex += 1;
      return (
        result ??
        success(`jetls version ${JETLS_REVISION}, julia version 1.12.2\n`)
      );
    }
    throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
  });
}

// Seeds a generation the way a completed installation leaves it: a
// manifest inside the generation depot, the `current` pointer naming it,
// and (unless disabled) a matching install stamp.
async function seedGeneration(
  storagePath: string,
  juliaPath: string,
  options: {
    juliaVersion?: string;
    stampJuliaVersion?: string;
    stamped?: boolean;
    id?: string;
  } = {},
): Promise<string> {
  const juliaVersion = options.juliaVersion ?? "1.12.2";
  const containerPath = managedDepotPath(storagePath, juliaPath, juliaVersion);
  const id = options.id ?? `${JETLS_REVISION}-seeded`;
  const generationPath = path.join(containerPath, id);
  const manifest = path.join(
    managedEnvironment(generationPath),
    "Manifest.toml",
  );
  await mkdir(path.dirname(manifest), { recursive: true });
  await writeFile(manifest, "");
  if (options.stamped !== false) {
    await writeFile(
      installStampPath(generationPath),
      JSON.stringify({
        revision: JETLS_REVISION,
        julia: options.stampJuliaVersion ?? juliaVersion,
      }),
    );
  }
  await writeFile(
    currentPointerPath(containerPath),
    JSON.stringify({ generation: id }),
  );
  return generationPath;
}

// Creates a generation directory without touching the `current` pointer,
// for exercising cleanup of unreferenced generations.
async function seedUnreferencedGeneration(
  containerPath: string,
  id: string,
  stamped: boolean,
): Promise<string> {
  const generationPath = path.join(containerPath, id);
  await mkdir(generationPath, { recursive: true });
  if (stamped) {
    await writeFile(
      installStampPath(generationPath),
      JSON.stringify({ revision: JETLS_REVISION, julia: "1.12.2" }),
    );
  }
  return generationPath;
}

async function setAgeMs(target: string, ageMs: number): Promise<void> {
  const time = new Date(Date.now() - ageMs);
  await utimes(target, time, time);
}

function isJETLSVersionCall(call: ProcessCall): boolean {
  return call.args.includes("JETLS") && call.args.at(-1) === "version";
}

function jetlsVersionCalls(calls: ProcessCall[]): ProcessCall[] {
  return calls.filter(isJETLSVersionCall);
}

const posixOnlyTest = process.platform === "win32" ? test.skip : test;

test("reads the supported Julia version range from JETLS_VERSION.json", () => {
  const lower = parseJuliaVersion(jetlsVersion.julia.lower);
  const upper = /^(\d+)\.(\d+)$/.exec(jetlsVersion.julia.upperMinor);
  assert.ok(lower !== undefined);
  assert.ok(upper !== null);

  assert.equal(isSupportedJuliaVersion(jetlsVersion.julia.lower), true);
  if (lower.patch > 0) {
    assert.equal(
      isSupportedJuliaVersion(
        `${lower.major}.${lower.minor}.${lower.patch - 1}`,
      ),
      false,
    );
  }
  const upperMajor = Number(upper[1]);
  const upperMinor = Number(upper[2]);
  assert.equal(
    isSupportedJuliaVersion(`${upperMajor}.${upperMinor}.999`),
    true,
  );
  assert.equal(
    isSupportedJuliaVersion(`${upperMajor}.${upperMinor + 1}.0`),
    false,
  );
  assert.equal(isSupportedJuliaVersion("invalid"), false);
});

test("keys depots by executable and Julia minor version", () => {
  const firstPatch = runtimeKey("/runtime/bin/julia", "1.12.2");
  const nextPatch = runtimeKey("/runtime/bin/julia", "1.12.9");
  assert.equal(firstPatch, nextPatch);
  assert.notEqual(firstPatch, runtimeKey("/runtime/bin/julia", "1.13.0"));
  assert.notEqual(firstPatch, runtimeKey("/other/bin/julia", "1.12.2"));
  // The minor version reads in the clear; only the executable path is
  // hashed.
  assert.match(firstPatch, /^v1\.12-[0-9a-f]{8}$/);
});

test("resolves Julia from the supplied PATH and handles explicit paths", async () => {
  await withFixture(async (fixture) => {
    const resolvedBare = await resolveExecutable("julia", fixture.environment);
    assert.equal(resolvedBare, fixture.juliaPath);

    const resolvedPath = await resolveExecutable(fixture.juliaPath, {
      PATH: path.join(fixture.root, "missing"),
    });
    assert.equal(resolvedPath, fixture.juliaPath);

    if (process.platform === "win32") {
      const jetlsPath = path.join(path.dirname(fixture.juliaPath), "jetls.bat");
      await writeFile(jetlsPath, "@echo off\r\n");
      const resolvedJETLS = await resolveExecutable(
        "jetls",
        fixture.environment,
        "win32",
      );
      assert.equal(resolvedJETLS, jetlsPath);
      assert.equal(needsWindowsBatchShell(resolvedJETLS, "win32"), true);
    }

    assert.equal(
      needsWindowsBatchShell("C:\\managed\\jetls.bat", "win32"),
      true,
    );
    assert.equal(
      needsWindowsBatchShell("C:\\managed\\jetls.cmd", "win32"),
      true,
    );
    assert.equal(
      needsWindowsBatchShell("C:\\managed\\jetls.exe", "win32"),
      false,
    );
    assert.equal(needsWindowsBatchShell("/managed/jetls.bat", "linux"), false);

    const launchEnvironment = serverLaunchEnvironment(
      {
        ...fixture.environment,
        JULIA_DEPOT_PATH: "/custom/depot",
        JULIA_LOAD_PATH: "/custom/environment",
      },
      "/managed/depot",
    );
    assert.equal(
      launchEnvironment.JULIA_DEPOT_PATH,
      `/managed/depot${path.delimiter}/custom/depot`,
    );
    assert.equal(
      launchEnvironment.JULIA_LOAD_PATH,
      managedEnvironment("/managed/depot"),
    );

    const defaultChain = serverLaunchEnvironment(
      { PATH: "/usr/bin" },
      "/managed/depot",
    );
    assert.equal(
      defaultChain.JULIA_DEPOT_PATH,
      `/managed/depot${path.delimiter}` +
        `${path.join(homedir(), ".julia")}${path.delimiter}`,
    );
  });
});

test("builds direct julia launch commands for the managed server", () => {
  const installation = {
    env: {},
    depotPath: "/managed/depot",
    juliaPath: "/runtime/bin/julia",
  };
  const commands = managedJETLSCommands(installation, "4");
  assert.equal(commands.command, "/runtime/bin/julia");
  assert.deepEqual(commands.serveArgs, [
    "--startup-file=no",
    "--history-file=no",
    "--threads=4",
    "-m",
    "JETLS",
    "serve",
  ]);
  assert.equal(commands.versionArgs.at(-1), "version");
  assert.ok(
    managedJETLSCommands(installation).serveArgs.includes("--threads=auto"),
  );
});

test("recognizes only the exact pinned JETLS version", () => {
  assert.equal(
    isPinnedJETLSVersion(
      `jetls version ${JETLS_REVISION}, julia version 1.12.2\n`,
    ),
    true,
  );
  assert.equal(isPinnedJETLSVersion("jetls version 2026-08-05\n"), false);
  assert.equal(
    isPinnedJETLSVersion(`jetls version ${JETLS_REVISION}0\n`),
    false,
  );
  assert.equal(
    isPinnedJETLSVersion(
      `jetls version ${JETLS_REVISION}\njetls version ${JETLS_REVISION}\n`,
    ),
    false,
  );
});

test("uses a verified current generation without reinstalling", async () => {
  await withFixture(async (fixture) => {
    const generationPath = await seedGeneration(
      fixture.storagePath,
      fixture.juliaPath,
      { stamped: false },
    );
    const fake = standardRunner(fixture.juliaPath);
    const environment: NodeJS.ProcessEnv = {
      ...fixture.environment,
      JULIA_DEPOT_PATH: "user-depot",
    };

    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment,
      processRunner: fake.runner,
    });

    assert.equal(installation.juliaPath, fixture.juliaPath);
    assert.equal(installation.depotPath, generationPath);
    assert.equal(
      installation.env.JULIA_DEPOT_PATH,
      `${installation.depotPath}${path.delimiter}user-depot`,
    );
    assert.equal(
      installation.env.JULIA_LOAD_PATH,
      managedEnvironment(installation.depotPath),
    );
    assert.equal(installation.env.PATH, environment.PATH);
    assert.equal(fake.calls.length, 2);
    assert.equal(fake.calls[1].command, fixture.juliaPath);
    assert.deepEqual(fake.calls[1].args, [
      "--startup-file=no",
      "--history-file=no",
      "-m",
      "JETLS",
      "version",
    ]);
    assert.equal(
      fake.calls[1].options.env.JULIA_DEPOT_PATH,
      `${installation.depotPath}${path.delimiter}user-depot`,
    );
    assert.equal(callsWithScript(fake.calls, "Pkg.Apps.add").length, 0);
  });
});

test("skips the version probe when the install stamp matches", async () => {
  await withFixture(async (fixture) => {
    const generationPath = await seedGeneration(
      fixture.storagePath,
      fixture.juliaPath,
    );
    const fake = standardRunner(fixture.juliaPath);

    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    assert.equal(installation.depotPath, generationPath);
    assert.equal(fake.calls.length, 1);
    assert.equal(scriptFor(fake.calls[0]), "print(stdout, VERSION)");
  });
});

test("stamps a verified installation for later fast starts", async () => {
  await withFixture(async (fixture) => {
    await seedGeneration(fixture.storagePath, fixture.juliaPath, {
      stamped: false,
    });
    const fake = standardRunner(fixture.juliaPath);
    const options: ManagedInstallationOptions = {
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    };

    const installation = await ensureManagedJETLS(options);
    assert.equal(jetlsVersionCalls(fake.calls).length, 1);
    const stamp = JSON.parse(
      await readFile(installStampPath(installation.depotPath), "utf8"),
    ) as { revision: string; julia: string };
    assert.deepEqual(stamp, { revision: JETLS_REVISION, julia: "1.12.2" });

    await ensureManagedJETLS(options);
    assert.equal(jetlsVersionCalls(fake.calls).length, 1);
  });
});

test("re-verifies when the stamp records another Julia patch version", async () => {
  await withFixture(async (fixture) => {
    const generationPath = await seedGeneration(
      fixture.storagePath,
      fixture.juliaPath,
      { stampJuliaVersion: "1.12.1" },
    );
    const fake = standardRunner(fixture.juliaPath);

    await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    assert.equal(jetlsVersionCalls(fake.calls).length, 1);
    const stamp = JSON.parse(
      await readFile(installStampPath(generationPath), "utf8"),
    ) as { julia: string };
    assert.equal(stamp.julia, "1.12.2");
  });
});

test("invalidating the stamp restores the version probe", async () => {
  await withFixture(async (fixture) => {
    await seedGeneration(fixture.storagePath, fixture.juliaPath, {
      stamped: false,
    });
    const fake = standardRunner(fixture.juliaPath);
    const options: ManagedInstallationOptions = {
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    };

    const installation = await ensureManagedJETLS(options);
    assert.equal(jetlsVersionCalls(fake.calls).length, 1);

    await invalidateInstallStamp(installation.depotPath);
    await ensureManagedJETLS(options);
    assert.equal(jetlsVersionCalls(fake.calls).length, 2);
  });
});

test("installs and verifies the exact pin in a private generation depot", async () => {
  await withFixture(async (fixture) => {
    const fake = standardRunner(fixture.juliaPath);
    const progress: string[] = [];
    const environment: NodeJS.ProcessEnv = {
      ...fixture.environment,
      JULIA_DEPOT_PATH: "user-depot",
    };

    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment,
      processRunner: fake.runner,
      progress: (message) => progress.push(message),
    });

    const containerPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    // The generation lives directly inside the container and is
    // published through the `current` pointer.
    assert.equal(path.dirname(installation.depotPath), containerPath);
    assert.ok(path.basename(installation.depotPath).startsWith(JETLS_REVISION));
    assert.equal(
      await readCurrentGeneration(containerPath),
      installation.depotPath,
    );
    await stat(installStampPath(installation.depotPath));

    const installCalls = callsWithScript(fake.calls, "Pkg.Apps.add");
    const versionCalls = jetlsVersionCalls(fake.calls);
    assert.equal(installCalls.length, 1);
    assert.equal(versionCalls.length, 1);
    assert.match(
      scriptFor(installCalls[0]) ?? "",
      new RegExp(`url="${JETLS_REPOSITORY.replaceAll(".", "\\.")}"`),
    );
    assert.match(
      scriptFor(installCalls[0]) ?? "",
      new RegExp(`rev="${JETLS_REVISION}"`),
    );
    // The generation's own `bin` leads the install PATH, keeping
    // `Pkg.Apps.add` from warning about a colliding `jetls` elsewhere on
    // `PATH`.
    assert.ok(
      (installCalls[0].options.env.PATH ?? "").startsWith(
        `${path.join(installation.depotPath, "bin")}${path.delimiter}`,
      ),
    );
    assert.equal(
      installCalls[0].options.env.JULIA_DEPOT_PATH,
      `${installation.depotPath}${path.delimiter}`,
    );
    assert.equal(
      versionCalls[0].options.env.JULIA_DEPOT_PATH,
      `${installation.depotPath}${path.delimiter}user-depot`,
    );
    assert.equal(
      installation.env.JULIA_DEPOT_PATH,
      `${installation.depotPath}${path.delimiter}user-depot`,
    );
    assert.ok(progress.some((message) => message.startsWith("Installing")));
    await assert.rejects(stat(path.join(containerPath, "install.lock")));
  });
});

test("streams installation output before the process exits", async () => {
  await withFixture(async (fixture) => {
    let notifyOutput: () => void = () => undefined;
    const outputReceived = new Promise<void>((resolve) => {
      notifyOutput = resolve;
    });
    const fake = standardRunner(fixture.juliaPath, {
      installDelay: 30,
      onInstallOutput: notifyOutput,
    });
    const logs: string[] = [];
    let completed = false;
    const operation = ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
      logger: (message) => logs.push(message),
    }).then((installation) => {
      completed = true;
      return installation;
    });

    await outputReceived;
    assert.equal(completed, false);
    assert.ok(
      logs.some((message) => message.includes("Precompiling packages")),
    );
    await operation;
  });
});

test("reports installation phases from non-TTY Pkg output", async () => {
  await withFixture(async (fixture) => {
    const fake = standardRunner(fixture.juliaPath, {
      installOutput: (call) => {
        call.options.onStderr?.("Updating reg");
        call.options.onStderr?.("istry at `/tmp/General`\n");
        call.options.onStderr?.("Cloning git-repo `JETLS.jl`\n");
        call.options.onStderr?.("Resolving package");
        call.options.onStderr?.(" versions...\n");
        call.options.onStderr?.("Installed JuliaSyntax v1.0.2\n");
        call.options.onStderr?.("Building JETLS → `/tmp/build.log`\n");
        call.options.onStderr?.("Precompiling packages...\n");
      },
    });
    const progress: string[] = [];

    await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
      progress: (message) => progress.push(message),
    });

    assert.deepEqual(
      progress.filter((message) => message.startsWith("Installing JETLS")),
      [
        "Installing JETLS...",
        "Installing JETLS: Updating registry...",
        "Installing JETLS: Fetching sources...",
        "Installing JETLS: Resolving and installing dependencies...",
        "Installing JETLS: Building dependencies...",
        "Installing JETLS: Precompiling...",
      ],
    );
  });
});

test("reports installation phases from ANSI-colored Pkg output", async () => {
  await withFixture(async (fixture) => {
    const fake = standardRunner(fixture.juliaPath, {
      installOutput: (call) => {
        // A phase marker wrapped in color sequences and split mid-word,
        // mirroring Pkg's TTY output arriving in arbitrary chunks.
        call.options.onStderr?.("\u001b[2K\u001b[32m\u001b[1m  Precompi");
        call.options.onStderr?.("ling\u001b[22m\u001b[39m packages...\n");
      },
    });
    const progress: string[] = [];

    await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
      progress: (message) => progress.push(message),
    });

    assert.ok(progress.includes("Installing JETLS: Precompiling..."));
  });
});

test("keeps phases from the head of oversized output chunks", async () => {
  await withFixture(async (fixture) => {
    const fake = standardRunner(fixture.juliaPath, {
      installOutput: (call) => {
        call.options.onStderr?.(
          `Resolving package versions...\n${"#".repeat(8192)}\n`,
        );
      },
    });
    const progress: string[] = [];

    await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
      progress: (message) => progress.push(message),
    });

    assert.ok(
      progress.includes(
        "Installing JETLS: Resolving and installing dependencies...",
      ),
    );
  });
});

test("replaces the current generation after failed verification", async () => {
  await withFixture(async (fixture) => {
    const seeded = await seedGeneration(
      fixture.storagePath,
      fixture.juliaPath,
      {
        stamped: false,
      },
    );
    const fake = standardRunner(fixture.juliaPath, {
      jetlsVersions: [
        failure(1, "broken stdout\n", "broken stderr\n"),
        success(`jetls version ${JETLS_REVISION}, julia version 1.12.2\n`),
      ],
    });
    const progress: string[] = [];

    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
      progress: (message) => progress.push(message),
    });

    assert.equal(installation.juliaPath, fixture.juliaPath);
    assert.equal(callsWithScript(fake.calls, "Pkg.Apps.add").length, 1);
    assert.equal(jetlsVersionCalls(fake.calls).length, 2);
    assert.ok(progress.includes("Installing JETLS: Precompiling..."));
    // The replacement is a fresh generation; the broken one stays behind
    // for cleanup instead of being repaired in place.
    assert.notEqual(installation.depotPath, seeded);
    await stat(installStampPath(installation.depotPath));
    const containerPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    assert.equal(
      await readCurrentGeneration(containerPath),
      installation.depotPath,
    );
  });
});

test("fails when the fresh installation still mismatches the pin", async () => {
  await withFixture(async (fixture) => {
    const seeded = await seedGeneration(
      fixture.storagePath,
      fixture.juliaPath,
      {
        stamped: false,
      },
    );
    const oldVersion = success(
      "jetls version 2026-08-05, julia version 1.12.2\n",
    );
    const fake = standardRunner(fixture.juliaPath, {
      jetlsVersions: [oldVersion, oldVersion],
    });
    const containerPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );

    await assert.rejects(
      ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      }),
      (error: unknown) => {
        assert.ok(error instanceof ManagedJETLSError);
        assert.match(error.message, new RegExp(`expected ${JETLS_REVISION}`));
        assert.match(error.message, /Julia command:/);
        assert.ok(error.message.includes(containerPath));
        // The recovery hint speaks in VSCode terms, not internal API names.
        assert.match(error.message, /Reinstall Server/);
        assert.equal(error.retryable, true);
        assert.match(error.summary, /unexpected version/);
        return true;
      },
    );
    assert.equal(callsWithScript(fake.calls, "Pkg.Apps.add").length, 1);
    // The failed installation publishes nothing: the pointer still names
    // the previous generation and the failed one carries no stamp.
    assert.equal(await readCurrentGeneration(containerPath), seeded);
    await assert.rejects(stat(path.join(containerPath, "install.lock")));
  });
});

test("a failed update leaves the current generation untouched", async () => {
  await withFixture(async (fixture) => {
    // The current generation carries a stamp for an older pin, as after
    // an extension update.
    const seeded = await seedGeneration(
      fixture.storagePath,
      fixture.juliaPath,
      {
        stampJuliaVersion: "1.12.2",
      },
    );
    await writeFile(
      installStampPath(seeded),
      JSON.stringify({ revision: "2026-08-05", julia: "1.12.2" }),
    );
    const manifest = path.join(managedEnvironment(seeded), "Manifest.toml");
    await writeFile(manifest, "old manifest\n");
    const containerPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    const fake = fakeRunner(async (call) => {
      const script = scriptFor(call);
      if (script?.includes("Pkg.Apps.add")) {
        return failure(1, "", "could not download package sources\n");
      }
      if (script !== undefined) {
        return success("1.12.2\n");
      }
      if (isJETLSVersionCall(call)) {
        // The current installation still reports the previous pin.
        return success("jetls version 2026-08-05, julia version 1.12.2\n");
      }
      throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
    });

    // The update fails outright; the old revision is never started.
    await assert.rejects(
      ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      }),
      (error: unknown) => {
        assert.ok(error instanceof ManagedJETLSError);
        assert.match(error.summary, /Managed JETLS installation failed/);
        return true;
      },
    );

    // The failed installation went to its own generation: the previous
    // one, including its environment, is untouched and still current.
    assert.equal(await readFile(manifest, "utf8"), "old manifest\n");
    assert.equal(await readCurrentGeneration(containerPath), seeded);
    await assert.rejects(stat(path.join(containerPath, "install.lock")));
  });
});

test("a surviving installer does not block a retry", async () => {
  await withFixture(async (fixture) => {
    const surviving = fakeRunner(async (call) => {
      const script = scriptFor(call);
      if (script?.includes("Pkg.Apps.add")) {
        return {
          status: null,
          stdout: "",
          stderr: "",
          error:
            "Process timed out after 10 ms. " +
            "The process did not exit after termination.",
          processMayBeAlive: true,
        };
      }
      if (script !== undefined) {
        return success("1.12.2\n");
      }
      throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
    });

    await assert.rejects(
      ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: surviving.runner,
      }),
      (error: unknown) => {
        assert.ok(error instanceof ManagedJETLSError);
        // The survivor only writes to its own unpublished generation, so
        // a retry can help and the message merely notes the process.
        assert.equal(error.retryable, true);
        assert.match(error.message, /may still be running in the background/);
        return true;
      },
    );

    // The retry installs into a fresh generation and succeeds while the
    // survivor's generation stays behind for cleanup.
    const fake = standardRunner(fixture.juliaPath);
    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });
    assert.equal(callsWithScript(fake.calls, "Pkg.Apps.add").length, 1);
    const containerPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    assert.equal(
      await readCurrentGeneration(containerPath),
      installation.depotPath,
    );
    const generations = (await readdir(containerPath)).filter((entry) =>
      entry.startsWith(JETLS_REVISION),
    );
    assert.equal(generations.length, 2);
  });
});

test("classifies first-install failures as retryable install errors", async () => {
  await withFixture(async (fixture) => {
    const fake = fakeRunner(async (call) => {
      const script = scriptFor(call);
      if (script?.includes("Pkg.Apps.add")) {
        return failure(1, "", "could not download package sources\n");
      }
      if (script !== undefined) {
        return success("1.12.2\n");
      }
      throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
    });
    const expectedDepot = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );

    await assert.rejects(
      ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      }),
      (error: unknown) => {
        assert.ok(error instanceof ManagedJETLSError);
        assert.equal(error.retryable, true);
        assert.equal(
          error.summary,
          "Managed JETLS installation failed with status 1",
        );
        assert.ok(error.message.includes(expectedDepot));
        assert.match(error.message, /may need network access/);
        return true;
      },
    );

    // The failed process has exited, so the install lock is released.
    await assert.rejects(stat(path.join(expectedDepot, "install.lock")));
  });
});

test("classifies an unsupported Julia version as non-retryable", async () => {
  await withFixture(async (fixture) => {
    const fake = fakeRunner(async () => success("1.10.5\n"));

    await assert.rejects(
      ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      }),
      (error: unknown) => {
        assert.ok(error instanceof ManagedJETLSError);
        assert.equal(error.retryable, false);
        assert.match(error.summary, /found Julia 1\.10\.5/);
        // A configuration problem gets a settings-oriented hint; a
        // reinstall would not fix it.
        assert.match(error.message, /jetls-client\.executable/);
        assert.doesNotMatch(error.message, /Reinstall Server/);
        return true;
      },
    );
  });
});

test("classifies an unresolvable Julia command as a resolution failure", async () => {
  await withFixture(async (fixture) => {
    await assert.rejects(
      ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        juliaCommand: "missing-julia",
        processRunner: fakeRunner(async () => success()).runner,
      }),
      (error: unknown) => {
        assert.ok(error instanceof ManagedJETLSError);
        assert.equal(error.retryable, false);
        assert.match(
          error.summary,
          /Unable to find executable 'missing-julia'/,
        );
        return true;
      },
    );
  });
});

test("force install replaces a verified current generation", async () => {
  await withFixture(async (fixture) => {
    const seeded = await seedGeneration(fixture.storagePath, fixture.juliaPath);
    const fake = standardRunner(fixture.juliaPath);

    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
      forceInstall: true,
    });

    assert.equal(callsWithScript(fake.calls, "Pkg.Apps.add").length, 1);
    assert.notEqual(installation.depotPath, seeded);
    const containerPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    assert.equal(
      await readCurrentGeneration(containerPath),
      installation.depotPath,
    );
    // The previous generation is left for cleanup, not deleted up front:
    // another window may still be running a server from it.
    await stat(seeded);
  });
});

test("cleanup removes aged generations but never the current one", async () => {
  await withFixture(async (fixture) => {
    const seeded = await seedGeneration(fixture.storagePath, fixture.juliaPath);
    const containerPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    // An old unpublished generation (a crashed or surviving install), an
    // old published one (long superseded), and a fresh published one.
    const crashed = await seedUnreferencedGeneration(
      containerPath,
      "crashed",
      false,
    );
    await setAgeMs(crashed, 25 * 60 * 60 * 1000);
    const superseded = await seedUnreferencedGeneration(
      containerPath,
      "superseded",
      true,
    );
    await writeFile(lastUsedPath(superseded), "");
    await setAgeMs(lastUsedPath(superseded), 8 * 24 * 60 * 60 * 1000);
    const recent = await seedUnreferencedGeneration(
      containerPath,
      "recent",
      true,
    );
    await writeFile(lastUsedPath(recent), "");
    // The current generation is exempt from the age judgment entirely.
    await writeFile(lastUsedPath(seeded), "");
    await setAgeMs(lastUsedPath(seeded), 30 * 24 * 60 * 60 * 1000);
    const fake = standardRunner(fixture.juliaPath);

    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    assert.equal(installation.depotPath, seeded);
    await assert.rejects(stat(crashed));
    await assert.rejects(stat(superseded));
    await stat(recent);
    await stat(seeded);
    // The resolution marks both the generation and the runtime container
    // as used.
    await stat(lastUsedPath(seeded));
    await stat(lastUsedPath(containerPath));
  });
});

test("cleanup removes runtime containers of Julia versions no longer used", async () => {
  await withFixture(async (fixture) => {
    await seedGeneration(fixture.storagePath, fixture.juliaPath);
    const containerPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    const depotsPath = path.dirname(containerPath);
    // A runtime nothing resolved past the retention, one still in use,
    // and a marker-less leftover (e.g. a legacy lock directory) judged by
    // its own mtime.
    const staleRuntime = path.join(depotsPath, "stale-runtime");
    await mkdir(staleRuntime, { recursive: true });
    await writeFile(lastUsedPath(staleRuntime), "");
    await setAgeMs(lastUsedPath(staleRuntime), 31 * 24 * 60 * 60 * 1000);
    const liveRuntime = path.join(depotsPath, "live-runtime");
    await mkdir(liveRuntime, { recursive: true });
    await writeFile(lastUsedPath(liveRuntime), "");
    const leftover = path.join(depotsPath, "leftover.lock");
    await mkdir(leftover, { recursive: true });
    await setAgeMs(leftover, 31 * 24 * 60 * 60 * 1000);
    const fake = standardRunner(fixture.juliaPath);

    await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    await assert.rejects(stat(staleRuntime));
    await assert.rejects(stat(leftover));
    await stat(liveRuntime);
    await stat(containerPath);
  });
});

test("cleanup ages out entries outside the generation layout", async () => {
  await withFixture(async (fixture) => {
    const seeded = await seedGeneration(fixture.storagePath, fixture.juliaPath);
    const containerPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    // Leftovers from an older layout are judged like unpublished
    // generations: removed once aged, kept while fresh.
    const legacyDir = path.join(containerPath, "environments");
    await mkdir(path.join(legacyDir, "apps"), { recursive: true });
    await setAgeMs(legacyDir, 25 * 60 * 60 * 1000);
    const legacyFile = path.join(containerPath, "install-stamp.json");
    await writeFile(legacyFile, "{}");
    await setAgeMs(legacyFile, 25 * 60 * 60 * 1000);
    const freshEntry = path.join(containerPath, "fresh-entry");
    await mkdir(freshEntry, { recursive: true });
    const fake = standardRunner(fixture.juliaPath);

    await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    await assert.rejects(stat(legacyDir));
    await assert.rejects(stat(legacyFile));
    await stat(freshEntry);
    await stat(seeded);
  });
});

test("the install lock serializes concurrent ensures for the same runtime", async () => {
  await withFixture(async (fixture) => {
    const fake = standardRunner(fixture.juliaPath, { installDelay: 150 });
    const options: ManagedInstallationOptions = {
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    };

    const [first, second] = await Promise.all([
      ensureManagedJETLS(options),
      ensureManagedJETLS(options),
    ]);

    assert.equal(first.depotPath, second.depotPath);
    // Both callers query the Julia version, but the loser of the lock
    // race adopts the winner's published generation instead of
    // duplicating the installation.
    assert.equal(
      callsWithScript(fake.calls, "print(stdout, VERSION)").length,
      2,
    );
    assert.equal(callsWithScript(fake.calls, "Pkg.Apps.add").length, 1);
    assert.equal(jetlsVersionCalls(fake.calls).length, 1);
  });
});

test("removes a stale install lock by age", async () => {
  await withFixture(async (fixture) => {
    const containerPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    const lockPath = path.join(containerPath, "install.lock");
    await mkdir(lockPath, { recursive: true });
    // Older than the whole installation budget: its holder is dead.
    await setAgeMs(lockPath, 17 * 60 * 1000);
    const fake = standardRunner(fixture.juliaPath);

    await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    assert.equal(callsWithScript(fake.calls, "Pkg.Apps.add").length, 1);
    await assert.rejects(stat(lockPath));
  });
});

test("terminates a timed-out process group and reports the timeout", async () => {
  const child = new FakeChildProcess();
  child.onKill = () => child.close(null, "SIGTERM");
  const spawnCalls: SpawnCall[] = [];
  const groupSignals: [number, NodeJS.Signals][] = [];
  const runner = createDefaultProcessRunner({
    spawnProcess: (command, args, options) => {
      spawnCalls.push({ command, args, options });
      return child.asChildProcess();
    },
    platform: "darwin",
    terminationTimeoutMs: 20,
    killProcessGroup: (pid, signal) => {
      groupSignals.push([pid, signal]);
      child.kill(signal);
    },
    isProcessGroupAlive: () => false,
  });

  const result = await runner("cmd", [], {
    env: {},
    shell: false,
    timeoutMs: 10,
  });

  assert.equal(spawnCalls[0].options.detached, true);
  assert.deepEqual(groupSignals, [[1234, "SIGTERM"]]);
  assert.equal(result.status, null);
  assert.equal(result.processMayBeAlive, undefined);
  assert.match(result.error ?? "", /Process timed out after 10 ms\./);
});

test("escalates to a group SIGKILL when a timed-out process ignores termination", async () => {
  const child = new FakeChildProcess();
  child.onKill = (signal) => {
    if (signal === "SIGKILL") {
      child.close(null, "SIGKILL");
    }
  };
  const groupSignals: NodeJS.Signals[] = [];
  const runner = createDefaultProcessRunner({
    spawnProcess: () => child.asChildProcess(),
    platform: "darwin",
    terminationTimeoutMs: 10,
    killProcessGroup: (_pid, signal) => {
      groupSignals.push(signal);
      child.kill(signal);
    },
    isProcessGroupAlive: () => false,
  });

  const result = await runner("cmd", [], {
    env: {},
    shell: false,
    timeoutMs: 10,
  });

  assert.deepEqual(groupSignals, ["SIGTERM", "SIGKILL"]);
  assert.equal(result.status, null);
  assert.match(result.error ?? "", /Process timed out after 10 ms\./);
});

test("marks survival when the process never exits", async () => {
  const child = new FakeChildProcess();
  const groupSignals: NodeJS.Signals[] = [];
  const runner = createDefaultProcessRunner({
    spawnProcess: () => child.asChildProcess(),
    platform: "darwin",
    terminationTimeoutMs: 5,
    killProcessGroup: (_pid, signal) => {
      groupSignals.push(signal);
    },
  });

  const result = await runner("cmd", [], {
    env: {},
    shell: false,
    timeoutMs: 10,
  });

  assert.deepEqual(groupSignals, ["SIGTERM", "SIGKILL"]);
  assert.equal(result.status, null);
  assert.equal(result.processMayBeAlive, true);
  assert.match(
    result.error ?? "",
    /Process timed out after 10 ms\. The process did not exit after termination\./,
  );
});

posixOnlyTest(
  "terminates real process groups including TERM-ignoring children",
  async () => {
    const runner = createDefaultProcessRunner({ terminationTimeoutMs: 500 });
    // The direct process dies on the group SIGTERM while the child ignores
    // it, so only the group-death probe and the SIGKILL escalation can
    // finish the tree.
    const script = '(trap "" TERM; exec sleep 30) & exec sleep 30';

    const result = await runner("bash", ["-c", script], {
      env: { PATH: process.env.PATH ?? "" },
      shell: false,
      timeoutMs: 300,
    });

    assert.match(result.error ?? "", /Process timed out/);
    assert.notEqual(result.processMayBeAlive, true);
  },
);

posixOnlyTest("bounds the output retained by the process runner", async () => {
  const runner = createDefaultProcessRunner();
  const script = 'head -c 200000 /dev/zero | tr "\\0" "x"; printf "TAIL-END"';

  const result = await runner("bash", ["-c", script], {
    env: { PATH: process.env.PATH ?? "" },
    shell: false,
    timeoutMs: 10_000,
  });

  assert.equal(result.status, 0);
  assert.ok(result.stdout.length <= 64 * 1024);
  assert.ok(result.stdout.endsWith("TAIL-END"));
});

function closedTerminationTarget(child: FakeChildProcess) {
  return {
    process: child.asChildProcess(),
    isClosed: () => true,
    closedPromise: Promise.resolve(),
  };
}

test("escalates when the direct process closed but its group lives", async () => {
  const groupSignals: NodeJS.Signals[] = [];
  let groupAlive = true;

  await terminateProcess(closedTerminationTarget(new FakeChildProcess()), {
    platform: "darwin",
    terminationTimeoutMs: 20,
    spawnProcess: () => {
      throw new Error("spawn is unused on POSIX");
    },
    processGroup: true,
    killProcessGroup: (_pid, signal) => {
      groupSignals.push(signal);
      if (signal === "SIGKILL") {
        groupAlive = false;
      }
    },
    isProcessGroupAlive: () => groupAlive,
    survivalMessage: "unused",
  });

  assert.deepEqual(groupSignals, ["SIGTERM", "SIGKILL"]);
});

test("returns for a closed process with no surviving group", async () => {
  const groupSignals: NodeJS.Signals[] = [];

  await terminateProcess(closedTerminationTarget(new FakeChildProcess()), {
    platform: "darwin",
    terminationTimeoutMs: 20,
    spawnProcess: () => {
      throw new Error("spawn is unused on POSIX");
    },
    processGroup: true,
    killProcessGroup: (_pid, signal) => {
      groupSignals.push(signal);
    },
    isProcessGroupAlive: () => false,
    survivalMessage: "unused",
  });

  assert.deepEqual(groupSignals, []);
});

test("reports survival for a pre-closed process on Windows", async () => {
  // A parent that closed before termination started can no longer anchor
  // a `taskkill /T`, so its tree is unconfirmable.
  await assert.rejects(
    terminateProcess(closedTerminationTarget(new FakeChildProcess()), {
      platform: "win32",
      terminationTimeoutMs: 20,
      spawnProcess: () => {
        throw new Error("taskkill must not run for a closed parent");
      },
      survivalMessage: "The process did not exit after termination.",
    }),
    ProcessSurvivedError,
  );
});

test("marks survival when group members outlive the closed parent", async () => {
  const child = new FakeChildProcess();
  child.onKill = (signal) => {
    if (signal === "SIGTERM") {
      // The direct process dies, but its worker group keeps running.
      child.close(null, "SIGTERM");
    }
  };
  const groupSignals: NodeJS.Signals[] = [];
  const runner = createDefaultProcessRunner({
    spawnProcess: () => child.asChildProcess(),
    platform: "darwin",
    terminationTimeoutMs: 10,
    killProcessGroup: (_pid, signal) => {
      groupSignals.push(signal);
      child.kill(signal);
    },
    isProcessGroupAlive: () => true,
  });

  const result = await runner("cmd", [], {
    env: {},
    shell: false,
    timeoutMs: 10,
  });

  assert.deepEqual(groupSignals, ["SIGTERM", "SIGKILL"]);
  assert.equal(result.status, null);
  assert.equal(result.processMayBeAlive, true);
  assert.match(
    result.error ?? "",
    /Process timed out after 10 ms\. The process did not exit after termination\./,
  );
});

test("terminates timed-out process trees with taskkill on Windows", async () => {
  const child = new FakeChildProcess();
  const taskkill = new FakeChildProcess();
  const spawnCalls: SpawnCall[] = [];
  const runner = createDefaultProcessRunner({
    spawnProcess: (command, args, options) => {
      spawnCalls.push({ command, args, options });
      if (spawnCalls.length === 1) {
        return child.asChildProcess();
      }
      queueMicrotask(() => {
        taskkill.close(0, null);
        child.close(null, null);
      });
      return taskkill.asChildProcess();
    },
    platform: "win32",
    terminationTimeoutMs: 20,
  });

  const result = await runner("cmd", [], {
    env: {},
    shell: false,
    timeoutMs: 10,
  });

  assert.equal(spawnCalls.length, 2);
  assert.equal(spawnCalls[1].command, "taskkill");
  assert.deepEqual(spawnCalls[1].args, ["/PID", "1234", "/T", "/F"]);
  assert.deepEqual(child.killCalls, []);
  assert.equal(result.status, null);
  assert.match(result.error ?? "", /Process timed out after 10 ms\./);
});
