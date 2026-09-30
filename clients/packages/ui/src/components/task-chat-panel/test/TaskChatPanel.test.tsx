import { fireEvent, render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { TaskChatPanel } from "../TaskChatPanel";

describe("TaskChatPanel", () => {
  it("starts at the newest message and follows updates only while near the end", () => {
    const view = renderPanel("First message");
    expect(view.container.querySelector('[data-slot="task-chat-panel"]')).toHaveClass(
      "bg-main-panel-bg"
    );
    const viewport = screen.getByRole("log", { name: "Task conversation" });
    let scrollHeight = 600;
    Object.defineProperty(viewport, "clientHeight", {
      configurable: true,
      value: 200,
    });
    Object.defineProperty(viewport, "scrollHeight", {
      configurable: true,
      get: () => scrollHeight,
    });

    view.rerender(panel("Second message"));
    expect(viewport.scrollTop).toBe(400);

    viewport.scrollTop = 390;
    fireEvent.scroll(viewport);
    scrollHeight = 700;
    view.rerender(panel("Third message"));
    expect(viewport.scrollTop).toBe(500);

    viewport.scrollTop = 100;
    fireEvent.scroll(viewport);
    scrollHeight = 800;
    view.rerender(panel("Fourth message"));
    expect(viewport.scrollTop).toBe(100);
  });
});

function renderPanel(message: string) {
  return render(panel(message));
}

function panel(message: string) {
  return (
    <TaskChatPanel
      aiInputProps={{
        showAccessButton: false,
        showAttachButton: false,
        showVoiceButton: false,
      }}
      onClose={vi.fn()}
      title="Task"
    >
      <p>{message}</p>
    </TaskChatPanel>
  );
}
