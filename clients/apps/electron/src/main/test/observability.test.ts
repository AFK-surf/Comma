import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { JsonlNativeObservabilitySink } from "../modules/observability";
import type { NativeObservationEvent } from "../modules/ipc";

describe("JsonlNativeObservabilitySink", () => {
  it("writes redacted JSONL observations for agent-readable traces", () => {
    const dir = mkdtempSync(join(tmpdir(), "comma-observability-"));
    const filePath = join(dir, "native-events.jsonl");
    const sink = new JsonlNativeObservabilitySink({ filePath });
    const event: NativeObservationEvent = {
      caller: {
        origin: "assets://.",
        role: "main-window",
        webContentsId: 12,
        windowId: "win_main",
      },
      capabilityId: "session.proxyProbe",
      channel: "comma:session:proxy-probe",
      durationMs: 1,
      error: new Error(
        "Authorization Bearer secret-token failed at /Users/pengx17/Comma/.env"
      ),
      kind: "native-command",
      payloadClass: "control",
      permission: "session.proxy-probe",
      status: "handler-error",
      timestamp: "2026-07-01T07:00:00.000Z",
      trace: {
        flowId: "native-command",
        id: "native-command:session.proxyProbe:1",
        source: "renderer:win_main",
        stepId: "session.proxyProbe",
        target: "main:session.proxyProbe",
      },
      transport: "ipc-rpc",
    };

    try {
      sink.record(event);

      const line = readFileSync(filePath, "utf8").trim();
      expect(line).toContain('"channel":"comma:session:proxy-probe"');
      expect(line).toContain("[redacted:secret]");
      expect(line).toContain("[redacted-path]");
      expect(line).not.toContain("secret-token");
      expect(line).not.toContain("/Users/pengx17");
    } finally {
      rmSync(dir, { force: true, recursive: true });
    }
  });
});
