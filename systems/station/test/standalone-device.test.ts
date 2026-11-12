// What an enrollment gives a computer without the desktop app: its connection to Salix, as the station reads it.
import assert from "node:assert/strict";
import { mkdtempSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Effect } from "effect";
import { INSTANCES_DIR } from "../src/accounts/sources.ts";
import { writeDeviceInstance } from "../src/cli.ts";
import { instanceConfig } from "../src/connector/service.ts";

test("an enrollment's connector is an instance the station connects as a device with", async () => {
  const data = mkdtempSync(join(tmpdir(), "standalone-"));
  writeDeviceInstance(data, "https://comma.test", { token: "salix_conn_x", server: "https://salix.test", name: "Station", workspace_id: "wsp_1" });
  const path = join(data, INSTANCES_DIR, "device.json");
  assert.equal(statSync(path).mode & 0o777, 0o600);
  const cfg = await Effect.runPromise(instanceConfig(path, {}));
  assert.equal(cfg?.token, "salix_conn_x");
  assert.equal(cfg?.server, "https://salix.test");
  assert.equal(cfg?.deviceMode, true);
  assert.equal(cfg?.deviceWorkspaceId, "wsp_1");
});

test("a connector naming no server connects where the station enrolled", async () => {
  const data = mkdtempSync(join(tmpdir(), "standalone-"));
  writeDeviceInstance(data, "https://comma.test", { token: "salix_conn_x", server: "", name: "Station", workspace_id: "wsp_1" });
  const cfg = await Effect.runPromise(instanceConfig(join(data, INSTANCES_DIR, "device.json"), {}));
  assert.equal(cfg?.server, "https://comma.test");
});
