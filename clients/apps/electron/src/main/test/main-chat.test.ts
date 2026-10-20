import type { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it, vi } from "vitest";
import { MainChat } from "../modules/chat";

describe("Main's chat client", () => {
  it("tells a core that started again the device ids and language it told the one before", async () => {
    let rejoined: (() => void) | undefined;
    const call = vi.fn(async () => null);
    const client = {
      call,
      onRejoin: (listener: () => void) => {
        rejoined = listener;
        return () => undefined;
      },
    } as unknown as CoreClient;
    const chat = new MainChat(() => client);
    chat.setClientDevices({ wsp_1: "dev_1" });
    chat.setLocale("zh-CN");
    expect(call.mock.calls).toEqual([
      ["chat.clientDevices", { devices: { wsp_1: "dev_1" } }],
      ["chat.locale", { locale: "zh-CN" }],
    ]);
    call.mockClear();
    // The core's process restarted: it knows neither.
    rejoined?.();
    expect(call.mock.calls).toEqual([
      ["chat.clientDevices", { devices: { wsp_1: "dev_1" } }],
      ["chat.locale", { locale: "zh-CN" }],
    ]);
  });
});
