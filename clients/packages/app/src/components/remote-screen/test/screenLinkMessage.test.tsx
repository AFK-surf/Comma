import type { ChatMessage } from "@comma/core/chat";
import { messageMarkdown } from "@comma/core/markdown";
import { defaultCommaClientSettings } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { messageMarkdownElements } from "../../chat/thread/inline/MessageInlineElements";
import { useCompiledMessageMarkdown } from "../../chat/thread/rows/assistant/useCompiledMessageMarkdown";
import { useOptionalCommaClientSettings } from "../../commaClientSettings";

vi.mock("../../commaClientSettings", () => ({
  useOptionalCommaClientSettings: vi.fn(),
}));

const LINK = "comma:screen/dev/android%3Aemulator-5554";
const SIMULATOR = "comma:screen/dev/simulator%3AFA43E77A";
const message = {
  markdown: [["p", [["a", ["The phone"], { href: LINK }]]]],
  parts: [{ kind: "markdown", text: `[The phone](${LINK})` }],
  attachments: [],
} as unknown as ChatMessage;
const context = { groupId: "g", workspaceId: "w" };

describe("a screen link in an Agent's message", () => {
  it("where cards are off (the web, or the mesh off) stays the link it was, and no card is drawn", () => {
    const off = messageMarkdownElements(message, context)!;
    expect(off.inlineElements.size).toBe(0);
    expect(JSON.stringify(off.nodes)).toContain(LINK);
    const again = messageMarkdownElements(message, { ...context, screenCards: false })!;
    expect(again.nodes).toEqual(off.nodes);
  });

  it("with it on stands for its card", () => {
    const on = messageMarkdownElements(message, { ...context, screenCards: true })!;
    expect([...on.inlineElements.keys()]).toEqual(["screen-0"]);
    expect(JSON.stringify(on.nodes)).not.toContain(LINK);
  });

  it("under a sentence with one newline between them, as Agents write it, is a card and keeps the sentence", () => {
    const text = `实时画面：\n${SIMULATOR}`;
    const written = {
      markdown: messageMarkdown([{ kind: "markdown", text }]),
      parts: [{ kind: "markdown", text }],
      attachments: [],
    } as unknown as ChatMessage;
    const on = messageMarkdownElements(written, { ...context, screenCards: true })!;
    expect([...on.inlineElements.keys()]).toEqual(["screen-0"]);
    const nodes = JSON.stringify(on.nodes);
    expect(nodes).toContain("实时画面：");
    expect(nodes).not.toContain(SIMULATOR);
    const off = messageMarkdownElements(written, context)!;
    expect(off.inlineElements.size).toBe(0);
    expect(JSON.stringify(off.nodes)).toContain(SIMULATOR);
  });

  it("is a card in the desktop app with the settings as they come, Settings › Debug untouched", () => {
    installNativeBridgeMock({ platform: "electron" });
    for (const settings of [undefined, defaultCommaClientSettings]) {
      vi.mocked(useOptionalCommaClientSettings).mockReturnValue(settings as never);
      const { result } = renderHook(() =>
        useCompiledMessageMarkdown(message, true, "g", "w")
      );
      expect([...result.current!.inlineElements.keys()]).toEqual(["screen-0"]);
    }
  });
});
