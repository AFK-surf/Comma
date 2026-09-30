#!/usr/bin/env node

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const defaultRepoRoot = path.resolve(scriptDir, "../..");
const composePath = path.join(defaultRepoRoot, "systems/docker-compose.salix-dev.yml");
const supportedCommands = new Set([
  "up",
  "rebuild",
  "status",
  "logs",
  "down",
  "reset",
  "psql",
  "shell",
  "config",
  "info",
]);

export function deriveSandbox({ repoRoot, env = process.env }) {
  const root = path.resolve(repoRoot);
  const digest = createHash("sha256").update(root).digest("hex");
  const slot = Number.parseInt(digest.slice(0, 8), 16) % 10_000;
  const fallbackName = `${path.basename(path.dirname(root))}-${path.basename(root)}`;
  const requestedName = env.SALIX_DEV_ID || fallbackName;
  const id = normalizeId(requestedName);
  const project = `comma-salix-${id.slice(0, 32)}-${digest.slice(0, 6)}`;
  const httpPort = parsePort(env.SALIX_DEV_HTTP_PORT, 20_000 + slot, "SALIX_DEV_HTTP_PORT");
  const transferPort = parsePort(
    env.SALIX_DEV_TRANSFER_PORT,
    40_000 + slot,
    "SALIX_DEV_TRANSFER_PORT",
  );

  if (httpPort === transferPort) {
    throw new Error("Salix HTTP and transfer ports must differ");
  }

  const stateDir = path.join(root, ".local", "salix-dev", project);

  return {
    id,
    project,
    image: `comma-systems-dev:${project}`,
    httpPort,
    transferPort,
    stateDir,
    configPath: path.join(stateDir, "config.json"),
    releaseCookie: `comma-dev-${digest}`,
  };
}

export function renderConfig(sandbox) {
  return {
    storage: {
      endpoint: "http://minio:9000",
      region: "us-east-1",
      bucket: "salix-dev",
      access_key_id: "minioadmin",
      secret_access_key: "minioadmin",
      atomic_operations: "s3",
      conditional_delete: "emulate",
    },
    web: {
      port: 4000,
      api_token: "test-token",
      api_base_url: `http://127.0.0.1:${sandbox.httpPort}`,
      sites_domain: "salix.localhost",
      sites_port: sandbox.httpPort,
    },
    transfer: {
      port: 4400,
      advertise_host: "127.0.0.1",
      advertise_port: sandbox.transferPort,
    },
    salix_dashboard: {
      secret_key_base:
        "dev_only_secret_key_base_for_isolated_salix_000000000000000000000000000000000",
    },
    salix: {
      database: {
        url: "ecto://postgres:postgres@postgres:5432/billing_core_dev",
        pool_size: 4,
      },
    },
    billing: {
      database: {
        url: "ecto://postgres:postgres@postgres:5432/billing_core_dev",
        pool_size: 10,
      },
    },
    clickhouse: {
      url: "http://clickhouse:8123",
      table: "salix_analytics.events",
      user: null,
      password: null,
    },
    llm: {
      default_template: {
        template_id: "salix-local-dev",
        name: "Salix Local Dev Mock",
        model: "gpt-local-dev",
        max_tokens: 2048,
        context_tokens: 32768,
        provider_config: {
          protocol: "chat_completions",
          base_url: "http://llm-mock:43123",
          api_key: "local-dev-only",
        },
      },
    },
  };
}

export function normalizeId(value) {
  const normalized = String(value)
    .toLowerCase()
    .replace(/^refs\/heads\//, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

  if (!normalized) {
    throw new Error("SALIX_DEV_ID must contain at least one letter or number");
  }

  return normalized;
}

function parsePort(raw, fallback, name) {
  const value = raw === undefined || raw === "" ? fallback : Number(raw);

  if (!Number.isInteger(value) || value < 1 || value > 65_535) {
    throw new Error(`${name} must be an integer from 1 through 65535`);
  }

  return value;
}

export function prepareConfig(sandbox) {
  mkdirSync(sandbox.stateDir, { recursive: true, mode: 0o700 });
  chmodSync(sandbox.stateDir, 0o700);
  writeFileSync(sandbox.configPath, `${JSON.stringify(renderConfig(sandbox), null, 2)}\n`, {
    mode: 0o644,
  });
  // Docker bind mounts preserve the source mode on a regular Linux engine.
  // The release runs as 10001:10001, which is intentionally unrelated to
  // the host developer's uid, so the mounted file needs its other-read bit.
  // The per-sandbox directory remains 0700 to keep the local-only credentials
  // out of reach of other host users.
  chmodSync(sandbox.configPath, 0o644);
}

function composeEnvironment(sandbox) {
  return {
    ...process.env,
    SALIX_DEV_IMAGE: sandbox.image,
    SALIX_DEV_CONFIG_PATH: sandbox.configPath,
    SALIX_DEV_HTTP_PORT: String(sandbox.httpPort),
    SALIX_DEV_TRANSFER_PORT: String(sandbox.transferPort),
    SALIX_DEV_RELEASE_COOKIE: sandbox.releaseCookie,
  };
}

function composeArgs(sandbox, args) {
  const override = path.join(sandbox.stateDir, "compose.override.yml");
  const files = ["--file", composePath];
  if (existsSync(override)) files.push("--file", override);
  return ["compose", "--project-name", sandbox.project, ...files, ...args];
}

function runCompose(sandbox, args) {
  const result = spawnSync("docker", composeArgs(sandbox, args), {
    cwd: defaultRepoRoot,
    env: composeEnvironment(sandbox),
    stdio: "inherit",
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const error = new Error(`docker ${composeArgs(sandbox, args).join(" ")} failed`);
    error.exitCode = result.status ?? 1;
    throw error;
  }
}

function isSalixRunning(sandbox) {
  const result = spawnSync(
    "docker",
    composeArgs(sandbox, ["ps", "--status", "running", "--services"]),
    {
      cwd: defaultRepoRoot,
      env: composeEnvironment(sandbox),
      encoding: "utf8",
    },
  );

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const detail = result.stderr?.trim();
    throw new Error(detail || "Unable to inspect this worktree's Salix sandbox");
  }

  return result.stdout.split(/\r?\n/).includes("salix");
}

export async function assertHostPortsAvailable(sandbox) {
  await Promise.all([
    assertHostPortAvailable(sandbox.httpPort, "Salix HTTP", "SALIX_DEV_HTTP_PORT"),
    assertHostPortAvailable(
      sandbox.transferPort,
      "Salix transfer",
      "SALIX_DEV_TRANSFER_PORT",
    ),
  ]);
}

function assertHostPortAvailable(port, label, variable) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();

    server.once("error", (error) => {
      if (error?.code === "EADDRINUSE") {
        reject(
          new Error(`${label} host port ${port} is already in use; choose a free ${variable}`),
        );
        return;
      }

      reject(error);
    });

    server.listen({ host: "127.0.0.1", port, exclusive: true }, () => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  });
}

function printInfo(sandbox) {
  console.log(`Salix sandbox:  ${sandbox.id}`);
  console.log(`Compose project: ${sandbox.project}`);
  console.log(`Salix API:       http://127.0.0.1:${sandbox.httpPort}`);
  console.log(`Dashboard:       http://127.0.0.1:${sandbox.httpPort}/dash`);
  console.log(`Transfer:        127.0.0.1:${sandbox.transferPort}`);
  console.log("Postgres:        internal only (postgres:5432)");
  console.log("MinIO:           internal only (minio:9000)");
  console.log("Redis:           internal only (redis:6379)");
  console.log("ClickHouse:      internal only (clickhouse:8123)");
}

function usage() {
  console.error(
    `Usage: node systems/scripts/salix-dev.mjs <${[...supportedCommands].join("|")}>`,
  );
}

async function main() {
  const command = process.argv[2];

  if (!supportedCommands.has(command)) {
    usage();
    process.exitCode = 2;
    return;
  }

  const sandbox = deriveSandbox({ repoRoot: defaultRepoRoot, env: process.env });
  prepareConfig(sandbox);

  switch (command) {
    case "up":
      printInfo(sandbox);
      if (!isSalixRunning(sandbox)) {
        await assertHostPortsAvailable(sandbox);
      }
      runCompose(sandbox, ["up", "--detach", "--build", "--wait"]);
      break;
    case "rebuild":
      printInfo(sandbox);
      if (!isSalixRunning(sandbox)) {
        await assertHostPortsAvailable(sandbox);
      }
      runCompose(sandbox, ["build", "salix"]);
      runCompose(sandbox, ["stop", "salix"]);
      runCompose(sandbox, ["run", "--rm", "--no-deps", "salix-migrate"]);
      runCompose(sandbox, [
        "up",
        "--detach",
        "--no-deps",
        "--force-recreate",
        "--wait",
        "salix",
      ]);
      break;
    case "status":
      printInfo(sandbox);
      runCompose(sandbox, ["ps", "--all"]);
      break;
    case "logs":
      runCompose(sandbox, ["logs", "--follow", "salix", "salix-migrate", "llm-mock"]);
      break;
    case "down":
      runCompose(sandbox, ["down", "--remove-orphans"]);
      break;
    case "reset":
      runCompose(sandbox, ["down", "--volumes", "--remove-orphans"]);
      break;
    case "psql":
      runCompose(sandbox, ["exec", "postgres", "psql", "-U", "postgres", "-d", "billing_core_dev"]);
      break;
    case "shell":
      runCompose(sandbox, ["exec", "salix", "/bin/sh"]);
      break;
    case "config":
      runCompose(sandbox, ["config"]);
      break;
    case "info":
      printInfo(sandbox);
      break;
  }
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "")) {
  try {
    await main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = Number.isInteger(error?.exitCode) ? error.exitCode : 1;
  }
}
