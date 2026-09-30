import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve as resolvePath } from "node:path";
import { expect, test } from "@playwright/test";
import {
  WorkspaceConnectorRuntimeService,
  type ConnectorChildLike,
} from "../src/main/modules/connector-runtime";
import { MainProductCredentialAuthority } from "../src/main/modules/session/main-product-credential-authority";
import type { MainSessionTransportAuthority } from "../src/main/modules/session/main-session-transport";

const workspaceId = "wsp_connector_containment_e2e";
const ownerPath = resolvePath(
  __dirname,
  "fixtures/connector-runtime-containment/owner.mts"
);
const expiringChildPath = resolvePath(
  __dirname,
  "fixtures/connector-runtime-containment/expiring-child.mjs"
);
const clientsRoot = resolvePath(__dirname, "../../..");

test.describe.configure({ timeout: 30_000 });

test("a restart contains a real child from the spawn-before-PID crash window", async () => {
  const rootDir = await mkdtemp(join(tmpdir(), "comma-connector-containment-e2e-"));
  const connectorsRootDir = join(rootDir, "connectors");
  const localFileIndexRoot = join(rootDir, "local-file-index");
  const connectorFileRoot = join(rootDir, "home");
  const blockedMarkerPath = join(rootDir, "pid-persistence-blocked.json");
  const childStartedMarkerPath = join(rootDir, "child-started.json");
  const endpoint = await startConnectorTokenEndpoint();
  let owner: ChildProcess | undefined;
  let ownerStderr = "";
  let recovery: WorkspaceConnectorRuntimeService | undefined;
  let childPid: number | undefined;

  try {
    owner = spawn(process.execPath, ["--import", "tsx", ownerPath], {
      cwd: clientsRoot,
      env: {
        ...process.env,
        COMMA_CONNECTOR_CONTAINMENT_AUDIENCE: endpoint.baseUrl,
        COMMA_CONNECTOR_CONTAINMENT_BLOCKED_MARKER: blockedMarkerPath,
        COMMA_CONNECTOR_CONTAINMENT_CHILD_STARTED_MARKER: childStartedMarkerPath,
        COMMA_CONNECTOR_CONTAINMENT_CONNECTORS_ROOT: connectorsRootDir,
        COMMA_CONNECTOR_CONTAINMENT_FILE_ROOT: connectorFileRoot,
        COMMA_CONNECTOR_CONTAINMENT_LOCAL_FILE_INDEX_ROOT: localFileIndexRoot,
        COMMA_CONNECTOR_CONTAINMENT_WORKSPACE_ID: workspaceId,
      },
      stdio: ["ignore", "ignore", "pipe"],
    });
    owner.stderr?.on("data", (chunk: Buffer) => {
      ownerStderr += chunk.toString();
    });

    await expect
      .poll(async () => {
        if (owner?.exitCode !== null || owner.signalCode !== null) {
          throw new Error(`owner exited before the crash barrier: ${ownerStderr}`);
        }
        return readJsonIfPresent<CrashMarker>(blockedMarkerPath);
      })
      .not.toBeUndefined();

    const marker = JSON.parse(await readFile(blockedMarkerPath, "utf8")) as CrashMarker;
    const childStarted = JSON.parse(await readFile(childStartedMarkerPath, "utf8")) as {
      pid: number;
      runNonce: string;
    };
    childPid = marker.pid;
    expect(childStarted).toEqual({ pid: marker.pid, runNonce: marker.runNonce });
    expect(marker.binaryPath).toBe(await realpath(process.execPath));
    expect(marker.workspaceId).toBe(workspaceId);
    expect(existsSync(marker.pidEvidencePath)).toBe(false);
    expect(processExists(marker.pid)).toBe(true);

    const config = JSON.parse(await readFile(marker.configPath, "utf8")) as {
      connector: { connector_token: string };
    };
    const crashedToken = config.connector.connector_token;
    expect(crashedToken).toBe("salix_tok_containment_1");

    expect(owner.kill("SIGKILL")).toBe(true);
    await waitForExit(owner);
    // The deliberately stubborn detached helper proves this is not merely a
    // no-process recovery case: Main is gone, the child and token still live,
    // and there is no PID record to use as authority.
    expect(processExists(marker.pid)).toBe(true);
    expect(existsSync(marker.pidEvidencePath)).toBe(false);
    expect(existsSync(marker.runDir)).toBe(true);

    recovery = new WorkspaceConnectorRuntimeService({
      binaryPath: process.execPath,
      connectorFileRoot,
      connectorsRootDir,
      localFileIndexRoot,
      session: createSignedInSession(endpoint.baseUrl),
    });

    await expect
      .poll(() => endpoint.revocations)
      .toContainEqual({ token: crashedToken, workspaceId });
    await expect.poll(() => existsSync(marker.shutdownRequestPath)).toBe(true);

    const shutdownRequest = JSON.parse(
      await readFile(marker.shutdownRequestPath, "utf8")
    ) as { runNonce: string };
    expect(shutdownRequest.runNonce).toBe(marker.runNonce);
    expect(processExists(marker.pid)).toBe(true);
    expect(existsSync(marker.runDir)).toBe(true);
    const containedBeforeExit = JSON.parse(
      await readFile(join(marker.runDir, "run.json"), "utf8")
    ) as Record<string, unknown>;
    expect(containedBeforeExit.credentialContainedAtMs).toEqual(expect.any(Number));
    expect(containedBeforeExit.processAbsentAtMs).toBeUndefined();

    await expect.poll(() => processExists(marker.pid)).toBe(false);
    await expect.poll(() => existsSync(marker.runDir)).toBe(false);
    expect(endpoint.revocations).toEqual([{ token: crashedToken, workspaceId }]);
  } finally {
    await recovery?.close().catch(() => undefined);
    if (owner && owner.exitCode === null && owner.signalCode === null) {
      owner.kill("SIGKILL");
      await waitForExit(owner).catch(() => undefined);
    }
    if (childPid && processExists(childPid)) {
      try {
        process.kill(childPid, "SIGKILL");
      } catch {
        // It exited between the liveness check and cleanup.
      }
    }
    await endpoint.close();
    await rm(rootDir, { force: true, recursive: true });
  }
});

test("a rejected credential past its TTL cannot hold the workspace offline when revocation stays unconfirmed", async () => {
  // Observed on staging: the token expires after its TTL, the server rejects
  // it, the binary writes auth_required and exits, and DELETE /connector-token
  // then answers 400 internal_error indefinitely because the retired socket
  // owner's node left the cluster. The runtime must not retry that gate forever.
  const rootDir = await mkdtemp(join(tmpdir(), "comma-connector-expiry-e2e-"));
  const rejectedTokenPath = join(rootDir, "rejected-token");
  const endpoint = await startConnectorTokenEndpoint({ revocation: "reject" });
  const children: ChildProcess[] = [];
  let runtime: WorkspaceConnectorRuntimeService | undefined;

  try {
    runtime = new WorkspaceConnectorRuntimeService({
      backoffScheduleMs: [50],
      binaryPath: process.execPath,
      connectorFileRoot: join(rootDir, "home"),
      connectorsRootDir: join(rootDir, "connectors"),
      localFileIndexRoot: join(rootDir, "local-file-index"),
      readyTimeoutMs: 5_000,
      session: createSignedInSession(endpoint.baseUrl),
      spawnConnector: (input) => {
        // The real OS child follows the binary's local_file_read ordering.
        const child = spawn(
          process.execPath,
          [
            expiringChildPath,
            "--config",
            input.configPath,
            "--run-nonce",
            input.runNonce,
            "--shutdown-request-file",
            input.shutdownRequestPath,
            "--rejected-token-file",
            rejectedTokenPath,
          ],
          { stdio: "ignore" }
        );
        children.push(child);
        return realChild(child);
      },
      statusPollIntervalMs: 20,
      stopGraceMs: 500,
      tokenTtlSeconds: 1,
      // Production watchdog interval: the child's exit, not a poll, must be
      // what surfaces its final auth_required status.
    });

    await expect(runtime.registrationTarget(workspaceId)).resolves.toMatchObject({
      connectorRunId: "run_salix_tok_containment_1",
    });
    expect(children).toHaveLength(1);

    // The server now refuses the first credential: the child reports it and
    // exits at once, before Main's next status poll.
    await writeFile(rejectedTokenPath, "salix_tok_containment_1\n");
    await waitForExit(children[0]!);

    // At least two whole retire rounds refused the DELETE while the credential
    // was still inside its TTL, and no successor was minted.
    await expect.poll(() => endpoint.revocationAttempts()).toBeGreaterThanOrEqual(4);
    expect(endpoint.mintCount()).toBe(1);
    expect(children).toHaveLength(1);

    // After the TTL the credential is unredeemable by anyone; the entry mints
    // a replacement and reconnects without any restart or sign-out.
    await expect(runtime.registrationTarget(workspaceId)).resolves.toMatchObject({
      connectorRunId: "run_salix_tok_containment_2",
    });
    // The endpoint's own clock: the successor was only requested after the
    // first credential's requested TTL had elapsed.
    expect(endpoint.mintedAtMs[1]! - endpoint.mintedAtMs[0]!).toBeGreaterThanOrEqual(
      1_000
    );
    expect(endpoint.mintCount()).toBe(2);
    expect(endpoint.revocations).toEqual([]);
    expect(children).toHaveLength(2);
    expect(processExists(children[1]!.pid!)).toBe(true);
  } finally {
    await runtime?.close().catch(() => undefined);
    for (const child of children) {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }
    await endpoint.close();
    await rm(rootDir, { force: true, recursive: true });
  }
});

test("remote device installation copies the server command and revokes on copy failure", async () => {
  const rootDir = await mkdtemp(join(tmpdir(), "comma-connector-install-e2e-"));
  const endpoint = await startConnectorTokenEndpoint();
  const runtime = new WorkspaceConnectorRuntimeService({
    binaryPath: process.execPath,
    connectorFileRoot: join(rootDir, "home"),
    connectorsRootDir: join(rootDir, "connectors"),
    localFileIndexRoot: join(rootDir, "local-file-index"),
    session: createSignedInSession(endpoint.baseUrl),
  });
  try {
    let copied = "";
    await runtime.copyConnectCommand(workspaceId, (command) => {
      copied = command;
    });
    expect(copied).toBe("curl -fsSL https://install.invalid/device | sh");
    expect(endpoint.revocations).toEqual([]);

    await expect(
      runtime.copyConnectCommand(workspaceId, () => {
        throw new Error("clipboard unavailable");
      })
    ).rejects.toThrow("clipboard unavailable");
    expect(endpoint.revocations).toEqual([
      { token: "salix_tok_containment_2", workspaceId },
    ]);
  } finally {
    await runtime.close();
    await endpoint.close();
    await rm(rootDir, { force: true, recursive: true });
  }
});

interface CrashMarker {
  binaryPath: string;
  configPath: string;
  pid: number;
  pidEvidencePath: string;
  runDir: string;
  runNonce: string;
  shutdownRequestPath: string;
  workspaceId: string;
}

/** Supervises a real OS child through the runtime's child contract. */
function realChild(child: ChildProcess): ConnectorChildLike {
  return {
    get pid() {
      return child.pid;
    },
    once(_event, listener) {
      if (child.exitCode !== null || child.signalCode !== null) {
        listener();
        return this;
      }
      let settled = false;
      const settle = () => {
        if (settled) return;
        settled = true;
        listener();
      };
      child.once("exit", settle);
      child.once("error", settle);
      return this;
    },
    requestStop() {
      // Production closes the parent lifeline; the fixture also honours the
      // durable nonce request that the runtime persists before this call.
      child.kill("SIGTERM");
    },
    setScope() {},
  };
}

function createSignedInSession(audience: string): MainSessionTransportAuthority {
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: "connector_containment_e2e_recovery",
    trustedAudience: audience,
  });
  authority.acceptVerifiedCredential({
    audience,
    email: "connector-containment@comma.local",
    expiresAtEpochSeconds: 4_102_444_800,
    sessionId: "sess_connector_containment_recovery",
    token: "comma_session_connector_containment",
    userId: "usr_connector_containment",
  });
  return {
    authority,
    reportUnauthorized: async () => undefined,
  };
}

async function startConnectorTokenEndpoint({
  revocation = "confirm",
}: { revocation?: "confirm" | "reject" } = {}) {
  const revocations: Array<{ token: string; workspaceId: string }> = [];
  const mintedAtMs: number[] = [];
  let mintCount = 0;
  let revocationAttempts = 0;
  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url ?? "/", "http://127.0.0.1");
      const match = /^\/v1\/comma\/workspaces\/([^/]+)\/connector-token$/.exec(
        url.pathname
      );
      if (!match) {
        respondJson(response, 404, { error: "not_found" });
        return;
      }
      const requestWorkspaceId = decodeURIComponent(match[1]!);
      const body = JSON.parse(await readBody(request)) as Record<string, unknown>;
      if (request.method === "POST") {
        mintCount += 1;
        mintedAtMs.push(Date.now());
        respondJson(response, 201, {
          alias: "comma",
          device_id: `dev_containment_${mintCount}`,
          name: "Containment E2E connector",
          scope: "local_file_read",
          server: "wss://salix.invalid",
          token: `salix_tok_containment_${mintCount}`,
          ...(body.installation === true
            ? { install_command: "curl -fsSL https://install.invalid/device | sh" }
            : {}),
        });
        return;
      }
      if (request.method === "DELETE") {
        revocationAttempts += 1;
        if (revocation === "reject") {
          // The exact staging response while the retired socket owner's node
          // is unreachable: the product API collapses the reason to this.
          respondJson(response, 400, { error: "internal_error" });
          return;
        }
        revocations.push({
          token: String(body.token ?? ""),
          workspaceId: requestWorkspaceId,
        });
        respondJson(response, 200, { revoked: true });
        return;
      }
      respondJson(response, 405, { error: "method_not_allowed" });
    } catch (error) {
      respondJson(response, 500, { error: String(error) });
    }
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("Connector token E2E server did not bind a TCP port.");
  }
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    close: () => closeServer(server),
    mintCount: () => mintCount,
    mintedAtMs,
    revocationAttempts: () => revocationAttempts,
    revocations,
  };
}

function readBody(request: import("node:http").IncomingMessage) {
  return new Promise<string>((resolve, reject) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.once("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.once("error", reject);
  });
}

function respondJson(
  response: import("node:http").ServerResponse,
  status: number,
  body: unknown
) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

function closeServer(server: Server) {
  return new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

function waitForExit(child: ChildProcess) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise<void>((resolve, reject) => {
    child.once("exit", () => resolve());
    child.once("error", reject);
  });
}

function processExists(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

async function readJsonIfPresent<T>(path: string): Promise<T | undefined> {
  try {
    return JSON.parse(await readFile(path, "utf8")) as T;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}
