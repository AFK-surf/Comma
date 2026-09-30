import { describe, expect, it } from "vitest";
import { createSenderPolicy } from "../modules/ipc";

describe("createSenderPolicy", () => {
  it("allows the packaged assets origin", () => {
    const policy = createSenderPolicy({
      devOrigins: [],
      isDevelopment: false,
    });

    expect(
      policy.allow({
        caller: {
          origin: "assets://.",
          role: "main-window",
          webContentsId: 1,
          windowId: "win_main",
        },
        channel: "comma:native:info",
        event: {},
      })
    ).toBe(true);
  });

  it("allows configured dev server origins only in development", () => {
    const devPolicy = createSenderPolicy({
      devOrigins: ["http://127.0.0.1:5173"],
      isDevelopment: true,
    });
    const prodPolicy = createSenderPolicy({
      devOrigins: ["http://127.0.0.1:5173"],
      isDevelopment: false,
    });
    const caller = {
      origin: "http://127.0.0.1:5173",
      role: "main-window" as const,
      webContentsId: 1,
      windowId: "win_main",
    };

    expect(devPolicy.allow({ caller, channel: "comma:native:info", event: {} })).toBe(
      true
    );
    expect(prodPolicy.allow({ caller, channel: "comma:native:info", event: {} })).toBe(
      false
    );
  });
});
