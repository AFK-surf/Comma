import { CheckIcon } from "@comma/ui/components/icons";
import { cx } from "@comma/ui/components/utils";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  type ReactNode,
} from "react";
import "./agent-card.css";

/**
 * Tracks an open Agent card's rendered height so when it closes live into its
 * compact receipt, the receipt smoothly folds from the card's footprint rather
 * than yanking the conversation upward in a single frame.
 */
export type AgentCardMorph = {
  cardRef: (node: HTMLElement | null) => void;
  receiptRef: (node: HTMLElement | null) => void;
};

const AgentCardMorphContext = createContext<AgentCardMorph | undefined>(undefined);

function captureCardGhost(source: HTMLElement): HTMLDivElement {
  const ghost = document.createElement("div");
  ghost.className = source.className;
  ghost.setAttribute("aria-hidden", "true");
  ghost.inert = true;
  ghost.innerHTML = source.innerHTML;
  const interactive = Array.from(
    ghost.querySelectorAll("input, button, textarea, output")
  ).slice(0, 64);
  for (const el of interactive) {
    const span = document.createElement("span");
    span.className = el.className;
    span.append(...Array.from(el.childNodes));
    el.replaceWith(span);
  }
  const labelled = Array.from(
    ghost.querySelectorAll(
      "[id], [data-testid], [role], [aria-label], [aria-labelledby]"
    )
  ).slice(0, 128);
  for (const el of labelled) {
    el.removeAttribute("id");
    el.removeAttribute("data-testid");
    el.removeAttribute("role");
    el.removeAttribute("aria-label");
    el.removeAttribute("aria-labelledby");
  }
  Object.assign(ghost.style, {
    position: "absolute",
    inset: "0",
    width: "100%",
    maxWidth: "none",
    margin: "0",
    boxShadow: "none",
    background: "transparent",
    pointerEvents: "none",
    transformOrigin: "top center",
    zIndex: "1",
  });
  return ghost;
}

export function useAgentCardMorph(): AgentCardMorph {
  const lastOpenRef = useRef<{
    height: number;
    snapshot: (() => HTMLDivElement) | null;
  }>({ height: 0, snapshot: null });
  const nodeRef = useRef<HTMLElement | null>(null);
  const lastGhostRef = useRef<HTMLDivElement | null>(null);
  const observerRef = useRef<ResizeObserver | null>(null);

  useEffect(() => () => observerRef.current?.disconnect(), []);

  const cardRef = useCallback((node: HTMLElement | null) => {
    // Capture the final visual state right as the open card unmounts.
    if (!node && nodeRef.current && lastOpenRef.current.height > 0) {
      lastGhostRef.current = captureCardGhost(nodeRef.current);
    }
    observerRef.current?.disconnect();
    observerRef.current = null;
    nodeRef.current = node;
    if (!node) return;
    lastGhostRef.current = null;
    const record = () => {
      const height = node.getBoundingClientRect().height;
      if (height > 0) {
        lastOpenRef.current = {
          height,
          snapshot: () => captureCardGhost(node),
        };
      }
    };
    record();
    if (typeof ResizeObserver !== "undefined") {
      const observer = new ResizeObserver(record);
      observer.observe(node);
      observerRef.current = observer;
    }
  }, []);

  const receiptRef = useCallback((node: HTMLElement | null) => {
    if (!node) return;
    const fromHeight = lastOpenRef.current.height;
    const ghost = lastGhostRef.current ?? lastOpenRef.current.snapshot?.() ?? null;
    lastOpenRef.current = { height: 0, snapshot: null };
    lastGhostRef.current = null;
    if (fromHeight <= 0) return;

    const reduced =
      document.documentElement.dataset.commaReducedMotion === "true" ||
      (typeof matchMedia === "function" &&
        matchMedia("(prefers-reduced-motion: reduce)").matches);
    if (reduced || typeof node.animate !== "function") return;

    const toHeight = node.getBoundingClientRect().height;
    if (toHeight <= 0 || Math.abs(fromHeight - toHeight) <= 4) return;

    node.style.position = "relative";
    node.style.overflow = "hidden";
    if (ghost) {
      node.append(ghost);
      ghost.animate(
        [
          { opacity: 1, transform: "scale(1)" },
          { opacity: 0, transform: "scale(0.985)" },
        ],
        { duration: 130, easing: "cubic-bezier(0.4, 0, 1, 1)", fill: "forwards" }
      );
    }

    const morph = node.animate(
      [
        {
          height: `${fromHeight}px`,
          borderRadius: "var(--radius-2xl)",
          backgroundColor: "var(--color-bg-popup-secondary)",
        },
        {
          height: `${toHeight}px`,
          borderRadius: "var(--radius-xl)",
          backgroundColor: "var(--color-bg-secondary)",
        },
      ],
      { duration: 240, easing: "cubic-bezier(0.32, 0.72, 0, 1)" }
    );
    const cleanup = () => {
      ghost?.remove();
      node.style.removeProperty("overflow");
      node.style.removeProperty("position");
    };
    void morph.finished.then(cleanup, cleanup);

    const icon = node.querySelector<HTMLElement>(".comma-agent-receipt-icon");
    icon?.animate(
      [
        { opacity: 0, scale: "0.6" },
        { opacity: 1, scale: "1" },
      ],
      {
        delay: 35,
        duration: 205,
        easing: "cubic-bezier(0.25, 0.3, 0.25, 1.32)",
        fill: "backwards",
      }
    );

    const text = node.querySelector<HTMLElement>(".comma-agent-receipt-text");
    text?.animate(
      [
        { opacity: 0, translate: "0 4px" },
        { opacity: 1, translate: "0 0" },
      ],
      {
        delay: 35,
        duration: 205,
        easing: "cubic-bezier(0.22, 1, 0.36, 1)",
        fill: "backwards",
      }
    );
  }, []);

  return useMemo(() => ({ cardRef, receiptRef }), [cardRef, receiptRef]);
}

export function AgentCardMorphProvider({ children }: { children: ReactNode }) {
  const morph = useAgentCardMorph();
  return (
    <AgentCardMorphContext.Provider value={morph}>
      {children}
    </AgentCardMorphContext.Provider>
  );
}

/**
 * The shell every Agent card shares (a question, a request): a head with the card's title and what it is about, the
 * kind's own body, and a foot with what is under way and the card's actions. Answered, it closes into an
 * `AgentReceipt` with a continuous height fold.
 */
export function AgentCard({
  titleId,
  state,
  testId,
  morph,
  children,
}: {
  titleId: string;
  /** What the card is waiting on, for styling and tests. */
  state?: string;
  testId?: string;
  morph?: AgentCardMorph;
  children: ReactNode;
}) {
  const contextMorph = useContext(AgentCardMorphContext);
  const resolvedMorph = morph ?? contextMorph;
  return (
    <section
      aria-labelledby={titleId}
      className="comma-agent-card"
      data-state={state}
      data-testid={testId}
      ref={resolvedMorph?.cardRef}
    >
      {children}
    </section>
  );
}

/** The card's title, with its mark (an account's logo) when it has one, and the Agent's reason under it. */
export function AgentCardHead({
  titleId,
  title,
  mark,
  reason,
}: {
  titleId: string;
  title: ReactNode;
  mark?: ReactNode;
  reason?: ReactNode;
}) {
  return (
    <div className="comma-agent-card-head" data-mark={mark ? "" : undefined}>
      {mark ? (
        <span aria-hidden="true" className="comma-agent-card-mark">
          {mark}
        </span>
      ) : null}
      <p className="comma-agent-card-title" id={titleId}>
        {title}
      </p>
      {reason ? <p className="comma-agent-card-reason">{reason}</p> : null}
    </div>
  );
}

/** What is under way or how long is left, at the leading end; the card's actions at the trailing end. */
export function AgentCardFoot({
  lead,
  actions,
}: {
  lead?: ReactNode;
  actions: ReactNode;
}) {
  return (
    <div className="comma-agent-card-foot">
      <span className="comma-agent-card-hint">{lead}</span>
      <span className="comma-agent-card-actions">{actions}</span>
    </div>
  );
}

/** A closed card: what it was about, small, and how it ended; a muted ending is one that gave the Agent nothing. */
export function AgentReceipt({
  label,
  about,
  outcome,
  note,
  icon,
  muted = false,
  morph,
  testId,
}: {
  label: string;
  about: ReactNode;
  outcome: ReactNode;
  note?: ReactNode;
  icon?: ReactNode;
  muted?: boolean;
  morph?: AgentCardMorph;
  testId?: string;
}) {
  const contextMorph = useContext(AgentCardMorphContext);
  const resolvedMorph = morph ?? contextMorph;
  return (
    <section
      aria-label={label}
      className="comma-agent-receipt"
      data-testid={testId}
      ref={resolvedMorph?.receiptRef}
    >
      <span className={cx("comma-agent-receipt-icon", muted && "is-muted")}>
        {icon ?? <CheckIcon aria-hidden="true" />}
      </span>
      <span className="comma-agent-receipt-text">
        <span className="comma-agent-receipt-prompt">{about}</span>
        <span className={cx("comma-agent-receipt-answer", muted && "is-muted")}>
          {outcome}
          {note ? <span className="comma-agent-receipt-note"> · {note}</span> : null}
        </span>
      </span>
    </section>
  );
}
