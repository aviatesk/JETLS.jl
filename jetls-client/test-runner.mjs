import { spawn } from "node:child_process";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

const rootDirectory = path.dirname(fileURLToPath(import.meta.url));
const testDirectory = path.join(rootDirectory, "test");

async function runNodeTests(testFiles) {
  return await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["--test", ...testFiles], {
      cwd: rootDirectory,
      stdio: "inherit",
    });
    child.on("error", reject);
    child.on("exit", (code, signal) => {
      if (signal !== null) {
        reject(new Error(`Node test process exited with signal ${signal}.`));
      } else {
        resolve(code ?? 1);
      }
    });
  });
}

const testNames = (await readdir(testDirectory))
  .filter((name) => name.endsWith(".test.ts"))
  .sort();
if (testNames.length === 0) {
  throw new Error(`No TypeScript tests found in ${testDirectory}.`);
}

const outputDirectory = await mkdtemp(
  path.join(tmpdir(), "jetls-client-tests-"),
);
try {
  await build({
    entryPoints: testNames.map((name) => path.join(testDirectory, name)),
    outdir: outputDirectory,
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node20",
    outExtension: { ".js": ".cjs" },
    sourcemap: "inline",
    logLevel: "silent",
  });
  const compiledTests = testNames.map((name) =>
    path.join(outputDirectory, name.replace(/\.ts$/, ".cjs")),
  );
  const exitCode = await runNodeTests(compiledTests);
  if (exitCode !== 0) {
    process.exitCode = exitCode;
  }
} finally {
  await rm(outputDirectory, { recursive: true, force: true });
}
