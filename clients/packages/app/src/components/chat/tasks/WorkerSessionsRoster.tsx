import type { ChatWorkerSession } from "@comma/core/chat";
import { useCommaMessages } from "@comma/i18n/react";
import { Tooltip } from "@comma/ui/components/tooltip";
import { Focusable } from "react-aria-components";
import { WorkerModelMark } from "../thread/activity/WorkerModelMark";

/** Whether a name needs its @handle beside it: not when the name already is the handle ("Lead @lead"). */
export function showsWorkerSessionSlot(label: string, slot: string): boolean {
  const name = label.trim().toLowerCase();
  const handle = slot.trim().toLowerCase();
  return name !== handle && name !== `@${handle}`;
}

export function hasWorkerSessionLiveState(session: ChatWorkerSession): boolean {
  return (
    session.subscribed === true ||
    session.state !== "stopped" ||
    Boolean(session.status) ||
    session.updatedAt !== undefined ||
    Boolean(session.issue)
  );
}

/** The maker whose mark stands for a session, from its runtime with a model-prefix fallback. */
const RUNTIME_VENDORS: Record<string, string> = {
  claude: "anthropic",
  codex: "openai",
  gemini: "google",
};

export function workerSessionVendor(
  runtime: string | undefined,
  model?: string | undefined
): string | undefined {
  const fromRuntime = runtime
    ? RUNTIME_VENDORS[runtime.trim().toLowerCase()]
    : undefined;
  if (fromRuntime) return fromRuntime;
  if (!model) return undefined;
  const normalized = model.trim().toLowerCase();
  const bare = normalized.includes("/")
    ? normalized.slice(normalized.lastIndexOf("/") + 1)
    : normalized;
  if (bare.startsWith("claude")) return "anthropic";
  if (
    bare.startsWith("gpt") ||
    bare.startsWith("o1") ||
    bare.startsWith("o3") ||
    bare.startsWith("o4") ||
    bare.startsWith("codex")
  ) {
    return "openai";
  }
  if (bare.startsWith("gemini")) return "google";
  return undefined;
}

/**
 * The session's name without a trailing "(Claude)"-style note of what it runs on, when its mark and model
 * already say so ("Lead (Claude)" beside the Anthropic mark and claude-sonnet-4-6 reads "Claude" twice).
 */
export function workerSessionDisplayLabel(
  session: Pick<ChatWorkerSession, "label" | "runtime" | "model">
): string {
  const match = /^(.+?)\s*[(（]([^()（）]+)[)）]$/u.exec(session.label.trim());
  if (!match) return session.label;
  const note = match[2]!.trim().toLowerCase();
  const runtime = session.runtime?.trim().toLowerCase();
  const model = session.model?.trim().toLowerCase();
  const modelTokens = model ? model.split(/[^a-z0-9]+/i).filter(Boolean) : [];
  const vendor = workerSessionVendor(session.runtime, session.model);
  const said =
    note === runtime ||
    (vendor !== undefined && note === vendor) ||
    (runtime !== undefined && RUNTIME_VENDORS[runtime] === note) ||
    (model !== undefined && note === model) ||
    (note.length >= 3 && modelTokens.includes(note));
  return said ? match[1]! : session.label;
}

const MODEL_FAMILY_NAMES: Record<string, string> = {
  sonnet: "Sonnet",
  opus: "Opus",
  haiku: "Haiku",
  gpt: "GPT",
  gemini: "Gemini",
};

/**
 * Compact model name for a session row or message beside the vendor mark:
 * strips provider prefix (`anthropic/`, `openai/`, `google/`), drops a redundant
 * leading `claude-`, and capitalizes known families (`claude-sonnet-4-6` -> `Sonnet-4-6`,
 * `gpt-5.3-codex` -> `GPT-5.3-codex`), leaving other ids like `kimi-k2` intact.
 */
export function workerSessionModelName(model: string): string {
  const trimmed = model.trim();
  const id = trimmed.includes("/")
    ? trimmed.slice(trimmed.lastIndexOf("/") + 1)
    : trimmed;
  const bare = id.replace(/^claude-/i, "");
  const family = /^([a-z]+)-(.+)$/i.exec(bare);
  if (!family) return bare;
  const name = MODEL_FAMILY_NAMES[family[1]!.toLowerCase()];
  return name ? `${name}-${family[2]}` : bare;
}

/** What names a session on a row or a message: its model in reader words, else its own name. */
export function workerSessionName(
  session: Pick<ChatWorkerSession, "label" | "runtime" | "model">
): string {
  return session.model
    ? workerSessionModelName(session.model)
    : workerSessionDisplayLabel(session);
}

function stateLabel(
  messages: ReturnType<typeof useCommaMessages>,
  state: ChatWorkerSession["state"]
): string {
  switch (state) {
    case "active":
      return messages.task_worker_session_state_active();
    case "waiting":
      return messages.task_worker_session_state_waiting();
    case "error":
      return messages.task_worker_session_state_error();
    default:
      return messages.task_worker_session_state_idle();
  }
}

/** What the session is doing: its live status while it runs, else its state. */
function sessionActivity(
  messages: ReturnType<typeof useCommaMessages>,
  session: ChatWorkerSession
): string {
  const live = session.state === "active" || session.state === "waiting";
  return live && session.status ? session.status : stateLabel(messages, session.state);
}

/**
 * One session on one line: its model maker's mark, whose corner dot is its state, its name and its @handle.
 * The model and what the session is doing show on hover or focus.
 */
function SessionItem({
  className,
  primaryModelFallback,
  session,
}: {
  className: string;
  primaryModelFallback?: string | undefined;
  session: ChatWorkerSession;
}) {
  const messages = useCommaMessages();
  const hasLiveState = hasWorkerSessionLiveState(session);
  const displayModel =
    session.model || (session.isPrimary ? primaryModelFallback : undefined);
  const resolvedSession =
    displayModel && !session.model ? { ...session, model: displayModel } : session;
  const displayLabel = workerSessionDisplayLabel(resolvedSession);
  const primaryText = workerSessionName(resolvedSession);
  const activity = hasLiveState ? sessionActivity(messages, session) : undefined;
  const state = hasLiveState ? stateLabel(messages, session.state) : undefined;
  const detail =
    hasLiveState && activity && state
      ? activity === state
        ? state
        : `${state}: ${activity}`
      : undefined;
  const srLabel = displayLabel !== primaryText ? displayLabel : undefined;
  const srModel =
    displayModel && displayModel !== primaryText ? displayModel : undefined;
  const srText = [srLabel, srModel, detail].filter(Boolean).join(", ");

  return (
    <li
      className={className}
      data-primary={session.isPrimary ? "true" : undefined}
      data-session-slot={session.slot}
      data-session-state={hasLiveState ? session.state : undefined}
    >
      <Tooltip
        content={displayModel ?? displayLabel}
        placement="bottom"
        supportingText={activity}
      >
        <Focusable>
          <span className="comma-worker-session-item">
            <span className="comma-worker-session-mark">
              <WorkerModelMark
                className="size-4"
                vendor={workerSessionVendor(session.runtime, displayModel)}
              />
              {hasLiveState ? (
                <span
                  aria-hidden
                  className="comma-worker-session-dot"
                  data-state={session.state}
                />
              ) : null}
            </span>
            <span className="comma-worker-session-label">{primaryText}</span>
            {showsWorkerSessionSlot(primaryText, session.slot) ? (
              <span className="comma-worker-session-slot">@{session.slot}</span>
            ) : null}
            {srText ? <span className="sr-only">{srText}</span> : null}
          </span>
        </Focusable>
      </Tooltip>
    </li>
  );
}

/**
 * Compact multi-session worker roster for the Task Details panel.
 * Renders nothing for single-worker Tasks so single-worker visual layout is 100% unchanged.
 */
export function WorkerSessionsRoster({
  primaryModelFallback,
  sessions,
}: {
  primaryModelFallback?: string | undefined;
  sessions?: readonly ChatWorkerSession[] | undefined;
}) {
  const messages = useCommaMessages();
  if (!sessions || sessions.length <= 1) return null;

  const heading = messages.task_panel_sessions();
  return (
    <section
      aria-label={heading}
      className="comma-task-panel-section"
      data-testid="task-panel-worker-sessions"
    >
      <h2 className="comma-task-panel-heading">{heading}</h2>
      <ul className="comma-worker-sessions-panel-list">
        {sessions.map((session) => (
          <SessionItem
            className="comma-worker-sessions-panel-item"
            key={session.participantId}
            primaryModelFallback={primaryModelFallback}
            session={session}
          />
        ))}
      </ul>
    </section>
  );
}
