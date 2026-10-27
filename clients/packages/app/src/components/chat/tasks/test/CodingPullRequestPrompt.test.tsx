import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { beforeEach, expect, it, vi } from "vitest";
import { CodingPullRequestPrompt } from "../CodingPullRequestPrompt";
import { forgetCodingRecords } from "../CodingSession";
import { pullRequestScript } from "./pullRequestScript";

const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

beforeEach(() => {
  setInteractionModality("pointer");
  forgetCodingRecords();
});

const coding = { workspaceId: "w1", taskId: "cnv_1" };

const changes = (pullRequest: Record<string, unknown> | null) => ({
  source: "sandbox",
  base: "main",
  branch: "comma/abc",
  truncated: false,
  files: [
    {
      path: "src/retry.ts",
      status: "modified",
      additions: 3,
      deletions: 1,
      patch: null,
    },
  ],
  pullRequest,
});

const pullRequest = (state: string, more: Record<string, unknown> = {}) => ({
  url: "https://github.com/acme/api/pull/9",
  number: 9,
  title: "Fix it",
  body: null,
  headSha: null,
  state,
  mergeable: "unknown",
  checks: null,
  newCommits: false,
  ...more,
});

/**
 * A core whose branch has `branchPr`, which keeps the Task's pull request as the core would from what it answers
 * (`learn` says what it learned on another surface), and whose closed prompts are `closed` (the account's marks).
 */
function promptCore(
  branchPr: Record<string, unknown> | null,
  closed: Record<string, number> = {}
) {
  const script = pullRequestScript((name) =>
    name === "coding.changes"
      ? changes(branchPr)
      : name === "coding.pullRequest"
        ? { url: "https://github.com/acme/api/pull/7", number: 7, title: "Fix it" }
        : name === "status"
          ? pullRequest("draft", {
              url: "https://github.com/acme/api/pull/7",
              number: 7,
            })
          : null
  );
  const core = script.attach(
    createScriptedCore({
      calls: script.calls,
      values: (topic) =>
        script.values(topic) ??
        (topic.topic === "marks" ? { marks: closed } : undefined),
    })
  );
  return Object.assign(core, { learn: script.learn });
}

function prompt(
  core: ReturnType<typeof promptCore>,
  { due = true, working = false }: { due?: boolean; working?: boolean } = {}
) {
  return core.wrap(
    <CodingPullRequestPrompt
      branch="comma/abc"
      coding={coding}
      due={due}
      working={working}
    />
  );
}

it("offers the pull request once the moment comes, a draft once the menu switches it, and goes once it is made", async () => {
  const core = promptCore(null);
  const view = render(prompt(core, { due: false }));
  await flush();
  // Not due: nothing is read, nothing shows.
  expect(core.sentTo("coding.changes")).toEqual([]);
  expect(screen.queryByTestId("coding-pr-prompt")).toBeNull();

  view.rerender(prompt(core));
  await flush();
  await flush();
  expect(core.sentTo("coding.changes")).toEqual([coding]);
  expect(screen.getByTestId("coding-pr-prompt")).toHaveTextContent(
    "Changes are pushed to comma/abc. Open a pull request?"
  );

  // The chip makes a pull request; its menu switches it to a draft, which the chip then says.
  const create = screen.getByTestId("coding-pr-prompt-create");
  expect(create).toHaveTextContent("Create PR");
  await user().click(screen.getByTestId("coding-pr-prompt-menu"));
  const menu = within(await screen.findByRole("menu"));
  expect(menu.getByRole("menuitemradio", { name: "Create PR" })).toHaveAttribute(
    "aria-checked",
    "true"
  );
  await user().click(menu.getByRole("menuitemradio", { name: "Create draft PR" }));
  expect(create).toHaveTextContent("Create draft PR");
  expect(core.sentTo("coding.pullRequest")).toEqual([]);

  await user().click(create);
  await flush();
  await flush();
  expect(core.sentTo("coding.pullRequest")).toEqual([{ ...coding, draft: true }]);
  expect(screen.queryByTestId("coding-pr-prompt")).toBeNull();
});

it("waits through the Worker's turn: the chip stays, dimmed, and says so", async () => {
  const core = promptCore(null);
  const view = render(prompt(core, { working: true }));
  await flush();
  await flush();
  const create = screen.getByTestId("coding-pr-prompt-create");
  expect(create).toHaveAttribute("aria-disabled", "true");
  await user().hover(create);
  await advance(400);
  expect(await screen.findByRole("tooltip")).toHaveTextContent(
    "The Worker is working. Wait for the turn to finish."
  );
  await user().click(create);
  await flush();
  expect(core.sentTo("coding.pullRequest")).toEqual([]);

  // The turn over, the changes are read again and the chip works.
  view.rerender(prompt(core));
  await flush();
  await flush();
  expect(core.sentTo("coding.changes")).toHaveLength(2);
  expect(create).not.toHaveAttribute("aria-disabled");
  await user().click(create);
  await flush();
  expect(core.sentTo("coding.pullRequest")).toEqual([{ ...coding, draft: false }]);
});

it("stays away while the branch has a pull request open, and asks again once a merged one is left behind", async () => {
  const open = promptCore(pullRequest("open"));
  const first = render(prompt(open));
  await flush();
  await flush();
  expect(screen.queryByTestId("coding-pr-prompt")).toBeNull();
  first.unmount();

  const mergedBehind = promptCore(pullRequest("merged", { newCommits: true }));
  const second = render(prompt(mergedBehind));
  await flush();
  await flush();
  expect(screen.getByTestId("coding-pr-prompt")).toBeVisible();
  second.unmount();

  const mergedUpToDate = promptCore(pullRequest("merged", { newCommits: false }));
  render(prompt(mergedUpToDate));
  await flush();
  await flush();
  expect(screen.queryByTestId("coding-pr-prompt")).toBeNull();
});

it("keeps a closed prompt closed for the account, on this device and after the app opens again", async () => {
  const core = promptCore(null);
  const first = render(prompt(core));
  await flush();
  await flush();
  await user().click(screen.getByRole("button", { name: "Dismiss" }));
  expect(core.sentTo("marks.mark")).toEqual([
    { kind: "codingPullRequestPromptDismissed", ids: ["cnv_1"] },
  ]);
  first.unmount();

  // The mark kept: a prompt that would show stays closed, and reads nothing.
  const kept = promptCore(null, { cnv_1: 1 });
  render(prompt(kept));
  await flush();
  await flush();
  expect(screen.queryByTestId("coding-pr-prompt")).toBeNull();
  expect(kept.sentTo("coding.changes")).toEqual([]);
});

it("closes the prompt after a merged pull request apart from the one before it", async () => {
  // Closed before the first pull request; the merged one left work behind: the prompt asks again, under its own key.
  // The Task's panel read the changes and learned the merged pull request.
  const merged = pullRequest("merged", { newCommits: true });
  const core = promptCore(merged, { cnv_1: 1 });
  core.learn(merged);
  render(prompt(core));
  await flush();
  await flush();
  expect(screen.getByTestId("coding-pr-prompt")).toBeVisible();
  await user().click(screen.getByRole("button", { name: "Dismiss" }));
  expect(core.sentTo("marks.mark")).toEqual([
    { kind: "codingPullRequestPromptDismissed", ids: ["cnv_1@9"] },
  ]);
});
