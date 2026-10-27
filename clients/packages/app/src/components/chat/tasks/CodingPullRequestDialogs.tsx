import type { CodingPullRequest } from "@comma/core/contract";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { PullRequestIcon } from "@comma/ui/components/icons";
import { isImeKeyEvent } from "@comma/ui/components/utils";
import { useState, type KeyboardEvent } from "react";

/**
 * Edits an open pull request's title and description, as Linear edits an issue: the title, then the description,
 * both prefilled with what GitHub has. Saved with the button or ⌘↵; an empty description clears it, an empty title
 * saves nothing.
 */
export function PullRequestEditDialog({
  busy,
  onClose,
  onSave,
  pr,
}: {
  busy: boolean;
  onClose: () => void;
  onSave: (changes: { title: string; body: string }) => void;
  pr: CodingPullRequest;
}) {
  const messages = useCommaMessages();
  const [title, setTitle] = useState(pr.title ?? "");
  const [body, setBody] = useState(pr.body ?? "");
  const unchanged = title === (pr.title ?? "") && body === (pr.body ?? "");
  const savable = !busy && title.trim() !== "" && !unchanged;
  const save = () => {
    if (savable) onSave({ title: title.trim(), body });
  };
  const saveOnCommandEnter = (event: KeyboardEvent) => {
    if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey)) return;
    if (isImeKeyEvent(event.nativeEvent)) return;
    event.preventDefault();
    save();
  };
  return (
    <Dialog
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      showCloseButton
      title={messages.coding_pr_edit_title()}
      titleLeading={
        <span className="comma-coding-pr-dialog-ref" data-state={pr.state}>
          <PullRequestIcon aria-hidden />
          {pr.number === null ? null : `#${pr.number}`}
        </span>
      }
      variant="compose"
    >
      <div className="comma-coding-pr-dialog" data-testid="coding-pr-edit">
        <input
          aria-label={messages.coding_pr_field_title()}
          className="comma-coding-pr-dialog-title"
          maxLength={256}
          onChange={(event) => setTitle(event.target.value)}
          onKeyDown={saveOnCommandEnter}
          placeholder={messages.coding_pr_field_title()}
          readOnly={busy}
          value={title}
        />
        <textarea
          aria-label={messages.coding_pr_field_body()}
          className="comma-coding-pr-dialog-body"
          onChange={(event) => setBody(event.target.value)}
          onKeyDown={saveOnCommandEnter}
          placeholder={messages.coding_pr_body_placeholder()}
          readOnly={busy}
          value={body}
        />
        <div className="comma-coding-pr-dialog-actions">
          <Button hierarchy="secondary-gray" onPress={onClose} size="xs">
            {messages.coding_pr_cancel()}
          </Button>
          <Button hierarchy="primary" isDisabled={!savable} onPress={save} size="xs">
            {messages.coding_pr_save()}
          </Button>
        </div>
      </div>
    </Dialog>
  );
}

/**
 * Asks before an open pull request merges: what merges, and how its checks stand where not all passed (GitHub has
 * the last word on whether a failed or running check holds it back).
 */
export function PullRequestMergeDialog({
  busy,
  onClose,
  onMerge,
  pr,
}: {
  busy: boolean;
  onClose: () => void;
  onMerge: () => void;
  pr: CodingPullRequest;
}) {
  const messages = useCommaMessages();
  const checks = pr.checks;
  const checksNote = !checks
    ? null
    : checks.failed > 0
      ? messages.coding_pr_checks_failed({
          failed: String(checks.failed),
          total: String(checks.total),
        })
      : checks.passed < checks.total
        ? messages.coding_pr_checks_running({
            running: String(checks.total - checks.passed),
            total: String(checks.total),
          })
        : null;
  return (
    <Dialog
      actions={[
        {
          label: messages.coding_pr_cancel(),
          hierarchy: "secondary-gray",
          onPress: onClose,
        },
        {
          label: messages.coding_pr_merge_action(),
          hierarchy: "primary",
          disabled: busy,
          onPress: onMerge,
        },
      ]}
      description={[pr.title, checksNote].filter(Boolean).join(" · ")}
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={
        pr.number === null
          ? messages.coding_pr_merge_confirm_unnamed()
          : messages.coding_pr_merge_confirm({ number: String(pr.number) })
      }
    />
  );
}
