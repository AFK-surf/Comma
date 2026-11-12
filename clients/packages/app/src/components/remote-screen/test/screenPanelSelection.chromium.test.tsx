import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { act, cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { RightSidebar } from "@comma/ui/components/right-sidebar";
import { afterEach, expect, it, vi } from "vitest";
import { commands } from "vitest/browser";
import {
  ChatSidebarProvider,
  screenPageId,
  type ChatSidebarScreenPage,
} from "../../chat-sidebar/ChatSidebarContext";
import { DeviceScreenPanel } from "../DeviceScreenPanel";
import { openMeshScreenStream } from "../meshScreenStream";
import type { ScreenStreamSource } from "../ScreenStreamStage";

vi.mock("../meshScreenStream", () => ({ openMeshScreenStream: vi.fn() }));
vi.mock("../useDeviceScreenSource", () => ({ useDeviceScreenSource: () => source }));

const source: ScreenStreamSource = {
  key: "workspace\ndevice\ndisplay",
  view: { open: () => new Promise(() => undefined), send: () => undefined },
};
const target = { workspaceId: "workspace", device: "device", apps: ["Safari"] };
const page: ChatSidebarScreenPage = { ...target, id: screenPageId(target) };

/** The text a person would copy now. */
const selected = () => document.getSelection()?.toString() ?? "";

afterEach(() => {
  document.getSelection()?.removeAllRanges();
  cleanup();
});

it("selects none of a screen's tab, header or toolbar by a drag over the picture or a select-all", async () => {
  const opened: Parameters<typeof openMeshScreenStream>[0][] = [];
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    opened.push(peer);
    return { send: () => undefined, close: () => undefined };
  });
  const view = render(
    createScriptedCore({ values: () => undefined }).wrap(
      <ChatSidebarProvider>
        <RightSidebar
          activeTab="screen"
          ariaLabel="Chat sidebar"
          onTabChange={() => undefined}
          onWidthChange={() => undefined}
          open
          tabs={[{ id: "screen", label: "still.fail-try", panelId: "screen-panel" }]}
          width={640}
        >
          <div id="screen-panel" style={{ display: "flex", height: 400 }}>
            <DeviceScreenPanel active page={page} />
          </div>
        </RightSidebar>
      </ChatSidebarProvider>
    )
  );
  const canvas = document.createElement("canvas");
  canvas.getContext("2d")!.fillRect(0, 0, 300, 150);
  act(() => {
    opened[0]!.onStream(canvas.captureStream(0));
    opened[0]!.onState("live");
  });
  const chrome = ["still.fail-try", "Safari", "Watch", "Control"];

  // In Watch, a drag from the picture up past the tabs.
  const picture = view.container.querySelector("video")!.getBoundingClientRect();
  const tab = view.getByRole("tab", { name: "still.fail-try" }).getBoundingClientRect();
  await commands.mouseMove(picture.right - 8, picture.bottom - 8);
  await commands.mouseDown();
  await commands.mouseMove(tab.left - 4, tab.top + tab.height / 2, 10);
  await commands.mouseUp();
  for (const text of chrome) expect(selected()).not.toContain(text);

  // Select all, as Ctrl+A on the page does.
  document.getSelection()!.selectAllChildren(view.container);
  for (const text of chrome) expect(selected()).not.toContain(text);
});
