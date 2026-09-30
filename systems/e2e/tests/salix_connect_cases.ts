const REPO_ROOT = new URL("../../..", import.meta.url).pathname;
const SALIX_ROOT = new URL("../..", import.meta.url).pathname;
const DEFAULT_TIMEOUT_MS = 120_000;
const RECOVERY_MESSAGE_MARKER =
  "The previous execution was interrupted outside the runtime; the runtime did not choose to stop.";

export const remote = {
  name:
    "salix-connect Go connector works in remote mode, including managed read_ref",
  sanitizeOps: false,
  sanitizeResources: false,
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
        "minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e",
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
            SALIX_CONNECT_BIN: bin,
          },
        },
      );

      assertIncludes(output.combined, "SALIX_CONNECT_E2E: PASS");
      assertIncludes(output.combined, "SALIX_CONNECT_READ_REF_E2E: PASS");
    } finally {
      if (salixConfigPath) await Deno.remove(salixConfigPath).catch(() => {});
      await Deno.remove(bin).catch(() => {});
      await run("docker", ["rm", "-f", minioName], { allowFailure: true });
      releasePorts(minioPort, httpPort, transferPort);
    }
  },
};

export const observability = {
  name: "connector runtime observability reports bounded held sessions",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const id = crypto.randomUUID().slice(0, 8);
    const minioName = `runtime-observability-e2e-minio-${id}`;
    const bucket = `runtime-observability-e2e-${id}`;
    const minioPort = reservePort();
    const httpPort = reservePort();
    const transferPort = reservePort();
    const bin = `/tmp/salix-connect-runtime-observability-${id}`;
    const helper = `${bin}-helper`;
    const fakeBin = await Deno.makeTempDir({
      prefix: "runtime-observability-",
    });
    const fakeInstall = `${fakeBin}/codex-install`;
    const fakeCodex = `${fakeInstall}/codex`;
    const fakeLog = `${fakeBin}/codex.log`;
    const asyncCompletionShim = `${fakeBin}/async-completion-shim`;
    const asyncCompletionEvidence = `${fakeBin}/async-completion.evidence`;
    const readinessGate = `${fakeBin}/readiness.gate`;
    const accountReadGate = `${fakeBin}/account-read.gate`;
    const authFailure = `${fakeBin}/auth-failure.gate`;
    const lifecycleGate = `${fakeBin}/lifecycle.gate`;
    const normalExitGate = `${fakeBin}/normal-exit.gate`;
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
        "minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e",
        "server",
        "/data",
      ]);

      const endpoint = `http://127.0.0.1:${minioPort.port}`;
      await waitForMinio(endpoint);
      await createBucket(minioName, bucket);
      salixConfigPath = await writeSalixConfig(endpoint, bucket);

      const connectorDir = new URL(
        "../../connector/salix-connect",
        import.meta.url,
      ).pathname;
      await run("go", ["build", "-o", bin, "."], {
        cwd: connectorDir,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });
      await run("go", ["test", "-c", "-o", helper, "."], {
        cwd: connectorDir,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });

      await writeFakeAsyncCompletionShim(asyncCompletionShim);
      await Deno.mkdir(fakeInstall);
      await Deno.writeTextFile(
        fakeCodex,
        [
          "#!/bin/sh",
          "export SALIX_TEST_FAKE_CODEX=1",
          "export SALIX_TEST_FAKE_CODEX_EXECUTE_SALIX=1",
          `export SALIX_TEST_FAKE_CODEX_LOG=${shellQuote(fakeLog)}`,
          `export SALIX_TEST_FAKE_CODEX_READINESS_GATE=${
            shellQuote(
              readinessGate,
            )
          }`,
          `export SALIX_TEST_FAKE_CODEX_ACCOUNT_READ_GATE=${
            shellQuote(
              accountReadGate,
            )
          }`,
          `export SALIX_TEST_FAKE_CODEX_AUTH_FAILURE_WHILE_EXISTS=${
            shellQuote(
              authFailure,
            )
          }`,
          `export SALIX_TEST_FAKE_RUNTIME_LIFECYCLE_GATE=${
            shellQuote(
              lifecycleGate,
            )
          }`,
          `export SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_GATE=${
            shellQuote(
              normalExitGate,
            )
          }`,
          ...fakeAsyncCompletionShimEnvironment(
            asyncCompletionShim,
            fakeLog,
            asyncCompletionEvidence,
          ),
          `exec ${
            shellQuote(
              helper,
            )
          } -test.run=TestHelperCodexAppServer -- "$@"`,
          "",
        ].join("\n"),
      );
      await Deno.chmod(fakeCodex, 0o755);
      await Deno.writeTextFile(
        `${fakeInstall}/codex-code-mode-host`,
        "#!/bin/sh\nexit 0\n",
      );
      await Deno.chmod(`${fakeInstall}/codex-code-mode-host`, 0o755);
      await Deno.symlink(fakeCodex, `${fakeBin}/codex`);
      await Deno.writeTextFile(readinessGate, "ready\n");
      await Deno.writeTextFile(accountReadGate, "ready\n");
      await Deno.writeTextFile(fakeLog, "");
      releasePorts(httpPort, transferPort);

      const output = await run(
        "mix",
        [
          "run",
          "-e",
          'Application.put_env(:salix_web, :runtime_proxy_tool_terminal_wait_ms, 0); Code.require_file("scripts/comma31_external_runtime_manual_e2e.exs")',
        ],
        {
          cwd: SALIX_ROOT,
          timeoutMs: 300_000,
          env: {
            ...Deno.env.toObject(),
            PATH: `${fakeBin}:${pathWithAsdf()}`,
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
            SALIX_CONNECT_TEST_HELPER: helper,
            COMMA31_RUNTIME_PROVIDER: "codex",
            COMMA31_RUNTIME_OBSERVABILITY: "1",
            SALIX_TEST_FAKE_CODEX_LOG: fakeLog,
            SALIX_TEST_FAKE_CODEX_READINESS_GATE: readinessGate,
            SALIX_TEST_FAKE_CODEX_ACCOUNT_READ_GATE: accountReadGate,
            SALIX_TEST_FAKE_CODEX_AUTH_FAILURE_WHILE_EXISTS: authFailure,
            SALIX_TEST_FAKE_RUNTIME_LIFECYCLE_GATE: lifecycleGate,
            SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_GATE: normalExitGate,
          },
        },
      );

      assertIncludes(
        output.combined,
        "CONNECTOR_RUNTIME_OBSERVABILITY_E2E: PASS",
      );
      assertIncludes(
        output.combined,
        "CONNECTOR_RUNTIME_WORKSPACE_ISSUE_E2E: PASS",
      );
      await assertFakeAsyncCompletionEvidence(
        asyncCompletionEvidence,
        "observability codex",
      );
    } finally {
      if (salixConfigPath) await Deno.remove(salixConfigPath).catch(() => {});
      await Deno.remove(fakeBin, { recursive: true }).catch(() => {});
      await Deno.remove(bin).catch(() => {});
      await Deno.remove(helper).catch(() => {});
      await run("docker", ["rm", "-f", minioName], { allowFailure: true });
      releasePorts(minioPort, httpPort, transferPort);
    }
  },
};

export const external = {
  name: "external runtimes complete, steer, and resume through the connector",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const id = crypto.randomUUID().slice(0, 8);
    const minioName = `external-runtime-e2e-minio-${id}`;
    const bucket = `external-runtime-e2e-${id}`;
    const minioPort = reservePort();
    const bin = `/tmp/salix-connect-external-runtime-${id}`;
    const helper = `/tmp/salix-connect-external-runtime-helper-${id}`;
    const fakeBin = await Deno.makeTempDir({
      prefix: "salix-connect-external-runtime-",
    });
    const fakeLogs = {
      codex: `${fakeBin}/codex.log`,
      pi: `${fakeBin}/pi.log`,
      kimi: `${fakeBin}/kimi.log`,
    };
    const asyncCompletionShim = `${fakeBin}/async-completion-shim`;
    const asyncCompletionEvidence = {
      codex: `${fakeBin}/codex-async-completion.evidence`,
      pi: `${fakeBin}/pi-async-completion.evidence`,
      kimi: `${fakeBin}/kimi-async-completion.evidence`,
    };
    const oversizedRuntimeEventOnce = `${fakeBin}/pi-oversized-event.once`;
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
        "minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e",
        "server",
        "/data",
      ]);

      const endpoint = `http://127.0.0.1:${minioPort.port}`;
      await waitForMinio(endpoint);
      await createBucket(minioName, bucket);
      salixConfigPath = await writeSalixConfig(endpoint, bucket);

      const connectorDir = new URL(
        "../../connector/salix-connect",
        import.meta.url,
      ).pathname;
      await run("go", ["build", "-o", bin, "."], {
        cwd: connectorDir,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });
      await run("go", ["test", "-c", "-o", helper, "."], {
        cwd: connectorDir,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });

      await writeFakeAsyncCompletionShim(asyncCompletionShim);
      const fakeCodexInstall = `${fakeBin}/codex-install`;
      const fakeCodex = `${fakeCodexInstall}/codex`;
      await Deno.mkdir(fakeCodexInstall);
      await Deno.writeTextFile(
        fakeCodex,
        [
          "#!/bin/sh",
          `printf 'argv0=%s\\n' "$0" >> ${shellQuote(fakeLogs.codex)}`,
          `printf 'args=%s\\n' "$*" >> ${shellQuote(fakeLogs.codex)}`,
          "export SALIX_TEST_FAKE_CODEX=1",
          "export SALIX_TEST_FAKE_CODEX_EXECUTE_SALIX=1",
          `export SALIX_TEST_FAKE_CODEX_LOG=${shellQuote(fakeLogs.codex)}`,
          ...fakeAsyncCompletionShimEnvironment(
            asyncCompletionShim,
            fakeLogs.codex,
            asyncCompletionEvidence.codex,
            "2",
          ),
          `exec ${
            shellQuote(
              helper,
            )
          } -test.run=TestHelperCodexAppServer -- \"$@\"`,
          "",
        ].join("\n"),
      );
      await Deno.chmod(fakeCodex, 0o755);
      const fakeCodeModeHost = `${fakeCodexInstall}/codex-code-mode-host`;
      await Deno.writeTextFile(fakeCodeModeHost, "#!/bin/sh\nexit 0\n");
      await Deno.chmod(fakeCodeModeHost, 0o755);
      await Deno.symlink(fakeCodex, `${fakeBin}/codex`);
      const resolvedFakeCodex = await Deno.realPath(fakeCodex);

      const fakePiInstall = `${fakeBin}/pi-install/dist`;
      const fakePiBundle = `${fakePiInstall}/bundle`;
      const fakePiAuthDir = `${fakeBin}/pi-auth`;
      const fakePi = `${fakePiBundle}/cli.js`;
      await Deno.mkdir(fakePiBundle, { recursive: true });
      await Deno.mkdir(fakePiAuthDir, { recursive: true });
      await Deno.writeTextFile(
        `${fakePiInstall}/package.json`,
        JSON.stringify({ type: "module" }),
      );
      await Deno.writeTextFile(
        `${fakePiInstall}/index.js`,
        [
          `export const getAgentDir = () => ${JSON.stringify(fakePiAuthDir)};`,
          "export class ModelRuntime {",
          "  static async create() { return new ModelRuntime(); }",
          "  getModel(provider, id) { return provider === 'openrouter' && id === 'test-model' ? { provider, id } : undefined; }",
          "  async complete(_model, _context, options) {",
          "    await options.fetch('data:application/json,{}');",
          "    return { stopReason: 'stop' };",
          "  }",
          "}",
          "",
        ].join("\n"),
      );
      await Deno.writeTextFile(
        `${fakePiAuthDir}/auth.json`,
        JSON.stringify({
          openrouter: {
            type: "api_key",
            key: "comma31-synthetic-openrouter-key",
          },
        }),
      );
      await writeFakeRuntime(
        fakePi,
        "pi fake",
        [
          "export SALIX_TEST_FAKE_PI=1",
          "export SALIX_TEST_FAKE_PI_MODEL_PROVIDER=openrouter",
          "export SALIX_TEST_FAKE_RUNTIME_EXECUTE_SALIX=1",
          `export SALIX_TEST_FAKE_PI_LOG=${shellQuote(fakeLogs.pi)}`,
          "export SALIX_TEST_FAKE_PI_OVERSIZED_TOOL_RESULT_BYTES=9437184",
          `export SALIX_TEST_FAKE_PI_OVERSIZED_TOOL_RESULT_ONCE=${
            shellQuote(
              oversizedRuntimeEventOnce,
            )
          }`,
          ...fakeAsyncCompletionShimEnvironment(
            asyncCompletionShim,
            fakeLogs.pi,
            asyncCompletionEvidence.pi,
            "2",
          ),
        ],
        helper,
        "TestHelperPiRPC",
      );
      await Deno.symlink(fakePi, `${fakeBin}/pi`);
      await writeFakeRuntime(
        `${fakeBin}/kimi`,
        "kimi fake",
        [
          "export SALIX_TEST_FAKE_KIMI=1",
          "export SALIX_TEST_FAKE_RUNTIME_EXECUTE_SALIX=1",
          `export SALIX_TEST_FAKE_KIMI_LOG=${shellQuote(fakeLogs.kimi)}`,
          ...fakeAsyncCompletionShimEnvironment(
            asyncCompletionShim,
            fakeLogs.kimi,
            asyncCompletionEvidence.kimi,
            "2",
          ),
        ],
        helper,
        "TestHelperKimiServer",
      );

      for (const provider of ["pi", "codex", "kimi"] as const) {
        const httpPort = reservePort();
        const transferPort = reservePort();
        const reconnectTrigger = `${fakeBin}/${provider}-reconnect`;
        try {
          if (provider === "pi") {
            await Deno.writeTextFile(oversizedRuntimeEventOnce, "pending\n");
          }
          await Deno.remove(reconnectTrigger).catch(() => {});
          await Deno.remove(`${reconnectTrigger}.waiting`).catch(() => {});
          releasePorts(httpPort, transferPort);
          const serverConfigPath = salixConfigPath;
          const runServer = () =>
            run(
              "mix",
              [
                "run",
                "-e",
                'Application.put_env(:salix_web, :runtime_proxy_tool_terminal_wait_ms, 0); Code.require_file("scripts/comma31_external_runtime_manual_e2e.exs")',
              ],
              {
                cwd: SALIX_ROOT,
                timeoutMs: 240_000,
                env: {
                  ...Deno.env.toObject(),
                  PATH: `${fakeBin}:${pathWithAsdf()}`,
                  MIX_ENV: "test",
                  SALIX_CONFIG_PATH: serverConfigPath,
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
                  COMMA31_RUNTIME_PROVIDER: provider,
                  COMMA31_VERIFY_CONFIGURED_RUNTIME: provider === "pi"
                    ? "1"
                    : "0",
                  COMMA31_FLEETSUP_COLD_START_E2E: provider === "codex"
                    ? "1"
                    : "0",
                  COMMA31_SERVER_RESTART_FILE: provider === "codex"
                    ? `${fakeBin}/server-restart.bin`
                    : "",
                  SALIX_LIVE_LLM_S3_BACKEND: "aws",
                  SALIX_TEST_RUNTIME_RECONNECT_TRIGGER: reconnectTrigger,
                  SALIX_TEST_FAKE_RUNTIME_LIFECYCLE_DELAY_MS: "750",
                  COMMA31_OVERSIZED_RUNTIME_EVENT_E2E: provider === "pi"
                    ? "1"
                    : "0",
                },
              },
            );

          let output;
          try {
            output = await runServer();
          } catch (error) {
            // These fixtures use synthetic credentials and local fake runtimes.
            // Preserve their diagnostics before the finally block removes them.
            console.error(
              `fake ${provider} runtime log:\n${await Deno.readTextFile(
                fakeLogs[provider],
              ).catch(() => "(unavailable)")}`,
            );
            throw error;
          }
          if (provider === "codex") {
            assertIncludes(output.combined, "COMMA31_SERVER_RESTART: CHECKPOINT");
            output = await runServer();
            assertIncludes(output.combined, "COMMA31_SERVER_RESTART_E2E: PASS");
          }
          assertIncludes(
            output.combined,
            `COMMA31_EXTERNAL_RUNTIME_E2E: PASS provider=${provider}`,
          );
          await assertFakeAsyncCompletionEvidence(
            asyncCompletionEvidence[provider],
            provider,
          );
        } finally {
          await Deno.remove(reconnectTrigger).catch(() => {});
          await Deno.remove(`${reconnectTrigger}.waiting`).catch(() => {});
          releasePorts(httpPort, transferPort);
        }
      }

      const codexLog = await Deno.readTextFile(fakeLogs.codex);
      assertIncludes(codexLog, `argv0=${resolvedFakeCodex}`);
      assertIncludes(
        codexLog,
        "args=app-server --disable tool_suggest --listen",
      );
      assertIncludes(codexLog, "turn/steer");
      assertIncludes(codexLog, "thread/resume");
      assertIncludes(codexLog, "/.comma/workspaces/");
      assertIncludes(codexLog, "local_shell root=");
      assertIncludes(codexLog, "err=<nil> output=local-shell-ok");
      assertIncludes(
        codexLog,
        "SALIX_ENV_ROOT is the Connector-managed local environment root.",
      );
      const piLog = await Deno.readTextFile(fakeLogs.pi);
      assertIncludes(piLog, '"streamingBehavior":"steer"');
      assertIncludes(piLog, '"type":"set_auto_retry"');
      assertIncludes(piLog, '"enabled":false');
      assertIncludes(piLog, "--session pi-native-");
      assertIncludes(piLog, "--append-system-prompt");
      assertIncludes(piLog, "cwd=");
      assertIncludes(piLog, "/.comma/workspaces/");
      assertIncludes(piLog, "local_shell root=");
      assertIncludes(piLog, "err=<nil> output=local-shell-ok");
      assertIncludes(
        piLog,
        "SALIX_ENV_ROOT is the Connector-managed local environment root.",
      );
      assertIncludes(
        piLog,
        "You are an external coding worker running inside Salix.",
      );
      const kimiLog = await Deno.readTextFile(fakeLogs.kimi);
      assertIncludes(kimiLog, "start web --no-open --port");
      assertIncludes(kimiLog, "/prompts:steer");
      assertIncludes(kimiLog, '"model":"kimi-test"');
      assertIncludes(kimiLog, '"thinking":"high"');
      assertIncludes(kimiLog, "GET /api/v1/sessions/kimi-native-");
      assertIncludes(kimiLog, "pong");
      assertIncludes(kimiLog, "cwd=");
      assertIncludes(kimiLog, "/.comma/workspaces/");
      assertIncludes(kimiLog, "local_shell root=");
      assertIncludes(kimiLog, "err=<nil> output=local-shell-ok");
      assertIncludes(
        kimiLog,
        "SALIX_ENV_ROOT is the Connector-managed local environment root.",
      );
      assertIncludes(
        kimiLog,
        "You are an external coding worker running inside Salix.",
      );
      assertIncludes(kimiLog, "salix tool call im_api.internal.send_message");
    } finally {
      if (salixConfigPath) await Deno.remove(salixConfigPath).catch(() => {});
      await Deno.remove(fakeBin, { recursive: true }).catch(() => {});
      await Deno.remove(bin).catch(() => {});
      await Deno.remove(helper).catch(() => {});
      await run("docker", ["rm", "-f", minioName], { allowFailure: true });
      releasePorts(minioPort);
    }
  },
};

export const recovery = {
  name: "external runtimes recover locally without a Server",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const id = crypto.randomUUID().slice(0, 8);
    const connectorDir = new URL(
      "../../connector/salix-connect",
      import.meta.url,
    ).pathname;
    const bin = `/tmp/salix-connect-local-recovery-${id}`;
    const helper = `/tmp/salix-connect-local-recovery-helper-${id}`;
    const temp = await Deno.makeTempDir({
      prefix: "salix-connect-local-recovery-",
    });

    try {
      await run("go", ["build", "-o", bin, "."], {
        cwd: connectorDir,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });
      await run("go", ["test", "-c", "-o", helper, "."], {
        cwd: connectorDir,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });

      await exerciseDurableDownstreamBatch({
        bin,
        helper,
        root: `${temp}/downstream-root`,
        home: `${temp}/downstream-home`,
        fakeBin: `${temp}/downstream-bin`,
      });
      await exerciseSettledSessionIdentity({
        bin,
        helper,
        root: `${temp}/settled-identity-root`,
        home: `${temp}/settled-identity-home`,
        fakeBin: `${temp}/settled-identity-bin`,
      });
      await exerciseLegacyLifecycleMigration({
        bin,
        helper,
        root: `${temp}/legacy-lifecycle-root`,
        home: `${temp}/legacy-lifecycle-home`,
        fakeBin: `${temp}/legacy-lifecycle-bin`,
      });
      await exerciseRuntimeEventPayloadCompaction({
        bin,
        helper,
        root: `${temp}/oversized-event-root`,
        home: `${temp}/oversized-event-home`,
        fakeBin: `${temp}/oversized-event-bin`,
      });
      await exerciseRuntimeEventRetryFairness({
        bin,
        helper,
        root: `${temp}/event-retry-fairness-root`,
        home: `${temp}/event-retry-fairness-home`,
        fakeBin: `${temp}/event-retry-fairness-bin`,
      });
      await exerciseLegacyOversizedAsyncCompletionRecovery({
        bin,
        helper,
        root: `${temp}/legacy-async-root`,
        home: `${temp}/legacy-async-home`,
        fakeBin: `${temp}/legacy-async-bin`,
      });
      await exerciseWorkspacePreparationAfterDurableAck({
        bin,
        helper,
        root: `${temp}/workspace-deferred-root`,
        home: `${temp}/workspace-deferred-home`,
        fakeBin: `${temp}/workspace-deferred-bin`,
      });
      await exerciseTransientCodexResumeRetry({
        bin,
        helper,
        root: `${temp}/codex-resume-retry-root`,
        home: `${temp}/codex-resume-retry-home`,
        fakeBin: `${temp}/codex-resume-retry-bin`,
      });
      await exerciseLocalRuntimeRecovery({
        bin,
        helper,
        root: `${temp}/abnormal-root`,
        home: `${temp}/abnormal-home`,
        fakeBin: `${temp}/abnormal-bin`,
        exitNormally: false,
      });
      await exerciseLocalRuntimeRecovery({
        bin,
        helper,
        root: `${temp}/normal-root`,
        home: `${temp}/normal-home`,
        fakeBin: `${temp}/normal-bin`,
        exitNormally: true,
      });
      await assertUnsafeRecoveryFileRejected(
        bin,
        `${temp}/unsafe-root`,
        `${temp}/unsafe-home`,
      );
    } finally {
      await Deno.remove(temp, { recursive: true }).catch(() => {});
      await Deno.remove(bin).catch(() => {});
      await Deno.remove(helper).catch(() => {});
    }
  },
};

export const upgrade = {
  name:
    "external runtime bbolt upgrade accepts semantically identical legacy JSON",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const id = crypto.randomUUID().slice(0, 8);
    const connectorDir = new URL(
      "../../connector/salix-connect",
      import.meta.url,
    ).pathname;
    const bin = `/tmp/salix-connect-semantic-upgrade-${id}`;
    const temp = await Deno.makeTempDir({
      prefix: "salix-connect-semantic-upgrade-",
    });
    let connector: StdioConnectorClient | undefined;
    try {
      await run("go", ["build", "-o", bin, "."], {
        cwd: connectorDir,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });
      await run(
        "go",
        ["test", "-run", "^TestHelperSeedLegacyRuntimeState$", "."],
        {
          cwd: connectorDir,
          timeoutMs: DEFAULT_TIMEOUT_MS,
          env: {
            ...Deno.env.toObject(),
            SALIX_TEST_SEED_LEGACY_RUNTIME_STATE: temp,
            SALIX_TEST_SEED_LEGACY_RUNTIME_EVENT: "1",
          },
        },
      );

      const legacyPath = legacyRecoveryPath(temp, "session-upgrade");
      const state = JSON.parse(await Deno.readTextFile(legacyPath));
      await Deno.writeTextFile(legacyPath, JSON.stringify(state, null, 2), {
        mode: 0o600,
      });

      const home = `${temp}/home`;
      const kimiSource = `${temp}/kimi-source`;
      await Deno.mkdir(home, { recursive: true });
      await Deno.mkdir(kimiSource, { recursive: true });
      connector = startLocalStdioConnector(bin, temp, home, kimiSource);
      const first = await connector.waitForRuntimeEventDelivery(
        (event) => event.name === "read_file",
        10_000,
        false,
        true,
      );
      if (!first.delivery.legacy) {
        throw new Error(
          "migrated runtime event was not isolated for exact-id settlement",
        );
      }
      assertCompactedReadEvent(first.event, "/workspace/report.txt", 1_000_000);
      await connector.crash();
      connector = startLocalStdioConnector(bin, temp, home, kimiSource);
      const second = await connector.waitForRuntimeEventDelivery(
        (event) => event.name === "read_file",
        10_000,
        true,
        true,
      );
      if (!second.delivery.legacy) {
        throw new Error("restarted migration lost exact-id settlement");
      }
      if (JSON.stringify(second.event) !== JSON.stringify(first.event)) {
        throw new Error(
          "runtime event compaction changed across connector restart",
        );
      }
      if (await legacyRecoveryFileExists(temp, "session-upgrade")) {
        throw new Error("connector did not finish interrupted legacy cleanup");
      }
    } finally {
      await connector?.close().catch(() => {});
      await Deno.remove(temp, { recursive: true }).catch(() => {});
      await Deno.remove(bin).catch(() => {});
    }
  },
};

export const shutdown = {
  name: "graceful connector shutdown preserves the native terminal tail",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const id = crypto.randomUUID().slice(0, 8);
    const connectorDir = new URL(
      "../../connector/salix-connect",
      import.meta.url,
    ).pathname;
    const bin = `/tmp/salix-connect-shutdown-tail-${id}`;
    const helper = `/tmp/salix-connect-shutdown-tail-helper-${id}`;
    const temp = await Deno.makeTempDir({
      prefix: "salix-connect-shutdown-tail-",
    });
    const root = `${temp}/root`;
    const home = `${temp}/home`;
    const fakeBin = `${temp}/bin`;
    const kimiSource = `${fakeBin}/kimi-source`;
    const command = `${fakeBin}/pi`;
    const logPath = `${fakeBin}/pi.log`;
    const pidPath = `${fakeBin}/pi.pid`;
    const firstPromptLifecycle = `${fakeBin}/first-prompt.lifecycle`;
    let connector: StdioConnectorClient | undefined;

    try {
      for (const path of [root, home, fakeBin, kimiSource]) {
        await Deno.mkdir(path, { recursive: true });
      }
      await Deno.writeTextFile(firstPromptLifecycle, "running\n");
      await run("go", ["build", "-o", bin, "."], {
        cwd: connectorDir,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });
      await run("go", ["test", "-c", "-o", helper, "."], {
        cwd: connectorDir,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });
      await writeFakeRuntime(
        command,
        "pi shutdown tail fake",
        [
          "export SALIX_TEST_FAKE_PI=1",
          `export SALIX_TEST_FAKE_PI_LOG=${shellQuote(logPath)}`,
          `export SALIX_TEST_FAKE_PI_FIRST_PROMPT_LIFECYCLE_MARKER=${
            shellQuote(
              firstPromptLifecycle,
            )
          }`,
          "export SALIX_TEST_FAKE_PI_FIRST_PROMPT_LIFECYCLE=running",
          `printf '%s\\n' "$$" > ${shellQuote(pidPath)}`,
        ],
        helper,
        "TestHelperPiRPC",
      );

      connector = startLocalStdioConnector(bin, root, home, kimiSource);
      await connector.request("start-shutdown-tail", "agent_runtime_input", {
        kind: "external",
        provider: "pi",
        session_id: "session-shutdown-tail",
        dispatch_id: "dispatch-shutdown-tail",
        runtime_capability_token: "capability-shutdown-tail",
        runtime_payload: {},
        runtime_config: { command },
        system_prompt: "shutdown tail e2e",
        input_messages: [{ role: "user", content: "keep working" }],
      });
      await connector.waitForRuntimeEvent(
        (event) =>
          event.work_state === "running" &&
          event.dispatch_id === "dispatch-shutdown-tail",
        5_000,
      );
      await connector.close();
      connector = undefined;

      connector = startLocalStdioConnector(bin, root, home, kimiSource);
      const terminal = await connector.waitForRuntimeEvent(
        (event) =>
          event.type === "error" &&
          event.work_state === "failed" &&
          event.dispatch_id === "dispatch-shutdown-tail",
        5_000,
      );
      if (
        !terminal.execution_id ||
        terminal.issue !== "runtime_failed" ||
        terminal.message !== "Pi runtime execution failed."
      ) {
        throw new Error(
          `shutdown tail lost its fenced canonical failure: ${
            JSON.stringify(
              terminal,
            )
          }`,
        );
      }
      if (JSON.stringify(terminal).includes("pi process exited")) {
        throw new Error(
          `shutdown tail leaked raw provider text: ${JSON.stringify(terminal)}`,
        );
      }
    } finally {
      await connector?.crash().catch(() => {});
      const pid = await Deno.readTextFile(pidPath).catch(() => "");
      if (pid.trim()) {
        await run("kill", ["-9", pid.trim()], { allowFailure: true });
      }
      await Deno.remove(temp, { recursive: true }).catch(() => {});
      await Deno.remove(bin).catch(() => {});
      await Deno.remove(helper).catch(() => {});
    }
  },
};

export const isolation = {
  name: "external runtime state is isolated from live VM archives",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const id = crypto.randomUUID().slice(0, 8);
    const connectorDir = new URL(
      "../../connector/salix-connect",
      import.meta.url,
    ).pathname;
    const bin = `/tmp/salix-connect-vm-archive-${id}`;
    const temp = await Deno.makeTempDir({
      prefix: "salix-connect-vm-archive-",
    });
    const port = reservePort();
    const url = `http://127.0.0.1:${port.port}`;
    port.release();
    let child: Deno.ChildProcess | undefined;
    const connectorArgs = [
      "--vm-server",
      "--listen",
      `127.0.0.1:${port.port}`,
      "--root",
      `${temp}/root`,
      "--system-info-interval",
      "0",
    ];
    try {
      await run("go", ["build", "-o", bin, "."], {
        cwd: connectorDir,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });
      child = new Deno.Command(bin, {
        args: connectorArgs,
        stdout: "null",
        stderr: "inherit",
      }).spawn();
      await waitForConnectorHealth(url);

      const legacyDir = `${temp}/root/external-runtime/active`;
      await Deno.mkdir(legacyDir, { recursive: true, mode: 0o700 });
      await Deno.writeTextFile(`${legacyDir}/session.json`, "legacy secret", {
        mode: 0o600,
      });

      const archive = `${temp}/workspace.tar.gz`;
      const response = await fetch(`${url}/archive`);
      if (!response.ok) {
        throw new Error(`archive GET returned ${response.status}`);
      }
      await Deno.writeFile(
        archive,
        new Uint8Array(await response.arrayBuffer()),
      );
      const listing = await run("tar", ["-tzf", archive]);
      if (listing.stdout.includes("external-runtime/state.db")) {
        throw new Error("live bbolt state leaked into the VM archive");
      }
      if (listing.stdout.includes("external-runtime/active")) {
        throw new Error("legacy runtime state leaked into the VM archive");
      }
      await Deno.remove(legacyDir, { recursive: true });

      const payload = `${temp}/payload`;
      await Deno.mkdir(`${payload}/external-runtime/active`, {
        recursive: true,
      });
      await Deno.writeTextFile(
        `${payload}/external-runtime/state.db`,
        "corrupt",
      );
      await Deno.writeTextFile(
        `${payload}/external-runtime/active/session.json`,
        "legacy secret",
      );
      const corruptArchive = `${temp}/corrupt.tar.gz`;
      await run("tar", [
        "-czf",
        corruptArchive,
        "-C",
        payload,
        "external-runtime/./state.db",
        "external-runtime/active/session.json",
      ]);
      const restore = await fetch(`${url}/archive`, {
        method: "PUT",
        body: await Deno.readFile(corruptArchive),
      });
      if (!restore.ok) {
        throw new Error(`archive PUT returned ${restore.status}`);
      }
      if (await legacyRecoveryFileExists(`${temp}/root`, "session")) {
        throw new Error("VM restore injected legacy runtime state");
      }
      child.kill("SIGTERM");
      await child.status;
      child = new Deno.Command(bin, {
        args: connectorArgs,
        stdout: "null",
        stderr: "inherit",
      }).spawn();
      await waitForConnectorHealth(url);
      await assertExternalRuntimeStateSymlinksRejected(bin, temp);
    } finally {
      if (child) {
        try {
          child.kill("SIGTERM");
        } catch {
          // Already exited.
        }
        await child.status.catch(() => {});
      }
      await Deno.remove(temp, { recursive: true }).catch(() => {});
      await Deno.remove(bin).catch(() => {});
    }
  },
};

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

type LocalRecoveryOptions = {
  bin: string;
  helper: string;
  root: string;
  home: string;
  fakeBin: string;
  exitNormally: boolean;
};

type LocalRuntimeFixture = {
  provider: "codex" | "pi" | "kimi";
  sessionID: string;
  command: string;
  logPath: string;
  pidPath: string;
  statePath: string;
  decisionPath: string;
  recoveryMarker: string;
  startMarker: (line: string) => boolean;
};

async function exerciseLegacyOversizedAsyncCompletionRecovery(
  opts: Omit<LocalRecoveryOptions, "exitNormally">,
) {
  const kimiSource = `${opts.fakeBin}/kimi-source`;
  const fakeCodexInstall = `${opts.fakeBin}/codex-install`;
  const command = `${fakeCodexInstall}/codex`;
  const logPath = `${opts.fakeBin}/codex.log`;
  for (
    const path of [
      opts.root,
      opts.home,
      opts.fakeBin,
      kimiSource,
      fakeCodexInstall,
    ]
  ) {
    await Deno.mkdir(path, { recursive: true });
  }
  await Deno.writeTextFile(
    command,
    [
      "#!/bin/sh",
      "export SALIX_TEST_FAKE_CODEX=1",
      "export SALIX_TEST_FAKE_CODEX_MAX_INPUT_CHARS=1048576",
      `export SALIX_TEST_FAKE_CODEX_LOG=${shellQuote(logPath)}`,
      `exec ${
        shellQuote(
          opts.helper,
        )
      } -test.run=TestHelperCodexAppServer -- "$@"`,
      "",
    ].join("\n"),
  );
  await Deno.chmod(command, 0o755);
  await Deno.writeTextFile(
    `${fakeCodexInstall}/codex-code-mode-host`,
    "#!/bin/sh\nexit 0\n",
  );
  await Deno.chmod(`${fakeCodexInstall}/codex-code-mode-host`, 0o755);

  const toolCallID = "call-legacy-oversized";
  const legacyResultMarker = "LEGACY_RESULT_END";
  const dispatchID = "batch-legacy-oversized-async";
  const messageID = "message-legacy-oversized-async";
  await run(opts.helper, ["-test.run=^TestHelperSeedLegacyAsyncInputBatch$"], {
    env: {
      ...Deno.env.toObject(),
      SALIX_TEST_SEED_LEGACY_ASYNC_INPUT: opts.root,
      SALIX_TEST_SEED_LEGACY_ASYNC_COMMAND: command,
    },
  });

  let connector = startLocalStdioConnector(
    opts.bin,
    opts.root,
    opts.home,
    kimiSource,
  );
  try {
    await waitUntil(
      "legacy oversized async batch accepted after connector upgrade",
      15_000,
      async () => (await codexBatchEnvelopes(logPath)).length === 1,
    );
    const envelope = (await codexBatchEnvelopes(logPath))[0];
    const messages = envelope.messages as Array<Record<string, unknown>>;
    const content = messages[0]?.content as Array<Record<string, unknown>>;
    const notification = JSON.parse(String(content?.[0]?.text ?? ""));
    const failedContent = messages[1]?.content as Array<
      Record<string, unknown>
    >;
    const failedNotification = JSON.parse(
      String(failedContent?.[0]?.text ?? ""),
    );
    const ordinaryContent = messages[2]?.content as Array<
      Record<string, unknown>
    >;
    const pageContent = messages[3]?.content as Array<Record<string, unknown>>;
    const currentPageNotification = JSON.parse(
      String(pageContent?.[0]?.text ?? ""),
    );
    if (
      envelope.batch_id !== dispatchID ||
      (envelope.source_batch_ids as string[]).join(",") !== dispatchID ||
      messages.length !== 4 ||
      messages[0]?.message_id !== messageID ||
      notification.type !== "tool_call_completed" ||
      notification.tool_call_id !== toolCallID ||
      notification.status !== "completed" ||
      "result" in notification ||
      JSON.stringify(notification).includes(legacyResultMarker) ||
      !String(notification.message).includes("tool_call.get_result") ||
      !String(notification.message).includes("offset 0")
    ) {
      throw new Error(
        "legacy oversized async recovery changed identity or retained its result",
      );
    }
    if (
      messages[1]?.message_id !== "message-legacy-oversized-failed" ||
      failedNotification.type !== "tool_call_failed" ||
      failedNotification.tool_call_id !== "call-legacy-oversized-failed" ||
      failedNotification.status !== "failed" ||
      failedNotification.error !== true ||
      "result" in failedNotification ||
      JSON.stringify(failedNotification).includes("LEGACY_FAILED_RESULT_END") ||
      !String(failedNotification.message).includes("tool_call.get_result") ||
      !String(failedNotification.message).includes("offset 0")
    ) {
      throw new Error(
        "historical failed async recovery remained oversized or lost failure semantics",
      );
    }
    if (
      ordinaryContent?.[0]?.text !== "ORDINARY_USER_INPUT_UNCHANGED" ||
      currentPageNotification.result_page?.content !== "CURRENT_PAGE_PREVIEW" ||
      "result" in currentPageNotification
    ) {
      throw new Error(
        "legacy async recovery rewrote ordinary input or a current result page",
      );
    }
    if (
      (await Deno.readTextFile(logPath)).includes(
        "turn/rejected input_too_large",
      )
    ) {
      throw new Error(
        "compacted legacy async batch still exceeded native input",
      );
    }
    // The fake logs turn/start before writing its RPC response. Wait for the
    // Connector to consume that response and retire the durable inbox row so
    // the restart assertion observes an accepted batch, not the intentional
    // at-least-once ambiguous-response window.
    await delay(500);
    await connector.crash();
    connector = startLocalStdioConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    await delay(1_000);
    if ((await codexBatchEnvelopes(logPath)).length !== 1) {
      throw new Error(
        "acked legacy async batch was delivered again after connector restart",
      );
    }
  } finally {
    await connector.close().catch(() => {});
  }
}

async function exerciseDurableDownstreamBatch(
  opts: Omit<LocalRecoveryOptions, "exitNormally">,
) {
  const kimiSource = `${opts.fakeBin}/kimi-source`;
  const command = `${opts.fakeBin}/pi`;
  const logPath = `${command}.log`;
  const blockMarker = `${command}.block-prompt`;
  for (const path of [opts.root, opts.home, opts.fakeBin, kimiSource]) {
    await Deno.mkdir(path, { recursive: true });
  }
  await Deno.writeTextFile(blockMarker, "armed\n");
  await writeFakeRuntime(
    command,
    "durable downstream pi fake",
    [
      "export SALIX_TEST_FAKE_PI=1",
      `export SALIX_TEST_FAKE_PI_LOG=${shellQuote(logPath)}`,
      `export SALIX_TEST_FAKE_PI_BLOCK_PROMPT_WHILE_EXISTS=${
        shellQuote(
          blockMarker,
        )
      }`,
    ],
    opts.helper,
    "TestHelperPiRPC",
  );

  const params = {
    kind: "external",
    provider: "pi",
    session_id: "session-durable-downstream",
    dispatch_id: "batch-durable-downstream",
    runtime_capability_token: "capability-session-durable-downstream",
    runtime_payload: {},
    runtime_config: { command },
    system_prompt: "durable downstream e2e",
    input_messages: [
      {
        id: "message-one",
        role: "user",
        content: "first message",
        created_at: 1_721_038_896,
      },
      {
        id: "message-two",
        role: "user",
        content: '"]},"delivery":{"may_be_duplicate":false},"injected":"value',
        created_at: 1_721_042_496,
      },
    ],
  };
  let connector = startLocalStdioConnector(
    opts.bin,
    opts.root,
    opts.home,
    kimiSource,
  );
  let disconnected: Deno.ChildProcess | undefined;
  try {
    const accepted = await withTimeout(
      connector.request("durable-downstream", "agent_runtime_input", params),
      5_000,
      "connector durable batch ACK",
    );
    if (accepted.accepted !== true) {
      throw new Error("connector did not durably accept the downstream batch");
    }
    const duplicate = await withTimeout(
      connector.request(
        "durable-downstream-duplicate",
        "agent_runtime_input",
        params,
      ),
      5_000,
      "connector duplicate batch ACK",
    );
    if (
      duplicate.dispatch_id !== accepted.dispatch_id ||
      "execution_id" in accepted ||
      "execution_id" in duplicate
    ) {
      throw new Error("Connector ACK leaked or changed native execution state");
    }
    await waitUntil(
      "native runtime blocked after durable ACK",
      5_000,
      async () =>
        (await Deno.readTextFile(logPath).catch(() => "")).includes(
          "blocked_batch_prompt",
        ),
    );
    const followupParams = {
      ...params,
      dispatch_id: "batch-durable-downstream-followup",
      input_messages: [
        {
          id: "message-three",
          role: "user",
          content: "follow-up message while the prior batch is pending",
          created_at: 1_721_046_096,
        },
      ],
    };
    const followup = await withTimeout(
      connector.request(
        "durable-downstream-followup",
        "agent_runtime_input",
        followupParams,
      ),
      5_000,
      "connector durable follow-up batch ACK",
    );
    if (
      followup.accepted !== true ||
      followup.dispatch_id !== followupParams.dispatch_id
    ) {
      throw new Error("connector did not durably accept the follow-up batch");
    }
    const envelopesBeforeCrash = (await downstreamBatchEnvelopes(logPath))
      .length;
    await connector.crash();
    await Deno.remove(blockMarker);
    disconnected = startDisconnectedConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    await waitUntil(
      "pending batches merged and delivered without a Server",
      30_000,
      async () =>
        (await downstreamBatchEnvelopes(logPath)).length ===
          envelopesBeforeCrash + 1,
    );
    await delay(750);
    if (
      (await downstreamBatchEnvelopes(logPath)).length !==
        envelopesBeforeCrash + 1
    ) {
      throw new Error(
        "pending batches were delivered as separate runtime calls",
      );
    }
    const runtimeStarts = (await Deno.readTextFile(logPath))
      .split("\n")
      .filter((line) => line.startsWith("start "));
    if (
      runtimeStarts.length < 2 ||
      !runtimeStarts.at(-1)?.includes("--session pi-native")
    ) {
      throw new Error(
        `pending batch recreated Pi instead of exact resume: ${
          runtimeStarts.join(
            " | ",
          )
        }`,
      );
    }
    const envelopes = await downstreamBatchEnvelopes(logPath);
    const envelope = envelopes.at(-1) as Record<string, unknown>;
    if (
      envelope.schema !== "external_session_message_batch_v1" ||
      envelope.batch_id !== followupParams.dispatch_id ||
      (envelope.source_batch_ids as string[]).join(",") !==
        `${params.dispatch_id},${followupParams.dispatch_id}`
    ) {
      throw new Error(
        `invalid downstream batch envelope: ${JSON.stringify(envelope)}`,
      );
    }
    const delivery = envelope.delivery as Record<string, unknown>;
    if (
      delivery.may_be_duplicate !== true ||
      typeof delivery.delivered_at !== "string" ||
      !delivery.delivered_at.includes("UTC")
    ) {
      throw new Error(
        "replayed batch lacked readable duplicate delivery context",
      );
    }
    const messages = envelope.messages as Array<Record<string, unknown>>;
    const secondContent = messages[1]?.content as Array<
      Record<string, unknown>
    >;
    if (
      messages.map((message) => message.message_id).join(",") !==
        "message-one,message-two,message-three" ||
      messages.map((message) => message.sent_at).join(",") !==
        "Monday, 15 July 2024 at 10:21:36 UTC,Monday, 15 July 2024 at 11:21:36 UTC,Monday, 15 July 2024 at 12:21:36 UTC" ||
      secondContent?.[0]?.text !== params.input_messages[1].content ||
      "injected" in envelope
    ) {
      throw new Error(
        "downstream batch lost order, readable time, or JSON isolation",
      );
    }
    await delay(500);
    const deliveredCount = envelopes.length;
    await stopDisconnectedConnector(disconnected);
    disconnected = startDisconnectedConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    await delay(1_000);
    if ((await downstreamBatchEnvelopes(logPath)).length !== deliveredCount) {
      throw new Error(
        "acked native batch was delivered again after connector restart",
      );
    }
    await stopDisconnectedConnector(disconnected);
    disconnected = undefined;
    connector = startLocalStdioConnectorWithoutHome(
      opts.bin,
      opts.root,
      kimiSource,
    );
    const noHomeParams = {
      ...params,
      dispatch_id: "batch-existing-session-without-home",
      input_messages: [
        {
          id: "message-existing-session-without-home",
          role: "user",
          content: "continue the existing session without ambient HOME",
          created_at: 1_721_049_696,
        },
      ],
    };
    const noHomeAccepted = await connector.request(
      "existing-session-without-home",
      "agent_runtime_input",
      noHomeParams,
    );
    if (
      noHomeAccepted.accepted !== true ||
      noHomeAccepted.dispatch_id !== noHomeParams.dispatch_id
    ) {
      throw new Error("existing session rejected input without ambient HOME");
    }
    await waitUntil(
      "existing session used its persisted workspace without HOME",
      15_000,
      async () =>
        (await downstreamBatchEnvelopes(logPath)).length === deliveredCount + 1,
    );
  } finally {
    await connector.close().catch(() => {});
    if (disconnected) {
      await stopDisconnectedConnector(disconnected).catch(() => {});
    }
  }
}

async function exerciseRuntimeEventRetryFairness(
  opts: Omit<LocalRecoveryOptions, "exitNormally">,
) {
  const kimiSource = `${opts.fakeBin}/kimi-source`;
  for (const path of [opts.root, opts.home, opts.fakeBin, kimiSource]) {
    await Deno.mkdir(path, { recursive: true });
  }
  await run(
    opts.helper,
    ["-test.run=^TestHelperSeedRuntimeEventRetryFairness$"],
    {
      env: {
        ...Deno.env.toObject(),
        SALIX_TEST_SEED_RUNTIME_EVENT_RETRY_FAIRNESS: opts.root,
      },
    },
  );

  const connector = startLocalStdioConnector(
    opts.bin,
    opts.root,
    opts.home,
    kimiSource,
  );
  try {
    await connector.requireHealthyRuntimeEventBehindRetryingSession(13_000);
  } finally {
    await connector.close().catch(() => {});
  }
}

async function exerciseLegacyLifecycleMigration(
  opts: Omit<LocalRecoveryOptions, "exitNormally">,
) {
  const kimiSource = `${opts.fakeBin}/kimi-source`;
  const completedCommand = `${opts.fakeBin}/pi-completed`;
  const activeCommand = `${opts.fakeBin}/pi-active`;
  const ackedActiveCommand = `${opts.fakeBin}/pi-acked-active`;
  const completedLog = `${completedCommand}.log`;
  const activeLog = `${activeCommand}.log`;
  const ackedActiveLog = `${ackedActiveCommand}.log`;
  const activeBlock = `${activeCommand}.block`;
  const ackedActiveBlock = `${ackedActiveCommand}.block`;
  for (const path of [opts.root, opts.home, opts.fakeBin, kimiSource]) {
    await Deno.mkdir(path, { recursive: true });
  }
  await Deno.writeTextFile(activeBlock, "armed\n");
  await Deno.writeTextFile(ackedActiveBlock, "armed\n");
  for (
    const [command, log, extra] of [
      [completedCommand, completedLog, []],
      [
        activeCommand,
        activeLog,
        [
          `export SALIX_TEST_FAKE_PI_BLOCK_PROMPT_WHILE_EXISTS=${
            shellQuote(
              activeBlock,
            )
          }`,
        ],
      ],
      [
        ackedActiveCommand,
        ackedActiveLog,
        [
          `export SALIX_TEST_FAKE_PI_BLOCK_PROMPT_WHILE_EXISTS=${
            shellQuote(
              ackedActiveBlock,
            )
          }`,
        ],
      ],
    ] as const
  ) {
    await writeFakeRuntime(
      command,
      "pi legacy lifecycle fake",
      [
        "export SALIX_TEST_FAKE_PI=1",
        `export SALIX_TEST_FAKE_PI_LOG=${shellQuote(log)}`,
        ...extra,
      ],
      opts.helper,
      "TestHelperPiRPC",
    );
  }
  await run(
    opts.helper,
    ["-test.run=^TestHelperSeedLegacyRuntimeLifecycleState$"],
    {
      env: {
        ...Deno.env.toObject(),
        SALIX_TEST_SEED_LEGACY_RUNTIME_LIFECYCLE_STATE: opts.root,
        SALIX_TEST_SEED_LEGACY_COMPLETED_COMMAND: completedCommand,
        SALIX_TEST_SEED_LEGACY_ACTIVE_COMMAND: activeCommand,
        SALIX_TEST_SEED_LEGACY_ACKED_ACTIVE_COMMAND: ackedActiveCommand,
      },
    },
  );

  const disconnected = startDisconnectedConnector(
    opts.bin,
    opts.root,
    opts.home,
    kimiSource,
  );
  let stopped = false;
  try {
    await waitUntil(
      "legacy unacknowledged active execution restored",
      10_000,
      async () =>
        (await Deno.readTextFile(activeLog).catch(() => "")).includes("start "),
    );
    await waitUntil(
      "legacy acknowledged-running execution restored",
      10_000,
      async () =>
        (await Deno.readTextFile(ackedActiveLog).catch(() => "")).includes(
          "start ",
        ),
    );
    if (
      (await Deno.readTextFile(completedLog).catch(() => "")).includes("start ")
    ) {
      throw new Error(
        "legacy completed identity was promoted to active recovery",
      );
    }
    await stopDisconnectedConnector(disconnected);
    stopped = true;
    const state = await inspectExternalRuntimeState(opts.helper, opts.root);
    if (
      Number(state["session-identities-v2"] ?? 0) !== 3 ||
      Number(state["active-executions-v2"] ?? 0) !== 2 ||
      Number(state["input-batches-v1"] ?? 0) !== 0 ||
      Number(state["active-sessions-v1"] ?? 0) !== 0
    ) {
      throw new Error(
        `legacy lifecycle migration misclassified facts: ${
          JSON.stringify(
            state,
          )
        }`,
      );
    }
  } finally {
    if (!stopped) await stopDisconnectedConnector(disconnected).catch(() => {});
    await Deno.remove(activeBlock).catch(() => {});
    await Deno.remove(ackedActiveBlock).catch(() => {});
  }
}

async function exerciseRuntimeEventPayloadCompaction(
  opts: Omit<LocalRecoveryOptions, "exitNormally">,
) {
  const kimiSource = `${opts.fakeBin}/kimi-source`;
  const command = `${opts.fakeBin}/pi`;
  for (const path of [opts.root, opts.home, opts.fakeBin, kimiSource]) {
    await Deno.mkdir(path, { recursive: true });
  }
  await writeFakeRuntime(
    command,
    "pi oversized event fake",
    [
      "export SALIX_TEST_FAKE_PI=1",
      "export SALIX_TEST_FAKE_PI_OVERSIZED_TOOL_RESULT_BYTES=9437184",
      "export SALIX_TEST_FAKE_PI_OVERSIZED_TOOL_NAME=read_file",
      "export SALIX_TEST_FAKE_PI_OVERSIZED_TOOL_PATH=/workspace/large-report.txt",
    ],
    opts.helper,
    "TestHelperPiRPC",
  );

  const connector = startLocalStdioConnector(
    opts.bin,
    opts.root,
    opts.home,
    kimiSource,
  );
  let crashed = false;
  try {
    const delivery = await connector.requestAndWaitForRuntimeEvent(
      "start-oversized-event",
      "agent_runtime_input",
      {
        kind: "external",
        provider: "pi",
        session_id: "session-oversized-event",
        dispatch_id: "dispatch-oversized-event",
        runtime_capability_token: "capability-oversized-event",
        runtime_config: { command },
        system_prompt: "event byte bound e2e",
        input_messages: [{ role: "user", content: "emit the result" }],
      },
      (event) => event.event.name === "read_file",
      "permanent",
    );
    if (delivery.legacy) {
      throw new Error(
        "a compacted runtime event was still sent through the oversized legacy method",
      );
    }
    const event = delivery.events.find(
      (item) => item.event.name === "read_file",
    )?.event;
    if (!event) throw new Error("compacted read event was not delivered");
    assertCompactedReadEvent(event, "/workspace/large-report.txt", 9437184);
    await delay(500);
    await connector.crash();
    crashed = true;
    const state = await inspectExternalRuntimeState(opts.helper, opts.root);
    const eventNames = (state.event_names ?? {}) as Record<string, number>;
    if (Number(eventNames.read_file ?? 0) !== 0) {
      throw new Error(
        "permanently rejected runtime event remained in the durable outbox",
      );
    }
  } finally {
    if (!crashed) await connector.crash().catch(() => {});
  }
}

async function exerciseSettledSessionIdentity(
  opts: Omit<LocalRecoveryOptions, "exitNormally">,
) {
  const kimiSource = `${opts.fakeBin}/kimi-source`;
  const command = `${opts.fakeBin}/pi`;
  const logPath = `${command}.log`;
  const pidPath = `${command}.pid`;
  const replacementCommand = `${opts.fakeBin}/pi-replacement`;
  const replacementLogPath = `${replacementCommand}.log`;
  const replacementPIDPath = `${replacementCommand}.pid`;
  const lifecycleMarker = `${command}.settle-first-prompt`;
  for (const path of [opts.root, opts.home, opts.fakeBin, kimiSource]) {
    await Deno.mkdir(path, { recursive: true });
  }
  await Deno.writeTextFile(lifecycleMarker, "armed\n");
  await writeFakeRuntime(
    command,
    "settled identity pi fake",
    [
      "export SALIX_TEST_FAKE_PI=1",
      `export SALIX_TEST_FAKE_PI_LOG=${shellQuote(logPath)}`,
      `export SALIX_TEST_FAKE_PI_FIRST_PROMPT_LIFECYCLE_MARKER=${
        shellQuote(
          lifecycleMarker,
        )
      }`,
      "export SALIX_TEST_FAKE_PI_FIRST_PROMPT_LIFECYCLE=settled",
      `printf '%s\\n' "$$" > ${shellQuote(pidPath)}`,
    ],
    opts.helper,
    "TestHelperPiRPC",
  );
  await writeFakeRuntime(
    replacementCommand,
    "replacement settled identity pi fake",
    [
      "export SALIX_TEST_FAKE_PI=1",
      `export SALIX_TEST_FAKE_PI_LOG=${shellQuote(replacementLogPath)}`,
      `printf '%s\\n' "$$" > ${shellQuote(replacementPIDPath)}`,
    ],
    opts.helper,
    "TestHelperPiRPC",
  );

  let connector = startLocalStdioConnector(
    opts.bin,
    opts.root,
    opts.home,
    kimiSource,
  );
  let disconnected: Deno.ChildProcess | undefined;
  try {
    const accepted = await connector.request(
      "start-settled-identity",
      "agent_runtime_input",
      {
        kind: "external",
        provider: "pi",
        session_id: "session-settled-identity",
        dispatch_id: "dispatch-settled-identity",
        runtime_capability_token: "capability-settled-identity",
        runtime_config: { command },
        system_prompt: "settled identity e2e",
        input_messages: [{ role: "user", content: "finish this turn" }],
      },
    );
    if (accepted.accepted !== true) {
      throw new Error("settled identity input was not durably accepted");
    }
    await connector.waitForRuntimeEvent(
      (event) => event.work_state === "settled",
      10_000,
    );
    const startsBeforeRestart = (await Deno.readTextFile(logPath))
      .split("\n")
      .filter((line) => line.startsWith("start ")).length;
    if (startsBeforeRestart !== 1) {
      throw new Error(`settled identity started ${startsBeforeRestart} times`);
    }

    await connector.crash();
    const persisted = await inspectExternalRuntimeState(opts.helper, opts.root);
    if (
      Number(persisted["session-identities-v2"] ?? 0) !== 1 ||
      Number(persisted["active-executions-v2"] ?? 0) !== 0 ||
      Number(persisted["active-sessions-v1"] ?? 0) !== 0
    ) {
      throw new Error(
        `settled identity persistence was not sparse: ${
          JSON.stringify(
            persisted,
          )
        }`,
      );
    }
    try {
      Deno.kill(Number((await Deno.readTextFile(pidPath)).trim()), "SIGKILL");
    } catch {
      // The Connector-owned child may already have observed its closed pipe.
    }
    disconnected = startDisconnectedConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    await delay(2_000);
    const startsAfterRestart = (await Deno.readTextFile(logPath))
      .split("\n")
      .filter((line) => line.startsWith("start ")).length;
    if (startsAfterRestart !== startsBeforeRestart) {
      throw new Error(
        "Connector restart treated a settled resumable identity as active work",
      );
    }
    if (
      (await recoveryDecisionCount({
        provider: "pi",
        sessionID: "session-settled-identity",
        command,
        logPath,
        pidPath,
        statePath:
          `${opts.home}/.comma/workspaces/session-settled-identity/recovery-state`,
        decisionPath:
          `${opts.home}/.comma/workspaces/session-settled-identity/recovery-decisions.log`,
        recoveryMarker: "--session pi-native",
        startMarker: (line) => line.startsWith("start --mode rpc"),
      })) !== 0
    ) {
      throw new Error(
        "settled identity received an interruption recovery turn",
      );
    }

    await stopDisconnectedConnector(disconnected);
    disconnected = undefined;
    connector = startLocalStdioConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    const resumed = await connector.request(
      "resume-settled-identity",
      "agent_runtime_input",
      {
        kind: "external",
        provider: "pi",
        session_id: "session-settled-identity",
        dispatch_id: "dispatch-resume-settled-identity",
        runtime_capability_token: "capability-settled-identity",
        runtime_config: { command: replacementCommand },
        system_prompt: "settled identity e2e",
        input_messages: [{ role: "user", content: "start new work" }],
      },
    );
    if (resumed.accepted !== true) {
      throw new Error("settled identity rejected later real input");
    }
    await waitUntil(
      "settled identity selected its exact persisted command",
      10_000,
      async () => {
        const starts = (await Deno.readTextFile(logPath))
          .split("\n")
          .filter((line) => line.startsWith("start "));
        const replacementStarts = (await pathExists(replacementLogPath))
          ? (await Deno.readTextFile(replacementLogPath))
            .split("\n")
            .filter((line) => line.startsWith("start ")).length
          : 0;
        return (
          starts.length === startsBeforeRestart + 1 || replacementStarts > 0
        );
      },
    );
    if (await pathExists(replacementLogPath)) {
      const replacementStarts = (await Deno.readTextFile(replacementLogPath))
        .split("\n")
        .filter((line) => line.startsWith("start ")).length;
      if (replacementStarts > 0) {
        throw new Error(
          "settled identity accepted a replacement command after Connector restart",
        );
      }
    }
    const resumedStarts = (await Deno.readTextFile(logPath))
      .split("\n")
      .filter((line) => line.startsWith("start "));
    if (
      resumedStarts.length !== startsBeforeRestart + 1 ||
      !resumedStarts.at(-1)?.includes("--session pi-native")
    ) {
      throw new Error(
        "settled identity did not resume its exact native session",
      );
    }

    const codexCommand = `${opts.fakeBin}/codex`;
    const codexLog = `${codexCommand}.log`;
    const codexPID = `${codexCommand}.pid`;
    const codexWorkspace = `${opts.home}/.comma/workspaces/session-settled-codex`;
    const codexState = `${codexWorkspace}/recovery-state`;
    const codexDecisions = `${codexWorkspace}/recovery-decisions.log`;
    await Deno.mkdir(codexWorkspace, { recursive: true });
    await Deno.writeTextFile(codexState, "complete\n");
    await writeFakeRuntime(
      codexCommand,
      "settled identity codex fake",
      [
        "export SALIX_TEST_FAKE_CODEX=1",
        "export SALIX_TEST_FAKE_CODEX_COMPLETE_TURN=1",
        `export SALIX_TEST_FAKE_CODEX_LOG=${shellQuote(codexLog)}`,
        `export SALIX_TEST_FAKE_RECOVERY_STATE_PATH=${shellQuote(codexState)}`,
        `export SALIX_TEST_FAKE_RECOVERY_DECISION_PATH=${
          shellQuote(
            codexDecisions,
          )
        }`,
        `printf '%s\\n' "$$" > ${shellQuote(codexPID)}`,
      ],
      opts.helper,
      "TestHelperCodexAppServer",
    );
    const codexFixture: LocalRuntimeFixture = {
      provider: "codex",
      sessionID: "session-settled-codex",
      command: codexCommand,
      logPath: codexLog,
      pidPath: codexPID,
      statePath: codexState,
      decisionPath: codexDecisions,
      recoveryMarker: "thread/resume",
      startMarker: (line) => line === "start",
    };
    await connector.requestAndWaitForRuntimeEvent(
      "start-settled-codex",
      "agent_runtime_input",
      {
        kind: "external",
        provider: "codex",
        session_id: codexFixture.sessionID,
        dispatch_id: "dispatch-settled-codex",
        runtime_capability_token: "capability-settled-codex",
        runtime_config: { command: codexCommand },
        system_prompt: "settled identity e2e",
        input_messages: [{ role: "user", content: "finish this codex turn" }],
      },
      (event) =>
        event.dispatchID === "dispatch-settled-codex" &&
        event.event.work_state === "settled",
    );
    const codexStartsBeforeIdleExit = await runtimeStartCount(codexFixture);
    Deno.kill(Number((await Deno.readTextFile(codexPID)).trim()), "SIGKILL");
    await waitUntil(
      "settled Codex app-server exited",
      5_000,
      async () => !(await runtimeProcessAlive(codexFixture)),
    );
    await delay(1_000);
    if ((await runtimeStartCount(codexFixture)) !== codexStartsBeforeIdleExit) {
      throw new Error(
        "settled Codex app-server exit triggered active recovery",
      );
    }
    const resumedCodex = await connector.request(
      "resume-settled-codex",
      "agent_runtime_input",
      {
        kind: "external",
        provider: "codex",
        session_id: codexFixture.sessionID,
        dispatch_id: "dispatch-resume-settled-codex",
        runtime_capability_token: "capability-settled-codex",
        runtime_config: { command: codexCommand },
        system_prompt: "settled identity e2e",
        input_messages: [{ role: "user", content: "start later codex work" }],
      },
    );
    if (resumedCodex.accepted !== true) {
      throw new Error("settled Codex identity rejected later input");
    }
    await waitUntil(
      "settled Codex identity lazily resumed its thread",
      10_000,
      async () =>
        (await runtimeStartCount(codexFixture)) ===
          codexStartsBeforeIdleExit + 1 &&
        (await runtimeMethodCount(codexFixture, "thread/resume")) === 1,
    );
    await delay(500);
    if (
      (await runtimeStartCount(codexFixture)) !==
        codexStartsBeforeIdleExit + 1 ||
      (await runtimeMethodCount(codexFixture, "thread/resume")) !== 1
    ) {
      throw new Error(
        "settled Codex identity did not lazily resume its thread",
      );
    }
    if ((await recoveryDecisionCount(codexFixture)) !== 0) {
      throw new Error(
        "later Codex input was incorrectly prefixed with interruption recovery",
      );
    }
  } finally {
    await connector.close().catch(() => {});
    if (disconnected) {
      await stopDisconnectedConnector(disconnected).catch(() => {});
    }
  }
}

async function inspectExternalRuntimeState(helper: string, root: string) {
  const output = `${root}/external-runtime-state-summary.json`;
  await run(helper, ["-test.run=^TestHelperInspectExternalRuntimeState$"], {
    env: {
      ...Deno.env.toObject(),
      SALIX_TEST_INSPECT_EXTERNAL_RUNTIME_STATE: root,
      SALIX_TEST_INSPECT_EXTERNAL_RUNTIME_STATE_OUTPUT: output,
    },
  });
  return JSON.parse(await Deno.readTextFile(output)) as Record<string, unknown>;
}

function assertCompactedReadEvent(
  event: Record<string, unknown>,
  expectedPath: string,
  minimumJSONBytes: number,
) {
  const input = (event.input ?? {}) as Record<string, unknown>;
  const output = (event.output ?? {}) as Record<string, unknown>;
  if (
    input.path !== expectedPath ||
    input.offset !== 7 ||
    Object.hasOwn(input, "content")
  ) {
    throw new Error(
      `read event retained unsafe input: ${JSON.stringify(input)}`,
    );
  }
  if (
    output.omitted !== true ||
    Number(output.json_bytes ?? 0) < minimumJSONBytes
  ) {
    throw new Error(
      "read event retained raw output instead of bounded metadata",
    );
  }
  if (Object.hasOwn(event, "issue")) {
    throw new Error("non-terminal runtime event retained a terminal issue");
  }
}

async function exerciseWorkspacePreparationAfterDurableAck(
  opts: Omit<LocalRecoveryOptions, "exitNormally">,
) {
  const kimiSource = `${opts.fakeBin}/kimi-source`;
  const command = `${opts.fakeBin}/pi`;
  const logPath = `${command}.log`;
  const workspaceRoot = `${opts.home}/.comma/workspaces`;
  for (
    const path of [
      opts.root,
      opts.home,
      opts.fakeBin,
      kimiSource,
      `${opts.home}/.comma`,
    ]
  ) {
    await Deno.mkdir(path, { recursive: true });
  }
  await Deno.writeTextFile(workspaceRoot, "temporarily unavailable\n");
  await writeFakeRuntime(
    command,
    "workspace deferred pi fake",
    [
      "export SALIX_TEST_FAKE_PI=1",
      `export SALIX_TEST_FAKE_PI_LOG=${shellQuote(logPath)}`,
    ],
    opts.helper,
    "TestHelperPiRPC",
  );

  let connector = startLocalStdioConnector(
    opts.bin,
    opts.root,
    opts.home,
    kimiSource,
  );
  let disconnected: Deno.ChildProcess | undefined;
  try {
    const params = {
      kind: "external",
      provider: "pi",
      session_id: "session-workspace-deferred",
      dispatch_id: "batch-workspace-deferred",
      runtime_capability_token: "capability-session-workspace-deferred",
      runtime_payload: {},
      runtime_config: { command },
      system_prompt: "workspace deferred e2e",
      input_messages: [
        {
          id: "message-workspace-deferred",
          role: "user",
          content: "persist before preparing the workspace",
          created_at: 1_721_053_296,
        },
      ],
    };
    const accepted = await withTimeout(
      connector.request("workspace-deferred", "agent_runtime_input", params),
      1_000,
      "workspace-deferred durable ACK",
    );
    if (
      accepted.accepted !== true ||
      accepted.dispatch_id !== params.dispatch_id
    ) {
      throw new Error("workspace failure prevented durable local ACK");
    }
    await delay(500);
    if ((await downstreamBatchEnvelopes(logPath)).length !== 0) {
      throw new Error("runtime received input before its workspace was ready");
    }

    await connector.crash();
    connector = startLocalStdioConnectorWithoutHome(
      opts.bin,
      opts.root,
      kimiSource,
    );
    const duplicate = await withTimeout(
      connector.request(
        "workspace-deferred-duplicate",
        "agent_runtime_input",
        params,
      ),
      1_000,
      "persisted workspace duplicate ACK without HOME",
    );
    if (
      duplicate.accepted !== true ||
      duplicate.dispatch_id !== params.dispatch_id
    ) {
      throw new Error("persisted batch was not re-ACKed without ambient HOME");
    }
    await connector.crash();
    await Deno.remove(workspaceRoot);
    disconnected = startDisconnectedConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    await waitUntil(
      "durable batch resumed after workspace preparation recovered",
      30_000,
      async () => (await downstreamBatchEnvelopes(logPath)).length === 1,
    );
    const envelope = (await downstreamBatchEnvelopes(logPath))[0];
    if (envelope.batch_id !== params.dispatch_id) {
      throw new Error("workspace recovery delivered the wrong durable batch");
    }
  } finally {
    await connector.close().catch(() => {});
    if (disconnected) {
      await stopDisconnectedConnector(disconnected).catch(() => {});
    }
  }
}

async function downstreamBatchEnvelopes(path: string) {
  const lines = (await Deno.readTextFile(path).catch(() => "")).split("\n");
  const envelopes: Array<Record<string, unknown>> = [];
  for (const line of lines) {
    if (!line.startsWith('{"id"') || !line.includes('"type":"prompt"')) {
      continue;
    }
    const request = JSON.parse(line);
    const message = String(request.message ?? "");
    try {
      const envelope = JSON.parse(message);
      if (envelope.schema === "external_session_message_batch_v1") {
        envelopes.push(envelope);
      }
    } catch {
      // Pre-change input is deliberately not a JSON batch envelope.
    }
  }
  return envelopes;
}

async function codexBatchEnvelopes(path: string) {
  const lines = (await Deno.readTextFile(path).catch(() => "")).split("\n");
  const envelopes: Array<Record<string, unknown>> = [];
  for (const line of lines) {
    if (!line.startsWith("turn/start ")) continue;
    const params = JSON.parse(line.slice("turn/start ".length));
    for (const input of params.input ?? []) {
      const text = String(input.text ?? "");
      try {
        const envelope = JSON.parse(text);
        if (envelope.schema === "external_session_message_batch_v1") {
          envelopes.push(envelope);
        }
      } catch {
        // Recovery guidance is a separate text input.
      }
    }
  }
  return envelopes;
}

async function exerciseTransientCodexResumeRetry(
  opts: Omit<LocalRecoveryOptions, "exitNormally">,
) {
  const sessionID = "session-codex-resume-retry";
  const command = `${opts.fakeBin}/codex-resume-retry`;
  const logPath = `${command}.log`;
  const pidPath = `${command}.pid`;
  const initializeFailureMarker = `${command}-fail-initialize`;
  const initializeResponseDropMarker = `${command}-drop-initialize-response`;
  const resumeFailureMarker = `${command}-fail-thread-resume`;
  const workspace = `${opts.home}/.comma/workspaces/${sessionID}`;
  const statePath = `${workspace}/recovery-state`;
  const decisionPath = `${workspace}/recovery-decisions.log`;
  const kimiSource = `${opts.fakeBin}/kimi-source`;
  for (
    const path of [
      opts.root,
      opts.home,
      opts.fakeBin,
      workspace,
      kimiSource,
    ]
  ) {
    await Deno.mkdir(path, { recursive: true });
  }
  await Deno.writeTextFile(statePath, "continue\n");
  await writeFakeRuntime(
    command,
    "codex fake",
    [
      "export SALIX_TEST_FAKE_CODEX=1",
      `export SALIX_TEST_FAKE_CODEX_LOG=${shellQuote(logPath)}`,
      `export SALIX_TEST_FAKE_RECOVERY_STATE_PATH=${shellQuote(statePath)}`,
      `export SALIX_TEST_FAKE_RECOVERY_DECISION_PATH=${
        shellQuote(
          decisionPath,
        )
      }`,
      `export SALIX_TEST_FAKE_CODEX_FAIL_THREAD_RESUME_ONCE=${
        shellQuote(
          resumeFailureMarker,
        )
      }`,
      `export SALIX_TEST_FAKE_CODEX_FAIL_INITIALIZE_ONCE=${
        shellQuote(
          initializeFailureMarker,
        )
      }`,
      `export SALIX_TEST_FAKE_CODEX_DROP_INITIALIZE_RESPONSE_ONCE=${
        shellQuote(
          initializeResponseDropMarker,
        )
      }`,
      `printf '%s\\n' "$$" > ${shellQuote(pidPath)}`,
    ],
    opts.helper,
    "TestHelperCodexAppServer",
  );
  const fixture: LocalRuntimeFixture = {
    provider: "codex",
    sessionID,
    command,
    logPath,
    pidPath,
    statePath,
    decisionPath,
    recoveryMarker: "thread/resume",
    startMarker: (line) => line === "start",
  };
  let connector = startLocalStdioConnector(
    opts.bin,
    opts.root,
    opts.home,
    kimiSource,
  );
  let disconnectedConnector: Deno.ChildProcess | undefined;
  try {
    const result = await connector.request(
      `start-${sessionID}`,
      "agent_runtime_input",
      {
        kind: "external",
        provider: "codex",
        session_id: sessionID,
        dispatch_id: `dispatch-${sessionID}`,
        runtime_capability_token: `capability-${sessionID}`,
        runtime_config: { command },
        system_prompt: "local recovery e2e",
        input_messages: [{ role: "user", content: "exercise recovery" }],
      },
    );
    if (result.accepted !== true) {
      throw new Error("Codex did not accept the retry fixture input");
    }
    await waitUntil(
      "initial Codex retry fixture input",
      10_000,
      async () => (await runtimeInputCount(fixture)) === 1,
    );
    const originalThreadID = await recoveryThreadID(fixture);

    await Deno.writeTextFile(initializeFailureMarker, "armed\n");
    Deno.kill(Number((await Deno.readTextFile(pidPath)).trim()), "SIGKILL");
    await waitUntil(
      "live Codex recovery retried after transient initialize failure",
      25_000,
      async () => (await recoveryDecisionCount(fixture)) === 1,
    );
    if (await pathExists(initializeFailureMarker)) {
      throw new Error(
        "live Codex recovery did not exercise the transient initialize failure",
      );
    }
    if ((await recoveryThreadID(fixture)) !== originalThreadID) {
      throw new Error(
        "live transient Codex initialize failure changed the native thread",
      );
    }

    await startCodexRetryFixtureTurn(connector, sessionID, command, 2);

    await Deno.writeTextFile(initializeResponseDropMarker, "armed\n");
    Deno.kill(Number((await Deno.readTextFile(pidPath)).trim()), "SIGKILL");
    await waitUntil(
      "live Codex recovery settled an ambiguous initialize response",
      45_000,
      async () => (await recoveryDecisionCount(fixture)) === 2,
    );
    if (await pathExists(initializeResponseDropMarker)) {
      throw new Error(
        "live Codex recovery did not exercise the ambiguous initialize response",
      );
    }
    if ((await recoveryThreadID(fixture)) !== originalThreadID) {
      throw new Error(
        "ambiguous Codex initialize response changed the native thread",
      );
    }

    await startCodexRetryFixtureTurn(connector, sessionID, command, 3);
    const resumesBeforeRestart = await runtimeMethodCount(
      fixture,
      "thread/resume",
    );

    await connector.crash();
    Deno.kill(Number((await Deno.readTextFile(pidPath)).trim()), "SIGKILL");
    await Deno.writeTextFile(resumeFailureMarker, "armed\n");
    disconnectedConnector = startDisconnectedConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    // Owner contract: an offline Server cannot admit Codex recovery. Keep
    // the native identity and queued work, then resume after reconnection.
    await delay(3_000);
    if (
      (await recoveryDecisionCount(fixture)) !== 2 ||
      !(await pathExists(resumeFailureMarker))
    ) {
      throw new Error("offline Codex recovery bypassed subscription admission");
    }
    await stopDisconnectedConnector(disconnectedConnector);
    disconnectedConnector = undefined;
    connector = startLocalStdioConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    await waitUntil(
      "Codex recovery retried after transient thread/resume failure",
      25_000,
      async () => (await recoveryDecisionCount(fixture)) === 3,
    );
    if (await pathExists(resumeFailureMarker)) {
      throw new Error(
        "Codex recovery did not exercise the transient resume failure",
      );
    }
    if (
      (await runtimeMethodCount(fixture, "thread/resume")) <
        resumesBeforeRestart + 2
    ) {
      throw new Error(
        "Codex bypassed native resume after its transient failure",
      );
    }
    if ((await recoveryThreadID(fixture)) !== originalThreadID) {
      throw new Error(
        "transient Codex resume failure changed the native thread",
      );
    }
  } finally {
    await connector.close().catch(() => {});
    if (disconnectedConnector) {
      await stopDisconnectedConnector(disconnectedConnector).catch(() => {});
    }
  }
}

async function startCodexRetryFixtureTurn(
  connector: StdioConnectorClient,
  sessionID: string,
  command: string,
  sequence: number,
) {
  const dispatchID = `dispatch-${sessionID}-${sequence}`;
  const result = await connector.request(
    `continue-${sessionID}-${sequence}`,
    "agent_runtime_input",
    {
      kind: "external",
      provider: "codex",
      session_id: sessionID,
      dispatch_id: dispatchID,
      runtime_capability_token: `capability-${sessionID}`,
      runtime_config: { command },
      system_prompt: "local recovery e2e",
      input_messages: [{ role: "user", content: `active turn ${sequence}` }],
    },
  );
  if (result.accepted !== true) {
    throw new Error(`Codex did not accept active retry turn ${sequence}`);
  }
  await connector.waitForRuntimeEvent(
    (event) =>
      event.dispatch_id === dispatchID && event.work_state === "running",
    10_000,
  );
}

async function exerciseLocalRuntimeRecovery(opts: LocalRecoveryOptions) {
  const kimiSource = `${opts.fakeBin}/kimi-source`;
  for (const path of [opts.root, opts.home, opts.fakeBin, kimiSource]) {
    await Deno.mkdir(path, { recursive: true });
  }
  const fixtures = await createLocalRuntimeFixtures(opts);
  const migratedFixture = opts.exitNormally ? undefined : fixtures[3];
  if (migratedFixture) {
    await writeLegacyRecoveryFile(opts.root, migratedFixture);
  }
  let connector = startLocalStdioConnector(
    opts.bin,
    opts.root,
    opts.home,
    kimiSource,
  );
  let disconnectedConnector: Deno.ChildProcess | undefined;

  try {
    for (let index = 0; index < fixtures.length; index++) {
      const fixture = fixtures[index];
      if (fixture === migratedFixture) continue;
      const result = await connector.request(
        `start-${fixture.sessionID}`,
        "agent_runtime_input",
        {
          kind: "external",
          provider: fixture.provider,
          session_id: fixture.sessionID,
          dispatch_id: `dispatch-${fixture.sessionID}`,
          runtime_capability_token: `capability-${fixture.sessionID}`,
          runtime_payload: {},
          runtime_config: { command: fixture.command },
          system_prompt: "local recovery e2e",
          input_messages: [{ role: "user", content: "exercise recovery" }],
        },
      );
      if (result.accepted !== true) {
        throw new Error(`${fixture.provider} did not accept initial input`);
      }
      if (fixture.provider === "codex") {
        await waitUntil(
          `initial ${fixture.sessionID} native batch accepted`,
          15_000,
          async () => (await runtimeInputCount(fixture)) > 0,
        );
      }
    }
    if (migratedFixture) {
      await waitUntil(
        "legacy recovery record migrated and resumed",
        10_000,
        async () =>
          (await recoveryDecisionCount(migratedFixture)) > 0 &&
          !(await legacyRecoveryFileExists(
            opts.root,
            migratedFixture.sessionID,
          )),
      );
      await startRuntimeFixtureTurn(
        connector,
        migratedFixture,
        "after-migration",
      );
    }
    const initialFixtures = fixtures.filter(
      (fixture) => fixture !== migratedFixture,
    );
    try {
      await waitUntil(
        "initial native batches accepted",
        30_000,
        async () =>
          (await Promise.all(initialFixtures.map(runtimeInputCount))).every(
            (count) => count > 0,
          ),
      );
    } catch (error) {
      const counts = await Promise.all(initialFixtures.map(runtimeInputCount));
      throw new Error(
        `initial native batch counts: ${
          initialFixtures
            .map((fixture, index) => `${fixture.sessionID}=${counts[index]}`)
            .join(", ")
        }`,
        { cause: error },
      );
    }

    if (opts.exitNormally) {
      await waitUntil("normal runtimes exited", 10_000, async () =>
        (
          await Promise.all(
            fixtures.map((fixture) => runtimeProcessAlive(fixture)),
          )
        ).every((alive) => !alive));
      const starts = await Promise.all(
        fixtures.map((fixture) => runtimeStartCount(fixture)),
      );
      await connector.close();
      connector = startLocalStdioConnector(
        opts.bin,
        opts.root,
        opts.home,
        kimiSource,
      );
      await delay(1_500);
      for (let index = 0; index < fixtures.length; index++) {
        const current = await runtimeStartCount(fixtures[index]);
        if (current !== starts[index]) {
          throw new Error(
            `${fixtures[index].provider} restarted after a normal exit`,
          );
        }
      }
      const continuations = await Promise.all(
        fixtures.map((fixture) => recoveryContinuationCount(fixture)),
      );
      if (continuations.some((count) => count !== 0)) {
        throw new Error(
          `normal runtime exits triggered recovery continuation: ${
            fixtures.map((fixture, index) =>
              `${fixture.sessionID}=${continuations[index]}`
            ).join(", ")
          }`,
        );
      }
      return;
    }

    await assertStateDatabaseSecurity(opts.root);
    const codexFixtures = fixtures.filter(
      (fixture) => fixture.provider === "codex",
    );
    const codexFixture = codexFixtures[0];
    const codexBeforeListenFixture = codexFixtures[1];
    if (!codexFixture || !codexBeforeListenFixture) {
      throw new Error("missing Codex recovery fixtures");
    }
    const originalCodexThreadID = await recoveryThreadID(codexFixture);
    let codexThreadID = originalCodexThreadID;
    const recoveryFlows = connector.waitForRecoveryFlows(
      fixtures.map((fixture) => fixture.sessionID),
      40_000,
    );
    for (const fixture of fixtures) {
      const pid = Number((await Deno.readTextFile(fixture.pidPath)).trim());
      Deno.kill(pid, "SIGKILL");
    }
    await waitUntil(
      "native sessions recovered and agents continued",
      25_000,
      async () => {
        const resumed = await Promise.all(
          fixtures.map((fixture) => recoveryCount(fixture)),
        );
        const continued = await Promise.all(
          fixtures.map((fixture) => recoveryDecisionCount(fixture)),
        );
        return (
          resumed.every((count) => count > 0) &&
          continued.every((count) => count > 0)
        );
      },
    );
    await recoveryFlows;
    const recreatedCodexThreadID = await recoveryThreadID(codexFixture);
    if (recreatedCodexThreadID === codexThreadID) {
      throw new Error("missing Codex thread was not recreated and persisted");
    }
    codexThreadID = recreatedCodexThreadID;
    await delay(23_000);
    for (const fixture of fixtures) {
      const decisions = await recoveryDecisions(fixture);
      const expected = fixture === migratedFixture
        ? "continue,continue"
        : "continue";
      if (decisions.join(",") !== expected) {
        throw new Error(
          `${fixture.provider} repeated or skipped the accepted recovery decision: ${decisions}`,
        );
      }
    }

    await Deno.writeTextFile(codexFixture.statePath, "complete\n");
    await startCodexRetryFixtureTurn(
      connector,
      codexFixture.sessionID,
      codexFixture.command,
      4,
    );
    const runtimeStartsBeforeMissingThread = await runtimeStartCount(
      codexFixture,
    );
    const runtimePIDBeforeMissingThread = Number(
      (await Deno.readTextFile(codexFixture.pidPath)).trim(),
    );
    await Deno.writeTextFile(
      `${codexFixture.command}-missing-thread-on-read`,
      "armed\n",
    );
    const threadBeforeMissingRead = codexThreadID;
    await waitUntil(
      "missing Codex thread recreated on the existing app-server",
      15_000,
      async () => {
        codexThreadID = await recoveryThreadID(codexFixture);
        return (
          codexThreadID !== threadBeforeMissingRead &&
          (await recoveryDecisionCount(codexFixture)) === 2
        );
      },
    );
    if (
      (await runtimeStartCount(codexFixture)) !==
        runtimeStartsBeforeMissingThread
    ) {
      throw new Error("missing Codex thread restarted the app-server");
    }
    const runtimePIDAfterMissingThread = Number(
      (await Deno.readTextFile(codexFixture.pidPath)).trim(),
    );
    if (runtimePIDAfterMissingThread !== runtimePIDBeforeMissingThread) {
      throw new Error("missing Codex thread replaced the app-server process");
    }

    const threadBeforeMalformedRead = codexThreadID;
    await startCodexRetryFixtureTurn(
      connector,
      codexFixture.sessionID,
      codexFixture.command,
      5,
    );
    const startsBeforeMalformedRead = await runtimeStartCount(codexFixture);
    const decisionsBeforeMalformedRead = await recoveryDecisionCount(
      codexFixture,
    );
    const readsBeforeMalformedRead = await runtimeMethodCount(
      codexFixture,
      "thread/read",
    );
    const malformedReadMarker = `${codexFixture.command}-malformed-thread-read`;
    await Deno.writeTextFile(malformedReadMarker, "armed\n");
    await waitUntil(
      "malformed Codex thread/read consumed",
      12_000,
      async () => {
        try {
          await Deno.stat(malformedReadMarker);
          return false;
        } catch (error) {
          if (error instanceof Deno.errors.NotFound) return true;
          throw error;
        }
      },
    );
    await waitUntil(
      "Codex health check retried after malformed thread/read",
      12_000,
      async () =>
        (await runtimeMethodCount(codexFixture, "thread/read")) >
          readsBeforeMalformedRead + 1,
    );
    if (
      (await recoveryThreadID(codexFixture)) !== threadBeforeMalformedRead ||
      (await runtimeStartCount(codexFixture)) !== startsBeforeMalformedRead ||
      (await recoveryDecisionCount(codexFixture)) !==
        decisionsBeforeMalformedRead
    ) {
      throw new Error("malformed Codex thread/read changed runtime state");
    }

    const startsBeforeClosedTransport = await runtimeStartCount(codexFixture);
    const runtimePIDBeforeClosedTransport = Number(
      (await Deno.readTextFile(codexFixture.pidPath)).trim(),
    );
    const threadBeforeClosedTransport = codexThreadID;
    await Deno.writeTextFile(
      `${codexFixture.command}-close-thread-read`,
      "armed\n",
    );
    await waitUntil(
      "closed Codex transport recovered with a new app-server",
      15_000,
      async () => {
        codexThreadID = await recoveryThreadID(codexFixture);
        return (
          codexThreadID !== threadBeforeClosedTransport &&
          (await runtimeStartCount(codexFixture)) ===
            startsBeforeClosedTransport + 1 &&
          (await recoveryDecisionCount(codexFixture)) === 3
        );
      },
    );
    const runtimePIDAfterClosedTransport = Number(
      (await Deno.readTextFile(codexFixture.pidPath)).trim(),
    );
    if (runtimePIDAfterClosedTransport === runtimePIDBeforeClosedTransport) {
      throw new Error("closed Codex transport kept the unusable app-server");
    }
    await connector.waitForRuntimeEvent(
      (event) =>
        event.dispatch_id === `dispatch-${codexFixture.sessionID}-5` &&
        event.work_state === "settled",
      15_000,
    );

    const logBeforeServerInput = await Deno.readTextFile(codexFixture.logPath);
    const decisionsBeforeServerInput = await recoveryDecisionCount(
      codexFixture,
    );
    const inputsBeforeServerInput = await runtimeInputCount(codexFixture);
    await Deno.writeTextFile(codexFixture.statePath, "complete\n");
    Deno.kill(
      Number((await Deno.readTextFile(codexFixture.pidPath)).trim()),
      "SIGKILL",
    );
    const serverInputResult = await connector.request(
      `server-input-${codexFixture.sessionID}`,
      "agent_runtime_input",
      {
        kind: "external",
        provider: "codex",
        session_id: codexFixture.sessionID,
        dispatch_id: `server-input-${codexFixture.sessionID}`,
        runtime_capability_token: `capability-${codexFixture.sessionID}`,
        runtime_payload: { thread_id: originalCodexThreadID },
        runtime_config: { command: codexFixture.command },
        system_prompt: "local recovery e2e",
        input_messages: [
          {
            role: "user",
            content: "continue after the interrupted native process",
          },
        ],
      },
    );
    if (serverInputResult.accepted !== true) {
      throw new Error("Codex did not accept Server input after interruption");
    }
    await waitUntil(
      "Codex Server input recovered from connector-owned thread",
      25_000,
      async () =>
        (await runtimeInputCount(codexFixture)) > inputsBeforeServerInput,
    );
    const serverInputLog = (
      await Deno.readTextFile(codexFixture.logPath)
    ).slice(logBeforeServerInput.length);
    if (!serverInputLog.includes(`"threadId":"${codexThreadID}"`)) {
      throw new Error("Codex did not resume the connector-owned local thread");
    }
    if (serverInputLog.includes(`"threadId":"${originalCodexThreadID}"`)) {
      throw new Error("Codex used the stale Server thread id");
    }
    if (
      (await recoveryDecisionCount(codexFixture)) !== decisionsBeforeServerInput
    ) {
      throw new Error(
        "new Codex input was incorrectly prefixed with an interruption recovery instruction",
      );
    }
    codexThreadID = await recoveryThreadID(codexFixture);

    const offlineToolFixture = fixtures.find(
      (fixture) => fixture.provider === "pi",
    );
    if (!offlineToolFixture) throw new Error("missing offline tool fixture");
    await Deno.writeTextFile(
      `${offlineToolFixture.command}-crash-pending-message.trigger`,
      "armed\n",
    );
    const pendingResult = await connector.requestLeavingRuntimeProxyPending(
      `crash-pending-${offlineToolFixture.sessionID}`,
      "agent_runtime_input",
      {
        kind: "external",
        provider: "pi",
        session_id: offlineToolFixture.sessionID,
        dispatch_id: `dispatch-crash-pending-${offlineToolFixture.sessionID}`,
        runtime_capability_token: `capability-${offlineToolFixture.sessionID}`,
        runtime_payload: { session_id: "pi-native" },
        runtime_config: { command: offlineToolFixture.command },
        system_prompt: "local recovery e2e",
        input_messages: [
          {
            role: "user",
            content: "start a message send that remains pending across a crash",
          },
        ],
      },
    );
    if (pendingResult.accepted !== true) {
      throw new Error("Pi did not accept the pending-message input");
    }

    for (const fixture of fixtures) {
      if (fixture !== offlineToolFixture) {
        await startRuntimeFixtureTurn(connector, fixture, "before-restart");
      }
    }

    for (const fixture of fixtures) {
      await Deno.writeTextFile(fixture.statePath, "complete\n");
    }
    const beforeRestart = {
      resumed: await Promise.all(
        fixtures.map((fixture) => recoveryCount(fixture)),
      ),
      continued: await Promise.all(
        fixtures.map((fixture) => recoveryDecisionCount(fixture)),
      ),
    };

    const normallyStoppedPiFixtures = fixtures
      .filter(
        (fixture) =>
          fixture.provider === "pi" &&
          fixture !== offlineToolFixture &&
          fixture !== migratedFixture,
      )
      .slice(0, 4);
    if (normallyStoppedPiFixtures.length !== 4) {
      throw new Error("missing normally stopped Pi fixtures");
    }
    await Deno.writeTextFile(
      `${offlineToolFixture.command}-offline-tool.trigger`,
      "armed\n",
    );
    for (const fixture of normallyStoppedPiFixtures) {
      await Deno.writeTextFile(
        `${fixture.command}-offline-message.trigger`,
        "armed\n",
      );
    }
    await connector.crash();
    for (const fixture of fixtures) {
      const pid = Number((await Deno.readTextFile(fixture.pidPath)).trim());
      try {
        Deno.kill(pid, "SIGKILL");
      } catch (error) {
        if (!(error instanceof Deno.errors.NotFound)) throw error;
      }
    }
    const offlineEventFloor = Math.floor(Date.now() / 1_000);
    disconnectedConnector = startDisconnectedConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    await waitUntil(
      "connector restart recovered sessions and continued agents",
      8_000,
      async () => {
        const resumed = await Promise.all(
          fixtures.map((fixture) => recoveryCount(fixture)),
        );
        const continued = await Promise.all(
          fixtures.map((fixture) => recoveryDecisionCount(fixture)),
        );
        return (
          resumed.every(
            (count, index) =>
              fixtures[index].provider === "codex"
                ? count === beforeRestart.resumed[index]
                : count > beforeRestart.resumed[index],
          ) &&
          continued.every(
            (count, index) =>
              fixtures[index].provider === "codex"
                ? count === beforeRestart.continued[index]
                : count > beforeRestart.continued[index],
          )
        );
      },
    );
    await waitUntil(
      "offline tool returned locally",
      5_000,
      async () =>
        (await Deno.readTextFile(offlineToolFixture.logPath)).includes(
          "offline_tool ",
        ),
    );
    const offlineToolLog = await Deno.readTextFile(offlineToolFixture.logPath);
    assertIncludes(offlineToolLog, "offline_tool err=exit status 1");
    assertIncludes(offlineToolLog, '"code":"connector_offline"');
    assertIncludes(offlineToolLog, "tool gateway returned HTTP 503");
    const elapsed = /offline_tool .* elapsed_ms=(\d+)/.exec(offlineToolLog);
    if (!elapsed || Number(elapsed[1]) >= 3_000) {
      throw new Error(
        `offline tool did not fail immediately: ${offlineToolLog}`,
      );
    }
    await waitUntil(
      "stale offline-message sessions stopped normally",
      5_000,
      async () => {
        const logs = await Promise.all(
          normallyStoppedPiFixtures.map((fixture) =>
            Deno.readTextFile(fixture.logPath)
          ),
        );
        const alive = await Promise.all(
          normallyStoppedPiFixtures.map(runtimeProcessAlive),
        );
        return (
          logs.every((log) => log.includes("offline_message ")) &&
          alive.every((value) => !value)
        );
      },
    );
    // The recovery decision above emitted terminal lifecycle evidence.  Give
    // the local reader time to commit it, then prove killing the now-idle
    // native process does not promote its identity back into work.  The four
    // normally-stopped fixtures above retain the real offline-message/HTTP-503
    // coverage.
    await delay(2_000);
    const idleStarts = await runtimeStartCount(offlineToolFixture);
    await Deno.writeTextFile(
      `${offlineToolFixture.command}-offline-message.trigger`,
      "armed\n",
    );
    Deno.kill(
      Number((await Deno.readTextFile(offlineToolFixture.pidPath)).trim()),
      "SIGKILL",
    );
    await waitUntil(
      "idle Pi process exited",
      5_000,
      async () => !(await runtimeProcessAlive(offlineToolFixture)),
    );
    await delay(12_000);
    if ((await runtimeStartCount(offlineToolFixture)) !== idleStarts) {
      throw new Error("health check promoted an idle Pi identity");
    }
    const offlineMessageLog = await Deno.readTextFile(
      offlineToolFixture.logPath,
    );
    if (offlineMessageLog.includes("offline_message ")) {
      throw new Error("idle Pi identity consumed work without a real input");
    }
    if (
      migratedFixture &&
      (await legacyRecoveryFileExists(opts.root, migratedFixture.sessionID))
    ) {
      throw new Error("legacy recovery migration was not cleaned up");
    }
    for (const fixture of fixtures) {
      if (fixture.provider === "codex") continue;
      const decisions = await recoveryDecisions(fixture);
      const expected = fixture.sessionID === codexFixture.sessionID
        ? "continue,complete,complete,complete"
        : fixture === offlineToolFixture
        ? "continue,complete"
        : fixture === migratedFixture
        ? "continue,continue,complete"
        : "continue,complete";
      if (decisions.join(",") !== expected) {
        throw new Error(
          `${fixture.sessionID} did not decide from updated workspace state without a Server: ${decisions}`,
        );
      }
    }
    if (
      (await recoveryDecisionCount(codexFixture)) !==
        beforeRestart.continued[fixtures.indexOf(codexFixture)]
    ) {
      throw new Error("offline Codex executed before subscription admission");
    }

    const shutdownEventFloor = Math.floor(Date.now() / 1_000);
    await stopDisconnectedConnector(disconnectedConnector);
    disconnectedConnector = undefined;
    const offlineEventCeiling = Math.floor(Date.now() / 1_000);
    await delay(1_100);
    connector = startLocalStdioConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    await connector.waitForRuntimeEventsAfterReconnect(
      offlineEventFloor,
      offlineEventCeiling,
      fixtures.filter((fixture) => fixture.provider !== "codex").map((
        fixture,
      ) => fixture.sessionID),
      fixtures
        .filter(
          (fixture) =>
            fixture.provider !== "codex" &&
            fixture !== offlineToolFixture &&
            !normallyStoppedPiFixtures.includes(fixture),
        )
        .map((fixture) => fixture.sessionID),
      shutdownEventFloor,
      45_000,
    );

    await waitUntil(
      "Codex recovered after subscription admission returned",
      25_000,
      async () =>
        (await recoveryDecisions(codexFixture)).join(",") ===
          "continue,complete,complete,complete",
    );
    if ((await recoveryThreadID(codexFixture)) === codexThreadID) {
      throw new Error(
        "reconnected recovery did not persist the recreated Codex thread",
      );
    }

    const beforeListenThreadID = await recoveryThreadID(
      codexBeforeListenFixture,
    );
    const beforeListenMarker =
      `${codexBeforeListenFixture.command}-normal-exit-before-listen`;
    const beforeListenBridgeURL = `${beforeListenMarker}.bridge-url`;
    const beforeListenLifecycleGate =
      `${codexBeforeListenFixture.command}-lifecycle-gate`;
    await Deno.remove(beforeListenBridgeURL).catch(() => {});
    await Deno.remove(beforeListenLifecycleGate);
    await startRuntimeFixtureTurn(
      connector,
      codexBeforeListenFixture,
      "before-pre-listen-normal-exit",
    );
    const interruptedPID = Number(
      (await Deno.readTextFile(codexBeforeListenFixture.pidPath)).trim(),
    );
    await connector.crash();
    try {
      Deno.kill(interruptedPID, "SIGKILL");
    } catch (error) {
      if (!(error instanceof Deno.errors.NotFound)) throw error;
    }
    await waitUntil(
      "interrupted Codex app-server exited before pre-listen restore",
      5_000,
      async () => !(await runtimeProcessAlive(codexBeforeListenFixture)),
    );
    const startsBeforePreListenExit = await runtimeStartCount(
      codexBeforeListenFixture,
    );
    await Deno.writeTextFile(beforeListenMarker, "armed\n");
    disconnectedConnector = startDisconnectedConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );
    await waitUntil(
      "restored Codex normal exit before app-server listen",
      15_000,
      async () =>
        (await runtimeStartCount(codexBeforeListenFixture)) ===
          startsBeforePreListenExit + 1,
    );
    await delay(12_000);
    if (
      (await runtimeStartCount(codexBeforeListenFixture)) !==
        startsBeforePreListenExit + 1
    ) {
      throw new Error("pre-listen normal exit restarted the Codex app-server");
    }
    const bridgeURL = (await Deno.readTextFile(beforeListenBridgeURL)).trim();
    const stoppedRouteResponse = await fetch(
      `${bridgeURL}/runtime/${encodeURIComponent(beforeListenThreadID)}/tools`,
    );
    const stoppedRouteBody = await stoppedRouteResponse.text();
    if (
      stoppedRouteResponse.status !== 404 ||
      !stoppedRouteBody.includes("not associated")
    ) {
      throw new Error(
        `normally stopped Codex route remained available: ${stoppedRouteResponse.status}`,
      );
    }

    await stopDisconnectedConnector(disconnectedConnector);
    disconnectedConnector = undefined;
    await delay(1_100);
    connector = startLocalStdioConnector(
      opts.bin,
      opts.root,
      opts.home,
      kimiSource,
    );

    await startRuntimeFixtureTurn(
      connector,
      codexFixture,
      "before-thread-start-response-normal-exit",
    );
    await Deno.writeTextFile(
      `${codexFixture.command}-normal-exit-before-thread-start-response`,
      "armed\n",
    );
    const startsBeforeNormalExit = await runtimeMethodCount(
      codexFixture,
      "thread/start",
    );
    Deno.kill(
      Number((await Deno.readTextFile(codexFixture.pidPath)).trim()),
      "SIGKILL",
    );
    await waitUntil(
      "normal Codex exit before replacement thread bind",
      15_000,
      async () =>
        (await runtimeMethodCount(codexFixture, "thread/start")) ===
          startsBeforeNormalExit + 1,
    );
    await delay(12_000);
    if (
      (await runtimeMethodCount(codexFixture, "thread/start")) !==
        startsBeforeNormalExit + 1
    ) {
      throw new Error("normally stopped Codex session was recovered again");
    }
    const normallyStoppedMessageFixture = normallyStoppedPiFixtures[0];
    const normallyStoppedLog = await Deno.readTextFile(
      normallyStoppedMessageFixture.logPath,
    );
    const resumed = await connector.request(
      `resume-${normallyStoppedMessageFixture.sessionID}`,
      "agent_runtime_input",
      {
        kind: "external",
        provider: "pi",
        session_id: normallyStoppedMessageFixture.sessionID,
        dispatch_id:
          `dispatch-resume-${normallyStoppedMessageFixture.sessionID}`,
        runtime_capability_token:
          `capability-${normallyStoppedMessageFixture.sessionID}`,
        runtime_payload: { session_id: "pi-native" },
        runtime_config: { command: normallyStoppedMessageFixture.command },
        system_prompt: "local recovery e2e",
        input_messages: [
          {
            role: "user",
            content: "resume the normally stopped session",
          },
        ],
      },
    );
    if (resumed.accepted !== true) {
      throw new Error("normally stopped Pi session did not accept new input");
    }
    await delay(2_000);
    for (
      const [label, log] of [
        [
          "normally stopped session",
          (await Deno.readTextFile(normallyStoppedMessageFixture.logPath))
            .slice(
              normallyStoppedLog.length,
            ),
        ],
        [
          "recovered session",
          await Deno.readTextFile(offlineToolFixture.logPath),
        ],
      ] as const
    ) {
      if (log.includes("Connector connectivity notice")) {
        throw new Error(
          `${label} converted a failed tool call into a native reminder`,
        );
      }
    }
    const lostResponseDispatchID =
      "dispatch-retry-runtime-event-after-lost-response";
    await Deno.writeTextFile(
      `${offlineToolFixture.command}-event-retry.trigger`,
      "armed\n",
    );
    const retriedAfterLostResponse = await connector
      .requestWithDroppedRuntimeEventResponse(
        "retry-runtime-event-after-lost-response",
        "agent_runtime_input",
        {
          kind: "external",
          provider: offlineToolFixture.provider,
          session_id: offlineToolFixture.sessionID,
          dispatch_id: lostResponseDispatchID,
          runtime_capability_token:
            `capability-${offlineToolFixture.sessionID}`,
          runtime_payload: { session_id: "pi-native" },
          runtime_config: { command: offlineToolFixture.command },
          system_prompt: "local recovery e2e",
          input_messages: [
            {
              role: "user",
              content: "produce a runtime event whose first response is lost",
            },
          ],
        },
        lostResponseDispatchID,
      );
    if (retriedAfterLostResponse.accepted !== true) {
      throw new Error(
        "connector rejected the lost-response event retry verification input",
      );
    }
    await delay(1_000);
    if (
      (await runtimeMethodCount(codexFixture, "thread/start")) !==
        startsBeforeNormalExit + 1
    ) {
      throw new Error("connector restart resurrected normally stopped Codex");
    }
  } finally {
    await connector.close().catch(() => {});
    if (disconnectedConnector) {
      await stopDisconnectedConnector(disconnectedConnector).catch(() => {});
    }
  }
}

async function assertUnsafeRecoveryFileRejected(
  bin: string,
  root: string,
  home: string,
) {
  const dir = `${root}/external-runtime/active`;
  await Deno.mkdir(dir, { recursive: true, mode: 0o700 });
  await Deno.mkdir(home, { recursive: true });
  await Deno.writeTextFile(`${dir}/unsafe.json`, "{}", { mode: 0o644 });
  await Deno.chmod(`${dir}/unsafe.json`, 0o644);
  const output = await run(
    bin,
    ["--stdio", "--root", root, "--system-info-interval", "0"],
    {
      allowFailure: true,
      env: {
        ...Deno.env.toObject(),
        HOME: home,
        PATH: "/usr/bin:/bin",
      },
    },
  );
  if (output.success || !output.combined.includes("private regular file")) {
    throw new Error(`unsafe recovery file was accepted\n${output.combined}`);
  }
}

async function startRuntimeFixtureTurn(
  connector: StdioConnectorClient,
  fixture: LocalRuntimeFixture,
  suffix: string,
) {
  const before = await runtimeInputCount(fixture);
  const result = await connector.request(
    `active-${fixture.sessionID}-${suffix}`,
    "agent_runtime_input",
    {
      kind: "external",
      provider: fixture.provider,
      session_id: fixture.sessionID,
      dispatch_id: `dispatch-${fixture.sessionID}-${suffix}`,
      runtime_capability_token: `capability-${fixture.sessionID}`,
      runtime_config: { command: fixture.command },
      system_prompt: "local recovery e2e",
      input_messages: [{ role: "user", content: `active ${suffix}` }],
    },
  );
  if (result.accepted !== true) {
    throw new Error(`${fixture.provider} did not accept active ${suffix} turn`);
  }
  await waitUntil(
    `${fixture.sessionID} accepted active ${suffix} turn`,
    15_000,
    async () => (await runtimeInputCount(fixture)) > before,
  );
}

async function createLocalRuntimeFixtures(opts: LocalRecoveryOptions) {
  const piDefinition = {
    provider: "pi" as const,
    helper: "TestHelperPiRPC",
    fakeFlag: "SALIX_TEST_FAKE_PI",
    logFlag: "SALIX_TEST_FAKE_PI_LOG",
    exitFlag: "SALIX_TEST_FAKE_PI_EXIT_AFTER_PROMPT",
    recoveryMarker: "--session pi-native",
    startMarker: (line: string) => line.startsWith("start --mode rpc"),
  };
  const codexDefinition = {
    provider: "codex" as const,
    helper: "TestHelperCodexAppServer",
    fakeFlag: "SALIX_TEST_FAKE_CODEX",
    logFlag: "SALIX_TEST_FAKE_CODEX_LOG",
    exitFlag: "SALIX_TEST_FAKE_CODEX_EXIT_AFTER_TURN",
    recoveryMarker: "thread/resume",
    startMarker: (line: string) => line === "start",
  };
  const definitions = [
    codexDefinition,
    piDefinition,
    {
      provider: "kimi" as const,
      helper: "TestHelperKimiServer",
      fakeFlag: "SALIX_TEST_FAKE_KIMI",
      logFlag: "SALIX_TEST_FAKE_KIMI_LOG",
      exitFlag: "SALIX_TEST_FAKE_KIMI_EXIT_AFTER_PROMPT",
      recoveryMarker: "GET /api/v1/sessions/kimi-native",
      startMarker: (line: string) => line.startsWith("start server run"),
    },
    ...(!opts.exitNormally
      ? Array.from({ length: 6 }, () => piDefinition)
      : []),
    ...(!opts.exitNormally ? [codexDefinition] : []),
  ];
  const fixtures: LocalRuntimeFixture[] = [];
  for (const [index, definition] of definitions.entries()) {
    const key = `${definition.provider}-${index}`;
    const command = `${opts.fakeBin}/${key}`;
    const logPath = `${opts.fakeBin}/${key}.log`;
    const pidPath = `${opts.fakeBin}/${key}.pid`;
    const workspace = `${opts.home}/.comma/workspaces/session-${key}`;
    const statePath = `${workspace}/recovery-state`;
    const decisionPath = `${workspace}/recovery-decisions.log`;
    await Deno.mkdir(workspace, { recursive: true });
    await Deno.writeTextFile(statePath, "continue\n");
    const environment = [
      `export ${definition.fakeFlag}=1`,
      `export ${definition.logFlag}=${shellQuote(logPath)}`,
      `export SALIX_TEST_FAKE_RECOVERY_STATE_PATH=${shellQuote(statePath)}`,
      `export SALIX_TEST_FAKE_RECOVERY_DECISION_PATH=${
        shellQuote(
          decisionPath,
        )
      }`,
      `printf '%s\\n' "$$" > ${shellQuote(pidPath)}`,
    ];
    if (definition.provider === "codex" && !opts.exitNormally) {
      environment.push(
        "export SALIX_TEST_FAKE_CODEX_MISSING_THREAD_ON_RESUME=1",
        "export SALIX_TEST_FAKE_EXPECT_RECREATED_THREAD=1",
        `export SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_BEFORE_THREAD_START_RESPONSE_ONCE=${
          shellQuote(
            `${command}-normal-exit-before-thread-start-response`,
          )
        }`,
        `export SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_BEFORE_LISTEN_ONCE=${
          shellQuote(
            `${command}-normal-exit-before-listen`,
          )
        }`,
        `export SALIX_TEST_FAKE_CODEX_MISSING_THREAD_ON_READ_ONCE=${
          shellQuote(
            `${command}-missing-thread-on-read`,
          )
        }`,
        `export SALIX_TEST_FAKE_CODEX_MALFORMED_THREAD_READ_ONCE=${
          shellQuote(
            `${command}-malformed-thread-read`,
          )
        }`,
        `export SALIX_TEST_FAKE_CODEX_CLOSE_THREAD_READ_ONCE=${
          shellQuote(
            `${command}-close-thread-read`,
          )
        }`,
        `export SALIX_TEST_FAKE_CODEX_DROP_RECOVERY_RESPONSE_ONCE=${
          shellQuote(
            `${command}-recovery-response-dropped`,
          )
        }`,
      );
    }
    if (
      !opts.exitNormally &&
      definition === codexDefinition &&
      index === definitions.length - 1
    ) {
      const lifecycleGate = `${command}-lifecycle-gate`;
      environment.push(
        `export SALIX_TEST_FAKE_RUNTIME_LIFECYCLE_GATE=${
          shellQuote(
            lifecycleGate,
          )
        }`,
      );
      await Deno.writeTextFile(lifecycleGate, "open\n");
    }
    if (!opts.exitNormally && key === "pi-1") {
      environment.push(
        `export SALIX_TEST_FAKE_OFFLINE_TOOL_TRIGGER=${
          shellQuote(
            `${command}-offline-tool.trigger`,
          )
        }`,
        `export SALIX_TEST_FAKE_OFFLINE_MESSAGE_TRIGGER=${
          shellQuote(
            `${command}-offline-message.trigger`,
          )
        }`,
        `export SALIX_TEST_FAKE_CRASH_PENDING_MESSAGE_TRIGGER=${
          shellQuote(
            `${command}-crash-pending-message.trigger`,
          )
        }`,
        `export SALIX_TEST_FAKE_PI_FIRST_PROMPT_LIFECYCLE_MARKER=${
          shellQuote(
            `${command}-event-retry.trigger`,
          )
        }`,
        "export SALIX_TEST_FAKE_PI_FIRST_PROMPT_LIFECYCLE=running",
      );
    }
    if (!opts.exitNormally && ["pi-4", "pi-5", "pi-6", "pi-7"].includes(key)) {
      environment.push(
        `export SALIX_TEST_FAKE_OFFLINE_MESSAGE_TRIGGER=${
          shellQuote(
            `${command}-offline-message.trigger`,
          )
        }`,
        "export SALIX_TEST_FAKE_OFFLINE_MESSAGE_EXIT_AFTER=1",
      );
    }
    if (opts.exitNormally) {
      environment.push(`export ${definition.exitFlag}=1`);
    }
    await writeFakeRuntime(
      command,
      `${definition.provider} fake`,
      environment,
      opts.helper,
      definition.helper,
    );
    fixtures.push({
      provider: definition.provider,
      sessionID: `session-${key}`,
      command,
      logPath,
      pidPath,
      statePath,
      decisionPath,
      recoveryMarker: definition.recoveryMarker,
      startMarker: definition.startMarker,
    });
  }
  return fixtures;
}

function startLocalStdioConnector(
  bin: string,
  root: string,
  home: string,
  kimiSource: string,
) {
  const child = new Deno.Command(bin, {
    args: ["--stdio", "--root", root, "--system-info-interval", "0"],
    env: {
      ...Deno.env.toObject(),
      HOME: home,
      KIMI_CODE_HOME: kimiSource,
      PATH: "/usr/bin:/bin",
    },
    stdin: "piped",
    stdout: "piped",
    stderr: "inherit",
  }).spawn();
  return new StdioConnectorClient(child);
}

function startLocalStdioConnectorWithoutHome(
  bin: string,
  root: string,
  kimiSource: string,
) {
  const child = new Deno.Command(bin, {
    args: ["--stdio", "--root", root, "--system-info-interval", "0"],
    clearEnv: true,
    env: {
      KIMI_CODE_HOME: kimiSource,
      PATH: "/usr/bin:/bin",
    },
    stdin: "piped",
    stdout: "piped",
    stderr: "inherit",
  }).spawn();
  return new StdioConnectorClient(child);
}

function startDisconnectedConnector(
  bin: string,
  root: string,
  home: string,
  kimiSource: string,
) {
  const unavailable = reservePort();
  unavailable.release();
  return new Deno.Command(bin, {
    args: [
      "--root",
      root,
      "--server",
      `ws://127.0.0.1:${unavailable.port}`,
      "--connector-token",
      "offline-recovery-test",
      "--system-info-interval",
      "0",
    ],
    env: {
      ...Deno.env.toObject(),
      HOME: home,
      KIMI_CODE_HOME: kimiSource,
      PATH: "/usr/bin:/bin",
    },
    stdin: "null",
    stdout: "null",
    stderr: "null",
  }).spawn();
}

async function stopDisconnectedConnector(child: Deno.ChildProcess) {
  try {
    child.kill("SIGTERM");
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  try {
    await withTimeout(child.status, 10_000, "disconnected connector exit");
  } catch (error) {
    try {
      child.kill("SIGKILL");
    } catch {
      // Already exited.
    }
    await child.status.catch(() => {});
    throw error;
  }
}

class StdioConnectorClient {
  #writer: WritableStreamDefaultWriter<Uint8Array>;
  #lines: AsyncIterator<string>;
  #seenRuntimeEventRequestIDs = new Set<string>();
  #seenRuntimeEventMessages = new WeakSet<Record<string, unknown>>();
  #closed = false;

  constructor(private child: Deno.ChildProcess) {
    this.#writer = child.stdin.getWriter();
    this.#lines = this.readUnboundSubscriptionRequests(child.stdout);
  }

  // These local fixtures use provider-native fake accounts, not a Server
  // subscription binding. Answer the scoped lookup instead of letting it
  // time out while the test waits for the resulting runtime event.
  private readUnboundSubscriptionRequests(stream: ReadableStream<Uint8Array>) {
    // Read continuously: callers can wait for provider log evidence without
    // issuing another Connector request while the native call needs this reply.
    return new ReadableStream<string>({
      start: async (controller) => {
        try {
          for await (const line of textLines(stream)) {
            let message: Record<string, unknown>;
            try {
              message = JSON.parse(line);
            } catch {
              controller.enqueue(line);
              continue;
            }
            if (
              message.type === "request" &&
              message.method === "runtime_subscription_access"
            ) {
              await this.#writer.write(new TextEncoder().encode(
                JSON.stringify({
                  id: message.id,
                  type: "response",
                  result: { bound: false },
                }) + "\n",
              ));
            } else {
              controller.enqueue(line);
            }
          }
          controller.close();
        } catch (error) {
          controller.error(error);
        }
      },
    }).values();
  }

  async request(id: string, method: string, params: Record<string, unknown>) {
    await this.#writer.write(
      new TextEncoder().encode(
        JSON.stringify({ id, type: "request", method, params }) + "\n",
      ),
    );
    while (true) {
      const next = await withTimeout(
        this.#lines.next(),
        30_000,
        `stdio response ${id}`,
      );
      if (next.done) throw new Error(`connector closed before response ${id}`);
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(next.value);
      } catch {
        continue;
      }
      if (await this.acknowledgeRuntimeEvent(message)) continue;
      if (message.id !== id) continue;
      if (message.type === "error") {
        throw new Error(`connector request ${id} failed: ${message.error}`);
      }
      if (message.type === "response") {
        return (message.result ?? {}) as Record<string, unknown>;
      }
    }
  }

  async requestAndWaitForRuntimeEvent(
    id: string,
    method: string,
    params: Record<string, unknown>,
    predicate: (event: DurableRuntimeEvent) => boolean,
    settlement: "accepted" | "permanent" = "accepted",
  ) {
    await this.#writer.write(
      new TextEncoder().encode(
        JSON.stringify({ id, type: "request", method, params }) + "\n",
      ),
    );
    let result: Record<string, unknown> | undefined;
    let matched: DurableRuntimeEventDelivery | undefined;
    while (!result || !matched) {
      const next = await withTimeout(
        this.#lines.next(),
        30_000,
        `stdio response and runtime event ${id}`,
      );
      if (next.done) throw new Error(`connector closed before response ${id}`);
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(next.value);
      } catch {
        continue;
      }
      const delivery = runtimeEventDelivery(message);
      if (delivery) {
        const matching = delivery.events.filter(predicate);
        await this.acknowledgeRuntimeEvent(
          message,
          settlement === "permanent"
            ? delivery.events
              .filter((event) => !matching.includes(event))
              .map((event) => event.id)
            : undefined,
          settlement === "permanent" ? matching.map((event) => event.id) : [],
        );
        if (matching.length > 0) matched = delivery;
        continue;
      }
      if (message.id !== id) continue;
      if (message.type === "error") {
        throw new Error(`connector request ${id} failed: ${message.error}`);
      }
      if (message.type === "response") {
        result = (message.result ?? {}) as Record<string, unknown>;
      }
    }
    return matched;
  }

  async requireHealthyRuntimeEventBehindRetryingSession(timeoutMs: number) {
    const deadline = Date.now() + timeoutMs;
    let retryingAttempts = 0;
    let retryingPrefixIDs: Set<string> | undefined;
    const healthyStates = new Set<string>();
    while (Date.now() < deadline) {
      const next = await withTimeout(
        this.#lines.next(),
        Math.max(1, deadline - Date.now()),
        "healthy runtime event behind retrying session",
      );
      if (next.done) {
        throw new Error("connector closed before the healthy runtime event");
      }
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(next.value);
      } catch {
        continue;
      }
      const delivery = runtimeEventDelivery(message);
      if (!delivery) continue;
      const healthy = delivery.events.filter((event) =>
        event.params.capability_token === "capability-healthy-session"
      );
      if (healthy.length > 0) {
        if (healthy.length !== delivery.events.length) {
          throw new Error(
            "a later event overtook an earlier retry from the same runtime session",
          );
        }
        for (const event of healthy) {
          healthyStates.add(String(event.event.state ?? ""));
        }
        await this.acknowledgeRuntimeEvent(message);
        if (healthyStates.has("healthy") && healthyStates.has("healthy-tail")) {
          return;
        }
        continue;
      }
      if (
        delivery.events.some((event) =>
          event.params.capability_token !== "capability-retrying-session"
        )
      ) {
        throw new Error(
          "runtime retry fairness fixture mixed an unknown session",
        );
      }
      if (!retryingPrefixIDs) {
        retryingPrefixIDs = new Set(delivery.events.map((event) => event.id));
      } else if (
        delivery.events.some((event) => !retryingPrefixIDs?.has(event.id))
      ) {
        throw new Error(
          "a later event overtook an earlier retry from the same runtime session",
        );
      }
      retryingAttempts++;
      await delay(Math.min(6_000, Math.max(1, deadline - Date.now())));
      if (Date.now() >= deadline) break;
      await this.acknowledgeRuntimeEvent(message, []);
    }
    throw new Error(
      `a retrying runtime session starved a later healthy session across ${retryingAttempts} attempts`,
    );
  }

  async requestWithDroppedRuntimeEventResponse(
    id: string,
    method: string,
    params: Record<string, unknown>,
    expectedDispatchID: string,
  ) {
    await this.#writer.write(
      new TextEncoder().encode(
        JSON.stringify({ id, type: "request", method, params }) + "\n",
      ),
    );
    let result: Record<string, unknown> | undefined;
    let droppedID = "";
    let droppedAt = 0;
    let retried = false;
    const firstEventDeadline = Date.now() + 20_000;
    while (!result || !retried) {
      const deadline = droppedAt === 0 ? firstEventDeadline : droppedAt + 6_500;
      const next = await withTimeout(
        this.#lines.next(),
        Math.max(1, deadline - Date.now()),
        `stdio lost-response event retry ${id}`,
      );
      if (next.done) {
        throw new Error(
          `connector closed before lost-response event retry ${id}`,
        );
      }
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(next.value);
      } catch {
        continue;
      }
      const delivery = runtimeEventDelivery(message);
      if (delivery) {
        this.observeRuntimeEventRequest(message, delivery);
        const matchingEvent = delivery.events.find(
          (event) => event.dispatchID === expectedDispatchID,
        );
        if (droppedID === "" && matchingEvent) {
          droppedID = matchingEvent.id;
          droppedAt = Date.now();
          continue;
        }
        await this.acknowledgeRuntimeEvent(message);
        if (delivery.events.some((event) => event.id === droppedID)) {
          retried = true;
        }
        continue;
      }
      if (message.id !== id) continue;
      if (message.type === "error") {
        throw new Error(`connector request ${id} failed: ${message.error}`);
      }
      if (message.type === "response") {
        result = (message.result ?? {}) as Record<string, unknown>;
      }
    }
    return result;
  }

  async requestLeavingRuntimeProxyPending(
    id: string,
    method: string,
    params: Record<string, unknown>,
  ) {
    await this.#writer.write(
      new TextEncoder().encode(
        JSON.stringify({ id, type: "request", method, params }) + "\n",
      ),
    );
    let result: Record<string, unknown> | undefined;
    let sawProxy = false;
    while (!result || !sawProxy) {
      const next = await withTimeout(
        this.#lines.next(),
        30_000,
        `stdio response and pending runtime proxy ${id}`,
      );
      if (next.done) throw new Error(`connector closed before response ${id}`);
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(next.value);
      } catch {
        continue;
      }
      if (await this.acknowledgeRuntimeEvent(message)) continue;
      if (message.method === "runtime_proxy") {
        sawProxy = true;
        continue;
      }
      if (message.id !== id) continue;
      if (message.type === "error") {
        throw new Error(`connector request ${id} failed: ${message.error}`);
      }
      if (message.type === "response") {
        result = (message.result ?? {}) as Record<string, unknown>;
      }
    }
    return result;
  }

  async waitForRecoveryFlows(sessionIDs: string[], timeoutMs: number) {
    const expected = new Set(sessionIDs);
    const recovered = new Set<string>();
    const worked = new Set<string>();
    let deadline = Date.now() + timeoutMs;
    while (recovered.size < expected.size || worked.size < expected.size) {
      let next: IteratorResult<string>;
      try {
        next = await withTimeout(
          this.#lines.next(),
          Math.max(1, deadline - Date.now()),
          "runtime recovery events",
        );
      } catch (error) {
        const missingRecovered = [...expected].filter(
          (sessionID) => !recovered.has(sessionID),
        );
        const missingWork = [...expected].filter(
          (sessionID) => !worked.has(sessionID),
        );
        throw new Error(
          `runtime recovery events stalled; missing recovered=[${
            missingRecovered.join(
              ",",
            )
          }] work=[${missingWork.join(",")}]`,
          { cause: error },
        );
      }
      if (next.done) throw new Error("connector closed before recovery events");
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(next.value);
      } catch {
        continue;
      }
      const delivery = runtimeEventDelivery(message);
      if (!delivery) continue;
      await this.acknowledgeRuntimeEvent(message);
      const progressBefore = recovered.size + worked.size;
      for (const item of delivery.events) {
        const token = String(item.params.capability_token ?? "");
        const sessionID = token.replace(/^capability-/, "");
        if (!expected.has(sessionID)) continue;
        const event = item.event;
        if (event.name === "runtime_recovered") {
          recovered.add(sessionID);
        } else if (event.type === "operation") {
          worked.add(sessionID);
        }
      }
      if (recovered.size + worked.size > progressBefore) {
        deadline = Date.now() + timeoutMs;
      }
    }
  }

  async waitForRuntimeEventsAfterReconnect(
    offlineFloor: number,
    offlineCeiling: number,
    offlineRecoverySessionIDs: string[],
    shutdownSessionIDs: string[],
    shutdownFloor: number,
    timeoutMs: number,
  ) {
    const missingRecoveries = new Set(offlineRecoverySessionIDs);
    const missingShutdown = new Set(shutdownSessionIDs);
    let rejectedID = "";
    let retried = false;
    const acceptedBeforeRetry = new Set<string>();
    const deadline = Date.now() + timeoutMs;
    while (missingRecoveries.size > 0 || missingShutdown.size > 0 || !retried) {
      let next: IteratorResult<string>;
      try {
        next = await withTimeout(
          this.#lines.next(),
          Math.max(1, deadline - Date.now()),
          "offline durable runtime events",
        );
      } catch (error) {
        throw new Error(
          `connector restart missed recovery events for ${
            [
              ...missingRecoveries,
            ].join(
              ",",
            )
          } or shutdown-tail events for ${[...missingShutdown].join(",")}`,
          { cause: error },
        );
      }
      if (next.done) throw new Error("connector closed before durable event");
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(next.value);
      } catch {
        continue;
      }
      if (message.method === "runtime_proxy") {
        throw new Error("offline tool call was replayed after reconnect");
      }
      const delivery = runtimeEventDelivery(message);
      if (!delivery) continue;
      if (delivery.legacy) {
        throw new Error(
          "offline durable runtime events were sent one request per event instead of a bounded batch",
        );
      }
      if (rejectedID === "") {
        if (delivery.events.length < 2) {
          throw new Error(
            `offline durable runtime event batch contained only ${delivery.events.length} event`,
          );
        }
        rejectedID = delivery.events[0].id;
        for (const item of delivery.events.slice(1)) {
          acceptedBeforeRetry.add(item.id);
        }
        await this.acknowledgeRuntimeEvent(
          message,
          delivery.events.slice(1).map((event) => event.id),
        );
      } else {
        for (const item of delivery.events) {
          if (acceptedBeforeRetry.has(item.id)) {
            throw new Error(
              `partially acknowledged runtime event was redelivered: ${item.id}`,
            );
          }
          if (item.id === rejectedID) retried = true;
        }
        await this.acknowledgeRuntimeEvent(message);
      }
      for (const item of delivery.events) {
        if (item.id === rejectedID && !retried) continue;
        const event = item.event;
        const sessionID = String(item.params.capability_token ?? "").replace(
          /^capability-/,
          "",
        );
        if (
          item.createdAt >= offlineFloor &&
          item.createdAt <= offlineCeiling &&
          event.name === "runtime_recovered"
        ) {
          missingRecoveries.delete(sessionID);
        }
        if (
          item.createdAt >= shutdownFloor &&
          item.createdAt <= offlineCeiling &&
          (sessionID.startsWith("session-pi-")
            ? event.type === "status" && event.name === "runtime_stopped" &&
              event.state === "stopped" && event.work_state === undefined &&
              event.issue === undefined
            : event.type === "error" &&
              String(event.message ?? "").includes("exited"))
        ) {
          missingShutdown.delete(sessionID);
        }
      }
    }
  }

  async waitForRuntimeEvent(
    predicate: (event: Record<string, unknown>) => boolean,
    timeoutMs: number,
  ) {
    return (await this.waitForRuntimeEventDelivery(predicate, timeoutMs)).event;
  }

  async waitForRuntimeEventDelivery(
    predicate: (event: Record<string, unknown>) => boolean,
    timeoutMs: number,
    acknowledge = true,
    rejectUnmatched = false,
  ) {
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const next = await withTimeout(
        this.#lines.next(),
        Math.max(1, deadline - Date.now()),
        "runtime event",
      );
      if (next.done) throw new Error("connector closed before runtime event");
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(next.value);
      } catch {
        continue;
      }
      const delivery = runtimeEventDelivery(message);
      if (!delivery) continue;
      const event = delivery.events.map((item) => item.event).find(predicate);
      if (event) {
        if (acknowledge) await this.acknowledgeRuntimeEvent(message);
        return { delivery, event };
      }
      if (rejectUnmatched) {
        throw new Error(
          `permanently invalid legacy runtime event survived migration: ${message.id}`,
        );
      }
      await this.acknowledgeRuntimeEvent(message);
    }
  }

  private async acknowledgeRuntimeEvent(
    message: Record<string, unknown>,
    acceptedEventIDs?: string[],
    permanentlyRejectedEventIDs: string[] = [],
  ): Promise<boolean> {
    const delivery = runtimeEventDelivery(message);
    if (!delivery) return false;
    this.observeRuntimeEventRequest(message, delivery);
    const accepted = acceptedEventIDs ??
      delivery.events.map((event) => event.id);
    const result = delivery.legacy
      ? { ok: accepted.includes(delivery.events[0].id) }
      : {
        accepted_event_ids: accepted,
        permanently_rejected_events: permanentlyRejectedEventIDs.map(
          (eventID) => ({
            event_id: eventID,
            error_code: "stale_external_session",
          }),
        ),
      };
    await this.#writer.write(
      new TextEncoder().encode(
        JSON.stringify({
          id: delivery.requestID,
          type: "response",
          result,
        }) + "\n",
      ),
    );
    return true;
  }

  private observeRuntimeEventRequest(
    message: Record<string, unknown>,
    delivery: DurableRuntimeEventDelivery,
  ) {
    if (this.#seenRuntimeEventMessages.has(message)) return;
    this.#seenRuntimeEventMessages.add(message);
    if (
      !delivery.legacy &&
      this.#seenRuntimeEventRequestIDs.has(delivery.requestID)
    ) {
      throw new Error(
        `external runtime event delivery reused request id ${delivery.requestID}`,
      );
    }
    if (!delivery.legacy) {
      this.#seenRuntimeEventRequestIDs.add(delivery.requestID);
    }
  }

  async close() {
    if (this.#closed) return;
    this.#closed = true;
    await this.#writer.close().catch(() => {});
    let status: Deno.CommandStatus;
    try {
      status = await withTimeout(this.child.status, 10_000, "connector exit");
    } catch (error) {
      try {
        this.child.kill("SIGKILL");
      } catch {
        // Already exited.
      }
      await this.child.status.catch(() => {});
      throw error;
    }
    if (!status.success) {
      throw new Error(`connector exited with code ${status.code}`);
    }
  }

  async crash() {
    if (this.#closed) return;
    this.#closed = true;
    this.child.kill("SIGKILL");
    await this.#writer.abort("simulated host restart").catch(() => {});
    await withTimeout(this.child.status, 10_000, "connector crash");
  }
}

type DurableRuntimeEvent = {
  id: string;
  createdAt: number;
  dispatchID: string;
  params: Record<string, unknown>;
  event: Record<string, unknown>;
};

type DurableRuntimeEventDelivery = {
  requestID: string;
  legacy: boolean;
  events: DurableRuntimeEvent[];
};

function runtimeEventDelivery(
  message: Record<string, unknown>,
): DurableRuntimeEventDelivery | undefined {
  if (
    message.method !== "external_runtime_event" &&
    message.method !== "external_runtime_events"
  ) {
    return undefined;
  }
  const requestID = String(message.id ?? "");
  const outer = (message.params ?? {}) as Record<string, unknown>;
  const paramsList = message.method === "external_runtime_event"
    ? [outer]
    : Array.isArray(outer.events)
    ? (outer.events as Record<string, unknown>[])
    : [];
  if (paramsList.length === 0 || paramsList.length > 64) {
    throw new Error("external runtime event batch has invalid cardinality");
  }
  const events = paramsList.map((params) => runtimeEvent(params));
  if (new Set(events.map((event) => event.id)).size !== events.length) {
    throw new Error("external runtime event batch repeats an event id");
  }
  const validRequestID = message.method === "external_runtime_event"
    ? requestID === events[0].id
    : /^runtime_events_[0-7][0-9A-HJKMNP-TV-Z]{25}$/.test(requestID);
  if (!validRequestID) {
    throw new Error(
      message.method === "external_runtime_event"
        ? "legacy runtime event request id differs from its durable event id"
        : "external runtime event batch is missing a unique attempt id",
    );
  }
  return {
    requestID,
    legacy: message.method === "external_runtime_event",
    events,
  };
}

function runtimeEvent(params: Record<string, unknown>): DurableRuntimeEvent {
  const id = String(params.event_id ?? "");
  const event = (params.event ?? {}) as Record<string, unknown>;
  if (
    !/^[0-7][0-9A-HJKMNP-TV-Z]{25}$/.test(id) ||
    !Number.isInteger(event.created_at)
  ) {
    throw new Error(
      "external runtime event is missing its durable execution identity",
    );
  }
  return {
    id,
    createdAt: event.created_at as number,
    dispatchID: String(event.dispatch_id ?? ""),
    params,
    event,
  };
}

async function* textLines(stream: ReadableStream<Uint8Array>) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      buffer += decoder.decode(value, { stream: !done });
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        yield buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf("\n");
      }
      if (done) {
        if (buffer !== "") yield buffer;
        return;
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function legacyRecoveryPath(root: string, sessionID: string) {
  return `${root}/external-runtime/active/${sessionID}.json`;
}

async function writeLegacyRecoveryFile(
  root: string,
  fixture: LocalRuntimeFixture,
) {
  const dir = `${root}/external-runtime/active`;
  await Deno.mkdir(dir, { recursive: true, mode: 0o700 });
  const workspace = fixture.statePath.slice(0, -"/recovery-state".length);
  await Deno.writeTextFile(
    legacyRecoveryPath(root, fixture.sessionID),
    JSON.stringify({
      version: 1,
      session: {
        provider: fixture.provider,
        session_id: fixture.sessionID,
        runtime_capability_token: `capability-${fixture.sessionID}`,
        command: fixture.command,
        workspace,
        system_prompt: "local recovery e2e",
        runtime_payload: fixture.provider === "pi"
          ? { session_id: "pi-native" }
          : {},
      },
    }),
    { mode: 0o600 },
  );
}

async function legacyRecoveryFileExists(root: string, sessionID: string) {
  try {
    await Deno.stat(legacyRecoveryPath(root, sessionID));
    return true;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return false;
    throw error;
  }
}

async function assertExternalRuntimeStateSymlinksRejected(
  bin: string,
  temp: string,
) {
  for (const variant of ["directory", "database"] as const) {
    const root = `${temp}/symlink-${variant}-root`;
    const outside = `${temp}/symlink-${variant}-outside`;
    const stateDir = `${root}/external-runtime`;
    await Deno.mkdir(root, { recursive: true, mode: 0o700 });
    await Deno.mkdir(outside, { recursive: true, mode: 0o700 });
    let escapedDatabase: string;
    if (variant === "directory") {
      await Deno.symlink(outside, stateDir);
      escapedDatabase = `${outside}/state.db`;
    } else {
      await Deno.mkdir(stateDir, { mode: 0o700 });
      escapedDatabase = `${outside}/state.db`;
      await Deno.symlink(escapedDatabase, `${stateDir}/state.db`);
    }

    const port = reservePort();
    port.release();
    const child = new Deno.Command(bin, {
      args: [
        "--vm-server",
        "--listen",
        `127.0.0.1:${port.port}`,
        "--root",
        root,
        "--system-info-interval",
        "0",
      ],
      stdout: "null",
      stderr: "null",
    }).spawn();
    const statusPromise = child.status;
    const status = await Promise.race([
      statusPromise,
      delay(2_000).then(() => undefined),
    ]);
    if (!status) {
      child.kill("SIGTERM");
      await statusPromise.catch(() => {});
      throw new Error(`connector followed external runtime ${variant} symlink`);
    }
    if (status.success) {
      throw new Error(`connector accepted external runtime ${variant} symlink`);
    }
    if (await pathExists(escapedDatabase)) {
      throw new Error(
        `connector created external runtime state outside root through ${variant} symlink`,
      );
    }
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

async function recoveryThreadID(fixture: LocalRuntimeFixture) {
  const lines = (await Deno.readTextFile(fixture.logPath)).split("\n");
  for (let index = lines.length - 1; index >= 0; index--) {
    if (!lines[index].startsWith("turn/start ")) continue;
    const params = JSON.parse(lines[index].slice("turn/start ".length));
    const threadID = String(params.threadId ?? "");
    if (threadID) return threadID;
  }
  throw new Error(`runtime log for ${fixture.sessionID} has no thread id`);
}

async function assertStateDatabaseSecurity(root: string) {
  const database = `${root}/external-runtime/state.db`;
  for (
    const [path, expected] of [
      [`${root}/external-runtime`, 0o700],
      [database, 0o600],
    ] as const
  ) {
    const mode = (await Deno.stat(path)).mode;
    if (mode !== null && (mode & 0o777) !== expected) {
      throw new Error(
        `${path} mode=${(mode & 0o777).toString(8)}, want ${
          expected.toString(
            8,
          )
        }`,
      );
    }
  }
}

async function runtimeProcessAlive(fixture: LocalRuntimeFixture) {
  const pid = (await Deno.readTextFile(fixture.pidPath)).trim();
  return (await run("kill", ["-0", pid], { allowFailure: true })).success;
}

async function recoveryCount(fixture: LocalRuntimeFixture) {
  const log = await Deno.readTextFile(fixture.logPath).catch(() => "");
  return log.split("\n").filter((line) => line.includes(fixture.recoveryMarker))
    .length;
}

async function recoveryContinuationCount(fixture: LocalRuntimeFixture) {
  const log = await Deno.readTextFile(fixture.logPath).catch(() => "");
  return log
    .split("\n")
    .filter((line) => line.includes(RECOVERY_MESSAGE_MARKER)).length;
}

async function recoveryDecisionCount(fixture: LocalRuntimeFixture) {
  return (await recoveryDecisions(fixture)).length;
}

async function recoveryDecisions(fixture: LocalRuntimeFixture) {
  const raw = await Deno.readTextFile(fixture.decisionPath).catch(() => "");
  return raw
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

async function runtimeStartCount(fixture: LocalRuntimeFixture) {
  const log = await Deno.readTextFile(fixture.logPath).catch(() => "");
  return log.split("\n").filter(fixture.startMarker).length;
}

async function runtimeMethodCount(
  fixture: LocalRuntimeFixture,
  method: string,
) {
  const log = await Deno.readTextFile(fixture.logPath).catch(() => "");
  return log.split("\n").filter((line) => line === method).length;
}

async function runtimeInputCount(fixture: LocalRuntimeFixture) {
  const lines = (
    await Deno.readTextFile(fixture.logPath).catch(() => "")
  ).split("\n");
  switch (fixture.provider) {
    case "codex":
      return lines.filter((line) => line.startsWith("turn/start ")).length;
    case "pi":
      return lines.filter((line) => line.includes('"type":"prompt"')).length;
    case "kimi":
      return lines.filter(
        (line) => line.startsWith('{"content"') || line.includes('"content":['),
      ).length;
  }
}

async function waitUntil(
  label: string,
  timeoutMs: number,
  ready: () => boolean | Promise<boolean>,
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await ready()) return;
    await delay(100);
  }
  throw new Error(`timed out waiting for ${label}`);
}

async function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  label: string,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_resolve, reject) => {
        timer = setTimeout(
          () => reject(new Error(`timed out waiting for ${label}`)),
          timeoutMs,
        );
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

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
    prefix: "salix-connect-e2e-config-",
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

async function waitForConnectorHealth(endpoint: string) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${endpoint}/healthz`);
      if (response.ok) return;
    } catch {
      // Connector is still starting.
    }
    await delay(50);
  }
  throw new Error(`connector did not become healthy: ${endpoint}`);
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

function pathWithAsdf() {
  const path = Deno.env.get("PATH") ?? "";
  const home = Deno.env.get("HOME");
  if (!home) return path;
  return `${home}/.asdf/shims:${path}`;
}

async function writeFakeAsyncCompletionShim(directory: string) {
  await Deno.mkdir(directory);
  const path = `${directory}/salix`;

  // The fake providers equate a successful CLI process exit with native-turn
  // completion. The E2E configures RuntimeProxy's compatibility wait to zero,
  // so keep only that fake process open until its exact running call has been
  // accepted, drained, and delivered back by the connector. The original fake
  // terminal then remains the final event.
  await Deno.writeTextFile(
    path,
    [
      "#!/bin/sh",
      'output=$("$SALIX_TEST_REAL_SALIX" "$@" 2>&1)',
      "status=$?",
      "printf '%s\\n' \"$output\"",
      'if [ "$status" -ne 0 ] || [ "${1-}" != tool ] || [ "${2-}" != call ] || [ "${3-}" != im_api.internal.send_message ]; then',
      '  exit "$status"',
      "fi",
      'if ! printf \'%s\\n\' "$output" | grep -Eq \'"status"[[:space:]]*:[[:space:]]*"running"\'; then',
      '  exit "$status"',
      "fi",
      'tool_call_id=$(printf \'%s\\n\' "$output" | sed -n \'s/.*"tool_call_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p\' | tail -n 1)',
      'if [ -z "$tool_call_id" ]; then',
      "  printf 'missing_running_tool_call_id\\n' >> \"$SALIX_TEST_FAKE_ASYNC_COMPLETION_EVIDENCE\"",
      "  exit 70",
      "fi",
      "attempt=0",
      'while [ "$attempt" -lt 600 ]; do',
      '  if grep -E \'tool_call_(completed|failed)\' "$SALIX_TEST_FAKE_RUNTIME_LOG" 2>/dev/null | grep -F "$tool_call_id" >/dev/null 2>&1; then',
      '    printf \'accepted_drained tool_call_id=%s\\n\' "$tool_call_id" >> "$SALIX_TEST_FAKE_ASYNC_COMPLETION_EVIDENCE"',
      '    sleep "${SALIX_TEST_FAKE_ASYNC_COMPLETION_SETTLE_DELAY_SECONDS:-1}"',
      '    exit "$status"',
      "  fi",
      "  attempt=$((attempt + 1))",
      "  sleep 0.1",
      "done",
      'printf \'delivery_timeout tool_call_id=%s\\n\' "$tool_call_id" >> "$SALIX_TEST_FAKE_ASYNC_COMPLETION_EVIDENCE"',
      "exit 70",
      "",
    ].join("\n"),
  );
  await Deno.chmod(path, 0o755);
}

function fakeAsyncCompletionShimEnvironment(
  shimDirectory: string,
  runtimeLog: string,
  evidencePath: string,
  settleDelaySeconds = "1",
) {
  return [
    'SALIX_TEST_REAL_SALIX="$(command -v salix)"; export SALIX_TEST_REAL_SALIX',
    `export SALIX_TEST_FAKE_RUNTIME_LOG=${shellQuote(runtimeLog)}`,
    `export SALIX_TEST_FAKE_ASYNC_COMPLETION_EVIDENCE=${
      shellQuote(
        evidencePath,
      )
    }`,
    `export SALIX_TEST_FAKE_ASYNC_COMPLETION_SETTLE_DELAY_SECONDS=${
      shellQuote(
        settleDelaySeconds,
      )
    }`,
    `export PATH=${shellQuote(shimDirectory)}:"$PATH"`,
  ];
}

async function assertFakeAsyncCompletionEvidence(
  evidencePath: string,
  provider: string,
) {
  const evidence = await Deno.readTextFile(evidencePath).catch(() => "");
  const accepted = evidence
    .split("\n")
    .filter((line) => line.startsWith("accepted_drained "));
  if (
    accepted.length === 0 ||
    !accepted.every((line) =>
      /^accepted_drained tool_call_id=http-tool:[0-9a-f]{24}$/.test(line)
    ) ||
    evidence.includes("delivery_timeout") ||
    evidence.includes("missing_running_tool_call_id")
  ) {
    throw new Error(
      `fake ${provider} runtime did not receive and drain an exact async completion delivery\n${evidence}`,
    );
  }
}

async function writeFakeRuntime(
  path: string,
  version: string,
  environment: string[],
  helper: string,
  testName: string,
) {
  await Deno.writeTextFile(
    path,
    [
      "#!/bin/sh",
      `if [ \"$1\" = \"--version\" ]; then echo ${
        shellQuote(
          version,
        )
      }; exit 0; fi`,
      ...environment,
      `exec ${shellQuote(helper)} -test.run=${testName} -- \"$@\"`,
      "",
    ].join("\n"),
  );
  await Deno.chmod(path, 0o755);
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

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
