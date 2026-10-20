import { rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createBucketArgs, MINIO_IMAGE } from "../helpers/minio.ts";

const SALIX_ROOT = new URL("../..", import.meta.url).pathname;
const DEFAULT_TIMEOUT_MS = 120_000;

export const remote = {
  name:
    "salix-connect Go connector works in remote mode, including managed read_ref",
  async fn() {
    const id = crypto.randomUUID().slice(0, 8);
    const minioName = `salix-connect-e2e-minio-${id}`;
    const bucket = `salix-connect-e2e-${id}`;
    const minioPort = reservePort();
    const httpPort = reservePort();
    const transferPort = reservePort();
    const bin = `/tmp/salix-connect-${id}`;
    let salixConfigPath: string | undefined;

    try {
      minioPort.release();
      await run("docker", [
        "run",
        "-d",
        "--rm",
        "--name",
        minioName,
        "-p",
        `${minioPort.port}:9000`,
        "-e",
        "MINIO_ROOT_USER=minioadmin",
        "-e",
        "MINIO_ROOT_PASSWORD=minioadmin",
        MINIO_IMAGE,
        "server",
        "/data",
      ]);

      const endpoint = `http://127.0.0.1:${minioPort.port}`;
      await waitForMinio(endpoint);
      await createBucket(minioName, bucket);
      salixConfigPath = await writeSalixConfig(endpoint, bucket);

      await run("go", ["build", "-o", bin, "."], {
        cwd: new URL("../../connector/salix-connect", import.meta.url).pathname,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });

      releasePorts(httpPort, transferPort);
      const output = await run(
        "mix",
        ["run", "scripts/salix_connect_e2e.exs"],
        {
          cwd: SALIX_ROOT,
          timeoutMs: DEFAULT_TIMEOUT_MS,
          env: {
            ...process.env,
            PATH: pathWithAsdf(),
            MIX_ENV: "test",
            SALIX_CONFIG_PATH: salixConfigPath,
            SALIX_API_TOKEN: "test-token",
            SALIX_HTTP_PORT: String(httpPort.port),
            SALIX_TRANSFER_PORT: String(transferPort.port),
            SALIX_S3_ENDPOINT: endpoint,
            SALIX_S3_ACCESS_KEY_ID: "minioadmin",
            SALIX_S3_SECRET_ACCESS_KEY: "minioadmin",
            SALIX_S3_REGION: "us-east-1",
            SALIX_S3_BUCKET: bucket,
            AWS_ACCESS_KEY_ID: "minioadmin",
            AWS_SECRET_ACCESS_KEY: "minioadmin",
            AWS_DEFAULT_REGION: "us-east-1",
            SALIX_CONNECT_BIN: bin,
          },
        },
      );

      assertIncludes(output.combined, "SALIX_CONNECT_E2E: PASS");
      assertIncludes(output.combined, "SALIX_CONNECT_READ_REF_E2E: PASS");
    } finally {
      if (salixConfigPath) await rm(salixConfigPath).catch(() => {});
      await rm(bin).catch(() => {});
      await run("docker", ["rm", "-f", minioName], { allowFailure: true });
      releasePorts(minioPort, httpPort, transferPort);
    }
  },
};

type RunOptions = {
  cwd?: string;
  env?: Record<string, string | undefined>;
  timeoutMs?: number;
  allowFailure?: boolean;
};

type PortLease = {
  port: number;
  release: () => void;
};

function reservePort(): PortLease {
  const listener = Bun.listen({
    hostname: "127.0.0.1",
    port: 0,
    socket: { data() {} },
  });
  const port = listener.port;
  let released = false;

  return {
    port,
    release() {
      if (released) return;
      released = true;
      listener.stop(true);
    },
  };
}

function releasePorts(...ports: PortLease[]) {
  for (const port of ports) port.release();
}

async function run(command: string, args: string[], opts: RunOptions = {}) {
  const child = Bun.spawn([command, ...args], {
    cwd: opts.cwd,
    env: { ...process.env, ...opts.env },
    stdout: "pipe",
    stderr: "pipe",
  });

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
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
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

  return { success: code === 0, code, stdout, stderr, combined };
}

async function writeSalixConfig(endpoint: string, bucket: string) {
  const path = join(tmpdir(), `salix-connect-e2e-config-${bucket}.json`);

  await writeFile(
    path,
    JSON.stringify({
      storage: {
        endpoint,
        region: "us-east-1",
        bucket,
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
      },
    }),
  );

  return path;
}

async function waitForMinio(endpoint: string) {
  for (let i = 0; i < 120; i++) {
    try {
      const response = await fetch(`${endpoint}/minio/health/live`, {
        signal: AbortSignal.timeout(1_000),
      });
      if (response.ok) return;
    } catch {
      // Retry below.
    }
    await delay(500);
  }

  throw new Error(`timed out waiting for MinIO at ${endpoint}`);
}

async function createBucket(containerName: string, bucket: string) {
  await run("docker", createBucketArgs(containerName, bucket));
}

function pathWithAsdf() {
  const path = process.env.PATH ?? "";
  const home = process.env.HOME;
  if (!home) return path;
  return `${home}/.asdf/shims:${path}`;
}

function assertIncludes(haystack: string, needle: string) {
  if (!haystack.includes(needle)) {
    throw new Error(
      `expected output to include ${JSON.stringify(needle)}\n${haystack}`,
    );
  }
}

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
