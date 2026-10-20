import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { describe, expect, it } from "vitest";
import { testProductLease } from "../../../test/productInboxProjectionHarness";
import { resolveWorkspaceChat } from "../useWorkspaceChat";

/** A core whose `chat.resolveWorkspaceChat` answers `resolution`. */
const coreAnswering = (resolution: unknown) =>
  createScriptedCore({
    calls: (name) => (name === "chat.resolveWorkspaceChat" ? resolution : null),
  });

// What the core decides (the server's default workspace, an exact one, provisioning, refusals) is the core's test
// (packages/core/test/chat/chat.test.ts); here, what the window asks and how it shows the answer.
describe("Workspace Chat resolution", () => {
  it("passes through an unauthorized resolution", async () => {
    const core = coreAnswering({ status: "unauthorized" });

    await expect(
      resolveWorkspaceChat({ core: core.client, session: testProductLease })
    ).resolves.toEqual({ status: "unauthorized" });
    expect(core.sentTo("chat.resolveWorkspaceChat")).toEqual([
      { session: testProductLease },
    ]);
  });

  it("preserves the core's canonical timestamps in a ready resolution", async () => {
    const core = coreAnswering({
      conversationId: "cnv_native",
      createdAt: 1_720_000_000,
      groupId: "grp_native",
      status: "ready",
      updatedAt: 1_720_000_003,
      workspaceId: "wsp_native",
    });

    await expect(
      resolveWorkspaceChat({
        core: core.client,
        defaultTitle: "Native Chat",
        session: testProductLease,
      })
    ).resolves.toMatchObject({
      conversation: {
        created_at: 1_720_000_000,
        id: "cnv_native",
        title: "Native Chat",
        updated_at: 1_720_000_003,
      },
      groupId: "grp_native",
      status: "ready",
      workspaceId: "wsp_native",
    });
  });

  it("fails closed without a Session lease", async () => {
    const core = coreAnswering({ status: "hidden" });

    await expect(resolveWorkspaceChat({ core: core.client })).rejects.toThrow(
      "requires the active Session product lease"
    );
    expect(core.sentTo("chat.resolveWorkspaceChat")).toEqual([]);
  });

  it("asks the core for the exact workspace only on an explicit route scope", async () => {
    const core = coreAnswering({ status: "hidden" });

    await resolveWorkspaceChat({
      core: core.client,
      session: testProductLease,
      workspaceId: "wsp_2",
    });
    await resolveWorkspaceChat({
      core: core.client,
      session: testProductLease,
      exactWorkspace: true,
      workspaceId: "wsp_2",
    });

    expect(core.sentTo("chat.resolveWorkspaceChat")).toEqual([
      { session: testProductLease },
      { session: testProductLease, workspaceId: "wsp_2" },
    ]);
  });
});
