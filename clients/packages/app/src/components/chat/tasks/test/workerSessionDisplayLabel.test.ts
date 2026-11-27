import { describe, expect, it } from "vitest";
import {
  showsWorkerSessionSlot,
  workerSessionDisplayLabel,
  workerSessionModelName,
  workerSessionName,
} from "../WorkerSessionsRoster";

describe("workerSessionDisplayLabel", () => {
  it("drops a runtime, vendor, or model-token note its mark and model already show", () => {
    expect(
      workerSessionDisplayLabel({
        label: "Lead (Claude)",
        runtime: "claude",
        model: "claude-sonnet-4-6",
      })
    ).toBe("Lead");
    expect(
      workerSessionDisplayLabel({ label: "Reviewer (Codex)", model: "gpt-5.3-codex" })
    ).toBe("Reviewer");
  });

  it("keeps a note that says something else or only matches a substring of the model", () => {
    expect(
      workerSessionDisplayLabel({
        label: "Reviewer (security)",
        runtime: "codex",
        model: "gpt-5.3-codex",
      })
    ).toBe("Reviewer (security)");
    expect(
      workerSessionDisplayLabel({
        label: "Reviewer (net)",
        runtime: "claude",
        model: "claude-sonnet-4-6",
      })
    ).toBe("Reviewer (net)");
    expect(workerSessionDisplayLabel({ label: "Lead", runtime: "claude" })).toBe(
      "Lead"
    );
  });

  it("does not duplicate @slot when stripping a trailing runtime note leaves @slot", () => {
    const displayLabel = workerSessionDisplayLabel({
      label: "@reviewer (Codex)",
      model: "gpt-5.3-codex",
    });
    expect(displayLabel).toBe("@reviewer");
    expect(showsWorkerSessionSlot(displayLabel, "reviewer")).toBe(false);
  });
});

describe("workerSessionModelName", () => {
  it("formats compact model names for the Sessions panel row and message headers", () => {
    expect(workerSessionModelName("claude-sonnet-4-6")).toBe("Sonnet-4-6");
    expect(workerSessionModelName("anthropic/claude-opus-4-6")).toBe("Opus-4-6");
    expect(workerSessionModelName("gpt-5.3-codex")).toBe("GPT-5.3-codex");
    expect(workerSessionModelName("openai/gpt-5.3-codex")).toBe("GPT-5.3-codex");
    expect(workerSessionModelName("kimi-k2")).toBe("kimi-k2");
  });
});

describe("workerSessionName", () => {
  it("names a session by its model when known, else falls back to display label", () => {
    expect(
      workerSessionName({
        label: "Lead",
        runtime: "claude",
        model: "claude-sonnet-4-6",
      })
    ).toBe("Sonnet-4-6");
    expect(workerSessionName({ label: "Lead (Claude)", runtime: "claude" })).toBe(
      "Lead"
    );
  });
});

describe("showsWorkerSessionSlot", () => {
  it("leaves out a handle the name already says", () => {
    expect(showsWorkerSessionSlot("Lead", "lead")).toBe(false);
    expect(showsWorkerSessionSlot("@lead", "lead")).toBe(false);
    expect(showsWorkerSessionSlot("Sonnet-4-6", "lead")).toBe(true);
    expect(showsWorkerSessionSlot("GPT-5.3-codex", "reviewer")).toBe(true);
  });
});
