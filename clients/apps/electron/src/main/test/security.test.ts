import { describe, expect, it, vi } from "vitest";
import type { Session } from "electron";
import {
  allowedRendererOrigins,
  installDynamicUiNetworkSecurity,
  installSessionSecurity,
  installWindowSecurity,
  isAllowedUrl,
} from "../security";

describe("Electron security guards", () => {
  it("allows only packaged and configured dev renderer navigation origins", () => {
    const origins = new Set(
      allowedRendererOrigins("https://vite.comma.test/some/path")
    );

    expect(isAllowedUrl("assets://./", origins)).toBe(true);
    expect(isAllowedUrl("assets://./settings", origins)).toBe(true);
    expect(isAllowedUrl("https://vite.comma.test/app", origins)).toBe(true);
    expect(isAllowedUrl("https://example.com/phish", origins)).toBe(false);
  });

  it("denies window-open by default and blocks unallowlisted navigation", () => {
    const on = vi.fn();
    const setWindowOpenHandler = vi.fn();
    const logger = { warn: vi.fn() };

    installWindowSecurity({
      logger,
      webContents: { on, setWindowOpenHandler },
    });

    const openHandler = setWindowOpenHandler.mock.calls[0]?.[0] as (details: {
      url: string;
    }) => { action: "allow" | "deny" };
    const navigateHandler = on.mock.calls[0]?.[1] as (
      event: { preventDefault: () => void },
      url: string
    ) => void;
    const preventDefault = vi.fn();

    expect(openHandler({ url: "https://example.com" })).toEqual({
      action: "deny",
    });
    navigateHandler({ preventDefault }, "https://example.com");

    expect(on).toHaveBeenCalledWith("will-navigate", expect.any(Function));
    expect(preventDefault).toHaveBeenCalled();
    expect(logger.warn).toHaveBeenCalledWith("Blocked renderer window-open request.", {
      url: "https://example.com",
    });
  });

  it("denies session permission requests and synchronous checks by default", () => {
    const setPermissionCheckHandler = vi.fn();
    const setPermissionRequestHandler = vi.fn();

    installSessionSecurity({ setPermissionCheckHandler, setPermissionRequestHandler });

    const requestHandler = setPermissionRequestHandler.mock.calls[0]?.[0] as (
      webContents: unknown,
      permission: string,
      callback: (permissionGranted: boolean) => void
    ) => void;
    const checkHandler = setPermissionCheckHandler.mock.calls[0]?.[0] as (
      webContents: unknown,
      permission: string
    ) => boolean;
    const callback = vi.fn();

    requestHandler({}, "media", callback);

    expect(callback).toHaveBeenCalledWith(false);
    expect(checkHandler({}, "media")).toBe(false);
  });

  it("grants the device permissions of Comma apps to the app's own top frame alone", () => {
    const setPermissionCheckHandler = vi.fn();
    const setPermissionRequestHandler = vi.fn();
    installSessionSecurity(
      { setPermissionCheckHandler, setPermissionRequestHandler },
      { appOrigins: ["assets://."] }
    );
    const requestHandler = setPermissionRequestHandler.mock.calls[0]?.[0] as (
      webContents: unknown,
      permission: string,
      callback: (permissionGranted: boolean) => void,
      details: Record<string, unknown>
    ) => void;
    const answer = (permission: string, details: Record<string, unknown>) => {
      let granted: boolean | undefined;
      requestHandler({}, permission, (value) => (granted = value), details);
      return granted;
    };
    const app = { isMainFrame: true, requestingUrl: "assets://./index.html" };

    expect(answer("media", { ...app, mediaTypes: ["audio"] })).toBe(true);
    expect(answer("media", { ...app, mediaTypes: ["audio", "video"] })).toBe(true);
    expect(answer("midi", app)).toBe(true);
    expect(answer("fullscreen", app)).toBe(true);
    // A remote screen in full screen takes Escape for the computer it controls.
    expect(answer("keyboardLock", app)).toBe(true);
    expect(answer("keyboardLock", { ...app, isMainFrame: false })).toBe(false);
    expect(answer("screen-wake-lock", app)).toBe(true);
    // No media type, a frame inside the page, another origin, or another permission: refused.
    expect(answer("media", { ...app, mediaTypes: [] })).toBe(false);
    expect(answer("media", { ...app, isMainFrame: false, mediaTypes: ["audio"] })).toBe(
      false
    );
    expect(answer("midi", { ...app, isMainFrame: false })).toBe(false);
    expect(
      answer("media", {
        isMainFrame: true,
        mediaTypes: ["audio"],
        requestingUrl: "https://example.com/",
      })
    ).toBe(false);
    // Electron reports all MIDI requests as midiSysex. The SDK requests no system exclusive messages.
    expect(answer("midiSysex", app)).toBe(true);
    expect(answer("midiSysex", { ...app, isMainFrame: false })).toBe(false);
    // The page's media check, so it sees the devices' names: its top frame alone.
    const checkHandler = setPermissionCheckHandler.mock.calls[0]?.[0] as (
      webContents: unknown,
      permission: string,
      requestingOrigin: string,
      details: Record<string, unknown>
    ) => boolean;
    const check = (permission: string, details: Record<string, unknown>) =>
      checkHandler({}, permission, "assets://.", details);
    expect(check("media", { ...app, mediaType: "audio" })).toBe(true);
    expect(check("media", { ...app, isMainFrame: false, mediaType: "audio" })).toBe(
      false
    );
    expect(
      check("media", {
        isMainFrame: true,
        mediaType: "audio",
        requestingUrl: "https://example.com/",
      })
    ).toBe(false);
    expect(check("midi", app)).toBe(false);
    expect(answer("display-capture", app)).toBe(false);
    expect(answer("geolocation", app)).toBe(true);
    expect(answer("geolocation", { ...app, isMainFrame: false })).toBe(false);
  });

  it("allows USB checks only for a mini-app frame embedded in a Comma page", () => {
    const setPermissionCheckHandler = vi.fn();
    installSessionSecurity(
      { setPermissionCheckHandler, setPermissionRequestHandler: vi.fn() },
      { appOrigins: ["assets://."] }
    );
    const check = setPermissionCheckHandler.mock.calls[0]![0];
    const contents = { getURL: () => "assets://./index.html" };
    const frame = { isMainFrame: false, requestingUrl: "comma-app://runtime/" };
    expect(check(contents, "usb", "null", frame)).toBe(true);
    expect(
      check(contents, "usb", "null", { ...frame, requestingUrl: "comma-ui://runtime/" })
    ).toBe(false);
    expect(check({ getURL: () => "https://other.test/" }, "usb", "null", frame)).toBe(
      false
    );
    expect(
      check(contents, "usb", "assets://.", {
        isMainFrame: true,
        requestingUrl: "assets://./index.html",
      })
    ).toBe(false);
  });

  it("lets a Comma app frame load only the runtime, blob: and data: URLs", () => {
    let beforeRequest:
      | ((
          details: Record<string, unknown>,
          callback: (response: { cancel: boolean }) => void
        ) => void)
      | undefined;
    const webRequest = {
      onBeforeRequest: vi.fn((listener: typeof beforeRequest) => {
        beforeRequest = listener;
      }),
      onBeforeSendHeaders: vi.fn(),
      onCompleted: vi.fn(),
      onErrorOccurred: vi.fn(),
    };
    installDynamicUiNetworkSecurity({ webRequest } as unknown as Session);
    const frame = {
      url: "comma-app://runtime/",
      parent: { url: "assets://./", parent: null },
    };
    const cancelled = (details: Record<string, unknown>) => {
      let result: boolean | undefined;
      beforeRequest!({ id: 1, resourceType: "xhr", ...details }, ({ cancel }) => {
        result = cancel;
      });
      return result;
    };

    expect(cancelled({ url: "comma-app://runtime/", frame: frame.parent })).toBe(false);
    expect(cancelled({ url: "comma-app://runtime/other" })).toBe(true);
    expect(cancelled({ url: "blob:null/1", frame })).toBe(false);
    expect(cancelled({ url: "data:image/png;base64,AA==", frame })).toBe(false);
    for (const url of [
      "https://example.com/",
      "http://127.0.0.1/",
      "ws://127.0.0.1/",
      "assets://./v1/comma/workspaces",
    ])
      expect(cancelled({ url, frame })).toBe(true);
    // A frame inside the app frame, and a request that names it as referrer.
    expect(
      cancelled({
        url: "https://example.com/",
        frame: { url: "about:blank", parent: frame },
      })
    ).toBe(true);
    expect(
      cancelled({ url: "https://example.com/", referrer: "comma-app://runtime/" })
    ).toBe(true);
    // The Comma renderer itself is not held.
    expect(cancelled({ url: "https://example.com/", frame: frame.parent })).toBe(false);
  });

  it("blocks a Comma app frame's own navigation and redirects", () => {
    const on = vi.fn();
    installWindowSecurity({ webContents: { on, setWindowOpenHandler: vi.fn() } });
    const handler = (name: string) =>
      on.mock.calls.find(([event]) => event === name)?.[1] as (
        event: Record<string, unknown>
      ) => void;
    const navigate = {
      preventDefault: vi.fn(),
      frame: { url: "comma-app://runtime/" },
    };
    handler("will-frame-navigate")(navigate);
    const redirect = { preventDefault: vi.fn(), url: "comma-app://runtime/" };
    handler("will-redirect")(redirect);

    expect(navigate.preventDefault).toHaveBeenCalled();
    expect(redirect.preventDefault).toHaveBeenCalled();
  });
});

it("routes App window-open and navigation requests to Main and prevents browser navigation", async () => {
  const { dispatchMiniAppRunLink } = await import("../mini-app-link");
  const routes: string[] = [];
  const on = vi.fn();
  const setWindowOpenHandler = vi.fn();
  installWindowSecurity({
    handleAppLink: (url) =>
      dispatchMiniAppRunLink(
        url,
        [],
        (route) => routes.push(route),
        () => {}
      ),
    webContents: { on, setWindowOpenHandler },
  });
  const url = "https://app.comma.surf/#/apps/another/app/run?version=3";
  const open = setWindowOpenHandler.mock.calls[0]![0];
  expect(open({ url })).toEqual({ action: "deny" });
  const navigate = on.mock.calls.find(([name]) => name === "will-navigate")![1];
  const preventDefault = vi.fn();
  navigate({ preventDefault }, url);
  expect(preventDefault).toHaveBeenCalledOnce();
  expect(routes).toEqual([
    "/apps/another/app/run?version=3",
    "/apps/another/app/run?version=3",
  ]);
});
