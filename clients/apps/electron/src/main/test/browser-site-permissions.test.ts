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
    settings: vi.fn(async () => {}),
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
  return { tab, platform, service, session, request: () => request };
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
      let finish!: (choice: SitePermissionChoice) => void;
      vi.mocked(h.platform.prompt).mockImplementation(
        () =>
          new Promise((resolve) => {
            finish = resolve;
          })
      );
      const pending = tab.ask();
      await vi.waitFor(() => expect(h.platform.prompt).toHaveBeenCalled());
      if (action === "close") tab.contents.destroy();
      else
        tab.contents.navigate(
          action === "reload" ? tab.contents.getURL() : "https://other.example/"
        );
      expect(await pending).toBe(false);
      finish("allow");
      await new Promise((resolve) => setImmediate(resolve));
      expect(h.service.choices("https://meet.google.com").microphone).toBe("ask");
    }
  });
  it("serializes prompts and refuses duplicate outstanding requests from a tab", async () => {
    const h = harness();
    const first = h.tab();
    const second = h.tab("https://second.example/");
    let finish!: (choice: SitePermissionChoice) => void;
    vi.mocked(h.platform.prompt).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    const one = first.ask();
    const two = second.ask();
    await vi.waitFor(() => expect(h.platform.prompt).toHaveBeenCalledTimes(1));
    expect(await first.ask()).toBe(false);
    finish("allow");
    expect(await one).toBe(true);
    expect(await two).toBe(true);
    expect(h.platform.prompt).toHaveBeenCalledTimes(2);
    h.service.install(h.session);
    expect(h.session.setPermissionRequestHandler).toHaveBeenCalledTimes(1);
  });
  it("bounds pending prompts at 32 tabs and denies overflow without another dialog", async () => {
    const h = harness();
    let finish!: (choice: SitePermissionChoice) => void;
    vi.mocked(h.platform.prompt).mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    const tabs = Array.from({ length: 33 }, (_, index) =>
      h.tab(`https://site-${index}.example/`)
    );
    const pending = tabs.slice(0, 32).map((tab) => tab.ask());
    await vi.waitFor(() => expect(h.platform.prompt).toHaveBeenCalledTimes(1));
    expect(await tabs[32]!.ask()).toBe(false);
    tabs.forEach((tab) => tab.contents.destroy());
    expect(await Promise.all(pending)).toEqual(Array(32).fill(false));
    finish("ask");
  });

  it("settings change and reset decisions; pending prompts cannot undo a reset", async () => {
    const h = harness();
    const tab = h.tab();
    vi.mocked(h.platform.settings).mockImplementation(async ({ change }) =>
      change("camera", "block")
    );
    await h.service.showSettings(tab.contents);
    expect(await tab.ask(["video"])).toBe(false);
    let finish!: (choice: SitePermissionChoice) => void;
    vi.mocked(h.platform.prompt).mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    const pending = tab.ask();
    await vi.waitFor(() => expect(h.platform.prompt).toHaveBeenCalled());
    vi.mocked(h.platform.settings).mockImplementation(async ({ reset, reload }) => {
      reset();
      reload();
    });
    await h.service.showSettings(tab.contents);
    finish("allow");
    expect(await pending).toBe(false);
    expect(h.service.choices("https://meet.google.com")).toEqual({
      microphone: "ask",
      camera: "ask",
    });
    expect(tab.contents.reload).toHaveBeenCalledOnce();
  });
});
