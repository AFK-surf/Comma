import { taskLoopRuleKey } from "@comma/core/task-loop-filter";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { render as renderBase, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { labelCatalog, labelsCore } from "../../../../test/labelsCore";
import type { CommaConversation } from "@comma/core/api-schemas";
import type { TaskLoop } from "@comma/core-client";
import type { ChatTaskActivity } from "@comma/chat-contract";
import { CommaI18nProvider } from "@comma/i18n/react";
import { TaskDetailsPanel } from "../TaskDetailsPanel";
import { TaskDetailsPopover } from "../TaskDetailsPopover";

const GROUP = "grp_panel";

/**
 * A cron zone whose offset is not the runner's, so Properties names it. No
 * other zone has Chatham's offset (+13:45 in January, the test clock's month).
 * A runner in Chatham gets Kathmandu (+5:45).
 */
const CRON_ZONE =
  new Intl.DateTimeFormat().resolvedOptions().timeZone === "Pacific/Chatham"
    ? { id: "Asia/Kathmandu", offset: "GMT+5:45", name: "Nepal" }
    : { id: "Pacific/Chatham", offset: "GMT+13:45", name: "Chatham" };

/** The catalog after label A was deleted: only B and C remain. */
const CATALOG = labelCatalog({
  labels: [
    { color: "blue", description: "", id: "lbl_b", name: "Backend" },
    { color: "purple", description: "", id: "lbl_c", name: "Design" },
  ],
});

let labels = labelsCore();

/** Renders over a core whose `taskLabels` topics show `labels`' catalog. */
const render: typeof renderBase = ((
  ui: Parameters<typeof renderBase>[0],
  options?: object
) => renderBase(ui, { wrapper: labels.wrapper, ...options })) as typeof renderBase;

/** The Group's catalog is `catalog`. */
function stubCatalog(catalog = CATALOG) {
  labels = labelsCore({ catalog });
}

/** A Task still carrying the deleted label A beside B. */
const conversation = {
  group_id: GROUP,
  id: "cnv_task",
  kind: "agent_task",
  labels: ["lbl_a", "lbl_b"],
  status: "running",
  title: "Labelled task",
} as unknown as CommaConversation;

function renderPanel(onSetLabels: (ids: string[]) => Promise<void>) {
  return render(
    <TaskDetailsPanel
      conversation={conversation}
      groupId={GROUP}
      onSetLabels={onSetLabels}
      open
    />
  );
}

describe("TaskDetailsPanel labels", () => {
  let user: ReturnType<typeof userEvent.setup>;
  beforeEach(() => {
    user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    setInteractionModality("pointer");
    // The Group's catalog has not been read.
    labels = labelsCore();
  });

  it("opens Tasks filtered by the clicked origin or client platform; an ended status is read-only", async () => {
    const onOpenTasksFilter = vi.fn();
    render(
      <TaskDetailsPanel
        conversation={{
          ...conversation,
          status: "completed",
          origin: "comma",
          client_platform: "macos",
        }}
        groupId={GROUP}
        onOpenTasksFilter={onOpenTasksFilter}
        open
      />
    );
    expect(screen.getByRole("button", { name: "Done" })).toBeDisabled();
    await user.click(screen.getByRole("button", { name: "Comma" }));
    expect(onOpenTasksFilter).toHaveBeenLastCalledWith({ platform: "comma" });
    await user.click(screen.getByRole("button", { name: "Created on macOS" }));
    expect(onOpenTasksFilter).toHaveBeenLastCalledWith({ clientPlatform: "macos" });
  });

  it("names where the Task runs and its model under Environment, never the Agent that runs it", () => {
    const { rerender } = render(
      <TaskDetailsPanel
        conversation={conversation}
        groupId={GROUP}
        open
        run={{
          place: { kind: "station", deviceId: "dev_studio", name: "Mac Studio" },
          model: { kind: "catalog", name: "Claude Sonnet" },
        }}
      />
    );
    expect(screen.getByTestId("task-panel-run-place")).toHaveTextContent("Mac Studio");
    expect(screen.getByTestId("task-panel-run-model")).toHaveTextContent(
      "Claude Sonnet"
    );
    // The place and model are the Task's Environment, apart from its Properties.
    const environment = screen.getByTestId("task-panel-environment");
    expect(
      within(environment).getByRole("heading", { name: "Environment" })
    ).toBeVisible();
    expect(environment).toContainElement(screen.getByTestId("task-panel-run-place"));
    expect(environment).toContainElement(screen.getByTestId("task-panel-run-model"));
    expect(
      within(screen.getByTestId("task-panel-properties")).queryByTestId(
        "task-panel-run-place"
      )
    ).toBeNull();
    rerender(
      <CommaI18nProvider locale="zh-CN">
        <TaskDetailsPanel
          conversation={conversation}
          groupId={GROUP}
          open
          run={{ place: { kind: "cloud_vm" }, model: { kind: "platform" } }}
        />
      </CommaI18nProvider>
    );
    expect(screen.getByRole("heading", { name: "运行环境" })).toBeVisible();
    expect(screen.getByTestId("task-panel-run-place")).toHaveTextContent("云电脑");
    expect(screen.getByTestId("task-panel-run-model")).toHaveTextContent("官方模型");
    // A station runs its runtime's default model when the Task names none.
    rerender(
      <CommaI18nProvider locale="en">
        <TaskDetailsPanel
          conversation={conversation}
          groupId={GROUP}
          open
          run={{
            place: { kind: "station", deviceId: "dev_unnamed" },
            model: { kind: "runtime", provider: "codex" },
          }}
        />
      </CommaI18nProvider>
    );
    expect(screen.getByTestId("task-panel-run-place")).toHaveTextContent("Computer");
    expect(screen.getByTestId("task-panel-run-model")).toHaveTextContent(
      "Codex default model"
    );
    // A server before it sends no place: the panel shows no Environment.
    rerender(<TaskDetailsPanel conversation={conversation} groupId={GROUP} open />);
    expect(screen.queryByTestId("task-panel-environment")).toBeNull();
    expect(screen.queryByTestId("task-panel-run-place")).toBeNull();
    expect(screen.queryByTestId("task-panel-run-model")).toBeNull();
  });

  it("opens the model picker from the Task's model, where the viewer may switch it", async () => {
    const onSwitchRun = vi.fn();
    const { rerender } = render(
      <TaskDetailsPanel
        conversation={conversation}
        groupId={GROUP}
        open
        onSwitchRun={onSwitchRun}
        run={{
          place: { kind: "station", deviceId: "dev_studio", name: "Mac Studio" },
          model: { kind: "runtime", provider: "codex" },
        }}
      />
    );
    await userEvent.click(
      screen.getByRole("button", { name: "Codex default model · Switch model" })
    );
    expect(onSwitchRun).toHaveBeenCalledOnce();
    // A run that names no model still offers one.
    rerender(
      <TaskDetailsPanel
        conversation={conversation}
        groupId={GROUP}
        open
        onSwitchRun={onSwitchRun}
        run={{ place: { kind: "station", deviceId: "dev_studio" } }}
      />
    );
    await userEvent.click(screen.getByRole("button", { name: "Switch model" }));
    expect(onSwitchRun).toHaveBeenCalledTimes(2);
    // A viewer who cannot switch it sees the model alone.
    rerender(
      <TaskDetailsPanel
        conversation={conversation}
        groupId={GROUP}
        open
        run={{
          place: { kind: "station", deviceId: "dev_studio" },
          model: { kind: "runtime", provider: "codex" },
        }}
      />
    );
    expect(screen.queryByTestId("task-panel-run-switch")).toBeNull();
  });

  it("ends an in-progress Task by hand from the status menu", async () => {
    const onSetStatus = vi.fn();
    render(
      <TaskDetailsPanel
        conversation={{ ...conversation, status: "active" }}
        groupId={GROUP}
        onOpenTasksFilter={vi.fn()}
        onSetStatus={onSetStatus}
        open
      />
    );
    await user.click(screen.getByRole("button", { name: "In progress" }));
    expect(screen.getAllByRole("menuitem").map((item) => item.textContent)).toEqual([
      "In progress",
      "Done",
      "Cancelled",
    ]);
    // The current status is a no-op.
    await user.click(screen.getByRole("menuitem", { name: "In progress" }));
    expect(onSetStatus).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "In progress" }));
    await user.click(screen.getByRole("menuitem", { name: "Cancelled" }));
    expect(onSetStatus).toHaveBeenCalledExactlyOnceWith("cancelled");
  });

  it("offers Done and Cancelled for a Task in review", async () => {
    const onSetStatus = vi.fn();
    render(
      <TaskDetailsPanel
        conversation={{ ...conversation, status: "ready_for_review" }}
        groupId={GROUP}
        onSetStatus={onSetStatus}
        open
      />
    );
    await user.click(screen.getByRole("button", { name: "Needs Review" }));
    expect(screen.getAllByRole("menuitem").map((item) => item.textContent)).toEqual([
      "Needs Review",
      "Done",
      "Cancelled",
    ]);
    await user.click(screen.getByRole("menuitem", { name: "Done" }));
    expect(onSetStatus).toHaveBeenCalledExactlyOnceWith("completed");
  });

  it("disables status changes while one is pending and reports a failure", async () => {
    const onSetStatus = vi.fn();
    const { rerender } = render(
      <TaskDetailsPanel
        conversation={{ ...conversation, status: "active" }}
        groupId={GROUP}
        onSetStatus={onSetStatus}
        open
        statusState="pending"
      />
    );
    await user.click(screen.getByRole("button", { name: "In progress" }));
    expect(screen.getByRole("menuitem", { name: "Done" })).toHaveAttribute(
      "aria-disabled",
      "true"
    );
    await user.keyboard("{Escape}");
    rerender(
      <TaskDetailsPanel
        conversation={{ ...conversation, status: "active" }}
        groupId={GROUP}
        onSetStatus={onSetStatus}
        open
        statusState="failed"
      />
    );
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Couldn’t change the status. The Task may have changed; check it and try again."
    );
  });

  it("keeps the status read-only without a status action", () => {
    render(
      <TaskDetailsPanel
        conversation={{ ...conversation, status: "active" }}
        groupId={GROUP}
        onOpenTasksFilter={vi.fn()}
        open
      />
    );
    expect(screen.getByRole("button", { name: "In progress" })).toBeDisabled();
  });

  it("refreshes a visible Task's catalog when server-assigned label IDs change", async () => {
    let read = CATALOG.labels;
    // A refresh reads the catalog the server has now.
    labels = labelsCore({
      catalog: CATALOG,
      answer: (name) =>
        name === "taskLabels.refresh" ? { ...CATALOG, labels: read } : undefined,
    });
    const panel = (ids: string[]) => (
      <TaskDetailsPanel
        conversation={{ ...conversation, labels: ids }}
        groupId={GROUP}
        open
      />
    );
    const { rerender } = render(panel(["lbl_b"]));
    await flush();
    expect(screen.getByText("Backend")).toBeVisible();
    expect(labels.subscribed).toHaveLength(1);
    expect(labels.sentTo("taskLabels.refresh")).toEqual([]);
    read = [
      ...read,
      { id: "lbl_new", name: "Release", color: "orange", description: "Release work" },
    ];
    rerender(panel(["lbl_b", "lbl_new"]));
    await flush();
    expect(screen.getByText("Release")).toBeVisible();
    expect(labels.sentTo("taskLabels.refresh")).toEqual([{ group: GROUP }]);
    rerender(panel(["lbl_b", "lbl_new"]));
    await flush();
    expect(labels.subscribed).toHaveLength(1);
    expect(labels.sentTo("taskLabels.refresh")).toHaveLength(1);
  });

  it("shows a new-label request for this Task even before its labels are created", async () => {
    stubCatalog({
      ...CATALOG,
      proposals: [
        {
          id: "prp_new",
          op: "create",
          status: "pending",
          created_at: 1,
          payload: {
            conversation_id: conversation.id,
            labels: [{ name: "Release", color: "orange", description: "Release work" }],
          },
        },
      ],
    });
    renderPanel(vi.fn(async () => undefined));
    await flush();
    expect(
      screen.getByText(
        "A label request needs your attention in the original chat or Settings."
      )
    ).toBeVisible();
  });

  it("keeps folded properties open while adding a label", async () => {
    stubCatalog();
    const setLabels = vi.fn(async () => undefined);
    render(
      <TaskDetailsPopover
        conversation={conversation}
        groupId={GROUP}
        onSetLabels={setLabels}
      />
    );
    await user.click(screen.getByTestId("task-panel-toggle"));
    await flush();
    await user.click(screen.getByRole("button", { name: "Add label" }));
    await flush();
    const search = screen.getByPlaceholderText("Change or add labels…");
    expect(search).toHaveFocus();
    await user.type(search, "des");
    await user.click(screen.getByRole("menuitemcheckbox", { name: "Design" }));
    await flush();
    expect(setLabels).toHaveBeenCalledWith(["lbl_b", "lbl_c"]);
    expect(screen.getByTestId("task-panel-popover")).toBeVisible();
    await user.keyboard("{Escape}");
    await flush();
    expect(screen.queryByTestId("task-label-picker")).toBeNull();
    expect(screen.getByTestId("task-panel-popover")).toBeVisible();
    // Focus returns to the trigger on the next frame.
    await advance(16);
    expect(screen.getByRole("button", { name: "Add label" })).toHaveFocus();
    await user.keyboard("{Escape}");
    await flush();
    expect(screen.queryByTestId("task-panel-popover")).toBeNull();
  });

  it("adds a label without carrying a deleted label's id into the write", async () => {
    stubCatalog();
    const setLabels = vi.fn(async () => undefined);
    renderPanel(setLabels);
    await flush();

    expect(screen.getByText("Backend")).toBeInTheDocument();
    expect(screen.queryByText("lbl_a")).toBeNull();

    await user.click(screen.getByRole("button", { name: "Add label" }));
    await flush();
    await user.click(screen.getByRole("menuitemcheckbox", { name: "Design" }));
    await flush();

    expect(setLabels).toHaveBeenCalledWith(["lbl_b", "lbl_c"]);
  });

  it("shows only the configured trigger and opens its exact rule from Properties", async () => {
    const onOpenTasksFilter = vi.fn();
    const loop: TaskLoop = {
      state: "active",
      cadence: {
        pattern: { kind: "weekly", days: [1, 3], hour: 18, minute: 30 },
        cron: "30 18 * * 1,3",
        timezone: CRON_ZONE.id,
      },
      maxRuns: 10,
      startedAt: atLocal(-7, 9, 0),
      wakeCount: 3,
      lastWakeAt: atLocal(-1, 18, 30),
      nextRunAt: atLocal(1, 18, 30),
      endsAt: atLocal(20, 9, 0),
      until: "the release ships",
    };
    render(
      <TaskDetailsPanel
        conversation={conversation}
        groupId={GROUP}
        loop={loop}
        onOpenTasksFilter={onOpenTasksFilter}
        open
      />
    );
    const section = screen.getByTestId("task-panel-schedule");
    expect(
      screen.getByTestId("task-panel-labels").compareDocumentPosition(section) &
        Node.DOCUMENT_POSITION_FOLLOWING
    ).toBeTruthy();
    expect(within(section).getByRole("heading")).toHaveTextContent("Scheduled");
    // The cron's zone shows as its offset. The hover text names it.
    const trigger = within(section).getByRole("button", {
      name: `Every Mon, Wed at 6:30 PM · ${CRON_ZONE.offset}`,
    });
    expect(
      within(trigger).getByTitle(`Every Mon, Wed at 6:30 PM · ${CRON_ZONE.name}`, {
        exact: false,
      })
    ).toBeVisible();
    expect(within(section).getAllByRole("listitem")).toHaveLength(1);
    expect(within(section).getAllByRole("button")).toHaveLength(1);
    await user.click(trigger);
    expect(onOpenTasksFilter).toHaveBeenCalledWith({ loopRule: taskLoopRuleKey(loop) });
  });

  it("shows event conditions and the pause reason without interaction", async () => {
    const loop: TaskLoop = {
      state: "paused",
      reason: "budget",
      cadence: { events: "new comments on PR #12" },
      until: "PR #12 is merged",
      startedAt: atLocal(-3, 9, 0),
      wakeCount: 2,
      lastWakeAt: atLocal(0, 9, 12),
    };
    render(
      <TaskDetailsPanel conversation={conversation} groupId={GROUP} loop={loop} open />
    );
    const section = screen.getByTestId("task-panel-schedule");
    expect(within(section).getByRole("heading")).toHaveTextContent("On updates");
    expect(
      within(section)
        .getAllByRole("listitem")
        .map((row) => row.textContent)
    ).toEqual(["new comments on PR #12", "Paused · it woke too often"]);
  });

  it("keeps an ended Loop's trigger type and shows only Ended until a new Loop configuration arrives", async () => {
    const loop: TaskLoop = {
      state: "active",
      cadence: { pattern: { kind: "interval", minutes: 360 }, everyMinutes: 360 },
      endsAt: atLocal(20, 9, 0),
      until: "old request",
      startedAt: atLocal(-9, 9, 0),
      wakeCount: 5,
    };
    const { rerender } = render(
      <TaskDetailsPanel conversation={conversation} groupId={GROUP} loop={loop} open />
    );
    expect(screen.getByTestId("task-panel-schedule")).toHaveTextContent(
      "Every 6 hours"
    );
    const ended: TaskLoop = {
      ...loop,
      state: "ended",
      reason: "ends_at",
      endedAt: atLocal(0, 9, 0),
    };
    rerender(
      <TaskDetailsPanel
        conversation={{ ...conversation, status: "completed" }}
        groupId={GROUP}
        loop={ended}
        open
      />
    );
    expect(screen.getByTestId("task-panel-schedule")).toHaveTextContent(
      /^ScheduledEnded$/
    );

    // Reopening the Task alone leaves the old Loop ended.
    rerender(
      <TaskDetailsPanel conversation={conversation} groupId={GROUP} loop={ended} open />
    );
    expect(screen.getByTestId("task-panel-schedule")).toHaveTextContent(
      /^ScheduledEnded$/
    );

    // A new request has fresh settings and starts from zero runs.
    rerender(
      <TaskDetailsPanel
        conversation={conversation}
        groupId={GROUP}
        loop={{
          state: "pending",
          cadence: { pattern: { kind: "interval", minutes: 180 }, everyMinutes: 180 },
          maxRuns: 6,
          startedAt: atLocal(0, 9, 0),
          wakeCount: 0,
        }}
        open
      />
    );
    expect(screen.getByTestId("task-panel-schedule")).toHaveTextContent("Setting up");
    expect(screen.getByTestId("task-panel-schedule")).toHaveTextContent(
      "Every 3 hours"
    );
    expect(
      within(screen.getByTestId("task-panel-schedule"))
        .getAllByRole("listitem")
        .map((row) => row.textContent)
    ).toEqual(["Every 3 hours", "Setting up"]);

    rerender(<TaskDetailsPanel conversation={conversation} groupId={GROUP} open />);
    expect(screen.queryByTestId("task-panel-schedule")).toBeNull();
  });

  it("localizes the trigger and cadence, including a paused Loop's reason", async () => {
    const loop: TaskLoop = {
      state: "paused",
      endsAt: atLocal(1, 9, 0),
      reason: "waiting",
      cadence: {
        pattern: { kind: "hourly", minute: 5 },
        cron: "5 * * * *",
        timezone: CRON_ZONE.id,
      },
      startedAt: atLocal(0, 9, 0),
      wakeCount: 0,
    };
    const { rerender } = render(
      <TaskDetailsPanel conversation={conversation} groupId={GROUP} loop={loop} open />
    );
    // English writes the minute as a clock does, Chinese counts it.
    expect(loopRows()).toEqual([
      `Every hour at :05 · ${CRON_ZONE.offset}`,
      "Paused until you reply",
    ]);
    rerender(
      <CommaI18nProvider locale="zh-CN">
        <TaskDetailsPanel
          conversation={conversation}
          groupId={GROUP}
          loop={loop}
          open
        />
      </CommaI18nProvider>
    );
    const details = screen.getByTestId("task-panel-schedule");
    expect(within(details).getByRole("heading")).toHaveTextContent("定时触发");
    expect(loopRows()).toEqual([
      `每小时第 5 分 · ${CRON_ZONE.offset}`,
      "已暂停，等你回复后继续",
    ]);
  });

  it("keeps a stepped-hour cron's minute and omits a zone this runtime does not know", async () => {
    const steppedHours = (cron: string): TaskLoop => ({
      state: "active",
      cadence: {
        pattern: { kind: "interval", minutes: 120 },
        cron,
        timezone: "Mars/Olympus",
      },
      startedAt: atLocal(0, 9, 0),
      wakeCount: 0,
    });
    const { rerender } = render(
      <TaskDetailsPanel
        conversation={conversation}
        groupId={GROUP}
        loop={steppedHours("15 */2 * * *")}
        open
      />
    );
    expect(loopRows()).toEqual(["Every 2 hours at :15"]);
    rerender(
      <TaskDetailsPanel
        conversation={conversation}
        groupId={GROUP}
        loop={steppedHours("0 */2 * * *")}
        open
      />
    );
    expect(loopRows()).toEqual(["Every 2 hours"]);
    rerender(
      <CommaI18nProvider locale="zh-CN">
        <TaskDetailsPanel
          conversation={conversation}
          groupId={GROUP}
          loop={steppedHours("15 */2 * * *")}
          open
        />
      </CommaI18nProvider>
    );
    expect(loopRows()).toEqual(["每 2 小时第 15 分"]);
  });

  it("names a trigger this client cannot read and still shows that its Loop runs", async () => {
    render(
      <TaskDetailsPanel
        conversation={conversation}
        groupId={GROUP}
        loop={{ state: "active", startedAt: atLocal(0, 9, 0), wakeCount: 0 }}
        onOpenTasksFilter={vi.fn()}
        open
      />
    );
    const section = screen.getByTestId("task-panel-schedule");
    expect(within(section).getByRole("heading")).toHaveTextContent("Other trigger");
    expect(loopRows()).toEqual(["Running"]);
    // No rule to filter by, so nothing in the section is a button.
    expect(within(section).queryByRole("button")).toBeNull();
  });

  it("narrows the picker by search", async () => {
    stubCatalog();
    renderPanel(vi.fn(async () => undefined));
    await flush();

    await user.click(screen.getByRole("button", { name: "Add label" }));
    await flush();
    await user.type(screen.getByPlaceholderText("Change or add labels…"), "des");

    expect(screen.getByRole("menuitemcheckbox", { name: "Design" })).toBeVisible();
    expect(screen.queryByRole("menuitemcheckbox", { name: "Backend" })).toBeNull();
  });
});

/** The text of each row in the Loop section of Properties. */
function loopRows() {
  return within(screen.getByTestId("task-panel-schedule"))
    .getAllByRole("listitem")
    .map((row) => row.textContent);
}

/** `days` from the test clock's day, at a time of day on the reader's clock. */
describe("TaskDetailsPanel Activity", () => {
  const at = atLocal(0, 10, 3);
  const activity: ChatTaskActivity = {
    key: "activity",
    groups: [
      {
        request: { messageId: "msg_brief", kind: "brief", text: "", at },
        entries: [
          { title: "Wrote the agenda", at, messageId: "msg_4" },
          { title: "Wrote Alice's invite", at, messageId: "msg_4" },
        ],
      },
      {
        request: {
          messageId: "msg_5",
          kind: "follow_up",
          text: "Also write one for Dave.",
          at,
        },
        entries: [{ title: "Wrote Dave's invite", at }],
      },
    ],
  };

  beforeEach(() => {
    setInteractionModality("pointer");
    labels = labelsCore();
  });

  it("lists each request with the milestones after it; a request folds them, a milestone opens its message", async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    const onRevealActivityStep = vi.fn();
    render(
      <TaskDetailsPanel
        activity={activity}
        activityWorking
        conversation={conversation}
        groupId={GROUP}
        onRevealActivityStep={onRevealActivityStep}
        open
      />
    );
    const section = screen.getByTestId("task-panel-activity");
    expect(within(section).getByRole("heading")).toHaveTextContent("Activity");
    const groups = within(section).getAllByTestId("task-activity-group");
    expect(groups).toHaveLength(2);
    expect(
      within(groups[0]!)
        .getAllByTestId("task-activity-step")
        .map((step) => step.textContent)
    ).toEqual(["Wrote the agenda10:03 AM", "Wrote Alice's invite10:03 AM"]);
    // The working Task's last request ends with a live row.
    expect(groups[1]).toHaveTextContent(
      /Also write one for Dave\.10:03 AM.*Wrote Dave's invite10:03 AM.*Working…/
    );
    expect(groups[0]).not.toHaveTextContent("Working…");

    await user.click(
      within(groups[0]!).getByRole("button", { name: /Wrote Alice's invite/ })
    );
    expect(onRevealActivityStep).toHaveBeenLastCalledWith("msg_4");

    // A request hides its milestones and shows them again; it opens nothing.
    const created = within(groups[0]!).getByRole("button", {
      name: /Created the Task/,
    });
    expect(created).toHaveAttribute("aria-expanded", "true");
    await user.click(created);
    expect(created).toHaveAttribute("aria-expanded", "false");
    expect(within(groups[0]!).queryAllByTestId("task-activity-step")).toHaveLength(0);
    await user.click(created);
    expect(within(groups[0]!).getAllByTestId("task-activity-step")).toHaveLength(2);
    // The live row folds with the last request.
    await user.click(
      within(groups[1]!).getByRole("button", { name: /Also write one for Dave/ })
    );
    expect(section).not.toHaveTextContent("Working…");
    expect(onRevealActivityStep).toHaveBeenCalledTimes(1);
    // A milestone with no message to show is text.
    expect(
      within(groups[1]!).queryByRole("button", { name: /Wrote Dave's invite/ })
    ).toBeNull();
  });

  it("says while earlier activity is read, and reads what a stopped read left out when pressed", async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    const onReadEarlierActivity = vi.fn();
    const { rerender } = render(
      <TaskDetailsPanel
        activity={{ key: "reading", groups: [], earlier: "reading" }}
        conversation={conversation}
        groupId={GROUP}
        onReadEarlierActivity={onReadEarlierActivity}
        open
      />
    );
    expect(screen.getByTestId("task-activity-earlier")).toHaveTextContent(
      "Reading earlier activity…"
    );
    expect(screen.queryByRole("button", { name: /Read it/ })).toBeNull();

    rerender(
      <TaskDetailsPanel
        activity={{ ...activity, key: "unread", earlier: "unread" }}
        conversation={conversation}
        groupId={GROUP}
        onReadEarlierActivity={onReadEarlierActivity}
        open
      />
    );
    // It comes first: what it stands for is older than every group.
    const section = screen.getByTestId("task-panel-activity");
    expect(within(section).getAllByRole("listitem")[0]).toHaveAttribute(
      "data-testid",
      "task-activity-earlier"
    );
    await user.click(within(section).getByRole("button", { name: /Read it/ }));
    expect(onReadEarlierActivity).toHaveBeenCalledTimes(1);
  });

  it("shows the live row only while the Task is in progress and its Agent works", () => {
    // A Loop Task between runs stays in progress with no Agent at work.
    const { rerender } = render(
      <TaskDetailsPanel
        activity={activity}
        conversation={conversation}
        groupId={GROUP}
        open
      />
    );
    expect(screen.getByTestId("task-panel-activity")).not.toHaveTextContent("Working…");
    rerender(
      <TaskDetailsPanel
        activity={activity}
        activityWorking
        conversation={{ ...conversation, status: "completed" }}
        groupId={GROUP}
        open
      />
    );
    expect(screen.getByTestId("task-panel-activity")).not.toHaveTextContent("Working…");
  });

  it("names a day once, on the first row of that day", () => {
    const yesterday = atLocal(-1, 23, 50);
    render(
      <TaskDetailsPanel
        activity={{
          key: "days",
          groups: [
            {
              request: {
                messageId: "msg_brief",
                kind: "brief",
                text: "",
                at: yesterday,
              },
              entries: [
                { title: "Wrote the agenda", at: yesterday + 60_000 },
                { title: "Wrote Alice's invite", at },
              ],
            },
          ],
        }}
        conversation={conversation}
        groupId={GROUP}
        open
      />
    );
    const day = new Intl.DateTimeFormat("en", {
      hour: "2-digit",
      minute: "2-digit",
      month: "numeric",
      day: "numeric",
    });
    expect(
      [...screen.getByTestId("task-panel-activity").querySelectorAll("time")].map(
        (time) => time.textContent
      )
    ).toEqual([day.format(yesterday), "11:51 PM", day.format(at)]);
  });

  it("keeps a long log's start and latest rows, and a fold row shows the rest", async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    const steps = (prefix: string, count: number) =>
      Array.from({ length: count }, (_, index) => ({
        title: `${prefix} ${index + 1}`,
        at,
        messageId: `msg_${prefix}_${index + 1}`,
      }));
    const run = (
      hour: number,
      entries: ChatTaskActivity["groups"][number]["entries"]
    ) => ({
      request: {
        messageId: `msg_run_${hour}`,
        kind: "run" as const,
        text: "",
        at: atLocal(0, hour, 0),
      },
      entries,
    });
    const long: ChatTaskActivity = {
      key: "long",
      groups: [
        {
          request: { messageId: "msg_brief", kind: "brief", text: "", at },
          entries: steps("Set up", 1),
        },
        run(1, steps("Run 1", 2)),
        run(2, steps("Run 2", 3)),
        run(3, steps("Run 3", 1)),
        run(4, steps("Run 4", 1)),
        run(5, steps("Wrote invoice", 10)),
      ],
    };
    render(
      <TaskDetailsPanel
        activity={long}
        conversation={conversation}
        groupId={GROUP}
        onRevealActivityStep={vi.fn()}
        open
      />
    );
    const section = screen.getByTestId("task-panel-activity");
    const titles = () =>
      within(section)
        .getAllByRole("listitem")
        .filter((item) => item.dataset.testid !== "task-activity-group")
        .map((item) => item.textContent);

    // The oldest group and the latest two stay; one row stands for the three between.
    expect(within(section).getAllByTestId("task-activity-group")).toHaveLength(3);
    const moreGroups = within(section).getByTestId("task-activity-more-groups");
    expect(moreGroups).toHaveTextContent("3 earlier groups6 steps");
    expect(section).toHaveTextContent(/Loop run04:00 AM.*Loop run05:00 AM/);
    // A long group keeps how it began and its latest three milestones.
    expect(titles().slice(-6)).toEqual([
      "Wrote invoice 110:03 AM",
      "Wrote invoice 210:03 AM",
      "5 more steps",
      "Wrote invoice 810:03 AM",
      "Wrote invoice 910:03 AM",
      "Wrote invoice 1010:03 AM",
    ]);

    await user.click(within(moreGroups).getByRole("button"));
    expect(within(section).getAllByTestId("task-activity-group")).toHaveLength(6);
    expect(within(section).queryByTestId("task-activity-more-groups")).toBeNull();
    // The first row it showed takes the fold row's focus.
    expect(
      within(section).getByRole("button", { name: "Loop run01:00 AM" })
    ).toHaveFocus();

    await user.click(
      within(within(section).getByTestId("task-activity-more-steps")).getByRole(
        "button"
      )
    );
    expect(titles().slice(-10)).toEqual(
      steps("Wrote invoice", 10).map((step) => `${step.title}10:03 AM`)
    );
    expect(
      within(section).getByRole("button", { name: "Wrote invoice 310:03 AM" })
    ).toHaveFocus();
  });

  it("closes the folded popover before it shows a milestone", async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    const onRevealActivityStep = vi.fn();
    render(
      <TaskDetailsPopover
        activity={activity}
        conversation={conversation}
        groupId={GROUP}
        onRevealActivityStep={onRevealActivityStep}
      />
    );
    await user.click(screen.getByTestId("task-panel-toggle"));
    await flush();
    await user.click(screen.getByRole("button", { name: /Wrote the agenda/ }));
    await flush();
    expect(onRevealActivityStep).toHaveBeenCalledWith("msg_4");
    expect(screen.queryByTestId("task-panel-popover")).toBeNull();
  });

  it("shows no Activity while the Task has no milestone", () => {
    render(<TaskDetailsPanel conversation={conversation} groupId={GROUP} open />);
    expect(screen.queryByTestId("task-panel-activity")).toBeNull();
  });
});

function atLocal(days: number, hour: number, minute: number) {
  const at = new Date(Date.now());
  at.setDate(at.getDate() + days);
  return at.setHours(hour, minute, 0, 0);
}
