// Ported from systems/connector/salix-connect/device_source_test.go (same test name).
// A device reports which client it runs for, from the runtime namespace the app gives it.
import assert from "node:assert/strict";
import { test } from "node:test";
import { makeConnector } from "../../src/connector/connector.ts";

test("TestDeviceSystemInfoReportsClientSource", () => {
  for (const [namespace, want] of [["@comma-dev", "comma_dev"], ["@comma-staging", "comma_staging"], ["@comma", "comma"], ["", "connector"], ["private-profile", "connector"]]) {
    const info = makeConnector({ runtimeNamespace: namespace }).deviceSystemInfo();
    assert.equal(info.client_source, want, `namespace ${namespace}`);
    assert.ok(info.hostname, "host information missing");
  }
});
