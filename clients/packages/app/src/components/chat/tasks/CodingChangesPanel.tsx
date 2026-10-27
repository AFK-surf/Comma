/* oxlint-disable jsx-a11y/prefer-tag-over-role -- the pane handles are window splitters: an hr can be neither focused nor dragged. */
import type { CodingChanges, CodingCommit } from "@comma/core/contract";
import { useCall } from "@comma/core-client";
import { formatNumber, formatRelativeTime } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import {
  ArrowRightIcon,
  ArrowUpRightIcon,
  BranchIcon,
  CheckIcon,
  ChevronDownSmallIcon,
  ListBulletsIcon,
  MoreHorizontalIcon,
} from "@comma/ui/components/icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
} from "@comma/ui/components/menu";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { toast } from "@comma/ui/components/toast";
import { uiClock } from "@comma/ui/clock";
import { Button as AriaButton } from "react-aria-components";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
  type RefObject,
} from "react";
import type { ChatSidebarChangesPage } from "../../chat-sidebar/ChatSidebarContext";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
} from "../../../nativePlatformActions";
import {
  CodingFileName,
  CodingLineCounts,
  CreatePullRequestButton,
  DiffBlock,
  PullRequestLink,
  codingFileStatus,
  proposable,
  pullRequestBlock,
  rememberCodingChanges,
  rememberedCodingChanges,
  useCodingTaskFacts,
  usePullRequest,
  usePullRequestActions,
  usePullRequestWatch,
  useReadTickets,
  useTurnEnds,
  useWindowReturns,
} from "./CodingSession";

/** A menu item of the tab's menu: its label, a check where it is a switch that is on, and whether it can be pressed. */
function menuItem(
  id: string,
  label: string,
  options: { checked?: boolean; disabled?: boolean } = {}
) {
  return (
    <MenuItem
      id={id}
      isDisabled={options.disabled ?? false}
      key={id}
      shortcut={options.checked ? <CheckIcon /> : undefined}
      textValue={label}
    >
      {label}
    </MenuItem>
  );
}

/**
 * Whether the tab is wide enough for the files and commits beside the diffs: at least `--container-md`. It changes
 * only when the width crosses that, so dragging the sidebar re-renders the tab once, not on every frame.
 */
function useWide(element: HTMLElement | null) {
  const [wide, setWide] = useState(false);
  useLayoutEffect(() => {
    if (!element || typeof ResizeObserver === "undefined") return undefined;
    const least = Number.parseFloat(
      getComputedStyle(element).getPropertyValue("--container-md")
    );
    if (!(least > 0)) return undefined;
    const measure = () => setWide(element.getBoundingClientRect().width >= least);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [element]);
  return wide;
}

/** What the tab shows the changes of: the whole branch, what is not committed yet, or one commit (its full sha). */
type ChangesScope = "all" | "uncommitted" | string;

function scopeParams(scope: ChangesScope) {
  if (scope === "all") return {};
  if (scope === "uncommitted") return { uncommitted: true };
  return { commit: scope };
}

/**
 * A coding Task's changes as a tab of the sidebar. A bar names what is compared (the base, then the session branch)
 * and holds the pull request to make, the files-and-commits switch and the tab's menu. Below, how much changed, then
 * each file's diff under a header that stays while it scrolls and folds it. Beside the diffs, the files, pressed to
 * come into view, and the branch's commits: all the changes, what is not committed yet, or one commit, whose changes
 * the diffs then show. A narrow tab has no room beside them: the files, then the commits, stand above the diffs.
 * Each part scrolls on its own, and handles between them drag their heights. The diff shows whole, wrapped to the width
 * (the menu turns that off), with each line's number in the file. Read while the tab is shown: when it opens or
 * comes back, each time it is opened from the Task panel (`page.revision`, which also lands it on the file pressed
 * there), after each of the Worker's turns, when the window comes back to the front, and on Refresh. What the Task's
 * conversation knows now (its sandbox's state, the Worker's turn) decides whether the pull request can be made.
 */
export function CodingChangesPanel({
  active,
  page,
}: {
  /** The tab is the one shown; a hidden tab keeps its changes without reading. */
  active: boolean;
  page: ChatSidebarChangesPage;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const [scope, setScope] = useState<ChangesScope>("all");
  // The last changes read, and which scope they are of: the commits stay while another scope is read. A Task seen
  // before opens on the whole branch's changes a surface of it last read, while they are read again.
  const [last, setLast] = useState<{
    scope: ChangesScope;
    changes: CodingChanges;
  } | null>(() => {
    const remembered = rememberedCodingChanges(page.taskId);
    return remembered ? { scope: "all", changes: remembered } : null;
  });
  const [failed, setFailed] = useState(false);
  const [showRail, setShowRail] = useState(true);
  const [commitsOpen, setCommitsOpen] = useState(true);
  // Heights the reader dragged the files and the commits to; unset, each takes its share of the tab.
  const [filesHeight, setFilesHeight] = useState<number | null>(null);
  const [commitsHeight, setCommitsHeight] = useState<number | null>(null);
  const filesPane = useRef<HTMLDivElement>(null);
  const commitsPane = useRef<HTMLElement>(null);
  const diffsPane = useRef<HTMLDivElement>(null);
  const [element, setElement] = useState<HTMLElement | null>(null);
  const wide = useWide(element);
  const [wrap, setWrap] = useState(true);
  const [folded, setFolded] = useState<ReadonlySet<string>>(() => new Set());
  const [menuOpen, setMenuOpen] = useState(false);
  const sections = useRef(new Map<string, HTMLElement>());

  const tickets = useReadTickets();
  const read = useCallback(() => {
    const ticket = tickets.take();
    // The core learns the branch's pull request from the whole branch's read, for every surface of the Task.
    call("coding.changes", {
      workspaceId: page.workspaceId,
      taskId: page.taskId,
      ...scopeParams(scope),
    }).then(
      (next) => {
        if (!tickets.current(ticket)) return;
        if (scope === "all") rememberCodingChanges(page.taskId, next);
        setLast({ scope, changes: next });
        setFailed(false);
        // A commit no longer on the branch, or nothing left uncommitted: back to all the changes.
        const gone =
          scope === "uncommitted"
            ? !next.uncommitted
            : scope !== "all" && !next.commits.some((commit) => commit.sha === scope);
        if (gone) setScope("all");
      },
      (failure: unknown) => {
        if (!tickets.current(ticket)) return;
        // The commit is no longer the branch's (amended or rebased away): back to all the changes, read again.
        if (
          scope !== "all" &&
          (failure as { code?: unknown } | null)?.code === "not_found"
        ) {
          setScope("all");
          return;
        }
        setFailed(true);
      }
    );
  }, [call, page.taskId, page.workspaceId, scope, tickets]);
  const changes = last?.scope === scope ? last.changes : null;
  const known = last?.changes ?? null;
  const facts = useCodingTaskFacts(page.taskId);
  const turnEnds = useTurnEnds(facts?.working);
  const windowReturns = useWindowReturns();
  const unfold = (path: string) =>
    setFolded((current) => {
      if (!current.has(path)) return current;
      const next = new Set(current);
      next.delete(path);
      return next;
    });
  // The file the tab was opened at comes into view, unfolded, once the changes show it: once per opening, so the
  // changes read again later (after a turn, when the window returns) do not take the reader back to it.
  const shownRevision = useRef<number | null>(null);
  useEffect(() => {
    if (!page.file || !changes || !active || shownRevision.current === page.revision)
      return;
    const section = sections.current.get(page.file);
    if (!section) return;
    shownRevision.current = page.revision;
    unfold(page.file);
    section.scrollIntoView({ block: "start" });
  }, [active, changes, page.file, page.revision]);
  const target = useMemo(
    () => ({ workspaceId: page.workspaceId, taskId: page.taskId }),
    [page.taskId, page.workspaceId]
  );
  const pullRequest = usePullRequest(target);
  const actions = usePullRequestActions(pullRequest);
  // Read while shown: when the tab opens or comes back, each time it is opened again, after a turn and when the window
  // returns. A hidden tab keeps what it has.
  useEffect(() => {
    if (active) read();
  }, [active, read, page.revision, turnEnds, windowReturns]);
  usePullRequestWatch(target, active);

  const files = changes?.files ?? [];
  const commits = known?.commits ?? [];
  const additions = files.reduce((sum, file) => sum + file.additions, 0);
  const deletions = files.reduce((sum, file) => sum + file.deletions, 0);
  const base = known?.base ?? page.base;
  const branch = known?.branch ?? page.branch;
  const repo = page.repo;
  const pr = pullRequest.pr ?? null;
  // A pull request stands until merged; a closed one, or a merged one the branch moved past, leaves work to propose.
  // The sandbox need not run: once it is gone, Comma opens the branch it pushed on GitHub.
  const canPropose =
    known !== null &&
    (known.commits.length > 0 ||
      known.uncommitted ||
      (last?.scope === "all" && known.files.length > 0)) &&
    proposable(pr);
  const blocked = pullRequestBlock(messages, {
    busy: pullRequest.busy,
    working: facts?.working ?? false,
  });
  // Where the changes are on GitHub: the pull request made here, else the branch against its base.
  const onGithub =
    pr?.url ??
    (repo && branch
      ? base
        ? `https://github.com/${repo.owner}/${repo.name}/compare/${base}...${branch}`
        : `https://github.com/${repo.owner}/${repo.name}/tree/${branch}`
      : null);
  const fileOnGithub = (path: string) =>
    repo && branch
      ? `https://github.com/${repo.owner}/${repo.name}/blob/${branch}/${path}`
      : null;
  const showFile = (path: string) => {
    unfold(path);
    sections.current.get(path)?.scrollIntoView({ block: "start" });
  };
  const toggleFile = (path: string) =>
    setFolded((current) => {
      const next = new Set(current);
      if (!next.delete(path)) next.add(path);
      return next;
    });
  const onMenuAction = (key: string | number) => {
    if (actions.handle(key)) return;
    if (key === "github" && onGithub) void openNativePlatformExternalUrl(onGithub);
    else if (key === "copy" && onGithub)
      void nativePlatformClipboard.writeText(onGithub).then(
        () => toast.success(messages.coding_link_copied()),
        () => undefined
      );
    else if (key === "draft") pullRequest.open(true);
    else if (key === "expand") setFolded(new Set());
    else if (key === "collapse") setFolded(new Set(files.map((file) => file.path)));
    else if (key === "wrap") setWrap((on) => !on);
    else if (key === "refresh") read();
  };
  const menuItems: ReactNode[] = [
    ...(onGithub
      ? [
          menuItem("github", messages.coding_repo_open()),
          menuItem("copy", messages.coding_copy_link()),
        ]
      : []),
    ...(canPropose
      ? [
          menuItem("draft", messages.coding_create_draft_pr(), {
            disabled: blocked !== null,
          }),
        ]
      : []),
    ...actions.items,
  ];
  if (menuItems.length > 0) menuItems.push(<MenuSeparator key="view-separator" />);
  menuItems.push(
    menuItem("expand", messages.coding_changes_expand_all(), {
      disabled: folded.size === 0,
    }),
    menuItem("collapse", messages.coding_changes_collapse_all(), {
      disabled: files.length === 0 || folded.size === files.length,
    }),
    <MenuSeparator key="wrap-separator" />,
    menuItem("wrap", messages.coding_changes_wrap(), { checked: wrap }),
    <MenuSeparator key="refresh-separator" />,
    menuItem("refresh", messages.coding_changes_refresh())
  );

  const index =
    files.length > 0 ? (
      <ol className="comma-coding-changes-index">
        {files.map((file) => (
          <li key={file.path}>
            <button
              className="comma-coding-changes-index-row"
              data-no-press-feedback
              data-testid="coding-changes-panel-index-row"
              onClick={() => showFile(file.path)}
              type="button"
            >
              <CodingFileName path={file.path} />
              <CodingLineCounts additions={file.additions} deletions={file.deletions} />
            </button>
          </li>
        ))}
      </ol>
    ) : null;
  const commitsSection =
    known && (commits.length > 0 || known.uncommitted) ? (
      <CommitsSection
        commits={commits}
        height={commitsHeight}
        onSelect={(next) => {
          setFailed(false);
          setScope(next);
        }}
        onToggle={() => setCommitsOpen((open) => !open)}
        open={commitsOpen}
        paneRef={commitsPane}
        scope={scope}
        uncommitted={known.uncommitted}
      />
    ) : null;
  // The commits' handle: beside the diffs it sits above them and gives them what it takes from the files; above the
  // diffs it sits below them and takes from the diffs. Folded, they have no height to drag.
  const commitsHandle =
    commitsSection && commitsOpen ? (
      <PaneSplitter
        label={messages.coding_changes_resize_commits()}
        onCommit={setCommitsHeight}
        onReset={() => setCommitsHeight(null)}
        pane={commitsPane}
        sign={wide ? -1 : 1}
        slack={wide ? filesPane : diffsPane}
      />
    ) : null;
  // Each part scrolls on its own and is as tall as dragged. Beside the diffs, the files fill the rail above the
  // commits; above them, the files, then the commits, then the diffs.
  const rail = (
    <aside
      aria-label={messages.coding_changes_rail()}
      className="comma-coding-changes-rail"
      data-wide={wide ? "true" : "false"}
    >
      <div
        className="comma-coding-changes-rail-files"
        ref={filesPane}
        style={
          !wide && filesHeight !== null
            ? { height: filesHeight, maxHeight: "none" }
            : undefined
        }
      >
        <ScrollArea className="min-h-0 flex-1" edgeEffect="none">
          {index}
        </ScrollArea>
      </div>
      {commitsSection ? (
        wide ? (
          <>
            {commitsHandle}
            {commitsSection}
          </>
        ) : (
          <>
            <PaneSplitter
              label={messages.coding_changes_resize_files()}
              onCommit={setFilesHeight}
              onReset={() => setFilesHeight(null)}
              pane={filesPane}
              sign={1}
              slack={diffsPane}
            />
            {commitsSection}
          </>
        )
      ) : null}
    </aside>
  );
  const diffsView = (
    <>
      {changes ? (
        <p className="comma-coding-changes-summary">
          {scope !== "all" ? (
            <span className="comma-coding-changes-scope">
              {scope === "uncommitted"
                ? messages.coding_changes_uncommitted()
                : scope.slice(0, 7)}
            </span>
          ) : null}
          <span>
            {messages.coding_changes_files({
              count: formatNumber(files.length, locale),
            })}
          </span>
          {files.length > 0 ? (
            <CodingLineCounts additions={additions} deletions={deletions} />
          ) : null}
          {changes.source === "github" ? (
            <span className="comma-coding-changes-note">
              {messages.coding_changes_pushed()}
            </span>
          ) : null}
        </p>
      ) : null}
      {failed ? (
        <p className="comma-task-panel-feedback" role="alert">
          {messages.coding_changes_failed()}
        </p>
      ) : null}
      {!changes && !failed ? (
        <output className="comma-coding-changes-loading">
          <LoadingIndicator label={messages.common_loading()} />
        </output>
      ) : null}
      {changes && files.length === 0 ? (
        <p className="comma-task-panel-empty">{messages.coding_changes_none()}</p>
      ) : null}
      {files.map((file) => {
        const open = !folded.has(file.path);
        const slash = file.path.lastIndexOf("/");
        const name = slash === -1 ? file.path : file.path.slice(slash + 1);
        const status = codingFileStatus(messages, file.status);
        const url = fileOnGithub(file.path);
        return (
          <section
            className="comma-coding-changes-file"
            data-open={open ? "true" : "false"}
            data-testid="coding-changes-panel-file"
            key={file.path}
            ref={(node) => {
              if (node) sections.current.set(file.path, node);
              else sections.current.delete(file.path);
            }}
          >
            <div className="comma-coding-changes-file-head">
              <button
                aria-expanded={open}
                aria-label={messages.coding_changes_fold_file({ name })}
                className="comma-coding-changes-fold"
                data-no-press-feedback
                onClick={() => toggleFile(file.path)}
                type="button"
              >
                <ChevronDownSmallIcon />
              </button>
              <CodingFileName path={file.path} />
              {status ? (
                <span className="comma-task-coding-status">{status}</span>
              ) : null}
              <CodingLineCounts additions={file.additions} deletions={file.deletions} />
              {url ? (
                <button
                  aria-label={`${name} · ${messages.coding_repo_open()}`}
                  className="comma-coding-changes-file-open"
                  data-no-press-feedback
                  onClick={() => void openNativePlatformExternalUrl(url)}
                  title={messages.coding_repo_open()}
                  type="button"
                >
                  <ArrowUpRightIcon />
                </button>
              ) : null}
            </div>
            {open ? (
              file.patch ? (
                <DiffBlock diff={file.patch} wrap={wrap} />
              ) : (
                <p className="comma-coding-changes-omitted">
                  {messages.coding_changes_truncated()}
                </p>
              )
            ) : null}
          </section>
        );
      })}
    </>
  );

  return (
    <section
      aria-label={messages.coding_changes()}
      className="comma-coding-changes"
      data-testid="coding-changes-panel"
      ref={setElement}
    >
      <header className="comma-coding-changes-bar">
        <span className="comma-coding-changes-ref">
          <BranchIcon aria-hidden className="comma-coding-changes-ref-icon" />
          {base ? (
            <>
              <span className="comma-coding-changes-base">{base}</span>
              <ArrowRightIcon aria-hidden className="comma-coding-changes-arrow" />
            </>
          ) : null}
          <span className="comma-coding-changes-branch">{branch}</span>
        </span>
        <span className="comma-coding-changes-bar-end">
          {pr ? <PullRequestLink pr={pr} /> : null}
          {canPropose ? (
            <CreatePullRequestButton
              blocked={blocked}
              onPress={() => pullRequest.open(false)}
              testId="coding-changes-panel-create"
            >
              {messages.coding_create_pr()}
            </CreatePullRequestButton>
          ) : null}
          <AriaButton
            aria-label={messages.coding_changes_show_files()}
            aria-pressed={showRail}
            className="comma-task-coding-more comma-coding-changes-rail-toggle"
            data-testid="coding-changes-panel-rail-toggle"
            onPress={() => setShowRail((shown) => !shown)}
          >
            <ListBulletsIcon />
          </AriaButton>
          <MenuTrigger isOpen={menuOpen} onOpenChange={setMenuOpen}>
            <AriaButton
              aria-label={messages.coding_changes_menu()}
              className="comma-task-coding-more"
              data-testid="coding-changes-panel-menu"
            >
              <MoreHorizontalIcon />
            </AriaButton>
            <MenuPopover placement="bottom end">
              <Menu aria-label={messages.coding_changes_menu()} onAction={onMenuAction}>
                {menuItems}
              </Menu>
            </MenuPopover>
          </MenuTrigger>
        </span>
      </header>
      {showRail ? (
        <div className="comma-coding-changes-main" data-wide={wide ? "true" : "false"}>
          {wide ? null : rail}
          {wide ? null : commitsSection ? (
            commitsHandle
          ) : (
            <PaneSplitter
              label={messages.coding_changes_resize_files()}
              onCommit={setFilesHeight}
              onReset={() => setFilesHeight(null)}
              pane={filesPane}
              sign={1}
              slack={diffsPane}
            />
          )}
          <ScrollArea
            className="comma-coding-changes-diffs"
            edgeEffect="none"
            ref={diffsPane}
          >
            <div className="comma-coding-changes-body">{diffsView}</div>
          </ScrollArea>
          {wide ? rail : null}
        </div>
      ) : (
        <ScrollArea className="comma-coding-changes-diffs" edgeEffect="none">
          <div className="comma-coding-changes-body">{diffsView}</div>
        </ScrollArea>
      )}
      {actions.dialogs}
    </section>
  );
}

/**
 * The branch's commits under a heading that folds them: all the changes, what is not committed yet (while there is
 * some), then each commit, the newest first, by its first line and its short sha, author and age. The one pressed is
 * what the diffs show.
 */
function CommitsSection({
  commits,
  height,
  onSelect,
  onToggle,
  open,
  paneRef,
  scope,
  uncommitted,
}: {
  commits: CodingCommit[];
  /** The height the reader dragged the commits to; unset, their share of the tab. */
  height: number | null;
  onSelect: (scope: ChangesScope) => void;
  onToggle: () => void;
  open: boolean;
  scope: ChangesScope;
  paneRef: RefObject<HTMLElement | null>;
  uncommitted: boolean;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const now = uiClock.now();
  const row = (key: ChangesScope, title: string, meta: string | null) => (
    <li key={key}>
      <button
        aria-current={scope === key ? "true" : undefined}
        className="comma-coding-changes-commit"
        data-no-press-feedback
        data-testid="coding-changes-panel-commit"
        onClick={() => onSelect(key)}
        type="button"
      >
        <span className="comma-coding-changes-commit-title">{title}</span>
        {meta ? <span className="comma-coding-changes-commit-meta">{meta}</span> : null}
      </button>
    </li>
  );
  const list = (
    <ol className="comma-coding-changes-commits-list">
      {row("all", messages.coding_changes_all(), null)}
      {uncommitted
        ? row("uncommitted", messages.coding_changes_uncommitted(), null)
        : null}
      {commits.map((commit) =>
        row(
          commit.sha,
          commit.title,
          [
            commit.sha.slice(0, 7),
            commit.author,
            commit.at ? formatRelativeTime(Date.parse(commit.at), locale, now) : null,
          ]
            .filter((part) => part)
            .join(" · ")
        )
      )}
    </ol>
  );
  return (
    <section
      className="comma-coding-changes-commits"
      data-open={open ? "true" : "false"}
      ref={paneRef}
      style={open && height !== null ? { height, maxHeight: "none" } : undefined}
    >
      <button
        aria-expanded={open}
        aria-label={messages.coding_changes_commits_fold()}
        className="comma-coding-changes-commits-head"
        data-no-press-feedback
        onClick={onToggle}
        type="button"
      >
        <ChevronDownSmallIcon
          aria-hidden
          className="comma-coding-changes-commits-chevron"
        />
        <span className="comma-coding-changes-commits-label">
          {messages.coding_changes_commits()}
        </span>
        <span className="comma-coding-changes-commits-count">
          {formatNumber(commits.length, locale)}
        </span>
      </button>
      {open ? (
        <ScrollArea className="comma-coding-changes-commits-scroll" edgeEffect="none">
          {list}
        </ScrollArea>
      ) : null}
    </section>
  );
}

/**
 * A handle between two parts of the tab that drags the height of `pane`: `sign` 1 where the handle is below it, -1
 * where it is above. The pane gives and takes height from `slack`, the part that fills what is left, and neither
 * goes under `--spacing-6xl`. While dragging, the height is written to the pane directly, without rendering, and
 * kept (`onCommit`) when the pointer lets go. Arrow keys move it by `--spacing-xl`; a double press gives the pane its
 * share back (`onReset`).
 */
function PaneSplitter({
  label,
  onCommit,
  onReset,
  pane,
  sign,
  slack,
}: {
  label: string;
  onCommit: (height: number) => void;
  onReset: () => void;
  pane: RefObject<HTMLElement | null>;
  sign: 1 | -1;
  slack: RefObject<HTMLElement | null>;
}) {
  const drag = useRef<{
    start: number;
    height: number;
    least: number;
    most: number;
  } | null>(null);
  const bounds = (handle: HTMLElement) => {
    const target = pane.current;
    const rest = slack.current;
    if (!target || !rest) return null;
    const least =
      Number.parseFloat(getComputedStyle(handle).getPropertyValue("--spacing-6xl")) ||
      0;
    const height = target.getBoundingClientRect().height;
    const most = Math.max(height, height + rest.getBoundingClientRect().height - least);
    return { height, least, most };
  };
  const apply = (height: number) => {
    const target = pane.current;
    if (!target) return;
    target.style.height = `${height}px`;
    target.style.maxHeight = "none";
  };
  const onPointerDown = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (event.button !== 0) return;
    const measured = bounds(event.currentTarget);
    if (!measured) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    drag.current = { start: event.clientY, ...measured };
  };
  const onPointerMove = (event: ReactPointerEvent<HTMLButtonElement>) => {
    const d = drag.current;
    if (!d) return;
    apply(
      Math.min(d.most, Math.max(d.least, d.height + sign * (event.clientY - d.start)))
    );
  };
  const onPointerUp = (event: ReactPointerEvent<HTMLButtonElement>) => {
    const d = drag.current;
    drag.current = null;
    if (!d || !pane.current) return;
    event.currentTarget.releasePointerCapture(event.pointerId);
    onCommit(pane.current.getBoundingClientRect().height);
  };
  const onKeyDown = (event: ReactKeyboardEvent<HTMLButtonElement>) => {
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    const measured = bounds(event.currentTarget);
    if (!measured) return;
    event.preventDefault();
    const step =
      Number.parseFloat(
        getComputedStyle(event.currentTarget).getPropertyValue("--spacing-xl")
      ) || 0;
    const delta = (event.key === "ArrowDown" ? step : -step) * sign;
    const next = Math.min(
      measured.most,
      Math.max(measured.least, measured.height + delta)
    );
    apply(next);
    onCommit(next);
  };
  return (
    <button
      aria-label={label}
      aria-orientation="horizontal"
      className="comma-coding-changes-splitter"
      data-testid="coding-changes-panel-splitter"
      onDoubleClick={() => {
        const target = pane.current;
        if (target) {
          target.style.removeProperty("height");
          target.style.removeProperty("max-height");
        }
        onReset();
      }}
      onKeyDown={onKeyDown}
      onLostPointerCapture={() => (drag.current = null)}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      role="separator"
      type="button"
    />
  );
}
