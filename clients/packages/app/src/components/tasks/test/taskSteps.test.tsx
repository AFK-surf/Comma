import { act, render, screen } from "@comma/test-utils/render";
import { useTaskProgress } from "@comma/ui/components/task-workspace";
import { useContext, useSyncExternalStore } from "react";
import { describe, expect, it } from "vitest";
import {
  TaskStepCards,
  TaskStepsContext,
  TaskStepsProvider,
  type TaskSteps,
} from "../taskSteps";

let session: TaskSteps | undefined;

/** Stands in for NotchTaskSync: whether a list watches, and its store. */
function Owner() {
  const steps = useContext(TaskStepsContext)!;
  session = steps;
  const watched = useSyncExternalStore(steps.subscribe, steps.watched);
  return <span data-testid="watched">{String(watched)}</span>;
}

function Card({ name }: { name: string }) {
  return <span data-testid={name}>{useTaskProgress("task-a") ?? "none"}</span>;
}

function Session({ home, board }: { home: boolean; board: boolean }) {
  return (
    <TaskStepsProvider>
      <Owner />
      <TaskStepCards active={home}>
        <Card name="home" />
      </TaskStepCards>
      {board ? (
        <TaskStepCards active>
          <Card name="board" />
        </TaskStepCards>
      ) : null}
      <Card name="chat" />
    </TaskStepsProvider>
  );
}

describe("Task step card lists", () => {
  it("follows Workers while any list shows and gives steps only to its cards", () => {
    const { rerender } = render(<Session home board />);
    act(() => session!.publish(new Map([["task-a", "Ran the tests"]])));

    expect(screen.getByTestId("watched").textContent).toBe("true");
    expect(screen.getByTestId("home").textContent).toBe("Ran the tests");
    expect(screen.getByTestId("board").textContent).toBe("Ran the tests");
    expect(screen.getByTestId("chat").textContent).toBe("none");

    rerender(<Session home board={false} />);
    expect(screen.getByTestId("watched").textContent).toBe("true");

    rerender(<Session home={false} board={false} />);
    expect(screen.getByTestId("watched").textContent).toBe("false");
    expect(screen.getByTestId("home").textContent).toBe("none");
  });
});
