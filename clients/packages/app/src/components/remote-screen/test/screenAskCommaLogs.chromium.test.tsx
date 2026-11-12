import { act, cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, expect, it, vi } from "vitest";
import {
  DraftSelectionsProvider,
  useConversationDraftSelections,
  type ChatDraftSelection,
} from "../../chat/composer/draftSelections";
import {
  ChatSidebarProvider,
  screenPageId,
  useChatSidebar,
  useRegisterChatSidebarHost,
  type ChatSidebarContextValue,
  type ChatSidebarScreenPage,
} from "../../chat-sidebar/ChatSidebarContext";
import { DeviceScreenPanel } from "../DeviceScreenPanel";
import type { ScreenSelection } from "../ScreenFrameMark";

const chat = vi.hoisted(() => ({
  ask: undefined as
    | undefined
    | ((selection: ScreenSelection, name: string) => Promise<void>),
}));

// The panel is the frame's side; here it only hands a selection to what asks Comma.
vi.mock("../ScreenStreamPanel", () => ({
  ScreenStreamPanel: (props: { onAskComma: typeof chat.ask }) => {
    chat.ask = props.onAskComma;
    return null;
  },
}));
vi.mock("../useDeviceScreenSource", () => ({ useDeviceScreenSource: () => ({}) }));
vi.mock("../useScreenListing", async (actual) => ({
  ...(await actual<typeof import("../useScreenListing")>()),
  useScreenListing: () => ({ read: false, screens: [] }),
}));
vi.mock("@tanstack/react-router", async (actual) => ({
  ...(await actual<typeof import("@tanstack/react-router")>()),
  useNavigate: () => () => Promise.resolve(),
}));
vi.mock("../../chat/ChatProvider", async (actual) => {
  const registry = {
    beginAttempt: () => ({
      signal: new AbortController().signal,
      isCurrent: () => true,
      release: () => undefined,
      run: <T,>(operation: (signal: AbortSignal) => T) =>
        Promise.resolve(operation(new AbortController().signal)),
    }),
    getHomeConversationTarget: () => undefined,
  };
  return {
    ...(await actual<typeof import("../../chat/ChatProvider")>()),
    useOptionalChatRegistry: () => registry,
  };
});

const host = { workspaceId: "workspace", groupId: "group", conversationId: "chat" };

/** What waits in the chat's composer, as the panel staged it. */
let staged: readonly ChatDraftSelection[] = [];

afterEach(() => {
  cleanup();
  staged = [];
});

function Sidebar({ onSidebar }: { onSidebar(sidebar: ChatSidebarContextValue): void }) {
  useRegisterChatSidebarHost(host);
  onSidebar(useChatSidebar());
  return null;
}

/** The chat's composer, as far as these tests look: what is staged for its next message. */
function Staged() {
  staged = useConversationDraftSelections(host.conversationId).items;
  return null;
}

/** A device's page; `logs`: what its station lists. */
const devicePage = (logs: boolean): Omit<ChatSidebarScreenPage, "id"> => ({
  workspaceId: "workspace",
  device: "mac",
  apps: [],
  target: "display",
  screen: {
    id: "android:emulator-5554",
    instance: "i1",
    title: "Pixel",
    capabilities: { input: "touch", ...(logs ? { logs: true } : {}) },
  } as unknown as ChatSidebarScreenPage["screen"],
});

/** Asks Comma about a device's screen with a picture, the core answering its calls with `calls`. */
async function ask(
  page: Omit<ChatSidebarScreenPage, "id">,
  calls: (name: string) => unknown
) {
  let sidebar: ChatSidebarContextValue | undefined;
  const core = createScriptedCore({ values: () => undefined, calls });
  render(
    core.wrap(
      <ChatSidebarProvider>
        <DraftSelectionsProvider>
          <Sidebar onSidebar={(value) => (sidebar = value)} />
          <Staged />
          <DeviceScreenPanel active page={{ ...page, id: screenPageId(page) }} />
        </DraftSelectionsProvider>
      </ChatSidebarProvider>
    )
  );
  act(() => sidebar!.openScreen(host, page));
  await act(() =>
    chat.ask!(
      {
        picture: Promise.resolve(new Blob(["png"], { type: "image/png" })),
        thumbnail: undefined,
        note: "What happened?",
      },
      "Pixel"
    )
  );
  expect(staged).toHaveLength(1);
  const [selection] = staged;
  if (selection!.about.kind !== "screen") throw new Error("Not a screen's selection.");
  return { core, selection: selection!, files: selection!.about.files ?? [] };
}

it("stages the app's recent lines as a file with the picture, when the screen has logs", async () => {
  const { files } = await ask(devicePage(true), (name) =>
    name === "devices.screenLogTail"
      ? {
          lines: [
            {
              seq: 1,
              at: "10:00:01",
              level: "Error",
              app: "Orders",
              text: "payment failed",
            },
            { seq: 2, at: "10:00:02", level: "Info", app: "Orders", text: "retrying" },
          ],
        }
      : null
  );
  expect(files).toHaveLength(1);
  const [file] = files;
  expect(file!.name).toBe("app-logs.txt");
  expect(new TextDecoder().decode(file!.bytes)).toBe(
    "10:00:01 Error Orders: payment failed\n10:00:02 Info Orders: retrying"
  );
});

it("stages only the picture where the screen lists no logs, or none were read", async () => {
  const older = await ask(devicePage(false), () => null);
  expect(older.files).toEqual([]);
  expect(older.core.sentTo("devices.screenLogTail")).toEqual([]);
  cleanup();
  const unread = await ask(devicePage(true), (name) =>
    name === "devices.screenLogTail" ? { lines: [] } : null
  );
  expect(unread.files).toEqual([]);
});

it("still stages the picture, with what was written about it, when the logs cannot be read", async () => {
  const { files, selection } = await ask(devicePage(true), (name) => {
    if (name === "devices.screenLogTail") throw new Error("gone");
    return null;
  });
  expect(files).toEqual([]);
  expect(selection.picture?.type).toBe("image/png");
  expect(selection.note).toBe("What happened?");
});
