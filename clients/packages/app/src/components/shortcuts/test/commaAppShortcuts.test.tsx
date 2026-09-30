import { act, renderHook } from "@testing-library/react";
import { chordKeybinding, sequenceKeybinding } from "@comma/ui";
import { afterEach, describe, expect, it } from "vitest";
import {
  createDefaultAppShortcutBindings,
  type AppShortcutPlatform,
} from "../appShortcutRegistry";
import { CommaAppShortcutsProvider, useCommaAppShortcuts } from "../commaAppShortcuts";
import {
  CommaWebClientSettingsProvider,
  commaClientSettingsStorageKey,
} from "../../commaClientSettings";
import { legacyCommaAppShortcutsStorageKey } from "../../readLegacyCommaClientSettings";

const wrapperFor = (platform: AppShortcutPlatform) =>
  function PlatformShortcutsProvider({ children }: { children: React.ReactNode }) {
    return (
      <CommaWebClientSettingsProvider>
        <CommaAppShortcutsProvider platform={platform}>
          {children}
        </CommaAppShortcutsProvider>
      </CommaWebClientSettingsProvider>
    );
  };

const readStoredOverrides = () =>
  JSON.parse(localStorage.getItem(commaClientSettingsStorageKey)!).appShortcutOverrides;

describe("commaAppShortcuts", () => {
  afterEach(() => {
    localStorage.clear();
  });

  it("persists customized bindings and rejects conflicts", () => {
    const { result } = renderHook(() => useCommaAppShortcuts(), {
      wrapper: wrapperFor("macos"),
    });

    act(() => {
      expect(
        result.current.setBinding("go-inbox", sequenceKeybinding("KeyG", "KeyX"))
      ).toBe(true);
    });

    expect(result.current.bindings["go-inbox"]).toEqual(
      sequenceKeybinding("KeyG", "KeyX")
    );
    expect(result.current.isDefault).toBe(false);

    act(() => {
      expect(
        result.current.setBinding("go-plugins", sequenceKeybinding("KeyG", "KeyX"))
      ).toBe(false);
    });
    expect(result.current.bindings["go-plugins"]).toEqual(
      createDefaultAppShortcutBindings("macos")["go-plugins"]
    );

    act(() => {
      result.current.resetAll();
    });
    expect(result.current.isDefault).toBe(true);
    expect(readStoredOverrides()).toEqual({});
    expect(result.current.bindings["go-settings"]).toEqual(
      chordKeybinding("Comma", { meta: true })
    );
  });

  it("clears one binding without restoring its default and reloads the null", () => {
    const first = renderHook(() => useCommaAppShortcuts(), {
      wrapper: wrapperFor("macos"),
    });

    act(() => {
      expect(first.result.current.setBinding("go-inbox", null)).toBe(true);
    });

    expect(first.result.current.bindings["go-inbox"]).toBeNull();
    expect(first.result.current.isDefault).toBe(false);
    expect(readStoredOverrides()).toEqual({ "go-inbox": null });

    first.unmount();
    const second = renderHook(() => useCommaAppShortcuts(), {
      wrapper: wrapperFor("macos"),
    });
    expect(second.result.current.bindings["go-inbox"]).toBeNull();
  });

  it("rejects a sequence-prefix conflict in both editing directions", () => {
    const { result } = renderHook(() => useCommaAppShortcuts(), {
      wrapper: wrapperFor("macos"),
    });

    act(() => {
      expect(
        result.current.setBinding(
          "go-inbox",
          sequenceKeybinding("KeyG", "KeyC", "KeyI")
        )
      ).toBe(false);
    });

    act(() => {
      expect(
        result.current.setBinding(
          "go-comma-assistant",
          sequenceKeybinding("KeyG", "KeyX", "KeyI")
        )
      ).toBe(true);
      expect(
        result.current.setBinding("go-inbox", sequenceKeybinding("KeyG", "KeyX"))
      ).toBe(false);
    });
  });

  it("uses Command defaults on macOS and Control defaults elsewhere", () => {
    const mac = renderHook(() => useCommaAppShortcuts(), {
      wrapper: wrapperFor("macos"),
    });
    expect(mac.result.current.bindings["go-settings"]).toEqual(
      chordKeybinding("Comma", { meta: true })
    );
    expect(mac.result.current.bindings["go-search"]).toEqual(
      chordKeybinding("KeyK", { meta: true })
    );
    expect(mac.result.current.bindings["go-tasks"]).toEqual(
      sequenceKeybinding("KeyG", "KeyT")
    );
    mac.unmount();

    const windows = renderHook(() => useCommaAppShortcuts(), {
      wrapper: wrapperFor("windows"),
    });
    expect(windows.result.current.bindings["go-settings"]).toEqual(
      chordKeybinding("Comma", { control: true })
    );
    expect(windows.result.current.bindings["go-search"]).toEqual(
      chordKeybinding("KeyK", { control: true })
    );
    expect(windows.result.current.bindings["go-tasks"]).toEqual(
      sequenceKeybinding("KeyG", "KeyT")
    );
  });

  it("migrates legacy hard-coded Mac defaults while preserving custom values", () => {
    localStorage.setItem(
      legacyCommaAppShortcutsStorageKey,
      JSON.stringify({
        "go-settings": chordKeybinding("Comma", { meta: true }),
        "go-inbox": sequenceKeybinding("KeyG", "KeyX"),
      })
    );

    const { result } = renderHook(() => useCommaAppShortcuts(), {
      wrapper: wrapperFor("linux"),
    });

    expect(result.current.bindings["go-settings"]).toEqual(
      chordKeybinding("Comma", { control: true })
    );
    expect(result.current.bindings["go-inbox"]).toEqual(
      sequenceKeybinding("KeyG", "KeyX")
    );
    expect(readStoredOverrides()).toEqual({
      "go-inbox": sequenceKeybinding("KeyG", "KeyX"),
    });
  });

  it("sanitizes legacy sequence-prefix conflicts during migration", () => {
    localStorage.setItem(
      legacyCommaAppShortcutsStorageKey,
      JSON.stringify({
        "go-comma-assistant": sequenceKeybinding("KeyG", "KeyC"),
        "go-inbox": sequenceKeybinding("KeyG", "KeyC", "KeyI"),
      })
    );

    const { result } = renderHook(() => useCommaAppShortcuts(), {
      wrapper: wrapperFor("macos"),
    });

    expect(result.current.bindings["go-comma-assistant"]).toBeNull();
    expect(result.current.bindings["go-inbox"]).toEqual(
      sequenceKeybinding("KeyG", "KeyC", "KeyI")
    );
    expect(readStoredOverrides()).toEqual({
      "go-comma-assistant": null,
      "go-inbox": sequenceKeybinding("KeyG", "KeyC", "KeyI"),
    });
  });

  it("preserves a legacy custom chord over a newly translated default", () => {
    localStorage.setItem(
      legacyCommaAppShortcutsStorageKey,
      JSON.stringify({
        "go-settings": chordKeybinding("KeyB", { control: true }),
        "toggle-left-sidebar": chordKeybinding("KeyB", { meta: true }),
      })
    );

    const { result } = renderHook(() => useCommaAppShortcuts(), {
      wrapper: wrapperFor("linux"),
    });

    expect(result.current.bindings["go-settings"]).toEqual(
      chordKeybinding("KeyB", { control: true })
    );
    expect(result.current.bindings["toggle-left-sidebar"]).toBeNull();
    expect(readStoredOverrides()).toEqual({
      "go-settings": chordKeybinding("KeyB", { control: true }),
      "toggle-left-sidebar": null,
    });
  });
});
