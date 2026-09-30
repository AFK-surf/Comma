/// <reference lib="dom" />

import {
  _electron as electron,
  type ElectronApplication,
  type Page,
} from "@playwright/test";
import type { CommaNativeBridge } from "@comma/native-bridge";
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import { mkdtemp, rm } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { cpus, platform, release, tmpdir, totalmem } from "node:os";
import { join, resolve } from "node:path";

import { findElectronWindowByRole } from "../src/test-support/electron-window.ts";

const PROFILE_EMAIL = "inbox-profile@example.com";
const PROFILE_TOKEN = "comma_sess_inbox_profile";
const PROFILE_SESSION_ID = "session-inbox-profile";
const PROFILE_USER_ID = "user-inbox-profile";
const DEFAULT_SAMPLES = 50;
const DEFAULT_CONVERSATIONS = 50;
const DEFAULT_WORKSPACES = 10;
const DEFAULT_WARMUP = 20;
const MAX_SAMPLES = 10_000;
const MAX_WARMUP = 1_000;

type ProfileOptions = {
  conversations: number;
  samples: number;
  selfTest: boolean;
  warmup: number;
  workspaces: number;
};

type SessionLease = Parameters<
  CommaNativeBridge["productInbox"]["refresh"]
>[0]["session"];

type RequestSnapshot = {
  conversationRequests: number;
  responseBodyBytes: number;
  unexpectedBearerRequests: number;
  workspaceRequests: number;
};

type StateRecorderSnapshot = {
  leaseMismatches: number;
  publications: number;
  secretReflections: number;
};

type ProfileWindow = Window & {
  commaInboxProfileRecorder?: {
    lease: SessionLease;
    leaseMismatches: number;
    publications: number;
    release(): void;
    secretReflections: number;
    unsubscribe(): void;
  };
  commaNative: CommaNativeBridge;
};

const electronAppDir = resolve(import.meta.dirname, "..");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

async function main() {
  const options = parseOptions(process.argv.slice(2));
  if (options.selfTest) {
    runSelfTest();
    console.log(JSON.stringify({ ok: true, suite: "profile-inbox-runtime" }));
    return;
  }

  const userDataDir = await mkdtemp(join(tmpdir(), "comma-inbox-runtime-profile-"));
  const stub = await startSalixStub(options);
  let app: ElectronApplication | undefined;

  try {
    app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: electronEnv(stub.baseUrl, userDataDir),
    });
    const appWindow = await findElectronWindowByRole(app, "heading", {
      name: "Welcome to Comma",
    });
    await appWindow.waitForLoadState("domcontentloaded");
    const runtime = await readRuntime(app);
    const lease = await signIn(appWindow);

    await appWindow.getByRole("link", { name: "Inbox" }).click();
    await installStateRecorder(appWindow, lease);
    await refreshOnce(appWindow, lease, stub.workspaceId);
    await waitForProfileMarker(appWindow);

    await runWarmup(appWindow, lease, stub.workspaceId, options.warmup);
    resetStateRecorder(appWindow);
    const changedRequestsBefore = stub.snapshot();
    const changed = await runChangedSingleFlightProfile(
      appWindow,
      lease,
      options.samples,
      stub.workspaceId
    );
    const changedRequests = diffRequests(changedRequestsBefore, stub.snapshot());
    const changedState = await readStateRecorder(appWindow);
    const changedSingleFlight = {
      pass:
        changedRequests.workspaceRequests === options.samples &&
        changedRequests.conversationRequests === options.samples &&
        changedState.publications === options.samples &&
        changedState.leaseMismatches === 0 &&
        changedState.secretReflections === 0 &&
        changedRequests.unexpectedBearerRequests === 0,
      requests: changedRequests,
      state: changedState,
    };

    const report = {
      benchmark: {
        name: "comma-inbox-runtime",
        schemaVersion: 3,
      },
      changedResponse: {
        concurrentRefreshPairRoundTripMs: summarize(changed.roundTripMs),
        dispatchToReactCommitMs: summarize(changed.dispatchToCommitMs),
        resultPayloadBytes: summarize(changed.payloadBytes),
      },
      machine: {
        arch: process.arch,
        cpu: cpus()[0]?.model ?? "unknown",
        cpuCount: cpus().length,
        os: `${platform()} ${release()}`,
        totalMemoryBytes: totalmem(),
      },
      method: {
        conversationsReturned: options.conversations,
        devJsonlObservabilitySinkEnabled: !runtime.isPackaged,
        exactLease: "{authorityInstanceId,generation,sessionId,audience}",
        localHttpStub: true,
        percentileMethod: "nearest-rank",
        samples: options.samples,
        transport:
          "renderer generated ProductInbox state/demand -> Main coordinator -> utility-process LocalDataRepository",
        warmup: options.warmup,
        workspacesReturned: options.workspaces,
      },
      smoke: {
        changedSingleFlight,
      },
      runtime,
    };
    assertTokenFree(report);
    console.log(JSON.stringify(report, null, 2));

    if (!changedSingleFlight.pass) {
      throw new Error("Changed-response single-flight smoke failed.");
    }
  } finally {
    await app?.close().catch(() => {});
    await stub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
}

void main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});

async function readRuntime(app: ElectronApplication) {
  return app.evaluate(({ app: electronApp }) => ({
    chrome: process.versions.chrome ?? "unknown",
    electron: process.versions.electron ?? "unknown",
    isPackaged: electronApp.isPackaged,
    node: process.versions.node,
  }));
}

async function signIn(page: Page): Promise<SessionLease> {
  return page.evaluate(
    async ({ email }) => {
      const bridge = (window as unknown as ProfileWindow).commaNative;
      const initial = await bridge.session.state.get();
      if (initial.phase !== "signed_out") {
        throw new Error(`Expected signed_out profile startup, got ${initial.phase}.`);
      }
      const requested = await bridge.session.requestEmailLogin({
        email,
        expected: {
          authorityInstanceId: initial.authority.authorityInstanceId,
          expectedSessionId: null,
          generation: initial.generation,
        },
      });
      if (!requested.ok) {
        throw new Error(`Profile login request failed: ${requested.error.code}.`);
      }
      const verified = await bridge.session.verifyEmailLogin({
        attempt: requested.value.attempt,
        challengeId: requested.value.challengeId,
        code: "654321",
      });
      if (!verified.ok) {
        throw new Error(`Profile login verification failed: ${verified.error.code}.`);
      }
      return {
        audience: verified.value.session.audience,
        authorityInstanceId: verified.value.authority.authorityInstanceId,
        generation: verified.value.generation,
        sessionId: verified.value.session.sessionId,
      };
    },
    { email: PROFILE_EMAIL }
  );
}

async function installStateRecorder(page: Page, lease: SessionLease) {
  await page.evaluate(
    async ({ expectedLease }) => {
      const scope = window as unknown as ProfileWindow;
      scope.commaInboxProfileRecorder?.unsubscribe();
      scope.commaInboxProfileRecorder?.release();
      const bridge = scope.commaNative.productInbox;
      const recorder: NonNullable<ProfileWindow["commaInboxProfileRecorder"]> = {
        lease: expectedLease,
        leaseMismatches: 0,
        publications: 0,
        release: () => undefined,
        secretReflections: 0,
        unsubscribe: () => undefined,
      };
      recorder.unsubscribe = bridge.state.subscribe(
        (envelope) => {
          recorder.publications += 1;
          if (leaseKey(envelope.session) !== leaseKey(expectedLease)) {
            recorder.leaseMismatches += 1;
          }
          if (containsCredentialShape(envelope)) {
            recorder.secretReflections += 1;
          }
        },
        { session: expectedLease }
      );
      await bridge.retain({ session: expectedLease });
      recorder.release = () => {
        void bridge.release({ session: expectedLease });
      };
      scope.commaInboxProfileRecorder = recorder;

      // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this callback without module-scope helpers.
      function leaseKey(value: SessionLease) {
        return JSON.stringify([
          value.authorityInstanceId,
          value.generation,
          value.sessionId,
          value.audience,
        ]);
      }

      // The renderer must never receive the exact Main-owned bearer, including
      // for diagnostics. Detect credential-shaped projections without giving
      // this callback any bearer value to compare against.
      // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this callback without module-scope helpers.
      function containsCredentialShape(value: unknown) {
        const pending = [value];
        const visited = new Set<object>();
        while (pending.length > 0) {
          const current = pending.pop();
          if (typeof current === "string") {
            const normalized = current.trim().toLowerCase();
            if (
              normalized.startsWith("bearer ") ||
              normalized.startsWith("comma_sess_")
            ) {
              return true;
            }
            continue;
          }
          if (!current || typeof current !== "object") continue;
          if (visited.has(current)) continue;
          visited.add(current);
          for (const [key, nested] of Object.entries(current)) {
            if (/authorization|bearer|token/i.test(key)) return true;
            pending.push(nested);
          }
        }
        return false;
      }
    },
    { expectedLease: lease }
  );
  resetStateRecorder(page);
}

function resetStateRecorder(page: Page) {
  return page.evaluate(() => {
    const recorder = (window as unknown as ProfileWindow).commaInboxProfileRecorder;
    if (!recorder) throw new Error("ProductInbox profile recorder is missing.");
    recorder.leaseMismatches = 0;
    recorder.publications = 0;
    recorder.secretReflections = 0;
  });
}

function readStateRecorder(page: Page): Promise<StateRecorderSnapshot> {
  return page.evaluate(() => {
    const recorder = (window as unknown as ProfileWindow).commaInboxProfileRecorder;
    if (!recorder) throw new Error("ProductInbox profile recorder is missing.");
    return {
      leaseMismatches: recorder.leaseMismatches,
      publications: recorder.publications,
      secretReflections: recorder.secretReflections,
    };
  });
}

async function refreshOnce(page: Page, lease: SessionLease, workspaceId: string) {
  return page.evaluate(
    ({ expectedLease, selectedWorkspaceId }) =>
      (window as unknown as ProfileWindow).commaNative.productInbox.refresh({
        limit: 50,
        session: expectedLease,
        workspaceId: selectedWorkspaceId,
      }),
    { expectedLease: lease, selectedWorkspaceId: workspaceId }
  );
}

async function runWarmup(
  page: Page,
  lease: SessionLease,
  workspaceId: string,
  iterations: number
) {
  for (let index = 0; index < iterations; index += 1) {
    await page.evaluate(
      ({ expectedLease, selectedWorkspaceId }) =>
        Promise.all([
          (window as unknown as ProfileWindow).commaNative.productInbox.refresh({
            limit: 50,
            session: expectedLease,
            workspaceId: selectedWorkspaceId,
          }),
          (window as unknown as ProfileWindow).commaNative.productInbox.refresh({
            limit: 50,
            session: expectedLease,
            workspaceId: selectedWorkspaceId,
          }),
        ]),
      { expectedLease: lease, selectedWorkspaceId: workspaceId }
    );
  }
}

async function runChangedSingleFlightProfile(
  page: Page,
  lease: SessionLease,
  samples: number,
  workspaceId: string
) {
  const roundTripMs: number[] = [];
  const dispatchToCommitMs: number[] = [];
  const payloadBytes: number[] = [];

  for (let index = 0; index < samples; index += 1) {
    const measurement = await page.evaluate(
      async ({ expectedLease, selectedWorkspaceId }) => {
        const bridge = (window as unknown as ProfileWindow).commaNative.productInbox;
        const previousSequence = latestMarker().sequence;
        const startedAt = performance.now();
        let commitResolve: (value: number) => void;
        const commit = new Promise<number>((resolveCommit) => {
          commitResolve = resolveCommit;
        });
        const timeout = window.setTimeout(() => {
          observer.disconnect();
          commitResolve(Number.NaN);
        }, 10_000);
        const observer = new MutationObserver(() => {
          if (latestMarker().sequence <= previousSequence) return;
          window.clearTimeout(timeout);
          observer.disconnect();
          commitResolve(performance.now() - startedAt);
        });
        observer.observe(document.body, {
          characterData: true,
          childList: true,
          subtree: true,
        });

        const input = {
          limit: 50,
          session: expectedLease,
          workspaceId: selectedWorkspaceId,
        };
        const [first, second] = await Promise.all([
          bridge.refresh(input),
          bridge.refresh(input),
        ]);
        const roundTrip = performance.now() - startedAt;
        const commitMs = await commit;
        if (!Number.isFinite(commitMs)) {
          throw new Error("Timed out waiting for the changed ProductInbox commit.");
        }
        return {
          commitMs,
          payloadBytes: new TextEncoder().encode(JSON.stringify([first, second]))
            .byteLength,
          roundTrip,
        };

        // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this callback without module-scope helpers.
        function latestMarker() {
          const matches = [
            ...(document.body.textContent ?? "").matchAll(
              /Profile task #(\d+) @(\d+)/g
            ),
          ];
          return matches.reduce(
            (latest, match) => {
              const sequence = Number(match[1]);
              return sequence > latest.sequence
                ? { sequence, timestamp: Number(match[2]) }
                : latest;
            },
            { sequence: 0, timestamp: 0 }
          );
        }
      },
      { expectedLease: lease, selectedWorkspaceId: workspaceId }
    );
    dispatchToCommitMs.push(measurement.commitMs);
    payloadBytes.push(measurement.payloadBytes);
    roundTripMs.push(measurement.roundTrip);
  }

  return { dispatchToCommitMs, payloadBytes, roundTripMs };
}

async function waitForProfileMarker(page: Page) {
  try {
    await page.waitForFunction(
      () => /Profile task #\d+ @\d+/.test(document.body.textContent ?? ""),
      undefined,
      { timeout: 10_000 }
    );
  } catch {
    const state = await page.evaluate(() => ({
      body: (document.body.textContent ?? "").replaceAll(/\s+/g, " ").slice(0, 800),
      url: window.location.href,
    }));
    throw new Error(
      `Timed out waiting for the ProductInbox React marker at ${state.url}. ` +
        `Visible text: ${state.body}`
    );
  }
}

async function startSalixStub({
  conversations,
  workspaces,
}: Pick<ProfileOptions, "conversations" | "workspaces">) {
  const workspaceRows = Array.from({ length: workspaces }, (_, index) => ({
    group_id: `group-${String(index).padStart(3, "0")}`,
    id: `workspace-${String(index).padStart(3, "0")}`,
    name: `Profile Workspace ${index}`,
  }));
  const workspaceId = workspaceRows[0]!.id;
  const groupId = workspaceRows[0]!.group_id;
  let markerSequence = 0;
  let markerTimestamp = Date.now();
  const counters: RequestSnapshot = {
    conversationRequests: 0,
    responseBodyBytes: 0,
    unexpectedBearerRequests: 0,
    workspaceRequests: 0,
  };

  const server = createServer(async (request, response) => {
    const url = new URL(request.url ?? "", "http://127.0.0.1");
    response.setHeader("content-type", "application/json");

    if (request.method === "POST" && url.pathname === "/v1/comma/auth/email/login") {
      await drain(request);
      sendJson(
        response,
        { challenge_id: "profile-challenge", code: "654321" },
        counters
      );
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/comma/auth/email/verify") {
      await drain(request);
      sendJson(
        response,
        {
          expires_at: 1_900_000_000,
          session_id: PROFILE_SESSION_ID,
          token: PROFILE_TOKEN,
          user: { email: PROFILE_EMAIL, id: PROFILE_USER_ID },
        },
        counters
      );
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/comma/auth/logout") {
      await drain(request);
      sendJson(response, { signed_out: true }, counters);
      return;
    }
    if (request.method === "GET" && url.pathname === "/v1/comma/auth/session") {
      sendJson(
        response,
        {
          expires_at: 1_900_000_000,
          session_id: PROFILE_SESSION_ID,
          user: { email: PROFILE_EMAIL, id: PROFILE_USER_ID },
        },
        counters
      );
      return;
    }

    if (url.pathname === "/v1/comma/workspaces") {
      counters.workspaceRequests += 1;
      recordBearer(request, counters);
      sendJson(
        response,
        { data: workspaceRows, has_more: false, next_cursor: null },
        counters
      );
      return;
    }

    if (url.pathname === `/v1/comma/groups/${groupId}/conversations`) {
      counters.conversationRequests += 1;
      recordBearer(request, counters);

      markerSequence += 1;
      markerTimestamp = Date.now();
      const rows = Array.from({ length: conversations }, (_, index) => ({
        created_at: 1_710_000_000 + index,
        freshness: { state: "fresh" as const },
        id: `conversation-${String(index).padStart(3, "0")}`,
        kind: index === 0 ? ("agent_task" as const) : ("user_chat" as const),
        status: index === 0 ? "running" : "open",
        title:
          index === 0
            ? `Profile task #${markerSequence} @${markerTimestamp}`
            : `Profile conversation ${index}`,
        updated_at: 1_720_000_000 + conversations - index,
        group_id: groupId,
      }));
      sendJson(response, { data: rows, has_more: false, next_cursor: null }, counters);
      return;
    }

    response.writeHead(404).end(JSON.stringify({ data: [] }));
  });

  await new Promise<void>((resolveListen) => {
    server.listen(0, "127.0.0.1", resolveListen);
  });
  const { port } = server.address() as AddressInfo;

  return {
    baseUrl: `http://127.0.0.1:${port}`,
    close: () =>
      new Promise<void>((resolveClose) =>
        (server as Server).close(() => resolveClose())
      ),
    snapshot: () => ({ ...counters }),
    workspaceId,
  };
}

function recordBearer(request: IncomingMessage, counters: RequestSnapshot) {
  if (request.headers.authorization !== `Bearer ${PROFILE_TOKEN}`) {
    counters.unexpectedBearerRequests += 1;
  }
}

function sendJson(
  response: ServerResponse<IncomingMessage>,
  value: unknown,
  counters: RequestSnapshot
) {
  const body = JSON.stringify(value);
  counters.responseBodyBytes += Buffer.byteLength(body);
  response.end(body);
}

async function drain(request: IncomingMessage) {
  for await (const chunk of request) {
    void chunk;
    // Drain the bounded local stub request body.
  }
}

function electronEnv(baseUrl: string, userDataDir: string) {
  const {
    ELECTRON_RUN_AS_NODE: _runAsNode,
    COMMA_ELECTRON_E2E_GOOGLE_ID_TOKEN: _googleToken,
    COMMA_ELECTRON_E2E_OPEN_SIDE_CHAT: _openSideChat,
    COMMA_ELECTRON_E2E_SECURE_SESSION_FILE_PATH: _secureSessionPath,
    COMMA_ELECTRON_STARTUP_SESSION_EMAIL: _seedEmail,
    COMMA_ELECTRON_STARTUP_SESSION_TOKEN: _seedToken,
    COMMA_ELECTRON_E2E_SIDE_CHAT_HOST_PATH: _sideChatHost,
    COMMA_ELECTRON_RENDERER_URL: _rendererUrl,
    ...env
  } = process.env;
  return {
    ...env,
    COMMA_API_BASE_URL: baseUrl,
    COMMA_ELECTRON_E2E_USER_DATA_PATH: userDataDir,
    NODE_ENV: "test",
  };
}

function diffRequests(
  before: RequestSnapshot,
  after: RequestSnapshot
): RequestSnapshot {
  return Object.fromEntries(
    Object.keys(before).map((key) => [
      key,
      after[key as keyof RequestSnapshot] - before[key as keyof RequestSnapshot],
    ])
  ) as RequestSnapshot;
}

function summarize(values: number[]) {
  if (values.length === 0) {
    throw new Error("Cannot summarize an empty measurement set.");
  }
  const sorted = values.toSorted((left, right) => left - right);
  return {
    max: round(sorted.at(-1) ?? 0),
    mean: round(sorted.reduce((sum, value) => sum + value, 0) / sorted.length),
    min: round(sorted[0] ?? 0),
    p50: round(percentile(sorted, 0.5)),
    p95: round(percentile(sorted, 0.95)),
  };
}

function percentile(sorted: number[], quantile: number) {
  const index = Math.max(0, Math.ceil(sorted.length * quantile) - 1);
  return sorted[index] ?? 0;
}

function round(value: number) {
  return Number(value.toFixed(3));
}

function assertTokenFree(value: unknown) {
  if (JSON.stringify(value).includes(PROFILE_TOKEN)) {
    throw new Error("Profiler report reflected the Main-only bearer.");
  }
}

function parseOptions(args: string[]): ProfileOptions {
  const parsed: ProfileOptions = {
    conversations: DEFAULT_CONVERSATIONS,
    samples: DEFAULT_SAMPLES,
    selfTest: false,
    warmup: DEFAULT_WARMUP,
    workspaces: DEFAULT_WORKSPACES,
  };
  for (const argument of args) {
    if (argument === "--") continue;
    if (argument === "--self-test") {
      parsed.selfTest = true;
      continue;
    }
    const match = /^(--[a-z-]+)=([1-9]\d*)$/.exec(argument);
    if (!match) {
      throw new Error(`Expected --name=positive-integer, received ${argument}`);
    }
    const [, name, rawValue] = match;
    const value = Number(rawValue);
    if (!Number.isSafeInteger(value)) {
      throw new Error(`Expected a positive integer, received ${argument}`);
    }
    if (name === "--conversations") parsed.conversations = value;
    else if (name === "--samples") parsed.samples = value;
    else if (name === "--warmup") parsed.warmup = value;
    else if (name === "--workspaces") parsed.workspaces = value;
    else throw new Error(`Unknown option ${name}`);
  }
  if (parsed.samples > MAX_SAMPLES) {
    throw new Error(`--samples must be <= ${MAX_SAMPLES}.`);
  }
  if (parsed.warmup > MAX_WARMUP) {
    throw new Error(`--warmup must be <= ${MAX_WARMUP}.`);
  }
  if (parsed.conversations > 100 || parsed.workspaces > 100) {
    throw new Error("--conversations and --workspaces must match API limit <= 100.");
  }
  return parsed;
}

function runSelfTest() {
  const options = parseOptions([
    "--samples=3",
    "--warmup=2",
    "--workspaces=4",
    "--conversations=5",
  ]);
  if (
    options.samples !== 3 ||
    options.warmup !== 2 ||
    options.workspaces !== 4 ||
    options.conversations !== 5
  ) {
    throw new Error("Runtime profiler option parsing self-test failed.");
  }
  const summary = summarize([1, 2, 3, 4]);
  if (summary.p50 !== 2 || summary.p95 !== 4) {
    throw new Error("Runtime profiler percentile self-test failed.");
  }
  const before: RequestSnapshot = {
    conversationRequests: 2,
    responseBodyBytes: 10,
    unexpectedBearerRequests: 0,
    workspaceRequests: 2,
  };
  const after: RequestSnapshot = {
    conversationRequests: 5,
    responseBodyBytes: 30,
    unexpectedBearerRequests: 0,
    workspaceRequests: 6,
  };
  const diff = diffRequests(before, after);
  if (diff.conversationRequests !== 3 || diff.workspaceRequests !== 4) {
    throw new Error("Runtime profiler request-counter self-test failed.");
  }
  assertTokenFree({ lease: "token-free" });
}
