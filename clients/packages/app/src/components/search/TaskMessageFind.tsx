import { useCall } from "@comma/core-client";
import type { TaskMessageSearchValue } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import {
  ArrowDownIcon,
  ArrowUpIcon,
  SearchIcon,
  XIcon,
} from "@comma/ui/components/icons";
import { Tooltip } from "@comma/ui/components/tooltip";
import { useEffect, useState } from "react";
import { Button as AriaButton } from "react-aria-components";
import { StepButton } from "../tasks/TaskSequenceNavigator";

/**
 * A search a Task was opened from, in its header: the query, which of its
 * matching Messages is shown ("2 / 5"), and steps to the previous (older) or
 * next one. The Messages are read once, oldest first.
 */
export function TaskMessageFind({
  conversationId,
  current,
  groupId,
  onClose,
  onStep,
  query,
}: {
  conversationId: string;
  /** The Message shown now. */
  current: string;
  groupId: string;
  onClose: () => void;
  onStep: (messageId: string) => void;
  query: string;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const [found, setFound] = useState<TaskMessageSearchValue>();
  useEffect(() => {
    const controller = new AbortController();
    call(
      "search.taskMessages",
      { query, group: groupId, conversation: conversationId },
      controller.signal
    ).then(
      (value) => {
        if (!controller.signal.aborted) setFound(value);
      },
      () => undefined
    );
    return () => controller.abort();
  }, [call, conversationId, groupId, query]);

  const ids = found?.messageIds ?? [];
  const total = ids.length;
  const index = ids.indexOf(current);
  return (
    <div className="flex min-w-0 shrink items-center gap-xs" data-testid="task-find">
      <span className="flex min-w-0 items-center gap-xxs text-sm text-secondary">
        <span aria-hidden className="comma-icon-slot size-4 shrink-0 [&_svg]:size-4">
          <SearchIcon />
        </span>
        <span className="min-w-0 max-w-40 truncate" title={query}>
          {query}
        </span>
      </span>
      {total > 0 ? (
        <span
          className="px-xs text-sm tabular-nums text-quaternary"
          data-testid="task-find-position"
        >
          <span aria-hidden>
            <span className="text-secondary">{index >= 0 ? index + 1 : "–"}</span> /{" "}
            {total}
          </span>
          {index >= 0 ? (
            <span className="app-sr-only">
              {messages.task_find_position({
                index: String(index + 1),
                total: String(total),
              })}
            </span>
          ) : null}
        </span>
      ) : null}
      <div className="inline-flex h-6 shrink-0 items-center rounded-full border border-primary bg-fg-button shadow-xs">
        <StepButton
          className="rounded-l-full pl-xxs"
          disabled={total === 0 || index >= total - 1}
          icon={<ArrowDownIcon />}
          label={messages.task_find_next()}
          onPress={() => onStep(ids[index + 1]!)}
          testId="task-find-next"
        />
        <span aria-hidden className="w-px shrink-0 self-stretch bg-border-primary" />
        <StepButton
          className="rounded-r-full pr-xxs"
          disabled={total === 0 || index === 0}
          icon={<ArrowUpIcon />}
          label={messages.task_find_previous()}
          onPress={() => onStep(ids[index < 0 ? total - 1 : index - 1]!)}
          testId="task-find-previous"
        />
      </div>
      <Tooltip content={messages.task_find_close()} placement="bottom">
        <AriaButton
          aria-label={messages.task_find_close()}
          className="inline-flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-full border-0 bg-transparent p-0 text-markdown-icon-primary outline-none transition-colors duration-[var(--motion-duration-feedback-out)] hover:bg-secondary-hover focus-visible:shadow-focus-gray-shadow-xs [&_svg]:size-3"
          data-testid="task-find-close"
          onPress={onClose}
        >
          <XIcon />
        </AriaButton>
      </Tooltip>
    </div>
  );
}
