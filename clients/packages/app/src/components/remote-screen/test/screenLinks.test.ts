import { messageMarkdown, type MarkdownTree } from "@comma/core/markdown";
import { describe, expect, it } from "vitest";
import { parseScreenLink, screenLinkCards, withoutScreenLinks } from "../screenLinks";

const ANDROID = "comma:screen/dev_1/android%3Aemulator-5554";
const SIMULATOR = "comma:screen/dev_1/simulator%3AFA43E77A";

describe("a screen link", () => {
  it("names a computer and one of its screens, and nothing else", () => {
    expect(parseScreenLink(ANDROID)).toEqual({
      device: "dev_1",
      screen: "android:emulator-5554",
    });
    expect(
      parseScreenLink(
        "comma:screen/dev_1/simulator%3A0702F8CC-2E2A-4D0A-8401-C37FA01E1646"
      )
    ).toEqual({
      device: "dev_1",
      screen: "simulator:0702F8CC-2E2A-4D0A-8401-C37FA01E1646",
    });
    expect(parseScreenLink("comma:screen/dev_1/display")).toEqual({
      device: "dev_1",
      screen: "display",
    });
    for (const other of [
      "comma:task/cnv_1",
      "https://example.com/x",
      "comma:screen/dev_1/app",
      "comma:screen/dev_1/android%3Aa%2Fb",
      "comma:screen/dev_1/simulator%3Aa%2Fb",
      "comma:screen/dev_1/%E0",
    ])
      expect(parseScreenLink(other)).toBeNull();
  });

  it("alone on its line is a card; within a sentence it stays words; the rest stays as it was", () => {
    const tree: MarkdownTree = [
      ["p", ["Please look:"]],
      ["p", [["a", ["The phone"], { href: ANDROID }]]],
      ["p", ["see ", ["a", ["this"], { href: ANDROID }], " now"]],
      ["p", ["comma:screen/dev_1/display"]],
    ];
    const { tree: out, links } = screenLinkCards(tree);
    expect([...links.values()]).toEqual([
      { device: "dev_1", screen: "android:emulator-5554", label: "The phone" },
      { device: "dev_1", screen: "display", label: undefined },
    ]);
    expect(out[0]).toBe(tree[0]);
    expect(out[1]).toEqual(["p", [["comma-inline", { key: "screen-0" }]]]);
    expect(out[2]).toBe(tree[2]);
    expect(out[3]).toEqual(["p", [["comma-inline", { key: "screen-1" }]]]);
  });

  it("alone on a line of a longer paragraph is a card, the words around it kept", () => {
    const { tree, links } = screenLinkCards(
      messageMarkdown([
        { kind: "markdown", text: `实时画面：\n${SIMULATOR}\n点开即可操作。` },
      ])
    );
    expect([...links.values()]).toEqual([
      { device: "dev_1", screen: "simulator:FA43E77A", label: undefined },
    ]);
    expect(tree).toEqual([
      ["p", ["实时画面："]],
      ["p", [["comma-inline", { key: "screen-0" }]]],
      ["p", ["点开即可操作。"]],
    ]);
  });

  it("is cut out at a hard break too, and each of two lines is its own card", () => {
    const { tree, links } = screenLinkCards(
      messageMarkdown([
        {
          kind: "markdown",
          text: `Here:  \n[The phone](${ANDROID})\ncomma:screen/dev_1/display`,
        },
      ])
    );
    expect([...links.keys()]).toEqual(["screen-0", "screen-1"]);
    expect(tree).toEqual([
      ["p", ["Here:"]],
      ["p", [["comma-inline", { key: "screen-0" }]]],
      ["p", [["comma-inline", { key: "screen-1" }]]],
    ]);
  });

  it("stays words with others on its line, or in a list, a quote or a code block", () => {
    for (const text of [
      `see ${SIMULATOR} now`,
      `first line\nsee [this](${ANDROID}) now`,
      `- ${SIMULATOR}`,
      `> ${SIMULATOR}`,
      `\`\`\`\n${SIMULATOR}\n\`\`\``,
      `\`${SIMULATOR}\``,
    ]) {
      const tree = messageMarkdown([{ kind: "markdown", text }]);
      const result = screenLinkCards(tree);
      expect(result.links.size).toBe(0);
      expect(result.tree).toBe(tree);
    }
  });

  it("leaves a tree with none exactly as it was", () => {
    const tree: MarkdownTree = [["p", [["a", ["x"], { href: "https://example.com" }]]]];
    expect(screenLinkCards(tree).tree).toBe(tree);
  });
});

describe("a message with screen links, as one line of text (a reply's excerpt)", () => {
  it("says each link's words, and a bare address not at all", () => {
    expect(
      withoutScreenLinks(
        `Have a look:\n\n[The foldable](${ANDROID})\n\ncomma:screen/dev_1/display\n\nand [this](https://example.com).`
      ).replace(/\s+/g, " ")
    ).toBe("Have a look: The foldable and [this](https://example.com).");
  });
});
