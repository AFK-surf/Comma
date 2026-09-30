import { describe, expect, it } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import { ChatPanel } from "../ChatPanel";

describe("ChatPanel", () => {
  it("renders header, messages, permission actions, and the AI input", () => {
    const { container } = render(
      <ChatPanel
        messages={[
          {
            id: "user",
            kind: "user",
            content: "Review this screen",
            attachments: [{ id: "file", label: "Openai.pdf" }],
          },
          { id: "tool", kind: "tool", content: "Thinking" },
          { id: "permission", kind: "permission", content: "Authorize Comma" },
        ]}
        subtitle="Mac mini"
        title="Summarize recent updates"
      />
    );

    expect(screen.getByText("Summarize recent updates")).toBeInTheDocument();
    expect(screen.getByText("Mac mini")).toBeInTheDocument();
    const filePill = screen.getByText("Openai.pdf").parentElement;
    const fileIconSurface = filePill?.querySelector('[data-slot="file-icon-surface"]');
    expect(filePill).toHaveClass("bg-popup-secondary");
    expect(filePill).not.toHaveClass("bg-panel-bg-file");
    expect(fileIconSurface).toHaveClass("bg-panel-bg-file");
    expect(screen.getByText("Review this screen")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Approve" })).toBeInTheDocument();
    expect(screen.getByLabelText("AI prompt")).toBeInTheDocument();

    const panel = container.querySelector("section");
    const messageScroll = container.querySelector(
      '[data-slot="chat-panel-message-scroll"]'
    );
    const scrollArea = messageScroll?.querySelector('[data-slot="scroll-area"]');
    const userBubble = container.querySelector('[data-slot="chat-panel-user-bubble"]');
    const inputShell = screen.getByLabelText("AI prompt").closest(".shadow-xs");

    expect(panel).toHaveClass("size-full", "min-h-0", "bg-main-panel-bg");
    expect(panel).not.toHaveClass("min-h-[1008px]");
    expect(userBubble).toHaveClass("px-lg", "py-md");
    expect(inputShell).toBeInTheDocument();
    expect(messageScroll).toBeInTheDocument();
    expect(scrollArea).toHaveAttribute("data-orientation", "vertical");
    expect(scrollArea).toHaveAttribute("data-edge-effect", "none");
  });
});
