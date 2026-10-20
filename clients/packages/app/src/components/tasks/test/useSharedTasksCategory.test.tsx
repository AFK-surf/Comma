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
