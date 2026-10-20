import type { ChatInlineTask } from "@comma/chat-contract";
import type { ChatMessage } from "@comma/core/chat";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  TaskSummaryCard,
  taskAriaLabel,
  taskStatusBucket,
} from "@comma/ui/components/task-workspace";
import { TaskArchiveMenu } from "@comma/ui/components/task-workspace/TaskArchiveMenu";
import { cx } from "@comma/ui/components/utils";
import {
  cloneElement,
  memo,
  useContext,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
  type ReactElement,
} from "react";
import { useProductInboxItem } from "../../../product-inbox";
import { taskOriginKey } from "../../tasks/taskOrigin";
import { useArchiveAction, useTaskSummary } from "../../tasks/useTaskArchive";
import { TaskBadgeChips } from "../../tasks/useTaskBadges";
import { useChatProductLease } from "../ChatProvider";
import { useTaskParticipantFeeds } from "../thread/activity/useActivityFocus";
import { useWorkerSteps } from "../thread/activity/useWorkerSteps";
import {
  renderInlineTaskLink,
  taskSummary,
  useInlineTaskLinkAdapter,
} from "../thread/inline/MessageInlineElements";
import { ChatTaskCardsContext, type ChatTaskCards } from "./chatTaskCards";
import { useTaskLabelsCatalogShared } from "./labels/useTaskLabelsCatalog";

const noSubscription = () => () => undefined;

/**
 * The Task card under a message that created one Task (an agent's message, in
 * addition to the Task's inline chip, or a person's Quick Chat). The card is
 * the Tasks board's own card, so a Task reads the same in the chat as in
 * Tasks. A message that names several new Tasks keeps its inline chips only
 * (chatTaskCards.ts).
 */
export const MessageTaskCards = memo(function MessageTaskCards({
  groupId,
  message,
  workspaceId,
}: {
  groupId: string;
  message: ChatMessage;
  workspaceId: string;
}) {
  const cards = useContext(ChatTaskCardsContext);
  const id = useSyncExternalStore(cards?.subscribe ?? noSubscription, () =>
    cards?.taskOf(message.messageId)
  );
  const task = useMemo(() => {
    if (!id) return undefined;
    for (const part of message.parts ?? []) {
      if (part.kind === "inline-task" && part.task.conversationId === id)
        return part.task;
    }
    return undefined;
  }, [id, message.parts]);
  if (!cards || !task) return null;
  return (
    <div className="comma-chat-task-cards" data-testid="chat-task-cards">
      <MessageTaskCard
        cards={cards}
        groupId={groupId}
        task={task}
        workspaceId={workspaceId}
      />
    </div>
  );
});

function MessageTaskCard({
  cards,
  groupId,
  task,
  workspaceId,
}: {
  cards: ChatTaskCards;
  groupId: string;
  task: ChatInlineTask;
  workspaceId: string;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const adapter = useInlineTaskLinkAdapter();
  const conversationId = task.conversationId!;
  const canonical = useTaskSummary(groupId, conversationId);
  const projected = useProductInboxItem(groupId, conversationId);
  const archiveAction = useArchiveAction(groupId, conversationId);
  const { catalog } = useTaskLabelsCatalogShared(groupId);
  // The live list and the canonical record outrank the message's snapshot,
  // as on the Task's inline chip.
  const summary = {
    ...taskSummary(task, undefined, projected),
    ...(canonical
      ? { statusBucket: taskStatusBucket(canonical.status), title: canonical.title }
      : {}),
  };
  const title = summary.title || messages.chat_ref_task();
  const running = summary.statusBucket === "in_progress";
  useEffect(
    () => (running ? cards.holdRunning(conversationId) : undefined),
    [cards, conversationId, running]
  );
  const follows = useSyncExternalStore(cards.subscribe, () =>
    cards.follows(conversationId)
  );
  const [step, setStep] = useState<string>();

  if (summary.statusBucket === "archived") return null;
  const labels = (canonical?.labels ?? []).flatMap(
    (id) => catalog?.labels.find((label) => label.id === id) ?? []
  );
  const origin = taskOriginKey(canonical?.origin);
  const loop = canonical?.loop ?? projected?.loop;
  const link = renderInlineTaskLink(adapter, {
    // Named like every Task card: by its Task, apart from the inline chip's
    // "Open task" link to the same Task.
    ariaLabel: taskAriaLabel({ ...summary, title }, locale),
    conversationId,
    groupId,
    title,
    workspaceId,
  });
  const interactive = link.type !== "span";
  return (
    <TaskArchiveMenu action={archiveAction} overlay="task-card">
      {cloneElement(
        link as ReactElement<{ className?: string }>,
        {
          className: cx("comma-chat-task-card", link.props.className),
          "data-testid": `chat-task-card-${conversationId}`,
          children: (
            <>
              {follows ? (
                <TaskWorkerStep
                  conversationId={conversationId}
                  groupId={groupId}
                  onStep={setStep}
                />
              ) : null}
              <TaskSummaryCard
                badges={
                  labels.length > 0 || origin || loop ? (
                    <TaskBadgeChips labels={labels} loop={loop} origin={origin} />
                  ) : undefined
                }
                interactive={interactive}
                progress={follows ? step : undefined}
                task={{ ...summary, title }}
                titleClassName="line-clamp-2"
              />
            </>
          ),
        } as Partial<{ className: string }>
      )}
    </TaskArchiveMenu>
  );
}

/** Reads a followed Task's Worker and reports its latest step in reader words. */
function TaskWorkerStep({
  conversationId,
  groupId,
  onStep,
}: {
  conversationId: string;
  groupId: string;
  onStep: (words: string | undefined) => void;
}) {
  const productLease = useChatProductLease();
  const ids = useMemo(() => [conversationId], [conversationId]);
  const worker = useTaskParticipantFeeds(groupId, ids).get(conversationId);
  if (!worker || !productLease) return null;
  return (
    <WorkerStepReader
      conversationId={conversationId}
      groupId={groupId}
      onStep={onStep}
      participantId={worker.participantId}
    />
  );
}

function WorkerStepReader({
  conversationId,
  groupId,
  onStep,
  participantId,
}: {
  conversationId: string;
  groupId: string;
  onStep: (words: string | undefined) => void;
  participantId: string;
}) {
  const history = useMemo(
    () => ({ conversationId, groupId, participantId }),
    [conversationId, groupId, participantId]
  );
  const words = useWorkerSteps(history).shown?.words;
  useEffect(() => onStep(words), [onStep, words]);
  // A Worker that goes, or a card that stops following it, leaves no step
  // behind: the card falls back to the status words.
  useEffect(() => () => onStep(undefined), [onStep]);
  return null;
}
