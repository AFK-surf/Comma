import { taskStatusBucketLabel } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  LoadingIndicator,
  MarkdownStream,
  taskStatusBucket,
  taskStatusIcon,
} from "@comma/ui";
import { useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { CommaApiClient, CommaConversationPreview } from "../../api";
import type {
  ChatImagePreviewRef,
  ChatMessage,
} from "../chat/model/conversationChannel";
import { MAX_ATTACHMENT_BYTES } from "../chat/model/protocol";
import { attachmentLabel } from "../chat/thread/attachments/attachmentLabels";
import {
  InlineTaskLinkAdapterProvider,
  passiveInlineTaskLinkAdapter,
  messagePartsHaveInlineElements,
  messagePartsPlainText,
} from "../chat/thread/inline/MessageInlineElements";
import {
  imagePreviewRefKey,
  agentBlobImagePreviewRef,
} from "../chat/thread/attachments/images/imagePreviewRefs";
import { MessageBlockExtras } from "../chat/thread/rows/MessageBlockExtras";
import { useCompiledMessageMarkdown } from "../chat/thread/rows/assistant/useCompiledMessageMarkdown";
import { ThreadFileSourceContext } from "../chat/thread/threadContexts";
import { useCommaUiThemeName } from "../commaUiTheme";
import { loadTaskConversationPreview } from "../search/taskConversationPreviewLoader";
import { normalizeUnixTimestampMs } from "../search/normalizeUnixTimestampMs";

const MESSAGE_LIMIT = 20;
/** Longer replies start folded, so the lead and the progress fit one screen. */
const FOLDED_BODY_CHARS = 280;

/**
 * Splits a reply that opens with a bold conclusion, such as
 * `修订结论：**…**。 evidence`, into that conclusion and the rest. A reply that
 * does not open this way has no lead and is shown whole.
 */
export function splitReplyLead(text: string): { lead?: string; body: string } {
  const match = /^(?:[^\n*]{0,12}[：:]\s*)?\*\*([^*\n]+?)\*\*[。.]?\s*/.exec(
    text.trim()
  );
  if (!match?.[1]) return { body: text.trim() };
  return { lead: match[1].trim(), body: text.trim().slice(match[0].length).trim() };
}

function plainLine(text: string) {
  return text
    .replace(/[*_`#>]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

type LoadState =
  | { status: "loading" }
  | { status: "error" }
  | { status: "ready"; messages: ChatMessage[] };

/**
 * A Task as a report: the Worker's latest reply first, then one line per
 * earlier message. Router instructions and earlier replies stay one tap away.
 */
export function TaskPanelReport({
  api,
  conversation,
  workspaceId,
}: {
  api: CommaApiClient;
  conversation: CommaConversationPreview;
  workspaceId: string;
}) {
  const messages = useCommaMessages();
  const [state, setState] = useState<LoadState>({ status: "loading" });
  const [retry, setRetry] = useState(0);
  const { id, group_id: groupId, status, title, updated_at: updatedAt } = conversation;

  const fileSource = useMemo(
    () => ({ api, groupId, conversationId: id }),
    [api, groupId, id]
  );

  useEffect(() => {
    const request = new AbortController();
    setState({ status: "loading" });
    loadTaskConversationPreview(
      api,
      { conversationId: id, groupId, status, title, updatedAt, workspaceId },
      AbortSignal.any([request.signal, AbortSignal.timeout(10_000)]),
      MESSAGE_LIMIT
    ).then(
      (data) => {
        if (!request.signal.aborted)
          setState({ status: "ready", messages: data.messages });
      },
      () => {
        if (!request.signal.aborted) setState({ status: "error" });
      }
    );
    return () => request.abort();
  }, [api, groupId, id, retry, status, title, updatedAt, workspaceId]);

  if (state.status === "loading") {
    return (
      <output className="flex items-center gap-md text-sm text-tertiary">
        <LoadingIndicator label={messages.common_loading()} />
      </output>
    );
  }
  if (state.status === "error") {
    return (
      <div className="flex flex-col items-start gap-xl" role="alert">
        <p className="text-sm text-tertiary">
          {messages.task_panel_messages_unavailable()}
        </p>
        <Button
          hierarchy="secondary-gray"
          onPress={() => setRetry((current) => current + 1)}
          size="sm"
        >
          {messages.common_retry()}
        </Button>
      </div>
    );
  }

  const workerName = conversation.bound_worker?.name ?? messages.chat_actor_worker();
  const latest = state.messages.findLast(
    (message) => message.role === "assistant" && message.actorRole === "worker"
  );
  return (
    <ThreadFileSourceContext.Provider value={fileSource}>
      <InlineTaskLinkAdapterProvider adapter={passiveInlineTaskLinkAdapter}>
        {latest ? (
          <LatestReply
            message={latest}
            workerName={workerName}
            groupId={groupId}
            workspaceId={workspaceId}
          />
        ) : (
          <p className="text-sm text-tertiary">{messages.task_panel_no_reply()}</p>
        )}
        <Progress
          conversation={conversation}
          latest={latest}
          messages={state.messages}
          workerName={workerName}
          workspaceId={workspaceId}
        />
      </InlineTaskLinkAdapterProvider>
    </ThreadFileSourceContext.Provider>
  );
}

function LatestReply({
  message,
  workerName,
  groupId,
  workspaceId,
}: {
  message: ChatMessage;
  workerName: string;
  groupId: string;
  workspaceId: string;
}) {
  const messages = useCommaMessages();
  // Keep structured parts in order. Only plain Markdown replies split their lead.
  const structured = messagePartsHaveInlineElements(message.parts);
  const { lead, body } = structured
    ? { lead: undefined, body: message.text }
    : splitReplyLead(message.text);
  const foldable = body.length > FOLDED_BODY_CHARS;
  const [open, setOpen] = useState(false);
  return (
    <section
      aria-label={messages.task_panel_latest_reply({ name: workerName })}
      className="comma-embedded-task-reply"
    >
      <p className="comma-embedded-task-eyebrow">
        {messages.task_panel_latest_reply({ name: workerName })}
      </p>
      {lead ? <p className="comma-embedded-task-lead">{lead}</p> : null}
      <div data-folded={foldable && !open ? "" : undefined}>
        <MessageContent
          message={message}
          content={body}
          groupId={groupId}
          workspaceId={workspaceId}
        />
      </div>
      {foldable ? (
        <button
          aria-expanded={open}
          className="comma-embedded-task-more"
          onClick={() => setOpen((current) => !current)}
          type="button"
        >
          {open ? messages.task_panel_show_less() : messages.task_panel_show_more()}
        </button>
      ) : null}
    </section>
  );
}

function Progress({
  conversation,
  latest,
  messages: chatMessages,
  workerName,
  workspaceId,
}: {
  conversation: CommaConversationPreview;
  workspaceId: string;
  latest: ChatMessage | undefined;
  messages: ChatMessage[];
  workerName: string;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const time = useTimeLabel();
  const [expanded, setExpanded] = useState<string>();
  const bucket = taskStatusBucket(conversation.status);
  return (
    <section
      aria-label={messages.task_panel_progress()}
      className="comma-embedded-task-progress"
    >
      <p className="comma-embedded-task-eyebrow">{messages.task_panel_progress()}</p>
      <ol>
        {chatMessages.map((message) => {
          const actor =
            message.role !== "assistant"
              ? messages.task_you()
              : message.actorRole === "router"
                ? messages.chat_actor_router()
                : workerName;
          const current = message === latest;
          const open = expanded === message.messageId;
          const text = messagePartsPlainText(
            message.parts ?? [{ kind: "markdown", text: message.text }],
            {
              task: messages.chat_ref_task(),
              unavailableTask: messages.chat_ref_task_unavailable(),
            }
          );
          const summary =
            plainLine(splitReplyLead(text).lead ?? text) ||
            [
              ...message.attachments.map((attachment) =>
                attachmentLabel(attachment, messages)
              ),
              ...message.refs.map((ref) => ref.title ?? messages.chat_ref_fallback()),
            ].join(" · ");
          const row = (
            <>
              <span className="comma-embedded-task-step-meta">
                {actor} · <time>{time(message.createdAt)}</time>
              </span>
              <span className="comma-embedded-task-step-summary">{summary}</span>
            </>
          );
          return (
            <li data-current={current ? "" : undefined} key={message.messageId}>
              {current ? (
                <div className="comma-embedded-task-step">{row}</div>
              ) : (
                <button
                  aria-expanded={open}
                  className="comma-embedded-task-step"
                  onClick={() => setExpanded(open ? undefined : message.messageId)}
                  type="button"
                >
                  {row}
                </button>
              )}
              {open ? (
                <div className="comma-embedded-task-step-full">
                  <MessageContent
                    message={message}
                    content={message.text}
                    groupId={conversation.group_id}
                    workspaceId={workspaceId}
                  />
                </div>
              ) : null}
            </li>
          );
        })}
        <li>
          <div className="comma-embedded-task-step">
            <span className="comma-embedded-task-step-meta">
              <time>{time(conversation.updated_at)}</time>
            </span>
            <span className="comma-embedded-task-step-summary">
              <span aria-hidden className="comma-embedded-task-step-status">
                {taskStatusIcon(bucket)}
              </span>
              {taskStatusBucketLabel(bucket, locale)}
            </span>
          </div>
        </li>
      </ol>
    </section>
  );
}

function MessageContent({
  message,
  content,
  groupId,
  workspaceId,
}: {
  message: ChatMessage;
  content: string;
  groupId: string;
  workspaceId: string;
}) {
  const isDark = useCommaUiThemeName() === "Dark mode";
  // The panel uses message snapshots, without live Task subscriptions or actions.
  const compiled = useCompiledMessageMarkdown(message, undefined, groupId, workspaceId);
  const source = useContext(ThreadFileSourceContext);
  const previewImage = useCallback(
    async (ref: ChatImagePreviewRef, signal?: AbortSignal) => {
      const attachment = message.attachments.find((candidate) => {
        const candidateRef = agentBlobImagePreviewRef(candidate);
        return (
          candidateRef && imagePreviewRefKey(candidateRef) === imagePreviewRefKey(ref)
        );
      });
      if (!source || attachment?.attachmentIndex === undefined) return undefined;
      // Read the authorized message attachment, never a caller-supplied blob locator.
      const blob = await source.api.fetchConversationAttachment(
        source.groupId,
        source.conversationId,
        message.messageId,
        attachment.attachmentIndex,
        {
          signal: AbortSignal.any([
            ...(signal ? [signal] : []),
            AbortSignal.timeout(10_000),
          ]),
        }
      );
      if (signal?.aborted || !blob.size || blob.size > MAX_ATTACHMENT_BYTES)
        return undefined;
      const url = URL.createObjectURL(blob);
      return { url, release: () => URL.revokeObjectURL(url) };
    },
    [message.attachments, message.messageId, source]
  );
  return (
    <>
      <MarkdownStream
        className="text-sm leading-5"
        content={compiled?.content ?? content}
        {...(compiled
          ? { inlineElements: compiled.inlineElements, nodes: compiled.nodes }
          : {})}
        final
        isDark={isDark}
        showCodeBlockHeader={false}
      />
      <MessageBlockExtras
        message={message}
        groupId={groupId}
        workspaceId={workspaceId}
        referenceMode="static"
        onPreviewLocalFile={previewImage}
      />
    </>
  );
}

/** Time of day for today, with the date for older messages. */
function useTimeLabel() {
  const locale = useCommaLocale();
  return (timestamp: number | undefined) => {
    const ms = normalizeUnixTimestampMs(timestamp);
    if (ms === undefined) return "";
    const date = new Date(ms);
    const today = new Date().toDateString() === date.toDateString();
    return new Intl.DateTimeFormat(locale, {
      hour: "2-digit",
      minute: "2-digit",
      ...(today ? {} : { month: "numeric", day: "numeric" }),
    }).format(date);
  };
}
