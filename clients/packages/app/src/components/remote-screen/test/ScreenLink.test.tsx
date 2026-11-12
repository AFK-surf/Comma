import type { ListedScreen } from "@comma/core-client";
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { installUiClock } from "@comma/ui/clock";
import { createVirtualUiClock } from "@comma/ui/clock/virtual";
import { useOptionalChatSidebar } from "../../chat-sidebar/ChatSidebarContext";
import { useOptionalCommaClientSettings } from "../../commaClientSettings";
import { ScreenLinkCard } from "../ScreenLink";
import { useOwnComputers } from "../ScreenMenus";

const EMULATOR = "android:emulator-5554";
const listed: ListedScreen = {
  id: EMULATOR,
  instance: "aaaa",
  name: "Fold",
  title: "Fold · Android 16",
  width: 1080,
  height: 2400,
  peek: true,
  capabilities: { input: "touch", buttons: ["rotate"], panels: [] },
};
const calls: {
  name: string;
  params: Record<string, unknown>;
  onEvent?: (event: unknown) => void;
  signal?: AbortSignal;
}[] = [];
let listing: ListedScreen[] = [listed];
const stillOpening = () => new Promise(() => undefined);
/** How a preview's call goes: by default it runs for as long as the view. */
let opening: (signal?: AbortSignal) => Promise<unknown> = stillOpening;
const call = vi.fn((name: string) =>
  name === "devices.listScreens"
    ? Promise.resolve({ screens: listing, avds: [] })
    : Promise.resolve(null)
);
const open = vi.fn();
vi.mock("@comma/core-client", async (original) => ({
  ...(await original<typeof import("@comma/core-client")>()),
  useCall: () => call,
  useCore: () => ({
    call: (
      name: string,
      params: Record<string, unknown>,
      onEvent?: (event: unknown) => void,
      signal?: AbortSignal
    ) => {
      calls.push({
        name,
        params,
        ...(onEvent ? { onEvent } : {}),
        ...(signal ? { signal } : {}),
      });
      return name === "devices.openScreenView"
        ? opening(signal)
        : Promise.resolve(null);
    },
  }),
}));
vi.mock("../../commaClientSettings", () => ({
  useOptionalCommaClientSettings: vi.fn(() => ({ computerMesh: "on" })),
}));
vi.mock("../../chat-sidebar/ChatSidebarContext", async (original) => ({
  ...(await original<typeof import("../../chat-sidebar/ChatSidebarContext")>()),
  useOptionalChatSidebar: vi.fn(),
}));
vi.mock("../ScreenMenus", async (original) => ({
  ...(await original<typeof import("../ScreenMenus")>()),
  useOwnComputers: vi.fn(() => []),
}));
vi.mocked(useOptionalChatSidebar).mockReturnValue({
  activeHost: { workspaceId: "wsp", groupId: "g", conversationId: "c" },
  openScreen: open,
} as never);
vi.mocked(useOwnComputers).mockReturnValue([
  { device_id: "dev", name: "Mac" },
] as never);
void useOptionalCommaClientSettings;

afterEach(() => {
  vi.unstubAllGlobals();
  cleanup();
  call.mockClear();
  calls.length = 0;
  open.mockClear();
  listing = [listed];
  opening = stillOpening;
});

const until = (what: () => boolean) => waitFor(() => expect(what()).toBe(true));

/** The page's view of what is on the screen, which the test says. */
const watched = new Set<{ target: Element; callback: IntersectionObserverCallback }>();
const shows = (inView: boolean) =>
  act(() => {
    for (const { target, callback } of watched)
      callback(
        [{ isIntersecting: inView, target } as IntersectionObserverEntry],
        {} as IntersectionObserver
      );
  });
beforeEach(() => {
  watched.clear();
  // (the page is shown)
  vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      readonly #callback: IntersectionObserverCallback;
      constructor(callback: IntersectionObserverCallback) {
        this.#callback = callback;
      }
      observe(target: Element) {
        watched.add({ target, callback: this.#callback });
        // (on the screen as it comes)
        this.#callback(
          [{ isIntersecting: true, target } as IntersectionObserverEntry],
          this as never
        );
      }
      disconnect() {}
    }
  );
  vi.stubGlobal(
    "VideoDecoder",
    class {
      state = "unconfigured";
      configure() {}
      decode() {}
      close() {
        this.state = "closed";
      }
    }
  );
});

describe("a screen's card in a message", () => {
  it.each([undefined, "FA43E77A-0A82-4850-8A7D-D22FD5CB5A0D"])(
    "shows an unavailable simulator after a cold start, then restores its name and preview (label: %s)",
    async (label) => {
      const id = "simulator:FA43E77A-0A82-4850-8A7D-D22FD5CB5A0D";
      const clock = createVirtualUiClock();
      const restore = installUiClock(clock);
      try {
        listing = [
          { ...listed, id, name: "still.fail-try", title: "still.fail-try · iOS 27.1" },
        ];
        call.mockRejectedValueOnce(new Error("station disconnected"));
        render(
          <ScreenLinkCard
            link={{ device: "dev", screen: id, label }}
            workspaceId="wsp"
          />
        );
        await act(async () => undefined);
        const card = screen.getByTestId("screen-card");
        expect(card).toHaveTextContent("iOS Simulator");
        expect(card).toHaveTextContent("Device information is unavailable");
        expect(card).not.toHaveTextContent("FA43E77A");
        expect(card).toBeDisabled();
        expect(screen.queryByTestId("screen-card-ended")).toBeNull();
        expect(calls).toEqual([]);

        await act(async () => clock.advance(5_000));
        await until(() => calls.length > 0);
        expect(screen.getByText("still.fail-try")).toBeTruthy();
        expect(screen.getByText("iOS 27.1")).toBeTruthy();
        expect(screen.getByTestId("screen-card")).toBeEnabled();
        expect(screen.getByTestId("screen-card-peek")).toBeTruthy();
        expect(screen.queryByText("Device information is unavailable")).toBeNull();
      } finally {
        cleanup();
        restore();
      }
    }
  );

  it("shows an unavailable device instead of an Android serial when its first listing fails", async () => {
    call.mockRejectedValueOnce(new Error("station disconnected"));
    render(
      <ScreenLinkCard
        link={{ device: "dev", screen: EMULATOR, label: undefined }}
        workspaceId="wsp"
      />
    );
    await act(async () => undefined);
    const card = screen.getByTestId("screen-card");
    expect(card).toHaveTextContent("Device information is unavailable");
    expect(card.querySelector("strong")).toHaveTextContent("Device");
    expect(card).not.toHaveTextContent("emulator-5554");
    expect(card).toBeDisabled();
    expect(screen.queryByTestId("screen-card-ended")).toBeNull();
  });

  it("previews a device while it is on the screen, only looking, and closes the preview off it", async () => {
    render(
      <ScreenLinkCard
        link={{ device: "dev", screen: EMULATOR, label: undefined }}
        workspaceId="wsp"
      />
    );
    await until(() => calls.length > 0);
    expect(calls.filter((one) => !one.signal!.aborted)).toHaveLength(1);
    expect(calls.at(-1)).toMatchObject({
      name: "devices.openScreenView",
      params: {
        target: EMULATOR,
        instance: "aaaa",
        control: false,
        peek: true,
        maxWidth: 640,
        maxHeight: 640,
      },
    });
    expect(screen.getByText("Fold")).toBeTruthy();
    expect(screen.getByText("Android 16")).toBeTruthy();

    await shows(false);
    await until(() => calls.every((one) => one.signal!.aborted));

    // Back on the screen: one preview again, and only one.
    await shows(true);
    await until(() => calls.some((one, i) => i > 0 && !one.signal!.aborted));
    expect(calls.filter((one) => !one.signal!.aborted)).toHaveLength(1);
  });

  it("previews a simulator as the JPEG pictures its station sends, each acknowledged as it is drawn", async () => {
    const SIMULATOR = "simulator:0702F8CC-2E2A-4D0A-8401-C37FA01E1646";
    listing = [
      { ...listed, id: SIMULATOR, title: "iPhone 17 · iOS 27.2", name: "iPhone 17" },
    ];
    const pictures: Blob[] = [];
    vi.stubGlobal("createImageBitmap", (blob: Blob) => {
      pictures.push(blob);
      return Promise.resolve({ width: 294, height: 640, close() {} });
    });
    render(
      <ScreenLinkCard
        link={{ device: "dev", screen: SIMULATOR, label: undefined }}
        workspaceId="wsp"
      />
    );
    await until(() => calls.length > 0);
    const peek = calls.at(-1)!;
    expect(peek.params).toMatchObject({
      target: SIMULATOR,
      peek: true,
      codecs: ["jpeg", "h264"],
    });
    act(() => {
      peek.onEvent!({ type: "open", view: 7 });
      peek.onEvent!({
        type: "config",
        codec: "jpeg",
        width: 294,
        height: 640,
        description: "",
      });
      peek.onEvent!({
        type: "video",
        key: true,
        ts: 1000,
        data: Uint8Array.from([0xff, 0xd8, 0xff, 0xd9]),
      });
    });
    await until(() => calls.some((one) => one.name === "devices.sendToScreenView"));
    expect(pictures.map((blob) => blob.type)).toEqual(["image/jpeg"]);
    expect(
      calls.find((one) => one.name === "devices.sendToScreenView")!.params
    ).toEqual({ view: 7, ack: 1000 });
    expect(
      screen.getByTestId("screen-card-peek").querySelector("canvas")!.dataset.drawn
    ).toBe("true");
  });

  it("starts its H.264 decoder anew in software when it fails, and asks the view for a key frame", async () => {
    const made: { init: VideoDecoderInit; config?: VideoDecoderConfig }[] = [];
    vi.stubGlobal(
      "VideoDecoder",
      class {
        static isConfigSupported = () => Promise.resolve({ supported: true });
        state = "unconfigured";
        readonly #made: (typeof made)[number];
        constructor(init: VideoDecoderInit) {
          this.#made = { init };
          made.push(this.#made);
        }
        configure(config: VideoDecoderConfig) {
          this.#made.config = config;
          this.state = "configured";
        }
        close() {
          this.state = "closed";
        }
      }
    );
    render(
      <ScreenLinkCard
        link={{ device: "dev", screen: EMULATOR, label: undefined }}
        workspaceId="wsp"
      />
    );
    await until(() => calls.length > 0);
    const peek = calls.at(-1)!;
    act(() => {
      peek.onEvent!({ type: "open", view: 7 });
      peek.onEvent!({
        type: "config",
        codec: "h264",
        width: 288,
        height: 640,
        description: "AULACv/hABVnQsAK2hHsBEAAAAMAQAAADyPEiagBAARozg/I",
      });
    });
    expect(made[0]!.config).toMatchObject({ codedWidth: 288, codedHeight: 640 });
    act(() =>
      made[0]!.init.error(new DOMException("Decoding error.", "EncodingError"))
    );
    await until(() =>
      calls.some(
        (one) => one.name === "devices.sendToScreenView" && one.params.keyframe === true
      )
    );
    expect(made).toHaveLength(2);
    expect(made[1]!.config?.hardwareAcceleration).toBe("prefer-software");
    expect(peek.signal!.aborted).toBe(false);
  });

  it("decodes two video previews on the page at once: a third lets go of its view, and asks again later", async () => {
    const devices = [
      "android:emulator-5554",
      "android:emulator-5556",
      "android:emulator-5558",
    ];
    listing = devices.map((id): ListedScreen => ({ ...listed, id }) as ListedScreen);
    render(
      <>
        {devices.map((id) => (
          <ScreenLinkCard
            key={id}
            link={{ device: "dev", screen: id, label: undefined }}
            workspaceId="wsp"
          />
        ))}
      </>
    );
    await until(
      () => calls.filter((one) => one.name === "devices.openScreenView").length === 3
    );
    const peeks = calls.filter((one) => one.name === "devices.openScreenView");
    act(() => {
      for (const [i, peek] of peeks.entries()) {
        peek.onEvent!({ type: "open", view: i });
        peek.onEvent!({
          type: "config",
          codec: "h264",
          width: 288,
          height: 640,
          description: "AULACv/hABVnQsAK2hHsBEAAAAMAQAAADyPEiagBAARozg/I",
        });
      }
    });
    expect(peeks.map((peek) => peek.signal!.aborted)).toEqual([false, false, true]);
  });

  it("says once why a preview is refused, and asks again", async () => {
    const clock = createVirtualUiClock();
    const restore = installUiClock(clock);
    const warned = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      opening = () =>
        Promise.reject(new Error("one client can preview at most 2 screens at once"));
      render(
        <ScreenLinkCard
          link={{ device: "dev", screen: EMULATOR, label: undefined }}
          workspaceId="wsp"
        />
      );
      await until(() => calls.length === 1 && warned.mock.calls.length === 1);
      expect(warned.mock.calls[0]![1]).toMatchObject({
        device: "dev",
        screen: EMULATOR,
        why: "one client can preview at most 2 screens at once",
      });
      // Its wait is on the clock the test moves.
      await until(() => clock.pending() > 0);
      act(() => clock.advance(5_000));
      await until(() => calls.length === 2);
      await act(async () => {
        await Promise.resolve();
      });
      expect(warned).toHaveBeenCalledTimes(1);
    } finally {
      cleanup();
      restore();
      warned.mockRestore();
    }
  });

  it("gives up a preview its station does not answer, says so, and asks again", async () => {
    const clock = createVirtualUiClock();
    const restore = installUiClock(clock);
    const warned = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      opening = (signal) =>
        new Promise((_, reject) =>
          signal!.addEventListener("abort", () => reject(new Error("cancelled")), {
            once: true,
          })
        );
      render(
        <ScreenLinkCard
          link={{ device: "dev", screen: EMULATOR, label: undefined }}
          workspaceId="wsp"
        />
      );
      await until(() => calls.length === 1);
      act(() => clock.advance(19_000));
      expect(calls[0]!.signal!.aborted).toBe(false);
      act(() => clock.advance(1_000));
      expect(calls[0]!.signal!.aborted).toBe(true);
      await until(() => warned.mock.calls.length === 1);
      expect(warned.mock.calls[0]![1]).toMatchObject({ why: "no answer in 20 s" });
      act(() => clock.advance(5_000));
      await until(() => calls.length === 2);
      // Open in time, it stays.
      act(() => calls[1]!.onEvent!({ type: "open", view: 1 }));
      act(() => clock.advance(30_000));
      expect(calls[1]!.signal!.aborted).toBe(false);
    } finally {
      cleanup();
      restore();
      warned.mockRestore();
    }
  });

  it("opens the device in a tab of the side panel on a press", async () => {
    render(
      <ScreenLinkCard
        link={{ device: "dev", screen: EMULATOR, label: "The phone" }}
        workspaceId="wsp"
      />
    );
    await until(() => calls.length > 0);
    screen.getByText("The phone").click();
    expect(open).toHaveBeenCalledWith(
      { workspaceId: "wsp", groupId: "g", conversationId: "c" },
      { workspaceId: "wsp", device: "dev", apps: [], screen: listed }
    );
  });

  it("shows a display with no preview, and asks nothing that would wake its adb or its display", async () => {
    render(
      <ScreenLinkCard
        link={{ device: "dev", screen: "display", label: undefined }}
        workspaceId="wsp"
      />
    );
    expect(screen.getByText("Mac")).toBeTruthy();
    expect(screen.queryByTestId("screen-card-peek")).toBeNull();
    expect(calls).toEqual([]);
    expect(call).not.toHaveBeenCalledWith("devices.listScreens", expect.anything());
    screen.getByText("Mac").click();
    expect(open).toHaveBeenCalledWith(expect.anything(), {
      workspaceId: "wsp",
      device: "dev",
      apps: [],
      target: "display",
    });
  });

  it("marks an expired boot as ended instead of offering the device that replaced it", async () => {
    const clock = createVirtualUiClock();
    const restore = installUiClock(clock);
    try {
      render(
        <ScreenLinkCard
          link={{ device: "dev", screen: EMULATOR, label: "The phone" }}
          workspaceId="wsp"
        />
      );
      await until(() => calls.length > 0);
      listing = [{ ...listed, instance: "bbbb", name: "Pixel" }];
      await act(async () => {
        clock.advance(5_000);
      });
      await until(() => screen.queryByTestId("screen-card") === null);
      expect(screen.getByTestId("screen-card-ended")).toHaveTextContent("Screen ended");
      expect(screen.queryByText("Pixel")).toBeNull();
      await until(() => calls.every((one) => one.signal!.aborted));
    } finally {
      cleanup();
      restore();
    }
  });

  it("keeps an inert placeholder when a successful listing no longer includes the device", async () => {
    listing = [];
    render(
      <>
        <p>The simulator was opened.</p>
        <ScreenLinkCard
          link={{ device: "dev", screen: EMULATOR, label: "The phone" }}
          workspaceId="wsp"
        />
        <p>The build finished.</p>
      </>
    );
    await until(() => call.mock.calls.length > 0);
    await until(() => screen.queryByTestId("screen-card") === null);
    expect(screen.getByTestId("screen-card-ended")).toHaveTextContent("Screen ended");
    expect(screen.queryByRole("button")).toBeNull();
    expect(screen.queryByText(EMULATOR)).toBeNull();
    expect(screen.queryByText("The phone")).toBeNull();
    expect(screen.getByText("The simulator was opened.")).toBeTruthy();
    expect(screen.getByText("The build finished.")).toBeTruthy();
    expect(calls).toEqual([]);
  });

  it("keeps the last card during a failed listing, then marks it ended when the station confirms it is gone", async () => {
    const clock = createVirtualUiClock();
    const restore = installUiClock(clock);
    try {
      render(
        <ScreenLinkCard
          link={{ device: "dev", screen: EMULATOR, label: "The phone" }}
          workspaceId="wsp"
        />
      );
      await until(() => calls.length > 0);
      listing = [];
      call.mockRejectedValueOnce(new Error("station disconnected"));
      await act(async () => {
        clock.advance(5_000);
      });
      expect(screen.getByTestId("screen-card")).toBeTruthy();
      expect(screen.getByText("The phone")).toBeTruthy();
      await act(async () => {
        clock.advance(5_000);
      });
      await until(() => screen.queryByTestId("screen-card") === null);
      expect(screen.getByTestId("screen-card-ended")).toHaveTextContent("Screen ended");
    } finally {
      cleanup();
      restore();
    }
  });
});
