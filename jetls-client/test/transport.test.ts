import * as assert from "node:assert/strict";
import * as net from "node:net";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";

import { connectSocketTransport, TransportOptions } from "../src/transport";
import { FakeChildProcess, SpawnCall } from "./fake-child-process";

function createTransportContext(
  children: FakeChildProcess[],
  overrides: Partial<TransportOptions> = {},
): {
  options: TransportOptions;
  spawnCalls: SpawnCall[];
  logs: string[];
  precompilingCount: () => number;
  processErrors: Error[];
} {
  const spawnCalls: SpawnCall[] = [];
  const logs: string[] = [];
  const processErrors: Error[] = [];
  let nextChild = 0;
  let precompilingCount = 0;
  const options: TransportOptions = {
    startTimeoutMs: 1000,
    precompilationTimeoutMs: 2000,
    spawnProcess: (command, args, spawnOptions) => {
      spawnCalls.push({ command, args, options: spawnOptions });
      const child = children[nextChild++];
      assert.ok(child, `Unexpected spawn: ${command}`);
      return child.asChildProcess();
    },
    appendLine: (message) => logs.push(message),
    onPrecompiling: () => {
      precompilingCount += 1;
    },
    onProcessError: (error) => {
      processErrors.push(error);
    },
    ...overrides,
  };
  return {
    options,
    spawnCalls,
    logs,
    precompilingCount: () => precompilingCount,
    processErrors,
  };
}

function listenOnEphemeralPort(): Promise<{
  server: net.Server;
  port: number;
}> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address() as net.AddressInfo;
      resolve({ server, port: address.port });
    });
  });
}

function closeServer(server: net.Server): Promise<void> {
  return new Promise((resolve) => server.close(() => resolve()));
}

test("socket transport connects to the announced port", async () => {
  const child = new FakeChildProcess();
  const { options, spawnCalls, logs } = createTransportContext([child]);
  const { server, port } = await listenOnEphemeralPort();
  const serverSockets: net.Socket[] = [];
  server.on("connection", (socket) => serverSockets.push(socket));
  try {
    const connect = connectSocketTransport(
      "jetls",
      ["--", "serve"],
      {},
      0,
      options,
    );
    child.stdout.write(`<JETLS-PORT>${port}</JETLS-PORT>\n`);
    const streams = await connect;
    assert.equal(streams.reader, streams.writer);
    assert.deepEqual(spawnCalls, [
      {
        command: "jetls",
        args: ["--", "serve", "--socket", "0"],
        options: {},
      },
    ]);
    assert.ok(logs.includes(`[jetls-client] JETLS listening on port: ${port}`));
    streams.reader.destroy();
  } finally {
    for (const socket of serverSockets) {
      socket.destroy();
    }
    await closeServer(server);
  }
});

test("socket transport rejects when the server exits without a port", async () => {
  const child = new FakeChildProcess();
  const { options, logs } = createTransportContext([child]);

  const connect = connectSocketTransport("jetls", ["serve"], {}, 0, options);
  child.close(1, null);

  await assert.rejects(connect, /exited without providing a port number/);
  assert.ok(
    logs.includes(
      "[jetls-client] JETLS process exited (code: 1, signal: null)",
    ),
  );
});

test("socket transport times out waiting for the port announcement", async () => {
  const child = new FakeChildProcess();
  const { options } = createTransportContext([child], { startTimeoutMs: 10 });

  await assert.rejects(
    connectSocketTransport("jetls", ["serve"], {}, 0, options),
    /Timeout waiting for JETLS to provide port number/,
  );
  assert.deepEqual(child.killCalls, [undefined]);
});

test("precompilation output re-arms the startup timeout", async () => {
  const child = new FakeChildProcess();
  const { options, precompilingCount } = createTransportContext([child], {
    startTimeoutMs: 30,
    precompilationTimeoutMs: 1000,
  });
  const { server, port } = await listenOnEphemeralPort();
  const serverSockets: net.Socket[] = [];
  server.on("connection", (socket) => serverSockets.push(socket));
  try {
    const connect = connectSocketTransport("jetls", ["serve"], {}, 0, options);
    child.stderr.write("Precompiling packages...\n");
    // Outlive the original 30ms budget; only the re-armed precompilation
    // timeout keeps the connection attempt alive.
    await delay(60);
    child.stdout.write(`<JETLS-PORT>${port}</JETLS-PORT>\n`);
    const streams = await connect;
    assert.equal(precompilingCount(), 1);
    assert.deepEqual(child.killCalls, []);
    streams.reader.destroy();
  } finally {
    for (const socket of serverSockets) {
      socket.destroy();
    }
    await closeServer(server);
  }
});

test("socket transport cancels a pending connection attempt", async () => {
  const child = new FakeChildProcess();
  let cancel: (() => void) | undefined;
  const { options } = createTransportContext([child], {
    registerCancel: (callback) => {
      cancel = callback;
    },
  });

  const connect = connectSocketTransport("jetls", ["serve"], {}, 0, options);
  assert.ok(cancel);
  cancel();
  await assert.rejects(connect, /cancelled by a restart request/);
  assert.deepEqual(child.killCalls, [undefined]);
  child.close(null, "SIGTERM");
});

test("socket transport cancellation is a no-op once connected", async () => {
  const child = new FakeChildProcess();
  let cancel: (() => void) | undefined;
  const { options } = createTransportContext([child], {
    registerCancel: (callback) => {
      cancel = callback;
    },
  });
  const { server, port } = await listenOnEphemeralPort();
  const serverSockets: net.Socket[] = [];
  server.on("connection", (socket) => serverSockets.push(socket));
  try {
    const connect = connectSocketTransport("jetls", ["serve"], {}, 0, options);
    child.stdout.write(`<JETLS-PORT>${port}</JETLS-PORT>\n`);
    const streams = await connect;
    assert.ok(cancel);
    cancel();
    assert.deepEqual(child.killCalls, []);
    streams.reader.destroy();
  } finally {
    for (const socket of serverSockets) {
      socket.destroy();
    }
    await closeServer(server);
  }
});

test("socket transport surfaces connection failures", async () => {
  const child = new FakeChildProcess();
  const { options } = createTransportContext([child]);
  // Grab a port and close it again so connecting to it is refused.
  const { server, port } = await listenOnEphemeralPort();
  await closeServer(server);

  const connect = connectSocketTransport("jetls", ["serve"], {}, 0, options);
  child.stdout.write(`<JETLS-PORT>${port}</JETLS-PORT>\n`);

  await assert.rejects(connect, /ECONNREFUSED/);
  assert.deepEqual(child.killCalls, [undefined]);
});

test("socket transport reports process errors", async () => {
  const child = new FakeChildProcess();
  const { options, processErrors } = createTransportContext([child]);
  const spawnError = Object.assign(new Error("spawn ENOENT"), {
    code: "ENOENT",
  });

  const connect = connectSocketTransport("missing", ["serve"], {}, 0, options);
  child.emit("error", spawnError);

  await assert.rejects(connect, (error) => error === spawnError);
  assert.deepEqual(processErrors, [spawnError]);
});
