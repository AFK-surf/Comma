import { describe, expect, it, vi } from "vitest";
import {
  allowedRendererOrigins,
  installSessionSecurity,
  installWindowSecurity,
  isAllowedUrl,
} from "../security";

describe("Electron security guards", () => {
  it("allows only packaged and configured dev renderer navigation origins", () => {
    const origins = new Set(allowedRendererOrigins("http://127.0.0.1:5173/some/path"));

    expect(isAllowedUrl("assets://./", origins)).toBe(true);
    expect(isAllowedUrl("assets://./settings", origins)).toBe(true);
    expect(isAllowedUrl("http://127.0.0.1:5173/app", origins)).toBe(true);
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
});
