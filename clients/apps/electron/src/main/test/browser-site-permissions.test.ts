import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Session, WebContents } from "electron";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  BrowserSitePermissions,
  type SitePermissionPlatform,
  type SitePermissionChoice,
} from "../modules/browser-sidebar/site-permissions";

const roots: string[] = [];
afterEach(() =>
  roots.splice(0).forEach((root) => rmSync(root, { recursive: true, force: true }))
);
function harness(filePath?: string) {
  let check!: Exclude<Parameters<Session["setPermissionCheckHandler"]>[0], null>;
  let request!: Exclude<Parameters<Session["setPermissionRequestHandler"]>[0], null>;
  const session = {
    setPermissionCheckHandler: vi.fn((fn: typeof check | null) => {
      check = fn!;
    }),
    setPermissionRequestHandler: vi.fn((fn: typeof request | null) => {
      request = fn!;
    }),
  };
  const platform: SitePermissionPlatform = {
    prompt: vi.fn(async () => "allow" as const),
    settings: vi.fn(async () => undefined),
    hasSystemAccess: () => true,
    ensureSystemAccess: vi.fn(async () => true),
    reportError: vi.fn(),
  };
  const service = new BrowserSitePermissions(platform, filePath);
  service.install(session);
  let id = 0;
  function tab(url = "https://meet.google.com/abc-defg-hij") {
    const events = new EventEmitter();
    let destroyed = false;
    const contents = Object.assign(events, {
      id: ++id,
      getURL: () => url,
      isDestroyed: () => destroyed,
      reload: vi.fn(),
      navigate(next: string) {
        events.emit("did-start-navigation", {}, next, false, true);
        url = next;
      },
      destroy() {
        destroyed = true;
        events.emit("destroyed");
      },
    });
    service.register(contents, {}, () => !destroyed);
    const ask = (types: ("audio" | "video")[] = ["audio"], extras = {}) =>
      new Promise<boolean>((resolve) =>
        request(contents as unknown as WebContents, "media", resolve, {
          isMainFrame: true,
          requestingUrl: url,
          mediaTypes: types,
          ...extras,
        })
      );
    return {
      contents,
      ask,
      check: (mediaType: "audio" | "video" = "audio") =>
        check(contents as unknown as WebContents, "media", new URL(url).origin, {
          isMainFrame: true,
          mediaType,
        }),
    };
  }
  /** Holds the next prompt open: `shown` once it is up, `answer` to close it. */
  function holdPrompt() {
    const shown = Promise.withResolvers<void>();
    let answer!: (choice: SitePermissionChoice) => void;
    vi.mocked(platform.prompt).mockImplementationOnce(() => {
      shown.resolve();
      return new Promise((resolve) => {
        answer = resolve;
      });
    });
    return {
      shown: shown.promise,
      answer: (choice: SitePermissionChoice) => answer(choice),
    };
  }
  return { tab, platform, service, session, holdPrompt, request: () => request };
}

describe("website microphone and camera permissions", () => {
  it("asks before allowing and persists independent choices for the exact origin", async () => {
    const dir = mkdtempSync(join(tmpdir(), "comma-site-permissions-"));
    roots.push(dir);
    const path = join(dir, "permissions.json");
    const h = harness(path);
    const tab = h.tab();
    expect(tab.check()).toBe(false);
    expect(await tab.ask()).toBe(true);
    expect(h.platform.prompt).toHaveBeenCalledWith(
      expect.objectContaining({
        origin: "https://meet.google.com",
        media: ["microphone"],
      })
    );
    expect(tab.check()).toBe(true);
    expect(tab.check("video")).toBe(false);
    expect(await tab.ask()).toBe(true);
    expect(h.platform.prompt).toHaveBeenCalledTimes(1);
    const reopened = harness(path);
    expect(reopened.tab().check()).toBe(true);
    expect(reopened.tab("https://accounts.google.com/").check()).toBe(false);
  });
  it("remembers Block, leaves dismissal as Ask, and never bypasses OS denial", async () => {
    const h = harness();
    const tab = h.tab();
    vi.mocked(h.platform.prompt)
      .mockResolvedValueOnce("ask")
      .mockResolvedValueOnce("block");
    expect(await tab.ask()).toBe(false);
    expect(h.service.choices("https://meet.google.com").microphone).toBe("ask");
    expect(await tab.ask()).toBe(false);
    expect(await tab.ask()).toBe(false);
    expect(h.platform.prompt).toHaveBeenCalledTimes(2);
    const other = h.tab("https://other.example/");
    vi.mocked(h.platform.ensureSystemAccess).mockResolvedValue(false);
    expect(await other.ask(["audio", "video"])).toBe(false);
    expect(h.platform.ensureSystemAccess).toHaveBeenCalledWith(expect.anything(), [
      "microphone",
      "camera",
    ]);
  });
  it("rejects HTTP, subframes, mismatched origins, unknown media and unmanaged popups", async () => {
    const h = harness();
    const tab = h.tab();
    expect(await h.tab("http://meet.google.com/").ask()).toBe(false);
    expect(await tab.ask(["audio"], { isMainFrame: false })).toBe(false);
    expect(await tab.ask(["audio"], { requestingUrl: "https://other.example/" })).toBe(
      false
    );
    expect(await tab.ask([])).toBe(false);
    const callback = vi.fn();
    h.request()({ id: 999 } as WebContents, "media", callback, {
      isMainFrame: true,
      requestingUrl: "https://meet.google.com/",
      mediaTypes: ["audio"],
    });
    expect(callback).toHaveBeenCalledWith(false);
    expect(h.platform.prompt).not.toHaveBeenCalled();
  });
  it("cancels on reload, navigation and close without saving a stale Allow", async () => {
    for (const action of ["reload", "navigate", "close"] as const) {
      const h = harness();
      const tab = h.tab();
      const prompt = h.holdPrompt();
      const pending = tab.ask();
      await prompt.shown;
      if (action === "close") tab.contents.destroy();
      else
        tab.contents.navigate(
          action === "reload" ? tab.contents.getURL() : "https://other.example/"
        );
      expect(await pending).toBe(false);
      prompt.answer("allow");
      // Prompts take turns, so the next tab is asked only after the stale
      // Allow has settled; it would not be asked at all had that Allow saved.
      vi.mocked(h.platform.prompt).mockResolvedValueOnce("ask");
      expect(await h.tab().ask()).toBe(false);
      expect(h.platform.prompt).toHaveBeenCalledTimes(2);
      expect(h.service.choices("https://meet.google.com").microphone).toBe("ask");
    }
  });
  it("serializes prompts and refuses duplicate outstanding requests from a tab", async () => {
    const h = harness();
    const first = h.tab();
    const second = h.tab("https://second.example/");
    const prompt = h.holdPrompt();
    const one = first.ask();
    const two = second.ask();
    await prompt.shown;
    expect(h.platform.prompt).toHaveBeenCalledTimes(1);
    expect(await first.ask()).toBe(false);
    prompt.answer("allow");
    expect(await one).toBe(true);
    expect(await two).toBe(true);
    expect(h.platform.prompt).toHaveBeenCalledTimes(2);
    h.service.install(h.session);
    expect(h.session.setPermissionRequestHandler).toHaveBeenCalledTimes(1);
  });
  it("bounds pending prompts at 32 tabs and denies overflow without another dialog", async () => {
    const h = harness();
    const prompt = h.holdPrompt();
    const tabs = Array.from({ length: 33 }, (_, index) =>
      h.tab(`https://site-${index}.example/`)
    );
    const pending = tabs.slice(0, 32).map((tab) => tab.ask());
    await prompt.shown;
    expect(h.platform.prompt).toHaveBeenCalledTimes(1);
    expect(await tabs[32]!.ask()).toBe(false);
    tabs.forEach((tab) => tab.contents.destroy());
    expect(await Promise.all(pending)).toEqual(Array(32).fill(false));
    prompt.answer("ask");
  });

  it("settings change and reset decisions; pending prompts cannot undo a reset", async () => {
    const h = harness();
    const tab = h.tab();
    vi.mocked(h.platform.settings).mockImplementation(async ({ site }) => {
      site!.change("camera", "block");
      return undefined;
    });
    await h.service.showSettings(tab.contents);
    expect(await tab.ask(["video"])).toBe(false);
    const prompt = h.holdPrompt();
    const pending = tab.ask();
    await prompt.shown;
    vi.mocked(h.platform.settings).mockImplementation(async ({ site }) => {
      site!.reset();
      site!.reload();
      return undefined;
    });
    await h.service.showSettings(tab.contents);
    prompt.answer("allow");
    expect(await pending).toBe(false);
    expect(h.service.choices("https://meet.google.com")).toEqual({
      microphone: "ask",
      camera: "ask",
    });
    expect(tab.contents.reload).toHaveBeenCalledOnce();
  });

  it("opens the page menu on a non-HTTPS page without site permissions and returns the pick", async () => {
    const h = harness();
    const tab = h.tab("http://example.com/page");
    vi.mocked(h.platform.settings).mockResolvedValue("open-external");
    expect(await h.service.showSettings(tab.contents)).toEqual({
      status: "opened",
      picked: "open-external",
    });
    expect(vi.mocked(h.platform.settings).mock.calls[0]![0].site).toBeUndefined();
  });
});
