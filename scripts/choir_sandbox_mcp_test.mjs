import assert from "node:assert/strict";
import test from "node:test";

import {
  parseLaunchArgs,
  relativePath,
  tools,
  validateArgv,
} from "./choir_sandbox_mcp.mjs";

const launchArgs = [
  "--binary", "/opt/boxlite",
  "--runtime-dir", "/opt/runtime",
  "--url", "http://127.0.0.1:22000",
  "--api-key", "take-key",
  "--home", "/tmp/take",
  "--box", "box-1",
];

test("launch arguments admit only the fixed local shape", () => {
  assert.equal(parseLaunchArgs(launchArgs).box, "box-1");
  const remote = launchArgs.slice();
  remote[5] = "https://example.com";
  assert.throws(() => parseLaunchArgs(remote));
  assert.throws(() => parseLaunchArgs([...launchArgs, "--extra", "value"]));
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
});
