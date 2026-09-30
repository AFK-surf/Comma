import { spawn } from "node:child_process";
import { access, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { MainProductCredentialAuthority } from "../../../src/main/modules/session/main-product-credential-authority";
import type { MainSessionTransportAuthority } from "../../../src/main/modules/session/main-session-transport";
import {
  WorkspaceConnectorRuntimeService,
  type ConnectorChildLike,
  type SpawnConnectorChild,
} from "../../../src/main/modules/connector-runtime";

const audience = requiredEnvironment("COMMA_CONNECTOR_CONTAINMENT_AUDIENCE");
const blockedMarkerPath = requiredEnvironment(
  "COMMA_CONNECTOR_CONTAINMENT_BLOCKED_MARKER"
);
const childStartedMarkerPath = requiredEnvironment(
  "COMMA_CONNECTOR_CONTAINMENT_CHILD_STARTED_MARKER"
);
const connectorsRootDir = requiredEnvironment(
  "COMMA_CONNECTOR_CONTAINMENT_CONNECTORS_ROOT"
);
const localFileIndexRoot = requiredEnvironment(
  "COMMA_CONNECTOR_CONTAINMENT_LOCAL_FILE_INDEX_ROOT"
);
const connectorFileRoot = requiredEnvironment("COMMA_CONNECTOR_CONTAINMENT_FILE_ROOT");
const workspaceId = requiredEnvironment("COMMA_CONNECTOR_CONTAINMENT_WORKSPACE_ID");
const helperPath = fileURLToPath(new URL("./stubborn-child.mjs", import.meta.url));

const authority = new MainProductCredentialAuthority({
  authorityInstanceId: "connector_containment_e2e_owner",
  trustedAudience: audience,
});
authority.acceptVerifiedCredential({
  audience,
  email: "connector-containment@comma.local",
  expiresAtEpochSeconds: 4_102_444_800,
  sessionId: "sess_connector_containment_owner",
  token: "comma_session_connector_containment",
  userId: "usr_connector_containment",
});
const session: MainSessionTransportAuthority = {
  authority,
  reportUnauthorized: async () => undefined,
};

const spawnConnector: SpawnConnectorChild = (input) => {
  const child = spawn(
    process.execPath,
    [
      helperPath,
      "--config",
      input.configPath,
      "--run-nonce",
      input.runNonce,
      "--shutdown-request-file",
      input.shutdownRequestPath,
      "--parent-lifeline-fd",
      String(input.parentLifelineFd),
      "--started-marker",
      childStartedMarkerPath,
    ],
    {
      detached: true,
      stdio: "ignore",
    }
  );
  return childThatIgnoresParentLifeline(child);
};

const runtime = new WorkspaceConnectorRuntimeService({
  backoffScheduleMs: [60_000],
  binaryPath: process.execPath,
  connectorFileRoot,
  connectorsRootDir,
  localFileIndexRoot,
  persistPidEvidence: async (path, evidence) => {
    // This is the exact crash barrier: spawn has returned and the real child
    // has entered its loop, while connector.pid still does not exist.
    await waitForFile(childStartedMarkerPath);
    await writeFile(
      blockedMarkerPath,
      `${JSON.stringify({
        ...evidence,
        pidEvidencePath: path,
        runDir: dirname(path),
      })}\n`,
      { mode: 0o600 }
    );
    await new Promise<void>(() => undefined);
  },
  session,
  spawnConnector,
});

runtime.prewarm(workspaceId);

// Keep the owner alive at the deterministic persistence barrier until the E2E
// kills it like an abrupt Electron Main crash.
await new Promise<void>(() => undefined);

function childThatIgnoresParentLifeline(
  child: ReturnType<typeof spawn>
): ConnectorChildLike {
  let settled = false;
  const listeners = new Set<() => void>();
  const settle = () => {
    if (settled) return;
    settled = true;
    for (const listener of listeners) listener();
    listeners.clear();
  };
  child.once("exit", settle);
  child.once("error", settle);
  return {
    get pid() {
      return child.pid;
    },
    once(_event, listener) {
      if (settled) listener();
      else listeners.add(listener);
      return this;
    },
    requestStop() {
      // Deliberately ignore the owner lifeline. Recovery must find this actual
      // OS child through executable/config/nonce identity and stop it by nonce.
    },
    setScope() {
      return Promise.resolve();
    },
  };
}

async function waitForFile(path: string) {
  for (;;) {
    try {
      await access(path);
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
}

function requiredEnvironment(name: string) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
}
