import type { ChatTaskRun } from "@comma/chat-contract";
import type {
  CodingChanges,
  CodingHistory,
  CodingPullRequest,
  CodingHistoryItem,
  CodingStep,
  CodingUsage,
} from "@comma/core/contract";
import { useCall, useTopic } from "@comma/core-client";
import { formatNumber } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  ArrowUpRightIcon,
  BranchIcon,
  ChatBubbleIcon,
  ChevronRightSmallIcon,
  CircleCheckFilledIcon,
  CircleCheckIcon,
  CircleDashedIcon,
  CircleXIcon,
  CloudIcon,
  ConsoleSimpleIcon,
  DifferenceModifiedIcon,
  GithubBrandIcon,
  LoaderIcon,
  MergeConflictIcon,
  MergedIcon,
  MoreHorizontalIcon,
  PullRequestClosedIcon,
  PullRequestIcon,
} from "@comma/ui/components/icons";
import { HOVER_PANEL_ITEM, HoverPanel } from "@comma/ui/components/hover-card";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  getMenuPointerOffsets,
  menuClasses,
  type MenuPointerOffsets,
} from "@comma/ui/components/menu";
import { toast } from "@comma/ui/components/toast";
import { Tooltip } from "@comma/ui/components/tooltip";
import { Button as AriaButton } from "react-aria-components";
import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type MouseEvent,
  type ReactNode,
} from "react";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../../../nativePlatformActions";
import { useTimeLabel } from "../../tasks/useTimeLabel";
import { useWindowAttended } from "../../useWindowAttended";
import {
  PullRequestEditDialog,
  PullRequestMergeDialog,
} from "./CodingPullRequestDialogs";

/** The message catalog as the hook hands it out; the catalog exports no type of its own. */
type CommaMessages = ReturnType<typeof useCommaMessages>;

/**
 * A coding Task in the Task details panel: a Task that runs on a cloud sandbox of its own with a GitHub repository
 * checked out (`runs_on {kind: sandbox}`). Its facts are rows of the panel's own kind: the sandbox and where it
 * stands, the repository and session branch and the terminal in Environment; its changes and the execution record as
 * sections before Activity, in Activity's timeline language.
 *
 * The place (`run.place`) comes with the Task's detail and its status stream, so those rows need no request. The
 * changes and the record are each one request, made when the panel first shows them, again once the Worker ends a
 * turn, the sandbox's state changes or the window comes back to the front, and after an action here; never on a
 * timer. A read answered after a newer one is dropped. Until a read answers, what the Task's surfaces last read in this
 * run of the app stands in, so a Task opened again shows its changes and record at once.
 */
export type CodingPanelTarget = { workspaceId: string; taskId: string };

export type SandboxPlace = Extract<ChatTaskRun["place"], { kind: "sandbox" }>;
/** What the Task's sandbox and GitHub answered last, as the server keeps it: shown until the panel's own reads answer. */
export type CodingFacts = NonNullable<ChatTaskRun["facts"]>;

const SANDBOX_STATES = [
  "starting",
  "ready",
  "stopped",
  "lost",
  "failed",
  "ended",
] as const;

/** More steps under one request than this fold all but the first two and the latest three. */
const STEP_FOLD = { above: 8, head: 2, tail: 3 };

const fence = (lang: string, text: string) => "```" + lang + "\n" + text + "\n```";

/** A code block of a detail: the code alone, without the chat's language header and copy button. */
export function Code({ lang, text }: { lang: string; text: string }) {
  return (
    <MarkdownStream
      className="text-xs"
      content={fence(lang, text)}
      final
      showCodeBlockCopy={false}
      showCodeBlockHeader={false}
    />
  );
}

/**
 * A unified diff line by line, whole: its hunk headers, the lines added and removed in their colours, the rest as it
 * is. Where the hunk headers give them, a gutter shows each line's number in the file (the old file's for a removed
 * line). Wrapped to the width when `wrap`, else as wide as its longest line, scrolled.
 */
export function DiffBlock({ diff, wrap = false }: { diff: string; wrap?: boolean }) {
  const rows = diffRows(diff);
  const numbered = rows.some((row) => row.number !== null);
  return (
    <div
      className="comma-diff"
      data-numbered={numbered ? "true" : undefined}
      data-wrap={wrap ? "true" : "false"}
    >
      {rows.map((row, index) => (
        <div className="comma-diff-line" data-kind={row.kind} key={index}>
          {numbered ? (
            <span aria-hidden className="comma-diff-gutter">
              {row.number ?? ""}
            </span>
          ) : null}
          <span className="comma-diff-code">{row.text === "" ? " " : row.text}</span>
        </div>
      ))}
    </div>
  );
}

type DiffLineKind = "hunk" | "meta" | "add" | "del" | "context";
type DiffRow = { kind: DiffLineKind; text: string; number: number | null };

/** The diff's lines with their numbers: a hunk header starts both counts; context moves both, a side its own. */
function diffRows(diff: string): DiffRow[] {
  let old = 0;
  let next = 0;
  let inHunk = false;
  return diff
    .replace(/\n$/, "")
    .split("\n")
    .map((line): DiffRow => {
      const kind = diffLineKind(line);
      if (kind === "hunk") {
        const header = /^@@ -(\d+)(?:,\d+)? \+(\d+)/.exec(line);
        if (header) {
          old = Number(header[1]);
          next = Number(header[2]);
          inHunk = true;
        }
        return { kind, text: line, number: null };
      }
      if (!inHunk || kind === "meta") return { kind, text: line, number: null };
      if (kind === "add") return { kind, text: line, number: next++ };
      if (kind === "del") return { kind, text: line, number: old++ };
      old += 1;
      return { kind, text: line, number: next++ };
    });
}

function diffLineKind(line: string): DiffLineKind {
  if (line.startsWith("@@")) return "hunk";
  if (line.startsWith("+++ ") || line.startsWith("--- ") || line.startsWith("\\"))
    return "meta";
  if (line.startsWith("+")) return "add";
  if (line.startsWith("-")) return "del";
  return "context";
}

/** The sandbox's state as the panel knows it; a state it does not know shows as its own word. */
const sandboxState = (place: SandboxPlace) =>
  SANDBOX_STATES.find((known) => known === place.state);

/** What to do while the sandbox is not running; nothing while it is. */
function sandboxHint(messages: CommaMessages, place: SandboxPlace): string | null {
  switch (sandboxState(place)) {
    case "starting":
      return messages.coding_hint_starting();
    case "stopped":
      return messages.coding_hint_stopped();
    case "lost":
      return messages.coding_hint_lost();
    case "failed":
      return place.reason
        ? messages.coding_hint_failed({ reason: place.reason })
        : messages.coding_hint_failed_unknown();
    case "ended":
      return messages.coding_hint_ended();
    default:
      return null;
  }
}

/** Counts the times the app's window came back to the front: a read keyed on it catches what changed meanwhile. */
export function useWindowReturns(): number {
  const [returns, setReturns] = useState(0);
  useEffect(() => {
    const count = () => setReturns((value) => value + 1);
    window.addEventListener("focus", count);
    return () => window.removeEventListener("focus", count);
  }, []);
  return returns;
}

/**
 * The newest of a component's reads wins: `take()` hands each read a ticket, and `current(ticket)` says whether no
 * read started since. An answer that arrives after a newer read's is dropped.
 */
export function useReadTickets() {
  const latest = useRef(0);
  return useMemo(
    () => ({
      take: () => ++latest.current,
      current: (ticket: number) => ticket === latest.current,
    }),
    []
  );
}

/** Counts the Worker's turns that ended here: a read keyed on it happens again once the agent is done. */
export function useTurnEnds(working: boolean | undefined): number {
  const [ends, setEnds] = useState(0);
  const was = useRef(working);
  useEffect(() => {
    if (was.current && !working) setEnds((count) => count + 1);
    was.current = working;
  }, [working]);
  return ends;
}

/** The Environment row of a coding Task's place: its sandbox, and where it stands at the row's end. */
export function CodingSandboxRow({ place }: { place: SandboxPlace }) {
  const messages = useCommaMessages();
  const state = sandboxState(place);
  const label =
    state === "starting"
      ? messages.coding_state_starting()
      : state === "stopped"
        ? messages.coding_state_stopped()
        : state === "lost"
          ? messages.coding_state_lost()
          : state === "failed"
            ? messages.coding_state_failed()
            : state === "ended"
              ? messages.coding_state_ended()
              : place.state;
  return (
    <div className="comma-task-panel-row" data-testid="task-panel-run-place">
      <span className="comma-task-panel-pill min-w-0">
        <CloudIcon className="size-5 shrink-0 text-quaternary" />
        <span className="truncate">{messages.coding_session_place()}</span>
      </span>
      {/* Running is the normal state and says nothing; any other trails the row. */}
      {state === "ready" ? null : (
        <output
          className="comma-task-coding-state"
          data-state={state ?? "unknown"}
          data-testid="task-panel-sandbox-state"
        >
          {state === "starting" ? (
            <LoaderIcon aria-hidden />
          ) : (
            <span aria-hidden className="comma-task-coding-dot" />
          )}
          {label}
        </output>
      )}
    </div>
  );
}

/** Copies `text`, and says `done` once it is on the clipboard. */
const copy = (text: string, done: string) =>
  void nativePlatformClipboard.writeText(text).then(
    () => toast.success(done),
    () => undefined
  );

type RowMenuItem = { id: string; label: string; separated?: boolean };

/**
 * An Environment row whose pill opens a menu of what to do with it, as Claude's folder and branch rows do. A `note`
 * ends the menu, below its items, on what the row's thing is now.
 */
function RowMenu({
  children,
  items,
  label,
  note,
  onAction,
}: {
  children: ReactNode;
  items: RowMenuItem[];
  label: string;
  note?: string | null | undefined;
  onAction: (key: string | number) => void;
}) {
  const noteId = useId();
  const menuItems = items.flatMap((item) => [
    ...(item.separated ? [<MenuSeparator key={`${item.id}-separator`} />] : []),
    <MenuItem id={item.id} key={item.id} textValue={item.label}>
      {item.label}
    </MenuItem>,
  ]);
  return (
    <MenuTrigger>
      <AriaButton
        aria-label={label}
        className="comma-task-panel-pill min-w-0"
        data-interactive="true"
      >
        {children}
      </AriaButton>
      <MenuPopover placement="bottom start">
        {note ? (
          // The note is no item: it sits on the menu's surface, after the items, where arrow keys do not reach it. The
          // menu is described by it, so a screen reader reads it with the item that has focus.
          <div className={menuClasses}>
            <Menu
              aria-describedby={noteId}
              aria-label={label}
              onAction={onAction}
              variant="embedded"
            >
              {menuItems}
            </Menu>
            <MenuSeparator />
            <p
              className="comma-task-coding-menu-note"
              data-testid="task-panel-coding-menu-note"
              id={noteId}
            >
              {note}
            </p>
          </div>
        ) : (
          <Menu aria-label={label} onAction={onAction}>
            {menuItems}
          </Menu>
        )}
      </MenuPopover>
    </MenuTrigger>
  );
}

/**
 * The Environment rows of a coding Task's sandbox, after its model: the repository (opens on GitHub), the session
 * branch (copies its name, with the branch it starts from), its terminal while the sandbox runs, and, while it does
 * not, a line on what to do.
 */
export function CodingSandboxRows({
  coding,
  onOpenTerminal,
  place,
}: {
  /** Where the panel's actions go; without it the rows only show. */
  coding?: CodingPanelTarget | undefined;
  /** Shows the terminal inside the app (a browser tab of the sidebar); without it, it opens in the browser outside. */
  onOpenTerminal?: ((url: string) => void) | undefined;
  place: SandboxPlace;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  // A Task without a repository has no repository or branch rows: its sandbox alone.
  const repo = place.repo ? `${place.repo.owner}/${place.repo.name}` : null;
  const branch = place.repo?.branch;
  const hint = sandboxHint(messages, place);
  // An ended session's line is about its branch: it ends the branch's menu instead, where the branch has a row.
  const branchNote = branch && sandboxState(place) === "ended" ? hint : null;
  const [opening, setOpening] = useState(false);
  const repoUrl = `https://github.com/${repo ?? ""}`;
  // The terminal's address is the sandbox's own on L4ES, where the member signs in with Comma: a tab can come back
  // to it. It is asked for at the press, since it answers only while the sandbox runs.
  const openTerminal = () => {
    if (!coding) return;
    setOpening(true);
    const opened = onOpenTerminal
      ? call("coding.terminal", coding).then(({ url }) => onOpenTerminal(url))
      : openNativePlatformExternalUrlFromUserAction(() =>
          call("coding.terminal", coding).then(({ url }) => url)
        );
    void opened
      .catch(() => toast.error(messages.coding_terminal_unavailable()))
      .finally(() => setOpening(false));
  };

  // Opening the terminal from a row's menu needs the sandbox running, as the Open terminal row does.
  const terminalItem: RowMenuItem[] =
    coding && place.state === "ready"
      ? [{ id: "terminal", label: messages.coding_open_in_terminal(), separated: true }]
      : [];

  return (
    <>
      {repo ? (
        <div className="comma-task-panel-row" data-testid="task-panel-coding-repo">
          <RowMenu
            items={[
              { id: "github", label: messages.coding_repo_open() },
              { id: "copy", label: messages.coding_copy_link() },
              ...terminalItem,
            ]}
            label={repo}
            onAction={(key) => {
              if (key === "github") void openNativePlatformExternalUrl(repoUrl);
              else if (key === "copy") copy(repoUrl, messages.coding_link_copied());
              else if (key === "terminal") openTerminal();
            }}
          >
            <span className="flex size-5 shrink-0 items-center justify-center">
              <GithubBrandIcon className="size-4 text-quaternary" />
            </span>
            <span className="truncate">{repo}</span>
          </RowMenu>
        </div>
      ) : null}
      {branch ? (
        <div className="comma-task-panel-row" data-testid="task-panel-coding-branch">
          <RowMenu
            items={[
              { id: "copy", label: messages.coding_copy_branch() },
              ...terminalItem,
            ]}
            label={branch}
            note={branchNote}
            onAction={(key) => {
              if (key === "copy") copy(branch, messages.coding_branch_copied());
              else if (key === "terminal") openTerminal();
            }}
          >
            <BranchIcon className="size-5 shrink-0 text-quaternary" />
            <span className="truncate">{branch}</span>
          </RowMenu>
          {place.repo?.baseRef ? (
            <span className="comma-task-coding-trailing">
              {messages.coding_branch_base({ branch: place.repo.baseRef })}
            </span>
          ) : null}
        </div>
      ) : null}
      {coding && place.state === "ready" ? (
        <div className="comma-task-panel-row" data-testid="task-panel-coding-terminal">
          <button
            className="comma-task-panel-pill min-w-0"
            data-interactive="true"
            disabled={opening}
            onClick={openTerminal}
            type="button"
          >
            <ConsoleSimpleIcon className="size-5 shrink-0 text-quaternary" />
            <span className="truncate">{messages.coding_terminal_open()}</span>
            {onOpenTerminal ? (
              <ChevronRightSmallIcon
                aria-hidden
                className="comma-task-coding-affordance"
              />
            ) : (
              <ArrowUpRightIcon aria-hidden className="comma-task-coding-affordance" />
            )}
          </button>
        </div>
      ) : null}
      {hint && !branchNote ? (
        <p
          className={
            place.state === "failed"
              ? "comma-task-panel-feedback"
              : "comma-task-panel-muted"
          }
          data-testid="task-panel-sandbox-hint"
        >
          {hint}
        </p>
      ) : null}
    </>
  );
}

/** A changed file's status, where it is not simply modified. */
export function codingFileStatus(
  messages: CommaMessages,
  status: string
): string | null {
  return status === "added"
    ? messages.coding_file_added()
    : status === "deleted" || status === "removed"
      ? messages.coding_file_deleted()
      : status === "renamed"
        ? messages.coding_file_renamed()
        : null;
}

/** A changed file's name first, then its directory, which gives way first when the room runs out. */
export function CodingFileName({ path }: { path: string }) {
  const slash = path.lastIndexOf("/");
  const name = slash === -1 ? path : path.slice(slash + 1);
  const dir = slash === -1 ? null : path.slice(0, slash);
  return (
    <span className="comma-task-coding-file" title={path}>
      <span className="comma-task-coding-file-name">{name}</span>
      {dir ? <span className="comma-task-coding-file-dir">{dir}</span> : null}
    </span>
  );
}

/** Lines added and removed, as +n −n. */
export function CodingLineCounts({
  additions,
  deletions,
}: {
  additions: number;
  deletions: number;
}) {
  const locale = useCommaLocale();
  return (
    <span className="comma-task-coding-counts">
      <span className="comma-task-coding-add">+{formatNumber(additions, locale)}</span>
      <span className="comma-task-coding-del">−{formatNumber(deletions, locale)}</span>
    </span>
  );
}

/** Whether a pull request can be made of the branch now: it has none, its last was closed, or one merged left work. */
export function proposable(pr: CodingPullRequest | null): boolean {
  return !pr || pr.state === "closed" || (pr.state === "merged" && pr.newCommits);
}

/**
 * The Task's pull request and what can be done to it, for every surface of the Task: `pr` as the core last learned it
 * (the `codingPullRequest` topic; undefined before any read answered), `busy` while a request about it is on its way
 * from any surface, and `open` (a pull request, or a draft), `update` (title, description, ready for review) and
 * `merge`. The core learns what each answers for every surface; failures say GitHub's words in a toast.
 */
export function usePullRequest(coding: CodingPanelTarget) {
  const messages = useCommaMessages();
  const call = useCall();
  const { taskId, workspaceId } = coding;
  const { value } = useTopic({
    topic: "codingPullRequest",
    workspace: workspaceId,
    task: taskId,
  });
  const pr = value?.known ? value.pr : undefined;
  const busy = value?.busy ?? false;
  const fail = useCallback(
    (failure: unknown) => {
      // Another surface's request was on its way (the core refuses a second): that one answers.
      if ((failure as { code?: unknown } | null)?.code === "busy") return;
      toast.error(messages.coding_pr_failed({ reason: (failure as Error).message }));
    },
    [messages]
  );
  // One request at a time per Task, from any surface: the core refuses another; one known busy is not sent.
  const act = <T,>(run: () => Promise<T>, done: (answer: T) => void) => {
    if (busy) return Promise.resolve(false);
    return run().then(
      (answer) => {
        done(answer);
        return true;
      },
      (failure: unknown) => {
        fail(failure);
        return false;
      }
    );
  };
  const open = (draft: boolean) =>
    void act(
      () => call("coding.pullRequest", { ...coding, draft }),
      (made) =>
        // The card shows it in place; the toast opens it on GitHub for one who wants to go there now.
        toast.success(messages.coding_pr_opened(), {
          actions: [
            {
              label: messages.coding_pr_open(),
              onPress: () => void openNativePlatformExternalUrl(made.url),
            },
          ],
        })
    );
  const update = (changes: { title?: string; body?: string; ready?: boolean }) =>
    act(
      () => call("coding.updatePullRequest", { ...coding, ...changes }),
      () =>
        toast.success(
          changes.ready ? messages.coding_pr_readied() : messages.coding_pr_updated()
        )
    );
  // Merges the pull request as it was confirmed: by its number, at the head shown then.
  const merge = (target: { number: number; headSha: string }) =>
    act(
      () => call("coding.mergePullRequest", { ...coding, ...target }),
      () => toast.success(messages.coding_pr_merged())
    );
  return { busy, merge, open, pr, update };
}

/**
 * Keeps the Task's open pull request's checks and mergeability current while `shown` and its window is in front: the
 * core reads its status every 30 s while it settles (`codingPullRequestWatch`), once per Task however many surfaces
 * watch it, and stops as soon as none does.
 */
export function usePullRequestWatch(coding: CodingPanelTarget, shown: boolean) {
  const attended = useWindowAttended();
  useTopic(
    shown && attended
      ? {
          topic: "codingPullRequestWatch",
          workspace: coding.workspaceId,
          task: coding.taskId,
        }
      : null,
    { lingerMs: 0 }
  );
}

/**
 * What a menu offers to do to the Task's open pull request: edit its title and description, mark a draft ready for
 * review, and merge one that is ready (asked first; not while it has conflicts). `items` go in the menu after its
 * own, `handle` takes their keys (false for a key not theirs), and `dialogs` render while one is open.
 */
export function usePullRequestActions(pull: ReturnType<typeof usePullRequest>) {
  const messages = useCommaMessages();
  const [editing, setEditing] = useState(false);
  // The pull request as the merge dialog opened on it: what the member confirms is what merges.
  const [merging, setMerging] = useState<CodingPullRequest | null>(null);
  const { busy, pr } = pull;
  const items: ReactNode[] =
    pr && (pr.state === "open" || pr.state === "draft")
      ? [
          <MenuSeparator key="pr-separator" />,
          <MenuItem
            id="pr-edit"
            isDisabled={busy}
            key="pr-edit"
            textValue={messages.coding_pr_edit()}
          >
            {messages.coding_pr_edit()}
          </MenuItem>,
          pr.state === "draft" ? (
            <MenuItem
              id="pr-ready"
              isDisabled={busy}
              key="pr-ready"
              textValue={messages.coding_pr_ready()}
            >
              {messages.coding_pr_ready()}
            </MenuItem>
          ) : (
            <MenuItem
              id="pr-merge"
              isDisabled={busy || conflicting(pr) || !mergeTarget(pr)}
              key="pr-merge"
              note={conflicting(pr) ? messages.coding_pr_conflicting() : undefined}
              textValue={messages.coding_pr_merge()}
            >
              {messages.coding_pr_merge()}
            </MenuItem>
          ),
        ]
      : [];
  const handle = (key: string | number) => {
    if (key === "pr-edit") setEditing(true);
    else if (key === "pr-ready") void pull.update({ ready: true });
    else if (key === "pr-merge" && pr && mergeTarget(pr)) setMerging(pr);
    else return false;
    return true;
  };
  const dialogs = pr ? (
    <>
      {editing ? (
        <PullRequestEditDialog
          busy={busy}
          onClose={() => setEditing(false)}
          onSave={(changes) =>
            void pull.update(changes).then((done) => {
              if (done) setEditing(false);
            })
          }
          pr={pr}
        />
      ) : null}
      {merging ? (
        <PullRequestMergeDialog
          busy={busy}
          onClose={() => setMerging(null)}
          onMerge={() => {
            const target = mergeTarget(merging);
            if (!target) return;
            void pull.merge(target).then((done) => {
              if (done) setMerging(null);
            });
          }}
          pr={merging}
        />
      ) : null}
    </>
  ) : null;
  return { dialogs, handle, items };
}

/**
 * What the Task's conversation knows of it now, for the surfaces outside its panel (the sidebar's Changes tab): its
 * sandbox's state and whether its Worker is in a turn. The conversation view publishes it as it changes.
 */
export type CodingTaskFacts = { placeState: string; working: boolean };
const taskFacts = new Map<string, CodingTaskFacts>();
const factListeners = new Set<() => void>();
const subscribeFacts = (listener: () => void) => {
  factListeners.add(listener);
  return () => {
    factListeners.delete(listener);
  };
};

/** Publishes what the Task's conversation knows of it now; the same facts again change nothing. */
export function publishCodingTaskFacts(taskId: string, facts: CodingTaskFacts) {
  const known = taskFacts.get(taskId);
  if (known?.placeState === facts.placeState && known.working === facts.working) return;
  taskFacts.set(taskId, facts);
  for (const listener of factListeners) listener();
}

/** What the Task's conversation last said of it, or null before it said anything. */
export function useCodingTaskFacts(taskId: string): CodingTaskFacts | null {
  return useSyncExternalStore(
    subscribeFacts,
    () => taskFacts.get(taskId) ?? null,
    () => null
  );
}

/** Forgets the published facts: for tests, which share one module. */
export function forgetCodingTaskFacts() {
  taskFacts.clear();
  for (const listener of factListeners) listener();
}

/** What a merge names, once the pull request has been read: its number and the commit its head is at. */
function mergeTarget(pr: CodingPullRequest) {
  return pr.number !== null && pr.headSha !== null
    ? { number: pr.number, headSha: pr.headSha }
    : null;
}

/** Whether an open pull request cannot merge as it stands. */
function conflicting(pr: CodingPullRequest) {
  return (
    pr.mergeable === "conflicting" && (pr.state === "open" || pr.state === "draft")
  );
}

/** Where a pull request stands, in a word: conflicts count before its state. */
function pullRequestStanding(messages: CommaMessages, pr: CodingPullRequest) {
  if (conflicting(pr)) return messages.coding_pr_conflicting();
  if (pr.state === "merged") return messages.coding_pr_state_merged();
  if (pr.state === "closed") return messages.coding_pr_state_closed();
  if (pr.state === "draft") return messages.coding_pr_state_draft();
  return messages.coding_pr_state_open();
}

/** A pull request by its number, or the plain word before the number is known. */
function pullRequestName(messages: CommaMessages, pr: CodingPullRequest) {
  return pr.number === null
    ? messages.coding_pr()
    : messages.coding_pr_link({ number: String(pr.number) });
}

/** A pull request's checks in words, or null where none are known. */
function checksText(messages: CommaMessages, pr: CodingPullRequest) {
  if (!pr.checks) return null;
  const { failed, passed, total } = pr.checks;
  return failed > 0
    ? messages.coding_pr_checks_failed({ failed: String(failed), total: String(total) })
    : messages.coding_pr_checks({ passed: String(passed), total: String(total) });
}

/** How the checks stand, for the dot: all passed, some failed, or still running; null where none are known. */
function checksStanding(pr: CodingPullRequest) {
  if (!pr.checks || pr.checks.total === 0) return null;
  if (pr.checks.failed > 0) return "failed";
  return pr.checks.passed >= pr.checks.total ? "passed" : "pending";
}

/**
 * The glyph of a pull request, in GitHub's colours: green open, gray draft, purple merged, red closed; amber where
 * an open one has conflicts.
 */
export function PullRequestGlyph({ pr }: { pr: CodingPullRequest }) {
  const clash = conflicting(pr);
  return (
    <span
      aria-hidden
      className="comma-task-coding-pr-glyph"
      data-conflicting={clash ? "true" : undefined}
      data-state={pr.state}
    >
      {clash ? (
        <MergeConflictIcon />
      ) : pr.state === "merged" ? (
        <MergedIcon />
      ) : pr.state === "closed" ? (
        <PullRequestClosedIcon />
      ) : (
        <PullRequestIcon />
      )}
    </span>
  );
}

/**
 * A pull request as a link to it on GitHub, for a bar: its glyph says where it stands, its number names it, and its
 * checks passed follow where known.
 */
export function PullRequestLink({ pr }: { pr: CodingPullRequest }) {
  const messages = useCommaMessages();
  const standing = pullRequestStanding(messages, pr);
  const name = pullRequestName(messages, pr);
  const checks = checksText(messages, pr);
  return (
    <button
      aria-label={[name, standing, checks].filter(Boolean).join(" · ")}
      className="comma-task-coding-pr-link"
      data-conflicting={conflicting(pr) ? "true" : undefined}
      data-state={pr.state}
      data-testid="task-panel-changes-pr"
      onClick={() => void openNativePlatformExternalUrl(pr.url)}
      title={pr.title ? `${pr.title} · ${standing}` : standing}
      type="button"
    >
      <PullRequestGlyph pr={pr} />
      {name}
      {pr.checks ? (
        <span className="comma-task-coding-pr-checks">
          {pr.checks.passed}/{pr.checks.total}
        </span>
      ) : null}
      <ArrowUpRightIcon aria-hidden />
    </button>
  );
}

/**
 * A pull request's title line, for its card: its glyph and title (its number before the title is known), which opens
 * it on GitHub; where it stands and how its checks go show on hover and focus.
 */
function PullRequestTitle({ pr }: { pr: CodingPullRequest }) {
  const messages = useCommaMessages();
  const standing = pullRequestStanding(messages, pr);
  const name = pullRequestName(messages, pr);
  const checks = checksText(messages, pr);
  return (
    <Tooltip
      content={standing}
      placement="bottom"
      {...(checks ? { supportingText: checks } : {})}
    >
      <AriaButton
        aria-label={[pr.title, name, standing, checks].filter(Boolean).join(" · ")}
        className="comma-task-panel-pill comma-task-coding-pr-title"
        data-conflicting={conflicting(pr) ? "true" : undefined}
        data-interactive="true"
        data-state={pr.state}
        data-testid="task-panel-changes-pr"
        onPress={() => void openNativePlatformExternalUrl(pr.url)}
      >
        <PullRequestGlyph pr={pr} />
        <span className="comma-task-coding-pr-name">{pr.title ?? name}</span>
      </AriaButton>
    </Tooltip>
  );
}

/**
 * The chip that ends the card's second line while a pull request is open, as Claude's does: how its checks stand —
 * how many failed, in red, where any did; else a dot (gray still running, green all passed) and how many passed of
 * all, which shines while they run. It opens them on GitHub; hovering it shows them by outcome.
 */
function PullRequestChecks({ pr }: { pr: CodingPullRequest }) {
  const messages = useCommaMessages();
  const standing = checksStanding(pr);
  const checks = pr.checks;
  if (!checks || standing === null || !(pr.state === "open" || pr.state === "draft")) {
    return null;
  }
  const running = checks.total - checks.passed - checks.failed;
  const text =
    standing === "failed"
      ? messages.coding_pr_checks_failed({
          failed: String(checks.failed),
          total: String(checks.total),
        })
      : standing === "pending"
        ? messages.coding_pr_checks_running({
            running: String(running),
            total: String(checks.total),
          })
        : messages.coding_pr_checks({
            passed: String(checks.passed),
            total: String(checks.total),
          });
  const url = `${pr.url}/checks`;
  const rows = [
    {
      outcome: "failed",
      label: messages.coding_pr_checks_row_failed(),
      count: checks.failed,
    },
    {
      outcome: "pending",
      label: messages.coding_pr_checks_row_running(),
      count: running,
    },
    {
      outcome: "passed",
      label: messages.coding_pr_checks_row_passed(),
      count: checks.passed - checks.skipped,
    },
    {
      outcome: "skipped",
      label: messages.coding_pr_checks_row_skipped(),
      count: checks.skipped,
    },
  ].filter((row) => row.count > 0);
  return (
    <HoverPanel
      className="comma-task-coding-checks-panel"
      content={
        <div data-testid="task-panel-changes-checks-panel">
          <div className="comma-task-coding-checks-head">
            <span className="comma-task-coding-checks-title">
              {messages.coding_pr_checks_title()}
            </span>
            <button
              {...{ [HOVER_PANEL_ITEM]: "" }}
              aria-label={messages.coding_pr_checks_open()}
              className="comma-task-coding-checks-open"
              data-no-press-feedback
              onClick={() => void openNativePlatformExternalUrl(url)}
              type="button"
            >
              <ArrowUpRightIcon aria-hidden />
            </button>
          </div>
          <ul className="comma-task-coding-checks-rows">
            {rows.map((row) => (
              <li className="comma-task-coding-checks-row" key={row.outcome}>
                <span
                  aria-hidden
                  className="comma-task-coding-checks-mark comma-icon-slot"
                  data-outcome={row.outcome}
                >
                  {row.outcome === "failed" ? (
                    <CircleXIcon />
                  ) : row.outcome === "passed" ? (
                    <CircleCheckIcon />
                  ) : null}
                </span>
                <span className="comma-task-coding-checks-label">{row.label}</span>
                <span className="comma-task-coding-checks-count">{row.count}</span>
              </li>
            ))}
          </ul>
        </div>
      }
      label={messages.coding_pr_checks_title()}
      placement="bottom end"
    >
      <button
        aria-label={text}
        className="comma-task-coding-pr-checks-chip"
        data-checks={standing}
        data-testid="task-panel-changes-checks"
        onClick={() => void openNativePlatformExternalUrl(url)}
        type="button"
      >
        {standing === "failed" ? (
          messages.coding_pr_checks_failing({ failed: String(checks.failed) })
        ) : (
          <>
            <span aria-hidden className="comma-task-coding-pr-checks-dot" />
            {/* While checks run, the count shines as the Routines "Generating…" line does (comma-shiny-text). */}
            <span
              className={
                standing === "pending"
                  ? "comma-task-coding-pr-checks-count comma-shiny-text"
                  : "comma-task-coding-pr-checks-count"
              }
            >
              {checks.passed}/{checks.total}
            </span>
          </>
        )}
      </button>
    </HoverPanel>
  );
}

/**
 * Why the pull request cannot be made now, or null: the Worker's turn (it may push more), or a request on its way.
 * The sandbox need not run: once it is gone, Comma opens the branch it pushed on GitHub.
 */
export function pullRequestBlock(
  messages: CommaMessages,
  state: { busy: boolean; working: boolean }
): string | null {
  if (state.working) return messages.coding_pr_wait_turn();
  if (state.busy) return messages.coding_pr_opening();
  return null;
}

/**
 * The chip that makes the pull request. Where it cannot now, `blocked` says why: the chip stays, dimmed, and says
 * so on hover and focus rather than going away.
 */
export function CreatePullRequestButton({
  blocked,
  children,
  className,
  onPress,
  pressFeedback = true,
  testId,
}: {
  blocked: string | null;
  children: ReactNode;
  className?: string | undefined;
  onPress: () => void;
  /** Off where a chip around it presses as one (the prompt's split chip). */
  pressFeedback?: boolean | undefined;
  testId?: string | undefined;
}) {
  return (
    <Tooltip content={blocked} isDisabled={blocked === null} placement="top">
      <AriaButton
        {...(blocked === null ? {} : { "aria-disabled": true })}
        className={
          className
            ? `comma-task-coding-action ${className}`
            : "comma-task-coding-action"
        }
        data-no-press-feedback={pressFeedback ? undefined : ""}
        data-testid={testId}
        onPress={() => {
          if (blocked === null) onPress();
        }}
      >
        {children}
      </AriaButton>
    </Tooltip>
  );
}

/**
 * What each Task's sandbox last answered, in this run of the app, so a surface that opens shows it at once and reads
 * again rather than starting empty: the whole branch's changes (the Changes line, the prompt above the composer and the
 * Changes tab) and the record (Execution and Activity). The record lives on the sandbox, so once it stops the panel
 * keeps showing the record it last read rather than nothing. 16 Tasks each, the oldest forgotten first.
 */
const rememberedChanges = new Map<string, CodingChanges>();
const rememberedRecords = new Map<string, CodingHistory>();
const REMEMBERED_TASKS = 16;
const remember = <T,>(memory: Map<string, T>, taskId: string, value: T) => {
  memory.delete(taskId);
  memory.set(taskId, value);
  if (memory.size > REMEMBERED_TASKS) {
    const oldest = memory.keys().next().value;
    if (oldest !== undefined) memory.delete(oldest);
  }
};

/** The whole branch's changes a surface of the Task last read, or null for a Task none read yet. */
export function rememberedCodingChanges(taskId: string): CodingChanges | null {
  return rememberedChanges.get(taskId) ?? null;
}

export function rememberCodingChanges(taskId: string, changes: CodingChanges) {
  remember(rememberedChanges, taskId, changes);
}

/** Forgets the remembered changes and records: for tests, which share one module. */
export function forgetCodingRecords() {
  rememberedChanges.clear();
  rememberedRecords.clear();
}

export function CodingChangesSection({
  coding,
  facts,
  onOpenChanges,
  place,
  working,
}: {
  coding: CodingPanelTarget;
  facts?: CodingFacts | undefined;
  /** Shows the changes file by file (the sidebar's Changes tab); without it the line only shows. */
  onOpenChanges?: (() => void) | undefined;
  place: SandboxPlace;
  working?: boolean | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const [changes, setChanges] = useState(() => rememberedCodingChanges(coding.taskId));
  const [failed, setFailed] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  // A right-click's menu lands where the pointer is, anchored to the row; null while it is closed.
  const [contextMenu, setContextMenu] = useState<MenuPointerOffsets | null>(null);
  const row = useRef<HTMLDivElement>(null);
  const turnEnds = useTurnEnds(working);
  const windowReturns = useWindowReturns();
  const tickets = useReadTickets();

  const read = useCallback(() => {
    const ticket = tickets.take();
    // The core learns the branch's pull request from it for every surface of the Task.
    call("coding.changes", coding).then(
      (next) => {
        if (!tickets.current(ticket)) return;
        rememberCodingChanges(coding.taskId, next);
        setChanges(next);
        setFailed(false);
      },
      () => {
        if (tickets.current(ticket)) setFailed(true);
      }
    );
  }, [call, coding, tickets]);
  const pullRequest = usePullRequest(coding);
  const actions = usePullRequestActions(pullRequest);
  // Read when first shown, after a turn, when the sandbox comes up or goes, and when the window comes back to the
  // front (a pull request merged or checked on GitHub meanwhile).
  useEffect(read, [read, turnEnds, place.state, windowReturns]);
  // While its checks run, the pull request's status is read again on its own (bounded in the core).
  usePullRequestWatch(coding, true);

  // Until the changes are read, what the server kept of them stands in: their totals, and the pull request while the
  // core knows none. What the line offers to do waits for the read.
  const changeTotals = changes
    ? {
        files: changes.files.length,
        additions: changes.files.reduce((sum, file) => sum + file.additions, 0),
        deletions: changes.files.reduce((sum, file) => sum + file.deletions, 0),
      }
    : (facts?.changes ?? null);
  const { additions = 0, deletions = 0 } = changeTotals ?? {};
  const changed = (changeTotals?.files ?? 0) > 0;
  const pr =
    pullRequest.pr !== undefined ? pullRequest.pr : (facts?.pullRequest ?? null);
  // A pull request stands until merged; a closed one, or a merged one the branch moved past, leaves work to propose.
  const canPropose = changes !== null && changed && proposable(pullRequest.pr ?? null);
  const blocked = pullRequestBlock(messages, {
    busy: pullRequest.busy,
    working: working ?? false,
  });
  const totals = messages.coding_changes_totals({
    additions: formatNumber(additions, locale),
    deletions: formatNumber(deletions, locale),
  });
  // Where the changes are on GitHub: the pull request made here, else the branch.
  const onGithub =
    pr?.url ??
    `https://github.com/${place.repo?.owner}/${place.repo?.name}${
      place.repo?.branch ? `/tree/${place.repo.branch}` : ""
    }`;
  const onMenuAction = (key: string | number) => {
    if (actions.handle(key)) return;
    if (key === "view") onOpenChanges?.();
    else if (key === "github") void openNativePlatformExternalUrl(onGithub);
    else if (key === "copy")
      void nativePlatformClipboard.writeText(onGithub).then(
        () => toast.success(messages.coding_link_copied()),
        () => undefined
      );
    else if (key === "draft") pullRequest.open(true);
  };
  const menuItems = [
    ...(onOpenChanges ? [{ id: "view", label: messages.coding_view_changes() }] : []),
    { id: "github", label: messages.coding_repo_open() },
    { id: "copy", label: messages.coding_copy_link() },
  ];
  const openMenu = (event: MouseEvent<HTMLDivElement>) => {
    if (!row.current) return;
    event.preventDefault();
    setContextMenu(getMenuPointerOffsets(row.current, event.clientX, event.clientY));
  };

  // The lines changed over every file, which open the Changes tab; their glyph only where no pull request's leads.
  const counts = onOpenChanges ? (
    <Tooltip content={messages.coding_view_changes()} placement="bottom">
      <AriaButton
        aria-label={`${totals} · ${messages.coding_view_changes()}`}
        className="comma-task-panel-pill min-w-0"
        data-interactive="true"
        data-testid="task-panel-changes-open"
        onPress={() => onOpenChanges()}
      >
        {pr ? null : (
          <DifferenceModifiedIcon className="size-5 shrink-0 text-quaternary" />
        )}
        <CodingLineCounts additions={additions} deletions={deletions} />
      </AriaButton>
    </Tooltip>
  ) : (
    <span aria-label={totals} className="comma-task-panel-pill min-w-0">
      {pr ? null : (
        <DifferenceModifiedIcon className="size-5 shrink-0 text-quaternary" />
      )}
      <CodingLineCounts additions={additions} deletions={deletions} />
    </span>
  );
  const propose = canPropose ? (
    <CreatePullRequestButton
      blocked={blocked}
      onPress={() => pullRequest.open(false)}
      testId="task-panel-changes-create"
    >
      {messages.coding_create_pr()}
    </CreatePullRequestButton>
  ) : null;
  const items = [
    ...menuItems.map((item) => (
      <MenuItem id={item.id} key={item.id} textValue={item.label}>
        {item.label}
      </MenuItem>
    )),
    ...(canPropose
      ? [
          <MenuSeparator key="draft-separator" />,
          <MenuItem
            id="draft"
            isDisabled={blocked !== null}
            key="draft"
            textValue={messages.coding_create_draft_pr()}
          >
            {messages.coding_create_draft_pr()}
          </MenuItem>,
        ]
      : []),
    ...actions.items,
  ];
  const menu = (
    <MenuTrigger isOpen={menuOpen} onOpenChange={setMenuOpen}>
      <AriaButton
        aria-label={messages.coding_changes_menu()}
        className="comma-task-coding-more"
        data-testid="task-panel-changes-menu"
      >
        <MoreHorizontalIcon />
      </AriaButton>
      <MenuPopover placement="bottom end">
        <Menu aria-label={messages.coding_changes_menu()} onAction={onMenuAction}>
          {items}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
  // The same menu from a right-click: at the pointer, and at once, as a context menu is.
  const contextPopover = contextMenu ? (
    <MenuPopover
      animation="none"
      crossOffset={contextMenu.crossOffset}
      dismissControlledNonModalOnInteractOutside
      isNonModal
      isOpen
      offset={contextMenu.offset}
      onOpenChange={(open) => {
        if (!open) setContextMenu(null);
      }}
      placement="right top"
      triggerRef={row}
    >
      <Menu
        aria-label={messages.coding_changes_menu()}
        // A context menu takes the keyboard as it opens, so Escape and the arrows work from the first key.
        // oxlint-disable-next-line jsx-a11y/no-autofocus
        autoFocus="first"
        onAction={(key) => {
          setContextMenu(null);
          onMenuAction(key);
        }}
        onClose={() => setContextMenu(null)}
      >
        {items}
      </Menu>
    </MenuPopover>
  ) : null;

  return (
    <section className="comma-task-panel-section" data-testid="task-panel-changes">
      <h2 className="comma-task-panel-heading">{messages.coding_changes()}</h2>
      {failed ? (
        <p className="comma-task-panel-feedback" role="alert">
          {messages.coding_changes_failed()}
        </p>
      ) : null}
      {changeTotals && !changed && !pr ? (
        <p className="comma-task-panel-empty">{messages.coding_changes_none()}</p>
      ) : null}
      {pr ? (
        // With a pull request, the line is its card: the title, then how its checks stand, its number and the lines.
        <div
          className="comma-task-coding-pr"
          data-testid="task-panel-changes-summary"
          onContextMenu={openMenu}
          ref={row}
        >
          <div className="comma-task-coding-pr-head">
            <PullRequestTitle pr={pr} />
            {menu}
          </div>
          <div className="comma-task-coding-pr-meta">
            {pr.number === null ? null : (
              <span className="comma-task-coding-pr-number">#{pr.number}</span>
            )}
            {/* A branch merged into its base with a merge commit has nothing left to compare: no lines. */}
            {changed ? counts : null}
            <span className="comma-task-coding-summary-end">
              {propose}
              <PullRequestChecks pr={pr} />
            </span>
          </div>
        </div>
      ) : changed ? (
        <div
          className="comma-task-panel-row comma-task-coding-summary"
          data-testid="task-panel-changes-summary"
          onContextMenu={openMenu}
          ref={row}
        >
          {counts}
          {/* The chip ends the line at the column's edge, with the rest's trailing text; the dots wait before it. */}
          <span className="comma-task-coding-summary-end">
            {menu}
            {propose}
          </span>
        </div>
      ) : null}
      {contextPopover}
      {actions.dialogs}
    </section>
  );
}

/** A request of the session with the tool steps its agent took after it; the agent's words are in the Task chat. */
type HistoryRequest = {
  key: string;
  text: string | null;
  at: string | null;
  steps: CodingStep[];
};

function requestsOf(items: CodingHistoryItem[]): HistoryRequest[] {
  const requests: HistoryRequest[] = [];
  let current: HistoryRequest | undefined;
  for (const item of items) {
    if (item.kind === "received") {
      current = { key: item.id, text: item.text, at: item.at, steps: [] };
      requests.push(current);
    } else if (item.kind === "group") {
      if (!current) {
        current = { key: item.id, text: null, at: null, steps: [] };
        requests.push(current);
      }
      current.steps.push(...item.steps);
    }
  }
  return requests;
}

/**
 * The session's execution record, from its sandbox (`coding.history`), as two sections. Execution: what its model
 * calls used; between them, `children` (the Changes line). Activity: each request with the tool steps taken after it, in
 * the panel's timeline, where a step opens
 * what it did and what came out, with earlier pages on request. Read when first shown, after a turn, and when the
 * sandbox's state changes; while the sandbox is not running the record cannot be read, and both sections say so.
 */
export function CodingRecordSections({
  children,
  coding,
  facts,
  place,
  working,
}: {
  /** What sits between the two sections: the Changes line. */
  children?: ReactNode;
  coding: CodingPanelTarget;
  facts?: CodingFacts | undefined;
  place: SandboxPlace;
  working?: boolean | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const [history, setHistory] = useState(
    () => rememberedRecords.get(coding.taskId) ?? null
  );
  const [failed, setFailed] = useState(false);
  const [reading, setReading] = useState(false);
  const [openSteps, setOpenSteps] = useState<ReadonlySet<string>>(() => new Set());
  const [allSteps, setAllSteps] = useState<ReadonlySet<string>>(() => new Set());
  const turnEnds = useTurnEnds(working);
  const tickets = useReadTickets();

  const read = useCallback(() => {
    const ticket = tickets.take();
    call("coding.history", coding).then(
      (next) => {
        if (!tickets.current(ticket)) return;
        // A sandbox that is not running answers nothing: what it answered last stands in.
        if (next.available) remember(rememberedRecords, coding.taskId, next);
        setHistory(
          next.available ? next : (rememberedRecords.get(coding.taskId) ?? next)
        );
        setFailed(false);
      },
      () => {
        if (tickets.current(ticket)) setFailed(true);
      }
    );
  }, [call, coding, tickets]);
  useEffect(read, [read, turnEnds, place.state]);

  const earlier = () => {
    // Earlier steps are read from the sandbox: none while it is not running.
    if (!history || history.start === 0 || reading || place.state !== "ready") return;
    setReading(true);
    call("coding.history", { ...coding, before: history.start })
      .then(
        (page) =>
          setHistory((now) =>
            now
              ? { ...now, start: page.start, items: [...page.items, ...now.items] }
              : page
          ),
        () => setFailed(true)
      )
      .finally(() => setReading(false));
  };
  const toggleStep = (id: string) =>
    setOpenSteps((current) => {
      const next = new Set(current);
      if (!next.delete(id)) next.add(id);
      return next;
    });

  const requests = history ? requestsOf(history.items) : [];
  // Until the record is read, and while the sandbox cannot be read (it answers no usage then), the token use the
  // server kept stands in. A record read says null only when the Session made no model calls.
  const usage = history?.available
    ? history.usage
    : (history?.usage ?? facts?.usage ?? null);
  return (
    <>
      <section className="comma-task-panel-section" data-testid="task-panel-execution">
        <h2 className="comma-task-panel-heading">{messages.coding_history()}</h2>
        {usage ? <UsageBlock usage={usage} /> : null}
        {failed ? (
          <p className="comma-task-panel-feedback" role="alert">
            {messages.coding_history_failed()}
          </p>
        ) : null}
        {history && !usage ? (
          <p className="comma-task-panel-empty">
            {history.available
              ? messages.coding_usage_none()
              : messages.coding_record_unavailable()}
          </p>
        ) : null}
      </section>
      {children}
      <section className="comma-task-panel-section" data-testid="task-panel-activity">
        <h2 className="comma-task-panel-heading">{messages.task_panel_activity()}</h2>
        {history && requests.length === 0 ? (
          <p className="comma-task-panel-empty">
            {history.available
              ? messages.coding_activity_none()
              : messages.coding_record_unavailable()}
          </p>
        ) : null}
        {requests.length > 0 ? (
          <ol className="comma-task-activity">
            {history && history.start > 0 && place.state === "ready" ? (
              <li className="comma-task-activity-group" data-fold="true">
                <button
                  className="comma-task-activity-row"
                  data-no-press-feedback
                  data-testid="task-panel-history-earlier"
                  disabled={reading}
                  onClick={earlier}
                  type="button"
                >
                  <span
                    aria-hidden
                    className="comma-task-activity-icon comma-icon-slot"
                  >
                    {reading ? <LoaderIcon /> : <MoreHorizontalIcon />}
                  </span>
                  <span className="comma-task-activity-text">
                    {messages.coding_history_earlier()}
                  </span>
                </button>
              </li>
            ) : null}
            {requests.map((request) => {
              const fold =
                !allSteps.has(request.key) && request.steps.length > STEP_FOLD.above
                  ? {
                      head: request.steps.slice(0, STEP_FOLD.head),
                      hidden: request.steps.length - STEP_FOLD.head - STEP_FOLD.tail,
                      tail: request.steps.slice(request.steps.length - STEP_FOLD.tail),
                    }
                  : undefined;
              const step = (entry: CodingStep) => (
                <StepRow
                  key={entry.id}
                  onToggle={() => toggleStep(entry.id)}
                  open={openSteps.has(entry.id)}
                  step={entry}
                />
              );
              return (
                <li
                  className="comma-task-activity-group"
                  data-testid="task-panel-history-request"
                  key={request.key}
                >
                  {request.text !== null ? (
                    <RequestRow at={request.at} text={request.text} />
                  ) : null}
                  <ol className="comma-task-activity-entries">
                    {fold
                      ? [
                          ...fold.head.map(step),
                          <li
                            className="comma-task-activity-item"
                            data-fold="true"
                            key="fold"
                          >
                            <button
                              className="comma-task-activity-row"
                              data-no-press-feedback
                              data-testid="task-panel-history-more"
                              onClick={() =>
                                setAllSteps((current) =>
                                  new Set(current).add(request.key)
                                )
                              }
                              type="button"
                            >
                              <span
                                aria-hidden
                                className="comma-task-activity-icon comma-icon-slot"
                              >
                                <MoreHorizontalIcon />
                              </span>
                              <span className="comma-task-activity-text">
                                {messages.coding_history_more({
                                  count: formatNumber(fold.hidden, locale),
                                })}
                              </span>
                            </button>
                          </li>,
                          ...fold.tail.map(step),
                        ]
                      : request.steps.map(step)}
                  </ol>
                </li>
              );
            })}
          </ol>
        ) : null}
      </section>
    </>
  );
}

/** What the session's model calls used, as a bar of the cached, fresh and written tokens. */
function UsageBlock({ usage }: { usage: CodingUsage }) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const compact = new Intl.NumberFormat(locale, { notation: "compact" });
  const percent = new Intl.NumberFormat(locale, {
    style: "percent",
    maximumFractionDigits: 0,
  });
  const total = usage.inputTokens + usage.outputTokens;
  const parts = [
    {
      key: "cached",
      label: messages.coding_usage_cached(),
      tokens: usage.cachedTokens,
    },
    {
      key: "input",
      label: messages.coding_usage_input(),
      tokens: Math.max(usage.inputTokens - usage.cachedTokens, 0),
    },
    {
      key: "output",
      label: messages.coding_usage_output(),
      tokens: usage.outputTokens,
    },
  ];
  return (
    <div className="comma-task-coding-usage" data-testid="task-panel-usage">
      <p className="comma-task-coding-usage-line">
        <span data-testid="task-panel-usage-line">
          {messages.coding_history_usage({
            tokens: compact.format(total),
            calls: compact.format(usage.modelCalls),
          })}
        </span>
      </p>
      {total > 0 ? (
        <>
          <div aria-hidden className="comma-task-coding-usage-bar">
            {parts
              .filter((part) => part.tokens > 0)
              .map((part) => (
                <span
                  data-part={part.key}
                  key={part.key}
                  style={{ flexGrow: part.tokens }}
                />
              ))}
          </div>
          <ul className="comma-task-coding-usage-legend">
            {parts.map((part) => (
              <li data-part={part.key} key={part.key}>
                <span aria-hidden className="comma-task-coding-swatch" />
                <span>{part.label}</span>
                <span className="comma-task-coding-usage-n">
                  {compact.format(part.tokens)}
                </span>
                <span className="comma-task-coding-usage-pct">
                  {percent.format(part.tokens / total)}
                </span>
              </li>
            ))}
          </ul>
        </>
      ) : null}
    </div>
  );
}

/** A request row: what was asked, and when. */
function RequestRow({ at, text }: { at: string | null; text: string }) {
  const time = useTimeLabel();
  const ms = at ? Date.parse(at) : Number.NaN;
  return (
    <div className="comma-task-activity-row">
      <span aria-hidden className="comma-task-activity-icon comma-icon-slot">
        <ChatBubbleIcon />
      </span>
      <span className="comma-task-activity-text" data-kind="request">
        <span className="comma-task-activity-title">{text}</span>
        {Number.isFinite(ms) ? (
          <time
            className="comma-task-activity-time"
            dateTime={new Date(ms).toISOString()}
          >
            {time(ms)}
          </time>
        ) : null}
      </span>
    </div>
  );
}

/** One step: its tool and what it worked on, how it ended; opened, what it did and what came out. */
function StepRow({
  onToggle,
  open,
  step,
}: {
  onToggle: () => void;
  open: boolean;
  step: CodingStep;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const thinking = step.kind === "thinking";
  const failed = !thinking && step.failed;
  const pending = !thinking && step.pending;
  const title = thinking ? messages.coding_history_thinking() : step.tool;
  const hint = thinking ? firstLine(step.text) : step.hint;
  const meta: ReactNode = thinking
    ? null
    : pending
      ? messages.coding_history_running()
      : failed
        ? messages.coding_history_step_failed()
        : step.durationMs !== null
          ? new Intl.NumberFormat(locale, {
              style: "unit",
              unit: "second",
              unitDisplay: "narrow",
              maximumFractionDigits: 1,
            }).format(step.durationMs / 1000)
          : null;
  const id = `coding-step-${step.id}`;
  return (
    <li className="comma-task-activity-item" data-testid="task-panel-history-step">
      <button
        aria-controls={open ? id : undefined}
        aria-expanded={open}
        className="comma-task-activity-row comma-task-coding-step"
        data-no-press-feedback
        onClick={onToggle}
        type="button"
      >
        {/* A step that went through keeps the glyph quiet: only a failure takes a colour. */}
        <span
          aria-hidden
          className="comma-task-activity-icon comma-icon-slot"
          data-failed={failed ? "true" : undefined}
        >
          {thinking ? (
            <CircleDashedIcon />
          ) : pending ? (
            <LoaderIcon />
          ) : failed ? (
            <CircleXIcon />
          ) : (
            <CircleCheckFilledIcon />
          )}
        </span>
        <span className="comma-task-activity-text comma-task-coding-step-text">
          <span className="comma-task-coding-step-tool">{title}</span>
          {hint ? <span className="comma-task-coding-step-hint">{hint}</span> : null}
          {meta ? (
            <span
              className="comma-task-activity-time"
              data-tone={failed ? "error" : undefined}
            >
              {meta}
            </span>
          ) : null}
        </span>
      </button>
      {open ? (
        <div className="comma-task-coding-detail" id={id}>
          {thinking ? (
            <p className="comma-task-coding-thinking">{step.text}</p>
          ) : (
            <>
              <StepBody step={step} />
              {step.result !== null ? (
                <>
                  <span className="comma-task-coding-detail-label">
                    {messages.coding_history_output()}
                  </span>
                  <Code lang="text" text={step.result} />
                </>
              ) : null}
            </>
          )}
        </div>
      ) : null}
    </li>
  );
}

function StepBody({ step }: { step: Extract<CodingStep, { kind: "tool" }> }) {
  const body = step.body;
  switch (body.kind) {
    case "command":
      return <Code lang="bash" text={body.command} />;
    case "edit":
      return (
        <>
          <span className="comma-task-coding-detail-label font-mono">{body.path}</span>
          <DiffBlock diff={body.diff} />
        </>
      );
    case "patch":
      return <DiffBlock diff={body.diff} />;
    case "read":
      return (
        <span className="comma-task-coding-detail-label font-mono">
          {body.path}
          {body.lines ? ` (${body.lines})` : ""}
        </span>
      );
    default:
      return <Code lang="json" text={body.text} />;
  }
}

function firstLine(text: string): string {
  const line = text.split("\n").find((candidate) => candidate.trim() !== "");
  return line?.trim() ?? "";
}
