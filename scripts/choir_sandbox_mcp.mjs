import net from "node:net";
import { pathToFileURL } from "node:url";

const MAX_TEXT_BYTES = 1024 * 1024;
const MAX_WRITE_BYTES = 256 * 1024;
const MAX_ARG_COUNT = 96;
const MAX_ARG_BYTES = 64 * 1024;

export const SANDBOX_MCP_LIMITS = Object.freeze({
  frameBytes: 512 * 1024,
  queuedCalls: 16,
  queuedBytes: 4 * 1024 * 1024,
});

export const SANDBOX_MCP_RESOURCE_ERROR = Object.freeze({
  code: -32001,
  queueMessage: "sandbox MCP request queue capacity exceeded",
  frameMessage: "sandbox MCP request frame exceeds byte limit",
});

function fail(message) {
  throw new Error(`sandbox bridge: ${message}`);
}

export function parseLaunchArgs(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined || values.has(key)) {
      fail("invalid launch arguments");
    }
    values.set(key, value);
  }
  const required = ["--owner-socket", "--box", "--access"];
  if (values.size !== required.length) fail("unknown launch argument");
  for (const key of required) {
    if (!values.get(key)) fail(`missing ${key}`);
  }
  if (!values.get("--owner-socket").startsWith("/")) {
    fail("owner socket must be absolute");
  }
  // The execution token arrives in the environment, never on argv.
  // /proc/<pid>/cmdline is world-readable; /proc/<pid>/environ is 0400. This
  // token is a bearer capability that authorizes exec inside the box and the
  // owner socket authenticates on possession alone, so putting it on a command
  // line published it to every process that could list the process table.
  const ownerToken = process.env.CHOIR_BOXLITE_EXECUTION_TOKEN ?? "";
  if (!/^[a-f0-9]{64}$/.test(ownerToken)) {
    fail("owner capability is invalid");
  }
  if (!/^[a-zA-Z0-9-]{1,180}$/.test(values.get("--box"))) {
    fail("invalid box identity");
  }
  if (!["mutable", "read-only-subject"].includes(values.get("--access"))) {
    fail("invalid workspace access");
  }
  return Object.freeze({
    ownerSocket: values.get("--owner-socket"),
    ownerToken,
    box: values.get("--box"),
    access: values.get("--access"),
  });
}

export function relativePath(value, allowRoot = false) {
  if (typeof value !== "string" || value.includes("\0") || value.includes("\\")) {
    fail("invalid workspace path");
  }
  const trimmed = value.replace(/^\.\//, "").replace(/\/$/, "");
  if ((!allowRoot && trimmed === "") || trimmed.startsWith("/")) {
    fail("workspace path must be relative");
  }
  const parts = trimmed === "" ? [] : trimmed.split("/");
  if (parts.some((part) => part === "" || part === "." || part === "..")) {
    fail("workspace path is not normalized");
  }
  return parts.join("/");
}

function guestPath(value, allowRoot = false) {
  const relative = relativePath(value, allowRoot);
  return relative === "" ? "/workspace" : `/workspace/${relative}`;
}

function scopedGuestPath(root, value, allowRoot = false) {
  const relative = relativePath(value, allowRoot);
  return relative === "" ? root : `${root}/${relative}`;
}

export function validateArgv(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > MAX_ARG_COUNT) {
    fail("argv is empty or too large");
  }
  let bytes = 0;
  for (const item of value) {
    if (typeof item !== "string" || item === "" || item.includes("\0")) {
      fail("argv contains an invalid item");
    }
    bytes += Buffer.byteLength(item);
  }
  if (bytes > MAX_ARG_BYTES || !value[0].startsWith("/")) {
    fail("argv exceeds its bound or lacks an absolute executable");
  }
  return value;
}

function ownerExec(config, argv, cwd, timeoutMs, signal) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(config.ownerSocket);
    let output = "";
    const abort = () => socket.destroy(new Error("execution interrupted"));
    signal.addEventListener("abort", abort, { once: true });
    socket.setTimeout(timeoutMs + 5000, () => socket.destroy(new Error("owner timed out")));
    socket.on("connect", () => {
      socket.write(`${JSON.stringify({
        operation: "exec",
        token: config.ownerToken,
        box: config.box,
        access: config.access,
        cwd,
        timeout_ms: timeoutMs,
        argv,
      })}\n`);
    });
    socket.on("data", (chunk) => {
      output += chunk.toString("utf8");
      if (Buffer.byteLength(output) > MAX_TEXT_BYTES) {
        socket.destroy(new Error("owner response exceeded its bound"));
      }
    });
    socket.on("error", reject);
    socket.on("end", () => {
      signal.removeEventListener("abort", abort);
      try {
        const response = JSON.parse(output.trim());
        if (!response?.ok) fail(response?.error ?? "owner rejected execution");
        if (!Number.isInteger(response.exit_code) ||
          typeof response.stdout !== "string" ||
          typeof response.stderr !== "string") {
          fail("owner response is malformed");
        }
        resolve({
          exitCode: response.exit_code,
          stdout: response.stdout,
          stderr: response.stderr,
        });
      } catch (error) {
        reject(error);
      }
    });
  });
}

export class BoundedLineFramer {
  constructor(maxFrameBytes = SANDBOX_MCP_LIMITS.frameBytes) {
    if (!Number.isInteger(maxFrameBytes) || maxFrameBytes <= 0) {
      fail("frame byte limit is invalid");
    }
    this.maxFrameBytes = maxFrameBytes;
    this.buffer = Buffer.allocUnsafe(maxFrameBytes);
    this.bytes = 0;
    this.oversized = false;
  }

  push(value) {
    const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
    const frames = [];
    let offset = 0;
    while (offset < chunk.length) {
      const newline = chunk.indexOf(0x0a, offset);
      if (newline < 0) {
        this.append(chunk.subarray(offset));
        break;
      }
      this.append(chunk.subarray(offset, newline));
      frames.push(this.finishFrame());
      offset = newline + 1;
    }
    return frames;
  }

  end() {
    if (!this.oversized && this.bytes === 0) return [];
    return [this.finishFrame()];
  }

  append(part) {
    if (this.oversized || part.length === 0) return;
    if (part.length > this.maxFrameBytes - this.bytes) {
      this.bytes = 0;
      this.oversized = true;
      return;
    }
    part.copy(this.buffer, this.bytes);
    this.bytes += part.length;
  }

  finishFrame() {
    let frame;
    if (this.oversized) {
      frame = Object.freeze({ oversized: true, bytes: this.maxFrameBytes + 1, text: "" });
    } else {
      const raw = this.buffer.subarray(0, this.bytes);
      const body = raw.length > 0 && raw[raw.length - 1] === 0x0d
        ? raw.subarray(0, raw.length - 1)
        : raw;
      frame = Object.freeze({ oversized: false, bytes: this.bytes, text: body.toString("utf8") });
    }
    this.bytes = 0;
    this.oversized = false;
    return frame;
  }
}

export class SandboxCallQueue {
  constructor(onCapacity = () => {}) {
    this.onCapacity = onCapacity;
    this.waiting = [];
    this.waitingBytes = 0;
    this.active = null;
    this.closed = false;
    this.pressured = false;
    this.drainWaiters = [];
  }

  get queuedCalls() {
    return this.waiting.length;
  }

  get queuedBytes() {
    return this.waitingBytes;
  }

  get atHighWater() {
    return this.waiting.length >= SANDBOX_MCP_LIMITS.queuedCalls ||
      this.waitingBytes >= SANDBOX_MCP_LIMITS.queuedBytes;
  }

  enqueue(bytes, operation) {
    if (!Number.isInteger(bytes) || bytes < 0 || typeof operation !== "function") {
      fail("queued call is invalid");
    }
    if (this.closed) {
      return Object.freeze({ admitted: false, reason: "closed" });
    }
    if (this.active !== null &&
      (this.waiting.length >= SANDBOX_MCP_LIMITS.queuedCalls ||
        bytes > SANDBOX_MCP_LIMITS.queuedBytes - this.waitingBytes)) {
      this.pressured = true;
      return Object.freeze({ admitted: false, reason: "capacity" });
    }
    let resolve;
    let reject;
    const promise = new Promise((resolveEntry, rejectEntry) => {
      resolve = resolveEntry;
      reject = rejectEntry;
    });
    const entry = { bytes, operation, promise, resolve, reject };
    if (this.active === null) {
      this.start(entry);
    } else {
      this.waiting.push(entry);
      this.waitingBytes += bytes;
      this.updatePressure();
    }
    return Object.freeze({
      admitted: true,
      promise,
      atHighWater: this.atHighWater,
    });
  }

  start(entry) {
    this.active = entry;
    Promise.resolve()
      .then(entry.operation)
      .then(entry.resolve, entry.reject)
      .finally(() => this.finish(entry));
  }

  finish(entry) {
    if (this.active !== entry) return;
    this.active = null;
    const next = this.waiting.shift();
    if (next) {
      this.waitingBytes -= next.bytes;
      this.start(next);
    }
    this.updatePressure();
    this.settleDrain();
  }

  updatePressure() {
    const pressured = this.atHighWater;
    if (this.pressured && !pressured) this.onCapacity();
    this.pressured = pressured;
  }

  close(cancelQueued = false) {
    this.closed = true;
    if (cancelQueued) {
      const error = new Error("sandbox bridge: queued call canceled");
      for (const entry of this.waiting) entry.reject(error);
      this.waiting = [];
      this.waitingBytes = 0;
      this.updatePressure();
      this.settleDrain();
    }
  }

  drain() {
    if (this.active === null && this.waiting.length === 0) return Promise.resolve();
    return new Promise((resolve) => this.drainWaiters.push(resolve));
  }

  settleDrain() {
    if (this.active !== null || this.waiting.length !== 0) return;
    for (const resolve of this.drainWaiters.splice(0)) resolve();
  }
}

class SandboxClient {
  constructor(config) {
    this.config = config;
    this.queue = Promise.resolve();
    this.controllers = new Set();
    this.closed = false;
  }

  close() {
    this.closed = true;
    for (const controller of this.controllers) controller.abort();
  }

  drain() {
    return this.queue;
  }

  run(argv, cwd = "", timeoutMs = 120000) {
    const operation = async () => {
      if (this.closed) fail("bridge is closed");
      const command = validateArgv(argv);
      const relativeCwd = relativePath(cwd, true);
      if (!Number.isInteger(timeoutMs) || timeoutMs < 1000 || timeoutMs > 600000) {
        fail("timeout is outside the admitted range");
      }
      const controller = new AbortController();
      this.controllers.add(controller);
      try {
        return await ownerExec(
          this.config,
          command,
          relativeCwd,
          timeoutMs,
          controller.signal,
        );
      } catch (error) {
        if (controller.signal.aborted) fail("execution interrupted");
        fail(error instanceof Error ? error.message : "owner execution failed");
      } finally {
        this.controllers.delete(controller);
      }
    };
    const next = this.queue.then(operation, operation);
    this.queue = next.then(() => undefined, () => undefined);
    return next;
  }

  async readFile(path) {
    const result = await this.run(["/bin/cat", guestPath(path)], "", 30000);
    if (result.exitCode !== 0) fail(`read failed with exit ${result.exitCode}`);
    return result.stdout;
  }

  async writeGuestFile(path, content) {
    if (typeof content !== "string" || Buffer.byteLength(content) > MAX_WRITE_BYTES) {
      fail("write content exceeds its bound");
    }
    const script = 'set -eu; mkdir -p "$(dirname "$1")"; printf %s "$2" | base64 -d > "$1"';
    const result = await this.run(
      ["/bin/sh", "-c", script, "choir-write", path, Buffer.from(content).toString("base64")],
      "",
      30000,
    );
    if (result.exitCode !== 0) fail(`write failed with exit ${result.exitCode}`);
  }


  async writeFile(path, content) {
    return this.writeGuestFile(guestPath(path), content);
  }

  async writeScopedFile(root, path, content) {
    return this.writeGuestFile(scopedGuestPath(root, path), content);
  }
}

export const mutableTools = [
  {
    name: "read_file",
    description: "Read one UTF-8 file from the sandbox workspace",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string" } },
      required: ["path"],
      additionalProperties: false,
    },
  },
  {
    name: "list_files",
    description: "List sandbox workspace paths under a relative directory",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", default: "" },
        max_depth: { type: "integer", minimum: 1, maximum: 8, default: 4 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "write_file",
    description: "Replace one UTF-8 file in the sandbox workspace",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string" }, content: { type: "string" } },
      required: ["path", "content"],
      additionalProperties: false,
    },
  },
  {
    name: "replace_text",
    description: "Replace exactly one occurrence in a sandbox workspace file",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string" },
        old_text: { type: "string" },
        new_text: { type: "string" },
      },
      required: ["path", "old_text", "new_text"],
      additionalProperties: false,
    },
  },
  {
    name: "run",
    description: "Execute an argv array inside the sandbox workspace",
    inputSchema: {
      type: "object",
      properties: {
        argv: { type: "array", minItems: 1, maxItems: MAX_ARG_COUNT, items: { type: "string" } },
        cwd: { type: "string", default: "" },
        timeout_ms: { type: "integer", minimum: 1000, maximum: 600000, default: 120000 },
      },
      required: ["argv"],
      additionalProperties: false,
    },
  },
];

export const assuranceTools = [
  {
    name: "read_file",
    description: "Read one UTF-8 file from the read-only candidate",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string" } },
      required: ["path"],
      additionalProperties: false,
    },
  },
  {
    name: "list_files",
    description: "List paths under the read-only candidate",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", default: "" },
        max_depth: { type: "integer", minimum: 1, maximum: 8, default: 4 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "write_scratch",
    description: "Write one UTF-8 file below the disposable scratch root",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string" }, content: { type: "string" } },
      required: ["path", "content"],
      additionalProperties: false,
    },
  },
  {
    name: "write_output",
    description: "Write one UTF-8 artifact below the declared output root",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string" }, content: { type: "string" } },
      required: ["path", "content"],
      additionalProperties: false,
    },
  },
];

export const tools = mutableTools;

export function toolsForAccess(access) {
  if (access === "mutable") return mutableTools;
  if (access === "read-only-subject") return assuranceTools;
  fail("invalid workspace access");
}

function toolText(value, isError = false) {
  return { content: [{ type: "text", text: value }], isError };
}

async function callTool(client, name, args) {
  if (!toolsForAccess(client.config.access).some((tool) => tool.name === name)) {
    fail("undeclared tool");
  }
  switch (name) {
    case "read_file":
      return toolText(await client.readFile(args.path));
    case "list_files": {
      const depth = args.max_depth ?? 4;
      if (!Number.isInteger(depth) || depth < 1 || depth > 8) fail("invalid list depth");
      const root = guestPath(args.path ?? "", true);
      const result = await client.run(
        ["/usr/bin/find", root, "-mindepth", "1", "-maxdepth", String(depth), "-printf", "%P\\n"],
        "",
        30000,
      );
      if (result.exitCode !== 0) fail(`list failed with exit ${result.exitCode}`);
      return toolText(result.stdout);
    }
    case "write_file":
      await client.writeFile(args.path, args.content);
      return toolText("written");
    case "replace_text": {
      if (typeof args.old_text !== "string" || args.old_text === "") fail("old text is empty");
      const current = await client.readFile(args.path);
      const first = current.indexOf(args.old_text);
      if (first < 0 || current.indexOf(args.old_text, first + args.old_text.length) >= 0) {
        fail("old text must occur exactly once");
      }
      const updated = current.slice(0, first) + args.new_text + current.slice(first + args.old_text.length);
      await client.writeFile(args.path, updated);
      return toolText("replaced");
    }
    case "write_scratch":
      await client.writeScopedFile("/scratch", args.path, args.content);
      return toolText("written");
    case "write_output":
      await client.writeScopedFile("/output", args.path, args.content);
      return toolText("written");
    case "run": {
      const result = await client.run(args.argv, args.cwd ?? "", args.timeout_ms ?? 120000);
      return toolText(JSON.stringify({
        exit_code: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      }));
    }
    default:
      fail("undeclared tool");
  }
}

function respond(write, id, result) {
  write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function respondError(write, id, message, code = -32000) {
  write(`${JSON.stringify({
    jsonrpc: "2.0",
    id,
    error: { code, message },
  })}\n`);
}

export function runSandboxMcpBridge({
  client,
  visibleTools,
  input,
  write,
  exit,
  dispatchTool = callTool,
}) {
  const framer = new BoundedLineFramer();
  let paused = false;
  let shuttingDown = false;
  let shutdownPromise = null;
  let deferredFrames = [];
  let resumeInput = () => {};
  const scheduler = new SandboxCallQueue(() => queueMicrotask(resumeInput));

  const shutdown = (graceful) => {
    if (shutdownPromise !== null) return shutdownPromise;
    shuttingDown = true;
    input.pause();
    scheduler.close(!graceful);
    if (!graceful) client.close();
    shutdownPromise = (async () => {
      await scheduler.drain();
      await client.drain();
      exit(0);
    })();
    return shutdownPromise;
  };

  const handleFrame = (frame) => {
    if (frame.oversized) {
      respondError(
        write,
        null,
        SANDBOX_MCP_RESOURCE_ERROR.frameMessage,
        SANDBOX_MCP_RESOURCE_ERROR.code,
      );
      return null;
    }
    let request;
    try {
      request = JSON.parse(frame.text);
    } catch {
      return null;
    }
    if (request.id === undefined || request.id === null) {
      if (request.method === "notifications/exit") {
        void shutdown(true);
        return "stop";
      }
      return null;
    }
    switch (request.method) {
      case "initialize":
        respond(write, request.id, {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "choir-sandbox", version: "1" },
        });
        return null;
      case "tools/list":
        respond(write, request.id, { tools: visibleTools });
        return null;
      case "tools/call": {
        const admitted = scheduler.enqueue(frame.bytes, async () => {
          try {
            respond(
              write,
              request.id,
              await dispatchTool(
                client,
                request.params?.name,
                request.params?.arguments ?? {},
              ),
            );
          } catch (error) {
            respond(
              write,
              request.id,
              toolText(
                error instanceof Error ? error.message : "sandbox bridge failed",
                true,
              ),
            );
          }
        });
        if (!admitted.admitted) {
          respondError(
            write,
            request.id,
            SANDBOX_MCP_RESOURCE_ERROR.queueMessage,
            SANDBOX_MCP_RESOURCE_ERROR.code,
          );
          return admitted.reason === "capacity" ? "hard-limit" : null;
        }
        // A canceled shutdown rejects queued entries before they start. The
        // bridge has already stopped accepting input, so no response is owed.
        admitted.promise.catch(() => {});
        return admitted.atHighWater ? "high-water" : null;
      }
      case "ping":
        respond(write, request.id, {});
        return null;
      default:
        respondError(write, request.id, "unsupported method");
        return null;
    }
  };

  const processFrames = (frames) => {
    for (let index = 0; index < frames.length; index += 1) {
      const disposition = handleFrame(frames[index]);
      if (disposition === "stop") return;
      if (disposition !== "high-water" && disposition !== "hard-limit") continue;
      input.pause();
      paused = true;
      // stdin is paused at the high-water mark. One frame may already have
      // been split from the same bounded stream chunk; reject that overrun
      // deterministically, then retain the bounded remainder until capacity
      // returns.
      if (disposition === "high-water" && index + 1 < frames.length) {
        index += 1;
        if (handleFrame(frames[index]) === "stop") return;
      }
      deferredFrames = frames.slice(index + 1);
      return;
    }
  };

  resumeInput = () => {
    if (!paused || shuttingDown) return;
    paused = false;
    const frames = deferredFrames;
    deferredFrames = [];
    processFrames(frames);
    if (!paused && !shuttingDown) input.resume();
  };

  const onData = (chunk) => {
    if (!shuttingDown) processFrames(framer.push(chunk));
  };
  const onEnd = () => {
    if (shuttingDown) return;
    processFrames(framer.end());
    if (!shuttingDown) void shutdown(false);
  };
  const onError = () => {
    if (!shuttingDown) void shutdown(false);
  };
  input.on("data", onData);
  input.once("end", onEnd);
  input.once("error", onError);
  return Object.freeze({ scheduler, shutdown });
}

export function startSandboxMcp(argv = process.argv.slice(2)) {
  const client = new SandboxClient(parseLaunchArgs(argv));
  return runSandboxMcpBridge({
    client,
    visibleTools: toolsForAccess(client.config.access),
    input: process.stdin,
    write: (message) => process.stdout.write(message),
    exit: (code) => process.exit(code),
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  startSandboxMcp();
}
