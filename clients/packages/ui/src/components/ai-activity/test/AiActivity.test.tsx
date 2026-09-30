import { render, screen } from "@comma/test-utils/render";
import { fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { describe, expect, it, vi } from "vitest";
import { AiActivity, AiWorkerActivity, type AiActivityEvent } from "../AiActivity";

const events = [
  {
    id: "reasoning",
    phase: "thinking",
    status: "complete",
    summary: "Weighed the implementation path",
  },
  {
    id: "tool",
    phase: "execution",
    status: "complete",
    summary: "Read the workspace",
    toolName: "fs.read_file",
  },
] satisfies AiActivityEvent[];

const longEvents = Array.from({ length: 9 }, (_, index) => ({
  id: `history-${index}`,
  phase: "thinking" as const,
  status: "complete" as const,
  summary: `Activity event ${index + 1}`,
})) satisfies AiActivityEvent[];

describe("AiActivity", () => {
  it("keeps an active headline separate from public history", () => {
    const { container } = render(
      <AiActivity
        activityKey="thinking"
        phase="thinking"
        shimmer
        status="running"
        summary="Thinking…"
      />
    );

    const root = container.querySelector('[data-slot="ai-activity"]');
    expect(root).toHaveAttribute("aria-busy", "true");
    expect(root).toHaveAttribute("data-phase", "thinking");
    expect(screen.getByRole("status")).toHaveTextContent("Thinking…");
    expect(screen.getByRole("status")).not.toHaveTextContent("Router");
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
    expect(
      container.querySelector(".comma-ai-activity-chevron")
    ).not.toBeInTheDocument();
    expect(container.querySelector('[data-shimmer="true"]')).toBeInTheDocument();
  });

  it("keeps the headline node stable while the first real history enables disclosure", () => {
    const { container, rerender } = render(
      <AiActivity
        activityKey="generic-thinking"
        phase="thinking"
        shimmer
        status="running"
        summary="Thinking…"
      />
    );
    const headline = container.querySelector(".comma-ai-activity-text");

    expect(headline).not.toBeNull();
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
    expect(container.querySelector(".comma-ai-activity-panel-shell")).toBeNull();

    rerender(
      <AiActivity
        activityKey="execution"
        events={[events[0]!]}
        phase="execution"
        status="running"
        summary="Reading the workspace"
      />
    );

    expect(headline).toBe(container.querySelector(".comma-ai-activity-text"));
    expect(headline).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Reading the workspace" })
    ).toHaveAttribute("aria-expanded", "false");
    expect(container.querySelector(".comma-ai-activity-panel-shell")).not.toBeNull();
  });

  it("reveals public events through an accessible downward disclosure", async () => {
    const user = userEvent.setup();
    const { container } = render(
      <AiActivity
        activityKey="complete"
        events={events}
        phase="messaging"
        result={<p>Implementation complete.</p>}
        status="complete"
        summary="Worked for 8 seconds"
      />
    );

    const disclosure = screen.getByRole("button", { name: "Worked for 8 seconds" });
    const panel = container.querySelector(".comma-ai-activity-panel");
    const panelShell = container.querySelector(".comma-ai-activity-panel-shell");
    const chevron = container.querySelector(".comma-ai-activity-chevron");
    expect(disclosure).toHaveAttribute("aria-expanded", "false");
    expect(disclosure).toHaveAttribute("data-no-press-feedback");
    expect(disclosure.parentElement?.nextElementSibling).toBe(panelShell);
    expect(panelShell?.firstElementChild).toBe(panel);
    expect(panelShell).toHaveAttribute("data-expanded", "false");
    expect(panelShell).toHaveAttribute("inert");
    expect(panel).toHaveAttribute("data-state", "closed");
    expect(panel).toHaveAttribute("aria-hidden", "true");
    expect(screen.getByText("Implementation complete.")).toBeInTheDocument();

    await user.tab();
    expect(disclosure).toHaveFocus();
    expect(disclosure).toHaveAttribute("data-focus-visible", "true");

    await user.click(disclosure);

    expect(disclosure).toHaveAttribute("aria-expanded", "true");
    expect(panelShell).toHaveAttribute("data-expanded", "true");
    expect(panelShell).not.toHaveAttribute("inert");
    expect(panel).toHaveAttribute("data-state", "open");
    expect(panel).toHaveAttribute("aria-hidden", "false");
    expect(container.querySelector(".comma-ai-activity-chevron")).toBe(chevron);
    expect(screen.getByText("Weighed the implementation path")).toBeInTheDocument();
    expect(screen.queryByText("Router")).not.toBeInTheDocument();
    expect(screen.queryByText("Worker")).not.toBeInTheDocument();
    expect(screen.getByText("fs.read_file")).toBeInTheDocument();
  });

  it("keeps Worker chat out of the timeline until hover", async () => {
    const user = userEvent.setup();
    render(
      <AiWorkerActivity
        messages={[
          {
            content: "Compress 1.mp4 and report back.",
            id: "assignment",
            sender: "Router",
          },
          {
            content: "Compression is running.",
            id: "progress",
            sender: "Worker",
          },
        ]}
        status="running"
      />
    );

    const worker = screen.getByRole("button", {
      name: "Worker, working",
    });
    expect(worker).toHaveTextContent("Worker");
    expect(worker).toHaveTextContent("working");
    expect(
      screen.queryByText("Compress 1.mp4 and report back.")
    ).not.toBeInTheDocument();

    await user.hover(worker);

    const tooltip = await screen.findByRole("tooltip");
    expect(tooltip).toHaveTextContent("Worker chat");
    expect(tooltip).toHaveTextContent("Router");
    expect(tooltip).toHaveTextContent("Compress 1.mp4 and report back.");
    expect(tooltip).toHaveTextContent("Compression is running.");
    expect(tooltip).not.toHaveTextContent("env.exec");
  });

  it("reveals Worker chat on keyboard focus", async () => {
    const user = userEvent.setup();
    render(
      <AiWorkerActivity
        messages={[
          {
            content: "Compress 1.mp4 and report back.",
            id: "assignment",
            sender: "Router",
          },
        ]}
        status="running"
      />
    );

    const worker = screen.getByRole("button", {
      name: "Worker, working",
    });
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();

    await user.tab();

    expect(worker).toHaveFocus();
    expect(await screen.findByRole("tooltip")).toHaveTextContent(
      "Compress 1.mp4 and report back."
    );
  });

  it("uses a non-interactive lowercase Worker completion label without chat", () => {
    const { container } = render(<AiWorkerActivity status="complete" />);

    const worker = screen.getByRole("status", { name: "Worker, done" });
    expect(container.querySelector('[data-slot="ai-worker-activity"]')).toHaveAttribute(
      "data-status",
      "complete"
    );
    expect(worker.querySelector(".comma-ai-worker-activity-state")).toHaveTextContent(
      "done"
    );
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("caps sections after eight events with a blurred internal ScrollArea", () => {
    const { container } = render(
      <AiActivity
        activityKey="long-history"
        defaultExpanded
        events={longEvents}
        phase="messaging"
        status="complete"
        summary="Worked for 17 seconds"
      />
    );

    const scrollArea = container.querySelector('[data-slot="scroll-area"]');
    expect(scrollArea).toHaveAttribute("data-edge-effect", "blur");
    expect(scrollArea).toHaveAttribute("data-capped", "true");
    expect(scrollArea).toHaveAttribute("data-orientation", "vertical");
    expect(
      container.querySelector('[data-slot="scroll-area-scrollbar"]')
    ).not.toBeInTheDocument();
    expect(
      container.querySelectorAll('[data-slot^="scroll-area-edge-blur-"]')
    ).toHaveLength(2);
    expect(
      container.querySelector('[data-slot="scroll-area-viewport"]')
    ).toHaveAttribute("aria-label", "Activity history");
    expect(container.querySelectorAll(".comma-ai-activity-event")).toHaveLength(9);
  });

  it("keeps the event list mounted when history crosses the scroll threshold", () => {
    const { container, rerender } = render(
      <AiActivity
        activityKey="eight-events"
        defaultExpanded
        events={longEvents.slice(0, 8)}
        phase="messaging"
        status="running"
        summary="Working"
      />
    );
    const eventList = container.querySelector(".comma-ai-activity-events");
    const scrollArea = container.querySelector('[data-slot="scroll-area"]');
    expect(eventList).toBeInTheDocument();
    expect(eventList?.parentElement).toHaveClass("comma-scroll-area__content");
    expect(scrollArea).not.toHaveAttribute("data-capped");

    rerender(
      <AiActivity
        activityKey="nine-events"
        defaultExpanded
        events={longEvents}
        phase="messaging"
        status="running"
        summary="Working"
      />
    );

    expect(container.querySelector(".comma-ai-activity-events")).toBe(eventList);
    expect(scrollArea).toHaveAttribute("data-capped", "true");
    expect(container.querySelectorAll(".comma-ai-activity-event")).toHaveLength(9);
  });

  it("animates expansion and collapse from the panel's current height", () => {
    const frames: FrameRequestCallback[] = [];
    const requestFrame = vi
      .spyOn(window, "requestAnimationFrame")
      .mockImplementation((callback) => {
        frames.push(callback);
        return frames.length;
      });
    const { container } = render(
      <AiActivity
        activityKey="complete"
        defaultExpanded
        events={events}
        phase="messaging"
        status="complete"
        summary="Worked for 8 seconds"
      />
    );
    const disclosure = screen.getByRole("button", { name: "Worked for 8 seconds" });
    const panelShell = container.querySelector(
      ".comma-ai-activity-panel-shell"
    ) as HTMLDivElement;
    let currentHeight = 110;
    const bounds = vi.spyOn(panelShell, "getBoundingClientRect").mockImplementation(
      () =>
        ({
          bottom: currentHeight,
          height: currentHeight,
          left: 0,
          right: 100,
          top: 0,
          width: 100,
          x: 0,
          y: 0,
          toJSON: () => ({}),
        }) as DOMRect
    );
    Object.defineProperty(panelShell, "scrollHeight", {
      configurable: true,
      value: 110,
    });
    frames.length = 0;
    requestFrame.mockClear();

    fireEvent.click(disclosure);
    expect(disclosure).toHaveAttribute("aria-expanded", "false");
    expect(panelShell).toHaveStyle({ height: "110px" });
    act(() => frames.shift()?.(0));
    expect(panelShell).toHaveStyle({ height: "0px" });

    currentHeight = 40;
    fireEvent.click(disclosure);
    expect(disclosure).toHaveAttribute("aria-expanded", "true");
    expect(panelShell).toHaveStyle({ height: "40px" });
    act(() => frames.shift()?.(16));
    expect(panelShell).toHaveStyle({ height: "110px" });
    fireEvent.transitionEnd(panelShell, { propertyName: "height" });
    expect(panelShell).toHaveStyle({ height: "auto" });

    bounds.mockRestore();
    requestFrame.mockRestore();
  });

  it("animates a controlled trace closed when the task completes", () => {
    const frames: FrameRequestCallback[] = [];
    const requestFrame = vi
      .spyOn(window, "requestAnimationFrame")
      .mockImplementation((callback) => {
        frames.push(callback);
        return frames.length;
      });
    const { container, rerender } = render(
      <AiActivity
        activityKey="running"
        details={<p>Router and Worker trace</p>}
        expanded
        phase="thinking"
        status="running"
        summary="Working"
      />
    );
    const panelShell = container.querySelector(
      ".comma-ai-activity-panel-shell"
    ) as HTMLDivElement;
    const bounds = vi.spyOn(panelShell, "getBoundingClientRect").mockReturnValue({
      bottom: 140,
      height: 140,
      left: 0,
      right: 100,
      top: 0,
      width: 100,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    } as DOMRect);
    frames.length = 0;

    rerender(
      <AiActivity
        activityKey="complete"
        details={<p>Router and Worker trace</p>}
        expanded={false}
        phase="messaging"
        result={<p>Committed result</p>}
        status="complete"
        summary="Worked for 17 seconds"
      />
    );

    expect(
      screen.getByRole("button", { name: "Worked for 17 seconds" })
    ).toHaveAttribute("aria-expanded", "false");
    expect(panelShell).toHaveStyle({ height: "140px" });
    act(() => frames.shift()?.(0));
    expect(panelShell).toHaveStyle({ height: "0px" });
    expect(screen.getByText("Committed result")).toBeInTheDocument();

    bounds.mockRestore();
    requestFrame.mockRestore();
  });

  it("returns nested focus to a completed section before collapse", () => {
    const { rerender } = render(
      <AiActivity
        activityKey="delegating"
        collapseOnComplete
        defaultExpanded
        details={
          <AiWorkerActivity
            messages={[
              {
                content: "Compress 1.mp4 and report back.",
                id: "assignment",
                sender: "Router",
              },
            ]}
            status="running"
          />
        }
        phase="messaging"
        status="running"
        summary="Handing the task to the Worker"
      />
    );

    expect(
      screen.getByRole("button", { name: "Handing the task to the Worker" })
    ).toHaveAttribute("aria-expanded", "true");
    act(() => screen.getByRole("button", { name: "Worker, working" }).focus());

    rerender(
      <AiActivity
        activityKey="delegated"
        collapseOnComplete
        defaultExpanded
        details={
          <AiWorkerActivity
            messages={[
              {
                content: "Compress 1.mp4 and report back.",
                id: "assignment",
                sender: "Router",
              },
            ]}
            status="complete"
          />
        }
        phase="messaging"
        status="complete"
        summary="Delegated in 1 second"
      />
    );

    const completedSection = screen.getByRole("button", {
      name: "Delegated in 1 second",
    });
    expect(completedSection).toHaveAttribute("aria-expanded", "false");
    expect(completedSection).toHaveFocus();

    fireEvent.click(completedSection);
    expect(completedSection).toHaveAttribute("aria-expanded", "true");
  });

  it("does not move external focus when a completed section collapses", () => {
    const { rerender } = render(
      <>
        <button type="button">Outside activity</button>
        <AiActivity
          activityKey="delegating"
          collapseOnComplete
          defaultExpanded
          details={<p>Router and Worker trace</p>}
          phase="messaging"
          status="running"
          summary="Handing the task to the Worker"
        />
      </>
    );
    const outside = screen.getByRole("button", { name: "Outside activity" });
    outside.focus();

    rerender(
      <>
        <button type="button">Outside activity</button>
        <AiActivity
          activityKey="delegated"
          collapseOnComplete
          defaultExpanded
          details={<p>Router and Worker trace</p>}
          phase="messaging"
          status="complete"
          summary="Delegated in 1 second"
        />
      </>
    );

    expect(
      screen.getByRole("button", { name: "Delegated in 1 second" })
    ).toHaveAttribute("aria-expanded", "false");
    expect(outside).toHaveFocus();
  });

  it("paints the incoming headline before starting the anchored swap", () => {
    const frames: FrameRequestCallback[] = [];
    const requestFrame = vi
      .spyOn(window, "requestAnimationFrame")
      .mockImplementation((callback) => {
        frames.push(callback);
        return frames.length;
      });
    const { container, rerender } = render(
      <AiActivity
        activityKey="thinking"
        phase="thinking"
        shimmer
        status="running"
        summary="Thinking…"
      />
    );
    rerender(
      <AiActivity
        activityKey="tool-call"
        phase="execution"
        shimmer={false}
        status="running"
        summary="Reading the workspace"
        toolName="fs.read_file"
      />
    );

    const outgoing = container.querySelector('[data-motion-key="running:thinking"]');
    const incoming = container.querySelector('[data-motion-key="running:tool-call"]');
    expect(container.querySelectorAll(".comma-ai-activity-text-layer")).toHaveLength(2);
    expect(outgoing).toHaveAttribute("aria-hidden", "true");
    expect(outgoing).toHaveTextContent("Thinking…");
    expect(outgoing?.querySelector('[data-shimmer="true"]')).toBeInTheDocument();
    expect(incoming).not.toHaveAttribute("aria-hidden");
    expect(incoming).toHaveTextContent("Reading the workspace");
    expect(incoming).toHaveTextContent("fs.read_file");
    const summary = incoming?.querySelector(".comma-ai-activity-text-summary");
    const toolName = incoming?.querySelector(".comma-ai-activity-tool-name");
    expect(summary).toHaveAttribute("data-shimmer", "false");
    expect(summary).not.toContainElement(toolName as HTMLElement);
    expect(outgoing).toHaveAttribute("data-motion", "rest");
    expect(incoming).toHaveAttribute("data-motion", "enter");
    expect(outgoing?.parentElement).toHaveAttribute("data-playing", "false");
    expect(screen.getByRole("status")).toHaveTextContent("Reading the workspace");

    act(() => frames.shift()?.(0));
    expect(requestFrame).toHaveBeenCalledTimes(2);
    expect(outgoing).toHaveAttribute("data-motion", "rest");
    expect(incoming).toHaveAttribute("data-motion", "enter");

    act(() => frames.shift()?.(16));
    expect(outgoing).toHaveAttribute("data-motion", "exit");
    expect(outgoing?.querySelector('[data-shimmer="true"]')).not.toBeInTheDocument();
    expect(incoming).toHaveAttribute("data-motion", "rest");
    expect(outgoing?.parentElement).toHaveAttribute("data-playing", "true");
    requestFrame.mockRestore();
  });

  it("coalesces 30ms headline updates behind the active swap and keeps only the latest target", () => {
    vi.useFakeTimers();
    const frames: FrameRequestCallback[] = [];
    let frameId = 0;
    const requestFrame = vi
      .spyOn(window, "requestAnimationFrame")
      .mockImplementation((callback) => {
        frames.push(callback);
        frameId += 1;
        return frameId;
      });
    const cancelFrame = vi.spyOn(window, "cancelAnimationFrame");

    try {
      const { container, rerender } = render(
        <AiActivity
          activityKey="thinking"
          phase="thinking"
          status="running"
          summary="Thinking…"
        />
      );

      rerender(
        <AiActivity
          activityKey="reading"
          phase="execution"
          status="running"
          summary="Reading the workspace"
        />
      );
      const thinkingLayer = container.querySelector(
        '[data-motion-key="running:thinking"]'
      );
      const readingLayer = container.querySelector(
        '[data-motion-key="running:reading"]'
      );

      rerender(
        <AiActivity
          activityKey="reading"
          phase="execution"
          status="running"
          summary="Reading source files"
        />
      );
      expect(container.querySelector('[data-motion-key="running:reading"]')).toBe(
        readingLayer
      );
      expect(readingLayer).toHaveTextContent("Reading source files");

      rerender(
        <AiActivity
          activityKey="planning"
          phase="thinking"
          status="running"
          summary="Planning the change"
        />
      );
      expect(requestFrame).toHaveBeenCalledTimes(1);
      expect(cancelFrame).not.toHaveBeenCalled();
      expect(container).not.toHaveTextContent("Planning the change");

      act(() => frames.shift()?.(0));
      act(() => frames.shift()?.(16));

      act(() => vi.advanceTimersByTime(30));
      rerender(
        <AiActivity
          activityKey="searching"
          phase="execution"
          status="running"
          summary="Searching the workspace"
        />
      );
      act(() => vi.advanceTimersByTime(30));
      rerender(
        <AiActivity
          activityKey="reviewing"
          phase="thinking"
          status="running"
          summary="Reviewing the result"
        />
      );

      expect(requestFrame).toHaveBeenCalledTimes(2);
      expect(cancelFrame).not.toHaveBeenCalled();
      expect(container.querySelectorAll(".comma-ai-activity-text-layer")).toHaveLength(
        2
      );
      expect(thinkingLayer).toHaveAttribute("data-motion", "exit");
      expect(readingLayer).toHaveAttribute("data-motion", "rest");
      expect(container).not.toHaveTextContent("Planning the change");
      expect(container).not.toHaveTextContent("Searching the workspace");
      expect(container).not.toHaveTextContent("Reviewing the result");

      fireEvent.transitionEnd(readingLayer!, { propertyName: "transform" });

      const reviewingLayer = container.querySelector(
        '[data-motion-key="running:reviewing"]'
      );
      expect(container.querySelectorAll(".comma-ai-activity-text-layer")).toHaveLength(
        2
      );
      expect(container.querySelector('[aria-hidden="true"]')).toBe(readingLayer);
      expect(readingLayer).toHaveTextContent("Reading source files");
      expect(reviewingLayer).toHaveAttribute("data-motion", "enter");
      expect(reviewingLayer).toHaveTextContent("Reviewing the result");
      expect(thinkingLayer).not.toBeInTheDocument();
      expect(container).not.toHaveTextContent("Planning the change");
      expect(container).not.toHaveTextContent("Searching the workspace");

      act(() => frames.shift()?.(32));
      act(() => frames.shift()?.(48));
      fireEvent.transitionEnd(reviewingLayer!, { propertyName: "transform" });

      const settledLayers = container.querySelectorAll(".comma-ai-activity-text-layer");
      expect(settledLayers).toHaveLength(1);
      expect(settledLayers[0]).toBe(reviewingLayer);
      expect(settledLayers[0]).toHaveTextContent("Reviewing the result");
    } finally {
      cancelFrame.mockRestore();
      requestFrame.mockRestore();
      vi.useRealTimers();
    }
  });

  it("settles an active headline swap immediately when reduced motion is enabled", () => {
    const frames: FrameRequestCallback[] = [];
    const requestFrame = vi
      .spyOn(window, "requestAnimationFrame")
      .mockImplementation((callback) => {
        frames.push(callback);
        return frames.length;
      });

    try {
      const { container, rerender } = render(
        <AiActivity
          activityKey="thinking"
          phase="thinking"
          status="running"
          summary="Thinking…"
        />
      );
      rerender(
        <AiActivity
          activityKey="reading"
          phase="execution"
          status="running"
          summary="Reading the workspace"
        />
      );
      expect(container.querySelectorAll(".comma-ai-activity-text-layer")).toHaveLength(
        2
      );

      document.documentElement.setAttribute("data-comma-reduced-motion", "true");
      rerender(
        <AiActivity
          activityKey="typing"
          phase="messaging"
          status="running"
          summary="Typing…"
        />
      );

      const settledLayers = container.querySelectorAll(".comma-ai-activity-text-layer");
      expect(settledLayers).toHaveLength(1);
      expect(settledLayers[0]).toHaveAttribute("data-motion-key", "running:typing");
      expect(settledLayers[0]).toHaveAttribute("data-motion", "rest");
      expect(settledLayers[0]).toHaveTextContent("Typing…");
    } finally {
      document.documentElement.removeAttribute("data-comma-reduced-motion");
      requestFrame.mockRestore();
    }
  });

  it("settles the latest headline when transitionend is lost", () => {
    vi.useFakeTimers();
    const frames: FrameRequestCallback[] = [];
    const requestFrame = vi
      .spyOn(window, "requestAnimationFrame")
      .mockImplementation((callback) => {
        frames.push(callback);
        return frames.length;
      });

    try {
      const { container, rerender } = render(
        <AiActivity
          activityKey="thinking"
          phase="thinking"
          status="running"
          summary="Thinking…"
        />
      );
      rerender(
        <AiActivity
          activityKey="typing"
          phase="messaging"
          status="running"
          summary="Typing…"
        />
      );
      const typingLayer = container.querySelector('[data-motion-key="running:typing"]');

      act(() => frames.shift()?.(0));
      act(() => frames.shift()?.(16));
      expect(container.querySelectorAll(".comma-ai-activity-text-layer")).toHaveLength(
        2
      );

      rerender(
        <AiActivity
          activityKey="answering"
          phase="messaging"
          status="running"
          summary="Answering…"
        />
      );

      act(() => vi.advanceTimersByTime(251));

      const answeringLayer = container.querySelector(
        '[data-motion-key="running:answering"]'
      );
      expect(container.querySelectorAll(".comma-ai-activity-text-layer")).toHaveLength(
        2
      );
      expect(container.querySelector('[aria-hidden="true"]')).toBe(typingLayer);
      expect(answeringLayer).toHaveAttribute("data-motion", "enter");

      act(() => frames.shift()?.(32));
      act(() => frames.shift()?.(48));
      act(() => vi.advanceTimersByTime(251));

      const settledLayers = container.querySelectorAll(".comma-ai-activity-text-layer");
      expect(settledLayers).toHaveLength(1);
      expect(settledLayers[0]).toBe(answeringLayer);
      expect(settledLayers[0]).toHaveTextContent("Answering…");
    } finally {
      requestFrame.mockRestore();
      vi.useRealTimers();
    }
  });

  it("FLIPs the chevron without constraining the headline width", () => {
    const frames: FrameRequestCallback[] = [];
    const requestFrame = vi
      .spyOn(window, "requestAnimationFrame")
      .mockImplementation((callback) => {
        frames.push(callback);
        return frames.length;
      });
    const { container, rerender } = render(
      <AiActivity
        activityKey="thinking"
        events={events}
        phase="thinking"
        status="running"
        summary="Thinking…"
      />
    );
    const text = container.querySelector(".comma-ai-activity-text") as HTMLSpanElement;
    const textBounds = vi
      .spyOn(text, "getBoundingClientRect")
      .mockReturnValueOnce({
        bottom: 20,
        height: 20,
        left: 0,
        right: 72,
        top: 0,
        width: 72,
        x: 0,
        y: 0,
        toJSON: () => ({}),
      } as DOMRect)
      .mockReturnValueOnce({
        bottom: 20,
        height: 20,
        left: 0,
        right: 220,
        top: 0,
        width: 220,
        x: 0,
        y: 0,
        toJSON: () => ({}),
      } as DOMRect);
    frames.length = 0;
    requestFrame.mockClear();

    rerender(
      <AiActivity
        activityKey="tool-call"
        events={events}
        phase="execution"
        status="running"
        summary="Reading the workspace"
        toolName="fs.read_file"
      />
    );

    const disclosure = screen.getByRole("button", {
      name: /Reading the workspace.*fs\.read_file/,
    });
    expect(disclosure).toHaveStyle({
      "--ai-activity-chevron-shift": "-148px",
    });
    expect(text).not.toHaveAttribute("style");

    while (frames.length > 0) {
      act(() => frames.shift()?.(16));
    }

    expect(disclosure).toHaveStyle({
      "--ai-activity-chevron-shift": "0px",
    });
    textBounds.mockRestore();
    requestFrame.mockRestore();
  });

  it("extends history downward without remounting completed rows", () => {
    const frames: FrameRequestCallback[] = [];
    const requestFrame = vi
      .spyOn(window, "requestAnimationFrame")
      .mockImplementation((callback) => {
        frames.push(callback);
        return frames.length;
      });
    const bounds = vi
      .spyOn(HTMLElement.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: HTMLElement) {
        const height = this.classList.contains("comma-ai-activity-event-content")
          ? 20
          : 0;
        return {
          bottom: height,
          height,
          left: 0,
          right: 100,
          top: 0,
          width: 100,
          x: 0,
          y: 0,
          toJSON: () => ({}),
        };
      });
    const { container, rerender } = render(
      <AiActivity
        activityKey="execution"
        defaultExpanded
        events={[events[0]!]}
        phase="execution"
        status="running"
        summary="Searching the workspace"
      />
    );

    const firstRow = container.querySelector(".comma-ai-activity-event");
    expect(firstRow).toHaveAttribute("data-entered", "true");
    expect(firstRow).toHaveAttribute("data-settled", "true");
    frames.length = 0;
    requestFrame.mockClear();

    rerender(
      <AiActivity
        activityKey="execution"
        defaultExpanded
        events={events}
        phase="execution"
        status="running"
        summary="Searching the workspace"
      />
    );

    const rows = container.querySelectorAll(".comma-ai-activity-event");
    expect(rows).toHaveLength(2);
    expect(rows[0]).toBe(firstRow);
    expect(rows[0]).toHaveAttribute("data-settled", "true");
    expect(rows[1]).toHaveAttribute("data-entered", "false");
    expect(rows[1]).toHaveStyle({ "--ai-activity-event-height": "20px" });
    expect(requestFrame).toHaveBeenCalled();

    act(() => {
      for (let frame = 0; frame < 4 && frames.length > 0; frame += 1) {
        const pending = frames.splice(0);
        pending.forEach((callback) => callback(frame * 16));
      }
    });
    expect(rows[1]).toHaveAttribute("data-entered", "true");
    fireEvent.transitionEnd(rows[1]!, { propertyName: "height" });
    expect(rows[1]).toHaveAttribute("data-settled", "true");

    requestFrame.mockRestore();
    bounds.mockRestore();
  });

  it("announces safe errors and hides uncommitted results", () => {
    render(
      <AiActivity
        activityKey="error"
        phase="execution"
        result={<p>Private diagnostic</p>}
        status="failed"
        summary="The tool could not complete"
      />
    );

    expect(screen.getByRole("alert")).toHaveTextContent("The tool could not complete");
    expect(screen.queryByText("Private diagnostic")).not.toBeInTheDocument();
  });
});
