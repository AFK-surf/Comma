const REPO_ROOT = new URL("../../..", import.meta.url).pathname;
const RUNNER_DIR = `${REPO_ROOT}/systems/connector/mac-mini-provisioner`;

function activeProvisionRequestRead(
  request: Request,
  url: URL,
): Response | undefined {
  if (
    request.method === "GET" &&
    url.pathname ===
      "/v1/orgs/org-e2e/runners/runner-e2e/provision-requests/request-e2e"
  ) {
    return Response.json({
      provision_request: { id: "request-e2e", status: "connected" },
    });
  }
}

Deno.test({
  name: "BFT runner keeps running when one control response is not valid JSON",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const root = await Deno.makeTempDir({ prefix: "bft-runner-continuity-" });
    let registerCount = 0;
    let heartbeatCount = 0;
    let recoveredBeforeRegistration = false;
    const connectorStarts = `${root}/connector-starts`;
    const connectorPIDs = `${root}/connector-pids`;
    const requests: string[] = [];
    const server = Deno.serve(
      { hostname: "127.0.0.1", port: 0, onListen: () => {} },
      async (request) => {
        const url = new URL(request.url);
        requests.push(url.pathname);
        await request.text();

        if (url.pathname === "/v1/orgs/org-e2e/runners") {
          registerCount++;
          if (registerCount <= 30) {
            return new Response("runner-e2e-register-502", {
              status: 502,
              headers: { "content-type": "text/html; charset=utf-8" },
            });
          }
          const starts = (
            await Deno.readTextFile(connectorStarts).catch(() => "")
          )
            .trim()
            .split("\n")
            .filter(Boolean);
          const pids = (await Deno.readTextFile(connectorPIDs).catch(() => ""))
            .trim()
            .split("\n")
            .filter(Boolean);
          recoveredBeforeRegistration = starts.length >= 2 &&
            pids.length >= 2 &&
            processAlive(Number(pids[1]));
          return Response.json(
            { runner: { id: "runner-e2e" } },
            {
              status: 201,
            },
          );
        }
        if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/heartbeat") {
          heartbeatCount++;
          if (heartbeatCount === 1) {
            return new Response("runner-e2e-upstream-502", {
              status: 502,
              headers: { "content-type": "text/html; charset=utf-8" },
            });
          }
          return Response.json({ runner: { id: "runner-e2e" }, updates: {} });
        }
        if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/claim") {
          return new Response(null, { status: 204 });
        }
        if (
          url.pathname ===
            "/v1/orgs/org-e2e/runners/runner-e2e/provision-requests/request-e2e"
        ) {
          return Response.json({
            provision_request: { id: "request-e2e", status: "running" },
          });
        }
        return new Response("not found", { status: 404 });
      },
    );

    try {
      const binary = `${root}/bft-runner`;
      const connector = `${root}/salix-connect`;
      const config = `${root}/runner.json`;
      await buildRunner(binary);
      await writeVersionedConnector(connector, "connector-e2e-v1");
      await writeRunnerConfig(config, root, connector, serverURL(server));
      await writeStoredConnector(root, "request-e2e");

      const result = await run(
        binary,
        [
          "run",
          "--config",
          config,
          "--start=true",
          "--loop=true",
          "--max-iterations=2",
          "--interval=0.01",
          "--timeout=1",
        ],
        {
          CONNECTOR_PID_FILE: connectorPIDs,
          CONNECTOR_START_FILE: connectorStarts,
          CONNECTOR_STATUS_FILE:
            `${root}/state/connectors/request-e2e.status.json`,
        },
      );

      const failures: string[] = [];
      if (result.code !== 0) {
        failures.push(`runner exited with ${result.code}`);
      }
      if (heartbeatCount !== 2) {
        failures.push(
          `expected 2 heartbeats after recovery, got ${heartbeatCount}`,
        );
      }
      if (registerCount !== 31) {
        failures.push(
          `expected 31 registration attempts, got ${registerCount}`,
        );
      }
      if (!recoveredBeforeRegistration) {
        failures.push(
          "connector was not recovered while registration remained unavailable",
        );
      }
      for (
        const evidence of [
          "HTTP 502",
          "text/html",
          "runner-e2e-upstream-502",
        ]
      ) {
        if (!result.combined.includes(evidence)) {
          failures.push(
            `missing diagnostic evidence ${JSON.stringify(evidence)}`,
          );
        }
      }
      if (!requests.includes("/v1/orgs/org-e2e/runners/runner-e2e/claim")) {
        failures.push("runner did not resume the control loop after recovery");
      }
      const pids = (await Deno.readTextFile(connectorPIDs)).trim().split("\n");
      if (pids.length !== 2 || !processAlive(Number(pids[1]))) {
        failures.push(`connector recovery did not settle: ${pids.join(",")}`);
      }
      const runnerStatus = JSON.parse(
        await Deno.readTextFile(`${root}/state/runner-status.json`),
      );
      if (
        runnerStatus.status !== "connected" ||
        runnerStatus.managed_connectors?.[0]?.attached !== true ||
        runnerStatus.managed_connectors?.[0]?.connector_run_id !== "run-e2e"
      ) {
        failures.push(
          `runner ignored connected local connector state: ${
            JSON.stringify(
              runnerStatus,
            )
          }`,
        );
      }
      if (failures.length > 0) {
        throw new Error(`${failures.join("\n")}\n${result.combined}`);
      }
    } finally {
      await killRecordedProcesses(`${root}/connector-pids`);
      await server.shutdown();
      await Deno.remove(root, { recursive: true }).catch(() => {});
    }
  },
});

Deno.test({
  name:
    "BFT runner restarts an attached connector when status reporting is rejected",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn(t) {
    const buildRoot = await Deno.makeTempDir({
      prefix: "bft-runner-recovery-build-",
    });
    try {
      const binary = `${buildRoot}/bft-runner`;
      await buildRunner(binary);
      await t.step(
        "recovers across repeated process exits",
        () => runRejectedStatusRecoveryScenario(binary, false),
      );
      await t.step(
        "keeps restart-pending truth when replacement spawn fails",
        () => runRejectedStatusRecoveryScenario(binary, true),
      );
      await t.step(
        "retries a host-restored connector after a transient spawn failure",
        () => runHostRestoreRetryScenario(binary),
      );
      await t.step(
        "does not project a connector that exits during heartbeat as connected",
        () => runExitDuringControlCallScenario(binary, "heartbeat"),
      );
      await t.step(
        "does not project a connector that exits during claim as connected",
        () => runExitDuringControlCallScenario(binary, "claim"),
      );
    } finally {
      await Deno.remove(buildRoot, { recursive: true }).catch(() => {});
    }
  },
});

async function runRejectedStatusRecoveryScenario(
  binary: string,
  failReplacementSpawn: boolean,
) {
  const root = await Deno.makeTempDir({ prefix: "bft-runner-recovery-" });
  let heartbeatCount = 0;
  let rejectedStatusCount = 0;
  const server = Deno.serve(
    { hostname: "127.0.0.1", port: 0, onListen: () => {} },
    async (request) => {
      const url = new URL(request.url);
      await request.text();

      if (url.pathname === "/v1/orgs/org-e2e/runners") {
        return Response.json({ runner: { id: "runner-e2e" } }, { status: 201 });
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/heartbeat") {
        heartbeatCount++;
        return Response.json({ runner: { id: "runner-e2e" }, updates: {} });
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/claim") {
        return new Response(null, { status: 204 });
      }
      if (
        url.pathname ===
          "/v1/orgs/org-e2e/runners/runner-e2e/provision-requests/request-e2e/status"
      ) {
        rejectedStatusCount++;
        return Response.json(
          {
            error: { code: "invalid_provisioner_status_transition" },
          },
          { status: 409 },
        );
      }
      return activeProvisionRequestRead(request, url) ??
        new Response("not found", { status: 404 });
    },
  );

  try {
    const connector = `${root}/salix-connect`;
    const connectorPIDs = `${root}/connector-pids`;
    const connectorStarts = `${root}/connector-starts`;
    const connectorStatus = `${root}/state/connectors/request-e2e.status.json`;
    const config = `${root}/runner.json`;
    await writeExecutable(
      connector,
      [
        "#!/bin/sh",
        'if [ "$1" = "version" ]; then',
        `  printf '%s\\n' '${
          JSON.stringify({
            component: "salix-connect",
            version: "connector-e2e-v1",
            release_id: "connector-e2e-v1",
          })
        }'`,
        "  exit 0",
        "fi",
        'printf "%s\\n" "$$" >> "$CONNECTOR_PID_FILE"',
        'printf "started\\n" >> "$CONNECTOR_START_FILE"',
        'start_number="$(wc -l < "$CONNECTOR_START_FILE" | tr -d " ")"',
        'printf \'{"state":"connected","connector_run_id":"run-e2e-%s"}\\n\' "$start_number" > "$CONNECTOR_STATUS_FILE"',
        ...(failReplacementSpawn
          ? [
            'if [ "$start_number" = "1" ]; then',
            '  chmod 0644 "$0"',
            "  exit 7",
            "fi",
          ]
          : [
            'if [ "$start_number" -le "3" ]; then',
            "  sleep 0.08",
            "  exit 7",
            "fi",
          ]),
        "trap 'exit 0' TERM INT",
        "while :; do sleep 1; done",
        "",
      ].join("\n"),
    );
    await writeRunnerConfig(config, root, connector, serverURL(server));
    await writeStoredConnector(root, "request-e2e");

    const iterations = 20;
    const result = await run(
      binary,
      [
        "run",
        "--config",
        config,
        "--start=true",
        "--loop=true",
        `--max-iterations=${iterations}`,
        "--interval=0.05",
        "--timeout=1",
      ],
      {
        CONNECTOR_PID_FILE: connectorPIDs,
        CONNECTOR_START_FILE: connectorStarts,
        CONNECTOR_STATUS_FILE: connectorStatus,
      },
    );

    const starts = (await Deno.readTextFile(connectorStarts))
      .trim()
      .split("\n");
    const pids = (await Deno.readTextFile(connectorPIDs)).trim().split("\n");
    const runnerStatus = JSON.parse(
      await Deno.readTextFile(`${root}/state/runner-status.json`),
    );
    const managed = runnerStatus.managed_connectors?.[0] ?? {};
    const failures: string[] = [];
    if (result.code !== 0) {
      failures.push(`runner exited with ${result.code}`);
    }
    if (heartbeatCount !== iterations) {
      failures.push(`expected ${iterations} heartbeats, got ${heartbeatCount}`);
    }
    if (rejectedStatusCount === 0) {
      failures.push("status rejection path was not exercised");
    }
    if (failReplacementSpawn) {
      if (Number(managed.restart_count) > heartbeatCount) {
        failures.push(
          `replacement spawn retried ${managed.restart_count} times across ${heartbeatCount} control iterations`,
        );
      }
      if (starts.length !== 1 || pids.length !== 1) {
        failures.push(
          `spawn failure unexpectedly launched another connector: ${starts.length}/${pids.length}`,
        );
      }
      if (
        runnerStatus.status !== "connector_restart_pending" ||
        managed.attached !== false ||
        "pid" in managed ||
        "connector_run_id" in managed
      ) {
        failures.push(
          `restart-pending connector was projected as live: ${
            JSON.stringify(
              runnerStatus,
            )
          }`,
        );
      }
    } else {
      if (starts.length !== 4) {
        failures.push(`expected three recovery starts, got ${starts.length}`);
      }
      if (pids.length !== 4 || !processAlive(Number(pids[3]))) {
        failures.push(`recovered connector is not alive: ${pids.join(",")}`);
      }
      if (
        runnerStatus.status !== "connected" ||
        managed.connector_run_id !== "run-e2e-4"
      ) {
        failures.push(
          `recovered connector did not project its new run: ${
            JSON.stringify(
              runnerStatus,
            )
          }`,
        );
      }
    }
    if (failures.length > 0) {
      throw new Error(`${failures.join("\n")}\n${result.combined}`);
    }
  } finally {
    await killRecordedProcesses(`${root}/connector-pids`);
    await server.shutdown();
    await Deno.remove(root, { recursive: true }).catch(() => {});
  }
}

async function runHostRestoreRetryScenario(binary: string) {
  const root = await Deno.makeTempDir({ prefix: "bft-runner-host-restore-" });
  let heartbeatCount = 0;
  const server = Deno.serve(
    { hostname: "127.0.0.1", port: 0, onListen: () => {} },
    async (request) => {
      const url = new URL(request.url);
      await request.text();
      if (url.pathname === "/v1/orgs/org-e2e/runners") {
        return Response.json({ runner: { id: "runner-e2e" } }, { status: 201 });
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/heartbeat") {
        heartbeatCount++;
        return Response.json({ runner: { id: "runner-e2e" }, updates: {} });
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/claim") {
        return new Response(null, { status: 204 });
      }
      if (
        url.pathname ===
          "/v1/orgs/org-e2e/runners/runner-e2e/provision-requests/request-e2e/status"
      ) {
        return Response.json(
          {
            error: { code: "invalid_provisioner_status_transition" },
          },
          { status: 409 },
        );
      }
      return activeProvisionRequestRead(request, url) ??
        new Response("not found", { status: 404 });
    },
  );

  try {
    const connector = `${root}/salix-connect`;
    const connectorPIDs = `${root}/connector-pids`;
    const connectorStatus = `${root}/state/connectors/request-e2e.status.json`;
    const config = `${root}/runner.json`;
    await writeVersionedConnector(connector, "connector-e2e-v1");
    await Deno.chmod(connector, 0o644);
    const repairConnector = new Promise<void>((resolve) => {
      setTimeout(async () => {
        await Deno.chmod(connector, 0o755);
        resolve();
      }, 250);
    });
    await writeRunnerConfig(config, root, connector, serverURL(server));
    await writeStoredConnector(root, "request-e2e");

    const iterations = 20;
    const result = await run(
      binary,
      [
        "run",
        "--config",
        config,
        "--start=true",
        "--loop=true",
        `--max-iterations=${iterations}`,
        "--interval=0.05",
        "--timeout=1",
      ],
      {
        CONNECTOR_PID_FILE: connectorPIDs,
        CONNECTOR_STATUS_FILE: connectorStatus,
      },
    );
    await repairConnector;

    const pids = (await Deno.readTextFile(connectorPIDs).catch(() => ""))
      .trim()
      .split("\n")
      .filter(Boolean);
    const runnerStatus = JSON.parse(
      await Deno.readTextFile(`${root}/state/runner-status.json`),
    );
    const failures: string[] = [];
    if (result.code !== 0) {
      failures.push(`runner exited with ${result.code}`);
    }
    if (heartbeatCount !== iterations) {
      failures.push(`expected ${iterations} heartbeats, got ${heartbeatCount}`);
    }
    if (pids.length !== 1 || !processAlive(Number(pids[0]))) {
      failures.push(`restored connector is not alive: ${pids.join(",")}`);
    }
    if (
      runnerStatus.status !== "connected" ||
      runnerStatus.managed_connectors?.[0]?.connector_run_id !== "run-e2e"
    ) {
      failures.push(
        `restored connector did not reach connected: ${
          JSON.stringify(
            runnerStatus,
          )
        }`,
      );
    }
    if (failures.length > 0) {
      throw new Error(`${failures.join("\n")}\n${result.combined}`);
    }
  } finally {
    await killRecordedProcesses(`${root}/connector-pids`);
    await server.shutdown();
    await Deno.remove(root, { recursive: true }).catch(() => {});
  }
}

async function runExitDuringControlCallScenario(
  binary: string,
  killDuring: "heartbeat" | "claim",
) {
  const root = await Deno.makeTempDir({
    prefix: `bft-runner-exit-during-${killDuring}-`,
  });
  const connectorPIDs = `${root}/connector-pids`;
  const connectorStatus = `${root}/state/connectors/request-e2e.status.json`;
  let killedPID = 0;
  const killCurrentConnector = async () => {
    await waitUntil(async () => {
      const raw = await Deno.readTextFile(connectorPIDs).catch(() => "");
      killedPID = Number(raw.trim().split("\n").filter(Boolean).at(-1) ?? 0);
      const statusExists = await Deno.stat(connectorStatus)
        .then(() => true)
        .catch(() => false);
      return killedPID > 0 && statusExists;
    });
    Deno.kill(killedPID, "SIGKILL");
    await waitUntil(() => !processAlive(killedPID));
  };
  const server = Deno.serve(
    { hostname: "127.0.0.1", port: 0, onListen: () => {} },
    async (request) => {
      const url = new URL(request.url);
      await request.text();
      if (url.pathname === "/v1/orgs/org-e2e/runners") {
        return Response.json({ runner: { id: "runner-e2e" } }, { status: 201 });
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/heartbeat") {
        if (killDuring === "heartbeat") {
          await killCurrentConnector();
        }
        return Response.json({ runner: { id: "runner-e2e" }, updates: {} });
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/claim") {
        if (killDuring === "claim") {
          await killCurrentConnector();
        }
        return new Response(null, { status: 204 });
      }
      return activeProvisionRequestRead(request, url) ??
        new Response("not found", { status: 404 });
    },
  );

  try {
    const connector = `${root}/salix-connect`;
    const config = `${root}/runner.json`;
    await writeExecutable(
      connector,
      [
        "#!/bin/sh",
        'if [ "$1" = "version" ]; then',
        `  printf '%s\\n' '${
          JSON.stringify({
            component: "salix-connect",
            version: "connector-e2e-v1",
            release_id: "connector-e2e-v1",
          })
        }'`,
        "  exit 0",
        "fi",
        'printf "%s\\n" "$$" >> "$CONNECTOR_PID_FILE"',
        `printf '%s\\n' '${
          JSON.stringify({
            state: "connected",
            connector_run_id: "run-e2e",
          })
        }' > "$CONNECTOR_STATUS_FILE"`,
        "trap 'exit 0' TERM INT",
        "while :; do sleep 1; done",
        "",
      ].join("\n"),
    );
    await writeRunnerConfig(config, root, connector, serverURL(server));
    await writeStoredConnector(root, "request-e2e");

    const result = await run(
      binary,
      [
        "run",
        "--config",
        config,
        "--start=true",
        "--loop=true",
        "--max-iterations=1",
        "--interval=0.01",
        "--timeout=2",
      ],
      {
        CONNECTOR_PID_FILE: connectorPIDs,
        CONNECTOR_STATUS_FILE: connectorStatus,
      },
    );
    assertEquals(result.code, 0, result.combined);
    const runnerStatus = JSON.parse(
      await Deno.readTextFile(`${root}/state/runner-status.json`),
    );
    const managed = runnerStatus.managed_connectors?.[0] ?? {};
    if (
      runnerStatus.status !== "connector_restart_pending" ||
      managed.attached !== false ||
      "pid" in managed ||
      "connector_run_id" in managed ||
      "connector_run_id" in runnerStatus
    ) {
      throw new Error(
        `dead connector ${killedPID} retained a live projection: ${
          JSON.stringify(
            runnerStatus,
          )
        }\n${result.combined}`,
      );
    }
  } finally {
    await killRecordedProcesses(connectorPIDs);
    await server.shutdown();
    await Deno.remove(root, { recursive: true }).catch(() => {});
  }
}

async function waitUntil(predicate: () => boolean | Promise<boolean>) {
  const deadline = Date.now() + 2_000;
  while (!(await predicate())) {
    if (Date.now() >= deadline) {
      throw new Error("timed out waiting for E2E condition");
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

Deno.test({
  name:
    "BFT runner system service stop fails closed without administrator access",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const root = await Deno.makeTempDir({ prefix: "bft-runner-service-" });
    try {
      const binary = `${root}/bft-runner`;
      const binDir = `${root}/bin`;
      const launchctlLog = `${root}/launchctl.log`;
      const sourcePlist = `${root}/source.plist`;
      const installPlist =
        `${root}/Library/LaunchDaemons/com.bridgeforteams.runner.plist`;
      const config = `${root}/runner.json`;
      await buildRunner(binary);
      await Deno.mkdir(binDir, { recursive: true });
      await Deno.mkdir(new URL(".", `file://${installPlist}`).pathname, {
        recursive: true,
      });
      await Deno.writeTextFile(sourcePlist, "plist\n");
      await Deno.writeTextFile(installPlist, "plist\n");
      await writeExecutable(
        `${binDir}/launchctl`,
        [
          "#!/bin/sh",
          `printf '%s\\n' "$*" >> ${shellQuote(launchctlLog)}`,
          'if [ "$*" = "bootout system/com.bridgeforteams.runner" ]; then exit 0; fi',
          "exit 42",
          "",
        ].join("\n"),
      );
      await Deno.writeTextFile(
        config,
        JSON.stringify({
          api_base_url: "http://127.0.0.1:1",
          org_id: "org-e2e",
          runner_token: "runner-token",
          paths: {
            state_dir: `${root}/state`,
            runner_install_status: `${root}/runner-install-status.json`,
          },
          launchd: {
            label: "com.bridgeforteams.runner",
            domain: "system",
            source_plist: sourcePlist,
            install_plist: installPlist,
          },
        }),
      );

      const result = await run(
        binary,
        ["service", "stop", "--config", config],
        { PATH: `${binDir}:${Deno.env.get("PATH") ?? ""}` },
      );

      if (result.code === 0) {
        throw new Error(
          `system service stop unexpectedly succeeded:\n${result.combined}`,
        );
      }
      assertIncludes(
        result.combined,
        "service.system_administrator_action_required",
      );
      assertIncludes(result.combined, "administrator");
      assertIncludes(
        result.combined,
        "agent-vmm-service-executor stop --job runner",
      );
      if (await pathExists(launchctlLog)) {
        throw new Error("unprivileged service stop invoked launchctl");
      }
    } finally {
      await Deno.remove(root, { recursive: true }).catch(() => {});
    }
  },
});

Deno.test({
  name:
    "BFT runner applies only exact connector artifacts and preserves continuity",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn(t) {
    const buildRoot = await Deno.makeTempDir({
      prefix: "bft-runner-update-build-",
    });
    try {
      const binary = `${buildRoot}/bft-runner`;
      await buildRunner(binary);
      await t.step(
        "applies an exact URL, digest, and size and reports the observed digest",
        () => runVerifiedConnectorUpdate(binary),
      );
      await t.step(
        "does not download an artifact whose digest is already installed",
        () => runSameDigestNoop(binary),
      );
      await t.step(
        "rejects corrupt bytes without replacing the installed connector",
        () => runRejectedConnectorUpdate(binary, "corrupt_bytes"),
      );
      await t.step(
        "rolls back when the staged connector fails its health probe",
        () => runRejectedConnectorUpdate(binary, "health_probe"),
      );
    } finally {
      await Deno.remove(buildRoot, { recursive: true }).catch(() => {});
    }
  },
});

async function runVerifiedConnectorUpdate(binary: string) {
  const root = await Deno.makeTempDir({ prefix: "bft-runner-update-" });
  const heartbeatDigests: Array<string | undefined> = [];
  const targetVersion = "connector-e2e-v2";
  const artifact = versionedConnectorScript(targetVersion);
  const artifactSHA = await sha256Hex(new TextEncoder().encode(artifact));
  let heartbeatCount = 0;
  const artifactServer = Deno.serve(
    { hostname: "127.0.0.1", port: 0, onListen: () => {} },
    (request) => {
      if (new URL(request.url).pathname === "/connector-v2") {
        return new Response(artifact, { status: 200 });
      }
      return new Response("not found", { status: 404 });
    },
  );
  const artifactURL = `${serverURL(artifactServer)}/connector-v2`;
  const server = Deno.serve(
    { hostname: "127.0.0.1", port: 0, onListen: () => {} },
    async (request): Promise<Response> => {
      const url = new URL(request.url);
      const body = request.method === "POST"
        ? JSON.parse((await request.text()) || "{}")
        : {};
      if (url.pathname === "/v1/orgs/org-e2e/runners") {
        return Response.json(
          { runner: { id: "runner-e2e" } },
          {
            status: 201,
          },
        );
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/heartbeat") {
        heartbeatCount++;
        heartbeatDigests.push(
          body.capabilities?.component_digests?.["salix-connect"],
        );
        return Response.json({
          runner: { id: "runner-e2e" },
          updates: heartbeatCount === 1
            ? {
              "salix-connect": {
                component: "salix-connect",
                artifact_url: artifactURL,
                sha256: artifactSHA,
                size: new TextEncoder().encode(artifact).byteLength,
              },
            }
            : {},
        });
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/claim") {
        return new Response(null, { status: 204 });
      }
      return activeProvisionRequestRead(request, url) ??
        new Response("not found", { status: 404 });
    },
  );
  try {
    const connector = `${root}/salix-connect`;
    const config = `${root}/runner.json`;
    await writeVersionedConnector(connector, "connector-e2e-v1");
    await writeRunnerConfig(config, root, connector, serverURL(server));

    const result = await run(
      binary,
      [
        "run",
        "--config",
        config,
        "--start=true",
        "--loop=true",
        "--max-iterations=2",
        "--interval=0.01",
        "--timeout=1",
      ],
    );

    assertEquals(result.code, 0, result.combined);
    assertEquals(
      heartbeatDigests,
      [
        await sha256Hex(await Deno.readFile(`${connector}.previous`)),
        artifactSHA,
      ],
      result.combined,
    );
    const version = await run(connector, ["version", "--json"]);
    assertEquals(JSON.parse(version.stdout).version, targetVersion);
  } finally {
    await server.shutdown();
    await artifactServer.shutdown();
    await Deno.remove(root, { recursive: true }).catch(() => {});
  }
}

async function runSameDigestNoop(binary: string) {
  const root = await Deno.makeTempDir({ prefix: "bft-runner-update-noop-" });
  const artifact = versionedConnectorScript("connector-e2e-v1");
  const artifactBytes = new TextEncoder().encode(artifact);
  const artifactSHA = await sha256Hex(artifactBytes);
  let artifactRequests = 0;
  const artifactServer = Deno.serve(
    { hostname: "127.0.0.1", port: 0, onListen: () => {} },
    () => {
      artifactRequests++;
      return new Response(artifact);
    },
  );
  const server = updateServer({
    artifactURL: `${serverURL(artifactServer)}/connector-v1`,
    artifactSHA,
    artifactSize: artifactBytes.byteLength,
  });
  try {
    const connector = `${root}/salix-connect`;
    const config = `${root}/runner.json`;
    await writeExecutable(connector, artifact);
    await writeRunnerConfig(config, root, connector, serverURL(server));
    const before = await sha256Hex(await Deno.readFile(connector));

    const result = await run(binary, [
      "run",
      "--config",
      config,
      "--start=true",
      "--loop=true",
      "--max-iterations=1",
      "--interval=0.01",
      "--timeout=1",
    ]);

    assertEquals(result.code, 0, result.combined);
    assertEquals(artifactRequests, 0, result.combined);
    assertEquals(await sha256Hex(await Deno.readFile(connector)), before);
  } finally {
    await server.shutdown();
    await artifactServer.shutdown();
    await Deno.remove(root, { recursive: true }).catch(() => {});
  }
}

async function runRejectedConnectorUpdate(
  binary: string,
  mode: "corrupt_bytes" | "health_probe",
) {
  const root = await Deno.makeTempDir({
    prefix: `bft-runner-update-${mode}-`,
  });
  const advertisedArtifact = mode === "health_probe"
    ? "#!/bin/sh\nexit 23\n"
    : versionedConnectorScript("connector-e2e-v2");
  const servedArtifact = mode === "corrupt_bytes"
    ? `${advertisedArtifact}\ncorrupt\n`
    : advertisedArtifact;
  const advertisedBytes = new TextEncoder().encode(advertisedArtifact);
  const artifactSHA = await sha256Hex(advertisedBytes);
  let artifactRequests = 0;
  const artifactServer = Deno.serve(
    { hostname: "127.0.0.1", port: 0, onListen: () => {} },
    (request) => {
      if (new URL(request.url).pathname === "/connector-v2") {
        artifactRequests++;
        return new Response(servedArtifact, { status: 200 });
      }
      return new Response("not found", { status: 404 });
    },
  );
  const server = updateServer({
    artifactURL: `${serverURL(artifactServer)}/connector-v2`,
    artifactSHA,
    artifactSize: advertisedBytes.byteLength,
  });
  try {
    const connector = `${root}/salix-connect`;
    const config = `${root}/runner.json`;
    await writeVersionedConnector(connector, "connector-e2e-v1");
    await writeRunnerConfig(config, root, connector, serverURL(server));
    const before = await sha256Hex(await Deno.readFile(connector));

    const result = await run(
      binary,
      [
        "run",
        "--config",
        config,
        "--start=true",
        "--loop=true",
        "--max-iterations=1",
        "--interval=0.01",
        "--timeout=1",
      ],
    );

    assertEquals(result.code, 0, result.combined);
    assertEquals(artifactRequests, 1, result.combined);
    assertEquals(await sha256Hex(await Deno.readFile(connector)), before);
    const version = await run(connector, ["version", "--json"]);
    assertEquals(JSON.parse(version.stdout).version, "connector-e2e-v1");
  } finally {
    await server.shutdown();
    await artifactServer.shutdown();
    await Deno.remove(root, { recursive: true }).catch(() => {});
  }
}

function updateServer(target: {
  artifactURL: string;
  artifactSHA: string;
  artifactSize: number;
}) {
  return Deno.serve(
    { hostname: "127.0.0.1", port: 0, onListen: () => {} },
    async (request): Promise<Response> => {
      const url = new URL(request.url);
      await request.text();
      if (url.pathname === "/v1/orgs/org-e2e/runners") {
        return Response.json({ runner: { id: "runner-e2e" } }, { status: 201 });
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/heartbeat") {
        return Response.json({
          runner: { id: "runner-e2e" },
          updates: {
            "salix-connect": {
              component: "salix-connect",
              artifact_url: target.artifactURL,
              sha256: target.artifactSHA,
              size: target.artifactSize,
            },
          },
        });
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/claim") {
        return new Response(null, { status: 204 });
      }
      return activeProvisionRequestRead(request, url) ??
        new Response("not found", { status: 404 });
    },
  );
}

async function buildRunner(path: string) {
  const result = await run(
    "go",
    ["build", "-tags", "bft_insecure_artifact_test", "-o", path, "."],
    undefined,
    RUNNER_DIR,
  );
  assertEquals(result.code, 0, result.combined);
}

async function writeRunnerConfig(
  path: string,
  root: string,
  connector: string,
  apiBaseURL: string,
) {
  await Deno.mkdir(`${root}/state`, { recursive: true });
  await Deno.writeTextFile(
    path,
    JSON.stringify({
      api_base_url: apiBaseURL,
      org_id: "org-e2e",
      runner_token: "runner-token",
      runner: { stable_id: "runner-e2e", name: "Runner E2E" },
      paths: {
        state_dir: `${root}/state`,
        workdir: `${root}/work`,
        salix_connect: connector,
      },
    }),
  );
}

function versionedConnectorScript(version: string) {
  const identity = {
    component: "salix-connect",
    version,
    release_id: version,
  };

  return [
    "#!/bin/sh",
    'if [ "$1" = "version" ]; then',
    `  printf '%s\\n' '${JSON.stringify(identity)}'`,
    "  exit 0",
    "fi",
    'if [ -n "$CONNECTOR_STATUS_FILE" ]; then',
    `  printf '%s\n' '${
      JSON.stringify({
        state: "connected",
        connector_run_id: "run-e2e",
      })
    }' > "$CONNECTOR_STATUS_FILE"`,
    "fi",
    'if [ -n "$CONNECTOR_PID_FILE" ]; then',
    '  printf "%s\\n" "$$" >> "$CONNECTOR_PID_FILE"',
    '  if [ -n "$CONNECTOR_START_FILE" ]; then',
    '    printf "started\\n" >> "$CONNECTOR_START_FILE"',
    '    if [ "$(wc -l < "$CONNECTOR_START_FILE" | tr -d " ")" = "1" ]; then',
    "      sleep 0.12",
    "      exit 7",
    "    fi",
    "  fi",
    "  trap 'exit 0' TERM INT",
    "  while :; do sleep 1; done",
    "fi",
    "exit 0",
    "",
  ].join("\n");
}

async function writeStoredConnector(root: string, requestID: string) {
  const directory = `${root}/state/connectors`;
  const connectorRoot = `${root}/connector-root`;
  await Deno.mkdir(directory, { recursive: true });
  await Deno.mkdir(connectorRoot, { recursive: true });
  await Deno.writeTextFile(
    `${directory}/${requestID}.json`,
    JSON.stringify({
      connector: {
        root: connectorRoot,
      },
      status: { path: `${directory}/${requestID}.status.json` },
    }),
  );
}

function processAlive(pid: number) {
  try {
    Deno.kill(pid, "SIGCONT");
    return true;
  } catch {
    return false;
  }
}

async function killRecordedProcesses(path: string) {
  const raw = await Deno.readTextFile(path).catch(() => "");
  for (const value of raw.trim().split("\n")) {
    const pid = Number(value);
    if (Number.isInteger(pid) && pid > 0) {
      try {
        Deno.kill(pid, "SIGKILL");
      } catch {
        // Process already exited.
      }
    }
  }
}

async function writeVersionedConnector(path: string, version: string) {
  await writeExecutable(path, versionedConnectorScript(version));
}

async function writeExecutable(path: string, body: string) {
  await Deno.writeTextFile(path, body);
  await Deno.chmod(path, 0o755);
}

function serverURL(server: Deno.HttpServer) {
  const address = server.addr as Deno.NetAddr;
  return `http://127.0.0.1:${address.port}`;
}

async function run(
  command: string,
  args: string[],
  env?: Record<string, string>,
  cwd?: string,
) {
  const output = await new Deno.Command(command, {
    args,
    cwd,
    env,
    stdout: "piped",
    stderr: "piped",
  }).output();
  const stdout = new TextDecoder().decode(output.stdout);
  const stderr = new TextDecoder().decode(output.stderr);
  return {
    code: output.code,
    stdout,
    stderr,
    combined: stdout + stderr,
  };
}

async function sha256Hex(data: Uint8Array) {
  const copy = new Uint8Array(data.byteLength);
  copy.set(data);
  const digest = await crypto.subtle.digest("SHA-256", copy.buffer);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function shellQuote(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function assertIncludes(haystack: string, needle: string) {
  if (!haystack.includes(needle)) {
    throw new Error(
      `expected output to include ${JSON.stringify(needle)}\n${haystack}`,
    );
  }
}

async function pathExists(path: string) {
  try {
    await Deno.lstat(path);
    return true;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return false;
    throw error;
  }
}

function assertEquals(actual: unknown, expected: unknown, message = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      message ||
        `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}
