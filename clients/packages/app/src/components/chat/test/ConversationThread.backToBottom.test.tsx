import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { createRef } from "react";
import { describe, expect, it, vi } from "vitest";
import { ConversationThread } from "../thread/ConversationThread";
import type { ChatMessage } from "@comma/core/chat";

const messages: ChatMessage[] = ["first", "second", "third"].map((id, index) => ({
  attachments: [],
  blocksKey: undefined,
  clientRequestId: undefined,
  createdAt: index + 1,
  createdBy: undefined,
  delivery: "sent",
  error: undefined,
  messageId: id,
  parts: [{ kind: "markdown", text: id }],
  refs: [],
  role: "user",
  source: "server",
  status: "completed",
  text: id,
}));

describe("ConversationThread back-to-bottom navigation", () => {
  it.each(["button", "End", "scrollbar"])(
    "keeps a count-free button and cancels pending task reveals via %s",
    async (entry) => {
      const reveal = createRef<(turn: string, message?: string) => void>();
      const { container } = render(
        <ConversationThread
          groupId="grp_test"
          workspaceId="wsp_test"
          messages={messages}
          onDiscard={() => {}}
          onRetry={() => {}}
          revealTurnHandle={reveal}
        />
      );
      const viewport = container.querySelector<HTMLElement>(
        '[data-slot="scroll-area-viewport"]'
      )!;
      Object.defineProperty(viewport, "clientHeight", {
        configurable: true,
        value: 100,
      });
      Object.defineProperty(viewport, "scrollHeight", {
        configurable: true,
        value: 1000,
      });
      vi.spyOn(viewport, "getBoundingClientRect").mockImplementation(() => ({
        top: 0,
        bottom: 100,
        left: 0,
        right: 400,
        width: 400,
        height: 100,
        x: 0,
        y: 0,
        toJSON: () => ({}),
      }));
      const anchors = [
        ...container.querySelectorAll<HTMLElement>(
          "[data-chat-turn-anchor][data-turn-key]"
        ),
      ];
      expect(anchors).toHaveLength(3);
      anchors.forEach((anchor, index) =>
        vi.spyOn(anchor, "getBoundingClientRect").mockImplementation(() => ({
          top: 100 + index * 250 - viewport.scrollTop,
          bottom: 200 + index * 250 - viewport.scrollTop,
          left: 0,
          right: 400,
          width: 400,
          height: 100,
          x: 0,
          y: 0,
          toJSON: () => ({}),
        }))
      );
      // The thread decides it scrolls from the reader's first wheel over the overflow.
      fireEvent.wheel(viewport, { deltaY: -120 });
      act(() => {
        reveal.current!(anchors[0]!.dataset.turnKey!);
        reveal.current!(anchors[1]!.dataset.turnKey!);
      });
      const button = screen.getByRole("button", { name: "Back to bottom" });
      expect(button).toHaveTextContent("↓ Back to bottom");
      expect(button.textContent).not.toMatch(/\d/);
      const secondPosition = viewport.scrollTop;
      act(() => reveal.current!(anchors[0]!.dataset.turnKey!));
      expect(viewport.scrollTop).toBeLessThan(secondPosition);
      expect(button).toBeVisible();
      fireEvent.click(button);
      expect(viewport.scrollTop).toBe(900);
      act(() => reveal.current!(anchors[0]!.dataset.turnKey!));
      const returnButton = screen.getByRole("button", { name: "Back to bottom" });
      // Returning to the tail must cancel a task jump waiting for the next commit.
      act(() => {
        reveal.current!(anchors[1]!.dataset.turnKey!);
        if (entry === "button") fireEvent.click(returnButton);
        else if (entry === "End") fireEvent.keyDown(viewport, { key: "End" });
        else {
          const scrollbar = container.querySelector(
            '[data-slot="scroll-area-scrollbar"]'
          );
          expect(scrollbar).not.toBeNull();
          fireEvent.pointerDown(scrollbar!);
          viewport.scrollTop = 900;
          fireEvent.scroll(viewport);
          fireEvent.pointerUp(window);
        }
      });
      expect(viewport.scrollTop).toBe(900);
      await waitFor(() =>
        expect(
          screen.queryByRole("button", { name: "Back to bottom" })
        ).not.toBeInTheDocument()
      );
    }
  );
});
