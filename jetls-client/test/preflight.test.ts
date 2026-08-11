import * as assert from "node:assert/strict";
import { test } from "node:test";

import {
  createStderrWatcher,
  resolveJETLSCommands,
  VersionPreflight,
  VersionPreflightOptions,
} from "../src/preflight";
import { FakeChildProcess, SpawnCall } from "./fake-child-process";

function createPreflight(
  children: FakeChildProcess[],
  options: Partial<VersionPreflightOptions> = {},
): {
  preflight: VersionPreflight;
  spawnCalls: SpawnCall[];
  groupKills: [number, NodeJS.Signals][];
  logs: string[];
  precompilationCount: () => number;
} {
  const spawnCalls: SpawnCall[] = [];
  const groupKills: [number, NodeJS.Signals][] = [];
  const logs: string[] = [];
  const spawned: FakeChildProcess[] = [];
  let nextChild = 0;
  let precompilationCount = 0;
  const preflight = new VersionPreflight({
    timeoutMs: 1000,
    terminationTimeoutMs: 20,
    platform: "darwin",
    spawnProcess: (command, args, spawnOptions) => {
      spawnCalls.push({ command, args, options: spawnOptions });
      const child = children[nextChild++];
      assert.ok(child, `Unexpected spawn: ${command}`);
      spawned.push(child);
      return child.asChildProcess();
    },
    // The default group probe and kill would touch real process groups;
    // fake a group that dies with its leader and route signals to the
    // fake child instead.
    isProcessGroupAlive: () => false,
    killProcessGroup: (pid, signal) => {
      groupKills.push([pid, signal]);
      for (let index = spawned.length - 1; index >= 0; index -= 1) {
        if (spawned[index].pid === pid) {
          spawned[index].kill(signal);
          break;
        }
      }
    },
    appendLine: (message) => logs.push(message),
    onPrecompiling: () => {
      precompilationCount += 1;
    },
    ...options,
  });
  return {
    preflight,
    spawnCalls,
    groupKills,
    logs,
    precompilationCount: () => precompilationCount,
  };
}

test("resolves installed and development commands", () => {
  assert.deepEqual(resolveJETLSCommands({}), {
    command: "jetls",
    versionArgs: ["--threads=auto", "--", "version"],
    serveArgs: ["--threads=auto", "--", "serve"],
  });
  assert.deepEqual(
    resolveJETLSCommands({ path: "/opt/julia/bin/jetls", threads: "4" }),
    {
      command: "/opt/julia/bin/jetls",
      versionArgs: ["--threads=4", "--", "version"],
      serveArgs: ["--threads=4", "--", "serve"],
    },
  );

  const executable = [
    "julia",
    "--startup-file=no",
    "--project=/checkout",
    "-m",
    "JETLS",
    "serve",
  ];
  assert.deepEqual(resolveJETLSCommands(executable), {
    command: "julia",
    versionArgs: [
      "--startup-file=no",
      "--project=/checkout",
      "-m",
      "JETLS",
      "version",
    ],
    serveArgs: [
      "--startup-file=no",
      "--project=/checkout",
      "-m",
      "JETLS",
      "serve",
    ],
  });
  assert.deepEqual(executable, [
    "julia",
    "--startup-file=no",
    "--project=/checkout",
    "-m",
    "JETLS",
    "serve",
  ]);

  assert.throws(
    () => resolveJETLSCommands(["julia", "-m", "JETLS"]),
    /expected exactly one `serve` subcommand/,
  );
  assert.throws(
    () => resolveJETLSCommands(["jetls", "serve", "serve"]),
    /expected exactly one `serve` subcommand/,
  );
});

test("runs a successful version preflight", async () => {
  const child = new FakeChildProcess();
  const { preflight, spawnCalls, logs } = createPreflight([child]);

  const run = preflight.run("jetls", ["--", "version"], { shell: true });
  child.stdout.write("JETLS version 1.0\n");
  child.close(0, null);
  await run;

  assert.deepEqual(spawnCalls, [
    {
      command: "jetls",
      args: ["--", "version"],
      options: { shell: true, detached: true },
    },
  ]);
  assert.ok(
    logs.includes(
      "[jetls-client] JETLS version check stdout:\nJETLS version 1.0",
    ),
  );
});

test("preserves spawn errors", async () => {
  const child = new FakeChildProcess();
  const { preflight } = createPreflight([child]);
  const expectedError = Object.assign(new Error("spawn failed"), {
    code: "ENOENT",
  });

  const run = preflight.run("missing-jetls", ["version"], {});
  child.emit("error", expectedError);
  child.close(-2, null);

  await assert.rejects(run, (error) => error === expectedError);
});

test("reports nonzero and signal exits", async () => {
  const failedChild = new FakeChildProcess();
  const { preflight: failedPreflight } = createPreflight([failedChild]);
  const failedRun = failedPreflight.run("jetls", ["version"], {});
  failedChild.close(2, null);
  await assert.rejects(failedRun, /JETLS version check exited with code 2\./);

  const signaledChild = new FakeChildProcess();
  const { preflight: signaledPreflight } = createPreflight([signaledChild]);
  const signaledRun = signaledPreflight.run("jetls", ["version"], {});
  signaledChild.close(null, "SIGTERM");
  await assert.rejects(
    signaledRun,
    /JETLS version check exited with signal SIGTERM\./,
  );
});

test("detects split precompilation output once", async () => {
  const child = new FakeChildProcess();
  const { preflight, precompilationCount } = createPreflight([child]);

  const run = preflight.run("jetls", ["version"], {});
  child.stderr.write("Precompiling pack");
  child.stderr.write("ages\nPrecompiling packages\n");
  child.close(0, null);
  await run;

  assert.equal(precompilationCount(), 1);
});

test("stderr watcher logs lines and detects a split marker once", () => {
  const logs: string[] = [];
  let precompilingCount = 0;
  const watch = createStderrWatcher({
    logPrefix: "[test-stderr]",
    appendLine: (message) => logs.push(message),
    onPrecompiling: () => {
      precompilingCount += 1;
    },
  });

  watch(Buffer.from("Info: loading\nPrecompiling pack"));
  watch(Buffer.from("ages\n"));
  watch(Buffer.from("Precompiling packages\n"));

  assert.equal(precompilingCount, 1);
  assert.deepEqual(logs.slice(0, 2), [
    "[test-stderr] Info: loading",
    "[test-stderr] Precompiling pack",
  ]);
});

test("terminates a timed-out preflight before rejecting", async () => {
  const child = new FakeChildProcess();
  child.onKill = () => queueMicrotask(() => child.close(null, "SIGTERM"));
  const { preflight, spawnCalls, groupKills } = createPreflight([child], {
    timeoutMs: 10,
  });

  await assert.rejects(
    preflight.run("jetls", ["version"], {}),
    /JETLS version check timed out after 0\.01 seconds\./,
  );
  // Spawned detached (own process group), terminated via a group signal.
  assert.equal(spawnCalls[0].options.detached, true);
  assert.deepEqual(groupKills, [[1234, "SIGTERM"]]);
  assert.deepEqual(child.killCalls, ["SIGTERM"]);
});

test("shares termination and escalates a stubborn POSIX process", async () => {
  const child = new FakeChildProcess();
  child.onKill = (signal) => {
    if (signal === "SIGKILL") {
      queueMicrotask(() => child.close(null, "SIGKILL"));
    }
  };
  const { preflight } = createPreflight([child], {
    terminationTimeoutMs: 5,
  });

  const run = preflight.run("jetls", ["version"], {});
  const firstTermination = preflight.terminate();
  const secondTermination = preflight.terminate();
  assert.equal(firstTermination, secondTermination);
  await firstTermination;
  await assert.rejects(run, /JETLS version check exited with signal SIGKILL\./);
  assert.deepEqual(child.killCalls, ["SIGTERM", "SIGKILL"]);
});

test("recovers after a failed termination", async () => {
  const stubbornChild = new FakeChildProcess();
  const replacementChild = new FakeChildProcess();
  const { preflight } = createPreflight([stubbornChild, replacementChild], {
    terminationTimeoutMs: 5,
  });

  const run = preflight.run("jetls", ["version"], {});
  await assert.rejects(preflight.terminate(), /did not exit after termination/);
  assert.deepEqual(stubbornChild.killCalls, ["SIGTERM", "SIGKILL"]);

  const rerun = preflight.run("jetls", ["version"], {});
  replacementChild.stdout.write("JETLS version 1.0\n");
  replacementChild.close(0, null);
  await rerun;

  stubbornChild.close(null, "SIGTERM");
  await assert.rejects(run, /JETLS version check exited with signal SIGTERM\./);
});

test("uses taskkill to terminate a Windows preflight", async () => {
  const versionChild = new FakeChildProcess();
  versionChild.pid = 4321;
  const taskkillChild = new FakeChildProcess();
  const { preflight, spawnCalls } = createPreflight(
    [versionChild, taskkillChild],
    { platform: "win32" },
  );

  const run = preflight.run("jetls.bat", ["version"], { shell: true });
  const termination = preflight.terminate();
  assert.deepEqual(spawnCalls[1], {
    command: "taskkill",
    args: ["/PID", "4321", "/T", "/F"],
    options: { stdio: "ignore", windowsHide: true },
  });
  taskkillChild.close(0, null);
  versionChild.close(null, "SIGTERM");
  await termination;
  await assert.rejects(run, /JETLS version check exited with signal SIGTERM\./);
  assert.deepEqual(versionChild.killCalls, []);
});

test("falls back to kill() when taskkill fails", async () => {
  const versionChild = new FakeChildProcess();
  versionChild.pid = 4321;
  versionChild.onKill = () =>
    queueMicrotask(() => versionChild.close(null, "SIGTERM"));
  const taskkillChild = new FakeChildProcess();
  const { preflight } = createPreflight([versionChild, taskkillChild], {
    platform: "win32",
  });

  const run = preflight.run("jetls.bat", ["version"], { shell: true });
  const termination = preflight.terminate();
  taskkillChild.close(1, null);
  // The fallback kill() cannot confirm the child tree, so the termination
  // reports survival even though the direct process closed.
  await assert.rejects(
    termination,
    /did not exit after termination\. taskkill exited with code 1\./,
  );
  assert.deepEqual(versionChild.killCalls, [undefined]);
  await assert.rejects(run, /JETLS version check exited with signal SIGTERM\./);
});
