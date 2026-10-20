import { describe, expect, it } from "vitest";
import type { SessionHistoryRecord } from "../../chat/session-history/useSessionHistory";
import { sessionHistoryEntries } from "../../chat/session-history/model/sessionHistoryEntries";
import {
  presentSessionRecords,
  type SessionItemLabels,
} from "../../chat/session-history/model/sessionHistoryPresentation";
import { openComputerUseSession } from "../computerUseSession";

const epoch = 1_788_564_963_000;
const labels = new Proxy({} as SessionItemLabels, {
  get: (_target, key) =>
    key === "count" ? () => "" : key === "inputSource" ? undefined : String(key),
});

/** One finished tool call: the model's request and the tool's result. */
function step(
  index: number,
  name: string,
  args: Record<string, unknown>,
  status: "completed" | "failed" = "completed"
): SessionHistoryRecord[] {
  const id = `call_${index}`;
  const at = epoch + index * 2000;
  return [
    {
      id: `${id}:call`,
      kind: "assistant",
      content: { tool_calls: [{ id, name, args }] },
      timestamp_ms: at,
      execution: {
        id: `${id}:model`,
        lane: "model",
        started_at_ms: at - 500,
        observed_at_ms: at,
        completed_at_ms: at,
        duration_ms: 500,
      },
    },
    {
      id: `${id}:result`,
      kind: "tool",
      content: { type: `tool_call_${status}`, tool_call_id: id, status },
      timestamp_ms: at + 1000,
      execution: {
        id,
        lane: "tool",
        started_at_ms: at + 100,
        observed_at_ms: at + 1000,
        completed_at_ms: at + 1000,
        duration_ms: 900,
      },
    },
  ];
}

function session(...steps: SessionHistoryRecord[][]) {
  const records = steps.flat();
  return openComputerUseSession(
    sessionHistoryEntries(records, presentSessionRecords(records, labels))
  );
}

const computerUse = (index: number, action: string, args?: Record<string, unknown>) =>
  step(index, "env.computer_use", {
    device_id: "dev_mac",
    action,
    ...(args ? { args } : {}),
  });

describe("openComputerUseSession", () => {
  it("names the computer and the apps of the session that start opened", () => {
    expect(
      session(
        step(1, "env.exec", { command: "ls" }),
        computerUse(2, "start", { apps: ["TextEdit", "Safari"] }),
        computerUse(3, "left_click", { x: 10, y: 20 })
      )
    ).toEqual({ device: "dev_mac", apps: ["TextEdit", "Safari"] });
  });

  it("has no session after end or stop", () => {
    expect(
      session(computerUse(1, "start", { apps: ["TextEdit"] }), computerUse(2, "end"))
    ).toBeUndefined();
    expect(session(computerUse(1, "start"), computerUse(2, "stop"))).toBeUndefined();
  });

  it("opens the newest session after an earlier one ended", () => {
    expect(
      session(
        computerUse(1, "start", { apps: ["TextEdit"] }),
        computerUse(2, "end"),
        computerUse(3, "start", { apps: ["Notes"] })
      )
    ).toEqual({ device: "dev_mac", apps: ["Notes"] });
  });

  it("shows the driven computer when start left the loaded page", () => {
    expect(session(computerUse(1, "get-screenshot"))).toEqual({
      device: "dev_mac",
      apps: [],
    });
  });

  it("opens nothing for a failed start or a status check", () => {
    expect(
      session(
        step(1, "env.computer_use", { device_id: "dev_mac", action: "start" }, "failed")
      )
    ).toBeUndefined();
    expect(session(computerUse(1, "permissions-status"))).toBeUndefined();
  });
});
