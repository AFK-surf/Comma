// Which computers say they serve their display on the mesh (`screen_view`), in a device connection's metadata
// (docs/desktop-screen.md, "Which computers offer a view").
import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import { makeConnector, type StationRelay } from "../../src/connector/connector.ts";
import { tempDir } from "./support/temp.ts";

const connector = (deviceMode: boolean, taskScreen = false) => {
  const root = tempDir();
  // The part of the station that carries the mesh through Salix (mesh/salix-relay.ts), which says whether this
  // station is a Task's sandbox that can show its display. The connection only reads that here.
  const relay: StationRelay = { endpointId: "ab".repeat(32), sign: () => Buffer.alloc(64), incoming: () => {}, attach: () => {}, taskScreen };
  return makeConnector({ root, deviceMode, configPath: join(root, "instance.json"), env: { HOME: tempDir() } }, undefined, { relay });
};

test("a Linux computer's station offers its desktop on the mesh", { skip: process.platform !== "linux" }, () => {
  const capabilities = connector(true).metadata().capabilities!;
  assert.equal(capabilities.screen_view, true);
});

test("a Task's sandbox with a display offers it on the mesh", { skip: process.platform !== "linux" }, () => {
  const capabilities = connector(false, true).metadata().capabilities!;
  assert.equal(capabilities.screen_view, true);
});

test("a station that is not a computer's and shows no Task its screen (a workload's) says no screen", () => {
  const capabilities = connector(false).metadata().capabilities!;
  assert.equal("screen_view" in capabilities, false);
});

test("a station that shows no Task its screen never says there is something on it", () => {
  const root = tempDir();
  const tasks = { handle: async () => ({}), models: () => ({}), browsing: () => true, attach: () => {} };
  const capabilities = makeConnector({ root, deviceMode: false, configPath: join(root, "instance.json"), env: { HOME: tempDir() } }, undefined, { tasks }).metadata().capabilities!;
  assert.equal("screen_active" in capabilities, false);
});
