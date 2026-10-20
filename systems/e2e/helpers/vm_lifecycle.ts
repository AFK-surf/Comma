import { once } from "node:events";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SALIX_ROOT = new URL("../..", import.meta.url).pathname;
const WORKER_ROOT = new URL(
  "../../cloudflare/salix-vm-gateway",
  import.meta.url,
).pathname;
const DEFAULT_TIMEOUT_MS = 10 * 60_000;

export type VmProvider = "cloudflare";
export type VmSurface = "bft" | "comma";

export type RunVmLifecycleOptions = {
  timeoutMs?: number;
};

type ProviderEnv = {
  env: Record<string, string>;
  cleanup: Array<() => Promise<void>>;
  skip?: string;
};

export type RunOptions = {
  cwd?: string;
  env?: Record<string, string | undefined>;
  timeoutMs?: number;
  allowFailure?: boolean;
  stdout?: "pipe" | "inherit" | "ignore";
  stderr?: "pipe" | "inherit" | "ignore";
};

export async function runVmLifecycle(
  surface: VmSurface,
  provider: VmProvider,
  opts: RunVmLifecycleOptions = {},
) {
  const providerEnv = await resolveProviderEnv([provider]);
  if (providerEnv.skip) return skipOrThrow(providerEnv.skip);

  const pg = await startPostgres();

  try {
    await run("mix", ["run", "scripts/vm_lifecycle_e2e.exs"], {
      cwd: SALIX_ROOT,
      timeoutMs: opts.timeoutMs ?? DEFAULT_TIMEOUT_MS,
      env: {
        ...process.env,
        ...providerEnv.env,
        PATH: pathWithAsdf(),
        MIX_ENV: "test",
        BRIDGE_TEST_DB_PORT: String(pg.port),
        BILLING_TEST_DB_PORT: String(pg.port),
        COMMA_TEST_DB_PORT: String(pg.port),
        SALIX_VM_E2E_SURFACE: surface,
        SALIX_VM_E2E_PROVIDER: provider,
        SALIX_VM_E2E_TIMEOUT_MS:
          process.env.SALIX_VM_E2E_TIMEOUT_MS ?? "300000",
      },
    });
  } finally {
    await Promise.allSettled(providerEnv.cleanup.map((cleanup) => cleanup()));
    await pg.close();
  }
}

export async function resolveProviderEnv(
  providers: VmProvider[],
): Promise<ProviderEnv> {
  const env: Record<string, string> = {};
  const cleanup: Array<() => Promise<void>> = [];

  if (providers.includes("cloudflare")) {
    const configuredBase = process.env.SALIX_E2E_CF_GATEWAY_BASE_URL;
    const configuredSecret = process.env.SALIX_E2E_CF_GATEWAY_SECRET;

    if (configuredBase && configuredSecret) {
      env.SALIX_E2E_CF_GATEWAY_BASE_URL = configuredBase;
      env.SALIX_E2E_CF_GATEWAY_SECRET = configuredSecret;
    } else if (process.env.SALIX_VM_E2E_ENABLE_CLOUDFLARE === "1") {
      const gateway = await startWranglerGateway();
      env.SALIX_E2E_CF_GATEWAY_BASE_URL = gateway.baseUrl;
      env.SALIX_E2E_CF_GATEWAY_SECRET = gateway.secret;
      cleanup.push(gateway.close);
    } else {
      return {
        env,
        cleanup,
        skip: "Cloudflare VM e2e is disabled; set SALIX_VM_E2E_ENABLE_CLOUDFLARE=1 or provide SALIX_E2E_CF_GATEWAY_BASE_URL/SECRET",
      };
    }
  }

  return { env, cleanup };
}

export async function startPostgres() {
  const id = crypto.randomUUID().slice(0, 8);
  const name = `vm-lifecycle-e2e-pg-${id}`;
  const port = await freePort();

  await run("docker", [
    "run",
    "-d",
    "--rm",
    "--name",
    name,
    "-p",
    `${port}:5432`,
    "-e",
    "POSTGRES_PASSWORD=postgres",
    "postgres:16-alpine",
  ]);

  for (let i = 0; i < 120; i++) {
    const result = await run(
      "docker",
      ["exec", name, "pg_isready", "-U", "postgres"],
      {
        allowFailure: true,
        stdout: "ignore",
        stderr: "ignore",
      },
    );
    if (result.success) break;
    if (i === 119) throw new Error("timed out waiting for Postgres");
    await delay(500);
  }

  await createDatabase(name, "bridge_for_teams_test");
  await createDatabase(name, "billing_core_test");
  await createDatabase(name, "comma_core_test");

  return {
    port,
    async close() {
      await run("docker", ["rm", "-f", name], { allowFailure: true });
    },
  };
}

async function createDatabase(containerName: string, database: string) {
  for (let i = 0; i < 30; i++) {
    const result = await run(
      "docker",
      ["exec", containerName, "createdb", "-U", "postgres", database],
      { allowFailure: true },
    );

    if (result.success || result.combined.includes("already exists")) return;
    if (i === 29) {
      throw new Error(`failed to create ${database}\n${result.combined}`);
    }

    await delay(500);
  }
}

async function startWranglerGateway() {
  const port = await freePort();
  const persistDir = await mkdtemp(join(tmpdir(), "salix-vm-gateway-"));
  const secret = `vm-e2e-${crypto.randomUUID()}`;
  let child: Bun.Subprocess | undefined;

  try {
    try {
      await stat(`${WORKER_ROOT}/node_modules`);
    } catch {
      await run("npm", ["ci"], { cwd: WORKER_ROOT, timeoutMs: 180_000 });
    }

    await run("npm", ["run", "prepare:image"], {
      cwd: WORKER_ROOT,
      timeoutMs: 180_000,
    });

    child = Bun.spawn(
      [
        "npx",
        "wrangler",
        "dev",
        "--env",
        "staging",
        "--port",
        String(port),
        "--ip",
        "127.0.0.1",
        "--local",
        "--persist-to",
        persistDir,
        "--var",
        `SALIX_VM_GATEWAY_SECRET:${secret}`,
        "--show-interactive-dev-session=false",
      ],
      {
        cwd: WORKER_ROOT,
        env: {
          ...process.env,
          PATH: pathWithAsdf(),
        },
        stdout: "inherit",
        stderr: "inherit",
      },
    );

    const baseUrl = `http://127.0.0.1:${port}`;
    await waitForHttp(`${baseUrl}/healthz`, "Cloudflare Worker gateway");
    const wrangler = child;

    return {
      baseUrl,
      secret,
      async close() {
        try {
          wrangler.kill("SIGTERM");
        } catch {
          // Already exited.
        }
        await wrangler.exited.catch(() => {});
        await rm(persistDir, { recursive: true }).catch(() => {});
      },
    };
  } catch (error) {
    if (child) {
      try {
        child.kill("SIGTERM");
      } catch {
        // Already exited.
      }
      await child.exited.catch(() => {});
    }
    await rm(persistDir, { recursive: true }).catch(() => {});
    throw error;
  }
}

async function waitForHttp(url: string, label: string) {
  const target = new URL(url);

  for (let i = 0; i < 180; i++) {
    try {
      if (await rawHttpOk(target)) return;
    } catch {
      // Retry below.
    }
    await delay(1_000);
  }
  throw new Error(`timed out waiting for ${label} at ${url}`);
}

async function rawHttpOk(target: URL) {
  if (target.protocol !== "http:") {
    throw new Error(`unsupported health-check protocol: ${target.protocol}`);
  }

  const port = Number(target.port || "80");
  const conn = connect({ host: target.hostname, port });

  try {
    await once(conn, "connect");
    const path = `${target.pathname}${target.search}`;
    const request = `GET ${path} HTTP/1.1\r\nHost: ${target.host}\r\nConnection: close\r\n\r\n`;
    conn.write(request);

    const head = await Promise.race<string | null>([
      once(conn, "data").then(([chunk]) => String(chunk)),
      delay(1_000).then(() => null),
    ]);

    if (!head) return false;

    return /^HTTP\/1\.[01] 2\d\d\b/.test(head);
  } finally {
    conn.destroy();
  }
}

export async function run(
  command: string,
  args: string[],
  opts: RunOptions = {},
) {
  const stdoutMode = opts.stdout ?? "pipe";
  const stderrMode = opts.stderr ?? "pipe";

  let child: Bun.Subprocess<"ignore", typeof stdoutMode, typeof stderrMode>;
  try {
    child = Bun.spawn([command, ...args], {
      cwd: opts.cwd,
      env: { ...process.env, ...opts.env },
      stdout: stdoutMode,
      stderr: stderrMode,
    });
  } catch (error) {
    if (!opts.allowFailure) throw error;

    const message = error instanceof Error ? error.message : String(error);
    return {
      success: false,
      code: -1,
      stdout: "",
      stderr: message,
      combined: message,
    };
  }

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    try {
      child.kill("SIGTERM");
    } catch {
      // Already exited.
    }
  }, opts.timeoutMs ?? 60_000);

  const [stdout, stderr, code] = await Promise.all([
    child.stdout ? new Response(child.stdout).text() : "",
    child.stderr ? new Response(child.stderr).text() : "",
    child.exited,
  ]);
  clearTimeout(timer);

  const combined = stdout + stderr;

  if ((code !== 0 || timedOut) && !opts.allowFailure) {
    throw new Error(
      [
        `command failed: ${command} ${args.join(" ")}`,
        `code=${code} timedOut=${timedOut}`,
        combined,
      ].join("\n"),
    );
  }

  return {
    success: code === 0,
    code,
    stdout,
    stderr,
    combined,
  };
}

async function freePort() {
  const listener = Bun.listen({
    hostname: "127.0.0.1",
    port: 0,
    socket: { data() {} },
  });
  const port = listener.port;
  listener.stop(true);
  return port;
}

function skipOrThrow(message: string) {
  if (process.env.SALIX_VM_E2E_STRICT === "1") throw new Error(message);
  console.log(`VM_LIFECYCLE_E2E: SKIP ${message}`);
}

export function pathWithAsdf() {
  const path = process.env.PATH ?? "";
  const home = process.env.HOME;
  if (!home) return path;
  return `${home}/.asdf/shims:${path}`;
}

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
