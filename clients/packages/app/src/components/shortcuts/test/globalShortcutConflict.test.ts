import { defaultOpenCommaShortcut } from "@comma/native-bridge";
import {
  chordKeybinding,
  sequenceKeybinding,
} from "@comma/ui/components/settings-shortcut";
import { describe, expect, it } from "vitest";
import {
  appBindingConflictsWithGlobalShortcut,
  findAppShortcutConflictForGlobalShortcut,
} from "../globalShortcutConflict";
import { createDefaultAppShortcutBindings } from "../appShortcutRegistry";

describe("globalShortcutConflict", () => {
  it("compares the Open Comma accelerator with app chords", () => {
    expect(
      appBindingConflictsWithGlobalShortcut(
        chordKeybinding("Comma", { alt: true }),
        defaultOpenCommaShortcut
      )
    ).toBe(true);
    expect(
      appBindingConflictsWithGlobalShortcut(
        chordKeybinding("Comma", { meta: true }),
        defaultOpenCommaShortcut
      )
    ).toBe(false);
    expect(
      appBindingConflictsWithGlobalShortcut(
        sequenceKeybinding("KeyG", "Comma"),
        defaultOpenCommaShortcut
      )
    ).toBe(false);
  });

  it("finds the app owner when Open Comma is edited to an app chord", () => {
    const bindings = createDefaultAppShortcutBindings("macos");

    expect(
      findAppShortcutConflictForGlobalShortcut(bindings, {
        key: "b",
        modifiers: {
          alt: false,
          control: false,
          meta: true,
          shift: false,
        },
      })
    ).toBe("toggle-left-sidebar");
  });
});
