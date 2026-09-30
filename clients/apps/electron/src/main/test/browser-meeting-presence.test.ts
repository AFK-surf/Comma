import { describe, expect, it, vi } from "vitest";
import {
  BrowserMeetingProbe,
  googleMeetRoom,
  type BrowserMeetingPage,
} from "../modules/browser-sidebar/meeting-presence";

function page(id: string, joined = false, visible = false): BrowserMeetingPage {
  return {
    id,
    tabId: id,
    visible,
    contents: {
      getOSProcessId: () => 42,
      getURL: () => "https://meet.google.com/abc-defg-hij",
      isDestroyed: () => false,
      executeJavaScript: vi.fn(async () => joined),
    },
  };
}

describe("in-app meeting observation", () => {
  it("admits only exact HTTPS Meet room URLs", () => {
    expect(googleMeetRoom("https://meet.google.com/abc-defg-hij?authuser=0")).toBe(
      "/abc-defg-hij"
    );
    for (const url of [
      "https://meet.google.com/",
      "https://meet.google.com/landing",
      "http://meet.google.com/abc-defg-hij",
      "https://meet.google.com.evil.test/abc-defg-hij",
    ])
      expect(googleMeetRoom(url)).toBeUndefined();
  });

  it("ignores the lobby and tracks simultaneous joined tabs independently", async () => {
    const probe = new BrowserMeetingProbe();
    expect(await probe.read([page("lobby")])).toEqual([]);
    const a = page("a", true),
      b = page("b", true);
    expect(await probe.read([a, b])).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: "a:/abc-defg-hij", tabId: "a" }),
        expect.objectContaining({ id: "b:/abc-defg-hij", tabId: "b" }),
      ])
    );
    expect(await probe.read([b])).toMatchObject([{ id: "b:/abc-defg-hij" }]);
    b.contents.executeJavaScript = vi.fn(async () => false);
    expect(await probe.read([b])).toEqual([]);
  });

  it("bounds each tick to four page reads and still discovers background meetings", async () => {
    const probe = new BrowserMeetingProbe();
    const pages = Array.from({ length: 32 }, (_, i) =>
      page(String(i), i === 31, i === 0)
    );
    let found: Awaited<ReturnType<BrowserMeetingProbe["read"]>> = [];
    for (let tick = 0; tick < 12 && !found?.length; tick++) {
      pages.forEach((p) => vi.mocked(p.contents.executeJavaScript).mockClear());
      found = await probe.read(pages);
      expect(
        pages.reduce(
          (count, p) =>
            count + vi.mocked(p.contents.executeJavaScript).mock.calls.length,
          0
        )
      ).toBeLessThanOrEqual(4);
    }
    expect(found?.[0]?.id).toBe("31:/abc-defg-hij");
    expect((await probe.read(pages))[0]?.id).toBe(found?.[0]?.id);
  });

  it("drops a joined result when the tab navigates or is destroyed during observation", async () => {
    const probe = new BrowserMeetingProbe();
    const tab = page("tab", true);
    tab.contents.executeJavaScript = async () => {
      tab.contents.getURL = () => "https://example.com";
      return true;
    };
    expect(await probe.read([tab])).toEqual([]);
    const closed = page("closed", true);
    closed.contents.executeJavaScript = async () => {
      closed.contents.isDestroyed = () => true;
      return true;
    };
    expect(await probe.read([closed])).toEqual([]);
  });

  it("does not reuse a delayed old room result after navigation", async () => {
    vi.useFakeTimers();
    try {
      const probe = new BrowserMeetingProbe();
      const tab = page("tab");
      let finish!: (joined: boolean) => void;
      tab.contents.executeJavaScript = vi.fn(
        () =>
          new Promise((resolve) => {
            finish = resolve;
          })
      );
      const first = probe.read([tab]);
      await vi.advanceTimersByTimeAsync(750);
      expect(await first).toEqual([]);
      tab.contents.getURL = () => "https://meet.google.com/klm-nopq-rst";
      const second = probe.read([tab]);
      finish(true);
      expect(await second).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("does not accumulate reads when a page is unresponsive", async () => {
    vi.useFakeTimers();
    try {
      const probe = new BrowserMeetingProbe();
      const tab = page("stuck");
      tab.contents.executeJavaScript = vi.fn(() => new Promise(() => {}));
      for (let i = 0; i < 3; i++) {
        const read = probe.read([tab]);
        await vi.advanceTimersByTimeAsync(750);
        expect(await read).toEqual([]);
      }
      expect(tab.contents.executeJavaScript).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });
});
