const SALIX_ROOT = new URL("../..", import.meta.url).pathname;
const DEFAULT_TIMEOUT_MS = 180_000;
const PAYLOAD_MB = Number(Deno.env.get("SALIX_E2E_PAYLOAD_MB") ?? "100");
const E2E_PERF_FACTOR = positiveNumber(Deno.env.get("E2E_PERF_FACTOR"), 1);

Deno.test({
  name: "large-file streaming transfer stays bounded without whole-file buffering",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const id = crypto.randomUUID().slice(0, 8);
    const minioName = `salix-e2e-minio-${id}`;
    const bucket = `salix-e2e-${id}`;
    const minioPort = reservePort();
    const httpPort = reservePort();
    const transferPort = reservePort();
    const peerHttpPort = reservePort();
    const peerTransferPort = reservePort();
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

      releasePorts(httpPort, transferPort, peerHttpPort, peerTransferPort);
      const output = await run(
        "elixir",
        [
          "--name",
          `salix_e2e_main_${id}@127.0.0.1`,
          "--cookie",
          "salix_e2e_cookie",
          "-S",
          "mix",
          "run",
          "scripts/streaming_copy_memory_demo.exs",
        ],
        {
          cwd: SALIX_ROOT,
          timeoutMs: DEFAULT_TIMEOUT_MS * E2E_PERF_FACTOR,
          env: {
            ...Deno.env.toObject(),
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
            SALIX_STREAM_COPY_SIZE_MB: String(PAYLOAD_MB),
            SALIX_E2E_PEER_HTTP_PORT: String(peerHttpPort.port),
            SALIX_E2E_PEER_TRANSFER_PORT: String(peerTransferPort.port),
          },
        },
      );

      assertIncludes(output.combined, "STREAMING_COPY_MEMORY_DEMO: PASS");
      assertIncludes(output.combined, `size=${PAYLOAD_MB * 1024 * 1024}`);

      const vfsToConnector = parseMetrics(output.combined, "vfs_to_connector");
      const remoteToRemoteSame = parseMetrics(
        output.combined,
        "remote_to_remote_same_connector",
      );
      const remoteToRemoteDifferent = parseMetrics(
        output.combined,
        "remote_to_remote_different_connectors",
      );
      const connectorToVfs = parseMetrics(output.combined, "connector_to_vfs");
      const remoteToRemoteCrossNode = parseMetrics(
        output.combined,
        "remote_to_remote_cross_node",
      );
      const remoteToRemoteCrossNodeReverse = parseMetrics(
        output.combined,
        "remote_to_remote_cross_node_reverse",
      );
      const payloadBytes = PAYLOAD_MB * 1024 * 1024;
      // A healthy local run usually completes this 100MB multi-leg streaming
      // flow in well under 30s. If it runs longer than that, investigate stream
      // backpressure/deadlock bugs before increasing timeouts.
      // CI runners can briefly throttle Docker/MinIO I/O; this test's primary
      // contract is bounded memory use, with duration kept only as a broad
      // streaming-regression guard.
      const maxCopyDurationMs = 90_000 * E2E_PERF_FACTOR;

      assertLessThan(
        vfsToConnector.beamDelta,
        payloadBytes / 2,
        "VFS→connector BEAM delta",
      );
      assertLessThan(
        remoteToRemoteSame.beamDelta,
        payloadBytes / 2,
        "remote→remote same-connector BEAM delta",
      );
      assertLessThan(
        remoteToRemoteDifferent.beamDelta,
        payloadBytes / 2,
        "remote→remote different-connectors BEAM delta",
      );
      assertLessThan(
        connectorToVfs.beamDelta,
        payloadBytes / 2,
        "connector→VFS BEAM delta",
      );
      assertLessThan(
        remoteToRemoteCrossNode.beamDelta,
        payloadBytes / 2,
        "remote→remote cross-node BEAM delta",
      );
      assertLessThan(
        remoteToRemoteCrossNodeReverse.beamDelta,
        payloadBytes / 2,
        "remote→remote cross-node reverse BEAM delta",
      );
      assertLessThan(
        vfsToConnector.connectorRssDeltaKb,
        PAYLOAD_MB * 512,
        "VFS→connector RSS delta",
      );
      assertLessThan(
        remoteToRemoteSame.connectorRssDeltaKb,
        PAYLOAD_MB * 512,
        "remote→remote same-connector RSS delta",
      );
      assertLessThan(
        remoteToRemoteDifferent.connectorRssDeltaKb,
        PAYLOAD_MB * 512,
        "remote→remote different-connectors RSS delta",
      );
      assertLessThan(
        connectorToVfs.connectorRssDeltaKb,
        PAYLOAD_MB * 512,
        "connector→VFS RSS delta",
      );
      assertLessThan(
        remoteToRemoteCrossNode.connectorRssDeltaKb,
        PAYLOAD_MB * 512,
        "remote→remote cross-node RSS delta",
      );
      assertLessThan(
        remoteToRemoteCrossNodeReverse.connectorRssDeltaKb,
        PAYLOAD_MB * 512,
        "remote→remote cross-node reverse RSS delta",
      );

      for (const label of [
        "vfs_to_connector",
        "remote_to_remote_same_connector",
        "remote_to_remote_different_connectors",
        "remote_to_remote_cross_node",
        "remote_to_remote_cross_node_reverse",
        "connector_to_vfs",
      ]) {
        assertLessThan(
          parseDuration(output.combined, label),
          maxCopyDurationMs,
          `${label} duration`,
        );
      }
    } finally {
      if (salixConfigPath) await Deno.remove(salixConfigPath).catch(() => {});
      await run("docker", ["rm", "-f", minioName], { allowFailure: true });
      releasePorts(
        minioPort,
        httpPort,
        transferPort,
        peerHttpPort,
        peerTransferPort,
      );
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
    prefix: "salix-e2e-config-",
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
  await run("docker", [
    "run",
    "--rm",
    "--network",
    `container:${containerName}`,
    "--entrypoint",
    "/bin/sh",
    "minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727",
    "-c",
    `mc alias set local http://127.0.0.1:9000 minioadmin minioadmin >/dev/null && mc mb -p local/${bucket}`,
  ]);
}

function parseMetrics(output: string, label: string) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const regex = new RegExp(
    `${escaped}:.*?beam_delta=(\\d+).*?connector_rss_delta_kb=(\\d+)`,
  );
  const match = output.match(regex);
  if (!match) throw new Error(`missing metrics line for ${label}\n${output}`);
  return {
    beamDelta: Number(match[1]),
    connectorRssDeltaKb: Number(match[2]),
  };
}

function parseDuration(output: string, label: string) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const regex = new RegExp(`${escaped}: duration_ms=(\\d+)`);
  const match = output.match(regex);
  if (!match) throw new Error(`missing duration line for ${label}\n${output}`);
  return Number(match[1]);
}

function positiveNumber(value: string | undefined, fallback: number) {
  if (value === undefined) return fallback;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function pathWithAsdf() {
  const path = Deno.env.get("PATH") ?? "";
  const home = Deno.env.get("HOME");
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

function assertLessThan(actual: number, maxExclusive: number, label: string) {
  if (!(actual < maxExclusive)) {
    throw new Error(`${label} too high: ${actual} >= ${maxExclusive}`);
  }
}

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
