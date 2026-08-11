import { spawn } from "node:child_process";
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
  ensureManagedJETLS,
  installPendingPath,
  installStampPath,
  invalidateInstallStamp,
  isPinnedJETLSVersion,
  isSupportedJuliaVersion,
  managedEnvironment,
  managedDepotPath,
  managedJETLSCommands,
  needsWindowsBatchShell,
  parseJuliaVersion,
  removeStaleLock,
  uninstallManagedJETLS,
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
        onPid: options.onPid,
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
    gcResult?: ProcessResult;
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
    if (call.command === juliaPath && script?.includes("Pkg.gc")) {
      return options.gcResult ?? success();
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

async function createAppManifest(
  storagePath: string,
  juliaPath: string,
  juliaVersion = "1.12.2",
): Promise<string> {
  const depotPath = managedDepotPath(storagePath, juliaPath, juliaVersion);
  const manifest = path.join(managedEnvironment(depotPath), "Manifest.toml");
  await mkdir(path.dirname(manifest), { recursive: true });
  await writeFile(manifest, "");
  return manifest;
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
  assert.match(firstPatch, /^[0-9a-f]{16}$/);
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

test("uses a verified cached installation without reinstalling", async () => {
  await withFixture(async (fixture) => {
    await createAppManifest(fixture.storagePath, fixture.juliaPath);
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
    assert.equal(callsWithScript(fake.calls, "Pkg.gc").length, 0);
  });
});

test("skips the version probe when the install stamp matches", async () => {
  await withFixture(async (fixture) => {
    await createAppManifest(fixture.storagePath, fixture.juliaPath);
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    await writeFile(
      installStampPath(depotPath),
      JSON.stringify({ revision: JETLS_REVISION, julia: "1.12.2" }),
    );
    const fake = standardRunner(fixture.juliaPath);

    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    assert.equal(installation.depotPath, depotPath);
    assert.equal(fake.calls.length, 1);
    assert.equal(scriptFor(fake.calls[0]), "print(stdout, VERSION)");
  });
});

test("stamps a verified installation for later fast starts", async () => {
  await withFixture(async (fixture) => {
    await createAppManifest(fixture.storagePath, fixture.juliaPath);
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
    await createAppManifest(fixture.storagePath, fixture.juliaPath);
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    await writeFile(
      installStampPath(depotPath),
      JSON.stringify({ revision: JETLS_REVISION, julia: "1.12.1" }),
    );
    const fake = standardRunner(fixture.juliaPath);

    await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    assert.equal(jetlsVersionCalls(fake.calls).length, 1);
    const stamp = JSON.parse(
      await readFile(installStampPath(depotPath), "utf8"),
    ) as { julia: string };
    assert.equal(stamp.julia, "1.12.2");
  });
});

test("invalidating the stamp restores the version probe", async () => {
  await withFixture(async (fixture) => {
    await createAppManifest(fixture.storagePath, fixture.juliaPath);
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

test("installs and verifies the exact pin in a private depot", async () => {
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

    const installCalls = callsWithScript(fake.calls, "Pkg.Apps.add");
    const gcCalls = callsWithScript(fake.calls, "Pkg.gc");
    const versionCalls = jetlsVersionCalls(fake.calls);
    assert.equal(installCalls.length, 1);
    assert.equal(gcCalls.length, 1);
    assert.equal(versionCalls.length, 1);
    assert.match(
      scriptFor(installCalls[0]) ?? "",
      new RegExp(`url="${JETLS_REPOSITORY.replaceAll(".", "\\.")}"`),
    );
    assert.match(
      scriptFor(installCalls[0]) ?? "",
      new RegExp(`rev="${JETLS_REVISION}"`),
    );
    // The depot's own `bin` leads the install PATH, keeping `Pkg.Apps.add`
    // from warning about a colliding `jetls` elsewhere on `PATH`.
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
      gcCalls[0].options.env.JULIA_DEPOT_PATH,
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
    assert.equal(progress.at(-1), "Cleaning up the JETLS depot...");
    await assert.rejects(stat(`${installation.depotPath}.lock`));
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

test("repairs a cached installation after failed verification", async () => {
  await withFixture(async (fixture) => {
    await createAppManifest(fixture.storagePath, fixture.juliaPath);
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
    assert.ok(progress.includes("Repairing JETLS: Precompiling..."));
    // The verified repair stamps the depot and consumes its backup and
    // pending marker.
    await stat(installStampPath(installation.depotPath));
    await assert.rejects(
      stat(path.join(installation.depotPath, "app-env-backup")),
    );
    await assert.rejects(stat(installPendingPath(installation.depotPath)));
  });
});

test("fails after one repair when the installed version still mismatches", async () => {
  await withFixture(async (fixture) => {
    const manifest = await createAppManifest(
      fixture.storagePath,
      fixture.juliaPath,
    );
    await writeFile(manifest, "old manifest\n");
    const oldVersion = success(
      "jetls version 2026-08-05, julia version 1.12.2\n",
    );
    const fake = standardRunner(fixture.juliaPath, {
      jetlsVersions: [oldVersion, oldVersion],
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
        assert.match(error.message, new RegExp(`expected ${JETLS_REVISION}`));
        assert.match(error.message, /Julia command:/);
        assert.ok(error.message.includes(expectedDepot));
        // The recovery hint speaks in VSCode terms, not internal API names.
        assert.match(error.message, /Reinstall Server/);
        assert.doesNotMatch(
          error.message,
          /resetManagedJETLS|uninstallManagedJETLS/,
        );
        assert.equal(error.retryable, true);
        assert.match(error.summary, /unexpected version/);
        return true;
      },
    );
    assert.equal(callsWithScript(fake.calls, "Pkg.Apps.add").length, 1);
    assert.equal(callsWithScript(fake.calls, "Pkg.gc").length, 0);
    // The failed process has exited, so the depot lock is released.
    await assert.rejects(stat(`${expectedDepot}.lock`));
    // The failed verification restores the previous environment and
    // writes no stamp.
    assert.equal(await readFile(manifest, "utf8"), "old manifest\n");
    await assert.rejects(stat(installStampPath(expectedDepot)));
    await assert.rejects(stat(path.join(expectedDepot, "app-env-backup")));
  });
});

test("a failed update restores the previous app environment", async () => {
  await withFixture(async (fixture) => {
    const manifest = await createAppManifest(
      fixture.storagePath,
      fixture.juliaPath,
    );
    await writeFile(manifest, "old manifest\n");
    const environmentDir = path.dirname(manifest);
    const appsDir = path.dirname(environmentDir);
    await writeFile(path.join(environmentDir, "Project.toml"), "old project\n");
    await writeFile(
      path.join(appsDir, "AppManifest.toml"),
      "old appmanifest\n",
    );
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    const fake = fakeRunner(async (call) => {
      const script = scriptFor(call);
      if (script?.includes("Pkg.Apps.add")) {
        // A failed update may have partially rewritten the environment
        // and the app manifest before erroring out.
        await writeFile(manifest, "clobbered manifest\n");
        await writeFile(
          path.join(appsDir, "AppManifest.toml"),
          "clobbered appmanifest\n",
        );
        return failure(1, "", "could not download package sources\n");
      }
      if (script !== undefined) {
        return success("1.12.2\n");
      }
      if (isJETLSVersionCall(call)) {
        // The cached installation still reports the previous pin.
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
        assert.equal(
          error.summary,
          "Failed to repair the managed JETLS installation.",
        );
        return true;
      },
    );

    assert.equal(await readFile(manifest, "utf8"), "old manifest\n");
    assert.equal(
      await readFile(path.join(environmentDir, "Project.toml"), "utf8"),
      "old project\n",
    );
    assert.equal(
      await readFile(path.join(appsDir, "AppManifest.toml"), "utf8"),
      "old appmanifest\n",
    );
    await assert.rejects(stat(installStampPath(depotPath)));
    await assert.rejects(stat(path.join(depotPath, "app-env-backup")));
    await assert.rejects(stat(installPendingPath(depotPath)));
    await assert.rejects(stat(`${depotPath}.lock`));
  });
});

test("recovers the pre-crash backup before repairing", async () => {
  await withFixture(async (fixture) => {
    const manifest = await createAppManifest(
      fixture.storagePath,
      fixture.juliaPath,
    );
    await writeFile(manifest, "partial manifest\n");
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    // A crashed update left the pending marker, the pre-update backup,
    // and a partially written environment behind.
    const backupPath = path.join(depotPath, "app-env-backup");
    await mkdir(path.join(backupPath, "JETLS"), { recursive: true });
    await writeFile(
      path.join(backupPath, "JETLS", "Manifest.toml"),
      "good manifest\n",
    );
    await writeFile(
      installPendingPath(depotPath),
      JSON.stringify({ revision: JETLS_REVISION }),
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
        return success("jetls version 2026-08-05, julia version 1.12.2\n");
      }
      throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
    });

    await assert.rejects(
      ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      }),
    );

    // The pre-crash state was restored before the fresh backup could
    // overwrite it, and it survived the failed repair.
    assert.equal(await readFile(manifest, "utf8"), "good manifest\n");
    await assert.rejects(stat(installPendingPath(depotPath)));
    await assert.rejects(stat(backupPath));
  });
});

test("discards a stale backup without a pending marker", async () => {
  await withFixture(async (fixture) => {
    const manifest = await createAppManifest(
      fixture.storagePath,
      fixture.juliaPath,
    );
    await writeFile(manifest, "current manifest\n");
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    // A backup without a marker comes from a transaction that verified
    // its environment afterwards; it must not be restored.
    const backupPath = path.join(depotPath, "app-env-backup");
    await mkdir(path.join(backupPath, "JETLS"), { recursive: true });
    await writeFile(
      path.join(backupPath, "JETLS", "Manifest.toml"),
      "ancient manifest\n",
    );
    const fake = standardRunner(fixture.juliaPath, {
      jetlsVersions: [
        failure(1, "", "broken\n"),
        success(`jetls version ${JETLS_REVISION}, julia version 1.12.2\n`),
      ],
    });

    await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    assert.equal(await readFile(manifest, "utf8"), "current manifest\n");
    await assert.rejects(stat(backupPath));
    await assert.rejects(stat(installPendingPath(depotPath)));
  });
});

test("a surviving installer leaves the backup and pending marker", async () => {
  await withFixture(async (fixture) => {
    const manifest = await createAppManifest(
      fixture.storagePath,
      fixture.juliaPath,
    );
    await writeFile(manifest, "old manifest\n");
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    const fake = fakeRunner(async (call) => {
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
      if (isJETLSVersionCall(call)) {
        return failure(1, "", "broken\n");
      }
      throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
    });

    await assert.rejects(
      ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      }),
      (error: unknown) => {
        assert.ok(error instanceof ManagedJETLSError);
        assert.equal(error.processMayBeAlive, true);
        return true;
      },
    );

    // The surviving installer may still write: nothing is restored, and
    // the kept marker sends the next start through the recovery.
    await stat(installPendingPath(depotPath));
    assert.equal(
      await readFile(
        path.join(depotPath, "app-env-backup", "JETLS", "Manifest.toml"),
        "utf8",
      ),
      "old manifest\n",
    );
    await stat(`${depotPath}.lock`);
  });
});

posixOnlyTest(
  "aborts the start when the pending recovery cannot restore",
  async () => {
    await withFixture(async (fixture) => {
      const manifest = await createAppManifest(
        fixture.storagePath,
        fixture.juliaPath,
      );
      const depotPath = managedDepotPath(
        fixture.storagePath,
        fixture.juliaPath,
        "1.12.2",
      );
      const backupPath = path.join(depotPath, "app-env-backup");
      await mkdir(path.join(backupPath, "JETLS"), { recursive: true });
      await writeFile(
        path.join(backupPath, "JETLS", "Manifest.toml"),
        "good manifest\n",
      );
      await writeFile(
        installPendingPath(depotPath),
        JSON.stringify({ revision: JETLS_REVISION }),
      );
      // A read-only parent makes the apps directory undeletable, so the
      // restore cannot complete.
      const environmentsDir = path.dirname(
        path.dirname(path.dirname(manifest)),
      );
      await chmod(environmentsDir, 0o555);
      const fake = standardRunner(fixture.juliaPath);

      try {
        await assert.rejects(
          ensureManagedJETLS({
            storagePath: fixture.storagePath,
            environment: fixture.environment,
            processRunner: fake.runner,
          }),
          /Failed to restore the app environments backup/,
        );
      } finally {
        await chmod(environmentsDir, 0o755);
      }

      // The marker and the backup survive, so a later start can retry.
      await stat(installPendingPath(depotPath));
      await stat(path.join(backupPath, "JETLS", "Manifest.toml"));
    });
  },
);

posixOnlyTest(
  "keeps the marker and backup when the rollback cannot restore",
  async () => {
    await withFixture(async (fixture) => {
      const manifest = await createAppManifest(
        fixture.storagePath,
        fixture.juliaPath,
      );
      await writeFile(manifest, "old manifest\n");
      const depotPath = managedDepotPath(
        fixture.storagePath,
        fixture.juliaPath,
        "1.12.2",
      );
      const environmentsDir = path.dirname(
        path.dirname(path.dirname(manifest)),
      );
      const logs: string[] = [];
      const fake = fakeRunner(async (call) => {
        const script = scriptFor(call);
        if (script?.includes("Pkg.Apps.add")) {
          // Break the restore before the install failure returns.
          await chmod(environmentsDir, 0o555);
          return failure(1, "", "could not download package sources\n");
        }
        if (script !== undefined) {
          return success("1.12.2\n");
        }
        if (isJETLSVersionCall(call)) {
          return failure(1, "", "broken\n");
        }
        throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
      });

      try {
        await assert.rejects(
          ensureManagedJETLS({
            storagePath: fixture.storagePath,
            environment: fixture.environment,
            processRunner: fake.runner,
            logger: (message) => logs.push(message),
          }),
          (error: unknown) => {
            assert.ok(error instanceof ManagedJETLSError);
            // The installation error stays the surfaced one.
            assert.match(
              error.summary,
              /Failed to repair the managed JETLS installation/,
            );
            return true;
          },
        );
      } finally {
        await chmod(environmentsDir, 0o755);
      }

      assert.ok(
        logs.some((message) =>
          message.includes("Failed to restore the app environments backup"),
        ),
      );
      // The marker and the backup survive, so a later start can retry.
      await stat(installPendingPath(depotPath));
      assert.equal(
        await readFile(
          path.join(depotPath, "app-env-backup", "JETLS", "Manifest.toml"),
          "utf8",
        ),
        "old manifest\n",
      );
    });
  },
);

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
        assert.equal(error.processMayBeAlive, false);
        assert.equal(
          error.summary,
          "Managed JETLS installation failed with status 1",
        );
        assert.ok(error.message.includes(expectedDepot));
        assert.match(error.message, /may need network access/);
        return true;
      },
    );

    // The failed process has exited, so the lock is released, and a first
    // install has no previous environment to back up.
    await assert.rejects(stat(`${expectedDepot}.lock`));
    await assert.rejects(stat(path.join(expectedDepot, "app-env-backup")));
    await assert.rejects(stat(installPendingPath(expectedDepot)));
  });
});

test("classifies a failed repair of a broken cache as a repair error", async () => {
  await withFixture(async (fixture) => {
    await createAppManifest(fixture.storagePath, fixture.juliaPath);
    const fake = fakeRunner(async (call) => {
      const script = scriptFor(call);
      if (script?.includes("Pkg.Apps.add")) {
        return failure(1, "", "could not download package sources\n");
      }
      if (script !== undefined) {
        return success("1.12.2\n");
      }
      if (isJETLSVersionCall(call)) {
        return failure(1, "", "broken installation\n");
      }
      throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
    });

    await assert.rejects(
      ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      }),
      (error: unknown) => {
        assert.ok(error instanceof ManagedJETLSError);
        assert.equal(error.retryable, true);
        assert.match(error.message, /may need network access/);
        assert.equal(
          error.summary,
          "Failed to repair the managed JETLS installation.",
        );
        return true;
      },
    );
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

test("ignores garbage collection failure after a verified install", async () => {
  await withFixture(async (fixture) => {
    const fake = standardRunner(fixture.juliaPath, {
      gcResult: failure(1, "gc stdout\n", "gc stderr\n"),
    });
    const logs: string[] = [];

    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
      logger: (message) => logs.push(message),
    });

    assert.equal(installation.juliaPath, fixture.juliaPath);
    assert.equal(callsWithScript(fake.calls, "Pkg.gc").length, 1);
    assert.ok(logs.some((message) => message.includes("gc stdout")));
    assert.ok(
      logs.some((message) =>
        message.includes("garbage collection failed and was ignored"),
      ),
    );
  });
});

test("uninstalls the managed depot for the current Julia runtime", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    await mkdir(depotPath, { recursive: true });
    await writeFile(path.join(depotPath, "state"), "managed");
    const fake = standardRunner(fixture.juliaPath);

    const confirmed: string[] = [];

    const removedPath = await uninstallManagedJETLS(
      {
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      },
      (candidate) => {
        confirmed.push(candidate);
        return true;
      },
    );

    assert.equal(removedPath, depotPath);
    // The confirmation sees the exact depot the uninstall then deletes.
    assert.deepEqual(confirmed, [depotPath]);
    await assert.rejects(stat(depotPath));
    await assert.rejects(stat(`${depotPath}.lock`));
    assert.equal(fake.calls.length, 1);
    assert.equal(scriptFor(fake.calls[0]), "print(stdout, VERSION)");
  });
});

test("a declined uninstall confirmation deletes nothing", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    await mkdir(depotPath, { recursive: true });
    await writeFile(path.join(depotPath, "state"), "managed");
    const fake = standardRunner(fixture.juliaPath);

    const removedPath = await uninstallManagedJETLS(
      {
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      },
      () => false,
    );

    assert.equal(removedPath, undefined);
    assert.equal(
      await readFile(path.join(depotPath, "state"), "utf8"),
      "managed",
    );
    await assert.rejects(stat(`${depotPath}.lock`));
  });
});

test("filesystem lock serializes concurrent ensures for the same depot", async () => {
  await withFixture(async (fixture) => {
    // The fake install leaves the manifest behind like the real one, so
    // the lock-race loser can recognize the winner's finished work.
    const fake = fakeRunner(async (call) => {
      const script = scriptFor(call);
      if (script?.includes("Pkg.Apps.add")) {
        await new Promise((resolve) => setTimeout(resolve, 150));
        await createAppManifest(fixture.storagePath, fixture.juliaPath);
        return success("installed\n");
      }
      if (script?.includes("Pkg.gc")) {
        return success();
      }
      if (script !== undefined) {
        return success("1.12.2\n");
      }
      if (isJETLSVersionCall(call)) {
        return success(
          `jetls version ${JETLS_REVISION}, julia version 1.12.2\n`,
        );
      }
      throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
    });
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
    // race finds the winner's verified installation and stamp.
    assert.equal(
      callsWithScript(fake.calls, "print(stdout, VERSION)").length,
      2,
    );
    assert.equal(callsWithScript(fake.calls, "Pkg.Apps.add").length, 1);
    assert.equal(jetlsVersionCalls(fake.calls).length, 1);
    assert.equal(callsWithScript(fake.calls, "Pkg.gc").length, 1);
  });
});

async function seedLock(
  depotPath: string,
  owner?: Record<string, unknown>,
): Promise<string> {
  const lockPath = `${depotPath}.lock`;
  await mkdir(lockPath, { recursive: true });
  if (owner !== undefined) {
    await writeFile(path.join(lockPath, "owner.json"), JSON.stringify(owner));
  }
  return lockPath;
}

test("reclaims a lock whose owner process is dead", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    await seedLock(depotPath, {
      pid: 999999999,
      createdAt: new Date().toISOString(),
    });
    const fake = standardRunner(fixture.juliaPath);

    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    assert.equal(installation.depotPath, depotPath);
    await assert.rejects(stat(`${depotPath}.lock`));
  });
});

test("reclaims an incomplete lock after the grace period", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    // A lock directory without a readable owner is a crashed acquisition;
    // it is reclaimed once its mtime has outlived the grace period.
    const lockPath = await seedLock(depotPath);
    const past = new Date(Date.now() - 60 * 1000);
    await utimes(lockPath, past, past);
    const fake = standardRunner(fixture.juliaPath);

    const installation = await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });

    assert.equal(installation.depotPath, depotPath);
    await assert.rejects(stat(`${depotPath}.lock`));
  });
});

posixOnlyTest(
  "keeps a dead host's lock while its surviving process lives",
  async () => {
    await withFixture(async (fixture) => {
      const depotPath = managedDepotPath(
        fixture.storagePath,
        fixture.juliaPath,
        "1.12.2",
      );
      // The managed process outlived its extension host: the host PID is
      // dead, but the recorded process group still runs detached.
      const survivor = spawn("sleep", ["30"], {
        detached: true,
        stdio: "ignore",
      });
      const survivorPid = survivor.pid;
      assert.ok(survivorPid !== undefined);
      try {
        const lockPath = await seedLock(depotPath, {
          pid: 999999999,
          createdAt: new Date().toISOString(),
          activeGroup: survivorPid,
        });

        assert.equal(await removeStaleLock(lockPath), false);
        await stat(lockPath);

        const exited = new Promise((resolve) => survivor.once("exit", resolve));
        process.kill(-survivorPid, "SIGKILL");
        await exited;

        assert.equal(await removeStaleLock(lockPath), true);
        await assert.rejects(stat(lockPath));
      } finally {
        try {
          process.kill(-survivorPid, "SIGKILL");
        } catch {
          // Already gone.
        }
      }
    });
  },
);

test("records the active process in the lock owner while it runs", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    const ownerPath = path.join(`${depotPath}.lock`, "owner.json");
    const fake = fakeRunner(async (call) => {
      const script = scriptFor(call);
      if (script?.includes("Pkg.Apps.add")) {
        call.options.onPid?.(7777);
        // The registration write races the (fake) process start; poll
        // briefly for it to land.
        let owner: { activeGroup?: number } = {};
        for (let attempt = 0; attempt < 100; attempt += 1) {
          try {
            owner = JSON.parse(await readFile(ownerPath, "utf8")) as {
              activeGroup?: number;
            };
            if (owner.activeGroup === 7777) {
              break;
            }
          } catch {
            // Not written yet.
          }
          await new Promise((resolve) => setTimeout(resolve, 10));
        }
        assert.equal(owner.activeGroup, 7777);
        return success("installed\n");
      }
      if (script?.includes("Pkg.gc")) {
        return success();
      }
      if (script !== undefined) {
        return success("1.12.2\n");
      }
      if (isJETLSVersionCall(call)) {
        return success(
          `jetls version ${JETLS_REVISION}, julia version 1.12.2\n`,
        );
      }
      throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
    });

    await ensureManagedJETLS({
      storagePath: fixture.storagePath,
      environment: fixture.environment,
      processRunner: fake.runner,
    });
  });
});

test("clears the completed process from the lock owner", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    const fake = fakeRunner(async (call) => {
      const script = scriptFor(call);
      if (script?.includes("Pkg.Apps.add")) {
        call.options.onPid?.(7777);
        return success("installed\n");
      }
      if (script !== undefined) {
        return success("1.12.2\n");
      }
      if (isJETLSVersionCall(call)) {
        // The post-install verification survives termination without ever
        // reporting a pid, keeping the lock with no recorded process.
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
      throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
    });

    await assert.rejects(
      ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      }),
    );

    // The installer that completed was cleared from the owner file; only
    // the host PID remains.
    const owner = JSON.parse(
      await readFile(path.join(`${depotPath}.lock`, "owner.json"), "utf8"),
    ) as { activeGroup?: number };
    assert.equal(owner.activeGroup, undefined);
  });
});

test("keeps a dead Windows host's lock until a reboot confirms the tree", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    // The recorded process is dead, but on Windows its child tree cannot
    // be confirmed dead while the system stays up.
    const lockPath = await seedLock(depotPath, {
      pid: 999999999,
      createdAt: new Date().toISOString(),
      activeGroup: 999999998,
    });

    assert.equal(await removeStaleLock(lockPath, "win32"), false);
    await stat(lockPath);

    // A record from before the current boot proves the tree is gone.
    await writeFile(
      path.join(lockPath, "owner.json"),
      JSON.stringify({
        pid: 999999999,
        createdAt: "2000-01-01T00:00:00.000Z",
        activeGroup: 999999998,
      }),
    );
    assert.equal(await removeStaleLock(lockPath, "win32"), true);
    await assert.rejects(stat(lockPath));
  });
});

test("reclaims an abandoned lock once its recorded survivor is gone", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    // The owner host (this process) is alive but has ceded the lock to a
    // survivor that is now gone.
    const lockPath = await seedLock(depotPath, {
      pid: process.pid,
      createdAt: new Date().toISOString(),
      activeGroup: 999999998,
      abandoned: true,
    });

    assert.equal(await removeStaleLock(lockPath, "linux"), true);
    await assert.rejects(stat(lockPath));
    // The steal-by-rename reclaim leaves no renamed instance behind.
    const siblings = await readdir(path.dirname(lockPath));
    assert.ok(siblings.every((entry) => !entry.includes(".reclaim-")));
  });
});

test("keeps an abandoned lock while its recorded survivor lives", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    // `activeGroup` is probed directly on win32, so the test process can
    // stand in for a live survivor; `createdAt` predates the boot so
    // only the group probe keeps the lock in force.
    const lockPath = await seedLock(depotPath, {
      pid: process.pid,
      createdAt: "2000-01-01T00:00:00.000Z",
      activeGroup: process.pid,
      abandoned: true,
    });

    assert.equal(await removeStaleLock(lockPath, "win32"), false);
    await stat(lockPath);
  });
});

test("keeps an abandoned Windows lock until a reboot confirms the survivor", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    const lockPath = await seedLock(depotPath, {
      pid: process.pid,
      createdAt: new Date().toISOString(),
      activeGroup: 999999998,
      abandoned: true,
    });

    assert.equal(await removeStaleLock(lockPath, "win32"), false);
    await stat(lockPath);

    await writeFile(
      path.join(lockPath, "owner.json"),
      JSON.stringify({
        pid: process.pid,
        createdAt: "2000-01-01T00:00:00.000Z",
        activeGroup: 999999998,
        abandoned: true,
      }),
    );
    assert.equal(await removeStaleLock(lockPath, "win32"), true);
    await assert.rejects(stat(lockPath));
  });
});

test("fails immediately with reboot guidance for an unconfirmable Windows lock", async () => {
  await withFixture(async (fixture) => {
    const depotPath = managedDepotPath(
      fixture.storagePath,
      fixture.juliaPath,
      "1.12.2",
    );
    const lockPath = await seedLock(depotPath, {
      pid: 999999999,
      createdAt: new Date().toISOString(),
      activeGroup: 999999998,
    });
    const fake = standardRunner(fixture.juliaPath);
    // Keep a regression from waiting for the full installation timeout.
    const releaseStuckLock = setTimeout(() => {
      void rm(lockPath, { recursive: true, force: true });
    }, 500);

    try {
      await assert.rejects(
        ensureManagedJETLS({
          storagePath: fixture.storagePath,
          environment: fixture.environment,
          juliaCommand: fixture.juliaPath,
          processRunner: fake.runner,
          platform: "win32",
        }),
        (error: unknown) => {
          assert.ok(error instanceof ManagedJETLSError);
          assert.equal(error.processMayBeAlive, true);
          assert.equal(error.retryable, true);
          assert.match(error.summary, /Restart Windows/);
          assert.match(error.message, /restart Windows/);
          assert.doesNotMatch(error.message, /Reinstall Server/);
          return true;
        },
      );
    } finally {
      clearTimeout(releaseStuckLock);
    }

    assert.equal(
      callsWithScript(fake.calls, "print(stdout, VERSION)").length,
      1,
    );
    assert.equal(callsWithScript(fake.calls, "Pkg.Apps.add").length, 0);
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

test("keeps the depot lock when the install process survives termination", async () => {
  await withFixture(async (fixture) => {
    const fake = fakeRunner(async (call) => {
      const script = scriptFor(call);
      if (
        call.command === fixture.juliaPath &&
        script?.includes("Pkg.Apps.add")
      ) {
        call.options.onPid?.(4321);
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
      if (call.command === fixture.juliaPath && script !== undefined) {
        return success("1.12.2\n");
      }
      throw new Error(`Unexpected process call: ${JSON.stringify(call)}`);
    });
    const depotPath = managedDepotPath(
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
        assert.match(error.message, /did not exit after termination/);
        // The recovery hint must not point at reinstall or manual
        // deletion, which would wait on or race the surviving process.
        assert.match(error.message, /end that process \(or reboot\)/);
        assert.equal(error.processMayBeAlive, true);
        return true;
      },
    );

    // The surviving installer may still write to the depot: the lock
    // stays, and its owner file still records the process registered at
    // spawn — marked abandoned, so any host (including this one on a
    // retry) reclaims the lock exactly once that process group is
    // confirmed gone.
    await stat(`${depotPath}.lock`);
    const owner = JSON.parse(
      await readFile(path.join(`${depotPath}.lock`, "owner.json"), "utf8"),
    ) as { activeGroup?: number; abandoned?: boolean };
    assert.equal(owner.activeGroup, 4321);
    assert.equal(owner.abandoned, true);
  });
});

posixOnlyTest(
  "retry reclaims the abandoned lock once the survivor is gone",
  async () => {
    await withFixture(async (fixture) => {
      const surviving = fakeRunner(async (call) => {
        const script = scriptFor(call);
        if (
          call.command === fixture.juliaPath &&
          script?.includes("Pkg.Apps.add")
        ) {
          call.options.onPid?.(999999998);
          return {
            status: null,
            stdout: "",
            stderr: "",
            error: "The process did not exit after termination.",
            processMayBeAlive: true,
          };
        }
        if (call.command === fixture.juliaPath && script !== undefined) {
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
        /did not exit after termination/,
      );

      // The recorded survivor is a dead PID, so the retry reclaims the
      // abandoned lock even though the abandoning host is this process.
      const fake = standardRunner(fixture.juliaPath);
      const installation = await ensureManagedJETLS({
        storagePath: fixture.storagePath,
        environment: fixture.environment,
        processRunner: fake.runner,
      });
      assert.equal(
        installation.depotPath,
        managedDepotPath(fixture.storagePath, fixture.juliaPath, "1.12.2"),
      );
      await assert.rejects(stat(`${installation.depotPath}.lock`));
    });
  },
);

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
