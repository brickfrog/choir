import assert from "node:assert/strict";
import test from "node:test";

import {
  assuranceTools,
  drainPendingResponses,
  parseLaunchArgs,
  relativePath,
  tools,
  toolsForAccess,
  validateArgv,
} from "./choir_sandbox_mcp.mjs";
import {
  deriveExecutionToken,
  parseOwnerLaunchArgs,
  validateOwnerRequest,
} from "./choir_boxlite_owner.mjs";

const launchArgs = [
  "--owner-socket", "/tmp/take/owner.sock",
  "--owner-token", "a".repeat(64),
  "--box", "box-1",
  "--access", "mutable",
];

test("launch arguments admit only the fixed local shape", () => {
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

test("graceful exit waits for responses before draining commands", async () => {
  let release;
  const response = new Promise((resolve) => { release = resolve; });
  const pending = new Set([response]);
  let drained = false;
  const waiting = drainPendingResponses(pending, async () => { drained = true; });
  await Promise.resolve();
  assert.equal(drained, false);
  release();
  await waiting;
  assert.equal(drained, true);
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
