import { describe, expect, it } from "vitest";
import {
  appKeybindingKeycapCount,
  appKeybindingKeycaps,
  appKeybindingsConflict,
  chordKeybinding,
  formatAppKeybinding,
  formatAppKeybindingAria,
  isValidAppKeybinding,
  matchesAppKeyStroke,
  parseStoredAppKeybinding,
  sameAppKeybinding,
  sequenceKeybinding,
} from "../appKeybinding";

describe("appKeybinding", () => {
  it("formats chord and sequence bindings for macOS tooltips and settings", () => {
    const pin = chordKeybinding("KeyP", { alt: true, meta: true });
    const commaAssistant = sequenceKeybinding("KeyG", "KeyC");

    expect(appKeybindingKeycaps(pin, "macos")).toEqual(["⌥", "⌘", "P"]);
    expect(formatAppKeybinding(pin, "macos")).toBe("⌥⌘P");
    expect(formatAppKeybindingAria(pin, "macos")).toBe("Option + Command + P");
    expect(appKeybindingKeycapCount(pin)).toBe(3);

    expect(appKeybindingKeycaps(commaAssistant, "macos")).toEqual(["G", "C"]);
    expect(formatAppKeybinding(commaAssistant, "macos")).toBe("G C");
    expect(formatAppKeybindingAria(commaAssistant, "macos")).toBe("G then C");
    expect(appKeybindingKeycapCount(commaAssistant)).toBe(2);
  });

  it("uses readable non-macOS modifier labels", () => {
    const binding = chordKeybinding("KeyP", { alt: true, control: true });

    expect(appKeybindingKeycaps(binding, "windows")).toEqual(["Ctrl", "Alt", "P"]);
    expect(formatAppKeybinding(binding, "windows")).toBe("Ctrl+Alt+P");
    expect(formatAppKeybindingAria(binding, "windows")).toBe("Control + Alt + P");
  });

  it("treats a sequence prefix as a conflict in either direction", () => {
    const shorter = sequenceKeybinding("KeyG", "KeyC");
    const longer = sequenceKeybinding("KeyG", "KeyC", "KeyI");

    expect(appKeybindingsConflict(shorter, longer)).toBe(true);
    expect(appKeybindingsConflict(longer, shorter)).toBe(true);
    expect(appKeybindingsConflict(shorter, sequenceKeybinding("KeyG", "KeyI"))).toBe(
      false
    );
  });

  it("rejects bindings that exceed three keycaps", () => {
    expect(
      isValidAppKeybinding({
        kind: "chord",
        stroke: {
          code: "KeyP",
          modifiers: { alt: true, control: true, meta: true, shift: true },
        },
      })
    ).toBe(false);
    expect(
      isValidAppKeybinding({
        kind: "sequence",
        codes: ["KeyG", "KeyC", "KeyI", "KeyP"],
      })
    ).toBe(false);
  });

  it("matches chord strokes and round-trips storage", () => {
    const settings = chordKeybinding("Comma", { meta: true });
    expect(settings.kind).toBe("chord");
    if (settings.kind !== "chord") return;
    expect(
      matchesAppKeyStroke(settings.stroke, {
        code: "Comma",
        altKey: false,
        ctrlKey: false,
        metaKey: true,
        shiftKey: false,
      })
    ).toBe(true);

    const stored = parseStoredAppKeybinding(settings);
    expect(stored).toEqual(settings);
    expect(sameAppKeybinding(settings, sequenceKeybinding("KeyG", "KeyC"))).toBe(false);
  });
});
