import * as assert from "node:assert/strict";
import { test } from "node:test";

import { CoalescingTaskRunner } from "../src/coalescing-task-runner";

function deferred(): {
  promise: Promise<void>;
  resolve: () => void;
} {
  let resolve!: () => void;
  const promise = new Promise<void>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

test("runs a task once", async () => {
  let runCount = 0;
  const runner = new CoalescingTaskRunner(async () => {
    runCount += 1;
  });

  await runner.run();

  assert.equal(runCount, 1);
});

test("coalesces requests while serializing task runs", async () => {
  const events: string[] = [];
  const releaseFirstRun = deferred();
  const firstRunStarted = deferred();
  let runCount = 0;
  const runner = new CoalescingTaskRunner(async () => {
    runCount += 1;
    events.push(`start ${runCount}`);
    if (runCount === 1) {
      firstRunStarted.resolve();
      await releaseFirstRun.promise;
    }
    events.push(`end ${runCount}`);
  });

  const activeRun = runner.run();
  await firstRunStarted.promise;
  const requestedRuns = [runner.run(), runner.run(), runner.run()];
  releaseFirstRun.resolve();
  await Promise.all([activeRun, ...requestedRuns]);

  assert.deepEqual(events, ["start 1", "end 1", "start 2", "end 2"]);
});

test("runs a pending task after the active task fails", async () => {
  const expectedError = new Error("task failed");
  const releaseFirstRun = deferred();
  const firstRunStarted = deferred();
  let runCount = 0;
  const runner = new CoalescingTaskRunner(async () => {
    runCount += 1;
    if (runCount === 1) {
      firstRunStarted.resolve();
      await releaseFirstRun.promise;
      throw expectedError;
    }
  });

  const activeRun = runner.run();
  await firstRunStarted.promise;
  const pendingRun = runner.run();
  releaseFirstRun.resolve();
  await Promise.all([activeRun, pendingRun]);

  assert.equal(runCount, 2);
});

test("exposes the active run until it settles", async () => {
  const release = deferred();
  const runner = new CoalescingTaskRunner(() => release.promise);

  assert.equal(runner.active, undefined);
  const run = runner.run();
  assert.equal(runner.active, run);
  release.resolve();
  await run;
  assert.equal(runner.active, undefined);
});

test("recovers after a failed task", async () => {
  const expectedError = new Error("task failed");
  let runCount = 0;
  const runner = new CoalescingTaskRunner(async () => {
    runCount += 1;
    if (runCount === 1) {
      throw expectedError;
    }
  });

  await assert.rejects(runner.run(), expectedError);
  await runner.run();

  assert.equal(runCount, 2);
});
