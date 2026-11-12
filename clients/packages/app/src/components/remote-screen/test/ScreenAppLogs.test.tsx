// The logs pane under a device's picture renders what the core's `devices.openScreenLogs` gives and its actions ask
// the core: lines as they come with crashes marked, App or All read anew, Pause holding lines back, Clear and Copy, a
// computer with none said so, and nothing read while it is closed.
import type { ListedScreen, ScreenLogEvent, ScreenLogLine } from "@comma/core-client";
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { copyTextToClipboard } from "../../chat/thread/inline/linkActions";
import { ScreenAppLogs } from "../ScreenAppLogs";

const SIM: ListedScreen = {
  id: "simulator:A119A827-41D5-49E0-9689-710DB19BF30E",
  instance: "i1",
  name: "applogs-test",
  title: "applogs-test · iOS 27.2",
  width: 1206,
  height: 2622,
  peek: true,
  capabilities: { input: "touch", buttons: [], panels: [], logs: true },
};

type Opened = {
  params: Record<string, unknown>;
  onEvent: (event: ScreenLogEvent) => void;
  signal: AbortSignal;
  fail: (error: { code: string; message: string }) => void;
};
const opened: Opened[] = [];
// (one client, as the app's provider gives)
const core = vi.hoisted(() => ({
  clearedTails: [] as unknown[],
  call: (
    name: string,
    params: Record<string, unknown>,
    onEvent: (event: unknown) => void,
    signal: AbortSignal
  ): Promise<unknown> => {
    if (name === "devices.clearScreenLogTail") core.clearedTails.push(params);
    if (name !== "devices.openScreenLogs") return Promise.resolve(null);
    return new Promise((_resolve, reject) => {
      opened.push({
        params,
        onEvent: onEvent as Opened["onEvent"],
        signal,
        fail: reject,
      });
    });
  },
}));
vi.mock("@comma/core-client", async (original) => ({
  ...(await original<typeof import("@comma/core-client")>()),
  useCore: () => core,
}));
vi.mock("../../chat/thread/inline/linkActions", () => ({
  copyTextToClipboard: vi.fn(() => Promise.resolve()),
}));

const line = (
  seq: number,
  text: string,
  more: Partial<ScreenLogLine> = {}
): ScreenLogLine => ({
  seq,
  at: "02:03:40.123",
  level: "Info",
  app: "LogDemo",
  pid: 41189,
  text,
  ...more,
});

function say(event: ScreenLogEvent, at = opened.length - 1) {
  act(() => opened[at]!.onEvent(event));
}

afterEach(() => {
  cleanup();
  opened.length = 0;
  vi.mocked(copyTextToClipboard).mockClear();
  localStorage.clear();
});

describe("ScreenAppLogs", () => {
  it("shows the app's lines as they come, a crash marked", async () => {
    render(<ScreenAppLogs device="dev" screen={SIM} workspace="wsp" />);
    expect(opened[0]!.params).toEqual({
      workspace: "wsp",
      device: "dev",
      screen: SIM.id,
      instance: "i1",
      mode: "app",
    });
    say({ type: "filter", mode: "app" });
    say({
      type: "lines",
      lines: [
        line(0, "tick 1"),
        line(1, "LogDemo/main.swift:35: Fatal error: LogDemo crashed on purpose", {
          level: "Default",
          crash: true,
        }),
      ],
    });
    const crashed = await screen.findByText(/Fatal error: LogDemo crashed on purpose/);
    expect(crashed.closest("li")?.dataset.crash).toBe("true");
    expect(screen.getByText(/tick 1/).closest("li")?.dataset.crash).toBeUndefined();
    expect(screen.getByTestId("remote-screen-logs-crashed")).toBeTruthy();
  });

  it("reads All anew, and its old stream ends", async () => {
    render(<ScreenAppLogs device="dev" screen={SIM} workspace="wsp" />);
    fireEvent.click(screen.getByRole("button", { name: "All" }));
    await waitFor(() => expect(opened).toHaveLength(2));
    expect(opened[0]!.signal.aborted).toBe(true);
    expect(opened[1]!.params.mode).toBe("all");
  });

  it("holds lines back while paused, and shows them once it goes on; Clear empties it; Copy copies what it shows", async () => {
    render(<ScreenAppLogs device="dev" screen={SIM} workspace="wsp" />);
    say({ type: "filter", mode: "app" });
    say({ type: "lines", lines: [line(0, "one")] });
    await screen.findByText(/one/);
    fireEvent.click(screen.getByRole("button", { name: "Pause logs" }));
    say({ type: "lines", lines: [line(1, "two")] });
    await screen.findByText(/1 new lines held/);
    expect(screen.queryByText(/two/)).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Resume logs" }));
    await screen.findByText(/two/);

    fireEvent.click(screen.getByRole("button", { name: "Copy logs" }));
    expect(copyTextToClipboard).toHaveBeenCalledWith(
      "02:03:40.123 Info LogDemo[41189]: one\n02:03:40.123 Info LogDemo[41189]: two"
    );
    fireEvent.click(screen.getByRole("button", { name: "Clear logs" }));
    await screen.findByText("Nothing logged yet");
    // What would go to a chat with the picture is cleared too.
    expect(core.clearedTails).toEqual([
      expect.objectContaining({
        device: expect.any(String),
        screen: expect.any(String),
      }),
    ]);
    // What was cleared is not shown again when the station gives it once more.
    say({ type: "lines", lines: [line(1, "two"), line(2, "three")] });
    await screen.findByText(/three/);
    expect(screen.queryByText(/two/)).toBeNull();
  });

  it("says a computer that reads no app logs has none, and asks no more", async () => {
    render(<ScreenAppLogs device="dev" screen={SIM} workspace="wsp" />);
    act(() =>
      opened[0]!.fail({
        code: "unsupported",
        message: "That computer reads no app logs.",
      })
    );
    await screen.findByText("Not available on this computer");
    expect(screen.queryByRole("button", { name: "Pause logs" })).toBeNull();
    expect(opened).toHaveLength(1);
  });

  it("reads nothing while closed, and remembers it closed", async () => {
    render(<ScreenAppLogs device="dev" screen={SIM} workspace="wsp" />);
    fireEvent.click(screen.getByRole("button", { name: /App logs/ }));
    await waitFor(() => expect(opened[0]!.signal.aborted).toBe(true));
    cleanup();
    render(<ScreenAppLogs device="dev" screen={SIM} workspace="wsp" />);
    expect(
      screen.getByRole("button", { name: /App logs/ }).getAttribute("aria-expanded")
    ).toBe("false");
    expect(opened).toHaveLength(1);
  });
});
