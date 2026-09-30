import { EventEmitter } from "node:events";
import { execFileSync, spawn as spawnProcess } from "node:child_process";
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MainProductCredentialAuthority } from "../modules/session/main-product-credential-authority";
import type { MainSessionTransportAuthority } from "../modules/session/main-session-transport";
import {
  createConnectorSpawnPlan,
  spawnConnectorProcess,
  WorkspaceConnectorRuntimeService,
  type ConnectorChildLike,
  type EnumerateConnectorProcesses,
  type InspectProcess,
  type PersistConnectorContainmentEvidence,
  type SpawnConnectorChild,
  type WorkspaceConnectorScopeSnapshot,
} from "../modules/connector-runtime";

const AUDIENCE = "https://comma.test";

let tempDir = "";

beforeEach(async () => {
  tempDir = await mkdtemp(join(tmpdir(), "comma-connector-runtime-"));
  await writeFile(join(tempDir, "salix-connect"), "#!/bin/sh\n", { mode: 0o755 });
  await writeFile(join(tempDir, "synch"), "#!/bin/sh\n", { mode: 0o755 });
});

afterEach(async () => {
  await rm(tempDir, { force: true, recursive: true });
});

class FakeConnectorChild extends EventEmitter implements ConnectorChildLike {
  static nextPid = 40_000;
  readonly configPath: string;
  exited = false;
  readonly pid = (FakeConnectorChild.nextPid += 1);
  stopRequests = 0;
  scopeRequests: Array<"" | "local_file_read"> = [];
  ignoreStopRequest = false;

  constructor(configPath: string) {
    super();
    this.configPath = configPath;
  }

  requestStop() {
    this.stopRequests += 1;
    if (this.ignoreStopRequest) return;
    queueMicrotask(() => this.exit());
  }

  setScope(scope: "" | "local_file_read") {
    this.scopeRequests.push(scope);
  }

  exit() {
    if (this.exited) return;
    this.exited = true;
    this.emit("exit");
  }
}

function createSessionHarness() {
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: "auth_test",
    trustedAudience: AUDIENCE,
  });
  const signIn = (sessionId: string, token: string) =>
    authority.acceptVerifiedCredential({
      audience: AUDIENCE,
      email: "user@example.com",
      expiresAtEpochSeconds: 4_102_444_800,
      sessionId,
      token,
      userId: "usr_1",
    });
  signIn("sess_1", "comma_sess_token_1");
  const session: MainSessionTransportAuthority = {
    authority,
    reportUnauthorized: vi.fn(async () => undefined),
  };
  return { authority, session, signIn };
}

function createTokenEndpoint({
  failFirst = 0,
  failRevocations = 0,
  rejectStableDevice = false,
}: {
  failFirst?: number;
  failRevocations?: number;
  rejectStableDevice?: boolean;
} = {}) {
  const requests: {
    authorization: string | null;
    body: Record<string, unknown>;
    workspaceId: string;
  }[] = [];
  const revocations: { token: string; workspaceId: string }[] = [];
  const mintedAtMs: number[] = [];
  let failures = failFirst;
  let revocationFailures = failRevocations;
  let revocationAttempts = 0;
  let minted = 0;
  const fetchImpl = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(
      typeof input === "string" || input instanceof URL ? String(input) : input.url
    );
    const match = url.pathname.match(
      /^\/v1\/comma\/workspaces\/([^/]+)\/connector-token$/
    );
    if (!match) {
      return new Response(JSON.stringify({ error: "not_found" }), { status: 404 });
    }
    const workspaceId = decodeURIComponent(match[1]!);
    const body = JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;

    if (init?.method === "DELETE") {
      revocationAttempts += 1;
      if (revocationFailures > 0) {
        revocationFailures -= 1;
        return new Response(JSON.stringify({ error: "unavailable" }), { status: 503 });
      }
      revocations.push({ token: String(body.token ?? ""), workspaceId });
      return new Response(JSON.stringify({ revoked: true }), {
        headers: { "content-type": "application/json" },
        status: 200,
      });
    }
    if (init?.method !== "POST") {
      return new Response(JSON.stringify({ error: "not_found" }), { status: 404 });
    }
    const headers = new Headers(init.headers);
    requests.push({
      authorization: headers.get("authorization"),
      body,
      workspaceId,
    });
    if (rejectStableDevice && typeof body.stable_device_id === "string") {
      // The server's explicit machine-readable refusal of this stable device.
      return new Response(JSON.stringify({ error: "stable_device_unavailable" }), {
        status: 403,
      });
    }
    if (failures > 0) {
      failures -= 1;
      return new Response(JSON.stringify({ error: "unavailable" }), { status: 503 });
    }
    minted += 1;
    mintedAtMs.push(Date.now());
    return new Response(
      JSON.stringify({
        alias: "comma",
        device_id:
          typeof body.stable_device_id === "string"
            ? body.stable_device_id
            : `dev_minted_${minted}`,
        name: "Test Workspace Connector",
        ...(typeof body.scope === "string" ? { scope: body.scope } : {}),
        server: "wss://salix.test",
        token: `salix_tok_${minted}`,
        ...(body.installation === true
          ? { install_command: `server-install-command-${minted}` }
          : {}),
      }),
      { headers: { "content-type": "application/json" }, status: 201 }
    );
  });
  return {
    fetchImpl,
    mintCount: () => minted,
    mintedAtMs,
    revocationAttemptCount: () => revocationAttempts,
    requests,
    revocations,
  };
}

function createRuntimeHarness(
  options: {
    backoffScheduleMs?: readonly number[];
    enumerateProcesses?: EnumerateConnectorProcesses;
    failFirstMints?: number;
    failRevocations?: number;
    inspectProcess?: InspectProcess;
    maxWorkspaces?: number;
    readyTimeoutMs?: number;
    rejectStableDevice?: boolean;
    tokenTtlSeconds?: number;
    staticStatusFilePath?: string;
    binaryPath?: string | undefined;
    synchBinaryPath?: string | undefined;
    synchDataDir?: string | undefined;
    clientControl?: (() => { endpoint: string; token: string } | undefined) | undefined;
    processPlatform?: NodeJS.Platform;
    onSpawn?: (input: Parameters<SpawnConnectorChild>[0]) => void;
    onScopeStateChanged?: (snapshot: WorkspaceConnectorScopeSnapshot) => void;
    persistContainmentEvidence?: PersistConnectorContainmentEvidence;
    spawnConnector?: SpawnConnectorChild;
  } = {}
) {
  const { authority, session, signIn } = createSessionHarness();
  const endpoint = createTokenEndpoint({
    failFirst: options.failFirstMints ?? 0,
    failRevocations: options.failRevocations ?? 0,
    rejectStableDevice: options.rejectStableDevice ?? false,
  });
  const children: FakeConnectorChild[] = [];
  const spawnInputs: Parameters<SpawnConnectorChild>[0][] = [];
  const runtime = new WorkspaceConnectorRuntimeService({
    backoffScheduleMs: options.backoffScheduleMs ?? [10, 20],
    binaryPath:
      "binaryPath" in options ? options.binaryPath : join(tempDir, "salix-connect"),
    connectorFileRoot: join(tempDir, "home"),
    connectorsRootDir: join(tempDir, "connectors"),
    ...(options.clientControl ? { clientControl: options.clientControl } : {}),
    ...(options.enumerateProcesses
      ? { enumerateProcesses: options.enumerateProcesses }
      : {}),
    fetch: endpoint.fetchImpl as typeof fetch,
    ...(options.inspectProcess ? { inspectProcess: options.inspectProcess } : {}),
    localFileIndexRoot: join(tempDir, "local-file-index"),
    runtimeNamespace: "@comma-staging",
    runtimeRoot: join(tempDir, "@comma-staging"),
    synchBinaryPath:
      "synchBinaryPath" in options ? options.synchBinaryPath : join(tempDir, "synch"),
    synchDataDir:
      "synchDataDir" in options ? options.synchDataDir : join(tempDir, "synchronicity"),
    maxWorkspaces: options.maxWorkspaces ?? 3,
    ...(options.onScopeStateChanged
      ? { onScopeStateChanged: options.onScopeStateChanged }
      : {}),
    ...(options.persistContainmentEvidence
      ? { persistContainmentEvidence: options.persistContainmentEvidence }
      : {}),
    ...(options.processPlatform ? { processPlatform: options.processPlatform } : {}),
    readyTimeoutMs: options.readyTimeoutMs ?? 2_000,
    session,
    spawnConnector: (input) => {
      spawnInputs.push(input);
      options.onSpawn?.(input);
      if (options.spawnConnector) return options.spawnConnector(input);
      const child = new FakeConnectorChild(input.configPath);
      children.push(child);
      return child;
    },
    staticStatusFilePath: options.staticStatusFilePath,
    statusPollIntervalMs: 10,
    stopGraceMs: 50,
    ...(options.tokenTtlSeconds !== undefined
      ? { tokenTtlSeconds: options.tokenTtlSeconds }
      : {}),
    watchdogIntervalMs: 20,
  });
  return { authority, children, endpoint, runtime, session, signIn, spawnInputs };
}

async function writeConnectedStatus(
  configPath: string,
  overrides: Record<string, unknown> = {}
) {
  await writeFile(
    `${configPath}.status.json`,
    JSON.stringify({
      connector_run_id: "run_live",
      device_id: "dev_live",
      local_file_index_version: 2,
      scope: "local_file_read",
      state: "connected",
      updated_at: Math.floor(Date.now() / 1000),
      ...overrides,
    })
  );
}

const noMatchingConnectorProcesses: EnumerateConnectorProcesses = async () => ({
  complete: true,
  processes: [],
});

describe("WorkspaceConnectorRuntimeService", () => {
  it("uses an explicit named-pipe lifeline in the Windows spawn contract", () => {
    const runNonce = "0123456789abcdef0123456789abcdef";
    const configPath = "C:\\Users\\Comma User\\connector.json";
    const shutdownRequestPath = "C:\\Users\\Comma User\\shutdown-request.json";
    const plan = createConnectorSpawnPlan(
      { configPath, parentLifelineFd: 3, runNonce, shutdownRequestPath },
      "win32",
      42
    );

    expect(plan).toEqual({
      args: [
        "--config",
        configPath,
        "--run-nonce",
        runNonce,
        "--shutdown-request-file",
        shutdownRequestPath,
        "--parent-lifeline-pipe",
        `\\\\.\\pipe\\comma-salix-parent-42-${runNonce}`,
      ],
      lifeline: {
        kind: "named_pipe",
        pipePath: `\\\\.\\pipe\\comma-salix-parent-42-${runNonce}`,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
  });

  it("rejects a scope write when the production child control pipe fails", async () => {
    const marker = join(tempDir, "stdin-closed");
    const binaryPath = join(tempDir, "close-stdin-connector");
    await writeFile(
      binaryPath,
      `#!/bin/sh\nexec 0<&-\nprintf ready > ${JSON.stringify(marker)}\nIFS= read -r _ <&3\n`,
      { mode: 0o755 }
    );
    const child = spawnConnectorProcess({
      binaryPath,
      cliDir: tempDir,
      configPath: join(tempDir, "scope-write.json"),
      logPath: join(tempDir, "scope-write.log"),
      parentLifelineFd: 3,
      runNonce: "0123456789abcdef0123456789abcdef",
      shutdownRequestPath: join(tempDir, "scope-write.stop.json"),
      synchDataDir: join(tempDir, "synchronicity"),
    });
    const exited = new Promise<void>((resolve) => child.once("exit", resolve));
    try {
      await vi.waitFor(() => expect(existsSync(marker)).toBe(true));
      await expect(Promise.resolve(child.setScope(""))).rejects.toBeInstanceOf(Error);
    } finally {
      child.requestStop();
    }
    await exited;
  });

  it("puts the bundled synch CLI and Comma node data dir in the env.exec environment", async () => {
    const marker = join(tempDir, "env-exec-synch.txt");
    const cliDir = join(tempDir, "bin");
    await mkdir(cliDir);
    await writeFile(
      join(cliDir, "synch"),
      `#!/bin/sh\nprintf 'origin: key:comma\\ndata-dir: %s\\n' "$SYNCH_DATA_DIR"\n`,
      { mode: 0o755 }
    );
    const binaryPath = join(tempDir, "env-connector");
    await writeFile(
      binaryPath,
      `#!/bin/sh\n{ command -v synch; synch id; } > ${JSON.stringify(marker)}\n`,
      { mode: 0o755 }
    );
    const synchDataDir = join(tempDir, "Comma Data", "synchronicity");
    const child = spawnConnectorProcess({
      binaryPath,
      cliDir,
      configPath: join(tempDir, "env-connector.json"),
      logPath: join(tempDir, "env-connector.log"),
      parentLifelineFd: 3,
      runNonce: "0123456789abcdef0123456789abcdef",
      shutdownRequestPath: join(tempDir, "env-connector.stop.json"),
      synchDataDir,
    });
    const exited = new Promise<void>((resolve) => child.once("exit", resolve));
    try {
      await exited;
      const output = await readFile(marker, "utf8");
      expect(output).toContain(join(cliDir, "synch"));
      expect(output).toContain("origin: key:comma");
      expect(output).toContain(`data-dir: ${synchDataDir}`);
    } finally {
      child.requestStop();
    }
    await exited;
  });

  it("writes a private synch wrapper beside comma before the workspace child starts", async () => {
    const synchBinaryPath = join(tempDir, "synch real");
    await writeFile(synchBinaryPath, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n", {
      mode: 0o755,
    });
    const harness = createRuntimeHarness({
      synchBinaryPath,
      synchDataDir: join(tempDir, "node"),
    });
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.spawnInputs).toHaveLength(1), {
      timeout: 5_000,
    });
    const input = harness.spawnInputs[0]!;
    expect(
      execFileSync(join(input.cliDir, "synch"), ["id", "argument with spaces"], {
        encoding: "utf8",
      })
    ).toBe("id\nargument with spaces\n");
    expect(input.synchDataDir).toBe(join(tempDir, "node"));
    await writeConnectedStatus(input.configPath);
    await pending;
    await harness.runtime.close();
  });

  it("allows operations by default with one full short-lived token", async () => {
    let evidenceObservedBeforeSpawn: Record<string, unknown> | undefined;
    const harness = createRuntimeHarness({
      onSpawn: (input) => {
        evidenceObservedBeforeSpawn = JSON.parse(
          readFileSync(join(dirname(input.configPath), "run.json"), "utf8")
        ) as Record<string, unknown>;
      },
    });
    const pending = harness.runtime.registrationTarget("wsp_alpha");

    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    const child = harness.children[0]!;
    const config = JSON.parse(await readFile(child.configPath, "utf8")) as {
      connector: Record<string, unknown>;
      electron: Record<string, unknown>;
    };
    expect(config.connector).toMatchObject({
      connector_token: "salix_tok_1",
      reconnect: true,
      root: join(tempDir, "home"),
      scope: "",
      server: "wss://salix.test",
    });
    expect(config.electron).toEqual({
      local_file_index_root: join(tempDir, "local-file-index"),
      run_nonce: expect.stringMatching(/^[a-f0-9]{32}$/),
      runtime_namespace: "@comma-staging",
      runtime_root: join(tempDir, "@comma-staging"),
    });
    const evidence = JSON.parse(
      await readFile(join(dirname(child.configPath), "run.json"), "utf8")
    ) as Record<string, unknown>;
    const resolvedBinaryPath = await realpath(join(tempDir, "salix-connect"));
    expect(evidence).toMatchObject({
      binaryPath: resolvedBinaryPath,
      configPath: child.configPath,
      runNonce: config.electron.run_nonce,
      shutdownRequestPath: join(dirname(child.configPath), "shutdown-request.json"),
      workspaceId: "wsp_alpha",
    });
    expect(evidenceObservedBeforeSpawn).toEqual(evidence);
    expect(harness.spawnInputs[0]).toMatchObject({
      binaryPath: resolvedBinaryPath,
      configPath: child.configPath,
      parentLifelineFd: 3,
      runNonce: config.electron.run_nonce,
      shutdownRequestPath: join(dirname(child.configPath), "shutdown-request.json"),
    });
    expect(harness.endpoint.requests[0]).toMatchObject({
      authorization: "Bearer comma_sess_token_1",
      body: { expires_in_seconds: 7_200 },
      workspaceId: "wsp_alpha",
    });
    expect(harness.endpoint.requests[0]?.body).not.toHaveProperty("scope");

    await writeConnectedStatus(child.configPath, { scope: "" });
    await expect(pending).resolves.toEqual({
      connectorRunId: "run_live",
      deviceId: "dev_live",
      localFileIndexVersion: 2,
    });

    // A second demand reuses the running connector without minting again.
    await expect(
      harness.runtime.registrationTarget("wsp_alpha")
    ).resolves.toMatchObject({ connectorRunId: "run_live" });
    expect(harness.children).toHaveLength(1);
    expect(harness.endpoint.mintCount()).toBe(1);

    await harness.runtime.close();
  });

  it("never spawns a Comma child before both client-control credentials are ready", async () => {
    let clientControl: { endpoint: string; token: string } | undefined;
    const harness = createRuntimeHarness({
      backoffScheduleMs: [10],
      clientControl: () => clientControl,
    });
    const pending = harness.runtime.registrationTarget("wsp_alpha");

    await vi.waitFor(() =>
      expect(harness.runtime.state()[0]?.lastError).toMatch(/endpoint is not ready/i)
    );
    expect(harness.endpoint.mintCount()).toBe(0);
    expect(harness.children).toHaveLength(0);
    expect(harness.spawnInputs).toHaveLength(0);

    clientControl = {
      endpoint: "http://127.0.0.1:43199",
      token: "main-control-token",
    };
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    expect(harness.spawnInputs[0]?.clientControl).toEqual(clientControl);
    await writeConnectedStatus(harness.children[0]!.configPath);
    await expect(pending).resolves.toMatchObject({ connectorRunId: "run_live" });
    await harness.runtime.close();
  });

  it("copies a fresh remote device command without starting or reusing the local device", async () => {
    const harness = createRuntimeHarness();
    const copy = vi.fn();
    await harness.runtime.copyConnectCommand("wsp_remote", copy);
    expect(harness.endpoint.requests[0]).toMatchObject({ workspaceId: "wsp_remote" });
    expect(harness.endpoint.requests[0]?.body).not.toHaveProperty("stable_device_id");
    expect(harness.endpoint.requests[0]?.body.installation).toBe(true);
    expect(copy).toHaveBeenCalledWith("server-install-command-1");
    expect(harness.children).toHaveLength(0);
    await harness.runtime.close();
  });

  it("revokes a new remote credential when its command cannot be copied", async () => {
    const harness = createRuntimeHarness();
    await expect(
      harness.runtime.copyConnectCommand("wsp_remote", () => {
        throw new Error("clipboard unavailable");
      })
    ).rejects.toThrow("clipboard unavailable");
    expect(harness.endpoint.revocations).toEqual([
      { workspaceId: "wsp_remote", token: "salix_tok_1" },
    ]);
    await harness.runtime.close();
  });

  it("changes only the explicitly targeted workspace child scope without recycling", async () => {
    const harness = createRuntimeHarness();
    const alphaPending = harness.runtime.registrationTarget("wsp_alpha");
    const betaPending = harness.runtime.registrationTarget("wsp_beta");

    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    const childrenByWorkspace = new Map(
      await Promise.all(
        harness.children.map(async (child) => {
          const evidence = JSON.parse(
            await readFile(join(dirname(child.configPath), "run.json"), "utf8")
          ) as { workspaceId: string };
          return [evidence.workspaceId, child] as const;
        })
      )
    );
    const alpha = childrenByWorkspace.get("wsp_alpha");
    const beta = childrenByWorkspace.get("wsp_beta");
    expect(alpha).toBeDefined();
    expect(beta).toBeDefined();
    await writeConnectedStatus(alpha!.configPath, { scope: "local_file_read" });
    await writeConnectedStatus(beta!.configPath, { scope: "local_file_read" });
    await Promise.all([alphaPending, betaPending]);

    alpha!.setScope = vi.fn(async (scope: "" | "local_file_read") => {
      alpha!.scopeRequests.push(scope);
      await writeConnectedStatus(alpha!.configPath, { scope });
    });

    await expect(harness.runtime.setScope("wsp_alpha", "")).resolves.toEqual({
      available: true,
      deviceId: "dev_live",
      scope: "",
      workspaceId: "wsp_alpha",
    });
    expect(alpha!.scopeRequests).toEqual([""]);
    expect(beta!.scopeRequests).toEqual([]);
    expect(harness.endpoint.mintCount()).toBe(2);
    expect(harness.children).toHaveLength(2);
    await expect(harness.runtime.scope("wsp_beta")).resolves.toMatchObject({
      available: true,
      scope: "local_file_read",
    });

    await harness.runtime.close();
  });

  it("setScope ensures the exact workspace child before any attachment demand", async () => {
    const harness = createRuntimeHarness();
    const pending = harness.runtime.setScope("wsp_fresh", "");

    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    const child = harness.children[0]!;
    child.setScope = vi.fn(async (scope: "" | "local_file_read") => {
      child.scopeRequests.push(scope);
      await writeConnectedStatus(child.configPath, { scope });
    });
    await writeConnectedStatus(child.configPath, { scope: "local_file_read" });

    await expect(pending).resolves.toEqual({
      available: true,
      deviceId: "dev_live",
      scope: "",
      workspaceId: "wsp_fresh",
    });
    expect(child.scopeRequests).toEqual([""]);
    expect(harness.endpoint.mintCount()).toBe(1);
    await harness.runtime.close();
  });

  it("restores persisted Full Access after a child restart without a renderer request", async () => {
    const snapshots: WorkspaceConnectorScopeSnapshot[] = [];
    const harness = createRuntimeHarness({
      onScopeStateChanged: (snapshot) => snapshots.push(snapshot),
    });
    const initial = harness.runtime.scope("wsp_restart");

    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    const first = harness.children[0]!;
    await writeConnectedStatus(first.configPath, { scope: "local_file_read" });
    await expect(initial).resolves.toMatchObject({
      available: true,
      scope: "local_file_read",
    });

    first.setScope = vi.fn(async (scope: "" | "local_file_read") => {
      first.scopeRequests.push(scope);
      await writeConnectedStatus(first.configPath, { scope });
    });
    await expect(harness.runtime.setScope("wsp_restart", "")).resolves.toMatchObject({
      available: true,
      scope: "",
    });
    expect(
      snapshots.at(-1)?.scopes.find(({ workspaceId }) => workspaceId === "wsp_restart")
    ).toMatchObject({ available: true, scope: "" });

    first.exit();
    await vi.waitFor(() => {
      expect(
        snapshots
          .flatMap(({ scopes }) => scopes)
          .some(
            (scope) =>
              scope.workspaceId === "wsp_restart" &&
              !scope.available &&
              scope.scope === ""
          )
      ).toBe(true);
    });
    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[1]!.configPath, {
      scope: "",
    });
    await vi.waitFor(() => {
      expect(
        snapshots
          .at(-1)
          ?.scopes.find(({ workspaceId }) => workspaceId === "wsp_restart")
      ).toMatchObject({ available: true, scope: "" });
    });

    await harness.runtime.close();
  });

  it.each(["", "local_file_read"] as const)(
    "restores the saved scope %j after Electron Main restarts",
    async (savedScope) => {
      const first = createRuntimeHarness();
      const initial = first.runtime.scope("wsp_persisted");
      await vi.waitFor(() => expect(first.children).toHaveLength(1), {
        timeout: 5_000,
      });
      const firstChild = first.children[0]!;
      await writeConnectedStatus(firstChild.configPath, {
        scope: savedScope === "" ? "local_file_read" : "",
      });
      await initial;
      firstChild.setScope = vi.fn(async (scope: "" | "local_file_read") => {
        firstChild.scopeRequests.push(scope);
        await writeConnectedStatus(firstChild.configPath, { scope });
      });
      await expect(
        first.runtime.setScope("wsp_persisted", savedScope)
      ).resolves.toMatchObject({
        available: true,
        scope: savedScope,
      });
      await first.runtime.close();

      const restarted = createRuntimeHarness();
      const restored = restarted.runtime.scope("wsp_persisted");
      await vi.waitFor(() => expect(restarted.children).toHaveLength(1), {
        timeout: 5_000,
      });
      const restartedChild = restarted.children[0]!;
      const config = JSON.parse(await readFile(restartedChild.configPath, "utf8")) as {
        connector: { scope: string };
      };
      expect(config.connector.scope).toBe(savedScope);
      await writeConnectedStatus(restartedChild.configPath, { scope: savedScope });
      await expect(restored).resolves.toMatchObject({
        available: true,
        scope: savedScope,
      });

      await restarted.runtime.close();
    }
  );

  it("keeps operations disabled when the saved permission file is corrupt", async () => {
    const first = createRuntimeHarness();
    const initial = first.runtime.registrationTarget("wsp_corrupt");
    await vi.waitFor(() => expect(first.children).toHaveLength(1));
    const firstChild = first.children[0]!;
    await writeConnectedStatus(firstChild.configPath);
    await initial;
    await first.runtime.close();
    const workspaceDir = dirname(dirname(dirname(firstChild.configPath)));
    await writeFile(join(workspaceDir, "scope.json"), "invalid json");

    const restarted = createRuntimeHarness();
    const restored = restarted.runtime.scope("wsp_corrupt");
    await vi.waitFor(() => expect(restarted.children).toHaveLength(1));
    const child = restarted.children[0]!;
    const config = JSON.parse(await readFile(child.configPath, "utf8"));
    expect(config.connector.scope).toBe("local_file_read");
    await writeConnectedStatus(child.configPath);
    await expect(restored).resolves.toMatchObject({
      available: true,
      scope: "local_file_read",
    });
    await restarted.runtime.close();
  });

  it("re-attaches the stable device identity the connected run registered", async () => {
    const harness = createRuntimeHarness();
    const first = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[0]!.configPath);
    await first;
    expect(harness.endpoint.requests[0]!.body.stable_device_id).toBeUndefined();

    harness.children[0]!.exit();

    const second = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    // The committed refs stay materializable because the replacement token is
    // minted against the exact device the first CONNECTED run registered —
    // identity becomes durable at connect, never at mint.
    expect(harness.endpoint.requests[1]!.body.stable_device_id).toBe("dev_live");
    await writeConnectedStatus(harness.children[1]!.configPath);
    await second;

    await harness.runtime.close();
  });

  it("never persists a device identity the registry has not seen", async () => {
    let spawnCount = 0;
    let secondStatusWrite = Promise.resolve();
    const harness = createRuntimeHarness({
      onSpawn: (input) => {
        spawnCount += 1;
        if (spawnCount === 2) {
          secondStatusWrite = writeConnectedStatus(input.configPath);
        }
      },
      readyTimeoutMs: 150,
    });
    // First attempt mints but the child never connects: no registry record,
    // so nothing may become durable.
    const first = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    await expect(first).resolves.toBeNull();
    harness.children[0]!.exit();

    const second = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children.length).toBeGreaterThanOrEqual(2), {
      timeout: 5_000,
    });
    // The retry must not request reuse of the unregistered identity —
    // that request could only be refused and would wedge the workspace.
    for (const request of harness.endpoint.requests) {
      expect(request.body.stable_device_id).toBeUndefined();
    }
    await secondStatusWrite;
    await expect(second).resolves.toMatchObject({ connectorRunId: "run_live" });

    await harness.runtime.close();
  });

  it("discards a stored device the server refuses and mints a fresh one", async () => {
    const harness = createRuntimeHarness({ rejectStableDevice: true });
    const workspaceDirRoot = join(tempDir, "connectors");
    await mkdir(workspaceDirRoot, { recursive: true });
    // Simulate a stored identity a different account owns now.
    const first = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[0]!.configPath);
    await first;
    harness.children[0]!.exit();

    const second = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    const retryBodies = harness.endpoint.requests.map(
      (request) => request.body.stable_device_id
    );
    // Second attempt tried the stored device, was refused, then minted fresh.
    expect(retryBodies).toEqual([undefined, "dev_live", undefined]);
    await writeConnectedStatus(harness.children[1]!.configPath);
    await second;

    await harness.runtime.close();
  });

  it("revokes the outstanding token before re-minting and at teardown", async () => {
    const harness = createRuntimeHarness();
    const first = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[0]!.configPath);
    await first;

    harness.runtime.recycle("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    await vi.waitFor(
      () =>
        expect(harness.endpoint.revocations).toContainEqual({
          token: "salix_tok_1",
          workspaceId: "wsp_alpha",
        }),
      { timeout: 5_000 }
    );

    await writeConnectedStatus(harness.children[1]!.configPath, {
      connector_run_id: "run_recycled",
    });
    await expect(
      harness.runtime.registrationTarget("wsp_alpha")
    ).resolves.toMatchObject({ connectorRunId: "run_recycled" });

    await harness.runtime.close();
    await vi.waitFor(
      () =>
        expect(harness.endpoint.revocations).toContainEqual({
          token: "salix_tok_2",
          workspaceId: "wsp_alpha",
        }),
      { timeout: 5_000 }
    );
  });

  it("keeps the old token and config until revocation succeeds before re-minting", async () => {
    const harness = createRuntimeHarness({
      backoffScheduleMs: [10_000],
      failRevocations: 2,
    });
    const first = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    const firstConfigPath = harness.children[0]!.configPath;
    await writeConnectedStatus(firstConfigPath);
    await first;

    harness.runtime.recycle("wsp_alpha");
    await vi.waitFor(() => expect(harness.endpoint.revocationAttemptCount()).toBe(2), {
      timeout: 5_000,
    });

    // Both bounded DELETE attempts failed. The attempt enters backoff with the
    // original recovery handle intact; it may not overwrite the config or mint
    // a successor until that exact credential is fenced.
    expect(harness.endpoint.mintCount()).toBe(1);
    expect(harness.children).toHaveLength(1);
    const retainedConfig = JSON.parse(await readFile(firstConfigPath, "utf8")) as {
      connector: { connector_token: string };
    };
    expect(retainedConfig.connector.connector_token).toBe("salix_tok_1");

    harness.runtime.recycle("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    expect(harness.endpoint.revocations).toContainEqual({
      token: "salix_tok_1",
      workspaceId: "wsp_alpha",
    });
    expect(harness.endpoint.mintCount()).toBe(2);

    await writeConnectedStatus(harness.children[1]!.configPath);
    await harness.runtime.close();
  });

  it.each([
    // The binary keeps retrying after auth_required for the unrestricted scope.
    { childExitsAfterRejection: false, ordering: "the child stays alive" },
    // The binary writes auth_required and exits in the same call for the
    // local_file_read scope, so Main sees the exit before any status poll.
    { childExitsAfterRejection: true, ordering: "the child exits immediately" },
  ])(
    "re-mints once a rejected credential's TTL elapses even though its revocation stays unconfirmed ($ordering)",
    async ({ childExitsAfterRejection }) => {
      // The server rejected the token (the connector reported auth_required)
      // AND its requested TTL elapsed: nobody can redeem it any more, so an
      // unconfirmed DELETE must not hold the workspace offline forever.
      const harness = createRuntimeHarness({
        backoffScheduleMs: [25],
        failRevocations: 1_000,
        tokenTtlSeconds: 1,
      });
      const first = harness.runtime.registrationTarget("wsp_alpha");
      await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
        timeout: 5_000,
      });
      const firstConfigPath = harness.children[0]!.configPath;
      await writeConnectedStatus(firstConfigPath);
      await first;

      await writeFile(
        `${firstConfigPath}.status.json`,
        JSON.stringify({
          last_error_message: "connector auth failed: HTTP 401",
          state: "auth_required",
        })
      );
      if (childExitsAfterRejection) harness.children[0]!.exit();

      // At least two whole retire rounds refused the DELETE while the
      // credential was still inside its TTL, and no successor was minted.
      await vi.waitFor(
        () =>
          expect(harness.endpoint.revocationAttemptCount()).toBeGreaterThanOrEqual(4),
        { timeout: 5_000 }
      );
      expect(harness.endpoint.mintCount()).toBe(1);
      expect(harness.children).toHaveLength(1);

      await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
        timeout: 5_000,
      });
      // The endpoint's own clock: the successor was only requested after the
      // first credential's requested TTL had elapsed.
      expect(
        harness.endpoint.mintedAtMs[1]! - harness.endpoint.mintedAtMs[0]!
      ).toBeGreaterThanOrEqual(1_000);
      expect(harness.endpoint.mintCount()).toBe(2);
      expect(harness.endpoint.revocations).toEqual([]);
      const successorConfig = JSON.parse(
        await readFile(harness.children[1]!.configPath, "utf8")
      ) as { connector: { connector_token: string } };
      expect(successorConfig.connector.connector_token).toBe("salix_tok_2");

      await writeConnectedStatus(harness.children[1]!.configPath, {
        connector_run_id: "run_after_expiry",
      });
      await expect(
        harness.runtime.registrationTarget("wsp_alpha")
      ).resolves.toMatchObject({ connectorRunId: "run_after_expiry" });

      await harness.runtime.close();
    }
  );

  it("keeps blocking re-mint for an expired credential the server never rejected", async () => {
    // TTL alone is a local clock claim. Without the connector's auth_required
    // report the entry keeps the durable retry handle, exactly as before.
    const harness = createRuntimeHarness({
      backoffScheduleMs: [25],
      failRevocations: 1_000,
      tokenTtlSeconds: 1,
    });
    const first = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[0]!.configPath);
    await first;
    await delay(1_100);

    harness.runtime.recycle("wsp_alpha");
    // More than one two-attempt retire round refused: the entry is in the
    // steady retry state, not merely between its first two attempts.
    await vi.waitFor(
      () => expect(harness.endpoint.revocationAttemptCount()).toBeGreaterThan(2),
      { timeout: 5_000 }
    );
    expect(harness.endpoint.mintCount()).toBe(1);
    expect(harness.children).toHaveLength(1);

    await harness.runtime.close();
  });

  it.each([true, false])(
    "only reaps an expired credential after failed teardown revocation when rejected=%s",
    async (rejected) => {
      const persistedEvidence: Record<string, unknown>[] = [];
      const harness = createRuntimeHarness({
        // Keep any rejection-triggered restart asleep until close stops the entry.
        backoffScheduleMs: [60_000],
        enumerateProcesses: noMatchingConnectorProcesses,
        failRevocations: 1_000,
        persistContainmentEvidence: async (path, evidence) => {
          await writeFile(path, `${JSON.stringify(evidence)}\n`, { mode: 0o600 });
          persistedEvidence.push(JSON.parse(await readFile(path, "utf8")));
        },
        tokenTtlSeconds: 1,
      });
      try {
        const pending = harness.runtime.registrationTarget("wsp_alpha");
        await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
          timeout: 5_000,
        });
        const child = harness.children[0]!;
        const configPath = child.configPath;
        const runDir = dirname(configPath);
        const devicePath = join(dirname(dirname(runDir)), "device.json");
        await writeConnectedStatus(configPath);
        await pending;
        const deviceIdentity = await readFile(devicePath, "utf8");
        await delay(1_100);

        if (rejected) {
          await writeFile(
            `${configPath}.status.json`,
            JSON.stringify({ state: "auth_required" })
          );
        }
        await harness.runtime.close();

        expect(child.exited).toBe(true);
        expect(harness.endpoint.mintCount()).toBe(1);
        expect(harness.children).toHaveLength(1);
        expect(harness.endpoint.revocations).toEqual([]);
        expect(await readFile(devicePath, "utf8")).toBe(deviceIdentity);
        expect(persistedEvidence.at(-1)?.processAbsentAtMs).toBeTypeOf("number");
        if (rejected) {
          expect(harness.endpoint.revocationAttemptCount()).toBe(2);
          expect(persistedEvidence.at(-1)?.credentialContainedAtMs).toBeTypeOf(
            "number"
          );
          expect(existsSync(runDir)).toBe(false);
        } else {
          // The common reaper makes one more revoke attempt, but TTL alone
          // cannot authorize deletion of the durable retry handle.
          expect(harness.endpoint.revocationAttemptCount()).toBe(3);
          const retainedEvidence = JSON.parse(
            await readFile(join(runDir, "run.json"), "utf8")
          ) as Record<string, unknown>;
          expect(retainedEvidence.credentialContainedAtMs).toBeUndefined();
          const retainedConfig = JSON.parse(await readFile(configPath, "utf8"));
          expect(retainedConfig.connector.connector_token).toBe("salix_tok_1");
        }
      } finally {
        await harness.runtime.close();
      }
    }
  );

  it("preserves normal-teardown evidence after revoke failure until a later two-proof sweep", async () => {
    const harness = createRuntimeHarness({
      enumerateProcesses: noMatchingConnectorProcesses,
      // Two bounded normal-teardown attempts plus the common reaper attempt.
      failRevocations: 3,
    });
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    const configPath = harness.children[0]!.configPath;
    const runDir = dirname(configPath);
    await writeConnectedStatus(configPath);
    await pending;
    await harness.runtime.close();

    expect(harness.endpoint.revocationAttemptCount()).toBe(3);
    expect(existsSync(runDir)).toBe(true);
    const retainedConfig = JSON.parse(await readFile(configPath, "utf8")) as {
      connector: { connector_token: string };
    };
    expect(retainedConfig.connector.connector_token).toBe("salix_tok_1");
    const retainedEvidence = JSON.parse(
      await readFile(join(runDir, "run.json"), "utf8")
    ) as Record<string, unknown>;
    expect(retainedEvidence.processAbsentAtMs).toBeTypeOf("number");
    expect(retainedEvidence.credentialContainedAtMs).toBeUndefined();

    const recovery = createRuntimeHarness({
      enumerateProcesses: noMatchingConnectorProcesses,
    });
    await vi.waitFor(() => expect(existsSync(runDir)).toBe(false), {
      timeout: 5_000,
    });
    expect(recovery.endpoint.revocations).toContainEqual({
      token: "salix_tok_1",
      workspaceId: "wsp_alpha",
    });
    await recovery.runtime.close();
  });

  it("supervises concurrent workspaces with isolated run directories", async () => {
    const harness = createRuntimeHarness();
    const alpha = harness.runtime.registrationTarget("wsp_alpha");
    const beta = harness.runtime.registrationTarget("wsp_beta");

    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    const [first, second] = harness.children as [
      FakeConnectorChild,
      FakeConnectorChild,
    ];
    expect(first.configPath).not.toBe(second.configPath);

    await writeConnectedStatus(first.configPath, { connector_run_id: "run_a" });
    await writeConnectedStatus(second.configPath, { connector_run_id: "run_b" });
    const [alphaTarget, betaTarget] = await Promise.all([alpha, beta]);
    const runs = [alphaTarget?.connectorRunId, betaTarget?.connectorRunId].toSorted();
    expect(runs).toEqual(["run_a", "run_b"]);
    expect(harness.runtime.state()).toHaveLength(2);

    await harness.runtime.close();
    expect(first.exited).toBe(true);
    expect(second.exited).toBe(true);
  });

  it("restarts a crashed connector with a freshly minted token", async () => {
    const harness = createRuntimeHarness();
    const first = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[0]!.configPath);
    await first;

    harness.children[0]!.exit();

    const second = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    const respawned = harness.children[1]!;
    await vi.waitFor(async () => {
      const config = JSON.parse(await readFile(respawned.configPath, "utf8")) as {
        connector: { connector_token: string };
      };
      expect(config.connector.connector_token).toBe("salix_tok_2");
    });

    await writeConnectedStatus(respawned.configPath, {
      connector_run_id: "run_after_crash",
    });
    await expect(second).resolves.toMatchObject({
      connectorRunId: "run_after_crash",
    });

    await harness.runtime.close();
  });

  it("does not clear a cooperative stop request or respawn until the exact child exits", async () => {
    const harness = createRuntimeHarness({ backoffScheduleMs: [10] });
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    const first = harness.children[0]!;
    first.ignoreStopRequest = true;
    await writeConnectedStatus(first.configPath);
    await pending;

    harness.runtime.recycle("wsp_alpha");
    await vi.waitFor(() => expect(first.stopRequests).toBeGreaterThan(0), {
      timeout: 5_000,
    });
    const shutdownRequestPath = join(
      dirname(first.configPath),
      "shutdown-request.json"
    );
    const request = JSON.parse(await readFile(shutdownRequestPath, "utf8")) as {
      runNonce?: string;
    };
    expect(request.runNonce).toBe(harness.spawnInputs[0]!.runNonce);
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(harness.children).toHaveLength(1);
    expect(existsSync(dirname(first.configPath))).toBe(true);
    expect(existsSync(shutdownRequestPath)).toBe(true);

    first.exit();
    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    expect(harness.spawnInputs[1]!.runNonce).toBe(harness.spawnInputs[0]!.runNonce);
    await writeConnectedStatus(harness.children[1]!.configPath);
    await harness.runtime.close();
  });

  it("wipes a stale status file before each spawn", async () => {
    const harness = createRuntimeHarness({ readyTimeoutMs: 300 });
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    const child = harness.children[0]!;
    expect(existsSync(`${child.configPath}.status.json`)).toBe(false);
    await expect(pending).resolves.toBeNull();

    await harness.runtime.close();
  });

  it("re-mints and restarts when the connector reports auth_required", async () => {
    const harness = createRuntimeHarness();
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });

    await writeFile(
      `${harness.children[0]!.configPath}.status.json`,
      JSON.stringify({
        last_error_message: "connector token rejected",
        state: "auth_required",
      })
    );

    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    expect(harness.endpoint.mintCount()).toBe(2);
    await writeConnectedStatus(harness.children[1]!.configPath, {
      connector_run_id: "run_after_reissue",
    });
    await expect(pending).resolves.toMatchObject({
      connectorRunId: "run_after_reissue",
    });

    await harness.runtime.close();
  });

  it("a Session generation bump stops the old child immediately and re-keys", async () => {
    const harness = createRuntimeHarness();
    const first = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[0]!.configPath);
    await first;

    harness.signIn("sess_2", "comma_sess_token_2");

    // The stop is lease-event-driven: no status poll or watchdog tick is
    // needed before the old child receives cooperative shutdown.
    await vi.waitFor(() => expect(harness.children[0]!.exited).toBe(true), {
      timeout: 500,
    });

    const second = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    expect(harness.endpoint.requests.at(-1)).toMatchObject({
      authorization: "Bearer comma_sess_token_2",
      workspaceId: "wsp_alpha",
    });
    await writeConnectedStatus(harness.children[1]!.configPath, {
      connector_run_id: "run_generation_2",
    });
    await expect(second).resolves.toMatchObject({
      connectorRunId: "run_generation_2",
    });

    await harness.runtime.close();
  });

  it("a replaced entry can never delete its successor's run files", async () => {
    const harness = createRuntimeHarness();
    const first = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[0]!.configPath);
    await first;
    const firstRunDir = dirname(harness.children[0]!.configPath);

    harness.signIn("sess_2", "comma_sess_token_2");
    const second = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    const secondRunDir = dirname(harness.children[1]!.configPath);
    expect(secondRunDir).not.toBe(firstRunDir);

    await writeConnectedStatus(harness.children[1]!.configPath, {
      connector_run_id: "run_generation_2",
    });
    await second;
    // The predecessor's teardown removed only its own run directory.
    await vi.waitFor(() => expect(existsSync(firstRunDir)).toBe(false), {
      timeout: 5_000,
    });
    expect(existsSync(harness.children[1]!.configPath)).toBe(true);

    await harness.runtime.close();
  });

  it("sign-out stops children and later demands fail closed", async () => {
    const harness = createRuntimeHarness();
    const first = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[0]!.configPath);
    await first;

    harness.authority.beginSignOut();
    harness.authority.settleSignedOut("user_signed_out");

    await vi.waitFor(() => expect(harness.children[0]!.exited).toBe(true), {
      timeout: 5_000,
    });
    await expect(harness.runtime.registrationTarget("wsp_alpha")).resolves.toBeNull();
    expect(harness.children).toHaveLength(1);

    await harness.runtime.close();
  });

  it("resolution returns null when the connector never connects, without killing it", async () => {
    const harness = createRuntimeHarness({ readyTimeoutMs: 120 });
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });

    await expect(pending).resolves.toBeNull();
    expect(harness.children[0]!.exited).toBe(false);

    await harness.runtime.close();
  });

  it("mint failures back off and recover on a later attempt", async () => {
    const harness = createRuntimeHarness({ failFirstMints: 2 });
    const pending = harness.runtime.registrationTarget("wsp_alpha");

    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 3_000,
    });
    await writeConnectedStatus(harness.children[0]!.configPath);
    await expect(pending).resolves.toMatchObject({ connectorRunId: "run_live" });

    await harness.runtime.close();
  });

  it("evicts the least recently used idle workspace beyond capacity", async () => {
    const harness = createRuntimeHarness({ maxWorkspaces: 2 });
    const alpha = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[0]!.configPath, {
      connector_run_id: "run_a",
    });
    await alpha;

    const beta = harness.runtime.registrationTarget("wsp_beta");
    await vi.waitFor(() => expect(harness.children).toHaveLength(2), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[1]!.configPath, {
      connector_run_id: "run_b",
    });
    await beta;

    const gamma = harness.runtime.registrationTarget("wsp_gamma");
    await vi.waitFor(() => expect(harness.children).toHaveLength(3), {
      timeout: 5_000,
    });
    await vi.waitFor(() => expect(harness.children[0]!.exited).toBe(true), {
      timeout: 5_000,
    });
    await writeConnectedStatus(harness.children[2]!.configPath, {
      connector_run_id: "run_c",
    });
    await gamma;
    expect(
      harness.runtime
        .state()
        .map((entry) => entry.workspaceId)
        .toSorted()
    ).toEqual(["wsp_beta", "wsp_gamma"]);

    await harness.runtime.close();
  });

  it("close requests cooperative child shutdown without sending a pid signal", async () => {
    const harness = createRuntimeHarness();
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    await vi.waitFor(() => expect(harness.children).toHaveLength(1), {
      timeout: 5_000,
    });
    const child = harness.children[0]!;
    await writeConnectedStatus(child.configPath);
    await pending;

    await harness.runtime.close();
    expect(child.stopRequests).toBe(1);
    expect(child.exited).toBe(true);
    await expect(harness.runtime.registrationTarget("wsp_alpha")).resolves.toBeNull();
  });

  it("retains legacy pid-only evidence until the process exits without signalling it", async () => {
    const orphanPid = 4_194_304;
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "aaaaaaaaaaaa"
    );
    await mkdir(orphanRunDir, { recursive: true });
    const startedAtMs = Date.now() - 5_000;
    await writeFile(
      join(orphanRunDir, "connector.pid"),
      JSON.stringify({
        binaryPath: join(tempDir, "salix-connect"),
        pid: orphanPid,
        startedAtMs,
      })
    );
    const signals: unknown[] = [];
    let orphanDead = false;
    const killSpy = vi.spyOn(process, "kill").mockImplementation(((
      pid: number,
      signal?: unknown
    ) => {
      if (pid !== orphanPid) return true;
      if (signal === 0) {
        if (orphanDead) {
          const gone = new Error("ESRCH") as NodeJS.ErrnoException;
          gone.code = "ESRCH";
          throw gone;
        }
        return true;
      }
      signals.push(signal);
      return true;
    }) as typeof process.kill);
    try {
      const harness = createRuntimeHarness({
        // Identity must match on the FULL recorded executable path — a
        // same-named binary at another path is a different program and may
        // never be signalled.
        inspectProcess: async () => ({
          command: join(tempDir, "salix-connect"),
          startedAtMs,
        }),
      });
      await new Promise((resolve) => setTimeout(resolve, 150));
      expect(existsSync(orphanRunDir)).toBe(true);
      expect(signals).toEqual([]);

      orphanDead = true;
      harness.runtime.resumeContainment();
      await vi.waitFor(() => expect(existsSync(orphanRunDir)).toBe(false), {
        timeout: 5_000,
      });
      expect(signals).toEqual([]);
      await harness.runtime.close();
    } finally {
      killSpy.mockRestore();
    }
  });

  it.each(["EPERM", "EACCES", "EIO"])(
    "retains legacy evidence when pid observation fails with %s",
    async (code) => {
      const orphanPid = 4_194_320;
      const orphanRunDir = join(
        tempDir,
        "connectors",
        "wsp_old-abcdef123456",
        "runs",
        `legacy-${code.toLowerCase()}`
      );
      await mkdir(orphanRunDir, { recursive: true });
      await writeFile(
        join(orphanRunDir, "connector.pid"),
        JSON.stringify({
          binaryPath: join(tempDir, "salix-connect"),
          pid: orphanPid,
          startedAtMs: Date.now() - 5_000,
        })
      );
      const killSpy = vi.spyOn(process, "kill").mockImplementation(((
        pid: number,
        signal?: unknown
      ) => {
        if (pid === orphanPid && signal === 0) {
          const denied = new Error(code) as NodeJS.ErrnoException;
          denied.code = code;
          throw denied;
        }
        throw new Error(`unexpected process signal: ${String(signal)}`);
      }) as typeof process.kill);
      try {
        const harness = createRuntimeHarness({
          inspectProcess: async () => null,
        });
        await new Promise((resolve) => setTimeout(resolve, 150));
        expect(existsSync(orphanRunDir)).toBe(true);
        await harness.runtime.close();
      } finally {
        killSpy.mockRestore();
      }
    }
  );

  it("sweeps run state whose pid was provably recycled by another program", async () => {
    const orphanPid = 4_194_305;
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "bbbbbbbbbbbb"
    );
    await mkdir(orphanRunDir, { recursive: true });
    await writeFile(
      join(orphanRunDir, "connector.pid"),
      JSON.stringify({
        binaryPath: join(tempDir, "salix-connect"),
        pid: orphanPid,
        startedAtMs: Date.now() - 5_000,
      })
    );
    const signals: unknown[] = [];
    const killSpy = vi.spyOn(process, "kill").mockImplementation(((
      pid: number,
      signal?: unknown
    ) => {
      if (pid === orphanPid && signal !== 0) signals.push(signal);
      return true;
    }) as typeof process.kill);
    try {
      const harness = createRuntimeHarness({
        // The pid was recycled by an unrelated program: same pid, different
        // executable. Pids are recycled only after the original process
        // exits, so contradictory identity is affirmative proof the recorded
        // child is gone — the foreign process must not be signalled, and the
        // credential-less state is inert junk that is safe to sweep.
        inspectProcess: async () => ({
          command: "/usr/bin/some-unrelated-tool",
          startedAtMs: Date.now(),
        }),
      });
      harness.runtime.prewarm("wsp_alpha");
      await vi.waitFor(() => expect(existsSync(orphanRunDir)).toBe(false), {
        timeout: 5_000,
      });
      expect(signals).toEqual([]);
      await harness.runtime.close();
    } finally {
      killSpy.mockRestore();
    }
  });

  it("re-arms the sweep on demand until containment succeeds", async () => {
    const orphanPid = 4_194_307;
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "dddddddddddd"
    );
    await mkdir(orphanRunDir, { recursive: true });
    await writeFile(
      join(orphanRunDir, "connector.pid"),
      JSON.stringify({
        binaryPath: join(tempDir, "salix-connect"),
        pid: orphanPid,
        startedAtMs: Date.now() - 5_000,
        workspaceId: "wsp_old",
      })
    );
    await writeFile(
      join(orphanRunDir, "connector.json"),
      JSON.stringify({
        connector: { connector_token: "salix_tok_stubborn", scope: "local_file_read" },
      })
    );
    const killSpy = vi
      .spyOn(process, "kill")
      .mockImplementation((() => true) as typeof process.kill);
    try {
      const harness = createRuntimeHarness({
        failRevocations: 1,
        // Unverifiable live process: only revocation can contain it.
        inspectProcess: async () => null,
        readyTimeoutMs: 150,
      });
      // The construction-time sweep fails revocation (503) and must KEEP the
      // state for retry.
      await new Promise((resolve) => setTimeout(resolve, 150));
      expect(existsSync(orphanRunDir)).toBe(true);
      expect(harness.endpoint.revocations).toEqual([]);

      // The next attachment demand re-arms the sweep; revocation now
      // succeeds. The live-but-unverifiable child is NOT proof of exit, so
      // the run state is kept for a later sweep to finish local containment.
      void harness.runtime.registrationTarget("wsp_alpha");
      await vi.waitFor(
        () =>
          expect(harness.endpoint.revocations).toContainEqual({
            token: "salix_tok_stubborn",
            workspaceId: "wsp_old",
          }),
        { timeout: 5_000 }
      );
      await new Promise((resolve) => setTimeout(resolve, 100));
      expect(existsSync(orphanRunDir)).toBe(true);
      await harness.runtime.close();
    } finally {
      killSpy.mockRestore();
    }
  });

  it("discovers a crash-window child by its pre-spawn nonce and keeps evidence until absence", async () => {
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "ffffffffffff"
    );
    await mkdir(orphanRunDir, { recursive: true });
    const configPath = join(orphanRunDir, "connector.json");
    const shutdownRequestPath = join(orphanRunDir, "shutdown-request.json");
    const runNonce = "0123456789abcdef0123456789abcdef";
    const orphanPid = 4_194_310;
    // Main crashed after spawn but before the PID write: the pre-spawn
    // evidence and the token-bearing config are all that survived. The
    // unique nonce is the process identity; PID publication is only an
    // optimization and cannot be required for recovery.
    await writeFile(
      join(orphanRunDir, "run.json"),
      JSON.stringify({
        binaryPath: join(tempDir, "salix-connect"),
        configPath,
        preparedAtMs: Date.now() - 5_000,
        runNonce,
        shutdownRequestPath,
        workspaceId: "wsp_old",
      })
    );
    await writeFile(
      configPath,
      JSON.stringify({
        connector: {
          connector_token: "salix_tok_crash_window",
          scope: "local_file_read",
        },
      })
    );
    let snapshots = 0;
    let allowAbsence = false;
    const signals: unknown[] = [];
    const killSpy = vi.spyOn(process, "kill").mockImplementation(((
      pid: number,
      signal?: unknown
    ) => {
      if (pid !== orphanPid) return true;
      if (signal !== 0) signals.push(signal);
      return true;
    }) as typeof process.kill);
    try {
      const harness = createRuntimeHarness({
        enumerateProcesses: async () => {
          snapshots += 1;
          return !allowAbsence
            ? {
                complete: true,
                processes: [
                  {
                    commandLine: `${join(tempDir, "salix-connect")} --config ${configPath} --run-nonce ${runNonce} --parent-lifeline-fd 3`,
                    executablePath: join(tempDir, "salix-connect"),
                    pid: orphanPid,
                    startedAtMs: Date.now() - 5_000,
                  },
                ],
              }
            : { complete: true, processes: [] };
        },
      });
      await vi.waitFor(
        () =>
          expect(harness.endpoint.revocations).toContainEqual({
            token: "salix_tok_crash_window",
            workspaceId: "wsp_old",
          }),
        { timeout: 5_000 }
      );
      await vi.waitFor(async () => {
        const request = JSON.parse(await readFile(shutdownRequestPath, "utf8")) as {
          runNonce?: string;
        };
        expect(request.runNonce).toBe(runNonce);
      });
      await new Promise((resolve) => setTimeout(resolve, 150));
      expect(existsSync(orphanRunDir)).toBe(true);
      expect(signals).toEqual([]);

      allowAbsence = true;
      harness.runtime.resumeContainment();
      await vi.waitFor(() => expect(existsSync(orphanRunDir)).toBe(false), {
        timeout: 5_000,
      });
      expect(snapshots).toBeGreaterThanOrEqual(4);
      expect(signals).toEqual([]);
      await harness.runtime.close();
    } finally {
      killSpy.mockRestore();
    }
  });

  it("retains and retries run evidence when native process enumeration is incomplete", async () => {
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "abababababab"
    );
    const configPath = join(orphanRunDir, "connector.json");
    const runNonce = "abcdefabcdefabcdefabcdefabcdefab";
    await mkdir(orphanRunDir, { recursive: true });
    await writeFile(
      join(orphanRunDir, "run.json"),
      JSON.stringify({
        binaryPath: join(tempDir, "salix-connect"),
        configPath,
        preparedAtMs: Date.now() - 5_000,
        runNonce,
        workspaceId: "wsp_old",
      })
    );
    await writeFile(
      configPath,
      JSON.stringify({
        connector: { connector_token: "salix_tok_incomplete" },
      })
    );

    let enumerations = 0;
    const harness = createRuntimeHarness({
      enumerateProcesses: async () => {
        enumerations += 1;
        return enumerations === 1
          ? { complete: false, processes: [] }
          : { complete: true, processes: [] };
      },
    });
    await vi.waitFor(() => expect(enumerations).toBe(1), { timeout: 5_000 });
    expect(existsSync(orphanRunDir)).toBe(true);

    harness.runtime.resumeContainment();
    await vi.waitFor(() => expect(existsSync(orphanRunDir)).toBe(false), {
      timeout: 5_000,
    });
    expect(enumerations).toBeGreaterThanOrEqual(2);
    await harness.runtime.close();
  });

  it("never deletes evidence when containment marker persistence fails", async () => {
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "bcbcbcbcbcbc"
    );
    const configPath = join(orphanRunDir, "connector.json");
    const runNonce = "aaaabbbbccccddddeeeeffff00001111";
    await mkdir(orphanRunDir, { recursive: true });
    await writeFile(
      join(orphanRunDir, "run.json"),
      JSON.stringify({
        binaryPath: join(tempDir, "salix-connect"),
        configPath,
        preparedAtMs: Date.now() - 5_000,
        runNonce,
        workspaceId: "wsp_old",
      })
    );
    await writeFile(
      configPath,
      JSON.stringify({ connector: { connector_token: "salix_tok_marker_io" } })
    );

    let persistAttempts = 0;
    let storageAvailable = false;
    const harness = createRuntimeHarness({
      enumerateProcesses: async () => ({ complete: true, processes: [] }),
      persistContainmentEvidence: async (path, evidence) => {
        persistAttempts += 1;
        if (!storageAvailable) throw new Error("injected rename failure");
        await writeFile(path, `${JSON.stringify(evidence)}\n`, { mode: 0o600 });
      },
    });
    await vi.waitFor(() => expect(persistAttempts).toBeGreaterThan(0), {
      timeout: 5_000,
    });
    expect(existsSync(orphanRunDir)).toBe(true);

    storageAvailable = true;
    harness.runtime.resumeContainment();
    await vi.waitFor(() => expect(existsSync(orphanRunDir)).toBe(false), {
      timeout: 5_000,
    });
    await harness.runtime.close();
  });

  it("finds and cooperatively stops a real pre-PID child by its durable nonce", async () => {
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "acacacacacac"
    );
    const configPath = join(orphanRunDir, "connector.json");
    const shutdownRequestPath = join(orphanRunDir, "shutdown-request.json");
    const runNonce = "1234567890abcdef1234567890abcdef";
    await mkdir(orphanRunDir, { recursive: true });
    await writeFile(
      join(orphanRunDir, "run.json"),
      JSON.stringify({
        binaryPath: process.execPath,
        configPath,
        preparedAtMs: Date.now(),
        runNonce,
        shutdownRequestPath,
        workspaceId: "wsp_old",
      })
    );
    await writeFile(
      configPath,
      JSON.stringify({
        connector: { connector_token: "salix_tok_real_crash_window" },
      })
    );

    // This helper stands in for the Go binary after spawn returned but before
    // connector.pid could be renamed. Its only recoverable identity is the
    // exact executable + config + nonce argv persisted before spawn.
    const helper = spawnProcess(
      process.execPath,
      [
        "-e",
        `const fs=require("node:fs");setInterval(()=>{try{const r=JSON.parse(fs.readFileSync(${JSON.stringify(
          shutdownRequestPath
        )},"utf8"));if(r.runNonce===${JSON.stringify(runNonce)})process.exit(0)}catch{}},25)`,
        "--",
        "--config",
        configPath,
        "--run-nonce",
        runNonce,
        "--parent-lifeline-fd",
        "3",
      ],
      { stdio: "ignore" }
    );
    try {
      await new Promise<void>((resolve, reject) => {
        helper.once("spawn", resolve);
        helper.once("error", reject);
      });
      expect(helper.pid).toBeTypeOf("number");
      const harness = createRuntimeHarness();
      // A complete native scan can legitimately consume the `ps` listing and
      // per-candidate inspection command budgets back-to-back on a loaded CI
      // host. Keep this integration assertion above that six-second bound;
      // the runtime's own containment deadline remains independently bounded.
      await vi.waitFor(
        () => expect(helper.exitCode !== null || helper.signalCode !== null).toBe(true),
        { timeout: 12_000 }
      );
      expect(helper.exitCode).toBe(0);
      // The child can exit between the native listing and executable inspection.
      // An incomplete scan deliberately retains evidence; after observing exit,
      // exercise the public recovery trigger to obtain a fresh complete scan.
      harness.runtime.resumeContainment();
      await vi.waitFor(() => expect(existsSync(orphanRunDir)).toBe(false), {
        timeout: 5_000,
      });
      expect(harness.endpoint.revocations).toContainEqual({
        token: "salix_tok_real_crash_window",
        workspaceId: "wsp_old",
      });
      await harness.runtime.close();
    } finally {
      if (helper.exitCode === null && helper.signalCode === null) {
        helper.kill("SIGKILL");
      }
    }
  }, 20_000);

  it("uses exact Windows executable identity and never signals a same-basename process", async () => {
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "cdcdcdcdcdcd"
    );
    const configPath =
      "C:\\Users\\Comma User\\AppData\\Local\\Comma\\runs\\cdcd\\connector.json";
    const binaryPath = "C:\\Program Files\\Comma\\salix-connect.exe";
    const runNonce = "fedcbafedcbafedcbafedcbafedcbafe";
    const foreignPid = 4_194_311;
    const nearPrefixPid = 4_194_313;
    await mkdir(orphanRunDir, { recursive: true });
    await writeFile(
      join(orphanRunDir, "run.json"),
      JSON.stringify({
        binaryPath,
        configPath,
        preparedAtMs: Date.now() - 5_000,
        runNonce,
        workspaceId: "wsp_old",
      })
    );

    const signals: unknown[] = [];
    const killSpy = vi.spyOn(process, "kill").mockImplementation(((
      pid: number,
      signal?: unknown
    ) => {
      if ((pid === foreignPid || pid === nearPrefixPid) && signal !== 0) {
        signals.push(signal);
      }
      return true;
    }) as typeof process.kill);
    try {
      const harness = createRuntimeHarness({
        enumerateProcesses: async () => ({
          complete: true,
          processes: [
            {
              commandLine: `"D:\\Other\\salix-connect.exe" --config "${configPath}" --run-nonce ${runNonce} --parent-lifeline-fd 3`,
              executablePath: "D:\\Other\\salix-connect.exe",
              pid: foreignPid,
              startedAtMs: Date.now() - 5_000,
            },
            {
              commandLine: `"${binaryPath}" --config "${configPath}-other" --run-nonce ${runNonce}ff --parent-lifeline-pipe \\\\.\\pipe\\unrelated`,
              executablePath: binaryPath,
              pid: nearPrefixPid,
              startedAtMs: Date.now() - 5_000,
            },
          ],
        }),
        processPlatform: "win32",
      });
      await vi.waitFor(() => expect(existsSync(orphanRunDir)).toBe(false), {
        timeout: 5_000,
      });
      expect(signals).toEqual([]);
      await harness.runtime.close();
    } finally {
      killSpy.mockRestore();
    }
  });

  it("uses cooperative shutdown and never signals a pid reused before absence proof", async () => {
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "dededededede"
    );
    const configPath = join(orphanRunDir, "connector.json");
    const binaryPath = join(tempDir, "salix-connect");
    const runNonce = "00112233445566778899aabbccddeeff";
    const shutdownRequestPath = join(orphanRunDir, "shutdown-request.json");
    const reusedPid = 4_194_312;
    await mkdir(orphanRunDir, { recursive: true });
    await writeFile(
      join(orphanRunDir, "run.json"),
      JSON.stringify({
        binaryPath,
        configPath,
        preparedAtMs: Date.now() - 5_000,
        runNonce,
        shutdownRequestPath,
        workspaceId: "wsp_old",
      })
    );

    let enumerations = 0;
    const signals: unknown[] = [];
    const killSpy = vi.spyOn(process, "kill").mockImplementation(((
      pid: number,
      signal?: unknown
    ) => {
      if (pid === reusedPid && signal !== 0) signals.push(signal);
      return true;
    }) as typeof process.kill);
    try {
      const harness = createRuntimeHarness({
        enumerateProcesses: async () => {
          enumerations += 1;
          return {
            complete: true,
            processes: [
              enumerations === 1
                ? {
                    commandLine: `${binaryPath} --config ${configPath} --run-nonce ${runNonce} --parent-lifeline-fd 3`,
                    executablePath: binaryPath,
                    pid: reusedPid,
                    startedAtMs: Date.now() - 5_000,
                  }
                : {
                    commandLine: "/usr/bin/unrelated",
                    executablePath: "/usr/bin/unrelated",
                    pid: reusedPid,
                    startedAtMs: Date.now(),
                  },
            ],
          };
        },
      });
      await vi.waitFor(() => expect(existsSync(orphanRunDir)).toBe(false), {
        timeout: 5_000,
      });
      expect(signals).toEqual([]);
      expect(enumerations).toBeGreaterThanOrEqual(2);
      await harness.runtime.close();
    } finally {
      killSpy.mockRestore();
    }
  });

  it("keeps containment independent of EPERM from pid signalling", async () => {
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "efefefefefef"
    );
    const configPath = join(orphanRunDir, "connector.json");
    const binaryPath = join(tempDir, "salix-connect");
    const runNonce = "ffeeddccbbaa99887766554433221100";
    const shutdownRequestPath = join(orphanRunDir, "shutdown-request.json");
    const orphanPid = 4_194_314;
    await mkdir(orphanRunDir, { recursive: true });
    await writeFile(
      join(orphanRunDir, "run.json"),
      JSON.stringify({
        binaryPath,
        configPath,
        preparedAtMs: Date.now() - 5_000,
        runNonce,
        shutdownRequestPath,
        workspaceId: "wsp_old",
      })
    );

    const signalAttempts: unknown[] = [];
    const killSpy = vi.spyOn(process, "kill").mockImplementation(((
      pid: number,
      signal?: unknown
    ) => {
      if (pid === orphanPid && signal !== 0) {
        signalAttempts.push(signal);
        const denied = new Error("EPERM") as NodeJS.ErrnoException;
        denied.code = "EPERM";
        throw denied;
      }
      return true;
    }) as typeof process.kill);
    let enumerations = 0;
    try {
      const harness = createRuntimeHarness({
        enumerateProcesses: async () => {
          enumerations += 1;
          return enumerations === 1
            ? {
                complete: true,
                processes: [
                  {
                    commandLine: `${binaryPath} --config ${configPath} --run-nonce ${runNonce} --parent-lifeline-fd 3`,
                    executablePath: binaryPath,
                    pid: orphanPid,
                    startedAtMs: Date.now() - 5_000,
                  },
                ],
              }
            : { complete: true, processes: [] };
        },
      });
      await vi.waitFor(() => expect(existsSync(orphanRunDir)).toBe(false), {
        timeout: 5_000,
      });
      expect(signalAttempts).toEqual([]);
      expect(enumerations).toBeGreaterThanOrEqual(2);
      await harness.runtime.close();
    } finally {
      killSpy.mockRestore();
    }
  });

  it("resumeContainment retries server-side containment after sign-in", async () => {
    const orphanPid = 4_194_309;
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "eeeeeeeeeeee"
    );
    await mkdir(orphanRunDir, { recursive: true });
    await writeFile(
      join(orphanRunDir, "connector.pid"),
      JSON.stringify({
        binaryPath: join(tempDir, "salix-connect"),
        pid: orphanPid,
        startedAtMs: Date.now() - 5_000,
        workspaceId: "wsp_old",
      })
    );
    await writeFile(
      join(orphanRunDir, "connector.json"),
      JSON.stringify({
        connector: { connector_token: "salix_tok_signin", scope: "local_file_read" },
      })
    );
    const killSpy = vi
      .spyOn(process, "kill")
      .mockImplementation((() => true) as typeof process.kill);
    try {
      // The construction sweep fails its revocation (as it would signed-out)
      // and cannot verify the live process; it must keep the state.
      const harness = createRuntimeHarness({
        failRevocations: 1,
        inspectProcess: async () => null,
      });
      await new Promise((resolve) => setTimeout(resolve, 150));
      expect(existsSync(orphanRunDir)).toBe(true);
      expect(harness.endpoint.revocations).toEqual([]);

      // The sign-in transition itself drives the retry — no attachment
      // demand. Revocation now succeeds; the live-but-unverifiable child
      // still keeps its run state for local containment later.
      harness.runtime.resumeContainment();
      await vi.waitFor(
        () =>
          expect(harness.endpoint.revocations).toContainEqual({
            token: "salix_tok_signin",
            workspaceId: "wsp_old",
          }),
        { timeout: 5_000 }
      );
      expect(existsSync(orphanRunDir)).toBe(true);
      await harness.runtime.close();
    } finally {
      killSpy.mockRestore();
    }
  });

  it("revokes an unverifiable live orphan but keeps its run state for retry", async () => {
    const orphanPid = 4_194_306;
    const orphanRunDir = join(
      tempDir,
      "connectors",
      "wsp_old-abcdef123456",
      "runs",
      "cccccccccccc"
    );
    await mkdir(orphanRunDir, { recursive: true });
    await writeFile(
      join(orphanRunDir, "connector.pid"),
      JSON.stringify({
        binaryPath: join(tempDir, "salix-connect"),
        pid: orphanPid,
        startedAtMs: Date.now() - 5_000,
        workspaceId: "wsp_old",
      })
    );
    await writeFile(
      join(orphanRunDir, "connector.json"),
      JSON.stringify({
        connector: { connector_token: "salix_tok_orphaned", scope: "local_file_read" },
      })
    );
    const signals: unknown[] = [];
    const killSpy = vi.spyOn(process, "kill").mockImplementation(((
      pid: number,
      signal?: unknown
    ) => {
      if (pid === orphanPid && signal !== 0) signals.push(signal);
      return true;
    }) as typeof process.kill);
    try {
      const harness = createRuntimeHarness({
        // Unverifiable process identity: no signal may be sent. Server-side
        // revocation severs the socket, but revocation success is not
        // process proof — the recorded identity is the only evidence a
        // later sweep has, so the run state must survive.
        inspectProcess: async () => null,
      });
      await vi.waitFor(
        () =>
          expect(harness.endpoint.revocations).toContainEqual({
            token: "salix_tok_orphaned",
            workspaceId: "wsp_old",
          }),
        { timeout: 5_000 }
      );
      await new Promise((resolve) => setTimeout(resolve, 100));
      expect(existsSync(orphanRunDir)).toBe(true);
      expect(signals).toEqual([]);
      await harness.runtime.close();
    } finally {
      killSpy.mockRestore();
    }
  });

  it("static status file mode resolves targets without any process", async () => {
    const staticStatusFilePath = join(tempDir, "connector.json.status.json");
    const harness = createRuntimeHarness({ staticStatusFilePath });

    await writeFile(
      staticStatusFilePath,
      JSON.stringify({
        connector_run_id: "run_old_reader",
        device_id: "dev_old_reader",
        state: "connected",
      })
    );
    await expect(harness.runtime.registrationTarget("wsp_any")).resolves.toBeNull();

    await writeFile(
      staticStatusFilePath,
      JSON.stringify({
        device_id: "dev_v2_without_run",
        local_file_index_version: 2,
        state: "connected",
      })
    );
    await expect(harness.runtime.registrationTarget("wsp_any")).resolves.toBeNull();

    await writeFile(
      staticStatusFilePath,
      JSON.stringify({
        connector_run_id: "run_v2_reader",
        device_id: "dev_v2_reader",
        local_file_index_version: 2,
        state: "connected",
      })
    );
    await expect(harness.runtime.registrationTarget("wsp_any")).resolves.toEqual({
      connectorRunId: "run_v2_reader",
      deviceId: "dev_v2_reader",
      localFileIndexVersion: 2,
    });
    expect(harness.children).toHaveLength(0);
    expect(harness.endpoint.mintCount()).toBe(0);

    await harness.runtime.close();
  });

  it("fails closed immediately when no connector binary is available", async () => {
    const harness = createRuntimeHarness({ binaryPath: undefined });
    await expect(harness.runtime.registrationTarget("wsp_alpha")).resolves.toBeNull();
    expect(harness.children).toHaveLength(0);
    expect(harness.endpoint.mintCount()).toBe(0);
    await harness.runtime.close();
  });

  it("backs off without spawning while the binary path does not exist yet", async () => {
    const harness = createRuntimeHarness({
      binaryPath: join(tempDir, "not-built-yet"),
      readyTimeoutMs: 120,
    });
    await expect(harness.runtime.registrationTarget("wsp_alpha")).resolves.toBeNull();
    expect(harness.children).toHaveLength(0);
    expect(harness.runtime.state()[0]?.lastError).toContain("not-built-yet");
    await harness.runtime.close();
  });

  it("cleans stale run directories on startup without touching device identity", async () => {
    const workspaceDir = join(tempDir, "connectors", "wsp_alpha-000000000000");
    await mkdir(join(workspaceDir, "runs", "cccccccccccc"), { recursive: true });
    await writeFile(
      join(workspaceDir, "device.json"),
      JSON.stringify({ deviceId: "dev_durable" })
    );

    const harness = createRuntimeHarness();
    harness.runtime.prewarm("wsp_other");
    await vi.waitFor(
      () => expect(existsSync(join(workspaceDir, "runs", "cccccccccccc"))).toBe(false),
      { timeout: 5_000 }
    );
    expect(existsSync(join(workspaceDir, "device.json"))).toBe(true);
    await harness.runtime.close();
  });
});
