import { execFile } from "node:child_process";
import { appendFileSync, chmodSync, rmSync } from "node:fs";
import net from "node:net";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { createHash, timingSafeEqual } from "node:crypto";

const execFileAsync = promisify(execFile);
const MAX_REQUEST_BYTES = 128 * 1024;
const MAX_OUTPUT_BYTES = 1024 * 1024;
const MAX_ARG_COUNT = 96;
const MAX_ARG_BYTES = 64 * 1024;

function fail(message) {
  throw new Error(`BoxLite owner: ${message}`);
}

function absolute(value, label) {
  if (typeof value !== "string" || !value.startsWith("/") || value.includes("\0")) {
    fail(`${label} must be absolute`);
  }
  return value;
}

export function parseOwnerLaunchArgs(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined || values.has(key)) {
      fail("invalid launch arguments");
    }
    values.set(key, value);
  }
  const required = ["--socket", "--binary", "--runtime-dir", "--home", "--url"];
  if (values.size !== required.length || required.some((key) => !values.get(key))) {
    fail("incomplete launch arguments");
  }
  const url = values.get("--url");
  if (!/^http:\/\/127\.0\.0\.1:[0-9]{2,5}$/.test(url)) {
    fail("server URL is not loopback HTTP");
  }
  return Object.freeze({
    socket: absolute(values.get("--socket"), "socket"),
    binary: absolute(values.get("--binary"), "binary"),
    runtimeDir: absolute(values.get("--runtime-dir"), "runtime directory"),
    home: absolute(values.get("--home"), "home"),
    url,
  });
}

function normalizedRelative(value) {
  if (typeof value !== "string" || value.includes("\0") || value.includes("\\")) {
    fail("invalid working directory");
  }
  const trimmed = value.replace(/^\.\//, "").replace(/\/$/, "");
  if (trimmed.startsWith("/")) fail("working directory must be relative");
  const parts = trimmed === "" ? [] : trimmed.split("/");
  if (parts.some((part) => part === "" || part === "." || part === "..")) {
    fail("working directory is not normalized");
  }
  return trimmed;
}

function boundedArgv(value) {
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

export function validateOwnerRequest(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    fail("request is not an object");
  }
  const keys = Object.keys(value).sort();
  const expected = ["access", "argv", "box", "cwd", "operation", "timeout_ms", "token"];
  if (keys.length !== expected.length || keys.some((key, index) => key !== expected[index])) {
    fail("request fields are not exact");
  }
  if (value.operation !== "exec") fail("operation is not admitted");
  if (typeof value.token !== "string" || !/^[a-f0-9]{64}$/.test(value.token)) {
    fail("invalid capability");
  }
  if (typeof value.box !== "string" || !/^[a-zA-Z0-9_-]{1,180}$/.test(value.box)) {
    fail("invalid box identity");
  }
  if (!["mutable", "read-only-subject"].includes(value.access)) {
    fail("invalid workspace access");
  }
  if (!Number.isInteger(value.timeout_ms) || value.timeout_ms < 1000 || value.timeout_ms > 600000) {
    fail("timeout is outside the admitted range");
  }
  return Object.freeze({
    operation: "exec",
    token: value.token,
    box: value.box,
    access: value.access,
    cwd: normalizedRelative(value.cwd),
    timeoutMs: value.timeout_ms,
    argv: boundedArgv(value.argv),
  });
}

function equalToken(presented, expected) {
  const left = Buffer.from(presented);
  const right = Buffer.from(expected);
  return left.length === right.length && timingSafeEqual(left, right);
}

export function deriveExecutionToken(secret, box, access) {
  if (!/^[a-f0-9]{64}$/.test(secret)) fail("invalid owner secret");
  if (typeof box !== "string" || !/^[a-zA-Z0-9_-]{1,180}$/.test(box)) {
    fail("invalid box identity");
  }
  if (!["mutable", "read-only-subject"].includes(access)) {
    fail("invalid workspace access");
  }
  return createHash("sha256")
    .update(`choir.boxlite-exec.v1\0${secret}\0${box}\0${access}`)
    .digest("hex");
}

async function execute(config, request, signal) {
  const command = request.access === "read-only-subject"
    ? ["/usr/bin/setpriv", "--reuid=65534", "--regid=65534", "--clear-groups", "--", ...request.argv]
    : request.argv;
  const workdir = request.cwd === "" ? "/workspace" : `/workspace/${request.cwd}`;
  const args = [
    "--home", config.home,
    "--url", config.url,
    "exec", "--workdir", workdir,
    request.box, "--", ...command,
  ];
  try {
    const result = await execFileAsync(config.binary, args, {
      cwd: config.home,
      env: {
        HOME: config.home,
        PATH: "/usr/bin:/bin",
        BOXLITE_API_KEY: process.env.CHOIR_BOXLITE_API_KEY,
        BOXLITE_RUNTIME_DIR: config.runtimeDir,
        LC_ALL: "C",
      },
      timeout: request.timeoutMs,
      maxBuffer: MAX_OUTPUT_BYTES,
      signal,
      windowsHide: true,
    });
    return { ok: true, exit_code: 0, stdout: result.stdout, stderr: result.stderr };
  } catch (error) {
    if (error?.name === "AbortError") return { ok: false, error: "execution interrupted" };
    if (error?.killed) return { ok: false, error: "execution timed out" };
    if (typeof error?.code === "number") {
      return {
        ok: true,
        exit_code: error.code,
        stdout: error.stdout ?? "",
        stderr: error.stderr ?? "",
      };
    }
    return { ok: false, error: "execution failed" };
  }
}

export function startBoxLiteOwner(argv = process.argv.slice(2)) {
  const config = parseOwnerLaunchArgs(argv);
  const log = (message) => {
    try {
      appendFileSync(`${config.home}/owner.log`, `${message}\n`, { mode: 0o600 });
    } catch {
      // The parent treats a missing socket as a failed-closed startup.
    }
  };
  const ownerSecret = process.env.CHOIR_BOXLITE_OWNER_TOKEN ?? "";
  const apiKey = process.env.CHOIR_BOXLITE_API_KEY ?? "";
  if (!/^[a-f0-9]{64}$/.test(ownerSecret) || apiKey === "") {
    fail("owner credentials are unavailable");
  }
  rmSync(config.socket, { force: true });
  const server = net.createServer((socket) => {
    let body = "";
    let dispatched = false;
    const controller = new AbortController();
    socket.on("close", () => controller.abort());
    socket.on("data", async (chunk) => {
      if (dispatched) return;
      body += chunk.toString("utf8");
      if (Buffer.byteLength(body) > MAX_REQUEST_BYTES) {
        dispatched = true;
        socket.end(`${JSON.stringify({ ok: false, error: "request too large" })}\n`);
        return;
      }
      const newline = body.indexOf("\n");
      if (newline < 0) return;
      dispatched = true;
      try {
        if (body.slice(newline + 1).trim() !== "") fail("multiple requests are not admitted");
        const request = validateOwnerRequest(JSON.parse(body.slice(0, newline)));
        const expectedToken = deriveExecutionToken(
          ownerSecret,
          request.box,
          request.access,
        );
        if (!equalToken(request.token, expectedToken)) fail("authentication failed");
        const response = await execute(config, request, controller.signal);
        if (!socket.destroyed) socket.end(`${JSON.stringify(response)}\n`);
      } catch (error) {
        const message = error instanceof Error ? error.message : "invalid request";
        if (!socket.destroyed) socket.end(`${JSON.stringify({ ok: false, error: message })}\n`);
      }
    });
  });
  server.on("error", (error) => {
    log(`listen failed: ${error instanceof Error ? error.message : "unknown error"}`);
    process.exit(1);
  });
  server.listen(config.socket, () => {
    chmodSync(config.socket, 0o600);
    log("ready");
  });
  const stop = () => server.close(() => {
    rmSync(config.socket, { force: true });
    process.exit(0);
  });
  process.once("SIGTERM", stop);
  process.once("SIGINT", stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  startBoxLiteOwner();
}
