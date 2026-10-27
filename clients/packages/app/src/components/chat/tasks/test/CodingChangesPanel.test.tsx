import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { beforeEach, expect, it, vi } from "vitest";
import { act } from "@comma/test-utils/render";
import { CodingChangesPanel } from "../CodingChangesPanel";
import {
  forgetCodingRecords,
  forgetCodingTaskFacts,
  publishCodingTaskFacts,
} from "../CodingSession";
import { pullRequestScript } from "./pullRequestScript";

const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

beforeEach(() => {
  setInteractionModality("pointer");
  forgetCodingRecords();
  forgetCodingTaskFacts();
});

const page = {
  id: "p1",
  workspaceId: "w1",
  taskId: "cnv_1",
  branch: "comma/abc",
  base: "main",
  repo: { owner: "acme", name: "api" },
  ready: true,
  revision: 0,
};

const SHA = "0123456789abcdef0123456789abcdef01234567";

const RETRY = {
  path: "src/retry.ts",
  status: "modified",
  additions: 3,
  deletions: 1,
  patch: "@@ -10,2 +10,2 @@\n a\n-b\n+c",
};
const README = {
  path: "README.md",
  status: "added",
  additions: 12,
  deletions: 0,
  patch: null,
};

// The branch has one commit (the retry change) and, in its sandbox, the README not committed yet.
function changesCore(source: "sandbox" | "github" = "sandbox") {
  return scriptedCore(changesCalls(source));
}

/** A core answering with `calls`, which keeps the Task's pull request as the core would from what they answer. */
function scriptedCore(calls: (name: string, params: unknown) => unknown) {
  const script = pullRequestScript(calls);
  return script.attach(
    createScriptedCore({ calls: script.calls, values: script.values })
  );
}

function changesCalls(source: "sandbox" | "github") {
  return (name: string, params: unknown) => {
    const scope = params as { commit?: string; uncommitted?: boolean };
    return name === "coding.changes"
      ? {
          source,
          base: "main",
          branch: "comma/abc",
          truncated: false,
          files: scope.commit
            ? [RETRY]
            : scope.uncommitted
              ? [README]
              : [RETRY, README],
          pullRequest: null,
          commits: [
            {
              sha: SHA,
              title: "Back off on retry",
              author: "Ann",
              at: "2026-10-23T10:00:00Z",
            },
          ],
          uncommitted: source === "sandbox",
        }
      : name === "coding.pullRequest"
        ? { url: "https://github.com/acme/api/pull/7", number: 7, title: null }
        : name === "status"
          ? {
              url: "https://github.com/acme/api/pull/7",
              number: 7,
              title: "Retry",
              body: null,
              headSha: null,
              state: "draft",
              mergeable: "mergeable",
              checks: null,
              newCommits: false,
            }
          : null;
  };
}

it("names the base and branch, lists every file, and shows each diff whole with its line numbers; a file folds from its header", async () => {
  const core = changesCore();
  render(core.wrap(<CodingChangesPanel active page={page} />));
  await flush();
  await flush();

  expect(core.sentTo("coding.changes")).toEqual([
    { workspaceId: "w1", taskId: "cnv_1" },
  ]);
  const panel = within(screen.getByTestId("coding-changes-panel"));
  expect(panel.getByText("main")).toBeVisible();
  expect(panel.getByText("comma/abc")).toBeVisible();
  expect(panel.getByText("2 files")).toBeVisible();
  expect(panel.getAllByTestId("coding-changes-panel-index-row")).toHaveLength(2);
  const files = panel.getAllByTestId("coding-changes-panel-file");
  expect(files).toHaveLength(2);
  // The hunk starts both files at line 10: the context keeps 10, the removed line is the old 11, the added the new 11.
  const lines = within(files[0]!).getAllByText(/^(10|11)$/);
  expect(lines.map((line) => line.textContent)).toEqual(["10", "11", "11"]);
  expect(files[0]).toHaveTextContent("-b");
  expect(files[0]).toHaveTextContent("+c");
  expect(files[1]).toHaveTextContent("Some changes are too large to show here.");

  const fold = within(files[0]!).getByRole("button", { name: "Show or hide retry.ts" });
  expect(fold).toHaveAttribute("aria-expanded", "true");
  await user().click(fold);
  expect(fold).toHaveAttribute("aria-expanded", "false");
  expect(within(files[0]!).queryByText("-b")).toBeNull();
});

it("brings the file it opened at into view once, and opens again on the changes it read while it reads them again", async () => {
  const scrolls = vi.spyOn(Element.prototype, "scrollIntoView");
  const opened = { ...page, file: "README.md" };
  const view = render(changesCore().wrap(<CodingChangesPanel active page={opened} />));
  await flush();
  await flush();
  expect(scrolls.mock.contexts).toEqual([
    screen.getAllByTestId("coding-changes-panel-file")[1],
  ]);
  // The window comes back to the front: the changes are read again, and the reader stays where they are.
  window.dispatchEvent(new Event("focus"));
  await flush();
  await flush();
  expect(scrolls).toHaveBeenCalledTimes(1);
  view.unmount();

  const again = scriptedCore((name) =>
    name === "coding.changes" ? new Promise(() => undefined) : null
  );
  render(again.wrap(<CodingChangesPanel active page={{ ...opened, revision: 1 }} />));
  await flush();
  expect(again.sentTo("coding.changes")).toHaveLength(1);
  expect(screen.getByText("2 files")).toBeVisible();
  expect(screen.getAllByTestId("coding-changes-panel-file")).toHaveLength(2);
  expect(scrolls).toHaveBeenCalledTimes(2);
  scrolls.mockRestore();
});

it("makes the pull request from the bar, and a draft one from the menu, which also holds the view's own switches", async () => {
  const core = changesCore();
  render(core.wrap(<CodingChangesPanel active page={page} />));
  await flush();
  await flush();
  const panel = within(screen.getByTestId("coding-changes-panel"));

  await user().click(panel.getByTestId("coding-changes-panel-menu"));
  const menu = within(await screen.findByRole("menu"));
  expect(menu.getByRole("menuitem", { name: "Open on GitHub" })).toBeVisible();
  expect(menu.getByRole("menuitem", { name: "Copy link" })).toBeVisible();
  expect(menu.getByRole("menuitem", { name: "Word wrap" })).toBeVisible();
  expect(menu.getByRole("menuitem", { name: "Refresh" })).toBeVisible();
  await user().keyboard("{Escape}");
  // Hiding the files and commits leaves the diffs.
  const rail = panel.getByRole("button", { name: "Show files and commits" });
  expect(rail).toHaveAttribute("aria-pressed", "true");
  await user().click(rail);
  expect(rail).toHaveAttribute("aria-pressed", "false");
  expect(panel.queryAllByTestId("coding-changes-panel-index-row")).toHaveLength(0);
  expect(panel.queryAllByTestId("coding-changes-panel-commit")).toHaveLength(0);
  expect(panel.getAllByTestId("coding-changes-panel-file")).toHaveLength(2);

  await user().click(panel.getByTestId("coding-changes-panel-menu"));
  await user().click(
    within(await screen.findByRole("menu")).getByRole("menuitem", {
      name: "Create draft PR",
    })
  );
  await flush();
  expect(core.sentTo("coding.pullRequest")).toEqual([
    { workspaceId: "w1", taskId: "cnv_1", draft: true },
  ]);
  const link = panel.getByTestId("task-panel-changes-pr");
  expect(link).toHaveTextContent("PR #7");
  expect(link).toHaveAttribute("data-state", "draft");
  expect(panel.queryByRole("button", { name: "Create PR" })).toBeNull();
});

it("lists the branch's commits beside the files; a commit, or what is not committed, shows its changes alone", async () => {
  const core = changesCore();
  render(core.wrap(<CodingChangesPanel active page={page} />));
  await flush();
  await flush();
  const panel = within(screen.getByTestId("coding-changes-panel"));
  const rail = within(panel.getByRole("complementary", { name: "Files and commits" }));
  const rows = rail.getAllByTestId("coding-changes-panel-commit");
  expect(rows.map((row) => row.textContent)).toEqual([
    "All changes",
    "Uncommitted changes",
    expect.stringMatching(/^Back off on retry0123456 · Ann · /),
  ]);
  expect(rows[0]).toHaveAttribute("aria-current", "true");

  await user().click(rows[2]!);
  await flush();
  await flush();
  expect(core.sentTo("coding.changes").at(-1)).toEqual({
    workspaceId: "w1",
    taskId: "cnv_1",
    commit: SHA,
  });
  expect(rail.getAllByTestId("coding-changes-panel-commit")[2]).toHaveAttribute(
    "aria-current",
    "true"
  );
  expect(panel.getAllByTestId("coding-changes-panel-file")).toHaveLength(1);
  expect(panel.getByText("1 files")).toBeVisible();

  await user().click(rail.getAllByTestId("coding-changes-panel-commit")[1]!);
  await advance(50);
  expect(core.sentTo("coding.changes").at(-1)).toEqual({
    workspaceId: "w1",
    taskId: "cnv_1",
    uncommitted: true,
  });
  expect(rail.getAllByTestId("coding-changes-panel-index-row")).toHaveLength(1);
  expect(rail.getByTestId("coding-changes-panel-index-row")).toHaveTextContent(
    "README.md"
  );

  // The commits fold under their heading.
  const fold = rail.getByRole("button", { name: "Show or hide the commits" });
  await user().click(fold);
  expect(fold).toHaveAttribute("aria-expanded", "false");
  expect(rail.queryAllByTestId("coding-changes-panel-commit")).toHaveLength(0);
});

it("goes back to all the changes when the commit shown is no longer the branch's", async () => {
  const answer = changesCalls("sandbox");
  let rebased = false;
  const core = scriptedCore((name, params) => {
    // The commit was amended away: the server no longer finds it on the branch.
    if (rebased && name === "coding.changes" && (params as { commit?: string }).commit)
      throw Object.assign(new Error("not_found"), { code: "not_found" });
    return answer(name, params);
  });
  render(core.wrap(<CodingChangesPanel active page={page} />));
  await flush();
  await flush();
  const panel = within(screen.getByTestId("coding-changes-panel"));
  const rail = within(panel.getByRole("complementary", { name: "Files and commits" }));
  await user().click(rail.getAllByTestId("coding-changes-panel-commit")[2]!);
  await flush();
  await flush();
  expect(panel.getAllByTestId("coding-changes-panel-file")).toHaveLength(1);

  rebased = true;
  await user().click(panel.getByRole("button", { name: "More for the changes" }));
  await user().click(
    within(await screen.findByRole("menu")).getByRole("menuitem", { name: "Refresh" })
  );
  await advance(50);
  expect(core.sentTo("coding.changes").at(-1)).toEqual({
    workspaceId: "w1",
    taskId: "cnv_1",
  });
  expect(rail.getAllByTestId("coding-changes-panel-commit")[0]).toHaveAttribute(
    "aria-current",
    "true"
  );
  expect(panel.getAllByTestId("coding-changes-panel-file")).toHaveLength(2);
  expect(panel.queryByText("The changes could not be read.")).toBeNull();
});

it("follows the Task as its conversation knows it: waits through the Worker's turn, then reads the changes again", async () => {
  act(() => publishCodingTaskFacts("cnv_1", { placeState: "ready", working: true }));
  const core = changesCore();
  render(core.wrap(<CodingChangesPanel active page={page} />));
  await flush();
  await flush();
  expect(core.sentTo("coding.changes")).toHaveLength(1);
  const panel = within(screen.getByTestId("coding-changes-panel"));
  // The tab was opened while the sandbox ran; the Worker's turn is what holds the pull request now.
  const create = panel.getByRole("button", { name: "Create PR" });
  expect(create).toHaveAttribute("aria-disabled", "true");

  act(() => publishCodingTaskFacts("cnv_1", { placeState: "ready", working: false }));
  await flush();
  await flush();
  expect(core.sentTo("coding.changes")).toHaveLength(2);
  expect(create).not.toHaveAttribute("aria-disabled");

  // The sandbox stopped since: Comma opens the branch it pushed on GitHub, so the chip still works.
  act(() => publishCodingTaskFacts("cnv_1", { placeState: "stopped", working: false }));
  expect(create).not.toHaveAttribute("aria-disabled");
});

it("keeps what it has while hidden, and reads again when shown", async () => {
  const core = changesCore();
  const view = render(core.wrap(<CodingChangesPanel active={false} page={page} />));
  await flush();
  expect(core.sentTo("coding.changes")).toHaveLength(0);
  view.rerender(core.wrap(<CodingChangesPanel active page={page} />));
  await flush();
  await flush();
  expect(core.sentTo("coding.changes")).toHaveLength(1);
});

it("shows the changes GitHub has once the sandbox is gone, says where they come from, and still offers the pull request", async () => {
  act(() => publishCodingTaskFacts("cnv_1", { placeState: "stopped", working: false }));
  const core = changesCore("github");
  render(core.wrap(<CodingChangesPanel active page={page} />));
  await flush();
  await flush();
  const panel = within(screen.getByTestId("coding-changes-panel"));
  expect(panel.getByText("Pushed to GitHub")).toBeVisible();
  expect(panel.getAllByTestId("coding-changes-panel-file")).toHaveLength(2);
  expect(panel.getByRole("button", { name: "Create PR" })).not.toHaveAttribute(
    "aria-disabled"
  );
});
