import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { act, cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, expect, it, vi } from "vitest";
import { userEvent } from "vitest/browser";
import {
  ChatSidebarProvider,
  screenPageId,
  useChatSidebar,
  type ChatSidebarContextValue,
  type ChatSidebarScreenPage,
} from "../../chat-sidebar/ChatSidebarContext";
import { DeviceScreenPanel } from "../DeviceScreenPanel";
import { ScreenWindowHost } from "../ScreenWindowHost";
import { openMeshScreenStream } from "../meshScreenStream";
import type { ScreenStreamSource } from "../ScreenStreamStage";
import {
  closeScreenWindows,
  openScreenWindow,
  screenWindowKey,
  screenWindowSize,
} from "../screenWindows";

vi.mock("../meshScreenStream", () => ({ openMeshScreenStream: vi.fn() }));
vi.mock("../useDeviceScreenSource", () => ({ useDeviceScreenSource: () => source }));

const source: ScreenStreamSource = {
  key: "workspace\ndevice\nwindow",
  view: { open: () => new Promise(() => undefined), send: () => undefined },
};

const target = { workspaceId: "workspace", device: "device", apps: ["Safari"] };
const page: ChatSidebarScreenPage = { ...target, id: screenPageId(target) };
const host = { workspaceId: "workspace", groupId: "group", conversationId: "chat" };

afterEach(() => {
  closeScreenWindows();
  cleanup();
});

/** Until a document shows a video, then its effects (the stream reaching the video) have run. */
async function untilVideo(document: Document) {
  while (!document.querySelector("video"))
    await new Promise<void>((resolve) => {
      const seen = new MutationObserver(() => {
        seen.disconnect();
        resolve();
      });
      seen.observe(document, { childList: true, subtree: true });
    });
  await act(async () => undefined);
  return document.querySelector("video")!;
}

/** The Watch or Control a document's screen panel is in. */
const inControl = (document: Document) =>
  document.querySelector(
    '[data-testid="remote-screen-panel"] button[aria-pressed="true"]'
  )?.textContent;
/** Until a document shows a screen panel, then its effects have run. */
const panelReady = async (document: Document) => {
  while (!document.querySelector('[data-testid="remote-screen-panel"]'))
    await new Promise<void>((resolve) => {
      const seen = new MutationObserver(() => {
        seen.disconnect();
        resolve();
      });
      seen.observe(document, { childList: true, subtree: true });
    });
  await act(async () => undefined);
  return document;
};

/** A press on an element of a screen's own window, then what it brings about. */
async function press(element: Element | null | undefined) {
  (element as HTMLElement).click();
  await act(async () => undefined);
}

function Sidebar({ onSidebar }: { onSidebar(sidebar: ChatSidebarContextValue): void }) {
  onSidebar(useChatSidebar());
  return null;
}

it("moves a screen to a window of its own on the same stream, brings that window forward when opened again, and takes it back", async () => {
  const opened: Parameters<typeof openMeshScreenStream>[0][] = [];
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    opened.push(peer);
    return { send: () => undefined, close: () => undefined };
  });
  const open = vi.spyOn(window, "open");
  let sidebar: ChatSidebarContextValue | undefined;
  const core = createScriptedCore({ values: () => undefined });
  const view = render(
    core.wrap(
      <ChatSidebarProvider>
        <Sidebar onSidebar={(value) => (sidebar = value)} />
        <div style={{ display: "flex", width: 480, height: 360 }}>
          <DeviceScreenPanel active page={page} />
        </div>
        <ScreenWindowHost />
      </ChatSidebarProvider>
    )
  );
  const canvas = document.createElement("canvas");
  canvas.getContext("2d")!.fillRect(0, 0, 300, 150);
  const media = canvas.captureStream(0);
  act(() => {
    opened[0]!.onStream(media);
    opened[0]!.onState("live");
  });

  const toolbar = view
    .getByTestId("remote-screen-panel")
    .querySelector("header")!
    .getBoundingClientRect().height;
  await userEvent.click(view.getByRole("button", { name: "Open in window" }));
  expect(open).toHaveBeenCalledTimes(1);
  // A new window: the picture (2:1) 960 wide under the toolbar, named for this screen; Main places it.
  const [, name, features] = open.mock.calls[0]!;
  expect(features).toBe(`popup,width=960,height=${480 + Math.round(toolbar)}`);
  expect(name).toMatch(
    new RegExp(`^comma-screen:[0-9a-f-]{36}:${screenWindowKey(page.id)}$`)
  );
  const child = open.mock.results[0]!.value as Window;
  // The window shows the screen from this page's stream: no other stream opened.
  expect((await untilVideo(child.document)).srcObject).toBe(media);
  expect(opened).toHaveLength(1);
  expect(child.document.title).toBe("Safari");
  // Its look is the app's: the app's style sheets came with it.
  expect(child.getComputedStyle(child.document.body).overflow).toBe("hidden");
  // The tab says where the screen is, and can bring it forward.
  view.getByText("Shown in its own window");
  expect(document.querySelector("video")).toBeNull();

  // Opened again, from the panel or from a link anywhere in the app: that window comes forward, and no other opens.
  const focus = vi.spyOn(child, "focus");
  await userEvent.click(view.getByRole("button", { name: "Show window" }));
  expect(focus).toHaveBeenCalledTimes(1);
  act(() => sidebar!.openScreen(host, target));
  expect(focus).toHaveBeenCalledTimes(2);
  expect(openScreenWindow(page)).toBe(true);
  expect(focus).toHaveBeenCalledTimes(3);
  expect(open).toHaveBeenCalledTimes(1);
  expect(sidebar!.activeSession?.screenPages ?? []).toHaveLength(0);

  // Moved back, the panel shows it again on the same stream.
  await userEvent.click(view.getByRole("button", { name: "Move back to panel" }));
  expect((await untilVideo(document)).srcObject).toBe(media);
  expect(child.closed).toBe(true);
  expect(opened).toHaveLength(1);

  // Closed by the person, the window gives the screen back as well.
  await userEvent.click(view.getByRole("button", { name: "Open in window" }));
  const again = open.mock.results[1]!.value as Window;
  await untilVideo(again.document);
  again.close();
  expect((await untilVideo(document)).srcObject).toBe(media);
});

it("keeps Watch or Control as the screen moves to its window and back, by either way back", async () => {
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    queueMicrotask(() => peer.onState("live"));
    return { send: () => undefined, close: () => undefined };
  });
  const open = vi.spyOn(window, "open");
  const core = createScriptedCore({ values: () => undefined });
  const view = render(
    core.wrap(
      <ChatSidebarProvider>
        <div style={{ display: "flex", width: 480, height: 360 }}>
          <DeviceScreenPanel active page={page} />
        </div>
        <ScreenWindowHost />
      </ChatSidebarProvider>
    )
  );
  await userEvent.click(view.getByRole("button", { name: "Control" }));
  expect(inControl(document)).toBe("Control");
  await userEvent.click(view.getByRole("button", { name: "Open in window" }));
  const child = await panelReady((open.mock.results.at(-1)!.value as Window).document);
  expect(inControl(child)).toBe("Control");

  // Back by the side panel's button: still in Control.
  await userEvent.click(view.getByRole("button", { name: "Move back to panel" }));
  expect(inControl(await panelReady(document))).toBe("Control");

  // Watch goes to the window, and back by its close button.
  await userEvent.click(view.getByRole("button", { name: "Watch" }));
  await userEvent.click(view.getByRole("button", { name: "Open in window" }));
  const again = open.mock.results.at(-1)!.value as Window;
  expect(inControl(await panelReady(again.document))).toBe("Watch");
  [...again.document.querySelectorAll("button")]
    .find((button) => button.textContent === "Control")!
    .click();
  await act(async () => undefined);
  expect(inControl(again.document)).toBe("Control");
  again.close();
  expect(inControl(await panelReady(document))).toBe("Control");

  // Shown anew later (its tab closed and opened again), it starts in Watch.
  view.unmount();
  render(
    core.wrap(
      <ChatSidebarProvider>
        <DeviceScreenPanel active page={page} />
      </ChatSidebarProvider>
    )
  );
  expect(inControl(await panelReady(document))).toBe("Watch");
});

it("shuts a device down from its own window, which then goes", async () => {
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    queueMicrotask(() => peer.onState("live"));
    return { send: () => undefined, close: () => undefined };
  });
  const open = vi.spyOn(window, "open");
  const simulator = {
    id: "simulator:A",
    instance: "A/boot",
    name: "iPhone 18 Pro",
    title: "iPhone 18 Pro · iOS 27.0",
    width: 390,
    height: 844,
    peek: true,
    capabilities: { input: "touch", buttons: [], panels: [], closable: true },
  } as unknown as NonNullable<ChatSidebarScreenPage["screen"]>;
  const shown = {
    workspaceId: "workspace",
    device: "device",
    apps: [],
    screen: simulator,
  };
  const core = createScriptedCore({
    values: () => undefined,
    calls: (name) =>
      name === "devices.listScreens"
        ? { screens: [simulator], avds: [], simulators: [] }
        : {},
  });
  const view = render(
    core.wrap(
      <ChatSidebarProvider>
        <div style={{ display: "flex", width: 480, height: 360 }}>
          <DeviceScreenPanel active page={{ ...shown, id: screenPageId(shown) }} />
        </div>
        <ScreenWindowHost />
      </ChatSidebarProvider>
    )
  );
  await userEvent.click(view.getByRole("button", { name: "Open in window" }));
  const child = open.mock.results.at(-1)!.value as Window;
  const inWindow = await panelReady(child.document);
  // The window shows its one screen: its menu has no other to choose, and still shuts the device down.
  await press(inWindow.querySelector('[data-testid="remote-screen-computers"]'));
  const rows = [...inWindow.querySelectorAll('[role="menuitem"]')];
  expect(rows.map((row) => row.textContent)).toEqual(["Shut down iPhone 18 Pro"]);
  await press(rows[0]);
  await press(
    [...inWindow.querySelectorAll("button")].find(
      (button) => button.textContent === "Close device"
    )
  );
  // Shut down, its window goes.
  await untilVideo(document);
  expect(child.closed).toBe(true);
  expect(core.sentTo("devices.closeScreenDevice")).toEqual([
    {
      workspace: "workspace",
      device: "device",
      screen: "simulator:A",
      instance: "A/boot",
    },
  ]);
});

it("sizes a new screen window by its picture: 960 on the long side, under the toolbar", () => {
  expect(screenWindowSize(16 / 9, 48)).toEqual({ width: 960, height: 540 + 48 });
  // A phone stands: its long side is its height.
  expect(screenWindowSize(9 / 19.5, 48)).toEqual({ width: 443, height: 960 + 48 });
  // No picture yet: a 16:10 display.
  expect(screenWindowSize(undefined, 0)).toEqual({ width: 960, height: 600 });
});
