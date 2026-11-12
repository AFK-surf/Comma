import { afterEach, describe, expect, it, vi } from "vitest";
import { keepFullScreenInStep } from "../full-screen-in-step";

function window() {
  const listeners = new Map<string, (() => void)[]>();
  const shown = {
    webContents: {
      executeJavaScript: vi.fn(async (_code: string): Promise<unknown> => false),
    },
    on: (event: string, listener: () => void) =>
      void listeners.set(event, [...(listeners.get(event) ?? []), listener]),
    emit: (...events: string[]) =>
      events.forEach((event) =>
        listeners.get(event)?.forEach((listener) => listener())
      ),
    isDestroyed: () => false,
    getSize: () => [800, 520],
    setSize: vi.fn(),
    isFullScreen: () => true,
    setFullScreen: vi.fn(),
  };
  keepFullScreenInStep(shown);
  return shown;
}

/** The page's answer to the window's last question, and what the window did with it. */
async function answered(shown: ReturnType<typeof window>) {
  await shown.webContents.executeJavaScript.mock.results.at(-1)?.value;
  await Promise.resolve();
}

describe("keepFullScreenInStep", () => {
  afterEach(() => void vi.useRealTimers());

  it("tells a page that left full screen during the window's way in that it is out, once the window is", async () => {
    const shown = window();

    // Left in step: nothing to tell.
    shown.emit("enter-html-full-screen", "leave-html-full-screen", "leave-full-screen");
    await answered(shown);
    expect(shown.setSize).not.toHaveBeenCalled();

    // Left during the window's transition: the page still thinks it fills the screen, and a resize tells it. The size
    // goes back at once.
    shown.webContents.executeJavaScript.mockResolvedValue(true);
    shown.emit("enter-html-full-screen", "leave-html-full-screen", "leave-full-screen");
    await answered(shown);
    expect(shown.setSize.mock.calls).toEqual([
      [801, 520],
      [800, 520],
    ]);

    // Main still has the page in full screen: not for this to change.
    shown.setSize.mockClear();
    shown.emit("enter-html-full-screen", "leave-full-screen");
    await answered(shown);
    expect(shown.setSize).not.toHaveBeenCalled();
  });

  it("ends a native full screen the page asked for and left before the window got there", () => {
    // (Main's next turn, where the window is taken out: a fake one)
    vi.useFakeTimers({ toFake: ["setImmediate"] });
    const shown = window();

    // The page's own, and the person's (the green button): kept.
    shown.emit(
      "enter-html-full-screen",
      "enter-full-screen",
      "leave-html-full-screen",
      "leave-full-screen",
      "enter-full-screen"
    );
    vi.runAllTimers();
    expect(shown.setFullScreen).not.toHaveBeenCalled();

    // Asked again on the way out, and taken out by Electron as the way out ended: the window comes out too.
    shown.emit(
      "leave-full-screen",
      "enter-html-full-screen",
      "leave-html-full-screen",
      "enter-full-screen"
    );
    vi.runAllTimers();
    expect(shown.setFullScreen).toHaveBeenCalledExactlyOnceWith(false);
  });

  it("keeps the person's native full screen when the page filled the screen inside it and left", () => {
    vi.useFakeTimers({ toFake: ["setImmediate"] });
    const shown = window();

    // The person's full screen; the page fills it and leaves (no transition of the window's), then the person leaves
    // full screen and goes back in.
    shown.emit(
      "enter-full-screen",
      "enter-html-full-screen",
      "leave-html-full-screen",
      "leave-full-screen",
      "enter-full-screen"
    );
    vi.runAllTimers();
    expect(shown.setFullScreen).not.toHaveBeenCalled();
  });
});
