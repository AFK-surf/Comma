import { CheckIcon } from "@comma/ui/components/icons";
import { cx } from "@comma/ui/components/utils";
import type { ReactNode } from "react";
import "./agent-card.css";

/**
 * The shell every Agent card shares (a question, a request): a head with the card's title and what it is about, the
 * kind's own body, and a foot with what is under way and the card's actions. Answered, it closes into an
 * `AgentReceipt`. Changes are instant: nothing transitions on answering or closing.
 */
export function AgentCard({
  titleId,
  state,
  testId,
  children,
}: {
  titleId: string;
  /** What the card is waiting on, for styling and tests. */
  state?: string;
  testId?: string;
  children: ReactNode;
}) {
  return (
    <section
      aria-labelledby={titleId}
      className="comma-agent-card"
      data-state={state}
      data-testid={testId}
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
  testId,
}: {
  label: string;
  about: ReactNode;
  outcome: ReactNode;
  note?: ReactNode;
  icon?: ReactNode;
  muted?: boolean;
  testId?: string;
}) {
  return (
    <section aria-label={label} className="comma-agent-receipt" data-testid={testId}>
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
