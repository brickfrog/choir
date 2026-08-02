import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import test from "node:test";

import {
  assuranceTools,
  BoundedLineFramer,
  parseLaunchArgs,
  relativePath,
  runSandboxMcpBridge,
  SANDBOX_MCP_LIMITS,
  SANDBOX_MCP_RESOURCE_ERROR,
  SandboxCallQueue,
  tools,
  toolsForAccess,
  validateArgv,
} from "./choir_sandbox_mcp.mjs";
import {
  deriveExecutionToken,
  parseOwnerLaunchArgs,
  reachableOnlyByOwner,
  validateOwnerRequest,
} from "./choir_boxlite_owner.mjs";

const launchArgs = [
  "--owner-socket", "/tmp/take/owner.sock",
  "--box", "box-1",
  "--access", "mutable",
];

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function toolCall(id, padding = "") {
  return `${JSON.stringify({
    jsonrpc: "2.0",
    id,
    method: "tools/call",
    params: { name: "slow", arguments: { id, padding } },
  })}\n`;
}

function fakeClient(onClose = () => {}) {
  return {
    config: { access: "mutable" },
    close: onClose,
    drain: async () => {},
  };
}

test("launch arguments admit only the fixed local shape", () => {
  process.env.CHOIR_BOXLITE_EXECUTION_TOKEN = "a".repeat(64);
  assert.equal(parseLaunchArgs(launchArgs).box, "box-1");
  assert.equal(parseLaunchArgs(launchArgs).access, "mutable");
  const relative = launchArgs.slice();
  relative[1] = "owner.sock";
  assert.throws(() => parseLaunchArgs(relative));
  assert.throws(() => parseLaunchArgs([...launchArgs, "--extra", "value"]));
  const invalidAccess = launchArgs.slice();
  invalidAccess[invalidAccess.length - 1] = "broad";
  assert.throws(() => parseLaunchArgs(invalidAccess));
});

test("the execution token is read from the environment, never from argv", () => {
  process.env.CHOIR_BOXLITE_EXECUTION_TOKEN = "b".repeat(64);
  assert.equal(parseLaunchArgs(launchArgs).ownerToken, "b".repeat(64));
  // No argv fallback: one would keep the leak alive for any caller that had
  // not been updated, which is exactly the situation being removed.
  assert.throws(() =>
    parseLaunchArgs([...launchArgs, "--owner-token", "c".repeat(64)])
  );
  delete process.env.CHOIR_BOXLITE_EXECUTION_TOKEN;
  assert.throws(() => parseLaunchArgs(launchArgs));
  process.env.CHOIR_BOXLITE_EXECUTION_TOKEN = "d".repeat(63) + "Z";
  assert.throws(() => parseLaunchArgs(launchArgs));
  process.env.CHOIR_BOXLITE_EXECUTION_TOKEN = "a".repeat(64);
});

test("runtime owner admits only exact bounded guest execution", () => {
  const config = parseOwnerLaunchArgs([
    "--socket", "/tmp/owner.sock",
    "--binary", "/opt/boxlite",
    "--runtime-dir", "/opt/runtime",
    "--home", "/tmp/boxlite",
    "--url", "http://127.0.0.1:22000",
  ]);
  assert.equal(config.socket, "/tmp/owner.sock");
  const request = {
    operation: "exec",
    token: "b".repeat(64),
    box: "box-1",
    access: "mutable",
    cwd: "src",
    timeout_ms: 30000,
    argv: ["/bin/echo", "ok"],
  };
  assert.deepEqual(validateOwnerRequest(request).argv, ["/bin/echo", "ok"]);
  const secret = "c".repeat(64);
  const token = deriveExecutionToken(secret, "box-1", "mutable");
  assert.match(token, /^[a-f0-9]{64}$/);
  assert.notEqual(token, deriveExecutionToken(secret, "box-2", "mutable"));
  assert.notEqual(token, deriveExecutionToken(secret, "box-1", "read-only-subject"));
  assert.throws(() => validateOwnerRequest({ ...request, operation: "clone" }));
  assert.throws(() => validateOwnerRequest({ ...request, cwd: "../host" }));
  assert.throws(() => validateOwnerRequest({ ...request, argv: ["sh", "-c", "true"] }));
  assert.throws(() => validateOwnerRequest({ ...request, extra: true }));
});

test("the owner socket is served only when no other user can reach it", () => {
  const socket = 0o140000;
  assert.equal(reachableOnlyByOwner({ uid: 1000, mode: socket | 0o600 }, 1000), true);
  assert.equal(reachableOnlyByOwner({ uid: 1000, mode: socket | 0o660 }, 1000), false);
  assert.equal(reachableOnlyByOwner({ uid: 1000, mode: socket | 0o606 }, 1000), false);
  assert.equal(reachableOnlyByOwner({ uid: 1000, mode: socket | 0o755 }, 1000), false);
  assert.equal(reachableOnlyByOwner({ uid: 1001, mode: socket | 0o600 }, 1000), false);
  assert.equal(reachableOnlyByOwner({ uid: 0, mode: socket | 0o600 }, 1000), false);
});

test("framing accepts 512 KiB and rejects one byte more", () => {
  const exact = new BoundedLineFramer();
  const exactFrames = exact.push(Buffer.concat([
    Buffer.alloc(SANDBOX_MCP_LIMITS.frameBytes, 0x78),
    Buffer.from("\n"),
  ]));
  assert.equal(exactFrames.length, 1);
  assert.equal(exactFrames[0].oversized, false);
  assert.equal(exactFrames[0].bytes, SANDBOX_MCP_LIMITS.frameBytes);

  const over = new BoundedLineFramer();
  const overFrames = over.push(Buffer.concat([
    Buffer.alloc(SANDBOX_MCP_LIMITS.frameBytes + 1, 0x78),
    Buffer.from("\n"),
  ]));
  assert.equal(overFrames.length, 1);
  assert.equal(overFrames[0].oversized, true);
});

test("framing stays bounded across chunks and recovers after an oversized frame", () => {
  const framer = new BoundedLineFramer(8);
  assert.deepEqual(framer.push("1234"), []);
  assert.equal(framer.push("5678\n")[0].text, "12345678");
  assert.equal(framer.push("123456789")[0], undefined);
  const recovered = framer.push("\nok\n");
  assert.equal(recovered[0].oversized, true);
  assert.equal(recovered[1].text, "ok");
});

test("the serialized call queue admits 16 waiting calls and recovers", async () => {
  const first = deferred();
  let capacitySignals = 0;
  const queue = new SandboxCallQueue(() => { capacitySignals += 1; });
  const active = queue.enqueue(1, () => first.promise);
  assert.equal(active.admitted, true);
  const waiting = [];
  for (let index = 0; index < SANDBOX_MCP_LIMITS.queuedCalls; index += 1) {
    waiting.push(queue.enqueue(1, async () => index));
  }
  assert.equal(queue.queuedCalls, 16);
  assert.equal(waiting.every((entry) => entry.admitted), true);
  assert.equal(waiting.at(-1).atHighWater, true);
  assert.deepEqual(queue.enqueue(1, async () => -1), {
    admitted: false,
    reason: "capacity",
  });

  first.resolve("first");
  await new Promise((resolve) => setImmediate(resolve));
  const refill = queue.enqueue(1, async () => "refill");
  assert.equal(refill.admitted, true);
  await queue.drain();
  assert.equal(queue.queuedCalls, 0);
  assert.equal(queue.queuedBytes, 0);
  assert.equal(capacitySignals >= 1, true);
});

test("the serialized call queue admits exactly 4 MiB of waiting frames", async () => {
  const first = deferred();
  const queue = new SandboxCallQueue();
  queue.enqueue(1, () => first.promise);
  const frameBytes = SANDBOX_MCP_LIMITS.frameBytes;
  const entries = [];
  for (let index = 0; index < 8; index += 1) {
    entries.push(queue.enqueue(frameBytes, async () => index));
  }
  assert.equal(entries.every((entry) => entry.admitted), true);
  assert.equal(queue.queuedBytes, SANDBOX_MCP_LIMITS.queuedBytes);
  assert.deepEqual(queue.enqueue(1, async () => -1), {
    admitted: false,
    reason: "capacity",
  });
  first.resolve("first");
  await queue.drain();
  assert.equal(queue.queuedBytes, 0);
});

test("slow calls pause stdin, reject the hard-limit overrun, and resume", async () => {
  const input = new PassThrough();
  const first = deferred();
  const output = [];
  const started = [];
  let exited = 0;
  const bridge = runSandboxMcpBridge({
    client: fakeClient(),
    visibleTools: [],
    input,
    write: (message) => output.push(message),
    exit: () => { exited += 1; },
    dispatchTool: async (_client, _name, args) => {
      started.push(args.id);
      if (args.id === 1) return first.promise;
      return { content: [{ type: "text", text: `done:${args.id}` }] };
    },
  });
  input.write(Array.from({ length: 18 }, (_, index) => toolCall(index + 1)).join(""));
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(started, [1]);
  assert.equal(bridge.scheduler.queuedCalls, 16);
  assert.equal(input.isPaused(), true);
  const hardLimit = output.map((line) => JSON.parse(line)).find((message) => message.id === 18);
  assert.deepEqual(hardLimit?.error, {
    code: SANDBOX_MCP_RESOURCE_ERROR.code,
    message: SANDBOX_MCP_RESOURCE_ERROR.queueMessage,
  });

  first.resolve({ content: [{ type: "text", text: "done:1" }] });
  await bridge.scheduler.drain();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(input.isPaused(), false);
  assert.equal(bridge.scheduler.queuedCalls, 0);
  assert.equal(bridge.scheduler.queuedBytes, 0);
  await bridge.shutdown(false);
  assert.equal(exited, 1);
});

test("oversized input receives a deterministic JSON-RPC resource error", async () => {
  const input = new PassThrough();
  const output = [];
  const bridge = runSandboxMcpBridge({
    client: fakeClient(),
    visibleTools: [],
    input,
    write: (message) => output.push(message),
    exit: () => {},
  });
  input.write(Buffer.concat([
    Buffer.alloc(SANDBOX_MCP_LIMITS.frameBytes + 1, 0x78),
    Buffer.from("\n"),
  ]));
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(JSON.parse(output[0]), {
    jsonrpc: "2.0",
    id: null,
    error: {
      code: SANDBOX_MCP_RESOURCE_ERROR.code,
      message: SANDBOX_MCP_RESOURCE_ERROR.frameMessage,
    },
  });
  await bridge.shutdown(false);
});

test("graceful shutdown drains serialized calls before exit", async () => {
  const input = new PassThrough();
  const gates = new Map([[1, deferred()], [2, deferred()]]);
  const started = [];
  let closes = 0;
  let exits = 0;
  const bridge = runSandboxMcpBridge({
    client: fakeClient(() => { closes += 1; }),
    visibleTools: [],
    input,
    write: () => {},
    exit: () => { exits += 1; },
    dispatchTool: async (_client, _name, args) => {
      started.push(args.id);
      return gates.get(args.id).promise;
    },
  });
  input.write(
    toolCall(1) +
    toolCall(2) +
    `${JSON.stringify({ jsonrpc: "2.0", method: "notifications/exit", params: {} })}\n`,
  );
  const shutdown = bridge.shutdown(true);
  await Promise.resolve();
  assert.deepEqual(started, [1]);
  assert.equal(exits, 0);
  gates.get(1).resolve({ content: [] });
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(started, [1, 2]);
  gates.get(2).resolve({ content: [] });
  await shutdown;
  assert.equal(closes, 0);
  assert.equal(exits, 1);
});

test("stdin shutdown cancels queued calls and the active client", async () => {
  const input = new PassThrough();
  const active = deferred();
  const exited = deferred();
  const started = [];
  let closes = 0;
  const bridge = runSandboxMcpBridge({
    client: fakeClient(() => {
      closes += 1;
      active.resolve({ content: [] });
    }),
    visibleTools: [],
    input,
    write: () => {},
    exit: (code) => exited.resolve(code),
    dispatchTool: async (_client, _name, args) => {
      started.push(args.id);
      return active.promise;
    },
  });
  input.end(toolCall(1) + toolCall(2) + toolCall(3));
  assert.equal(await exited.promise, 0);
  assert.deepEqual(started, [1]);
  assert.equal(closes, 1);
  assert.equal(bridge.scheduler.queuedCalls, 0);
  assert.equal(bridge.scheduler.queuedBytes, 0);
});

test("workspace paths reject aliases and escapes", () => {
  assert.equal(relativePath("src/main.mbt"), "src/main.mbt");
  assert.throws(() => relativePath("../secret"));
  assert.throws(() => relativePath("src//main.mbt"));
  assert.throws(() => relativePath("/etc/passwd"));
  assert.throws(() => relativePath(""));
  assert.equal(relativePath("", true), "");
});

test("guest execution requires bounded absolute argv", () => {
  assert.deepEqual(validateArgv(["/bin/sh", "-c", "true"]), ["/bin/sh", "-c", "true"]);
  assert.throws(() => validateArgv(["sh", "-c", "true"]));
  assert.throws(() => validateArgv([]));
  assert.throws(() => validateArgv(["/bin/echo", "bad\0arg"]));
});

test("tool declaration is fixed and unique", () => {
  assert.deepEqual(tools.map((tool) => tool.name), [
    "read_file",
    "list_files",
    "write_file",
    "replace_text",
    "run",
  ]);
  assert.equal(new Set(tools.map((tool) => tool.name)).size, tools.length);
  assert.deepEqual(assuranceTools.map((tool) => tool.name), [
    "read_file",
    "list_files",
    "write_scratch",
    "write_output",
  ]);
  assert.equal(
    new Set(assuranceTools.map((tool) => tool.name)).size,
    assuranceTools.length,
  );
  assert.equal(toolsForAccess("mutable"), tools);
  assert.equal(toolsForAccess("read-only-subject"), assuranceTools);
  assert.throws(() => toolsForAccess("unknown"));
});
