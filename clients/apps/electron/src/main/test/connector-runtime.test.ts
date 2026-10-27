import { existsSync } from "node:fs";
import { mainCoreRequests } from "../../test-support/main-core-requests";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { testEpoch } from "@comma/test-utils/test-clock";
import { MainCredentialGate } from "../modules/session/main-credential-gate";
import type { MainSessionTransportAuthority } from "../modules/session/main-session-transport";
import {
  WorkspaceConnectorRuntimeService,
  type StationHost,
  type WorkspaceConnectorScopeSnapshot,
} from "../modules/connector-runtime";
import {
  acceptVerified,
  beginSignOut,
  settleSignedOut,
} from "../../test-support/session-gate";

// The file's timers run on the test's clock: a test moves it.
beforeEach(() => {
  vi.useFakeTimers();
});

/** Waiters for the runtime's file removals (`removal`): sign-out signals nothing else. */
const removals = vi.hoisted(() => new Map<string, () => void>());

vi.mock("node:fs/promises", async (importOriginal) => {
  const fs = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...fs,
    rm: async (...args: Parameters<typeof fs.rm>) => {
      await fs.rm(...args);
      removals.get(String(args[0]))?.();
    },
  };
});

/** Resolves once the runtime has removed `path`: ask before what removes it. */
function removal(path: string) {
  const removed = Promise.withResolvers<void>();
  removals.set(path, removed.resolve);
  return removed.promise;
}

const AUDIENCE = "https://comma.test";
/** The delay of the runtime's status polls, which tells them from its other timers. */
const POLL_MS = 10;

let tempDir = "";

beforeEach(async () => {
  tempDir = await mkdtemp(join(tmpdir(), "comma-connector-runtime-"));
  await writeFile(join(tempDir, "synch"), "#!/bin/sh\n", { mode: 0o755 });
});

afterEach(async () => {
  await rm(tempDir, { force: true, recursive: true });
});

interface InstanceFile {
  comma: { workspace_id: string };
  connector: {
    connector_token: string;
    device: boolean;
    device_state_root: string;
    scope: string;
    server: string;
    workspace_id: string;
  };
  electron: {
    bin_dir: string;
    computer_use_helper_app?: string;
    env: Record<string, string>;
    local_file_index_root: string;
    runtime_namespace?: string;
  };
}

function createSessionHarness() {
  const authority = new MainCredentialGate({
    authorityInstanceId: "auth_test",
    trustedAudience: AUDIENCE,
  });
  const signIn = (sessionId: string, token: string) =>
    acceptVerified(authority, {
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
  installResponse,
  rejectStableDevice = false,
}: {
  failFirst?: number;
  installResponse?: Record<string, unknown> | undefined;
  rejectStableDevice?: boolean;
} = {}) {
  const requests: {
    session: string | null;
    body: Record<string, unknown>;
    workspaceId: string;
  }[] = [];
  const revocations: { token: string; workspaceId: string }[] = [];
  /** By token: settled once the endpoint has revoked it. */
  const revoked = new Map<string, PromiseWithResolvers<void>>();
  const revocation = (token: string) => {
    let pending = revoked.get(token);
    if (!pending) {
      pending = Promise.withResolvers<void>();
      revoked.set(token, pending);
    }
    return pending;
  };
  let failures = failFirst;
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
      const token = String(body.token ?? "");
      revocations.push({ token, workspaceId });
      revocation(token).resolve();
      return new Response(JSON.stringify({ revoked: true }), {
        headers: { "content-type": "application/json" },
        status: 200,
      });
    }
    requests.push({
      session: new Headers(init?.headers).get("x-comma-test-session"),
      body,
      workspaceId,
    });
    if (rejectStableDevice && typeof body.stable_device_id === "string") {
      return new Response(JSON.stringify({ error: "stable_device_unavailable" }), {
        status: 403,
      });
    }
    if (failures > 0) {
      failures -= 1;
      return new Response(JSON.stringify({ error: "unavailable" }), { status: 503 });
    }
    if (body.installation === true && installResponse) {
      return new Response(JSON.stringify(installResponse), {
        headers: { "content-type": "application/json" },
        status: 201,
      });
    }
    minted += 1;
    return new Response(
      JSON.stringify({
        alias: "comma",
        device_id:
          typeof body.stable_device_id === "string"
            ? body.stable_device_id
            : `dev_${minted}`,
        name: "Test Workspace Connector",
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
    requests,
    revocations,
    /** Resolves once the endpoint has revoked `token`. */
    revoked: (token: string) => revocation(token).promise,
  };
}

interface Timer {
  ms: number;
  run(): void;
}

/**
 * The runtime's clock: it stands at testEpoch until the test moves it (`at`), and its timers run only when the test
 * runs them. What the runtime does next never depends on how fast the machine is.
 */
function createTimers() {
  let now = testEpoch;
  const pending = new Set<Timer>();
  const watchers = new Set<(timer: Timer) => void>();
  /** The next timer armed from now on that `match`es. */
  const next = (match: (timer: Timer) => boolean) =>
    new Promise<Timer>((resolve) => {
      const watcher = (timer: Timer) => {
        if (!match(timer)) return;
        watchers.delete(watcher);
        resolve(timer);
      };
      watchers.add(watcher);
    });
  return {
    now: () => now,
    /** Moves the clock to `ms` (since the epoch); no timer runs by it. */
    at(ms: number) {
      now = ms;
    },
    setTimer(ms: number, run: () => void) {
      const timer: Timer = {
        ms,
        // Like a cleared timer, a cancelled one never runs.
        run: () => {
          if (pending.delete(timer)) run();
        },
      };
      pending.add(timer);
      for (const watcher of watchers) watcher(timer);
      return () => void pending.delete(timer);
    },
    next,
    /** The pending timer that `match`es, once there is one. */
    armed: async (match: (timer: Timer) => boolean) =>
      [...pending].find(match) ?? next(match),
  };
}

function createRuntimeHarness(
  options: {
    carried?: boolean;
    clientControl?: (() => { endpoint: string; token: string } | undefined) | undefined;
    failFirstMints?: number;
    installResponse?: Record<string, unknown>;
    maxWorkspaces?: number;
    onScopeStateChanged?: (snapshot: WorkspaceConnectorScopeSnapshot) => void;
    readyTimeoutMs?: number;
    rejectStableDevice?: boolean;
    staticStatusFilePath?: string;
  } = {}
) {
  const { authority, session, signIn } = createSessionHarness();
  const endpoint = createTokenEndpoint({
    failFirst: options.failFirstMints ?? 0,
    installResponse: options.installResponse,
    rejectStableDevice: options.rejectStableDevice ?? false,
  });
  const instancesDir = join(tempDir, "station", "connector", "instances");
  const station: StationHost & { starts: number } = {
    carried: options.carried ?? true,
    commandPath: join(tempDir, "station", "stillfail-station"),
    instancesDir,
    starts: 0,
    start() {
      this.starts += 1;
    },
  };
  const timers = createTimers();
  const isPoll = (timer: Timer) => timer.ms === POLL_MS;
  const runtime = new WorkspaceConnectorRuntimeService({
    ...(options.clientControl ? { clientControl: options.clientControl } : {}),
    computerUseHelperApp: join(tempDir, "Comma Computer Use.app"),
    connectorFileRoot: join(tempDir, "home"),
    connectorsRootDir: join(tempDir, "connectors"),
    core: mainCoreRequests(
      { state: () => authority.getSnapshot() },
      endpoint.fetchImpl as typeof fetch
    ),
    localFileIndexRoot: join(tempDir, "local-file-index"),
    maxWorkspaces: options.maxWorkspaces ?? 3,
    ...(options.onScopeStateChanged
      ? { onScopeStateChanged: options.onScopeStateChanged }
      : {}),
    readyTimeoutMs: options.readyTimeoutMs ?? 2_000,
    runtimeNamespace: "@comma-staging",
    runtimeRoot: join(tempDir, "@comma-staging"),
    session,
    // Its deadlines read the test's clock; status polls (`poll`), mint retries and the credential watch (`renewal`)
    // run when the test runs them.
    clock: timers,
    staticStatusFilePath: options.staticStatusFilePath,
    station,
    statusPollIntervalMs: POLL_MS,
    synchBinaryPath: join(tempDir, "synch"),
    synchDataDir: join(tempDir, "synchronicity"),
  });
  /** Resolves once the runtime waits on a status poll: it is done with the status it read. */
  const polling = () => timers.armed(isPoll);
  /**
   * The connection file the runtime writes next for `workspaceId`. Once it has
   * written one it watches the credential, so ask before it writes.
   */
  const instance = async (workspaceId: string, token?: string) => {
    await timers.next((timer) => !isPoll(timer));
    let found: { path: string; config: InstanceFile } | undefined;
    for (const name of await readdir(instancesDir).catch(() => [] as string[])) {
      if (!name.endsWith(".json") || name.endsWith(".status.json")) continue;
      const path = join(instancesDir, name);
      // An evicted connection's file may go while this reads.
      const text = await readFile(path, "utf8").catch(() => undefined);
      const config =
        text === undefined ? undefined : (JSON.parse(text) as InstanceFile);
      if (
        config?.comma.workspace_id === workspaceId &&
        (!token || config.connector.connector_token === token)
      ) {
        found = { path, config };
      }
    }
    expect(found).toBeDefined();
    return found!;
  };
  return {
    authority,
    clock: timers,
    endpoint,
    instance,
    instancesDir,
    /** Runs the status poll the runtime waits on. */
    poll: async () => (await polling()).run(),
    polling,
    /** Its pending mint retry or credential watch, once armed. */
    renewal: () => timers.armed((timer) => !isPoll(timer)),
    runtime,
    session,
    signIn,
    station,
  };
}

/** What the station writes once a connection is connected (systems/station/src/connector/status.ts). */
async function writeStatus(
  instancePath: string,
  overrides: Record<string, unknown> = {}
) {
  await writeFile(
    `${instancePath}.status.json`,
    JSON.stringify({
      connector_run_id: "run_live",
      device_id: "dev_live",
      local_file_index_version: 2,
      scope: "",
      state: "connected",
      // When the runtime wrote the connection: its clock stands at testEpoch.
      updated_at: testEpoch / 1000,
      ...overrides,
    })
  );
}

describe("WorkspaceConnectorRuntimeService", () => {
  it("writes a Workspace's connection to the station with one full short-lived credential", async () => {
    const harness = createRuntimeHarness({
      clientControl: () => ({
        endpoint: "http://127.0.0.1:9/control",
        token: "control",
      }),
    });
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    const { path, config } = await harness.instance("wsp_alpha");

    expect(harness.station.starts).toBe(1);
    expect(harness.endpoint.requests[0]).toMatchObject({
      session: "sess_1",
      workspaceId: "wsp_alpha",
    });
    expect(harness.endpoint.requests[0]?.body).toMatchObject({
      expires_in_seconds: 7_200,
    });
    expect(config.connector).toMatchObject({
      connector_token: "salix_tok_1",
      device: true,
      scope: "",
      server: "wss://salix.test",
      workspace_id: "wsp_alpha",
    });
    expect(config.electron).toMatchObject({
      computer_use_helper_app: join(tempDir, "Comma Computer Use.app"),
      env: {
        COMMA_CLIENT_CONTROL_TOKEN: "control",
        COMMA_CLIENT_CONTROL_URL: "http://127.0.0.1:9/control",
        SYNCH_DATA_DIR: join(tempDir, "synchronicity"),
      },
      local_file_index_root: join(tempDir, "local-file-index"),
      runtime_namespace: "@comma-staging",
    });
    // The agents' `comma` is the station's own command; `synch` the app's.
    await expect(
      readFile(join(config.electron.bin_dir, "comma"), "utf8")
    ).resolves.toContain(
      `'${join(tempDir, "station", "stillfail-station")}' comma-client`
    );
    await expect(
      readFile(join(config.electron.bin_dir, "synch"), "utf8")
    ).resolves.toContain(join(tempDir, "synch"));

    await writeStatus(path);
    await harness.poll();
    await expect(pending).resolves.toEqual({
      connectorRunId: "run_live",
      deviceId: "dev_live",
      localFileIndexVersion: 2,
    });
    // The stable device is durable before any route binds to it.
    await expect(
      readFile(join(config.connector.device_state_root, "device.json"), "utf8")
    ).resolves.toContain("dev_live");
    await harness.runtime.close();
    expect(existsSync(path)).toBe(false);
  });

  it("writes no connection before the client control endpoint is ready", async () => {
    let control: { endpoint: string; token: string } | undefined;
    const harness = createRuntimeHarness({ clientControl: () => control });
    harness.runtime.prewarm("wsp_alpha");
    // The attempt is over once it waits to retry.
    const retry = await harness.renewal();
    expect(harness.endpoint.mintCount()).toBe(0);
    expect(existsSync(harness.instancesDir)).toBe(false);
    control = { endpoint: "http://127.0.0.1:9/control", token: "control" };
    retry.run();
    const { config } = await harness.instance("wsp_alpha");
    expect(config.electron.env.COMMA_CLIENT_CONTROL_TOKEN).toBe("control");
    await harness.runtime.close();
  });

  it("changes the scope in the connection file and resolves once the station acknowledges it", async () => {
    const snapshots: WorkspaceConnectorScopeSnapshot[] = [];
    const harness = createRuntimeHarness({
      onScopeStateChanged: (snapshot) => snapshots.push(snapshot),
    });
    const pending = harness.runtime.setScope("wsp_alpha", "local_file_read");
    const { path, config } = await harness.instance("wsp_alpha");
    expect(config.connector.scope).toBe("local_file_read");
    await writeStatus(path, { scope: "" });
    await harness.poll();
    // That status does not acknowledge the scope: the runtime polls on.
    await harness.polling();
    await writeStatus(path, { scope: "local_file_read" });
    await harness.poll();
    await expect(pending).resolves.toEqual({
      available: true,
      deviceId: "dev_live",
      scope: "local_file_read",
      workspaceId: "wsp_alpha",
    });
    expect(snapshots.at(-1)?.scopes).toEqual([
      {
        available: true,
        deviceId: "dev_live",
        scope: "local_file_read",
        workspaceId: "wsp_alpha",
      },
    ]);
    await expect(
      readFile(join(config.connector.device_state_root, "scope.json"), "utf8")
    ).resolves.toContain('"local_file_read"');

    // Back to full access: the same file, the same credential.
    const full = harness.runtime.setScope("wsp_alpha", "");
    // It waits for the station once it has written the change.
    await harness.polling();
    const next = JSON.parse(await readFile(path, "utf8")) as InstanceFile;
    expect(next.connector.scope).toBe("");
    expect(next.connector.connector_token).toBe("salix_tok_1");
    await writeStatus(path, { scope: "" });
    await harness.poll();
    await expect(full).resolves.toMatchObject({ available: true, scope: "" });
    expect(harness.endpoint.mintCount()).toBe(1);
    await harness.runtime.close();
  });

  it("keeps operations disabled when the saved scope is unreadable", async () => {
    const harness = createRuntimeHarness();
    harness.runtime.prewarm("wsp_alpha");
    const first = await harness.instance("wsp_alpha");
    await harness.runtime.close();
    await writeFile(join(first.config.connector.device_state_root, "scope.json"), "{");

    const next = createRuntimeHarness();
    next.runtime.prewarm("wsp_alpha");
    const { config } = await next.instance("wsp_alpha");
    expect(config.connector.scope).toBe("local_file_read");
    await next.runtime.close();
  });

  it("gives up on a connection the station has not acknowledged once the ready deadline passes", async () => {
    const harness = createRuntimeHarness({ readyTimeoutMs: 2_000 });
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    await harness.instance("wsp_alpha");
    // Still unacknowledged at the deadline: the next poll gives up.
    await harness.polling();
    harness.clock.at(testEpoch + 2_000);
    await harness.poll();
    await expect(pending).resolves.toBeNull();
    await harness.runtime.close();
  });

  it("re-attaches the stable device, and mints a fresh one when the server refuses it", async () => {
    const harness = createRuntimeHarness();
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    const { path } = await harness.instance("wsp_alpha");
    await writeStatus(path, { device_id: "dev_stable" });
    await harness.poll();
    await pending;
    await harness.runtime.close();

    const again = createRuntimeHarness();
    again.runtime.prewarm("wsp_alpha");
    await again.instance("wsp_alpha");
    expect(again.endpoint.requests[0]?.body.stable_device_id).toBe("dev_stable");
    await again.runtime.close();

    const refused = createRuntimeHarness({ rejectStableDevice: true });
    refused.runtime.prewarm("wsp_alpha");
    const { config } = await refused.instance("wsp_alpha");
    expect(
      refused.endpoint.requests.map((request) => request.body.stable_device_id)
    ).toEqual(["dev_stable", undefined]);
    // The fresh device is the one the next mint re-attaches to.
    await expect(
      readFile(join(config.connector.device_state_root, "device.json"), "utf8")
    ).resolves.toContain("dev_1");
    await refused.runtime.close();
  });

  it("revokes a refused credential and writes the connection again with a new one", async () => {
    const harness = createRuntimeHarness();
    harness.runtime.prewarm("wsp_alpha");
    const { path } = await harness.instance("wsp_alpha");
    // A status from before the file was written is not this credential's: the
    // watch reads it and goes on.
    await writeStatus(path, { state: "auth_required", updated_at: 1 });
    (await harness.renewal()).run();
    await harness.renewal();
    expect(harness.endpoint.mintCount()).toBe(1);

    await writeStatus(path, { state: "auth_required" });
    const renewed = harness.instance("wsp_alpha", "salix_tok_2");
    (await harness.renewal()).run();
    await renewed;
    expect(harness.endpoint.revocations).toEqual([
      { token: "salix_tok_1", workspaceId: "wsp_alpha" },
    ]);
    // The new credential is for the same device, though it never connected.
    expect(
      harness.endpoint.requests.map((request) => request.body.stable_device_id)
    ).toEqual([undefined, "dev_1"]);
    await harness.runtime.close();
    expect(harness.endpoint.revocations.at(-1)).toEqual({
      token: "salix_tok_2",
      workspaceId: "wsp_alpha",
    });
  });

  it("renews the credential in the same connection a quarter of its life before it expires", async () => {
    const harness = createRuntimeHarness();
    harness.runtime.prewarm("wsp_alpha");
    const { path } = await harness.instance("wsp_alpha");
    await writeStatus(path);
    harness.clock.at(testEpoch + 5_399_000);
    (await harness.renewal()).run();
    await harness.renewal();
    expect(harness.endpoint.mintCount()).toBe(1);

    // The next credential, for the same device, in the same connection file;
    // the live connection may still hold the old one, so it stays unrevoked.
    harness.clock.at(testEpoch + 5_400_000);
    const renewed = harness.instance("wsp_alpha", "salix_tok_2");
    (await harness.renewal()).run();
    expect((await renewed).path).toBe(path);
    expect(harness.endpoint.requests.at(-1)?.body).toMatchObject({
      expires_in_seconds: 7_200,
      stable_device_id: "dev_1",
    });
    expect(harness.endpoint.revocations).toEqual([]);
    // The connection the station reported stays the target: nothing reconnected.
    await expect(
      harness.runtime.registrationTarget("wsp_alpha")
    ).resolves.toMatchObject({
      connectorRunId: "run_live",
    });

    harness.clock.at(testEpoch + 7_200_000);
    (await harness.renewal()).run();
    await harness.endpoint.revoked("salix_tok_1");
    expect(harness.endpoint.mintCount()).toBe(2);
    await harness.runtime.close();
    expect(harness.endpoint.revocations).toEqual([
      { token: "salix_tok_1", workspaceId: "wsp_alpha" },
      { token: "salix_tok_2", workspaceId: "wsp_alpha" },
    ]);
  });

  it("a renewal that cannot write the connection keeps the credential in use", async () => {
    const harness = createRuntimeHarness();
    harness.runtime.prewarm("wsp_alpha");
    const { path } = await harness.instance("wsp_alpha");
    await writeStatus(path);
    // Without the app's `synch` the runtime writes no connection.
    await rm(join(tempDir, "synch"));
    harness.clock.at(testEpoch + 5_400_000);
    (await harness.renewal()).run();
    // The watch goes on after the failed renewal.
    await harness.renewal();
    expect(harness.endpoint.mintCount()).toBe(2);
    await writeFile(join(tempDir, "synch"), "#!/bin/sh\n", { mode: 0o755 });

    // The next write of the connection still carries the credential in use,
    // not the one the renewal minted but never wrote.
    const scoped = harness.runtime.setScope("wsp_alpha", "local_file_read");
    await harness.polling();
    const written = JSON.parse(await readFile(path, "utf8")) as InstanceFile;
    expect(written.connector).toMatchObject({
      connector_token: "salix_tok_1",
      scope: "local_file_read",
    });
    expect(harness.endpoint.revocations).toEqual([]);
    await writeStatus(path, { scope: "local_file_read" });
    await harness.poll();
    await scoped;
    await harness.runtime.close();
  });

  it("mint failures back off and recover on a later attempt", async () => {
    const harness = createRuntimeHarness({ failFirstMints: 2 });
    const pending = harness.runtime.registrationTarget("wsp_alpha");
    // Each failed attempt waits longer before the next.
    const first = await harness.renewal();
    first.run();
    const second = await harness.renewal();
    expect(second.ms).toBeGreaterThan(first.ms);
    second.run();
    const { path } = await harness.instance("wsp_alpha");
    await writeStatus(path);
    await harness.poll();
    await expect(pending).resolves.toMatchObject({ connectorRunId: "run_live" });
    await harness.runtime.close();
  });

  it("a Session generation bump removes the old connection and its successor keeps the file", async () => {
    const harness = createRuntimeHarness();
    const first = harness.runtime.registrationTarget("wsp_alpha");
    const { path } = await harness.instance("wsp_alpha");
    await writeStatus(path);
    await harness.poll();
    await first;

    harness.signIn("sess_2", "comma_sess_token_2");
    const second = harness.runtime.registrationTarget("wsp_alpha");
    await harness.instance("wsp_alpha", "salix_tok_2");
    expect(harness.endpoint.requests.at(-1)).toMatchObject({
      session: "sess_2",
    });
    await writeStatus(path, { connector_run_id: "run_generation_2" });
    await harness.poll();
    await expect(second).resolves.toMatchObject({ connectorRunId: "run_generation_2" });
    // The old connection is done once its credential is revoked.
    await harness.endpoint.revoked("salix_tok_1");
    const kept = JSON.parse(await readFile(path, "utf8")) as InstanceFile;
    expect(kept.connector.connector_token).toBe("salix_tok_2");
    await harness.runtime.close();
  });

  it("sign-out removes the connection and later demands fail closed", async () => {
    const harness = createRuntimeHarness();
    const first = harness.runtime.registrationTarget("wsp_alpha");
    const { path } = await harness.instance("wsp_alpha");
    await writeStatus(path);
    await harness.poll();
    await first;

    const removed = removal(path);
    beginSignOut(harness.authority);
    settleSignedOut(harness.authority, "user_signed_out");

    await removed;
    await expect(harness.runtime.registrationTarget("wsp_alpha")).resolves.toBeNull();
    expect(harness.endpoint.mintCount()).toBe(1);
    await harness.runtime.close();
  });

  it("removes and revokes the connections an earlier run left, but not the static connector's", async () => {
    const harness = createRuntimeHarness();
    await mkdir(harness.instancesDir, { recursive: true });
    const leftover = join(harness.instancesDir, "wsp_old-0123456789ab.json");
    await writeFile(
      leftover,
      JSON.stringify({
        comma: { workspace_id: "wsp_old" },
        connector: { connector_token: "salix_tok_old", server: "wss://salix.test" },
      })
    );
    const staticConnector = join(harness.instancesDir, "static.json");
    await writeFile(
      staticConnector,
      JSON.stringify({
        connector: {
          connector_token: "user",
          name: "mine",
          root: "/",
          server: "wss://x",
        },
      })
    );

    harness.runtime.resumeContainment();
    // Closing waits for the containment to finish.
    await harness.runtime.close();
    expect(existsSync(leftover)).toBe(false);
    expect(harness.endpoint.revocations).toEqual([
      { token: "salix_tok_old", workspaceId: "wsp_old" },
    ]);
    expect(existsSync(staticConnector)).toBe(true);
  });

  it("evicts the least recently used workspace beyond capacity", async () => {
    const harness = createRuntimeHarness({ maxWorkspaces: 2 });
    harness.runtime.prewarm("wsp_a");
    const a = await harness.instance("wsp_a");
    // wsp_b is used after wsp_a.
    harness.clock.at(testEpoch + 1_000);
    harness.runtime.prewarm("wsp_b");
    await harness.instance("wsp_b");
    harness.runtime.prewarm("wsp_c");
    await harness.instance("wsp_c");
    // The evicted connection is done once its credential is revoked.
    await harness.endpoint.revoked(a.config.connector.connector_token);
    expect(existsSync(a.path)).toBe(false);
    await harness.runtime.close();
  });

  it("copies a fresh remote device command without writing a connection", async () => {
    const harness = createRuntimeHarness();
    const copy = vi.fn();
    await harness.runtime.copyConnectCommand("wsp_remote", copy);
    expect(harness.endpoint.requests[0]?.body.installation).toBe(true);
    expect(harness.endpoint.requests[0]?.body).not.toHaveProperty("stable_device_id");
    expect(copy).toHaveBeenCalledWith("server-install-command-1");
    expect(existsSync(harness.instancesDir)).toBe(false);

    await expect(
      harness.runtime.copyConnectCommand("wsp_remote", () => {
        throw new Error("clipboard unavailable");
      })
    ).rejects.toThrow("clipboard unavailable");
    expect(harness.endpoint.revocations).toEqual([
      { workspaceId: "wsp_remote", token: "salix_tok_2" },
    ]);
    await harness.runtime.close();
  });

  it("copies the station enrollment command the server gives", async () => {
    const command =
      "curl -fsSL https://comma.test/stations/install.sh | sh -s -- tok.secret";
    const harness = createRuntimeHarness({
      installResponse: { kind: "station", install_command: command, expires_at: 1 },
    });
    const copy = vi.fn();
    await harness.runtime.copyConnectCommand("wsp_remote", copy);
    expect(copy).toHaveBeenCalledWith(command);
    expect(harness.endpoint.mintCount()).toBe(0);
    await harness.runtime.close();
  });

  it("static status file mode resolves targets without a station", async () => {
    const statusFile = join(tempDir, "static.status.json");
    await writeStatus(statusFile.replace(/\.status\.json$/, ""), {
      scope: "local_file_read",
    });
    const harness = createRuntimeHarness({
      carried: false,
      staticStatusFilePath: statusFile,
    });
    await expect(harness.runtime.registrationTarget("wsp_alpha")).resolves.toEqual({
      connectorRunId: "run_live",
      deviceId: "dev_live",
      localFileIndexVersion: 2,
    });
    await expect(harness.runtime.scope("wsp_alpha")).resolves.toMatchObject({
      available: true,
      scope: "local_file_read",
    });
    expect(harness.endpoint.mintCount()).toBe(0);
    await harness.runtime.close();
  });

  it("fails closed at once when the app carries no station", async () => {
    const harness = createRuntimeHarness({ carried: false });
    await expect(harness.runtime.registrationTarget("wsp_alpha")).resolves.toBeNull();
    await expect(harness.runtime.scope("wsp_alpha")).resolves.toMatchObject({
      available: false,
    });
    expect(harness.endpoint.mintCount()).toBe(0);
    await harness.runtime.close();
  });
});
