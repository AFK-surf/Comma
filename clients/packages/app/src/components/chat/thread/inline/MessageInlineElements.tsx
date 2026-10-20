import { DynamicUiWidget } from "../../dynamic-ui/DynamicUiWidget";
import { useTaskSummary, useArchiveAction } from "../../../tasks/useTaskArchive";
import { taskOriginKey } from "../../../tasks/taskOrigin";
import { TaskBadgeChips } from "../../../tasks/useTaskBadges";
import { useTaskLabelsCatalogShared } from "../../tasks/labels/useTaskLabelsCatalog";
import type {
  ChatInlineMessagePart,
  ChatInlineMessagePartKind,
  ChatInlineTask,
  ChatMessagePart,
} from "@comma/chat-contract";
import { useCommaMessages } from "@comma/i18n/react";
import { useTopic, type ProductInboxItem } from "@comma/core-client";
import { InlineTask, type InlineTaskProps } from "@comma/ui/components/inline-task";
import { plainTextWithLinks } from "@comma/ui/components/markdown-stream/plainTextLinks";
import {
  taskStatusBucket,
  type TaskSummaryViewModel,
} from "@comma/ui/components/task-workspace";
import { Link } from "@tanstack/react-router";
import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
  type RefObject,
} from "react";
import type { CommaConversationPreview } from "@comma/core/api-schemas";
import { useProductInboxItem } from "../../../../product-inbox";
import { inlineMessagePartPlainText } from "@comma/core/chat";
import { modelMentionsAsWords, splitUserTaskMentionParts } from "@comma/core/chat";
export { messagePartsHaveInlineElements, sameMessageParts } from "@comma/core/chat";
import { stripCommaProtocolMarkersPreservingWhitespace } from "@comma/core/chat";
import type { ChatMessage } from "@comma/core/chat";
import {
  elementKey,
  fromMarkdownTree,
  markdownTreeElements,
  partsDocument,
  type MarkdownTree,
} from "@comma/core/markdown";
import {
  escapeReservedInlineTags,
  type CompiledTrustedInlineDocument,
} from "../../../inline-elements/compileTrustedInlineDocument";

const INLINE_SENTINEL = "\u0000";
const INLINE_SENTINEL_PATTERN = new RegExp(
  `${INLINE_SENTINEL}([0-9a-z]+)${INLINE_SENTINEL}`,
  "g"
);

export type CompiledMessageMarkdown = CompiledTrustedInlineDocument;

export type InlineTaskLinkTarget = {
  ariaLabel: string;
  conversationId: string;
  groupId: string;
  title: string;
  workspaceId: string;
  onOpenTask?: (() => void) | undefined;
  onOpenInSidebar?: (() => void) | undefined;
};

export type InlineTaskLinkAdapter = {
  showHoverPreview?: boolean;
  previewBoundaryRef?: RefObject<Element | null> | undefined;
  openTask?: ((target: InlineTaskLinkTarget) => void) | undefined;
  openInSidebar?: ((target: InlineTaskLinkTarget) => void) | undefined;
  render(target: InlineTaskLinkTarget): NonNullable<InlineTaskProps["link"]>;
};

function inlineTaskLinkTarget(
  adapter: InlineTaskLinkAdapter,
  target: Omit<InlineTaskLinkTarget, "onOpenTask" | "onOpenInSidebar">
): InlineTaskLinkTarget {
  return {
    ...target,
    onOpenTask: adapter.openTask ? () => adapter.openTask?.(target) : undefined,
    onOpenInSidebar: adapter.openInSidebar
      ? () => adapter.openInSidebar?.(target)
      : undefined,
  };
}

/**
 * A surface's link to a Task with the openers its adapter provides. Task chips
 * and the chat's status bubble open a Task the same way.
 */
export function renderInlineTaskLink(
  adapter: InlineTaskLinkAdapter,
  target: Omit<InlineTaskLinkTarget, "onOpenTask" | "onOpenInSidebar">
) {
  return adapter.render(inlineTaskLinkTarget(adapter, target));
}

export const routeInlineTaskLinkAdapter = {
  render: ({
    ariaLabel,
    conversationId,
    groupId,
    workspaceId,
    onOpenTask,
    onOpenInSidebar,
  }) => (
    <Link
      aria-label={ariaLabel}
      onClick={(event) => {
        const open = event.metaKey || event.ctrlKey ? onOpenTask : onOpenInSidebar;
        if (!open || event.button !== 0 || event.shiftKey || event.altKey) return;
        event.preventDefault();
        open();
      }}
      params={{ conversationId, groupId, workspaceId }}
      to="/tasks/$workspaceId/$groupId/$conversationId"
    />
  ),
} satisfies InlineTaskLinkAdapter;

export const staticInlineTaskLinkAdapter = {
  render: () => <span />,
} satisfies InlineTaskLinkAdapter;

export const passiveInlineTaskLinkAdapter = {
  render: () => <span className="comma-inline-task--passive" />,
  showHoverPreview: false,
} satisfies InlineTaskLinkAdapter;

const InlineTaskLinkAdapterContext = createContext<InlineTaskLinkAdapter>(
  staticInlineTaskLinkAdapter
);

/** This surface's way to open a Task, as its Task chips use it. */
export function useInlineTaskLinkAdapter() {
  return useContext(InlineTaskLinkAdapterContext);
}

export function InlineTaskLinkAdapterProvider({
  adapter,
  children,
}: {
  adapter: InlineTaskLinkAdapter;
  children: ReactNode;
}) {
  return (
    <InlineTaskLinkAdapterContext.Provider value={adapter}>
      {children}
    </InlineTaskLinkAdapterContext.Provider>
  );
}

type InlineElementRenderContext = {
  /**
   * The surface shows the core's live data: a Task chip's hover preview and a
   * generated UI widget. A static surface (a Task's report) shows neither.
   */
  live?: boolean | undefined;
  groupId: string;
  workspaceId: string;
};

type InlineElementRendererAdapter<Kind extends ChatInlineMessagePartKind> = {
  render(
    part: Extract<ChatInlineMessagePart, { kind: Kind }>,
    context: InlineElementRenderContext
  ): ReactNode;
};

type InlineElementRendererRegistry = {
  [Kind in ChatInlineMessagePartKind]: InlineElementRendererAdapter<Kind>;
};

/**
 * Renderer-only half of the registry. It stays out of ConversationChannel's
 * Electron Main dependency graph while remaining exhaustive over the same
 * chat-contract inline-kind SSOT as the pure decoder registry.
 */
const inlineElementRenderers = {
  "dynamic-ui": {
    render: (part, context) => (
      <DynamicUiWidget
        part={part}
        live={context.live === true}
        groupId={context.groupId}
        workspaceId={context.workspaceId}
      />
    ),
  },
  // Setting a device up needs a phone near it: here the offer shows as the device's name.
  "device-setup-offer": {
    render: (part) => <span>{part.offer.name}</span>,
  },
  // Drawn after the message's text by its row (MessageQuestionCards), outside the Markdown renderer.
  question: {
    render: () => null,
  },
  // The answer's own words show as the person's message; the card shows what was picked.
  "question-answer": {
    render: () => null,
  },
  "inline-task": {
    render: (part, context) => (
      <MessageInlineTask
        live={context.live}
        groupId={context.groupId}
        task={part.task}
        workspaceId={context.workspaceId}
      />
    ),
  },
} satisfies InlineElementRendererRegistry;

function renderInlineMessagePart(
  part: ChatInlineMessagePart,
  context: InlineElementRenderContext
) {
  // See inlineMessagePartPlainText: the mapped registry proves key coverage;
  // this is the single erased dispatch point for the discriminated union.
  const renderer = inlineElementRenderers[part.kind] as InlineElementRendererAdapter<
    typeof part.kind
  >;
  return renderer.render(part, context);
}

/**
 * Inline content for a user bubble: the user's own `[title](comma:task/<id>)`
 * mention links render as the same InlineTask chips assistant references use,
 * splicing the pill into the sentence position the mention was typed at.
 * Plain HTTP(S) URLs use the existing chat link routing. All other text stays literal.
 * Returns undefined when neither a mention nor a URL needs a rendered element.
 */
export function userMessageContentWithMentions(
  text: string,
  context: InlineElementRenderContext
): ReactNode | undefined {
  const shown = modelMentionsAsWords(text);
  const parts = splitUserTaskMentionParts(shown);
  // A model mention changed the words: they are rendered even without a link.
  if (!parts) return plainTextWithLinks(shown) ?? (shown === text ? undefined : shown);
  return parts.map((part, index) =>
    part.kind === "markdown" ? (
      // eslint-disable-next-line react/no-array-index-key -- static split of one string
      <span key={index}>{plainTextWithLinks(part.text) ?? part.text}</span>
    ) : (
      // eslint-disable-next-line react/no-array-index-key -- static split of one string
      <span key={index}>{renderInlineMessagePart(part, context)}</span>
    )
  );
}

/**
 * A committed message as its Markdown renderer draws it: the core's parse of
 * it (`ChatMessage.markdown`) as the renderer's nodes, and each Task chip or
 * card the tree names drawn in its place. The message is never parsed here.
 */
export function messageMarkdownElements(
  message: ChatMessage,
  context: InlineElementRenderContext
): CompiledTrustedInlineDocument | undefined {
  if (!message.markdown) return undefined;
  // Only the elements the parse kept: one inside a private fence is not shown.
  const shown = markdownTreeElements(message.markdown as MarkdownTree);
  const inlineElements = new Map<string, ReactNode>();
  (message.parts ?? []).forEach((part, index) => {
    if (part.kind !== "markdown" && shown.has(elementKey(index)))
      inlineElements.set(elementKey(index), renderInlineMessagePart(part, context));
  });
  return {
    // The document's text, each element as its tag: the source the renderer's nodes came from.
    content: partsDocument(message.parts ?? [], {
      markdownText: (part) =>
        part.kind === "markdown"
          ? part.text
          : part.kind === "question"
            ? ""
            : undefined,
      isBlock: (part) => part.kind === "dynamic-ui",
      sanitizeMarkdown: stripCommaProtocolMarkersPreservingWhitespace,
    }).content,
    inlineElements,
    nodes: fromMarkdownTree(message.markdown as MarkdownTree),
  };
}

export function messagePartsPlainText(
  parts: readonly ChatMessagePart[],
  labels: { task: string; unavailableTask: string }
) {
  const replacements = new Map<string, string>();
  let source = "";
  parts.forEach((part, index) => {
    if (part.kind === "markdown") {
      source += escapeInlineSentinels(part.text);
      return;
    }
    const sentinel = inlineSentinel(index);
    replacements.set(sentinel, inlineMessagePartPlainText(part, labels));
    source += sentinel;
  });
  return replaceInlineSentinels(
    stripCommaProtocolMarkersPreservingWhitespace(source),
    replacements,
    (text) => text
  );
}

export { escapeReservedInlineTags };

function inlineSentinel(index: number) {
  return `${INLINE_SENTINEL}${index.toString(36)}${INLINE_SENTINEL}`;
}

function escapeInlineSentinels(text: string) {
  return text.replaceAll(INLINE_SENTINEL, "�");
}

function replaceInlineSentinels(
  source: string,
  replacements: ReadonlyMap<string, string>,
  transformText: (text: string) => string
) {
  let content = "";
  let offset = 0;
  for (const match of source.matchAll(INLINE_SENTINEL_PATTERN)) {
    const index = match.index;
    content += transformText(source.slice(offset, index));
    content += replacements.get(match[0]) ?? "";
    offset = index + match[0].length;
  }
  return content + transformText(source.slice(offset));
}

/** One Task named inline: the chip with its hover preview and link, kept canonical. */
export function MessageInlineTask({
  live = false,
  groupId,
  showHoverPreview: showHoverPreviewOverride,
  task,
  workspaceId,
}: {
  /** Reads the Task's preview when its hover card opens. */
  live?: boolean | undefined;
  groupId: string;
  /** Overrides the adapter's choice; a card that is itself about the Task needs no preview. */
  showHoverPreview?: boolean | undefined;
  task: ChatInlineTask;
  workspaceId: string;
}) {
  const messages = useCommaMessages();
  const taskLinkAdapter = useContext(InlineTaskLinkAdapterContext);
  // Each opening of the card asks the core again (it reads again only once what it keeps is old); what it answered
  // last stays shown meanwhile.
  const [asked, setAsked] = useState<{ conversationId: string; read: number }>();
  const [preview, setPreview] = useState<CommaConversationPreview>();
  const [revokedConversationId, setRevokedConversationId] = useState<string>();
  const conversationId = task.conversationId;
  const { value: answer } = useTopic(
    asked && asked.conversationId === conversationId && live
      ? {
          topic: "taskPreview",
          group: groupId,
          conversation: asked.conversationId,
          read: String(asked.read),
        }
      : null
  );
  useEffect(() => {
    if (!asked || asked.conversationId !== conversationId) return;
    if (answer?.status === "ready") setPreview(answer.preview);
    if (answer?.status === "revoked") setRevokedConversationId(conversationId);
  }, [answer, asked, conversationId]);
  const canonical = useTaskSummary(groupId, conversationId ?? "");
  const archiveAction = useArchiveAction(groupId, conversationId ?? "");
  // Only this Task's item: another Task's update leaves this chip as it is.
  const projectedTask = useProductInboxItem(groupId, conversationId ?? "");
  const revoked = revokedConversationId === conversationId;
  const unavailable = task.unavailable || revoked || !conversationId;
  const currentPreview =
    preview !== undefined &&
    preview.id === conversationId &&
    (task.updatedAt === undefined || preview.updated_at >= task.updatedAt)
      ? preview
      : undefined;
  const showHoverPreview =
    showHoverPreviewOverride ?? taskLinkAdapter.showHoverPreview !== false;
  // The hover card wears the Task's chips like every other Task card; the
  // preview (read on open) or the canonical record names the ids, the
  // Group's shared catalog names the labels. Subscribed ahead of the early
  // returns below so live archive updates preserve hook order.
  const { catalog } = useTaskLabelsCatalogShared(
    showHoverPreview ? groupId : undefined
  );

  useEffect(() => {
    setAsked(undefined);
    setPreview(undefined);
    setRevokedConversationId(undefined);
  }, [task.conversationId]);

  if (unavailable) {
    return (
      <InlineTask
        dataTestId="chat-inline-task-unavailable"
        task={taskSummary(task, undefined)}
        unavailable
        unavailableLabel={messages.chat_ref_task_unavailable()}
      />
    );
  }

  // Loading and failed reads retain the message's navigable snapshot. A known
  // archive wins over old message/preview data until canonical restoration.
  const latest =
    currentPreview && currentPreview.updated_at > (canonical?.updated_at ?? 0)
      ? currentPreview
      : canonical;
  const summary = {
    ...taskSummary(task, currentPreview, projectedTask),
    ...(latest
      ? { statusBucket: taskStatusBucket(latest.status), title: latest.title }
      : {}),
  };
  const title = summary.title || messages.chat_ref_task();
  if (canonical?.status === "archived" || summary.statusBucket === "archived") {
    return (
      <InlineTask
        dataTestId={`chat-inline-task-${conversationId}`}
        task={{ ...summary, title, statusBucket: "archived" }}
      />
    );
  }
  const labelIds = latest?.labels ?? [];
  const badgeLabels = labelIds.flatMap(
    (id) => catalog?.labels.find((label) => label.id === id) ?? []
  );
  const badgeOrigin = taskOriginKey(latest?.origin);
  // The preview read carries no Loop; the summary and the list do.
  const badgeLoop = canonical?.loop ?? projectedTask?.loop;
  const badges =
    badgeLabels.length > 0 || badgeOrigin || badgeLoop ? (
      <TaskBadgeChips labels={badgeLabels} loop={badgeLoop} origin={badgeOrigin} />
    ) : undefined;
  const handleOpenChange = (open: boolean) => {
    if (!open || !live) return;
    setAsked((current) => ({ conversationId, read: (current?.read ?? 0) + 1 }));
  };

  const target = inlineTaskLinkTarget(taskLinkAdapter, {
    ariaLabel: messages.tasks_open({ title }),
    conversationId,
    groupId,
    title,
    workspaceId,
  });
  return (
    <InlineTask
      archiveAction={archiveAction}
      badges={badges}
      dataTestId={`chat-inline-task-${conversationId}`}
      link={taskLinkAdapter.render(target)}
      onOpenTask={target.onOpenTask}
      onOpenInSidebar={target.onOpenInSidebar}
      previewBoundaryRef={taskLinkAdapter.previewBoundaryRef}
      {...(showHoverPreview ? { onOpenChange: handleOpenChange } : {})}
      showHoverPreview={showHoverPreview}
      task={{ ...summary, title }}
    />
  );
}

export function taskSummary(
  task: ChatInlineTask,
  preview: CommaConversationPreview | undefined,
  projectedTask?: ProductInboxItem
): TaskSummaryViewModel {
  const status = projectedTask?.status ?? preview?.status ?? task.status ?? "unknown";
  return {
    activityStatus:
      projectedTask?.status ??
      preview?.activity_status ??
      task.activityStatus ??
      "idle",
    freshness:
      projectedTask?.freshness ??
      preview?.freshness?.state ??
      task.freshness ??
      "unknown",
    id:
      projectedTask?.conversationId ??
      preview?.id ??
      task.conversationId ??
      "unavailable",
    statusBucket: taskStatusBucket(status),
    title: projectedTask?.title ?? preview?.title ?? task.title ?? "",
    updatedAt: projectedTask?.updatedAt ?? preview?.updated_at ?? task.updatedAt ?? 0,
  };
}
