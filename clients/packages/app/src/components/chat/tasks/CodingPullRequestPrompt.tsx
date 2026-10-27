import type { CodingPullRequest } from "@comma/core/contract";
import { useCall, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import {
  ChevronDownSmallIcon,
  PullRequestIcon,
  XIcon,
} from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { Button as AriaButton } from "react-aria-components";
import { useEffect, useState } from "react";
import {
  CreatePullRequestButton,
  proposable,
  pullRequestBlock,
  rememberCodingChanges,
  rememberedCodingChanges,
  usePullRequest,
  useReadTickets,
  useTurnEnds,
  useWindowReturns,
  type CodingPanelTarget,
} from "./CodingSession";

/** The prompt closed for a Task: by Task, or by Task and the merged pull request a new one would follow. */
const DISMISSED = "codingPullRequestPromptDismissed";
const promptKey = (taskId: string, pr: CodingPullRequest | null) =>
  pr?.state === "merged" && pr.number !== null ? `${taskId}@${pr.number}` : taskId;

/**
 * Above the input of a coding Task, when the moment is right (`due`: the Task is in review or done; the sandbox need
 * not run, as Comma opens the pushed branch on GitHub once it is gone): the branch has changes and nothing proposes
 * them (no pull request, a closed one, or a merged one the branch moved past), so the one decision left is offered as
 * a split chip (the pull request, or the draft its menu switches it to) and a close. Through a Worker's turn
 * (`working`) the chip waits and says so. The changes are read once the moment comes, again after a turn and when
 * the window returns, and the changes a surface of the Task last read stand in until then; a pull request made
 * anywhere takes the prompt away. Closing it is the account's, kept on this
 * device (a mark), so it stays closed after the app opens again; after a merged pull request the prompt asks afresh.
 */
export function CodingPullRequestPrompt({
  branch,
  coding,
  due,
  working,
}: {
  branch?: string | undefined;
  coding: CodingPanelTarget;
  due: boolean;
  working: boolean;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const [changes, setChanges] = useState(() => rememberedCodingChanges(coding.taskId));
  const [draft, setDraft] = useState(false);
  const pullRequest = usePullRequest(coding);
  const { taskId, workspaceId } = coding;
  const marks = useTopic({ topic: "marks", kind: DISMISSED }).value?.marks;
  const key = promptKey(taskId, pullRequest.pr ?? null);
  const closed = marks !== undefined && key in marks;
  const turnEnds = useTurnEnds(working);
  const windowReturns = useWindowReturns();
  const tickets = useReadTickets();
  // Read once the moment comes, after each turn and when the window returns (a pull request made on GitHub meanwhile).
  // The account's closed prompts are known first (they are kept on this device): a closed one reads nothing.
  const marksKnown = marks !== undefined;
  useEffect(() => {
    if (!due || !marksKnown || closed) return;
    const ticket = tickets.take();
    call("coding.changes", { workspaceId, taskId }).then(
      (next) => {
        if (!tickets.current(ticket)) return;
        rememberCodingChanges(taskId, next);
        setChanges(next);
      },
      () => {
        if (tickets.current(ticket)) setChanges(null);
      }
    );
  }, [
    call,
    closed,
    due,
    marksKnown,
    taskId,
    tickets,
    turnEnds,
    windowReturns,
    workspaceId,
  ]);

  if (!due || closed || !changes || changes.files.length === 0) return null;
  if (!proposable(pullRequest.pr ?? null)) return null;
  const blocked = pullRequestBlock(messages, { busy: pullRequest.busy, working });
  return (
    <output className="comma-chat-pr-prompt" data-testid="coding-pr-prompt">
      <PullRequestIcon aria-hidden className="comma-chat-pr-prompt-glyph" />
      <span className="comma-chat-pr-prompt-text">
        {branch
          ? messages.coding_pr_prompt({ branch })
          : messages.coding_pr_prompt_no_branch()}
      </span>
      <span className="comma-chat-pr-prompt-actions">
        <span className="comma-chat-pr-prompt-split">
          <CreatePullRequestButton
            blocked={blocked}
            className="comma-chat-pr-prompt-main"
            onPress={() => pullRequest.open(draft)}
            pressFeedback={false}
            testId="coding-pr-prompt-create"
          >
            {draft ? messages.coding_create_draft_pr() : messages.coding_create_pr()}
          </CreatePullRequestButton>
          <MenuTrigger>
            <AriaButton
              aria-label={messages.coding_pr_prompt_menu()}
              className="comma-task-coding-action comma-chat-pr-prompt-caret"
              data-no-press-feedback=""
              data-testid="coding-pr-prompt-menu"
            >
              <ChevronDownSmallIcon aria-hidden />
            </AriaButton>
            <MenuPopover placement="bottom end">
              <Menu
                aria-label={messages.coding_pr_prompt_menu()}
                disallowEmptySelection
                onSelectionChange={(keys) =>
                  setDraft(keys !== "all" && keys.has("draft"))
                }
                selectedKeys={[draft ? "draft" : "pr"]}
                selectionMode="single"
              >
                <MenuItem
                  id="pr"
                  selectionIndicator="check"
                  textValue={messages.coding_create_pr()}
                >
                  {messages.coding_create_pr()}
                </MenuItem>
                <MenuItem
                  id="draft"
                  selectionIndicator="check"
                  textValue={messages.coding_create_draft_pr()}
                >
                  {messages.coding_create_draft_pr()}
                </MenuItem>
              </Menu>
            </MenuPopover>
          </MenuTrigger>
        </span>
        <button
          aria-label={messages.coding_pr_prompt_dismiss()}
          className="comma-chat-pr-prompt-close"
          onClick={() => void call("marks.mark", { kind: DISMISSED, ids: [key] })}
          type="button"
        >
          <XIcon />
        </button>
      </span>
    </output>
  );
}
