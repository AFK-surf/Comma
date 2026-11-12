// A selection staged for the next message (an element picked on a page, an area of a screen) is folded into the
// message at send time: its note in the person's words, its picture as a file, and what the agent reads about it.
import { decodeUserMessage } from "@comma/core/chat";
import { describe, expect, it } from "vitest";
import {
  composeMessageWithSelections,
  createChatDraftSelection,
  selectionFiles,
  selectionsFit,
  type ChatDraftSelection,
} from "../draftSelections";

const png = (...bytes: number[]) => new Uint8Array([137, 80, 78, 71, ...bytes]);

const element = (
  note: string,
  more: Partial<ChatDraftSelection> = {},
  tagName = "button"
): ChatDraftSelection =>
  createChatDraftSelection({
    note,
    about: {
      kind: "element",
      inspectionId: `inspection-${tagName}`,
      page: { title: "Example", url: "https://example.com/docs" },
      element: {
        attributes: { "aria-label": "Save", role: "button" },
        outerHTML: `<${tagName} aria-label="Save">Save</${tagName}>`,
        rect: { height: 32, width: 80, x: 20.04, y: 40.06 },
        selector: `main > ${tagName}`,
        tagName,
        text: "Save",
      },
    },
    ...more,
  });

const screen = (note: string, more: Partial<ChatDraftSelection> = {}) =>
  createChatDraftSelection({
    note,
    picture: { bytes: png(1), type: "image/png" },
    about: {
      kind: "screen",
      device: "mac",
      screen: "simulator:A",
      name: "iPhone 18 Pro",
      at: Date.UTC(2026, 10, 10, 12, 0, 5),
    },
    ...more,
  });

describe("a message with staged selections", () => {
  it("is the typed text alone when nothing is staged", () => {
    expect(composeMessageWithSelections("Hello", [])).toBe("Hello");
    expect(selectionFiles([])).toEqual([]);
  });

  it("carries one element's note as the person's words, its screenshot as a file, and its DOM for the agent", () => {
    const picked = element("Explain this control", {
      picture: { bytes: png(2), type: "image/png" },
    });
    const message = composeMessageWithSelections("", [picked]);

    expect(message.startsWith("Explain this control\n\n<user-reminder>")).toBe(true);
    expect(message).toContain('<browser-element-inspection id="inspection-button" />');
    expect(message).toContain("Page URL: https://example.com/docs");
    expect(message).toContain("Selector: main > button");
    expect(message).toContain("Attributes: aria-label=Save, role=button");
    expect(message).toContain("Bounding rect: x=20, y=40.1, width=80, height=32");
    expect(message).toContain("Screenshot: attached as inspected-element.png");
    expect(selectionFiles([picked])).toEqual([
      { bytes: png(2), name: "inspected-element.png", size: 5 },
    ]);
    // The chat shows the person's words alone: the element's DOM is for the agent.
    expect(decodeUserMessage(message).body).toBe("Explain this control");
  });

  it("goes with its DOM alone for an element that was not on screen", () => {
    const picked = element("Where is this?");
    expect(composeMessageWithSelections("", [picked])).not.toContain("Screenshot:");
    expect(selectionFiles([picked])).toEqual([]);
  });

  it("numbers several notes after the typed text as their pictures are numbered", () => {
    const selections = [
      element("This colour is wrong", {
        picture: { bytes: png(1), type: "image/png" },
      }),
      element("Where does this go?", {}, "a"),
      element(
        "Make this larger",
        { picture: { bytes: png(3), type: "image/jpeg" } },
        "h1"
      ),
    ];
    const message = composeMessageWithSelections("Fix these on the page", selections);

    expect(decodeUserMessage(message).body).toBe(
      "Fix these on the page\n\n1. This colour is wrong\n2. Where does this go?\n3. Make this larger"
    );
    expect(selectionFiles(selections).map((file) => file.name)).toEqual([
      "inspected-element-1.png",
      "inspected-element-3.jpg",
    ]);
    expect(message.match(/^Selection \d of 3$/gmu)).toEqual([
      "Selection 1 of 3",
      "Selection 2 of 3",
      "Selection 3 of 3",
    ]);
    expect(message).toContain("Screenshot: attached as inspected-element-1.png");
    expect(message).toContain("Screenshot: attached as inspected-element-3.jpg");
    expect(message.indexOf("Selector: main > a")).toBeGreaterThan(
      message.indexOf("Selection 2 of 3")
    );
  });

  it("names a screen once by its link, with its areas' pictures and its app's logs", () => {
    const logs = { bytes: new Uint8Array([1, 2]), name: "app-logs.txt", size: 2 };
    const again = { bytes: new Uint8Array([3]), name: "app-logs.txt", size: 1 };
    const selections = [
      screen("Why did this fail?", {
        about: {
          kind: "screen",
          device: "mac",
          screen: "simulator:A",
          name: "iPhone 18 Pro",
          at: Date.UTC(2026, 10, 10, 12, 0, 5),
          files: [logs],
        },
      }),
      screen("And this row?", {
        about: {
          kind: "screen",
          device: "mac",
          screen: "simulator:A",
          name: "iPhone 18 Pro",
          at: Date.UTC(2026, 10, 10, 12, 1, 0),
          files: [again],
        },
      }),
    ];
    const message = composeMessageWithSelections("", selections);

    expect(message.match(/\]\(comma:screen\/mac\/simulator%3AA\)/gu)).toHaveLength(1);
    expect(message).toMatch(
      /^1\. Why did this fail\?\n2\. And this row\?\n\n\[iPhone 18 Pro · \d\d:\d\d:\d\d\]\(comma:screen\/mac\/simulator%3AA\)$/u
    );
    // Each area's picture, and the logs once: the last read.
    expect(selectionFiles(selections)).toEqual([
      { bytes: png(1), name: "screen-1.png", size: 5 },
      { bytes: png(1), name: "screen-2.png", size: 5 },
      again,
    ]);
  });

  /** A selection of `screenId` on the Mac, with its app's logs of one byte. */
  const withLogs = (screenId: string, log: number) =>
    screen("What is this?", {
      about: {
        kind: "screen",
        device: "mac",
        screen: screenId,
        at: Date.UTC(2026, 10, 10, 12, 0, 5),
        files: [{ bytes: new Uint8Array([log]), name: "app-logs.txt", size: 1 }],
      },
    });

  it("keeps the logs of each screen, numbered as the selection they came with", () => {
    const files = selectionFiles([
      withLogs("simulator:A", 1),
      withLogs("android:emulator-5554", 2),
      withLogs("simulator:A", 3),
    ]);
    expect(files.map((file) => [file.name, [...file.bytes]])).toEqual([
      ["screen-1.png", [...png(1)]],
      ["screen-2.png", [...png(1)]],
      ["screen-3.png", [...png(1)]],
      // The simulator's as they stood at its latest selection, and the emulator's own.
      ["app-logs-3.txt", [3]],
      ["app-logs-2.txt", [2]],
    ]);
  });

  it("counts every file of a message: the pictures, the screens' logs, and what the composer has attached", () => {
    const sameScreen = (count: number) =>
      Array.from({ length: count }, () => withLogs("simulator:A", 1));
    // Seven pictures and the screen's logs are a message's eight files; an eighth picture is one too many.
    expect(selectionFiles(sameScreen(8))).toHaveLength(9);
    expect(selectionsFit(sameScreen(7), 0)).toBe(true);
    expect(selectionsFit(sameScreen(8), 0)).toBe(false);
    // Beside five files of the composer's own, three pictures go and four do not.
    const elements = (count: number) =>
      Array.from({ length: count }, () =>
        element("Explain", { picture: { bytes: png(2), type: "image/png" } })
      );
    expect(selectionsFit(elements(3), 5)).toBe(true);
    expect(selectionsFit(elements(4), 5)).toBe(false);
  });
});
