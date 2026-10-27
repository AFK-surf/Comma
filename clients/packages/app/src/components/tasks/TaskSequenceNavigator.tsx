import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { ArrowDownIcon, ArrowUpIcon } from "@comma/ui/components/icons";
import { isEditableTarget } from "@comma/ui/components/settings-shortcut";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { useEffect, useState, type ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import { useOptionalChatRegistry } from "../chat/ChatProvider";
import { ConversationPreparation } from "../chat/prepareConversations";
import { isOnboardingOpen } from "../onboarding/onboardingPresence";
import { typeSelectPopoverSelector } from "../shortcuts/typeSelectPopover";
import { useTaskSequence, type TaskSequenceEntry } from "./taskSequence";

// K and M belong to the page only while focus is on it: a menu or list box
// takes typed letters to pick an option, and a dialog (settings, a preview)
// covers the page they would step.
const layeredSurfaceSelector = `${typeSelectPopoverSelector}, dialog, [role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"]`;

/**
 * "3 / 16" with down and up buttons in a Task page's header: steps to the
 * next or previous Task of the list it was opened from. M and K do the same
 * while focus is outside a text field.
 */
export function TaskSequenceNavigator({ conversationId }: { conversationId: string }) {
  const messages = useCommaMessages();
  const sequence = useTaskSequence();
  const index =
    sequence?.entries.findIndex((entry) => entry.conversationId === conversationId) ??
    -1;
  const total = sequence?.entries.length ?? 0;
  const shown = sequence !== undefined && index >= 0 && total > 1;
  const open = sequence?.open;

  useEffect(() => {
    if (!shown || !open) return undefined;
    const onKeyDown = (event: KeyboardEvent) => {
      if (
        event.defaultPrevented ||
        event.repeat ||
        event.altKey ||
        event.ctrlKey ||
        event.metaKey ||
        event.shiftKey ||
        isEditableTarget(event.target) ||
        (event.target instanceof Element &&
          event.target.closest(layeredSurfaceSelector)) ||
        isOnboardingOpen()
      ) {
        return;
      }
      const step = event.code === "KeyM" ? 1 : event.code === "KeyK" ? -1 : 0;
      const target = index + step;
      if (step === 0 || target < 0 || target >= total) return;
      event.preventDefault();
      open(target);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [index, open, shown, total]);

  usePrepareNeighbours(
    shown ? sequence.entries[index + 1] : undefined,
    shown ? sequence.entries[index - 1] : undefined
  );

  if (!shown || !open) return null;
  return (
    <div className="flex shrink-0 items-center gap-xs" data-testid="task-sequence">
      <span
        className="px-xs text-sm tabular-nums text-quaternary"
        data-testid="task-sequence-position"
      >
        <span aria-hidden>
          <span className="text-secondary">{index + 1}</span> / {total}
        </span>
        <span className="app-sr-only">
          {messages.task_sequence_position({
            index: String(index + 1),
            total: String(total),
          })}
        </span>
      </span>
      {/* One outlined pill, as the Inbox rail's toolbar buttons, split in two. */}
      <div className="inline-flex h-6 shrink-0 items-center rounded-full border border-primary bg-fg-button shadow-xs">
        <StepButton
          className="rounded-l-full pl-xxs"
          disabled={index >= total - 1}
          icon={<ArrowDownIcon />}
          label={messages.task_sequence_next()}
          onPress={() => open(index + 1)}
          shortcut="M"
          testId="task-sequence-next"
        />
        <span aria-hidden className="w-px shrink-0 self-stretch bg-border-primary" />
        <StepButton
          className="rounded-r-full pr-xxs"
          disabled={index <= 0}
          icon={<ArrowUpIcon />}
          label={messages.task_sequence_previous()}
          onPress={() => open(index - 1)}
          shortcut="K"
          testId="task-sequence-previous"
        />
      </div>
    </div>
  );
}

/**
 * Reads the Tasks a step would open, so the next page paints from a snapshot
 * instead of waiting a round trip. One preparation per page, retargeted on
 * each step: its bound (two reads at a time, no live channels) still holds.
 */
function usePrepareNeighbours(
  next: TaskSequenceEntry | undefined,
  previous: TaskSequenceEntry | undefined
) {
  const registry = useOptionalChatRegistry();
  const call = useCall();
  const [preparation, setPreparation] = useState<ConversationPreparation>();
  useEffect(() => {
    if (!registry) return undefined;
    const owner = new ConversationPreparation(registry, call);
    setPreparation(owner);
    return () => owner.dispose();
  }, [call, registry]);
  const nextKey = next && `${next.groupId}/${next.conversationId}`;
  const previousKey = previous && `${previous.groupId}/${previous.conversationId}`;
  useEffect(() => {
    // A Task a station hosts has no Salix conversation to prepare.
    preparation?.update(
      [next, previous].flatMap((entry) =>
        entry && !entry.conversationId.startsWith("station:")
          ? [{ conversationId: entry.conversationId, groupId: entry.groupId }]
          : []
      )
    );
    // The keys stand for the entries: a new list with the same neighbours reads nothing again.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [preparation, nextKey, previousKey]);
}

/** One half of the step pill. */
function StepButton({
  className,
  disabled,
  icon,
  label,
  onPress,
  shortcut,
  testId,
}: {
  className: string;
  disabled: boolean;
  icon: ReactNode;
  label: string;
  onPress: () => void;
  shortcut: string;
  testId: string;
}) {
  return (
    <Tooltip content={label} placement="bottom" shortcut={shortcut}>
      <AriaButton
        aria-label={label}
        className={cx(
          "inline-flex h-full w-7 shrink-0 cursor-pointer items-center justify-center border-0 bg-transparent p-0 text-markdown-icon-primary outline-none transition-colors duration-[var(--motion-duration-feedback-out)] hover:bg-secondary-hover focus-visible:shadow-focus-gray-shadow-xs data-[disabled]:cursor-default data-[disabled]:bg-transparent data-[disabled]:text-disabled [&_svg]:size-3 [&_svg]:transition-[scale] data-[pressed]:[&_svg]:scale-[var(--motion-scale-tactile-pressed)] motion-reduce:data-[pressed]:[&_svg]:scale-100",
          className
        )}
        data-testid={testId}
        isDisabled={disabled}
        onPress={onPress}
      >
        {icon}
      </AriaButton>
    </Tooltip>
  );
}
