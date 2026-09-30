import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import type { MessageReply } from "./messageRelationships";

export function MessageReplyLines({
  columnRef,
  initialDraftId,
  replies,
  chainState,
}: {
  columnRef: RefObject<HTMLDivElement | null>;
  initialDraftId?: string | undefined;
  replies: ReadonlyMap<string, MessageReply>;
  chainState: (messageId: string) => "active" | "muted" | undefined;
}) {
  const svgRef = useRef<SVGSVGElement>(null);
  const [openedAt] = useState(Date.now);
  const seen = useRef(new Set<string>());
  const currentPaths = useRef(new Map<string, boolean>());
  const [paths, setPaths] = useState<
    { id: string; key: string; targetId: string; d: string; animate: boolean }[]
  >([]);
  useLayoutEffect(() => {
    // The transcript can mount outside the scroll viewport. Start its clock only
    // when the stroke is visible, and never replay it on geometry updates.
    const entering = [...(svgRef.current?.querySelectorAll("path") ?? [])].filter(
      (path) => path.dataset.replyDrawEnter === "true" && !path.dataset.replyDrawVisible
    );
    if (entering.length === 0) return;
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        (entry.target as SVGPathElement).dataset.replyDrawVisible = "true";
        observer.unobserve(entry.target);
      }
    });
    for (const path of entering) observer.observe(path);
    return () => observer.disconnect();
  }, [paths]);
  useLayoutEffect(() => {
    const column = columnRef.current;
    if (!column) return;
    if (replies.size === 0) {
      setPaths((previous) => (previous.length === 0 ? previous : []));
      return;
    }
    let frame = 0;
    const measure = () => {
      frame = 0;
      const bounds = column.getBoundingClientRect();
      const rows = new Map(
        [...column.querySelectorAll<HTMLElement>("article[data-message-id]")].map(
          (row) => [row.dataset.messageId!, row]
        )
      );
      const anchor = (id: string, edge: "start" | "end") => {
        const row = rows.get(id);
        if (row?.dataset.routerIdentityHidden === "true") {
          const bubbles = row.querySelectorAll<HTMLElement>(
            ".markdown-stream-bubble, .comma-chat-block-extras"
          );
          const bubble = edge === "start" ? bubbles[0] : [...bubbles].at(-1);
          if (!bubble) return;
          const rect = bubble.getBoundingClientRect();
          return {
            x: rect.left - bounds.left + 13,
            y: (edge === "start" ? rect.top - 8 : rect.bottom + 8) - bounds.top,
            radius: 0,
            bubbleEdge: true,
          };
        }
        const avatar = row?.querySelector<HTMLElement>(
          ":scope > .comma-chat-assistant-source-avatar"
        );
        const element =
          avatar ??
          row?.querySelector<HTMLElement>(".comma-chat-user-bubble") ??
          [
            ...(row?.querySelectorAll<HTMLElement>(
              ".markdown-stream-bubble, .comma-chat-block-extras"
            ) ?? []),
          ].at(-1);
        if (!element) return;
        const rect = element.getBoundingClientRect();
        return {
          x: rect.left - bounds.left + (avatar ? rect.width / 2 : -5),
          y: rect.top - bounds.top + rect.height / 2,
          radius: avatar ? rect.height / 2 + 4 : 0,
        };
      };
      const next: typeof paths = [];
      for (const reply of replies.values()) {
        const source = anchor(
          rows.get(reply.messageId)?.dataset.routerIdentityHidden === "true"
            ? reply.messageId
            : reply.sourceAnchorId,
          "start"
        );
        const target =
          reply.presentation === "line"
            ? anchor(reply.targetAnchorId, "end")
            : (() => {
                const preview = rows
                  .get(reply.messageId)
                  ?.querySelector<HTMLElement>(".comma-chat-reply-preview");
                if (!preview) return;
                const hideAvatar = preview.dataset.previewAvatarHidden === "true";
                const element = preview.querySelector<HTMLElement>(
                  hideAvatar
                    ? ".comma-chat-reply-preview-bubble"
                    : ".comma-chat-reply-preview-avatar"
                );
                if (!element) return;
                const rect = element.getBoundingClientRect();
                if (hideAvatar)
                  return {
                    x: rect.left - bounds.left + 13,
                    y: rect.bottom - bounds.top,
                    radius: 0,
                    bubbleEdge: true,
                  };
                return {
                  x: rect.left - bounds.left + rect.width / 2,
                  y: rect.top - bounds.top + rect.height / 2,
                  radius: rect.height / 2 + 4,
                };
              })();
        if (!source || !target) continue;
        const top = target.y + target.radius;
        const bottom = source.y - source.radius;
        if (bottom <= top) continue;
        const bend = Math.min(24, bottom - top);
        const middle = (top + bottom) / 2;
        // A small loop stays inside the avatar gutter, clear of bubble content.
        // Keep every segment in source-to-reply order for the stroke reveal.
        const stem =
          bottom - top > 800
            ? `V ${middle - 16} C ${source.x} ${middle + 16} ${source.x + 14} ${middle + 12} ${source.x + 14} ${middle} C ${source.x + 14} ${middle - 12} ${source.x} ${middle - 12} ${source.x} ${middle + 16} V ${bottom}`
            : `V ${bottom}`;
        // Avatar-to-avatar replies stay on their shared center line. A user
        // bubble has no avatar here, so mark its height with a short rounded
        // cap in the left gutter instead of crossing the transcript to it.
        const d =
          target.radius > 0 || ("bubbleEdge" in target && target.bubbleEdge)
            ? `M ${source.x} ${top} ${stem}`
            : `M ${source.x + 24} ${top} H ${source.x + bend} Q ${source.x} ${top} ${source.x} ${top + bend} ${stem}`;
        const row = rows.get(reply.messageId);
        const key = row?.dataset.replyAnimationKey ?? reply.messageId;
        const animate =
          currentPaths.current.get(key) ??
          (!seen.current.has(key) &&
            ((row?.dataset.replyStreaming === "true" &&
              reply.messageId !== initialDraftId) ||
              Number(row?.dataset.messageCreatedAt) >= openedAt));
        seen.current.add(key);
        next.push({
          id: reply.messageId,
          key,
          animate,
          targetId: reply.targetId,
          d,
        });
      }
      currentPaths.current = new Map(next.map((path) => [path.key, path.animate]));
      setPaths((previous) =>
        JSON.stringify(previous) === JSON.stringify(next) ? previous : next
      );
    };
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    measure();
    column.addEventListener("animationend", schedule);
    // One observer per transcript, shared by the currently mounted rows. Image,
    // Markdown, font and width reflow update paths without scroll-time layout reads.
    const observer = new ResizeObserver(schedule);
    observer.observe(column);
    for (const row of column.querySelectorAll("article[data-message-id]"))
      observer.observe(row);
    return () => {
      column.removeEventListener("animationend", schedule);
      observer.disconnect();
      cancelAnimationFrame(frame);
    };
  }, [columnRef, replies, openedAt, initialDraftId]);
  return (
    <svg ref={svgRef} aria-hidden className="comma-chat-reply-lines">
      {paths.map((path) => (
        <path
          key={path.key}
          d={path.d}
          pathLength={1}
          data-reply-draw-enter={path.animate ? "true" : undefined}
          data-reply-source={path.id}
          data-reply-target={path.targetId}
          data-reply-chain-state={chainState(path.id)}
        />
      ))}
    </svg>
  );
}
