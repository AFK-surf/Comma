// A stand-in for salix-connect that follows the binary's credential
// behaviour for the local_file_read scope: it reports `connected` for the
// token in its config, and when the endpoint refuses that token it writes
// `auth_required` and exits in the same call, before Main can poll.
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const configPath = requiredArgument("--config");
const runNonce = requiredArgument("--run-nonce");
const shutdownRequestPath = requiredArgument("--shutdown-request-file");
const rejectedTokenPath = requiredArgument("--rejected-token-file");
const statusPath = `${configPath}.status.json`;

const config = JSON.parse(readFileSync(configPath, "utf8"));
const token = config.connector.connector_token;

process.on("SIGTERM", () => {
  writeStatus({ state: "stopped" });
  process.exit(0);
});

writeStatus({
  connector_run_id: `run_${token}`,
  device_id: "dev_expiry_e2e",
  local_file_index_version: 2,
  scope: "local_file_read",
  state: "connected",
});

setInterval(() => {
  try {
    const request = JSON.parse(readFileSync(shutdownRequestPath, "utf8"));
    if (request.runNonce === runNonce) {
      writeStatus({ state: "stopped" });
      process.exit(0);
    }
  } catch {
    // No cooperative stop request yet.
  }
  if (
    existsSync(rejectedTokenPath) &&
    readFileSync(rejectedTokenPath, "utf8").trim() === token
  ) {
    writeStatus({
      last_error_class: "auth",
      last_error_message: "connector auth failed: HTTP 401",
      state: "auth_required",
    });
    process.exit(1);
  }
}, 20);

function writeStatus(fields) {
  writeFileSync(
    statusPath,
    `${JSON.stringify({ ...fields, updated_at: Math.floor(Date.now() / 1000) })}\n`
  );
}

function requiredArgument(name) {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value) throw new Error(`${name} is required.`);
  return value;
}
