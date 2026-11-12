import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { RIGHT_SIDEBAR_MIN_WIDTH } from "@comma/ui/components/right-sidebar";
import { afterEach, expect, it, vi } from "vitest";
import { userEvent } from "vitest/browser";
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

afterEach(cleanup);

/** A button's background once its colour transition has run. */
async function background(button: HTMLElement) {
  await Promise.all(button.getAnimations().map((animation) => animation.finished));
  return getComputedStyle(button).backgroundColor;
}

it("keeps the chosen one of Watch and Control looking chosen while the pointer is on it", async () => {
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    queueMicrotask(() => peer.onState("live"));
    return { send: () => undefined, close: () => undefined };
  });
  const view = render(
    createScriptedCore({ values: () => undefined }).wrap(
      <ChatSidebarProvider>
        <div style={{ display: "flex", width: 640, height: 360 }}>
          <DeviceScreenPanel active page={page} />
        </div>
      </ChatSidebarProvider>
    )
  );
  const watch = view.getByRole("button", { name: "Watch" });
  const control = view.getByRole("button", { name: "Control" });
  await userEvent.click(control);
  expect(control).toHaveAttribute("aria-pressed", "true");

  // The pointer on Watch: Control looks chosen, unlike Watch.
  await userEvent.hover(watch);
  await userEvent.unhover(watch);
  const chosen = await background(control);
  expect(chosen).not.toBe(await background(watch));

  // The pointer on Control: it still does.
  await userEvent.hover(control);
  expect(await background(control)).toBe(chosen);
});

it("keeps Watch and every other control of the toolbar in a panel as narrow as the sidebar goes", async () => {
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    queueMicrotask(() => peer.onState("live"));
    return { send: () => undefined, close: () => undefined };
  });
  const view = render(
    createScriptedCore({ values: () => undefined }).wrap(
      <ChatSidebarProvider>
        <div style={{ display: "flex", width: RIGHT_SIDEBAR_MIN_WIDTH, height: 360 }}>
          <DeviceScreenPanel active page={page} />
        </div>
      </ChatSidebarProvider>
    )
  );
  // Control taken, Watch is still there to go back to.
  await userEvent.click(view.getByRole("button", { name: "Control" }));
  await userEvent.click(view.getByRole("button", { name: "Watch" }));
  expect(view.getByRole("button", { name: "Watch" })).toHaveAttribute(
    "aria-pressed",
    "true"
  );

  // Nothing on the bar reaches past the panel's sides, where it could not be pressed.
  const panel = view.getByTestId("remote-screen-panel");
  const { left, right } = panel.getBoundingClientRect();
  const outside = [...panel.querySelectorAll("header button")].flatMap((button) => {
    const box = button.getBoundingClientRect();
    return box.left < left || box.right > right
      ? [button.getAttribute("aria-label") ?? button.textContent]
      : [];
  });
  expect(outside).toEqual([]);
  // The name is whole: the bar gives it a row.
  const name = panel.querySelector(".comma-remote-screen-title strong")!;
  expect(name.scrollWidth).toBeLessThanOrEqual(name.clientWidth);
});
