import { describe, expect, it } from "vitest";
import type { BftSwarmTask } from "../src/api";
import { filterTasks, initialView, taskStatuses } from "../src/SwarmTasksPage";

const task = (id: string, status: string, title: string | null, kind = "agent_task") =>
  ({
    id,
    title,
    status,
    kind,
    scheduled: false,
    updated_at: null,
    href: `/orgs/acme/projects/p1/tasks/${id}`,
  }) satisfies BftSwarmTask;

const tasks = [
  task("a", "done", "Summarize findings"),
  task("b", "active", "Investigate webhook"),
  task("c", "needs_review", null, "user_chat"),
];

describe("Agent Swarm tasks", () => {
  it("lists the loaded statuses with active first", () => {
    expect(taskStatuses(tasks)).toEqual(["active", "done", "needs_review"]);
  });

  it("filters by status and searches title, type and status labels", () => {
    expect(filterTasks(tasks, "done", "").map((row) => row.id)).toEqual(["a"]);
    expect(filterTasks(tasks, "all", "WEBHOOK").map((row) => row.id)).toEqual(["b"]);
    // An untitled chat is found by its label, its type and its status.
    expect(filterTasks(tasks, "all", "untitled").map((row) => row.id)).toEqual(["c"]);
    expect(filterTasks(tasks, "all", "chat").map((row) => row.id)).toEqual(["c"]);
    expect(filterTasks(tasks, "all", "needs review").map((row) => row.id)).toEqual([
      "c",
    ]);
    expect(filterTasks(tasks, "active", "summarize")).toEqual([]);
  });

  it("reads the view from the address", () => {
    expect(initialView("")).toBe("all");
    expect(initialView("?view=scheduled")).toBe("scheduled");
  });
});
