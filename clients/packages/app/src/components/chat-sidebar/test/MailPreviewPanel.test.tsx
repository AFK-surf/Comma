import { initializeCommaI18n } from "@comma/i18n";
import { flush } from "@comma/test-utils/fake-clock";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { LinkPreview, LinkPreviewValue } from "@comma/core/contract";
import { MailPreviewPanel } from "../MailPreviewPanel";

const openExternalSpy = vi.fn();

vi.mock("../../chat/thread/inline/linkActions", () => ({
  openUrlInExternalBrowser: (...args: unknown[]) => openExternalSpy(...args),
}));

const outlookPreview: LinkPreview = {
  kind: "outlook_message",
  href: "https://outlook.live.com/owa/?ItemID=AAMk1",
  title: "Q4 Cloud Invoice #4821",
  excerpt: "Your invoice is due on Nov 30.",
  sender: "Billing Team <billing@example.com>",
  recipients: "peng@example.com",
  receivedAt: Date.UTC(2026, 10, 25, 6, 30),
  body: "Hello Peng,\n\nYour invoice #4821 for $142.00 is ready.\nPlease pay by Nov 30.",
  startsAt: null,
};

const gmailPreview: LinkPreview = {
  kind: "gmail_message",
  href: "https://mail.google.com/mail/u/0/#inbox/198f2ab4c7d3e011",
  title: "Launch approval needed",
  excerpt: "Can you sign off before 5pm?",
  sender: "Dana Wu <dana@example.com>",
  recipients: "peng@example.com",
  receivedAt: Date.UTC(2026, 10, 25, 7, 0),
  body: "Hi Peng,\n\nEverything is green in staging. Can you sign off before 5pm?",
};

afterEach(() => {
  openExternalSpy.mockReset();
  initializeCommaI18n(["en"]);
});

describe("MailPreviewPanel", () => {
  it("renders Outlook message details, propagates title, refreshes, and opens external link", async () => {
    const onTitleChange = vi.fn();
    const asked: Record<string, unknown>[] = [];
    const value: LinkPreviewValue = {
      status: "ready",
      preview: outlookPreview,
    };
    const core = createScriptedCore({
      values: (topic) => (topic.topic === "linkPreview" ? value : undefined),
      onSubscribe: (topic) => {
        if (topic.topic === "linkPreview") asked.push(topic);
      },
    });

    render(
      core.wrap(
        <MailPreviewPanel
          active
          onTitleChange={onTitleChange}
          preview={{
            id: outlookPreview.href,
            href: outlookPreview.href,
            workspaceId: "wsp-1",
          }}
        />
      )
    );
    await flush();

    const panel = screen.getByTestId("mail-preview-panel");
    expect(panel).toHaveTextContent("Q4 Cloud Invoice #4821");
    expect(panel).toHaveTextContent("Outlook");
    expect(panel).toHaveTextContent("Billing Team <billing@example.com>");
    expect(panel).toHaveTextContent("peng@example.com");
    expect(panel).toHaveTextContent("Your invoice #4821 for $142.00 is ready.");
    expect(onTitleChange).toHaveBeenCalledWith("Q4 Cloud Invoice #4821");

    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    await flush();
    expect(asked.some((t) => t.topic === "linkPreview" && t.read === "1")).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "Open in Outlook" }));
    expect(openExternalSpy).toHaveBeenCalledWith(outlookPreview.href);
  });

  it("renders Gmail message details and opens Gmail externally", async () => {
    const value: LinkPreviewValue = {
      status: "ready",
      preview: gmailPreview,
    };
    const core = createScriptedCore({
      values: (topic) => (topic.topic === "linkPreview" ? value : undefined),
    });

    render(
      core.wrap(
        <MailPreviewPanel
          active
          preview={{
            id: gmailPreview.href,
            href: gmailPreview.href,
            workspaceId: "wsp-1",
          }}
        />
      )
    );
    await flush();

    const panel = screen.getByTestId("mail-preview-panel");
    expect(panel).toHaveTextContent("Launch approval needed");
    expect(panel).toHaveTextContent("Gmail");
    expect(panel).toHaveTextContent("Dana Wu <dana@example.com>");
    expect(panel).toHaveTextContent(
      "Everything is green in staging. Can you sign off before 5pm?"
    );

    fireEvent.click(screen.getByRole("button", { name: "Open in Gmail" }));
    expect(openExternalSpy).toHaveBeenCalledWith(gmailPreview.href);
  });

  it("shows unavailable notice with external link fallback when preview is missing", async () => {
    const core = createScriptedCore({
      values: (topic) =>
        topic.topic === "linkPreview" ? { status: "missing" } : undefined,
    });

    render(
      core.wrap(
        <MailPreviewPanel
          active
          preview={{
            id: outlookPreview.href,
            href: outlookPreview.href,
            workspaceId: "wsp-1",
          }}
        />
      )
    );
    await flush();

    const panel = screen.getByTestId("mail-preview-panel");
    expect(panel).toHaveTextContent("Couldn't load this email.");
    const buttons = screen.getAllByRole("button", { name: "Open in Outlook" });
    fireEvent.click(buttons[buttons.length - 1]!);
    expect(openExternalSpy).toHaveBeenCalledWith(outlookPreview.href);
  });
});
