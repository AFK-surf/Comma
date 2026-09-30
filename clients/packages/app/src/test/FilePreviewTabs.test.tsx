import { act, renderHook } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { describe, expect, it } from "vitest";
import {
  ChatSidebarProvider,
  useChatSidebar,
  useRegisterChatSidebarHost,
} from "../components/chat-sidebar/ChatSidebarContext";
import {
  conversationFileSourceKey,
  type ConversationFileSource,
} from "../runtime-files/fileSources";

const host = {
  workspaceId: "workspace",
  groupId: "host-group",
  conversationId: "router",
};
const source: ConversationFileSource = {
  groupId: "worker-group",
  conversationId: "worker",
  messageId: "message",
  attachmentIndex: 1,
  fileName: "report.pdf",
};

describe("file preview tabs", () => {
  it("deduplicates by original file identity and retains at most 32 descriptors without reading bytes", () => {
    installNativeBridgeMock({ platform: "web" });
    const { result } = renderHook(
      () => {
        useRegisterChatSidebarHost(host);
        return useChatSidebar();
      },
      { wrapper: ChatSidebarProvider }
    );
    act(() => result.current.openFilePreview(host, source));
    act(() => result.current.openFilePreview(host, source));
    expect(result.current.activeSession?.filePreviews).toEqual([
      { id: conversationFileSourceKey(source), source },
    ]);
    for (let index = 0; index < 32; index += 1) {
      act(() =>
        result.current.openFilePreview(host, {
          ...source,
          messageId: `message-${index}`,
        })
      );
    }
    const previews = result.current.activeSession!.filePreviews!;
    expect(previews).toHaveLength(32);
    expect(previews[0]!.source.messageId).toBe("message-0");
    expect(result.current.activeSession?.activeFilePreviewId).toBe(previews.at(-1)!.id);
    act(() => result.current.closeFilePreview(host, previews.at(-1)!.id));
    expect(result.current.activeSession?.activeFilePreviewId).toBe(previews.at(-2)!.id);
    expect(result.current.activeSession?.activeSurface).toBe("file");
  });
});
