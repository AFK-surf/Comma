import { describe, expect, it, vi } from "vitest";
import { defaultOpenCommaShortcut } from "@comma/native-bridge";
import { OpenCommaShortcut } from "../open-comma-shortcut";

describe("OpenCommaShortcut", () => {
  it("opens Comma from the registered default and releases only its own binding", () => {
    const open = vi.fn();
    const platform = {
      register: vi.fn((_accelerator: string, _callback: () => void) => true),
      unregister: vi.fn(),
    };
    const shortcut = new OpenCommaShortcut(platform, open);
    shortcut.set(defaultOpenCommaShortcut);
    expect(platform.register).toHaveBeenCalledWith("Alt+Space", open);
    platform.register.mock.calls[0]![1]();
    expect(open).toHaveBeenCalledOnce();
    shortcut.set(null);
    expect(platform.unregister).toHaveBeenCalledExactlyOnceWith("Alt+Space");
    shortcut.dispose();
    expect(platform.unregister).toHaveBeenCalledOnce();
  });

  it("retains the current registration when a replacement is occupied", () => {
    const platform = {
      register: vi.fn((_accelerator: string, _callback: () => void) => true),
      unregister: vi.fn(),
    };
    const shortcut = new OpenCommaShortcut(platform, vi.fn());
    shortcut.set(defaultOpenCommaShortcut);
    platform.register.mockReturnValueOnce(false);
    expect(() => shortcut.set({ ...defaultOpenCommaShortcut, key: "k" })).toThrow(
      "unavailable"
    );
    expect(platform.unregister).not.toHaveBeenCalled();
    shortcut.set({ ...defaultOpenCommaShortcut, key: "k" });
    expect(platform.unregister).toHaveBeenCalledExactlyOnceWith("Alt+Space");
    shortcut.dispose();
    expect(platform.unregister).toHaveBeenLastCalledWith("Alt+K");
  });
});
