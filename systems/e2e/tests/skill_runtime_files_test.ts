const SALIX_ROOT = new URL("../..", import.meta.url).pathname;
const DEFAULT_TIMEOUT_MS = 120_000;

Deno.test({
  name: "skill runtime files work through real VFS and tool side-effect commits",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const id = crypto.randomUUID().slice(0, 8);
    const minioName = `skill-runtime-e2e-minio-${id}`;
    const bucket = `skill-runtime-e2e-${id}`;
    const minioPort = reservePort();
    let salixConfigPath: string | undefined;

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
      "minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e",
      "server",
      "/data",
    ]);

    try {
      const endpoint = `http://127.0.0.1:${minioPort.port}`;
      await waitForMinio(endpoint);
      await createBucket(minioName, bucket);
      salixConfigPath = await writeSalixConfig(endpoint, bucket);

      const output = await run(
        "mix",
        ["run", "scripts/skill_runtime_files_e2e.exs"],
        {
          cwd: SALIX_ROOT,
          timeoutMs: DEFAULT_TIMEOUT_MS,
          env: {
            ...Deno.env.toObject(),
            PATH: pathWithAsdf(),
            MIX_ENV: "test",
            SALIX_CONFIG_PATH: salixConfigPath,
            SALIX_S3_ENDPOINT: endpoint,
            SALIX_S3_ACCESS_KEY_ID: "minioadmin",
            SALIX_S3_SECRET_ACCESS_KEY: "minioadmin",
            SALIX_S3_REGION: "us-east-1",
            SALIX_S3_BUCKET: bucket,
            AWS_ACCESS_KEY_ID: "minioadmin",
            AWS_SECRET_ACCESS_KEY: "minioadmin",
            AWS_DEFAULT_REGION: "us-east-1",
          },
        },
      );

      assertIncludes(output.combined, "SKILL_RUNTIME_FILES_E2E: PASS");
    } finally {
      if (salixConfigPath) await Deno.remove(salixConfigPath).catch(() => {});
      await run("docker", ["rm", "-f", minioName], { allowFailure: true });
      releasePorts(minioPort);
    }
  },
});

type RunOptions = {
  cwd?: string;
  env?: Record<string, string>;
  timeoutMs?: number;
  allowFailure?: boolean;
};

type PortLease = {
  port: number;
  release: () => void;
};

function reservePort(): PortLease {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const port = (listener.addr as Deno.NetAddr).port;
  let released = false;

  return {
    port,
    release() {
      if (released) return;
      released = true;
      listener.close();
    },
  };
}

function releasePorts(...ports: PortLease[]) {
  for (const port of ports) port.release();
}

async function run(command: string, args: string[], opts: RunOptions = {}) {
  const child = new Deno.Command(command, {
    args,
    cwd: opts.cwd,
    env: opts.env,
    stdout: "piped",
    stderr: "piped",
  }).spawn();

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

  const stdout = new TextDecoder().decode(output.stdout);
  const stderr = new TextDecoder().decode(output.stderr);
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

  return { ...output, stdout, stderr, combined };
}

async function writeSalixConfig(endpoint: string, bucket: string) {
  const path = await Deno.makeTempFile({
    prefix: "skill-runtime-e2e-config-",
    suffix: ".json",
  });

  await Deno.writeTextFile(
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
      const response = await fetch(`${endpoint}/minio/health/ready`, {
        signal: AbortSignal.timeout(1_000),
      });
      if (response.ok) return;
    } catch {
      // Retry below.
    }
    await delay(250);
  }
  throw new Error(`MinIO did not become ready at ${endpoint}`);
}

async function createBucket(container: string, bucket: string) {
  await run("docker", [
    "exec",
    container,
    "mc",
    "alias",
    "set",
    "local",
    "http://127.0.0.1:9000",
    "minioadmin",
    "minioadmin",
  ]);

  await run("docker", ["exec", container, "mc", "mb", `local/${bucket}`]);
}

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function pathWithAsdf() {
  const home = Deno.env.get("HOME") ?? "";
  const current = Deno.env.get("PATH") ?? "";
  const candidates = [
    `${home}/.asdf/shims`,
    `${home}/.asdf/bin`,
    `${home}/.local/bin`,
    "/opt/homebrew/bin",
    "/usr/local/bin",
  ];

  return candidates.filter(Boolean).join(":") + ":" + current;
}

function assertIncludes(haystack: string, needle: string) {
  if (!haystack.includes(needle)) {
    throw new Error(`expected output to include ${needle}, got:\n${haystack}`);
  }
}
