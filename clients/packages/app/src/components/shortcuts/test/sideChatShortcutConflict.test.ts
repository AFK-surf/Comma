import { defaultSideChatShortcut } from "@comma/native-bridge";
import { chordKeybinding, sequenceKeybinding } from "@comma/ui";
import { describe, expect, it } from "vitest";
import {
  appBindingConflictsWithSideChatShortcut,
  findAppShortcutConflictForSideChat,
} from "../sideChatShortcutConflict";
import { createDefaultAppShortcutBindings } from "../appShortcutRegistry";

describe("sideChatShortcutConflict", () => {
  it("compares the Side Chat accelerator with app chords", () => {
    expect(
      appBindingConflictsWithSideChatShortcut(
        chordKeybinding("KeyZ", { control: true }),
        defaultSideChatShortcut
      )
    ).toBe(true);
    expect(
      appBindingConflictsWithSideChatShortcut(
        chordKeybinding("KeyZ", { meta: true }),
        defaultSideChatShortcut
      )
    ).toBe(false);
    expect(
      appBindingConflictsWithSideChatShortcut(
        sequenceKeybinding("KeyG", "KeyZ"),
        defaultSideChatShortcut
      )
    ).toBe(false);
  });

  it("finds the app owner when Side Chat is edited to an app chord", () => {
    const bindings = createDefaultAppShortcutBindings("macos");

    expect(
      findAppShortcutConflictForSideChat(bindings, {
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
