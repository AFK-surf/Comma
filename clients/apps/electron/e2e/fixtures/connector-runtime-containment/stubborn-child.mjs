import { writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";

const runNonce = requiredArgument("--run-nonce");
const shutdownRequestPath = requiredArgument("--shutdown-request-file");
const startedMarkerPath = requiredArgument("--started-marker");

process.on("SIGTERM", () => undefined);
process.on("SIGHUP", () => undefined);

await writeFile(
  startedMarkerPath,
  `${JSON.stringify({ pid: process.pid, runNonce })}\n`,
  { mode: 0o600 }
);

let shutdownObservedAt;
setInterval(() => {
  if (shutdownObservedAt !== undefined) {
    // Keep a visible interval in which recovery has issued the exact nonce
    // request but may not yet delete the run evidence.
    if (Date.now() - shutdownObservedAt >= 300) process.exit(0);
    return;
  }
  try {
    const request = JSON.parse(readFileSync(shutdownRequestPath, "utf8"));
    if (request.runNonce === runNonce) shutdownObservedAt = Date.now();
  } catch {
    // No exact request yet.
  }
}, 20);

function requiredArgument(name) {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value) throw new Error(`${name} is required.`);
  return value;
}
