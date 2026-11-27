import { flush } from "@comma/test-utils/fake-clock";
import { renderHook } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type { ReactNode } from "react";
import { expect, it } from "vitest";
import { useSharedTasksCategory } from "../useSharedTasksCategory";

const workspace = { id: "ws-a", groupId: "grp-a", name: "Workspace A" };

it("lists the shared Tasks of the Workspace the app works in", async () => {
  const lists: Record<string, unknown>[] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "workspace"
        ? { status: "ready", workspace, selected: true }
        : topic.topic === "taskShares"
          ? {
              workspace: { id: workspace.id, name: workspace.name, group_id: "grp-a" },
              shares: [
                {
                  id: "cnv_a",
                  title: "Launch notes",
                  shared_at: 1_790_200_000,
                  artifact_count: 0,
                },
              ],
              hasMore: false,
              loading: false,
              error: null,
            }
          : undefined,
    calls: (name) =>
      name === "documentShares.list" ? { shares: [], cursor: null } : null,
    onSubscribe: (topic) => {
      if (topic.topic === "taskShares") lists.push(topic);
    },
  });
  const { result } = renderHook(() => useSharedTasksCategory(true), {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  await flush();
  const ids = () => result.current.sections[0]!.items.map((item) => item.id);
  expect(ids()).toEqual(["shared-task.cnv_a"]);

  expect(lists).toEqual([{ topic: "taskShares", workspace: workspace.id }]);
});

it("lists the Group's shared documents under the Tasks, and takes one off when its link stops", async () => {
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "workspace"
        ? { status: "ready", workspace, selected: true }
        : topic.topic === "taskShares"
          ? {
              workspace: { id: workspace.id, name: workspace.name, group_id: "grp-a" },
              shares: [],
              hasMore: false,
              loading: false,
              error: null,
            }
          : undefined,
    calls: (name, params) => {
      calls.push([name, params]);
      return name === "documentShares.list"
        ? {
            shares: [
              {
                url: "https://comma.test/s/one",
                fileName: "plan.md",
                conversation: "cnv_a",
                task: "Launch notes",
                shared_at: 1_790_200_000,
              },
            ],
            cursor: null,
          }
        : null;
    },
  });
  const { result } = renderHook(() => useSharedTasksCategory(true), {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  await flush();
  const documents = () => result.current.sections[1]!.items;
  // The list is read once, for the Workspace's Group.
  expect(calls).toEqual([["documentShares.list", { group: "grp-a" }]]);
  expect(documents().map((item) => [item.id, item.title])).toEqual([
    ["shared-document.cnv_a\u0000plan.md", "plan.md"],
  ]);
  expect(documents()[0]!.description).toContain("In Launch notes");

  // Stop sharing asks for that document's link, and the row leaves the list.
  const control = documents()[0]!.control;
  if (control?.type !== "button") throw new Error("The row has no button.");
  control.onPress?.();
  await flush();
  expect(calls.at(-1)).toEqual([
    "documentShare.revoke",
    { group: "grp-a", conversation: "cnv_a", fileName: "plan.md" },
  ]);
  expect(documents().map((item) => item.id)).toEqual(["shared-documents.empty"]);
});
