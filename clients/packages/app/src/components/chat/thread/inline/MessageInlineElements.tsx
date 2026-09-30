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
import {
  InlineTask,
  plainTextWithLinks,
  taskStatusBucket,
  type InlineTaskProps,
  type TaskSummaryViewModel,
} from "@comma/ui";
import { Link } from "@tanstack/react-router";
import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
  type RefObject,
} from "react";
import {
  CommaApiError,
  type CommaApiClient,
  type CommaConversationPreview,
} from "../../../../api";
import {
  useProductInboxItem,
  type ProductInboxProjectionEnvelope,
} from "../../../../product-inbox";
import { inlineMessagePartPlainText } from "../../model/inlineElementContract";
import { splitUserTaskMentionParts } from "../../model/mentionSerialization";
export {
  messagePartsHaveInlineElements,
  sameMessageParts,
} from "../../model/inlineElementContract";
import { stripCommaProtocolMarkersPreservingWhitespace } from "../../model/protocol";
import { loadTaskPreview } from "./taskPreviewCache";
import {
  compileTrustedInlineDocument,
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
  api?: CommaApiClient | undefined;
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
        api={context.api}
        groupId={context.groupId}
        workspaceId={context.workspaceId}
      />
    ),
  },
  "inline-task": {
    render: (part, context) => (
      <MessageInlineTask
        api={context.api}
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
  const parts = splitUserTaskMentionParts(text);
  if (!parts) return plainTextWithLinks(text);
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
 * Turns ordered, trusted message parts into one Markdown source. Only generated
 * opaque keys enter the reserved tag; resource identity remains in React state.
 */
export function compileMessageMarkdown(
  parts: readonly ChatMessagePart[],
  context: InlineElementRenderContext
): CompiledMessageMarkdown {
  return compileTrustedInlineDocument(parts, {
    markdownText: (part) => (part.kind === "markdown" ? part.text : undefined),
    renderInline: (part) =>
      part.kind === "markdown" ? null : renderInlineMessagePart(part, context),
    isBlock: (part) => part.kind === "dynamic-ui",
    sanitizeMarkdown: stripCommaProtocolMarkersPreservingWhitespace,
  });
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
  api,
  groupId,
  showHoverPreview: showHoverPreviewOverride,
  task,
  workspaceId,
}: {
  api?: CommaApiClient | undefined;
  groupId: string;
  /** Overrides the adapter's choice; a card that is itself about the Task needs no preview. */
  showHoverPreview?: boolean | undefined;
  task: ChatInlineTask;
  workspaceId: string;
}) {
  const messages = useCommaMessages();
  const taskLinkAdapter = useContext(InlineTaskLinkAdapterContext);
  const [preview, setPreview] = useState<CommaConversationPreview>();
  const [revokedConversationId, setRevokedConversationId] = useState<string>();
  const requestGeneration = useRef(0);
  const conversationId = task.conversationId;
  const canonical = useTaskSummary(api, groupId, conversationId ?? "");
  const archiveAction = useArchiveAction(api, groupId, conversationId ?? "");
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
    showHoverPreview ? api : undefined,
    groupId
  );

  useEffect(() => {
    requestGeneration.current += 1;
    setPreview(undefined);
    setRevokedConversationId(undefined);
    return () => {
      requestGeneration.current += 1;
    };
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
  const badges =
    badgeLabels.length > 0 || badgeOrigin ? (
      <TaskBadgeChips labels={badgeLabels} origin={badgeOrigin} />
    ) : undefined;
  const handleOpenChange = (open: boolean) => {
    if (!open || !api) return;
    const generation = ++requestGeneration.current;
    void loadTaskPreview(api, groupId, conversationId).then(
      (nextPreview) => {
        if (requestGeneration.current === generation) setPreview(nextPreview);
      },
      (error: unknown) => {
        if (
          requestGeneration.current === generation &&
          error instanceof CommaApiError &&
          (error.status === 403 || error.status === 404)
        ) {
          setRevokedConversationId(conversationId);
        }
      }
    );
  };

  const target = {
    ariaLabel: messages.tasks_open({ title }),
    conversationId,
    groupId,
    title,
    workspaceId,
  };
  const onOpenTask = taskLinkAdapter.openTask
    ? () => taskLinkAdapter.openTask?.(target)
    : undefined;
  const onOpenInSidebar = taskLinkAdapter.openInSidebar
    ? () => taskLinkAdapter.openInSidebar?.(target)
    : undefined;
  return (
    <InlineTask
      archiveAction={archiveAction}
      badges={badges}
      dataTestId={`chat-inline-task-${conversationId}`}
      link={taskLinkAdapter.render({ ...target, onOpenTask, onOpenInSidebar })}
      onOpenTask={onOpenTask}
      onOpenInSidebar={onOpenInSidebar}
      previewBoundaryRef={taskLinkAdapter.previewBoundaryRef}
      {...(showHoverPreview ? { onOpenChange: handleOpenChange } : {})}
      showHoverPreview={showHoverPreview}
      task={{ ...summary, title }}
    />
  );
}

function taskSummary(
  task: ChatInlineTask,
  preview: CommaConversationPreview | undefined,
  projectedTask?: ProductInboxProjectionEnvelope["snapshot"]["items"][number]
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
