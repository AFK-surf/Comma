import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  localDevElectronEnvironment,
  writeLocalDevSessionFile,
} from "./comma-local-dev-electron.mjs";

test("local Electron uses the shared startup Session with the normal dev profile", () => {
  const environment = localDevElectronEnvironment(
    {
      apiBaseUrl: "http://127.0.0.1:4200",
      email: "comma-local@example.com",
      sessionToken: "local-session-token",
    },
    {
      COMMA_ELECTRON_E2E_GOOGLE_ID_TOKEN: "must-not-escape",
      COMMA_ELECTRON_E2E_CONNECTOR_MODE: "static",
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "stale@example.com",
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "stale-token",
      COMMA_SKIP_NATIVE_BUILD: "1",
      NODE_ENV: "test",
    },
    "/repo/.local/comma-dev-session.json",
  );

  assert.deepEqual(environment, {
    COMMA_API_BASE_URL: "http://127.0.0.1:4200",
    COMMA_ELECTRON_STARTUP_SESSION_FILE: "/repo/.local/comma-dev-session.json",
    COMMA_SKIP_NATIVE_BUILD: "1",
    NODE_ENV: "development",
  });
});

test("local Electron persists its login seed in a private ignored config", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "comma-dev-session-"));
  const filePath = path.join(root, ".local/comma-dev-session.json");

  await writeLocalDevSessionFile(
    {
      apiBaseUrl: "http://127.0.0.1:4200",
      email: "comma-local@example.com",
      sessionToken: "local-session-token",
    },
    filePath,
  );

  assert.deepEqual(JSON.parse(await readFile(filePath, "utf8")), {
    apiBaseUrl: "http://127.0.0.1:4200",
    email: "comma-local@example.com",
    sessionToken: "local-session-token",
    version: 1,
  });
  assert.equal((await stat(filePath)).mode & 0o777, 0o600);
});
