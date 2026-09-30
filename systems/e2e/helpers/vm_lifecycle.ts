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
  env?: Record<string, string>;
  timeoutMs?: number;
  allowFailure?: boolean;
  stdout?: "piped" | "inherit" | "null";
  stderr?: "piped" | "inherit" | "null";
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
        ...Deno.env.toObject(),
        ...providerEnv.env,
        PATH: pathWithAsdf(),
        MIX_ENV: "test",
        BRIDGE_TEST_DB_PORT: String(pg.port),
        BILLING_TEST_DB_PORT: String(pg.port),
        COMMA_TEST_DB_PORT: String(pg.port),
        SALIX_VM_E2E_SURFACE: surface,
        SALIX_VM_E2E_PROVIDER: provider,
        SALIX_VM_E2E_TIMEOUT_MS:
          Deno.env.get("SALIX_VM_E2E_TIMEOUT_MS") ?? "300000",
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
    const configuredBase = Deno.env.get("SALIX_E2E_CF_GATEWAY_BASE_URL");
    const configuredSecret = Deno.env.get("SALIX_E2E_CF_GATEWAY_SECRET");

    if (configuredBase && configuredSecret) {
      env.SALIX_E2E_CF_GATEWAY_BASE_URL = configuredBase;
      env.SALIX_E2E_CF_GATEWAY_SECRET = configuredSecret;
    } else if (Deno.env.get("SALIX_VM_E2E_ENABLE_CLOUDFLARE") === "1") {
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
        stdout: "null",
        stderr: "null",
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
  const persistDir = await Deno.makeTempDir({ prefix: "salix-vm-gateway-" });
  const secret = `vm-e2e-${crypto.randomUUID()}`;
  let child: Deno.ChildProcess | undefined;

  try {
    try {
      await Deno.stat(`${WORKER_ROOT}/node_modules`);
    } catch {
      await run("npm", ["ci"], { cwd: WORKER_ROOT, timeoutMs: 180_000 });
    }

    await run("npm", ["run", "prepare:image"], {
      cwd: WORKER_ROOT,
      timeoutMs: 180_000,
    });

    child = new Deno.Command("npx", {
      cwd: WORKER_ROOT,
      args: [
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
      env: {
        ...Deno.env.toObject(),
        PATH: pathWithAsdf(),
      },
      stdout: "inherit",
      stderr: "inherit",
    }).spawn();

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
        await wrangler.status.catch(() => {});
        await Deno.remove(persistDir, { recursive: true }).catch(() => {});
      },
    };
  } catch (error) {
    if (child) {
      try {
        child.kill("SIGTERM");
      } catch {
        // Already exited.
      }
      await child.status.catch(() => {});
    }
    await Deno.remove(persistDir, { recursive: true }).catch(() => {});
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
  const conn = await Deno.connect({ hostname: target.hostname, port });

  try {
    const path = `${target.pathname}${target.search}`;
    const request = `GET ${path} HTTP/1.1\r\nHost: ${target.host}\r\nConnection: close\r\n\r\n`;
    await conn.write(new TextEncoder().encode(request));

    const buffer = new Uint8Array(512);
    const read = await Promise.race<number | null>([
      conn.read(buffer),
      delay(1_000).then(() => null),
    ]);

    if (!read) return false;

    const head = new TextDecoder().decode(buffer.subarray(0, read));
    return /^HTTP\/1\.[01] 2\d\d\b/.test(head);
  } finally {
    try {
      conn.close();
    } catch {
      // Already closed.
    }
  }
}

export async function run(
  command: string,
  args: string[],
  opts: RunOptions = {},
) {
  const stdoutMode = opts.stdout ?? "piped";
  const stderrMode = opts.stderr ?? "piped";

  let child: Deno.ChildProcess;
  try {
    child = new Deno.Command(command, {
      args,
      cwd: opts.cwd,
      env: opts.env,
      stdout: stdoutMode,
      stderr: stderrMode,
    }).spawn();
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

  const output = await child.output();
  clearTimeout(timer);

  const stdout =
    stdoutMode === "piped" && output.stdout
      ? new TextDecoder().decode(output.stdout)
      : "";
  const stderr =
    stderrMode === "piped" && output.stderr
      ? new TextDecoder().decode(output.stderr)
      : "";
  const combined = stdout + stderr;

  if ((!output.success || timedOut) && !opts.allowFailure) {
    throw new Error(
      [
        `command failed: ${command} ${args.join(" ")}`,
        `code=${output.code} timedOut=${timedOut}`,
        combined,
      ].join("\n"),
    );
  }

  return {
    success: output.success,
    code: output.code,
    stdout,
    stderr,
    combined,
  };
}

async function freePort() {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const port = (listener.addr as Deno.NetAddr).port;
  listener.close();
  return port;
}

function skipOrThrow(message: string) {
  if (Deno.env.get("SALIX_VM_E2E_STRICT") === "1") throw new Error(message);
  console.log(`VM_LIFECYCLE_E2E: SKIP ${message}`);
}

export function pathWithAsdf() {
  const path = Deno.env.get("PATH") ?? "";
  const home = Deno.env.get("HOME");
  if (!home) return path;
  return `${home}/.asdf/shims:${path}`;
}

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
