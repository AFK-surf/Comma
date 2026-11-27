import { act, render } from "@comma/test-utils/render";
import { createRef } from "react";
import { describe, expect, it, vi } from "vitest";
import { MessageReplyLines } from "../MessageReplyLines";
import type { MessageReply } from "../messageRelationships";

function mockRect(
  el: Element,
  rect: { left: number; top: number; width: number; height: number }
) {
  vi.spyOn(el, "getBoundingClientRect").mockReturnValue({
    ...rect,
    right: rect.left + rect.width,
    bottom: rect.top + rect.height,
    x: rect.left,
    y: rect.top,
    toJSON: () => ({}),
  } as DOMRect);
}

function flushLayoutFrame() {
  act(() => {
    vi.advanceTimersByTime(32);
  });
}

describe("MessageReplyLines", () => {
  it("anchors below a question card and preserves 8px edge gaps when space allows", () => {
    const columnRef = createRef<HTMLDivElement>();
    const replies = new Map<string, MessageReply>([
      [
        "m2",
        {
          messageId: "m2",
          targetId: "m1",
          sourceAnchorId: "m2",
          targetAnchorId: "m1",
          presentation: "line",
        },
      ],
    ]);

    const { container } = render(
      <div ref={columnRef}>
        <MessageReplyLines
          columnRef={columnRef}
          replies={replies}
          chainState={() => undefined}
        />
        <article data-message-id="m1" data-router-identity-hidden="true">
          <div className="markdown-stream-bubble" />
          <div className="comma-agent-card" />
        </article>
        <article data-message-id="m2" data-router-identity-hidden="true">
          <div className="markdown-stream-bubble" />
        </article>
      </div>
    );

    const column = columnRef.current!;
    mockRect(column, { left: 0, top: 0, width: 600, height: 500 });
    mockRect(
      container.querySelector('[data-message-id="m1"] .markdown-stream-bubble')!,
      { left: 32, top: 20, width: 300, height: 60 }
    );
    mockRect(container.querySelector('[data-message-id="m1"] .comma-agent-card')!, {
      left: 32,
      top: 90,
      width: 300,
      height: 110,
    });
    mockRect(
      container.querySelector('[data-message-id="m2"] .markdown-stream-bubble')!,
      { left: 32, top: 260, width: 300, height: 40 }
    );

    flushLayoutFrame();

    const path = container.querySelector(".comma-chat-reply-lines path");
    // m1 card ends at 200; m2 bubble starts at 260 (gap 60 >= 20 -> 8px inset each end).
    expect(path?.getAttribute("d")).toBe("M 45 208 V 252");
  });

  it("scales edge gaps down on tight consecutive bubbles so the stroke stays visible", () => {
    const columnRef = createRef<HTMLDivElement>();
    const replies = new Map<string, MessageReply>([
      [
        "m2",
        {
          messageId: "m2",
          targetId: "m1",
          sourceAnchorId: "m2",
          targetAnchorId: "m1",
          presentation: "line",
        },
      ],
    ]);

    const { container } = render(
      <div ref={columnRef}>
        <MessageReplyLines
          columnRef={columnRef}
          replies={replies}
          chainState={() => undefined}
        />
        <article data-message-id="m1" data-router-identity-hidden="true">
          <div className="markdown-stream-bubble" />
        </article>
        <article data-message-id="m2" data-router-identity-hidden="true">
          <div className="markdown-stream-bubble" />
        </article>
      </div>
    );

    const column = columnRef.current!;
    mockRect(column, { left: 0, top: 0, width: 600, height: 300 });
    mockRect(
      container.querySelector('[data-message-id="m1"] .markdown-stream-bubble')!,
      { left: 32, top: 20, width: 300, height: 60 }
    );
    mockRect(
      container.querySelector('[data-message-id="m2"] .markdown-stream-bubble')!,
      { left: 32, top: 86, width: 300, height: 40 }
    );

    flushLayoutFrame();

    const path = container.querySelector(".comma-chat-reply-lines path");
    // 6px consecutive gap: keeps 4px visible stroke (1px inset on each end).
    expect(path?.getAttribute("d")).toBe("M 45 81 V 85");
  });
});
