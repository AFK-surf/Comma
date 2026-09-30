import { access, mkdtemp, rm } from "node:fs/promises";
import { cpus, platform, release, tmpdir, totalmem } from "node:os";
import { join, resolve } from "node:path";
import { monitorEventLoopDelay, performance } from "node:perf_hooks";

const DEFAULT_SAMPLES = 200;
const DEFAULT_STARTUP_SAMPLES = 5;
const DEFAULT_WARMUP = 20;
const DEFAULT_RAW_BYTES = 512;
const AUDIENCE = "https://api.profile.comma.test";
const PRINCIPAL_ID = "profile-principal";

const scenarios = [
  {
    cachedConversations: 50,
    name: "single-workspace-complete-page",
    persistence: "replace",
    polledConversations: 50,
    workspaces: 1,
  },
  {
    cachedConversations: 500,
    name: "ten-workspaces-paged-cache",
    persistence: "merge",
    polledConversations: 50,
    workspaces: 10,
  },
  {
    cachedConversations: 5_000,
    name: "fifty-workspaces-large-cache",
    persistence: "merge",
    polledConversations: 50,
    workspaces: 50,
  },
];

const options = parseOptions(process.argv.slice(2));
if (options.selfTest) {
  runSelfTest();
  console.log(JSON.stringify({ ok: true, suite: "profile-local-data" }));
} else {
  void run().catch(async (error) => {
    console.error(error);
    process.exitCode = 1;
    const { app } = await import("electron");
    app.quit();
  });
}

async function run() {
  trace("loading Electron and repository modules");
  const { app } = await import("electron");
  const { openElectronLocalDataRepository } =
    await import("../src/main/modules/local-data/electron-utility-host.ts");
  trace("waiting for Electron ready");
  await app.whenReady();
  trace("Electron ready");

  const utilityModulePath = resolve(process.cwd(), ".vite/build/utility.js");
  try {
    await access(utilityModulePath);
  } catch {
    throw new Error(
      `Missing production utility bundle ${utilityModulePath}. Run the package ` +
        "profile script so Electron Forge builds it before this harness."
    );
  }

  const root = await mkdtemp(join(tmpdir(), "comma-local-data-profile-"));
  try {
    const context = {
      currentLease: lease("session-profile-a", 1),
      open: async (databasePath) => {
        trace(`opening utility repository ${databasePath}`);
        const repository = await openElectronLocalDataRepository({
          databasePath,
          isCurrentSessionLease: (candidate) =>
            leaseKey(candidate) === leaseKey(context.currentLease),
          modulePath: utilityModulePath,
        });
        trace(`utility repository ready ${databasePath}`);
        return repository;
      },
    };
    const startup = await profileStartup({
      context,
      root,
      samples: options.startupSamples,
      warmup: Math.min(options.warmup, options.startupSamples),
    });
    const scenarioReports = [];
    for (const scenario of scenarios) {
      context.currentLease = lease("session-profile-a", 1);
      scenarioReports.push(
        await profileScenario({
          context,
          profileOptions: options,
          root,
          scenario,
        })
      );
    }
    const workerRecovery = await profileWorkerRecovery({
      app,
      context,
      databasePath: join(root, "recovery.sqlite"),
    });
    const report = {
      acceptance: {
        workerRecovery: {
          pass:
            workerRecovery.recoveredEvents === 1 &&
            workerRecovery.repositoryReady &&
            workerRecovery.schemaVersion > 0 &&
            workerRecovery.workerGenerationAdvanced,
          ...workerRecovery,
        },
      },
      benchmark: {
        name: "comma-local-data-utility-repository",
        schemaVersion: 2,
      },
      machine: {
        arch: process.arch,
        cpu: cpus()[0]?.model ?? "unknown",
        cpuCount: cpus().length,
        electron: process.versions.electron ?? "unknown",
        node: process.version,
        os: `${platform()} ${release()}`,
        totalMemoryBytes: totalmem(),
      },
      method: {
        connectionOwner: "Electron utility process",
        exactLease: "{authorityInstanceId,generation,sessionId,audience}",
        journalMode: "wal",
        mainOwnsSynchronousSqliteConnection: false,
        percentileMethod: "nearest-rank",
        rawPaddingBytesPerEntity: options.rawBytes,
        repository:
          "Main-side async LocalDataRepository over the production utility-process bundle",
        samples: options.samples,
        startupSamples: options.startupSamples,
        warmup: options.warmup,
      },
      scenarios: scenarioReports,
      startup,
    };
    assertTokenFree(report);
    console.log(JSON.stringify(report, null, 2));

    const failures = Object.entries(report.acceptance)
      .filter(([, result]) => !result.pass)
      .map(([name]) => name);
    if (!options.diagnostic && failures.length > 0) {
      throw new Error(
        `LocalData post-change acceptance failed: ${failures.join(", ")}.`
      );
    }
  } finally {
    await rm(root, { force: true, recursive: true });
    app.quit();
  }
}

async function profileStartup({ context, root, samples, warmup }) {
  const cold = [];
  for (let index = 0; index < warmup + samples; index += 1) {
    const startedAt = performance.now();
    const repository = await context.open(join(root, `cold-${index}.sqlite`));
    const elapsed = performance.now() - startedAt;
    await repository.close();
    if (index >= warmup) cold.push(elapsed);
  }

  const warmPath = join(root, "warm.sqlite");
  await (await context.open(warmPath)).close();
  const warm = [];
  for (let index = 0; index < warmup + samples; index += 1) {
    const startedAt = performance.now();
    const repository = await context.open(warmPath);
    const elapsed = performance.now() - startedAt;
    await repository.close();
    if (index >= warmup) warm.push(elapsed);
  }

  return {
    coldUtilitySpawnOpenAndMigrateMs: summarize(cold),
    warmUtilitySpawnAndOpenMs: summarize(warm),
  };
}

async function profileScenario({ context, profileOptions, root, scenario }) {
  const databasePath = join(root, `${scenario.name}.sqlite`);
  const repository = await context.open(databasePath);
  try {
    const workspaces = makeWorkspaces(
      scenario.workspaces,
      PRINCIPAL_ID,
      profileOptions.rawBytes
    );
    const conversationsByWorkspace = distributeConversations({
      count: scenario.cachedConversations,
      principalId: PRINCIPAL_ID,
      rawBytes: profileOptions.rawBytes,
      workspaces,
    });
    await seedRepository({
      conversationsByWorkspace,
      repository,
      session: context.currentLease,
      workspaces,
    });
    const activeWorkspace = workspaces[0];
    const activeConversations = conversationsByWorkspace.get(activeWorkspace.id) ?? [];
    const polledConversations = activeConversations.slice(
      0,
      scenario.polledConversations
    );
    const observedDataScale = await observeDataScale({
      conversationsByWorkspace,
      repository,
      workspaces,
    });
    assertDataScale({
      expectedActiveWorkspaceConversations: activeConversations.length,
      expectedConversations: scenario.cachedConversations,
      expectedWorkspaces: scenario.workspaces,
      observed: observedDataScale,
      scenario: scenario.name,
    });

    const persistenceInput = {
      audience: AUDIENCE,
      conversations: {
        items: polledConversations,
        mode: scenario.persistence,
        workspaceId: activeWorkspace.id,
      },
      principalId: PRINCIPAL_ID,
      session: context.currentLease,
      workspaces: {
        items: workspaces,
        mode: "replace",
      },
    };
    const fallbackRead = () =>
      Promise.all([
        repository.listProductInboxItems({
          audience: AUDIENCE,
          limit: 50,
          principalId: PRINCIPAL_ID,
          workspaceId: activeWorkspace.id,
        }),
        repository.listProductWorkspaces({
          audience: AUDIENCE,
          principalId: PRINCIPAL_ID,
        }),
      ]).then(([items, workspaceRows]) => ({
        items,
        workspaces: workspaceRows.map(({ id, name }) => ({ id, name })),
      }));
    const persist = () => repository.applyProductInboxSync(persistenceInput);

    await warmAsync(persist, profileOptions.warmup);
    await warmAsync(fallbackRead, profileOptions.warmup);
    const persistence = await measureAsyncWithEventLoop(
      persist,
      profileOptions.samples
    );
    const fallback = await measureAsyncWithEventLoop(
      fallbackRead,
      profileOptions.samples
    );
    const payload = await fallbackRead();
    const payloadBytes = Buffer.byteLength(JSON.stringify(payload));
    const clone = measureSync(() => structuredClone(payload), profileOptions.samples);

    return {
      dataScale: {
        configured: {
          activeWorkspaceCachedConversations: activeConversations.length,
          cachedConversations: scenario.cachedConversations,
          polledConversations: scenario.polledConversations,
          rawPaddingBytesPerEntity: profileOptions.rawBytes,
          workspaces: scenario.workspaces,
        },
        observed: observedDataScale,
      },
      logicalUpsertsPerSync: scenario.workspaces + scenario.polledConversations,
      metrics: {
        asyncRepositoryFallbackRoundTripMs: summarize(fallback.samples),
        asyncRepositoryPersistenceRoundTripMs: summarize(persistence.samples),
        mainEventLoopDelayDuringFallbackMs: fallback.eventLoopDelay,
        mainEventLoopDelayDuringPersistenceMs: persistence.eventLoopDelay,
        rendererPayloadBytesProxy: payloadBytes,
        structuredCloneMsProxy: summarize(clone),
      },
      name: scenario.name,
      persistencePath: scenario.persistence,
    };
  } finally {
    await repository.close();
  }
}

async function seedRepository({
  conversationsByWorkspace,
  repository,
  session,
  workspaces,
}) {
  let first = true;
  for (const workspace of workspaces) {
    await repository.applyProductInboxSync({
      audience: AUDIENCE,
      conversations: {
        items: conversationsByWorkspace.get(workspace.id) ?? [],
        mode: "replace",
        workspaceId: workspace.id,
      },
      principalId: PRINCIPAL_ID,
      session,
      workspaces: {
        items: first ? workspaces : [workspace],
        mode: first ? "replace" : "merge",
      },
    });
    first = false;
  }
}

async function observeDataScale({ conversationsByWorkspace, repository, workspaces }) {
  const observedWorkspaces = await repository.listProductWorkspaces({
    audience: AUDIENCE,
    principalId: PRINCIPAL_ID,
  });
  let conversations = 0;
  let activeWorkspaceConversations = 0;
  for (const [index, workspace] of workspaces.entries()) {
    const expected = conversationsByWorkspace.get(workspace.id)?.length ?? 0;
    const rows = await repository.listProductInboxItems({
      audience: AUDIENCE,
      limit: Math.max(1, expected + 1),
      principalId: PRINCIPAL_ID,
      workspaceId: workspace.id,
    });
    conversations += rows.length;
    if (index === 0) activeWorkspaceConversations = rows.length;
  }
  return {
    activeWorkspaceConversations,
    cachedConversations: conversations,
    workspaces: observedWorkspaces.length,
  };
}

async function profileWorkerRecovery({ app, context, databasePath }) {
  const repository = await context.open(databasePath);
  let recoveredEvents = 0;
  const stop = repository.onRecovered(() => {
    recoveredEvents += 1;
  });
  try {
    const before = repository.health();
    const metricsBefore = localDataUtilityMetrics(app);
    const victim = metricsBefore.at(-1);
    if (!victim) {
      return {
        afterPids: [],
        beforePids: [],
        recoveredEvents,
        repositoryReady: false,
        schemaVersion: 0,
        workerGenerationAdvanced: false,
      };
    }
    process.kill(victim.pid, "SIGKILL");
    await waitUntil(
      () =>
        repository.health().status === "ready" &&
        repository.health().workerGeneration > before.workerGeneration,
      10_000
    );
    const after = repository.health();
    const metricsAfter = localDataUtilityMetrics(app);
    return {
      afterPids: metricsAfter.map(({ pid }) => pid),
      beforePids: metricsBefore.map(({ pid }) => pid),
      recoveredEvents,
      repositoryReady: after.status === "ready",
      schemaVersion: await repository.schemaVersion(),
      workerGenerationAdvanced: after.workerGeneration > before.workerGeneration,
    };
  } finally {
    stop();
    await repository.close();
  }
}

function localDataUtilityMetrics(app) {
  const metrics = app
    .getAppMetrics()
    .filter((metric) => metric.type === "Utility")
    .map(({ name, pid, serviceName, type }) => ({
      name,
      pid,
      serviceName,
      type,
    }));
  const named = metrics.filter(
    (metric) =>
      metric.name?.toLowerCase().includes("local data") ||
      metric.serviceName?.toLowerCase().includes("local data")
  );
  return named.length > 0 ? named : metrics;
}

async function waitUntil(predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolveWait) => setTimeout(resolveWait, 25));
  }
  throw new Error(`Timed out after ${timeoutMs} ms.`);
}

async function measureAsyncWithEventLoop(operation, iterations) {
  const delay = monitorEventLoopDelay({ resolution: 1 });
  delay.enable();
  delay.reset();
  const samples = [];
  for (let index = 0; index < iterations; index += 1) {
    const startedAt = performance.now();
    await operation();
    samples.push(performance.now() - startedAt);
  }
  delay.disable();
  return {
    eventLoopDelay: {
      max: nanosecondsToMilliseconds(delay.max),
      mean: nanosecondsToMilliseconds(delay.mean),
      p50: nanosecondsToMilliseconds(delay.percentile(50)),
      p95: nanosecondsToMilliseconds(delay.percentile(95)),
    },
    samples,
  };
}

async function warmAsync(operation, iterations) {
  for (let index = 0; index < iterations; index += 1) {
    await operation();
  }
}

function measureSync(operation, iterations) {
  const values = [];
  for (let index = 0; index < iterations; index += 1) {
    const startedAt = performance.now();
    operation();
    values.push(performance.now() - startedAt);
  }
  return values;
}

function nanosecondsToMilliseconds(value) {
  return round(Number.isFinite(value) ? value / 1_000_000 : 0);
}

function distributeConversations({ count, principalId, rawBytes, workspaces }) {
  const rows = new Map();
  let remaining = count;
  for (let index = 0; index < workspaces.length; index += 1) {
    const remainingWorkspaces = workspaces.length - index;
    const workspaceCount = Math.ceil(remaining / remainingWorkspaces);
    const workspaceId = workspaces[index].id;
    rows.set(
      workspaceId,
      makeConversations({
        count: workspaceCount,
        principalId,
        rawBytes,
        updatedAtBase: 1_700_000_000_000 + index * 1_000_000,
        workspaceId,
      })
    );
    remaining -= workspaceCount;
  }
  return rows;
}

function makeWorkspaces(count, principalId, rawBytes) {
  return Array.from({ length: count }, (_, index) => {
    const id = `workspace-${String(index).padStart(3, "0")}`;
    return {
      audience: AUDIENCE,
      id,
      name: `Workspace ${index}`,
      principalId,
      raw: {
        id,
        name: `Workspace ${index}`,
        padding: "w".repeat(rawBytes),
      },
    };
  });
}

function makeConversations({
  count,
  principalId,
  rawBytes,
  updatedAtBase,
  workspaceId,
}) {
  return Array.from({ length: count }, (_, index) => {
    const id = `conversation-${String(index).padStart(6, "0")}`;
    return {
      audience: AUDIENCE,
      createdAt: 1_700_000_000_000 + index,
      freshness: "fresh",
      id,
      kind: index === 0 ? "agent_task" : "user_chat",
      principalId,
      raw: {
        id,
        padding: "c".repeat(rawBytes),
        status: index === 0 ? "running" : "open",
        title: `Conversation ${index}`,
        workspace_id: workspaceId,
      },
      status: index === 0 ? "running" : "open",
      title: `Conversation ${index}`,
      updatedAt: updatedAtBase + count - index,
      workspaceId,
    };
  });
}

function lease(sessionId, generation) {
  return {
    audience: AUDIENCE,
    authorityInstanceId: "profile-authority-instance",
    generation,
    sessionId,
  };
}

function leaseKey(value) {
  return JSON.stringify([
    value.authorityInstanceId,
    value.generation,
    value.sessionId,
    value.audience,
  ]);
}

function assertDataScale({
  expectedActiveWorkspaceConversations,
  expectedConversations,
  expectedWorkspaces,
  observed,
  scenario,
}) {
  if (
    observed.activeWorkspaceConversations !== expectedActiveWorkspaceConversations ||
    observed.cachedConversations !== expectedConversations ||
    observed.workspaces !== expectedWorkspaces
  ) {
    throw new Error(
      `${scenario} seeded an unexpected data scale: ${JSON.stringify({
        expected: {
          activeWorkspaceConversations: expectedActiveWorkspaceConversations,
          cachedConversations: expectedConversations,
          workspaces: expectedWorkspaces,
        },
        observed,
      })}`
    );
  }
}

function summarize(values) {
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

function percentile(sorted, quantile) {
  const index = Math.max(0, Math.ceil(sorted.length * quantile) - 1);
  return sorted[index] ?? 0;
}

function round(value) {
  return Number(value.toFixed(3));
}

function assertTokenFree(value) {
  if (JSON.stringify(value).includes("profile-bearer-secret")) {
    throw new Error("LocalData profiler report reflected a bearer.");
  }
}

function trace(message) {
  if (process.env.COMMA_PROFILE_DEBUG === "1") {
    console.error(`[profile-local-data] ${message}`);
  }
}

function parseOptions(args) {
  const parsed = {
    diagnostic: false,
    rawBytes: DEFAULT_RAW_BYTES,
    samples: DEFAULT_SAMPLES,
    selfTest: false,
    startupSamples: DEFAULT_STARTUP_SAMPLES,
    warmup: DEFAULT_WARMUP,
  };
  for (const argument of args) {
    if (
      argument === "--" ||
      argument === "--experimental-strip-types" ||
      argument === "--no-warnings" ||
      /profile-local-data\.(?:mjs|js)$/.test(argument)
    ) {
      continue;
    }
    if (argument === "--diagnostic") {
      parsed.diagnostic = true;
      continue;
    }
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
    if (name === "--raw-bytes") parsed.rawBytes = value;
    else if (name === "--samples") parsed.samples = value;
    else if (name === "--startup-samples") parsed.startupSamples = value;
    else if (name === "--warmup") parsed.warmup = value;
    else throw new Error(`Unknown option ${name}`);
  }
  return parsed;
}

function runSelfTest() {
  const parsed = parseOptions([
    "--samples=3",
    "--startup-samples=2",
    "--warmup=1",
    "--raw-bytes=64",
    "--diagnostic",
  ]);
  if (
    parsed.samples !== 3 ||
    parsed.startupSamples !== 2 ||
    parsed.warmup !== 1 ||
    parsed.rawBytes !== 64 ||
    !parsed.diagnostic
  ) {
    throw new Error("LocalData profiler option parsing self-test failed.");
  }
  const summary = summarize([4, 1, 3, 2]);
  if (summary.p50 !== 2 || summary.p95 !== 4) {
    throw new Error("LocalData profiler percentile self-test failed.");
  }
  const first = lease("a", 1);
  const second = lease("b", 2);
  if (leaseKey(first) === leaseKey(second)) {
    throw new Error("LocalData profiler lease identity self-test failed.");
  }
  assertTokenFree({ session: first });
}
