import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { flush } from "@comma/test-utils/fake-clock";
import { render, screen } from "@comma/test-utils/render";
import { expect, it } from "vitest";
import { TaskDetailsPanel, type TaskDetailsPanelProps } from "../TaskDetailsPanel";

it("names who asked for a requested Task in a Request section, with their avatar, in place of its origin", async () => {
  const core = createScriptedCore({});
  const conversation = {
    id: "cnv_1",
    labels: [],
    origin: "task_request",
    requested_by: "Sam",
    requested_by_avatar: { workspace: "w1", request: "trq_1", revision: "avt_1" },
    status: "running",
  } as unknown as TaskDetailsPanelProps["conversation"];
  render(
    core.wrap(
      <TaskDetailsPanel
        conversation={conversation}
        groupId="grp_1"
        labeled={false}
        open
      />
    )
  );
  await flush();
  const section = screen.getByTestId("task-panel-request");
  expect(section).toHaveTextContent("Request");
  expect(section).toHaveTextContent("Sam");
  expect(screen.queryByTestId("task-panel-origin")).toBeNull();
  // The avatar is read through the request, at the revision the Task was made with.
  expect(core.sentTo("files.read")).toEqual([
    { source: "sender-avatar", workspace: "w1", request: "trq_1", revision: "avt_1" },
  ]);
});
