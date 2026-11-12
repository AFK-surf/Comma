// The machine's name the device is named by (system-info.ts `machineName`).
import assert from "node:assert/strict";
import { test } from "node:test";
import { parseArgs } from "../../src/connector/config.ts";
import { machineName } from "../../src/connector/system-info.ts";

test("a Mac's name on the local network names its device without the .local", () => {
  assert.equal(machineName("MacBook-Pro-2.local"), "MacBook-Pro-2");
  assert.equal(machineName("Pengs-Mac-Mini-2.local"), "Pengs-Mac-Mini-2");
  assert.equal(machineName("build-box"), "build-box");
  assert.equal(machineName("printer.local.example"), "printer.local.example");
  // What the connector dials as its name, unless one is given.
  assert.equal(parseArgs([], {}).cfg.name.endsWith(".local"), false);
  assert.equal(parseArgs([], { SALIX_CONNECTOR_NAME: "Studio.local" }).cfg.name, "Studio.local");
});
