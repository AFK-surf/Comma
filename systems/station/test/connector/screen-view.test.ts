// Which computers say they serve their display on the mesh (`screen_view`), in a device connection's metadata
// (docs/desktop-screen.md, "Which computers offer a view").
import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import { makeConnector } from "../../src/connector/connector.ts";
import { tempDir } from "./support/temp.ts";

const connector = (deviceMode: boolean) => {
  const root = tempDir();
  return makeConnector({ root, deviceMode, configPath: join(root, "instance.json"), env: { HOME: tempDir() } });
};

test("a Linux computer's station offers its desktop on the mesh", { skip: process.platform !== "linux" }, () => {
  const capabilities = connector(true).metadata().capabilities!;
  assert.equal(capabilities.screen_view, true);
});

test("a station that is not a computer's (a sandbox's, a workload's) says no screen", () => {
  const capabilities = connector(false).metadata().capabilities!;
  assert.equal("screen_view" in capabilities, false);
});
