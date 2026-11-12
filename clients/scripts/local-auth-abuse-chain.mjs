import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const clients = fileURLToPath(new URL("..", import.meta.url));
const systems = resolve(clients, "../systems");
const result = spawnSync(
  "mix",
  ["test", "apps/comma_web/test/auth_abuse_client_chain_test.exs"],
  {
    cwd: systems,
    stdio: "inherit",
    env: process.env,
  }
);
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
