import { useCommaMessages } from "@comma/i18n/react";
import {
  Checkbox,
  CircleCheckIcon,
  HoverCard,
  MoreHorizontalIcon,
  TagLabelIcon,
  TrashCanIcon,
} from "@comma/ui";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type {
  CommaApiClient,
  CommaTaskLabelCatalog,
  CommaTaskLabelProposal,
} from "../../../../api";
import type { LabelProposalDecision } from "../../../tasks/LabelProposalList";
import { taskLabelProposalLabels } from "../../../tasks/taskLabelProposal";
import { TaskLabelChip } from "../../../tasks/taskChips";
import { MessageInlineTask } from "../../thread/inline/MessageInlineElements";
import { useTaskLabelsCatalog } from "./useTaskLabelsCatalog";

type LabelChipProps = { color: string | undefined; name: string };
type InlineTaskRef = { conversationId: string; title: string | undefined };
type CardState = "pending" | "approved";
type CardGroup = {
  items: CommaTaskLabelProposal[];
  key: string;
  op: CommaTaskLabelProposal["op"];
  state: CardState;
};

/**
 * A batch shows this many chips in its row; the rest fold behind "···" and
 * list on hover, so ten creates stay one short sentence.
 */
const BATCH_CHIPS_SHOWN = 3;

/**
 * The proposals a conversation still shows. The card's own selection, shared so
 * the chat can place one card per reply that filed proposals.
 */
export function conversationLabelProposals(
  catalog: CommaTaskLabelCatalog | undefined,
  conversationId: string
): CommaTaskLabelProposal[] {
  return (catalog?.proposals ?? []).filter(
    (proposal) =>
      proposal.status !== "rejected" &&
      proposal.source_conversation_id === conversationId
  );
}

/**
 * Label changes the Router proposed from this conversation, offered for
 * confirmation right under its reply on the chat's notice frame: one card
 * per operation, its changes listed, Approve beside Reject, and an "Auto
 * approve" checkbox. The server records approval and the Group's standing
 * policy together; future decisions do not depend on this chat staying open.
 */
export function ChatLabelProposals({
  api,
  conversationId,
  groupId,
  proposals: proposalSubset,
  replyKey,
  revealOnAppear = true,
  workspaceId,
}: {
  api: CommaApiClient;
  conversationId: string;
  groupId: string;
  /**
   * The proposals this instance shows. The chat places one card per reply that
   * filed proposals and hands each card its own share; without it the card
   * shows every proposal of the conversation.
   */
  proposals?: readonly CommaTaskLabelProposal[] | undefined;
  /**
   * The latest reply; a new one may have filed proposals. Undefined means
   * this card does not watch for them.
   */
  replyKey: string | undefined;
  /**
   * Whether a card that appears after mount asks for the room. Only the newest
   * request should: an older card stays where the reader left it.
   */
  revealOnAppear?: boolean | undefined;
  workspaceId: string;
}) {
  const messages = useCommaMessages();
  const { catalog, refresh, replace } = useTaskLabelsCatalog(api, groupId);
  const policy = catalog?.approval_policy ?? "ask";
  const seenReply = useRef(replyKey);
  useEffect(() => {
    // A card that is not the newest one leaves the reading of new proposals
    // to the card that is.
    if (replyKey === undefined) return;
    if (seenReply.current === replyKey) return;
    seenReply.current = replyKey;
    void refresh();
  }, [refresh, replyKey]);

  const proposals = useMemo(
    () => proposalSubset ?? conversationLabelProposals(catalog, conversationId),
    [catalog, conversationId, proposalSubset]
  );

  // Each change reads as a verb phrase followed by the label itself, drawn
  // as the same chip the Task card and panel wear.
  const describe = useCallback(
    (
      proposal: CommaTaskLabelProposal
    ): { labels: LabelChipProps[]; task?: InlineTaskRef; verb: string } => {
      const payload = proposal.payload;
      const byId = new Map((catalog?.labels ?? []).map((label) => [label.id, label]));
      const text = (value: unknown) => (typeof value === "string" ? value : undefined);
      const existing = byId.get(text(payload["label_id"]) ?? "");
      switch (proposal.op) {
        case "create": {
          const taskId = payload.conversation_id;
          return {
            labels: taskLabelProposalLabels(proposal),
            ...(taskId
              ? { task: { conversationId: taskId, title: payload.conversation_title } }
              : {}),
            verb: taskId
              ? messages.chat_label_proposal_create_and_apply()
              : messages.chat_label_proposal_create(),
          };
        }
        case "update":
          return {
            labels: [
              {
                color: text(payload["color"]) ?? existing?.color,
                name: text(payload["name"]) ?? existing?.name ?? "",
              },
            ],
            verb: messages.chat_label_proposal_update(),
          };
        case "delete":
          return {
            labels: existing ? [{ color: existing.color, name: existing.name }] : [],
            verb: messages.chat_label_proposal_delete(),
          };
        default: {
          const ids = Array.isArray(payload["label_ids"]) ? payload["label_ids"] : [];
          const labels = ids.flatMap((id) => {
            const label = byId.get(text(id) ?? "");
            return label ? [{ color: label.color, name: label.name }] : [];
          });
          const taskId = text(payload["conversation_id"]);
          return taskId
            ? {
                labels,
                task: {
                  conversationId: taskId,
                  title: text(payload["conversation_title"]),
                },
                verb: messages.chat_label_proposal_apply_task(),
              }
            : { labels, verb: messages.chat_label_proposal_apply() };
        }
      }
    },
    [catalog, messages]
  );

  // Keep each Task's create-and-apply decision together, including its result.
  const groups = useMemo(() => {
    const byKey = new Map<string, CardGroup>();
    for (const proposal of proposals) {
      const state = proposal.status as CardState;
      const taskId = proposal.op === "create" ? proposal.payload.conversation_id : "";
      const key = `${proposal.op}:${taskId ?? ""}:${state}:${proposal.application_status ?? ""}`;
      const group = byKey.get(key) ?? { items: [], key, op: proposal.op, state };
      group.items.push(proposal);
      byKey.set(key, group);
    }
    return [...byKey.values()];
  }, [proposals]);
  const visibleKey = proposals.map((proposal) => proposal.id).join("|");
  // The transcript pins the reply's turn at its top and leaves what follows
  // to the reader; a decision should not hide below the fold. Once the
  // thread has settled its own anchoring, the cards ask for the room they
  // need, and only if they are actually cut off.
  const cardsRef = useRef<HTMLDivElement>(null);
  const revealedRef = useRef(false);
  useEffect(() => {
    if (!visibleKey) return undefined;
    const appearing = !revealedRef.current;
    revealedRef.current = true;
    if (appearing && !revealOnAppear) return undefined;
    const timer = window.setTimeout(() => {
      const cards = cardsRef.current;
      if (cards && typeof cards.scrollIntoView === "function") {
        cards.scrollIntoView({ behavior: "smooth", block: "nearest" });
      }
    }, 250);
    return () => window.clearTimeout(timer);
  }, [revealOnAppear, visibleKey]);

  const [busy, setBusy] = useState<string>();
  const [failed, setFailed] = useState(false);
  const decide = useCallback(
    async (
      key: string,
      items: readonly CommaTaskLabelProposal[],
      decision: LabelProposalDecision,
      autoApprove = false
    ) => {
      setBusy(key);
      setFailed(false);
      try {
        for (const proposal of items) {
          const next = await api.resolveTaskLabelProposal(
            groupId,
            proposal.id,
            decision,
            autoApprove ? { autoApprove: true } : undefined
          );
          replace(next);
        }
      } catch {
        // A legacy batch may have partly settled; the catalog owns each result.
        setFailed(true);
        void refresh();
      } finally {
        setBusy(undefined);
      }
    },
    [api, groupId, refresh, replace]
  );

  const setAutoApprove = useCallback(
    async (checked: boolean, group: CardGroup) => {
      if (busy !== undefined) return;
      if (checked && group.state === "pending") {
        await decide(group.key, group.items, "approve", true);
        return;
      }
      setBusy("policy");
      setFailed(false);
      try {
        replace(
          await api.setTaskLabelApprovalPolicy(groupId, checked ? "auto" : "ask")
        );
      } catch {
        setFailed(true);
      } finally {
        setBusy(undefined);
      }
    },
    [api, busy, decide, groupId, replace]
  );

  if (groups.length === 0) return null;
  return (
    <div
      className="comma-chat-label-proposals"
      data-testid="chat-label-proposals"
      ref={cardsRef}
    >
      {groups.map(({ items, key, op, state }) => {
        const { task: groupTask, verb: groupVerb } = describe(items[0]!);
        const applicationStatus = items[0]?.application_status;
        return (
          <section
            aria-label={messages.settings_labels_proposals()}
            className="comma-chat-notice-card comma-chat-label-proposals-card"
            data-state={state}
            data-application-status={applicationStatus}
            data-testid={`chat-label-proposals-${op}${state === "approved" ? "-approved" : ""}`}
            key={key}
          >
            {state === "approved" &&
            !["pending", "conflict"].includes(items[0]?.application_status ?? "") ? (
              <CircleCheckIcon aria-hidden className="comma-chat-notice-card-icon" />
            ) : op === "delete" ? (
              <TrashCanIcon aria-hidden className="comma-chat-notice-card-icon" />
            ) : (
              <TagLabelIcon aria-hidden className="comma-chat-notice-card-icon" />
            )}
            <div className="comma-chat-notice-card-content">
              <ul className="comma-chat-notice-card-copy comma-chat-label-proposals-list">
                {op === "apply" ? (
                  // Each Task is its own sentence.
                  items.map((proposal) => {
                    const { labels, task, verb } = describe(proposal);
                    return (
                      <li
                        data-testid={`chat-label-proposal-${proposal.id}`}
                        key={proposal.id}
                      >
                        <span>{verb}</span>
                        {task ? (
                          <>
                            <MessageInlineTask
                              api={api}
                              groupId={groupId}
                              showHoverPreview={false}
                              task={{
                                conversationId: task.conversationId,
                                unavailable: false,
                                ...(task.title ? { title: task.title } : {}),
                              }}
                              workspaceId={workspaceId}
                            />
                            <span>{messages.chat_label_proposal_apply_labels()}</span>
                          </>
                        ) : null}
                        {labels.map((label) => (
                          <TaskLabelChip
                            color={label.color}
                            key={label.name}
                            name={label.name}
                            size="sm"
                          />
                        ))}
                      </li>
                    );
                  })
                ) : (
                  // One verb, then the labels the batch names: three in the
                  // row, the rest listed on hover behind "···".
                  <BatchRow
                    chips={items.flatMap((proposal) =>
                      describe(proposal).labels.map((label) => ({
                        label,
                        proposalId: proposal.id,
                      }))
                    )}
                    op={op}
                    verb={groupVerb}
                    after={
                      op === "create" && groupTask ? (
                        <>
                          <span>{messages.chat_label_proposal_to_task()}</span>
                          <MessageInlineTask
                            api={api}
                            groupId={groupId}
                            showHoverPreview={false}
                            task={{
                              conversationId: groupTask.conversationId,
                              unavailable: false,
                              ...(groupTask.title ? { title: groupTask.title } : {}),
                            }}
                            workspaceId={workspaceId}
                          />
                        </>
                      ) : null
                    }
                  />
                )}
              </ul>
              <div className="comma-chat-notice-card-actions">
                {state === "approved" ? (
                  <span className="comma-chat-label-proposals-approved">
                    {items[0]?.application_status === "pending"
                      ? messages.chat_label_proposal_application_pending()
                      : items[0]?.application_status === "conflict"
                        ? messages.chat_label_proposal_application_conflict()
                        : op === "create" && items[0]?.application_status === "applied"
                          ? messages.chat_label_proposal_application_applied()
                          : messages.chat_label_proposal_approved()}
                  </span>
                ) : (
                  <div className="comma-chat-notice-card-actions-group">
                    <button
                      className="comma-chat-notice-card-action"
                      disabled={busy !== undefined}
                      onClick={() => void decide(key, items, "approve", false)}
                      type="button"
                    >
                      {messages.settings_labels_proposal_approve()}
                    </button>
                    <button
                      className="comma-chat-notice-card-action comma-chat-notice-card-action-quiet"
                      disabled={busy !== undefined}
                      onClick={() => void decide(key, items, "reject", false)}
                      type="button"
                    >
                      {messages.settings_labels_proposal_reject()}
                    </button>
                  </div>
                )}
                {state === "approved" && applicationStatus === "pending" ? (
                  <button
                    className="comma-chat-notice-card-action"
                    disabled={busy !== undefined}
                    onClick={() => void decide(key, items, "approve")}
                    type="button"
                  >
                    {messages.chat_label_proposal_retry_application()}
                  </button>
                ) : null}
                <Checkbox
                  checked={policy === "auto"}
                  className="comma-chat-label-proposals-auto"
                  disabled={busy !== undefined}
                  label={messages.chat_label_proposal_auto_approve()}
                  onChange={(event) =>
                    void setAutoApprove(event.target.checked, { items, key, op, state })
                  }
                  size="sm"
                />
              </div>
              {items
                .filter((item) => item.application_error)
                .map((item) => (
                  <p
                    className="comma-chat-label-proposals-error"
                    key={item.id}
                    role="alert"
                  >
                    {item.application_error}
                  </p>
                ))}
            </div>
          </section>
        );
      })}
      {failed ? (
        <p className="comma-chat-label-proposals-error" role="alert">
          {messages.settings_labels_save_failed()}
        </p>
      ) : null}
    </div>
  );
}

type BatchChip = { label: LabelChipProps; proposalId: string };

function BatchChipList({ chips }: { chips: BatchChip[] }) {
  return chips.map(({ label, proposalId }) => (
    <span
      className="contents"
      data-testid={`chat-label-proposal-${proposalId}`}
      key={`${proposalId}:${label.name}`}
    >
      <TaskLabelChip color={label.color} name={label.name} size="sm" />
    </span>
  ));
}

function BatchRow({
  after,
  chips,
  op,
  verb,
}: {
  after?: ReactNode;
  chips: BatchChip[];
  op: CommaTaskLabelProposal["op"];
  verb: string;
}) {
  const messages = useCommaMessages();
  const shown = chips.slice(0, BATCH_CHIPS_SHOWN);
  const rest = chips.slice(BATCH_CHIPS_SHOWN);
  return (
    <li data-testid={`chat-label-proposal-${op}`}>
      <span>{verb}</span>
      <BatchChipList chips={shown} />
      {rest.length > 0 ? (
        <HoverCard
          className="comma-chat-label-proposals-more-card"
          content={
            <ul className="comma-chat-label-proposals-more-list">
              {rest.map(({ label, proposalId }) => (
                <li
                  data-testid={`chat-label-proposal-${proposalId}`}
                  key={`${proposalId}:${label.name}`}
                >
                  <TaskLabelChip color={label.color} name={label.name} size="sm" />
                </li>
              ))}
            </ul>
          }
          delay={0}
          placement="bottom start"
        >
          <button
            aria-label={messages.tasks_labels_more({ count: rest.length })}
            className="comma-chat-label-proposals-more"
            data-testid="chat-label-proposals-more"
            type="button"
          >
            <MoreHorizontalIcon aria-hidden />
          </button>
        </HoverCard>
      ) : null}
      {after}
    </li>
  );
}
