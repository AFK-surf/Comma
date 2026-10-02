import { act, renderHook } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { describe, expect, it } from "vitest";
import {
  ChatSidebarProvider,
  useChatSidebar,
  useRegisterChatSidebarHost,
  type ChatSidebarContextValue,
} from "../ChatSidebarContext";

const host = { workspaceId: "workspace", groupId: "group", conversationId: "host" };

const tabCases: {
  name: string;
  open: (sidebar: ChatSidebarContextValue) => void;
  close: (sidebar: ChatSidebarContextValue) => void;
}[] = [
  {
    name: "browser",
    open: (sidebar) => sidebar.addBrowserTab(host),
    close: (sidebar) =>
      sidebar.closeBrowserPage(host, sidebar.activeSession!.browserPages[0]!.id),
  },
  {
    name: "chat",
    open: (sidebar) =>
      sidebar.openChat(host, { ...host, conversationId: "child", kind: "agent_task" }),
    close: (sidebar) => sidebar.closeChat(host),
  },
  {
    name: "Drive preview",
    open: (sidebar) => sidebar.openDrivePreview(host, { id: "file", name: "File" }),
    close: (sidebar) => sidebar.closeDrivePreview(host, "file"),
  },
  {
    name: "session history",
    open: (sidebar) =>
      sidebar.openSessionHistory(host, {
        groupId: host.groupId,
        participant: {
          conversationId: "child",
          participantId: "worker",
          name: "Worker",
        },
      }),
    close: (sidebar) =>
      sidebar.closeHistoryPage(host, sidebar.activeSession!.historyPages![0]!.id),
  },
];

function useRegisteredSidebar() {
  useRegisterChatSidebarHost(host);
  return useChatSidebar();
}

describe("sidebar tab closing", () => {
  it.each(tabCases)("collapses after the last $name tab closes", ({ open, close }) => {
    installNativeBridgeMock({ platform: "web" });
    const { result } = renderHook(useRegisteredSidebar, {
      wrapper: ChatSidebarProvider,
    });
    act(() => open(result.current));
    expect(result.current.isOpen).toBe(true);
    act(() => close(result.current));
    expect(result.current.isOpen).toBe(false);
    act(() => open(result.current));
    expect(result.current.isOpen).toBe(true);
  });

  it("keeps other tabs and another host's sidebar open", () => {
    installNativeBridgeMock({ platform: "web" });
    const { result } = renderHook(useRegisteredSidebar, {
      wrapper: ChatSidebarProvider,
    });
    const otherHost = { ...host, conversationId: "other" };
    act(() => {
      result.current.addBrowserTab(host);
      result.current.openDrivePreview(host, { id: "file", name: "File" });
      result.current.openDrivePreview(otherHost, {
        id: "other-file",
        name: "Other file",
      });
    });
    act(() => result.current.closeDrivePreview(otherHost, "other-file"));
    expect(result.current.isOpen).toBe(true);
    act(() => result.current.closeDrivePreview(host, "file"));
    expect(result.current.isOpen).toBe(true);
    expect(result.current.activeSession?.activeSurface).toBe("browser");
    act(() =>
      result.current.closeBrowserPage(
        host,
        result.current.activeSession!.browserPages[0]!.id
      )
    );
    expect(result.current.isOpen).toBe(false);
  });
});
