import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui";
import { useCallback } from "react";
import type { CommaTaskLabelCatalog, CommaTaskLabelProposal } from "../../api";
import { taskLabelProposalLabels } from "./taskLabelProposal";

export type LabelProposalDecision = "approve" | "reject";

/** Names a proposal the way the person reads it: what would change, to which label. */
export function useLabelProposalTitle(
  catalog: CommaTaskLabelCatalog | undefined
): (proposal: CommaTaskLabelProposal) => string {
  const messages = useCommaMessages();
  return useCallback(
    (proposal: CommaTaskLabelProposal): string => {
      const payload = proposal.payload;
      const byId = new Map(
        (catalog?.labels ?? []).map((label) => [label.id, label.name])
      );
      const targetName = () => {
        const id = payload["label_id"];
        return (
          (typeof id === "string" && byId.get(id)) || String(payload["name"] ?? "")
        );
      };
      switch (proposal.op) {
        case "create":
          return messages.settings_labels_proposal_create({
            name: taskLabelProposalLabels(proposal)
              .map((label) => label.name)
              .join(" · "),
          });
        case "update":
          return messages.settings_labels_proposal_update({ name: targetName() });
        case "delete":
          return messages.settings_labels_proposal_delete({ name: targetName() });
        default:
          return messages.settings_labels_proposal_apply();
      }
    },
    [catalog, messages]
  );
}

/**
 * One row per request requiring a decision or attention, including approved
 * creations that could not yet be added to their Task.
 */
export function LabelProposalList({
  busy,
  onResolve,
  onViewTask,
  proposals,
  proposalTitle,
}: {
  /** Id of the proposal whose decision is in flight; every button waits. */
  busy: string | undefined;
  onResolve: (proposalId: string, decision: LabelProposalDecision) => void;
  onViewTask: (conversationId: string) => void;
  proposals: readonly CommaTaskLabelProposal[];
  proposalTitle: (proposal: CommaTaskLabelProposal) => string;
}) {
  const messages = useCommaMessages();
  if (proposals.length === 0) return null;
  return (
    <section
      aria-label={messages.settings_labels_proposals()}
      className="comma-task-labels-proposals"
      data-testid="task-label-proposals"
    >
      <h2 className="m-0 text-xs font-medium text-quaternary">
        {messages.settings_labels_proposals()}
      </h2>
      {proposals.map((proposal) => (
        <div
          className="comma-task-labels-proposal"
          data-testid={`label-proposal-${proposal.id}`}
          key={proposal.id}
        >
          <div className="comma-task-labels-proposal-copy">
            <span className="truncate text-primary">{proposalTitle(proposal)}</span>
            <span className="comma-task-labels-proposal-summary truncate">
              {proposal.summary?.trim() || messages.settings_labels_proposal_by()}
            </span>
            {proposal.payload.conversation_id ? (
              <button
                className="comma-chat-notice-card-action comma-chat-notice-card-action-quiet self-start"
                onClick={() => onViewTask(proposal.payload.conversation_id!)}
                type="button"
              >
                {messages.settings_labels_proposal_task({
                  title:
                    proposal.payload.conversation_title ||
                    messages.task_conversation_label(),
                })}
              </button>
            ) : null}
            {proposal.op === "create" ? (
              taskLabelProposalLabels(proposal).map((label) => (
                <span className="comma-task-labels-proposal-rule" key={label.name}>
                  {label.description?.trim()
                    ? messages.settings_labels_proposal_rule({
                        description: `${label.name}: ${label.description.trim()}`,
                      })
                    : messages.settings_labels_proposal_missing_rule()}
                </span>
              ))
            ) : typeof proposal.payload["description"] === "string" &&
              proposal.payload["description"].trim() ? (
              <span className="comma-task-labels-proposal-rule">
                {messages.settings_labels_proposal_rule({
                  description: proposal.payload["description"].trim(),
                })}
              </span>
            ) : null}
            {proposal.status === "approved" ? (
              <span
                role={proposal.application_status === "conflict" ? "alert" : "status"}
              >
                {proposal.application_status === "conflict"
                  ? messages.chat_label_proposal_application_conflict()
                  : messages.chat_label_proposal_application_pending()}
                {proposal.application_error ? ` ${proposal.application_error}` : ""}
              </span>
            ) : null}
          </div>
          {proposal.status === "pending" ? (
            <>
              <Button
                hierarchy="secondary-gray"
                isDisabled={busy !== undefined}
                onPress={() => onResolve(proposal.id, "reject")}
                size="sm"
              >
                {messages.settings_labels_proposal_reject()}
              </Button>
              <Button
                hierarchy="primary"
                isDisabled={busy !== undefined}
                onPress={() => onResolve(proposal.id, "approve")}
                size="sm"
              >
                {messages.settings_labels_proposal_approve()}
              </Button>
            </>
          ) : proposal.application_status === "pending" ? (
            <Button
              hierarchy="secondary-gray"
              isDisabled={busy !== undefined}
              onPress={() => onResolve(proposal.id, "approve")}
              size="sm"
            >
              {messages.chat_label_proposal_retry_application()}
            </Button>
          ) : null}
        </div>
      ))}
    </section>
  );
}
