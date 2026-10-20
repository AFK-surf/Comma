import { renderHook, waitFor } from "@comma/test-utils/render";
import type { WorkspaceChatValue } from "@comma/core/contract";
import type { ReactNode } from "react";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { describe, expect, it } from "vitest";
import { testProductLease } from "../../../test/productInboxProjectionHarness";
import { ChatProvider } from "../ChatProvider";
import { useWorkspaceChat } from "../useWorkspaceChat";

/** The hook on a core whose `workspaceChat` is `value`. */
function render(value: WorkspaceChatValue) {
  installNativeBridgeMock();
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "workspaceChat" ? value : undefined),
  });
  return renderHook(() => useWorkspaceChat({}), {
    wrapper: ({ children }: { children: ReactNode }) =>
      core.wrap(
        <ChatProvider productLease={testProductLease}>{children}</ChatProvider>
      ),
  });
}

describe("useWorkspaceChat", () => {
  it("says a failed resolution failed in its own words, and shows a chat found before through it", async () => {
    const failed = render({ status: "error", chat: null, kept: false });
    await waitFor(() =>
      expect(failed.result.current.state).toEqual({
        message: "Chat is temporarily unavailable",
        status: "error",
      })
    );

    const kept = render({
      status: "error",
      chat: { workspaceId: "wsp_1", groupId: "grp_1", conversationId: "cnv_1" },
      kept: true,
    });
    await waitFor(() =>
      expect(kept.result.current.state).toMatchObject({
        status: "ready",
        workspaceId: "wsp_1",
        groupId: "grp_1",
        conversation: { id: "cnv_1", group_id: "grp_1" },
      })
    );
  });

  it("says the workspace is still being made while the core waits for it", async () => {
    const { result } = render({
      status: "provisioning",
      chat: null,
      kept: false,
      provisioning: {
        workspaceId: "wsp_reserved",
        groupId: "grp_reserved",
        retryAfterSeconds: 3,
      },
    });
    await waitFor(() =>
      expect(result.current.state).toEqual({
        groupId: "grp_reserved",
        retryAfterSeconds: 3,
        status: "provisioning",
        workspaceId: "wsp_reserved",
      })
    );
  });
});
