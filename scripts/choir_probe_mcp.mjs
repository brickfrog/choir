import readline from "node:readline";
import { writeFileSync } from "node:fs";

const delayIndex = process.argv.indexOf("--delay-ms");
const delayMs = delayIndex >= 0 ? Number(process.argv[delayIndex + 1]) : 0;
const credentialCanaryIndex = process.argv.indexOf("--credential-canary-path");
const credentialCanaryPath =
  credentialCanaryIndex >= 0 ? process.argv[credentialCanaryIndex + 1] : null;
if (!Number.isInteger(delayMs) || delayMs < 0 || delayMs > 30_000) {
  throw new Error("invalid probe delay");
}
if (credentialCanaryPath && process.env.CHOIR_CREDENTIAL_CANARY) {
  writeFileSync(credentialCanaryPath, process.env.CHOIR_CREDENTIAL_CANARY, {
    mode: 0o600,
  });
}

const input = readline.createInterface({ input: process.stdin, terminal: false });

function respond(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

input.on("line", (line) => {
  let request;
  try {
    request = JSON.parse(line);
  } catch {
    return;
  }

  if (request.id === undefined || request.id === null) return;

  switch (request.method) {
    case "initialize":
      respond(request.id, {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "choir-probe", version: "1" },
      });
      break;
    case "tools/list":
      respond(request.id, {
        tools: [
          {
            name: "probe",
            description: "Choir startup conformance canary",
            inputSchema: {
              type: "object",
              properties: {},
              additionalProperties: false,
            },
          },
        ],
      });
      break;
    case "tools/call":
      setTimeout(() => {
        respond(request.id, {
          content: [{ type: "text", text: "probe" }],
          isError: false,
        });
      }, delayMs);
      break;
    case "ping":
      respond(request.id, {});
      break;
    default:
      process.stdout.write(
        JSON.stringify({
          jsonrpc: "2.0",
          id: request.id,
          error: { code: -32601, message: `unsupported: ${request.method}` },
        }) + "\n",
      );
  }
});
