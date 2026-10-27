import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { fireEvent, render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { beforeEach, expect, it, vi } from "vitest";
import type { ChatTaskRun } from "@comma/chat-contract";
import { TaskDetailsPanel, type TaskDetailsPanelProps } from "../TaskDetailsPanel";
import { CodingPullRequestPrompt } from "../CodingPullRequestPrompt";
import {
  forgetCodingRecords,
  forgetCodingTaskFacts,
  type CodingFacts,
} from "../CodingSession";
import { pullRequestScript } from "./pullRequestScript";

const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

beforeEach(() => {
  setInteractionModality("pointer");
  forgetCodingRecords();
  forgetCodingTaskFacts();
});

const conversation = {
  client_platform: "macos",
  id: "cnv_1",
  labels: [],
  origin: "comma",
  status: "running",
} as unknown as TaskDetailsPanelProps["conversation"];

/** A coding Task on its sandbox, as the Task status stream says it. */
const run = (state: string): ChatTaskRun => ({
  place: {
    kind: "sandbox",
    repo: { owner: "acme", name: "api", baseRef: "main", branch: "comma/abc" },
    state,
  },
  model: { kind: "runtime", provider: "claude", name: "claude-opus-4-5" },
  vendor: "anthropic",
});

const changes = (source: "sandbox" | "github") => ({
  source,
  base: "main",
  branch: "comma/abc",
  truncated: false,
  files: [
    {
      path: "src/retry.ts",
      status: "modified",
      additions: 3,
      deletions: 1,
      patch: "@@ -1 +1 @@\n-a\n+b",
    },
    { path: "README.md", status: "added", additions: 12, deletions: 0, patch: null },
  ],
});

const unavailableHistory = {
  available: false,
  start: 0,
  total: 0,
  items: [],
  usage: null,
};

const pullRequest = { url: "https://github.com/acme/api/pull/7", number: 7 };

/** The branch's pull request as the changes carry it. */
const branchPullRequest = (
  state: string,
  mergeable: string,
  checks: {
    passed: number;
    failed: number;
    skipped?: number;
    total: number;
  } | null = null,
  more: { body?: string; newCommits?: boolean } = {}
) => ({
  url: "https://github.com/acme/api/pull/9",
  number: 9,
  title: "Back off between retries",
  body: more.body ?? "Make the retry helper back off.",
  headSha: "9".repeat(40),
  state,
  mergeable,
  checks,
  newCommits: more.newCommits ?? false,
});

/** The pull request made from here (#7), as GitHub reads it once made. */
const madePullRequest = (state = "open") => ({
  url: "https://github.com/acme/api/pull/7",
  number: 7,
  title: "Retry with backoff",
  body: "Make the retry helper back off.",
  headSha: "7".repeat(40),
  state,
  mergeable: "mergeable",
  checks: null,
  newCommits: false,
});

/** Hovers `element` long enough for its tooltip, and gives the tooltip's text. */
async function tooltipOf(element: HTMLElement) {
  await user().hover(element);
  await advance(400);
  return (await screen.findByRole("tooltip")).textContent;
}

/**
 * A core that answers the panel's coding calls with `calls`, keeps the Task's pull request as the core would from what
 * they answer (`learn` says what it learned meanwhile), and shows no label catalog. `watches` lists the pull request
 * watches it was asked for, `true` when one starts and `false` when it ends.
 */
function panelCore(calls: (name: string, params: unknown) => unknown) {
  const script = pullRequestScript(calls);
  const watches: boolean[] = [];
  const watch = (topic: Record<string, unknown>, on: boolean) => {
    if (topic.topic === "codingPullRequestWatch") watches.push(on);
  };
  const core = script.attach(
    createScriptedCore({
      calls: script.calls,
      onSubscribe: (topic) => watch(topic, true),
      onUnsubscribe: (topic) => watch(topic, false),
      values: (topic) =>
        script.values(topic) ??
        (topic.topic === "taskLabels"
          ? { catalog: null, error: false, loading: false }
          : topic.topic === "marks"
            ? { marks: {} }
            : undefined),
    })
  );
  return Object.assign(core, { learn: script.learn, watches });
}

function renderPanel(
  core: ReturnType<typeof panelCore>,
  state: string,
  onOpenCodingChanges?: (file?: string) => void,
  onOpenCodingTerminal?: (url: string) => void,
  working = false
) {
  return render(
    core.wrap(
      <TaskDetailsPanel
        activityWorking={working}
        coding={{ workspaceId: "w1", taskId: "cnv_1" }}
        conversation={conversation}
        groupId="grp_1"
        labeled={false}
        onOpenCodingChanges={onOpenCodingChanges}
        onOpenCodingTerminal={onOpenCodingTerminal}
        open
        run={run(state)}
      />
    )
  );
}

it("shows the sandbox, its repository and branch, and the changes in one line that opens the Changes tab and makes the pull request", async () => {
  const core = panelCore((name) => {
    if (name === "coding.changes") return changes("sandbox");
    if (name === "coding.history") return unavailableHistory;
    if (name === "coding.pullRequest") return pullRequest;
    if (name === "status") return madePullRequest();
    return null;
  });
  const onOpenCodingChanges = vi.fn();
  renderPanel(core, "ready", onOpenCodingChanges);
  await flush();
  await flush();

  const environment = within(screen.getByTestId("task-panel-environment"));
  // Running is the normal state: the row says nothing of it.
  expect(environment.queryByTestId("task-panel-sandbox-state")).toBeNull();
  // The repository and branch rows each open a menu of what to do with them.
  await user().click(environment.getByRole("button", { name: "acme/api" }));
  let menu = within(await screen.findByRole("menu"));
  expect(menu.getAllByRole("menuitem").map((item) => item.textContent)).toEqual([
    "Open on GitHub",
    "Copy link",
    "Open in terminal",
  ]);
  await user().keyboard("{Escape}");
  await user().click(environment.getByRole("button", { name: "comma/abc" }));
  menu = within(await screen.findByRole("menu"));
  expect(menu.getAllByRole("menuitem").map((item) => item.textContent)).toEqual([
    "Copy branch name",
    "Open in terminal",
  ]);
  await user().keyboard("{Escape}");
  expect(environment.getByText("on main")).toBeVisible();
  expect(environment.getByRole("button", { name: "Open terminal" })).toBeVisible();

  // The changes are one line: their lines over every file, which opens the Changes tab.
  const section = within(screen.getByTestId("task-panel-changes"));
  expect(section.queryByText("retry.ts")).toBeNull();
  const chip = section.getByTestId("task-panel-changes-open");
  expect(chip).toHaveTextContent("+15−1");
  expect(chip).toHaveAccessibleName("15 lines added, 1 removed · View the changes");
  await user().click(chip);
  expect(onOpenCodingChanges).toHaveBeenCalledTimes(1);
  expect(onOpenCodingChanges).toHaveBeenCalledWith();

  // The pull request is made from the line; once made, the line is its card.
  await user().click(section.getByRole("button", { name: "Create PR" }));
  await flush();
  await flush();
  expect(core.sentTo("coding.pullRequest")).toEqual([
    { workspaceId: "w1", taskId: "cnv_1", draft: false },
  ]);
  const link = section.getByTestId("task-panel-changes-pr");
  expect(link).toHaveTextContent("Retry with backoff");
  expect(link).toHaveAttribute("data-state", "open");
  expect(section.getByText("#7")).toBeVisible();
  expect(section.queryByRole("button", { name: "Create PR" })).toBeNull();
});

it("shows the branch's pull request as its card: the title in its colour, the number and lines under it, with nothing more to propose once merged", async () => {
  const core = panelCore((name) => {
    if (name === "coding.changes")
      return {
        ...changes("sandbox"),
        pullRequest: branchPullRequest("merged", "unknown", {
          passed: 29,
          failed: 0,
          total: 29,
        }),
      };
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  renderPanel(core, "ready", vi.fn());
  await flush();
  await flush();

  const section = within(screen.getByTestId("task-panel-changes"));
  const link = section.getByTestId("task-panel-changes-pr");
  expect(link).toHaveAttribute("data-state", "merged");
  expect(link).toHaveTextContent("Back off between retries");
  expect(link).toHaveAccessibleName(
    "Back off between retries · PR #9 · Merged · 29 of 29 checks passed"
  );
  expect(section.getByText("#9")).toBeVisible();
  expect(section.getByTestId("task-panel-changes-open")).toHaveTextContent("+15−1");
  // Merged, its checks no longer matter: no dot.
  expect(section.queryByTestId("task-panel-changes-checks")).toBeNull();
  expect(section.queryByRole("button", { name: "Create PR" })).toBeNull();
  await user().click(section.getByRole("button", { name: "More for the changes" }));
  const menu = within(await screen.findByRole("menu"));
  expect(menu.queryByRole("menuitem", { name: "Create draft PR" })).toBeNull();
});

it("marks an open pull request with conflicts, and lets a closed one be proposed again", async () => {
  const conflicting = panelCore((name) => {
    if (name === "coding.changes")
      return {
        ...changes("sandbox"),
        pullRequest: branchPullRequest("open", "conflicting"),
      };
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  const first = renderPanel(conflicting, "ready", vi.fn());
  await flush();
  await flush();
  const link = screen.getByTestId("task-panel-changes-pr");
  expect(link).toHaveAttribute("data-conflicting", "true");
  expect(link).toHaveAccessibleName("Back off between retries · PR #9 · Has conflicts");
  expect(screen.queryByTestId("task-panel-changes-checks")).toBeNull();
  first.unmount();

  const failing = panelCore((name) => {
    if (name === "coding.changes")
      return {
        ...changes("sandbox"),
        pullRequest: branchPullRequest("open", "mergeable", {
          passed: 2,
          failed: 1,
          skipped: 1,
          total: 5,
        }),
      };
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  const second = renderPanel(failing, "ready", vi.fn());
  await flush();
  await flush();
  const chip = screen.getByTestId("task-panel-changes-checks");
  expect(chip).toHaveAttribute("data-checks", "failed");
  expect(chip).toHaveAccessibleName("1 of 5 checks failed");
  expect(chip).toHaveTextContent("1 failing");
  // Hovering shows the checks by outcome, the ones that have any, and links to them on GitHub.
  await user().hover(chip);
  await advance(400);
  const panel = within(await screen.findByRole("dialog", { name: "CI checks" }));
  expect(panel.getAllByRole("listitem").map((row) => row.textContent)).toEqual([
    "Failed1",
    "In progress2",
    "Passed1",
    "Skipped1",
  ]);
  const open = vi.spyOn(window, "open").mockReturnValue(null);
  await user().click(panel.getByRole("button", { name: "Open checks on GitHub" }));
  expect(open).toHaveBeenLastCalledWith(
    "https://github.com/acme/api/pull/9/checks",
    "_blank",
    "noopener,noreferrer"
  );
  open.mockRestore();
  second.unmount();

  const closed = panelCore((name) => {
    if (name === "coding.changes")
      return {
        ...changes("sandbox"),
        pullRequest: branchPullRequest("closed", "unknown"),
      };
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  renderPanel(closed, "ready", vi.fn());
  await flush();
  await flush();
  expect(screen.getByTestId("task-panel-changes-pr")).toHaveAttribute(
    "data-state",
    "closed"
  );
  const again = screen.getByRole("button", { name: "Create PR" });
  expect(again).toBeVisible();
  expect(again).not.toHaveAttribute("aria-disabled");
});

it("offers the rest from the line's menu: the changes, the branch on GitHub, its link, and a draft pull request", async () => {
  const core = panelCore((name) => {
    if (name === "coding.changes") return changes("sandbox");
    if (name === "coding.history") return unavailableHistory;
    if (name === "coding.pullRequest") return pullRequest;
    return null;
  });
  renderPanel(core, "ready", vi.fn());
  await flush();
  await flush();

  const section = within(screen.getByTestId("task-panel-changes"));
  // A right-click on the line opens the same menu where the pointer is.
  fireEvent.contextMenu(section.getByTestId("task-panel-changes-summary"), {
    clientX: 40,
    clientY: 12,
  });
  const fromPointer = within(await screen.findByRole("menu"));
  expect(fromPointer.getByRole("menuitem", { name: "Copy link" })).toBeVisible();
  await user().keyboard("{Escape}");
  await flush();
  expect(screen.queryByRole("menu")).toBeNull();

  await user().click(section.getByRole("button", { name: "More for the changes" }));
  const menu = within(await screen.findByRole("menu"));
  expect(menu.getByRole("menuitem", { name: "View the changes" })).toBeVisible();
  expect(menu.getByRole("menuitem", { name: "Open on GitHub" })).toBeVisible();
  expect(menu.getByRole("menuitem", { name: "Copy link" })).toBeVisible();
  await user().click(menu.getByRole("menuitem", { name: "Create draft PR" }));
  await flush();
  expect(core.sentTo("coding.pullRequest")).toEqual([
    { workspaceId: "w1", taskId: "cnv_1", draft: true },
  ]);
});

it("only shows the line where nothing can show the changes file by file", async () => {
  const core = panelCore((name) => {
    if (name === "coding.changes") return changes("sandbox");
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  renderPanel(core, "ready");
  await flush();
  await flush();
  const section = within(screen.getByTestId("task-panel-changes"));
  expect(section.getByTestId("task-panel-changes-summary")).toHaveTextContent("+15−1");
  expect(section.queryByTestId("task-panel-changes-open")).toBeNull();
});

it("puts an ended session's line at the foot of its branch's menu", async () => {
  const core = panelCore((name) => {
    if (name === "coding.changes") return changes("github");
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  renderPanel(core, "ended", vi.fn());
  await flush();
  await flush();

  expect(screen.queryByTestId("task-panel-sandbox-hint")).toBeNull();
  const environment = within(screen.getByTestId("task-panel-environment"));
  await user().click(environment.getByRole("button", { name: "comma/abc" }));
  const menu = await screen.findByRole("menu");
  expect(
    within(menu)
      .getAllByRole("menuitem")
      .map((item) => item.textContent)
  ).toEqual(["Copy branch name"]);
  expect(screen.getByTestId("task-panel-coding-menu-note")).toHaveTextContent(
    "The session has ended. Its branch stays on GitHub."
  );
  expect(menu).toHaveAccessibleDescription(
    "The session has ended. Its branch stays on GitHub."
  );
});

it("keeps an ended session's line under the rows where it has no branch", async () => {
  const core = panelCore((name) => {
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  render(
    core.wrap(
      <TaskDetailsPanel
        coding={{ workspaceId: "w1", taskId: "cnv_1" }}
        conversation={conversation}
        groupId="grp_1"
        labeled={false}
        open
        run={{
          ...run("ended"),
          place: {
            kind: "sandbox",
            repo: { owner: "acme", name: "api" },
            state: "ended",
          },
        }}
      />
    )
  );
  await flush();
  await flush();

  expect(screen.queryByTestId("task-panel-coding-branch")).toBeNull();
  expect(screen.getByTestId("task-panel-sandbox-hint")).toHaveTextContent(
    "The session has ended. Its branch stays on GitHub."
  );
});

it("a sandbox Task without a repository shows its sandbox and terminal, and no repository, branch or changes", async () => {
  const core = panelCore(() => null);
  render(
    core.wrap(
      <TaskDetailsPanel
        activityWorking={false}
        coding={{ workspaceId: "w1", taskId: "cnv_1" }}
        conversation={conversation}
        groupId="grp_1"
        labeled={false}
        open
        run={{ ...run("ready"), place: { kind: "sandbox", state: "ready" } }}
      />
    )
  );
  await flush();
  await flush();

  const environment = within(screen.getByTestId("task-panel-environment"));
  expect(environment.queryByTestId("task-panel-coding-repo")).toBeNull();
  expect(environment.queryByTestId("task-panel-coding-branch")).toBeNull();
  expect(environment.getByTestId("task-panel-coding-terminal")).toBeTruthy();
});

it("says what to do when the sandbox is gone, and still makes the pull request of the branch it pushed", async () => {
  const core = panelCore((name) => {
    if (name === "coding.changes") return changes("github");
    if (name === "coding.history") return unavailableHistory;
    if (name === "coding.pullRequest") return pullRequest;
    if (name === "status") return madePullRequest();
    return null;
  });
  renderPanel(core, "stopped", vi.fn());
  await flush();
  await flush();

  expect(screen.getByTestId("task-panel-sandbox-state")).toHaveTextContent("Stopped");
  expect(screen.getByTestId("task-panel-sandbox-hint")).toHaveTextContent(
    "Shut down while idle; the branch is pushed. Reply to continue from it."
  );
  // Comma opens the pushed branch on GitHub: the sandbox need not run for the pull request.
  const create = screen.getByRole("button", { name: "Create PR" });
  expect(create).not.toHaveAttribute("aria-disabled");
  await user().click(create);
  await flush();
  await flush();
  expect(core.sentTo("coding.pullRequest")).toEqual([
    { workspaceId: "w1", taskId: "cnv_1", draft: false },
  ]);
  expect(screen.getByTestId("task-panel-changes-pr")).toHaveTextContent(
    "Retry with backoff"
  );
  expect(screen.queryByRole("button", { name: "Open terminal" })).toBeNull();
  // The record lives on the sandbox, and none was read while it ran: both its sections say it cannot be read.
  expect(screen.getByTestId("task-panel-execution")).toHaveTextContent(
    /^ExecutionUnavailable$/
  );
  expect(screen.getByTestId("task-panel-activity")).toHaveTextContent(
    /^ActivityUnavailable$/
  );
});

it("keeps showing the record it read once the sandbox stops, without offering what only the sandbox can read", async () => {
  const record = {
    available: true,
    start: 3,
    total: 4,
    usage: {
      modelCalls: 2,
      inputTokens: 4000,
      cachedTokens: 1000,
      outputTokens: 300,
      model: "claude-opus-4-5",
    },
    items: [
      { kind: "received", id: "h3", text: "add retries", at: null },
      {
        kind: "group",
        id: "h4",
        failures: 0,
        pending: 0,
        steps: [
          {
            kind: "tool",
            id: "h4",
            tool: "Edit",
            hint: "src/retry.ts",
            body: { kind: "edit", path: "src/retry.ts", diff: "-a\n+b" },
            result: null,
            pending: false,
            failed: false,
            durationMs: 200,
          },
        ],
      },
    ],
  };
  let running = true;
  const core = panelCore((name) => {
    if (name === "coding.changes") return changes(running ? "sandbox" : "github");
    if (name === "coding.history") return running ? record : unavailableHistory;
    return null;
  });
  const view = renderPanel(core, "ready");
  await flush();
  await flush();
  expect(screen.getByTestId("task-panel-usage-line")).toHaveTextContent(
    "4.3K tokens · 2 model calls"
  );
  expect(screen.getByRole("button", { name: "Show earlier steps" })).toBeVisible();

  running = false;
  view.rerender(
    core.wrap(
      <TaskDetailsPanel
        coding={{ workspaceId: "w1", taskId: "cnv_1" }}
        conversation={conversation}
        groupId="grp_1"
        labeled={false}
        onOpenCodingChanges={vi.fn()}
        open
        run={run("stopped")}
      />
    )
  );
  await flush();
  await flush();
  // The sandbox answered nothing: what it answered last stands.
  expect(core.sentTo("coding.history")).toHaveLength(2);
  expect(screen.getByTestId("task-panel-usage-line")).toHaveTextContent(
    "4.3K tokens · 2 model calls"
  );
  expect(screen.getByText("add retries")).toBeVisible();
  // Earlier steps are read from the sandbox: none to offer while it is stopped.
  expect(screen.queryByRole("button", { name: "Show earlier steps" })).toBeNull();
});

/** A record of one request, with its token use. */
const shortRecord = {
  available: true,
  start: 0,
  total: 1,
  usage: {
    modelCalls: 2,
    inputTokens: 4000,
    cachedTokens: 1000,
    outputTokens: 300,
    model: null,
  },
  items: [{ kind: "received", id: "h0", text: "add retries", at: null }],
};

it("shows a Task's changes and record at once when it opens again, while it reads them again", async () => {
  const first = renderPanel(
    panelCore((name) =>
      name === "coding.changes"
        ? changes("sandbox")
        : name === "coding.history"
          ? shortRecord
          : null
    ),
    "ready",
    vi.fn()
  );
  await flush();
  await flush();
  expect(screen.getByTestId("task-panel-usage-line")).toHaveTextContent(
    "4.3K tokens · 2 model calls"
  );
  first.unmount();

  // Opened again: its reads are on their way, and what the panel read before shows meanwhile.
  const again = panelCore((name) =>
    name === "coding.changes" || name === "coding.history"
      ? new Promise(() => undefined)
      : null
  );
  renderPanel(again, "ready", vi.fn());
  await flush();
  expect(again.sentTo("coding.history")).toHaveLength(1);
  expect(again.sentTo("coding.changes")).toHaveLength(1);
  expect(screen.getByTestId("task-panel-usage-line")).toHaveTextContent(
    "4.3K tokens · 2 model calls"
  );
  expect(screen.getByText("add retries")).toBeVisible();
  expect(screen.getByTestId("task-panel-changes-open")).toHaveTextContent("+15−1");
});

/** What the server kept of the Task's sandbox and GitHub when its Worker's last turn ended. */
const facts = (withPullRequest: boolean): CodingFacts => ({
  usage: {
    modelCalls: 36,
    inputTokens: 1_752_000,
    cachedTokens: 1_700_000,
    outputTokens: 9_100,
    model: null,
  },
  changes: { files: 24, additions: 2_676, deletions: 996 },
  pullRequest: withPullRequest
    ? {
        url: "https://github.com/acme/api/pull/9",
        number: 9,
        title: "Back off between retries",
        body: null,
        headSha: "9".repeat(40),
        state: "open",
        mergeable: "mergeable",
        checks: { passed: 98, failed: 0, skipped: 0, total: 100 },
        newCommits: false,
      }
    : null,
});

function renderPanelWithFacts(core: ReturnType<typeof panelCore>, kept: CodingFacts) {
  return render(
    core.wrap(
      <TaskDetailsPanel
        coding={{ workspaceId: "w1", taskId: "cnv_1" }}
        conversation={conversation}
        groupId="grp_1"
        labeled={false}
        onOpenCodingChanges={vi.fn()}
        open
        run={{ ...run("ready"), facts: kept }}
      />
    )
  );
}

it("shows the token use, change totals and pull request the server kept while the panel's own reads are on their way", async () => {
  const core = panelCore((name) =>
    name === "coding.changes" || name === "coding.history"
      ? new Promise(() => undefined)
      : null
  );
  renderPanelWithFacts(core, facts(true));
  await flush();
  expect(core.sentTo("coding.history")).toHaveLength(1);
  expect(core.sentTo("coding.changes")).toHaveLength(1);
  expect(screen.getByTestId("task-panel-usage-line")).toHaveTextContent(
    "1.8M tokens · 36 model calls"
  );
  const line = screen.getByTestId("task-panel-changes-summary");
  expect(within(line).getByText("Back off between retries")).toBeVisible();
  expect(within(line).getByText("#9")).toBeVisible();
  expect(within(line).getByTestId("task-panel-changes-open")).toHaveTextContent(
    "+2,676−996"
  );
});

it("keeps showing the token use the server kept when the stopped sandbox answers no record", async () => {
  const core = panelCore((name) =>
    name === "coding.history"
      ? unavailableHistory
      : name === "coding.changes"
        ? new Promise(() => undefined)
        : null
  );
  renderPanelWithFacts(core, facts(false));
  await flush();
  await flush();
  expect(core.sentTo("coding.history")).toHaveLength(1);
  expect(screen.getByTestId("task-panel-usage-line")).toHaveTextContent(
    "1.8M tokens · 36 model calls"
  );
  // Only the steps, which the server does not keep, say the record cannot be read.
  expect(
    within(screen.getByTestId("task-panel-execution")).queryByText("Unavailable")
  ).toBeNull();
  expect(
    within(screen.getByTestId("task-panel-activity")).getByText("Unavailable")
  ).toBeVisible();
});

it("offers to make a pull request only once the changes are read", async () => {
  let answer!: (value: unknown) => void;
  const read = new Promise((resolve) => (answer = resolve));
  const core = panelCore((name) =>
    name === "coding.changes"
      ? read
      : name === "coding.history"
        ? new Promise(() => undefined)
        : null
  );
  renderPanelWithFacts(core, facts(false));
  await flush();
  // The totals show at once; what the line offers to do waits for the sandbox to answer.
  expect(screen.getByTestId("task-panel-changes-open")).toHaveTextContent("+2,676−996");
  expect(screen.queryByTestId("task-panel-changes-create")).toBeNull();

  answer(changes("sandbox"));
  await flush();
  await flush();
  expect(screen.getByTestId("task-panel-changes-open")).toHaveTextContent("+15−1");
  expect(screen.getByTestId("task-panel-changes-create")).toBeVisible();
});

it("never shows another Task's changes or record while the Task it switched to reads its own", async () => {
  const core = panelCore((name, params) => {
    if ((params as { taskId?: string }).taskId === "cnv_2")
      return new Promise(() => undefined);
    if (name === "coding.changes") return changes("sandbox");
    if (name === "coding.history") return shortRecord;
    return null;
  });
  const view = renderPanel(core, "ready", vi.fn());
  await flush();
  await flush();
  expect(screen.getByTestId("task-panel-changes-open")).toHaveTextContent("+15−1");

  view.rerender(
    core.wrap(
      <TaskDetailsPanel
        coding={{ workspaceId: "w1", taskId: "cnv_2" }}
        conversation={{ ...conversation, id: "cnv_2" }}
        groupId="grp_1"
        labeled={false}
        onOpenCodingChanges={vi.fn()}
        open
        run={run("ready")}
      />
    )
  );
  await flush();
  expect(core.sentTo("coding.changes")).toContainEqual({
    workspaceId: "w1",
    taskId: "cnv_2",
  });
  expect(screen.queryByTestId("task-panel-changes-open")).toBeNull();
  expect(screen.queryByTestId("task-panel-usage-line")).toBeNull();
  expect(screen.queryByText("add retries")).toBeNull();
});

it("makes one pull request at a time from all of the Task's surfaces, and stays in the app once it is made", async () => {
  let answer: ((made: unknown) => void) | undefined;
  const core = panelCore((name) => {
    if (name === "coding.changes") return changes("sandbox");
    if (name === "coding.history") return unavailableHistory;
    if (name === "coding.pullRequest")
      return new Promise((resolve) => {
        answer = resolve;
      });
    if (name === "status") return { ...madePullRequest(), title: "Retry" };
    return null;
  });
  const open = vi.spyOn(window, "open").mockImplementation(() => null);
  render(
    core.wrap(
      <>
        <TaskDetailsPanel
          coding={{ workspaceId: "w1", taskId: "cnv_1" }}
          conversation={conversation}
          groupId="grp_1"
          labeled={false}
          onOpenCodingChanges={vi.fn()}
          open
          run={run("ready")}
        />
        <CodingPullRequestPrompt
          branch="comma/abc"
          coding={{ workspaceId: "w1", taskId: "cnv_1" }}
          due
          working={false}
        />
      </>
    )
  );
  await flush();
  await flush();

  await user().click(
    within(screen.getByTestId("task-panel-changes")).getByRole("button", {
      name: "Create PR",
    })
  );
  await flush();
  // The prompt's chip waits for the request the panel made.
  const chip = screen.getByTestId("coding-pr-prompt-create");
  expect(chip).toHaveAttribute("aria-disabled", "true");
  await user().click(chip);
  await flush();
  expect(core.sentTo("coding.pullRequest")).toHaveLength(1);

  answer?.({ url: "https://github.com/acme/api/pull/7", number: 7, title: "Retry" });
  await flush();
  await flush();
  expect(screen.getByTestId("task-panel-changes-pr")).toHaveTextContent("Retry");
  expect(screen.queryByTestId("coding-pr-prompt")).toBeNull();
  // The card shows the pull request in place; nothing opens outside the app on its own.
  expect(open).not.toHaveBeenCalled();
  open.mockRestore();
});

it("offers a new pull request once one merged and the branch moved past it, and none while nothing came after", async () => {
  let merged = branchPullRequest("merged", "unknown", null, { newCommits: true });
  const core = panelCore((name) => {
    if (name === "coding.changes")
      return { ...changes("sandbox"), pullRequest: merged };
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  const first = renderPanel(core, "ready", vi.fn());
  await flush();
  await flush();
  const section = within(screen.getByTestId("task-panel-changes"));
  expect(section.getByTestId("task-panel-changes-pr")).toHaveAttribute(
    "data-state",
    "merged"
  );
  expect(section.getByRole("button", { name: "Create PR" })).toBeVisible();
  first.unmount();

  merged = branchPullRequest("merged", "unknown", null, { newCommits: false });
  renderPanel(core, "ready", vi.fn());
  await flush();
  await flush();
  expect(screen.queryByRole("button", { name: "Create PR" })).toBeNull();
});

it("edits the title and description, marks a draft ready for review, and merges an open one after asking", async () => {
  let current = branchPullRequest("draft", "mergeable", {
    passed: 2,
    failed: 1,
    total: 3,
  });
  const core = panelCore((name, params) => {
    if (name === "coding.changes")
      return { ...changes("sandbox"), pullRequest: current };
    if (name === "coding.history") return unavailableHistory;
    if (name === "coding.updatePullRequest") {
      const change = params as { title?: string; body?: string; ready?: boolean };
      current = {
        ...current,
        ...(change.title === undefined ? {} : { title: change.title }),
        ...(change.body === undefined ? {} : { body: change.body }),
        ...(change.ready ? { state: "open" } : {}),
      };
      return current;
    }
    if (name === "coding.mergePullRequest") {
      current = { ...current, state: "merged" };
      return { method: "squash", pullRequest: current };
    }
    return null;
  });
  renderPanel(core, "ready", vi.fn());
  await flush();
  await flush();
  const section = within(screen.getByTestId("task-panel-changes"));
  const menuOf = async () => {
    await user().click(section.getByRole("button", { name: "More for the changes" }));
    return within(await screen.findByRole("menu"));
  };

  // The title and description, edited in a dialog prefilled with what GitHub has.
  await user().click(
    (await menuOf()).getByRole("menuitem", { name: "Edit title and description…" })
  );
  const dialog = within(await screen.findByTestId("coding-pr-edit"));
  const title = dialog.getByRole("textbox", { name: "Title" });
  expect(title).toHaveValue("Back off between retries");
  expect(dialog.getByRole("textbox", { name: "Description" })).toHaveValue(
    "Make the retry helper back off."
  );
  await user().clear(title);
  await user().type(title, "Faster retries");
  await user().click(dialog.getByRole("button", { name: "Save" }));
  await flush();
  await flush();
  expect(core.sentTo("coding.updatePullRequest")).toEqual([
    {
      workspaceId: "w1",
      taskId: "cnv_1",
      title: "Faster retries",
      body: "Make the retry helper back off.",
    },
  ]);
  expect(screen.queryByTestId("coding-pr-edit")).toBeNull();
  expect(section.getByTestId("task-panel-changes-pr")).toHaveTextContent(
    "Faster retries"
  );

  // A draft is made ready for review before it can merge (once the edit dialog's exit has played).
  await advance(300);
  let menu = await menuOf();
  expect(menu.queryByRole("menuitem", { name: /Merge pull request/ })).toBeNull();
  await user().click(menu.getByRole("menuitem", { name: "Ready for review" }));
  await flush();
  await flush();
  expect(core.sentTo("coding.updatePullRequest").at(-1)).toEqual({
    workspaceId: "w1",
    taskId: "cnv_1",
    ready: true,
  });
  expect(section.getByTestId("task-panel-changes-pr")).toHaveAttribute(
    "data-state",
    "open"
  );

  // Merging asks first, and says how its checks stand.
  menu = await menuOf();
  await user().click(menu.getByRole("menuitem", { name: /Merge pull request/ }));
  const ask = await screen.findByRole("dialog", { name: "Merge pull request #9?" });
  expect(ask).toHaveTextContent("Faster retries · 1 of 3 checks failed");
  // The Worker pushes while the dialog is open: what merges is what was confirmed, at the head shown then.
  core.learn({ ...current, headSha: "8".repeat(40) });
  await flush();
  await user().click(within(ask).getByRole("button", { name: /^Merge/ }));
  await flush();
  await flush();
  expect(core.sentTo("coding.mergePullRequest")).toEqual([
    { workspaceId: "w1", taskId: "cnv_1", number: 9, headSha: "9".repeat(40) },
  ]);
  expect(section.getByTestId("task-panel-changes-pr")).toHaveAttribute(
    "data-state",
    "merged"
  );
});

it("does not offer to merge a pull request with conflicts", async () => {
  const core = panelCore((name) => {
    if (name === "coding.changes")
      return {
        ...changes("sandbox"),
        pullRequest: branchPullRequest("open", "conflicting"),
      };
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  renderPanel(core, "ready", vi.fn());
  await flush();
  await flush();
  await user().click(screen.getByRole("button", { name: "More for the changes" }));
  const menu = within(await screen.findByRole("menu"));
  expect(menu.getByRole("menuitem", { name: /Merge pull request/ })).toHaveAttribute(
    "aria-disabled",
    "true"
  );
});

it("keeps the pull request current while it is shown and the window is in front, and shows what the core read", async () => {
  let focused = true;
  const focus = vi.spyOn(document, "hasFocus").mockImplementation(() => focused);
  const core = panelCore((name) => {
    if (name === "coding.changes")
      return {
        ...changes("sandbox"),
        pullRequest: branchPullRequest("open", "mergeable", {
          passed: 1,
          failed: 0,
          total: 3,
        }),
      };
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  renderPanel(core, "ready", vi.fn());
  await flush();
  await flush();
  // Shown with its window in front: the core watches it.
  expect(core.watches).toEqual([true]);
  expect(screen.getByTestId("task-panel-changes-checks")).toHaveAttribute(
    "data-checks",
    "pending"
  );

  // What the watch read shows on the card.
  core.learn(
    branchPullRequest("open", "mergeable", { passed: 3, failed: 0, total: 3 })
  );
  await flush();
  expect(screen.getByTestId("task-panel-changes-checks")).toHaveAttribute(
    "data-checks",
    "passed"
  );

  // The window goes behind: the watch ends at once.
  focused = false;
  window.dispatchEvent(new Event("blur"));
  await flush();
  await flush();
  expect(core.watches).toEqual([true, false]);
  focus.mockRestore();
});

it("keeps the pull request chip through the Worker's turn, dimmed, saying to wait", async () => {
  const core = panelCore((name) => {
    if (name === "coding.changes") return changes("sandbox");
    if (name === "coding.history") return unavailableHistory;
    return null;
  });
  renderPanel(core, "ready", vi.fn(), undefined, true);
  await flush();
  await flush();

  const create = screen.getByRole("button", { name: "Create PR" });
  expect(create).toHaveAttribute("aria-disabled", "true");
  expect(await tooltipOf(create)).toBe(
    "The Worker is working. Wait for the turn to finish."
  );
  await user().click(create);
  await flush();
  expect(core.sentTo("coding.pullRequest")).toEqual([]);
  // The draft waits too.
  await user().click(screen.getByRole("button", { name: "More for the changes" }));
  const menu = within(await screen.findByRole("menu"));
  expect(menu.getByRole("menuitem", { name: "Create draft PR" })).toHaveAttribute(
    "aria-disabled",
    "true"
  );
});

it("shows the record as two sections: Execution with the token use, Activity with each request and its steps", async () => {
  const core = panelCore((name) => {
    if (name === "coding.changes") return changes("sandbox");
    if (name === "coding.history")
      return {
        available: true,
        start: 0,
        total: 5,
        usage: {
          modelCalls: 4,
          inputTokens: 12000,
          cachedTokens: 9000,
          outputTokens: 800,
          model: "gpt-5.6-sol",
        },
        items: [
          { kind: "received", id: "h0", text: "fix the flaky test", at: null },
          {
            kind: "group",
            id: "h1",
            failures: 1,
            pending: 0,
            steps: [
              {
                kind: "tool",
                id: "h1",
                tool: "Bash",
                hint: "npm test",
                body: { kind: "command", command: "npm test" },
                result: "1 failing",
                pending: false,
                failed: true,
                durationMs: 2500,
              },
              {
                kind: "tool",
                id: "h2",
                tool: "Edit",
                hint: "src/retry.ts",
                body: { kind: "edit", path: "src/retry.ts", diff: "-a\n+b" },
                result: null,
                pending: false,
                failed: false,
                durationMs: 300,
              },
            ],
          },
          { kind: "text", id: "h3", text: "Fixed it.", at: null },
        ],
      };
    return null;
  });
  renderPanel(core, "ready");
  await flush();
  await flush();

  // The sections in the panel's order: Execution, then the Changes line, then Activity.
  expect(
    screen.getAllByRole("heading", { level: 2 }).map((heading) => heading.textContent)
  ).toEqual(["Properties", "Environment", "Execution", "Changes", "Activity"]);
  const execution = within(screen.getByTestId("task-panel-execution"));
  expect(execution.getByTestId("task-panel-usage-line")).toHaveTextContent(
    "13K tokens · 4 model calls"
  );
  expect(execution.getByText("Cached").closest("li")).toHaveTextContent("9K70%");
  expect(execution.queryByText("fix the flaky test")).toBeNull();

  const activity = within(screen.getByTestId("task-panel-activity"));
  expect(activity.getAllByTestId("task-panel-history-request")).toHaveLength(1);
  expect(activity.getByText("fix the flaky test")).toBeVisible();
  // The agent's words are in the Task chat, not here.
  expect(activity.queryByText("Fixed it.")).toBeNull();
  const steps = activity.getAllByTestId("task-panel-history-step");
  expect(steps).toHaveLength(2);
  expect(steps[0]).toHaveTextContent("Bash");
  expect(steps[0]).toHaveTextContent("npm test");
  expect(steps[0]).toHaveTextContent("failed");
  expect(steps[1]).toHaveTextContent("0.3s");
  // A step opens what it did and what came out.
  const bash = within(steps[0]!).getByRole("button");
  expect(bash).toHaveAttribute("aria-expanded", "false");
  await user().click(bash);
  expect(bash).toHaveAttribute("aria-expanded", "true");
  expect(within(steps[0]!).getByText("Output")).toBeVisible();
});

it("opens the terminal inside the app where the panel says it can, else in the browser outside", async () => {
  const core = panelCore((name) => {
    if (name === "coding.changes") return changes("sandbox");
    if (name === "coding.history") return unavailableHistory;
    if (name === "coding.terminal")
      return { url: "https://l4es.example/t/comma:g1/sbx" };
    return null;
  });
  const onOpenCodingTerminal = vi.fn();
  renderPanel(core, "ready", vi.fn(), onOpenCodingTerminal);
  await flush();
  await flush();

  await user().click(screen.getByRole("button", { name: "Open terminal" }));
  await flush();
  expect(core.sentTo("coding.terminal")).toEqual([
    { workspaceId: "w1", taskId: "cnv_1" },
  ]);
  expect(onOpenCodingTerminal).toHaveBeenCalledWith(
    "https://l4es.example/t/comma:g1/sbx"
  );
});
