import assert from "node:assert/strict";
import test from "node:test";

import {
  assuranceTools,
  parseLaunchArgs,
  relativePath,
  tools,
  toolsForAccess,
  validateArgv,
} from "./choir_sandbox_mcp.mjs";

const launchArgs = [
  "--binary", "/opt/boxlite",
  "--runtime-dir", "/opt/runtime",
  "--url", "http://127.0.0.1:22000",
  "--api-key", "take-key",
  "--home", "/tmp/take",
  "--box", "box-1",
  "--access", "mutable",
];

test("launch arguments admit only the fixed local shape", () => {
  assert.equal(parseLaunchArgs(launchArgs).box, "box-1");
  assert.equal(parseLaunchArgs(launchArgs).access, "mutable");
  const remote = launchArgs.slice();
  remote[5] = "https://example.com";
  assert.throws(() => parseLaunchArgs(remote));
  assert.throws(() => parseLaunchArgs([...launchArgs, "--extra", "value"]));
  const invalidAccess = launchArgs.slice();
  invalidAccess[invalidAccess.length - 1] = "broad";
  assert.throws(() => parseLaunchArgs(invalidAccess));
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
