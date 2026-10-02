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
    expect(platform.register).toHaveBeenCalledWith("Alt+,", open);
    platform.register.mock.calls[0]![1]();
    expect(open).toHaveBeenCalledOnce();
    shortcut.set(null);
    expect(platform.unregister).toHaveBeenCalledExactlyOnceWith("Alt+,");
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
    expect(platform.unregister).toHaveBeenCalledExactlyOnceWith("Alt+,");
    shortcut.dispose();
    expect(platform.unregister).toHaveBeenLastCalledWith("Alt+K");
  });

  it("lets the chord's keys through while suspended and holds it again after", () => {
    const platform = {
      register: vi.fn((_accelerator: string, _callback: () => void) => true),
      unregister: vi.fn(),
    };
    const shortcut = new OpenCommaShortcut(platform, vi.fn());
    shortcut.set(defaultOpenCommaShortcut);
    shortcut.setSuspended(true);
    expect(platform.unregister).toHaveBeenCalledExactlyOnceWith("Alt+,");

    // A new chord chosen meanwhile is checked, then waits for the suspension.
    shortcut.set({ ...defaultOpenCommaShortcut, key: "k" });
    expect(platform.register).toHaveBeenLastCalledWith("Alt+K", expect.any(Function));
    expect(platform.unregister).toHaveBeenLastCalledWith("Alt+K");
    expect(platform.unregister).toHaveBeenCalledTimes(2);

    expect(shortcut.setSuspended(false)).toBe(true);
    expect(platform.register).toHaveBeenCalledTimes(3);
    expect(platform.register).toHaveBeenLastCalledWith("Alt+K", expect.any(Function));
    shortcut.dispose();
    expect(platform.unregister).toHaveBeenLastCalledWith("Alt+K");
  });

  it("reports a chord another app took while it was suspended", () => {
    const platform = {
      register: vi.fn((_accelerator: string, _callback: () => void) => true),
      unregister: vi.fn(),
    };
    const shortcut = new OpenCommaShortcut(platform, vi.fn());
    shortcut.set(defaultOpenCommaShortcut);
    shortcut.setSuspended(true);
    platform.register.mockReturnValueOnce(false);
    expect(shortcut.setSuspended(false)).toBe(false);
    // Set again, it is tried again.
    shortcut.set(defaultOpenCommaShortcut);
    expect(platform.register).toHaveBeenLastCalledWith("Alt+,", expect.any(Function));
    expect(platform.register).toHaveBeenCalledTimes(3);
  });
});
