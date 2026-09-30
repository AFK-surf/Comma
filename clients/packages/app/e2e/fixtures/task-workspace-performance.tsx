import { useState } from "react";
import { createRoot } from "react-dom/client";
import { initializeCommaI18n } from "@comma/i18n";
import { TaskWorkspace, type TaskWorkspaceTask } from "@comma/ui";
import "../../src/styles.css";

initializeCommaI18n(["en"]);

declare global {
  interface Window {
    taskWorkspaceStress: {
      load(count: number): void;
      append(count: number): void;
      update(): void;
      selected: string[];
      visible: string[];
    };
  }
}

const statuses = ["backlog", "in_progress", "needs_review", "done"] as const;
const makeTask = (index: number): TaskWorkspaceTask => ({
  id: `task-${index}`,
  conversationId: `conversation-${index}`,
  groupId: "group",
  workspaceId: "workspace",
  title: `Task ${index} — review the implementation and the release notes`,
  updatedAt: 1_720_000_000_000,
  statusBucket: statuses[index % statuses.length]!,
  activityStatus: "idle",
  freshness: "fresh",
  messages: [],
});
const noop = () => undefined;
const askComma = (tasks: readonly TaskWorkspaceTask[]) => {
  window.taskWorkspaceStress.selected = tasks.map((task) => task.id);
};
const visibleTasks = (tasks: readonly TaskWorkspaceTask[]) => {
  window.taskWorkspaceStress.visible = tasks.map((task) => task.id);
};
function Fixture() {
  const [tasks, setTasks] = useState<TaskWorkspaceTask[]>([]);
  window.taskWorkspaceStress = {
    selected: [],
    visible: [],
    load: (count) =>
      setTasks(Array.from({ length: count }, (_, index) => makeTask(index))),
    append: (count) =>
      setTasks((current) => [
        ...current,
        ...Array.from({ length: count }, (_, index) =>
          makeTask(current.length + index)
        ),
      ]),
    update: () =>
      setTasks((current) =>
        current.map((task, index) =>
          index === 0 ? { ...task, title: task.title + "." } : task
        )
      ),
  };
  return (
    <div style={{ height: "100vh", display: "flex" }}>
      <TaskWorkspace
        initialView={location.search.includes("list") ? "list" : "board"}
        onAskComma={askComma}
        onOpenTask={noop}
        onVisibleTasksChange={visibleTasks}
        tasks={tasks}
      />
    </div>
  );
}
createRoot(document.getElementById("root")!).render(<Fixture />);
