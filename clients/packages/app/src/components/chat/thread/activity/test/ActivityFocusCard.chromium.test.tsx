import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import type { SessionHistoryRecord, SessionHistoryValue } from "@comma/core-client";
import { render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, expect, it, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { ParticipantStatusSlot } from "../ActivityLine";
import type { ActivityFocus } from "../activityFocus";

vi.mock("../../../ChatProvider", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  useChatProductLease: () => "lease",
}));

afterEach(() => document.body.replaceChildren());

const epoch = 1_788_564_963_000;
let clock = 0;

/** A finished tool step: its call and its result. */
function step(id: string, name: string, args: Record<string, string>) {
  clock += 1000;
  const call = {
    id: `${id}:call`,
    kind: "assistant",
    content: { tool_calls: [{ id, name, args }] },
    timestamp_ms: epoch + clock,
  } satisfies SessionHistoryRecord;
  clock += 1000;
  const result = {
    id: `${id}:result`,
    kind: "tool",
    content: { type: "tool_call_completed", tool_call_id: id, status: "completed" },
    timestamp_ms: epoch + clock,
    execution: {
      id,
      lane: "tool",
      started_at_ms: epoch + clock - 900,
      observed_at_ms: epoch + clock,
      completed_at_ms: epoch + clock,
      duration_ms: 900,
    },
  } satisfies SessionHistoryRecord;
  return [call, result];
}

/** A command the owner says runs now: its call and its start. */
function runningCommand(id: string, description: string): SessionHistoryRecord[] {
  clock += 1000;
  return [
    {
      id: `${id}:call`,
      kind: "assistant",
      content: {
        tool_calls: [{ id, name: "env.exec", args: { command: "x", description } }],
      },
      timestamp_ms: epoch + clock,
    },
    {
      id: `${id}:started`,
      kind: "tool",
      content: { type: "tool_call_started", tool_call_id: id },
      timestamp_ms: epoch + clock,
      execution: {
        id,
        lane: "tool",
        started_at_ms: epoch + clock,
        observed_at_ms: epoch + clock,
        completed_at_ms: null,
        duration_ms: 0,
        live: true,
      },
    },
  ];
}

/** A model request the owner says runs now. */
function thinking(id = "thinking"): SessionHistoryRecord {
  clock += 1000;
  return {
    id,
    kind: "assistant",
    content: {},
    timestamp_ms: epoch + clock,
    execution: {
      id,
      lane: "model",
      started_at_ms: epoch + clock,
      observed_at_ms: epoch + clock,
      completed_at_ms: null,
      duration_ms: 0,
      live: true,
    },
  };
}

const workingFocus: ActivityFocus = {
  groupId: "group",
  mode: "working",
  tasks: [
    {
      conversationId: "task",
      statusBucket: "in_progress",
      title: "Make remote previews faster",
      worker: {
        avatarId: "worker",
        name: "Worker",
        participantId: "worker",
        active: true,
      },
    },
  ],
};

/** The `history` topic holding these records for the Task's Worker. */
function historyValue(records: SessionHistoryRecord[]): SessionHistoryValue {
  return {
    groupId: "group",
    conversationId: "task",
    participantId: "worker",
    records,
    recentRecords: [],
    liveRecords: [],
    clockOffsetMs: 0,
    streamStatus: "live",
    hasMore: false,
    nextBefore: null,
    status: "ready",
    loaded: "detail",
    error: null,
  };
}

/** A core whose `history` topic holds these records for the Task's Worker. */
function historyCore(records: SessionHistoryRecord[]) {
  const history = historyValue(records);
  return createScriptedCore({
    values: (topic) => (topic.topic === "history" ? history : undefined),
  });
}

it("opens a row's step log beside the card and keeps it open on the way in", async () => {
  const core = historyCore([
    ...step("read", "fs.read_file", { path: "/workspace/evalens.config.ts" }),
    ...step("exec", "env.exec", {
      command: "pnpm bench",
      description: "Run the preview benchmark",
    }),
    thinking(),
  ]);
  await page.viewport(1024, 720);
  render(
    core.wrap(
      <div style={{ padding: "360px 48px 48px", width: 420 }}>
        <ParticipantStatusSlot
          participantStatus={undefined}
          focus={workingFocus}
          taskLink={(task) => (
            <a href={`#/tasks/${task.conversationId}`}>{task.title}</a>
          )}
        />
      </div>
    )
  );

  await userEvent.hover(
    page.getByRole("link", { name: /Make remote previews faster/ })
  );
  const card = page.getByTestId("activity-focus-card");
  await expect.element(card).toBeVisible();
  const row = card.getByRole("link");
  // The row names the last finished step and sweeps it while the Worker works.
  await expect.element(row).toHaveTextContent("Run the preview benchmark");
  // The sweep covers only the words, not the whole line.
  const sweep = row
    .element()
    .querySelector<HTMLElement>(".comma-chat-activity-step-words > [data-shimmer]")!;
  expect(sweep.getAnimations({ subtree: true }).length).toBeGreaterThan(0);
  expect(sweep.getBoundingClientRect().width).toBeLessThan(
    sweep.closest(".comma-chat-activity-step-text")!.getBoundingClientRect().width
  );

  const log = row
    .element()
    .parentElement!.querySelector<HTMLElement>(".comma-chat-activity-log")!;
  expect(getComputedStyle(log).visibility).toBe("hidden");
  await userEvent.hover(row);
  await vi.waitFor(() => expect(getComputedStyle(log).opacity).toBe("1"));
  expect(getComputedStyle(log).visibility).toBe("visible");
  expect(
    [...log.querySelectorAll("li")].map((item) =>
      item.textContent?.replace(/^\d{2}:\d{2}/, "")
    )
  ).toEqual(["Read evalens.config.ts", "Run the preview benchmark", "Thinking"]);
  expect(
    log.querySelector("li:last-child [data-shimmer]")!.getAnimations({ subtree: true })
      .length
  ).toBeGreaterThan(0);

  // Beside the card, level with its bottom, growing up as the card does.
  const cardBox = card.element().getBoundingClientRect();
  const frame = log.querySelector(".comma-chat-activity-log-frame")!;
  const steps = frame.getBoundingClientRect();
  expect(steps.left).toBeGreaterThan(cardBox.right);
  expect(Math.abs(steps.bottom - cardBox.bottom)).toBeLessThan(2);

  // The pointer crosses the gap into the log, and the log stays.
  await userEvent.hover(log.querySelector("li")!);
  await new Promise((resolve) => setTimeout(resolve, 500));
  expect(getComputedStyle(log).visibility).toBe("visible");
  await expect.element(card).toBeVisible();
});

it("scrolls before the window's top and follows the newest step", async () => {
  const records = Array.from({ length: 8 }, (_, index) =>
    step(`exec-${index}`, "env.exec", {
      command: "pnpm bench",
      description: `Run benchmark pass ${index + 1} over every preview fixture in the repository`,
    })
  ).flat();
  const core = historyCore([...records, thinking()]);
  await page.viewport(1024, 400);
  render(
    core.wrap(
      <div style={{ padding: "240px 48px 48px", width: 420 }}>
        <ParticipantStatusSlot
          participantStatus={undefined}
          focus={workingFocus}
          taskLink={(task) => (
            <a href={`#/tasks/${task.conversationId}`}>{task.title}</a>
          )}
        />
      </div>
    )
  );

  await userEvent.hover(
    page.getByRole("link", { name: /Make remote previews faster/ })
  );
  const card = page.getByTestId("activity-focus-card");
  await expect.element(card).toBeVisible();
  const row = card.getByRole("link");
  await userEvent.hover(row);
  const log = row
    .element()
    .parentElement!.querySelector<HTMLElement>(".comma-chat-activity-log")!;
  await vi.waitFor(() => expect(getComputedStyle(log).opacity).toBe("1"));

  const frame = log.querySelector<HTMLElement>(".comma-chat-activity-log-frame")!;
  await vi.waitFor(() => {
    // It stops short of the window's top and scrolls instead.
    expect(frame.getBoundingClientRect().top).toBeGreaterThanOrEqual(15);
    expect(frame.scrollHeight).toBeGreaterThan(frame.clientHeight);
    // Scrolled to the newest step.
    expect(frame.scrollTop + frame.clientHeight).toBeGreaterThanOrEqual(
      frame.scrollHeight - 2
    );
  });

  // A wrapped step keeps to its two lines; nothing of a third shows.
  for (const words of log.querySelectorAll<HTMLElement>(
    ".comma-chat-activity-step-words"
  )) {
    expect(words.getBoundingClientRect().height).toBeLessThanOrEqual(36);
  }
});

it("keeps the step in progress in one steady last row through the gaps between steps", async () => {
  const finished = step("read", "fs.read_file", {
    path: "/workspace/evalens.config.ts",
  });
  const core = historyCore([...finished, thinking("request-1")]);
  await page.viewport(1024, 720);
  render(
    core.wrap(
      <div style={{ padding: "360px 48px 48px", width: 420 }}>
        <ParticipantStatusSlot
          participantStatus={undefined}
          focus={workingFocus}
          taskLink={(task) => (
            <a href={`#/tasks/${task.conversationId}`}>{task.title}</a>
          )}
        />
      </div>
    )
  );
  await userEvent.hover(
    page.getByRole("link", { name: /Make remote previews faster/ })
  );
  const row = page.getByTestId("activity-focus-card").getByRole("link");
  await userEvent.hover(row);
  const log = row
    .element()
    .parentElement!.querySelector<HTMLElement>(".comma-chat-activity-log")!;
  const last = () => log.querySelector<HTMLElement>("li:last-child")!;
  await vi.waitFor(() => expect(last().textContent).toContain("Thinking"));
  const slot = last();

  // The request ends before the next one starts: no step is in progress for
  // a moment. The row stays, and is the same row when the next one starts.
  core.emit("history", historyValue([...finished]));
  await new Promise((resolve) => setTimeout(resolve, 300));
  expect(last()).toBe(slot);
  expect(slot.textContent).toContain("Thinking");
  core.emit("history", historyValue([...finished, thinking("request-2")]));
  await new Promise((resolve) => setTimeout(resolve, 100));
  expect(last()).toBe(slot);
  expect(log.querySelectorAll("li")).toHaveLength(2);

  // A command runs in the same row, then finishes and rises in above; the
  // last row stays, plainly working, until the next request starts in it.
  core.emit(
    "history",
    historyValue([...finished, ...runningCommand("exec", "Run the preview benchmark")])
  );
  await vi.waitFor(() =>
    expect(slot.textContent).toContain("Run the preview benchmark")
  );
  expect(last()).toBe(slot);
  const command = step("exec", "env.exec", {
    command: "pnpm bench",
    description: "Run the preview benchmark",
  });
  core.emit("history", historyValue([...finished, ...command]));
  await new Promise((resolve) => setTimeout(resolve, 300));
  expect(last()).toBe(slot);
  expect(slot.textContent).toContain("Working");
  expect(log.querySelectorAll("li")).toHaveLength(3);
  core.emit("history", historyValue([...finished, ...command, thinking("request-3")]));
  await vi.waitFor(() => expect(slot.textContent).toContain("Thinking"));
  expect(last()).toBe(slot);

  // Once the gap outlasts the hold, the Worker is no longer working.
  core.emit("history", historyValue([...finished, ...command]));
  await vi.waitFor(() => expect(log.querySelectorAll("li")).toHaveLength(2), {
    timeout: 3000,
  });
});
