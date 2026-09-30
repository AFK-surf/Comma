import { fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { ConversationRoute } from "../ConversationRoute";

const harness = vi.hoisted(() => ({
  acceptTaskReview: vi.fn(),
  apiAcceptTaskReview: vi.fn(),
  refresh: vi.fn(),
}));

vi.mock("@tanstack/react-router", () => ({
  useNavigate: () => vi.fn(),
  useParams: () => ({
    conversationId: "cnv_task",
    groupId: "grp_1",
    workspaceId: "wsp_1",
  }),
}));

vi.mock("../../../chat-sidebar/ChatSidebarContext", () => ({
  useChatSidebar: () => ({
    canOpenChildChat: () => false,
    openBrowser: vi.fn(),
    openChat: vi.fn(),
  }),
  useRegisterChatSidebarHost: vi.fn(),
}));

vi.mock("../../ChatProvider", () => ({
  useChatApi: () => ({ acceptTaskReview: harness.apiAcceptTaskReview }),
}));

vi.mock("../useConversation", () => ({
  useConversation: () => ({
    acceptTaskReview: harness.acceptTaskReview,
    attachFiles: vi.fn(),
    discard: vi.fn(),
    refresh: harness.refresh,
    removeAttachment: vi.fn(),
    retry: vi.fn(),
    retryAttachment: vi.fn(),
    send: vi.fn(),
    setDraft: vi.fn(),
    state: {},
  }),
}));

vi.mock("../../useWorkspaceSkills", () => ({
  useWorkspaceSkills: () => [],
}));

vi.mock("../ConversationView", () => ({
  ConversationView: ({
    actions,
    windowControlsInset,
  }: {
    actions: { acceptTaskReview?: (version: number) => Promise<unknown> };
    windowControlsInset?: boolean;
  }) => (
    <button
      data-window-controls-inset={String(windowControlsInset)}
      onClick={() => {
        void actions.acceptTaskReview?.(2).catch(() => undefined);
      }}
      type="button"
    >
      Accept
    </button>
  ),
}));

describe("ConversationRoute", () => {
  it("delegates review acceptance to the retained conversation owner", async () => {
    harness.acceptTaskReview.mockRejectedValueOnce(new Error("conflict"));

    render(<ConversationRoute />);
    fireEvent.click(screen.getByRole("button", { name: "Accept" }));

    await waitFor(() => expect(harness.acceptTaskReview).toHaveBeenCalledWith(2));
    expect(harness.apiAcceptTaskReview).not.toHaveBeenCalled();
  });
});
