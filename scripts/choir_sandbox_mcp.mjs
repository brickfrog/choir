import { execFile } from "node:child_process";
import readline from "node:readline";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const MAX_TEXT_BYTES = 1024 * 1024;
const MAX_WRITE_BYTES = 256 * 1024;
const MAX_ARG_COUNT = 96;
const MAX_ARG_BYTES = 64 * 1024;

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
  const required = [
    "--binary",
    "--runtime-dir",
    "--url",
    "--api-key",
    "--home",
    "--box",
    "--access",
  ];
  if (values.size !== required.length) fail("unknown launch argument");
  for (const key of required) {
    if (!values.get(key)) fail(`missing ${key}`);
  }
  const absolute = ["--binary", "--runtime-dir", "--home"];
  for (const key of absolute) {
    if (!values.get(key).startsWith("/")) fail(`${key} must be absolute`);
  }
  if (!/^http:\/\/127\.0\.0\.1:[0-9]{2,5}$/.test(values.get("--url"))) {
    fail("server URL is not loopback HTTP");
  }
  if (!/^[a-zA-Z0-9-]{1,180}$/.test(values.get("--box"))) {
    fail("invalid box identity");
  }
  if (!["mutable", "read-only-subject"].includes(values.get("--access"))) {
    fail("invalid workspace access");
  }
  return Object.freeze({
    binary: values.get("--binary"),
    runtimeDir: values.get("--runtime-dir"),
    url: values.get("--url"),
    apiKey: values.get("--api-key"),
    home: values.get("--home"),
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

class SandboxClient {
  constructor(config) {
    this.config = config;
    this.queue = Promise.resolve();
  }

  run(argv, cwd = "", timeoutMs = 120000) {
    const operation = async () => {
      const command = validateArgv(argv);
      const guestCommand = this.config.access === "read-only-subject"
        ? [
            "/usr/bin/setpriv",
            "--reuid=65534",
            "--regid=65534",
            "--clear-groups",
            "--",
            ...command,
          ]
        : command;
      const relativeCwd = relativePath(cwd, true);
      if (!Number.isInteger(timeoutMs) || timeoutMs < 1000 || timeoutMs > 600000) {
        fail("timeout is outside the admitted range");
      }
      const args = [
        "--home",
        this.config.home,
        "--url",
        this.config.url,
        "exec",
        "--workdir",
        guestPath(relativeCwd, true),
        this.config.box,
        "--",
        ...guestCommand,
      ];
      try {
        const result = await execFileAsync(this.config.binary, args, {
          cwd: this.config.home,
          env: {
            HOME: this.config.home,
            PATH: "/usr/bin:/bin",
            BOXLITE_API_KEY: this.config.apiKey,
            BOXLITE_RUNTIME_DIR: this.config.runtimeDir,
            LC_ALL: "C",
          },
          timeout: timeoutMs,
          maxBuffer: MAX_TEXT_BYTES,
          windowsHide: true,
        });
        return { exitCode: 0, stdout: result.stdout, stderr: result.stderr };
      } catch (error) {
        if (error?.killed) fail("execution timed out");
        if (typeof error?.code === "number") {
          return {
            exitCode: error.code,
            stdout: error.stdout ?? "",
            stderr: error.stderr ?? "",
          };
        }
        fail("BoxLite execution failed");
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

function respond(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function respondError(id, message) {
  process.stdout.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id,
    error: { code: -32000, message },
  })}\n`);
}

export function startSandboxMcp(argv = process.argv.slice(2)) {
  const client = new SandboxClient(parseLaunchArgs(argv));
  const visibleTools = toolsForAccess(client.config.access);
  const input = readline.createInterface({ input: process.stdin, terminal: false });
  input.on("line", async (line) => {
    let request;
    try {
      request = JSON.parse(line);
    } catch {
      return;
    }
    if (request.id === undefined || request.id === null) return;
    try {
      switch (request.method) {
        case "initialize":
          respond(request.id, {
            protocolVersion: "2024-11-05",
            capabilities: { tools: {} },
            serverInfo: { name: "choir-sandbox", version: "1" },
          });
          break;
        case "tools/list":
          respond(request.id, { tools: visibleTools });
          break;
        case "tools/call":
          respond(request.id, await callTool(client, request.params?.name, request.params?.arguments ?? {}));
          break;
        case "ping":
          respond(request.id, {});
          break;
        default:
          respondError(request.id, "unsupported method");
      }
    } catch (error) {
      respond(request.id, toolText(error instanceof Error ? error.message : "sandbox bridge failed", true));
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  startSandboxMcp();
}
