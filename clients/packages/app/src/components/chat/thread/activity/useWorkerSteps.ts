import { uiClock } from "@comma/ui/clock";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { useEffect, useMemo, useRef, useState } from "react";
import {
  useSessionHistory,
  type SessionHistoryInput,
} from "../../session-history/useSessionHistory";
import { usePresentedRecords } from "../../session-history/SessionHistory";
import { sessionHistoryEntries } from "../../session-history/model/sessionHistoryEntries";
import { useHistoryRecords } from "../../session-history/model/sessionHistoryLive";
import {
  latestWorkerStep,
  workerProgress,
  type WorkerProgress,
  type WorkerStep,
} from "./workerProgress";

type Messages = ReturnType<typeof useCommaMessages>;

export type ShownStep = { at: number | undefined; words: string };

// How long the step in progress outlasts the evidence of it.
const CURRENT_HOLD_MS = 1500;

/**
 * Progress whose step in progress outlasts short gaps. Between a model
 * request and the command it starts, or while the stream reconnects, the
 * owner briefly reports no step in progress; showing that would drop the
 * log's last row and bring it back a moment later. The last step in progress
 * stays until another starts or the gap outlasts `CURRENT_HOLD_MS`. One that
 * has finished, and is listed above, leaves the row to a plain "working".
 */
function useSteadyProgress(progress: WorkerProgress): WorkerProgress {
  const last = useRef(progress.current);
  if (progress.current) last.current = progress.current;
  const [lapsed, setLapsed] = useState(false);
  const live = progress.current !== undefined;
  useEffect(() => {
    setLapsed(false);
    if (live) return undefined;
    return uiClock.after(CURRENT_HOLD_MS, () => setLapsed(true));
  }, [live]);
  const held = last.current;
  if (live || lapsed || !held) return progress;
  const finished = progress.steps.some((step) => step.id === held.id);
  return {
    ...progress,
    current: finished ? { id: `${held.id}:after`, at: held.at, kind: "other" } : held,
  };
}

// The step each Worker's row showed last. The Session page is read again each
// time the card opens; until it arrives, the row shows this step instead of
// flashing the Task status. Display only, and bounded.
const lastShownSteps = new Map<string, ShownStep>();
const MAX_REMEMBERED_STEPS = 32;

function rememberShownStep(key: string, shown: ShownStep | undefined) {
  lastShownSteps.delete(key);
  if (!shown) return;
  lastShownSteps.set(key, shown);
  if (lastShownSteps.size > MAX_REMEMBERED_STEPS)
    lastShownSteps.delete(lastShownSteps.keys().next().value!);
}

export type WorkerStepsView = {
  /** The step the row shows, if any; else the row shows the Task status. */
  shown: ShownStep | undefined;
  /** The loaded steps, for the log. */
  progress: WorkerProgress | undefined;
  /** The Worker works now, by the owner's live evidence. */
  working: boolean;
  clock: Intl.DateTimeFormat;
};

/**
 * The Worker's steps, read only while a surface shows them: the activity
 * card while it is open, or the Notch while the Task runs. A step needs both its
 * call and its result, so this reads the bounded fifty-record page; the
 * three-record preview cannot hold them.
 */
export function useWorkerSteps(input: SessionHistoryInput): WorkerStepsView {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const { snapshot, transportError } = useSessionHistory(input, "latest");
  const records = useHistoryRecords(snapshot);
  const items = usePresentedRecords(records);
  const progress = useSteadyProgress(
    useMemo(
      () => workerProgress(sessionHistoryEntries(records, items)),
      [records, items]
    )
  );
  const clock = useMemo(
    () =>
      new Intl.DateTimeFormat(locale, {
        hour: "2-digit",
        minute: "2-digit",
        hourCycle: "h23",
      }),
    [locale]
  );
  const key = JSON.stringify([
    input.groupId,
    input.conversationId,
    input.participantId,
    locale,
  ]);
  const failed = transportError || Boolean(snapshot?.error);
  const loaded = !failed && snapshot !== undefined && snapshot.loaded !== "none";
  const step = loaded ? latestWorkerStep(progress) : undefined;
  const fresh: ShownStep | undefined = step && {
    at: step.at,
    words: stepWords(messages, step, step === progress.current),
  };
  useEffect(() => {
    if (loaded) rememberShownStep(key, fresh);
  }, [fresh?.at, fresh?.words, key, loaded]); // eslint-disable-line react-hooks/exhaustive-deps -- `fresh` is rebuilt each render; its fields are the facts.
  return {
    shown: loaded ? fresh : failed ? undefined : lastShownSteps.get(key),
    progress: loaded ? progress : undefined,
    working: loaded && progress.current !== undefined,
    clock,
  };
}

/**
 * A step in plain words. A command shows only the description the Worker
 * wrote for people. Finished steps read in the past tense; the step in
 * progress says what it does only when the Worker described it.
 */
export function stepWords(
  messages: Messages,
  step: WorkerStep,
  current: boolean
): string {
  const { detail } = step;
  if (step.kind === "thinking") return messages.chat_activity_thinking();
  if (step.kind === "command" && detail) return withFailure(messages, step, detail);
  if (current) return messages.chat_activity_step_other();
  const words = (() => {
    switch (step.kind) {
      case "command":
        return messages.chat_activity_step_command();
      case "read":
        return detail
          ? messages.chat_activity_step_read({ file: detail })
          : messages.chat_activity_step_browse();
      case "write":
        return detail
          ? messages.chat_activity_step_write({ file: detail })
          : messages.chat_activity_step_organize();
      case "edit":
        return detail
          ? messages.chat_activity_step_edit({ file: detail })
          : messages.chat_activity_step_organize();
      case "delete":
        return detail
          ? messages.chat_activity_step_delete({ file: detail })
          : messages.chat_activity_step_organize();
      case "browse":
        return messages.chat_activity_step_browse();
      case "organize":
        return messages.chat_activity_step_organize();
      case "search":
        return detail
          ? messages.chat_activity_step_search({ query: detail })
          : messages.chat_activity_step_search_any();
      case "update":
        return detail
          ? messages.chat_activity_step_update({ text: detail })
          : messages.chat_activity_step_update_any();
      default:
        return messages.chat_activity_step_other();
    }
  })();
  return withFailure(messages, step, words);
}

function withFailure(messages: Messages, step: WorkerStep, words: string) {
  return step.failed ? `${words} · ${messages.chat_activity_step_failed()}` : words;
}
