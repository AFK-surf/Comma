import { cleanup, render } from "@comma/test-utils/render";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  screenPageId,
  useOptionalChatSidebar,
} from "../../chat-sidebar/ChatSidebarContext";
import { openComputerUseSession } from "../computerUseSession";
import { FocusComputerUseScreen } from "../WorkerComputerUseScreen";

vi.mock("../../activeWorkspace", () => ({ useActiveWorkspaceId: () => "wsp_1" }));
vi.mock("../../chat-sidebar/ChatSidebarContext", async (actual) => ({
  ...(await actual<object>()),
  useOptionalChatSidebar: vi.fn(),
}));
vi.mock("../../chat/ChatProvider", () => ({ useChatProductLease: () => ({}) }));
vi.mock("../../commaClientSettings", () => ({
  useOptionalCommaClientSettings: () => ({ computerUseScreenEnabled: true }),
}));
vi.mock("../../chat/session-history/useSessionHistory", () => ({
  useSessionHistory: () => ({ snapshot: null }),
}));
vi.mock("../computerUseSession", () => ({ openComputerUseSession: vi.fn() }));
vi.mock("../ScreenStreamWindow", () => ({
  ScreenStreamWindow: () => <div data-testid="screen-card" />,
}));
vi.mock("../useDeviceScreenSource", () => ({ useDeviceScreenSource: () => ({}) }));

const page = { device: "dev_1", apps: ["Calculator"] };
const opened = { ...page, id: screenPageId(page), workspaceId: "wsp_1" };
const showsCard = (isOpen: boolean, activeSession: unknown) => {
  vi.mocked(useOptionalChatSidebar).mockReturnValue({
    activeSession,
    isOpen,
  } as never);
  return (
    render(
      <FocusComputerUseScreen conversationId="cnv" groupId="grp" participantId="me" />
    ).queryByTestId("screen-card") !== null
  );
};

describe("the card beside the panel", () => {
  afterEach(cleanup);
  beforeEach(() => {
    vi.mocked(openComputerUseSession).mockReturnValue(page as never);
  });

  it("does not pop out over the conversation while the panel shows another tab", () => {
    expect(showsCard(true, { activeSurface: "chat", screenPages: [opened] })).toBe(
      false
    );
  });

  it("shows the screen when the panel is closed or has no tab for it", () => {
    expect(showsCard(false, { screenPages: [opened] })).toBe(true);
    cleanup();
    expect(showsCard(true, { screenPages: [] })).toBe(true);
  });
});
