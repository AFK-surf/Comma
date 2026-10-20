import { describe, expect, it } from "vitest";
import type { BftSwarmTask, BftTaskPlace, BftTaskTargets } from "../src/api";
import {
  emptyTaskDraft,
  filterTasks,
  initialView,
  newTaskRequest,
  taskStatuses,
} from "../src/SwarmTasksPage";

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

  it("asks for the place and model chosen, the swarm's defaults when none", () => {
    const gpt = { kind: "catalog", model: "gpt-5.5" };
    const places: Omit<BftTaskPlace, "default">[] = [
      { id: "salix", kind: "salix", label: "Salix", models: {} },
      { id: "cloud_vm", kind: "cloud_vm", label: "The Cloud VM", models: {} },
      {
        id: "dev-1",
        kind: "station",
        device_id: "dev-1",
        label: "Mac Studio",
        models: { codex: ["gpt-5.5"] },
      },
    ];
    const targets = (defaultId: string): BftTaskTargets => ({
      places: places.map((place) => ({ ...place, default: place.id === defaultId })),
      models: [
        { key: "", choice: null, label: "Swarm default" },
        { key: "catalog:gpt-5.5", choice: gpt, label: "GPT-5.5" },
      ],
    });
    const draft = { ...emptyTaskDraft, title: " Report ", content: " Write it. " };
    const asked = { title: "Report", content: "Write it." };

    // The swarm's default place and Task model name nothing more.
    expect(newTaskRequest(targets("salix"), draft)).toEqual({
      ...asked,
      runs_on: { kind: "salix" },
    });
    expect(newTaskRequest(targets("dev-1"), draft)).toEqual({
      ...asked,
      runs_on: { kind: "station", device_id: "dev-1" },
      model: { kind: "runtime", provider: "codex" },
    });

    // A chosen place and model.
    expect(
      newTaskRequest(targets("dev-1"), {
        ...draft,
        placeId: "salix",
        modelKey: "catalog:gpt-5.5",
      })
    ).toEqual({ ...asked, runs_on: { kind: "salix" }, model: gpt });
    expect(
      newTaskRequest(targets("salix"), {
        ...draft,
        placeId: "cloud_vm",
        runtime: "claude",
        stationModel: "claude-opus-5-5",
      })
    ).toEqual({
      ...asked,
      runs_on: { kind: "cloud_vm" },
      model: { kind: "runtime", provider: "claude", model: "claude-opus-5-5" },
    });

    // A default place that cannot take Tasks now is not listed: Salix.
    expect(newTaskRequest(targets("dev-gone"), draft).runs_on).toEqual({
      kind: "salix",
    });
  });
});
