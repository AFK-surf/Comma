import type { ChatMessagePart } from "@comma/chat-contract";
import { initializeCommaI18n } from "@comma/i18n";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { MessageMacAppItemCards } from "../MacAppItemCards";

beforeAll(() => {
  initializeCommaI18n(["en"]);
});

const parts: ChatMessagePart[] = [
  { kind: "markdown", text: "Added it." },
  {
    kind: "mac-app-item",
    item: {
      app: "calendar",
      itemId: "E1",
      title: "Design review",
      start: "2026-10-20T10:00:00Z",
      end: "2026-10-20T11:00:00Z",
      calendar: "Work",
      color: "#0088FF",
    },
  },
  {
    kind: "mac-app-item",
    item: {
      app: "reminders",
      itemId: "3C8C2A71-84BF-4C87-8EFD-BB4827650D15",
      title: "Send the weekly report",
      due: "2026-10-23T07:00:00Z",
      list: "Reminders",
    },
  },
];

describe("Mac app cards", () => {
  it("draws each item with its app and opens it there on the Mac", async () => {
    const openItem = vi.fn(async () => ({ opened: true }));
    installNativeBridgeMock({
      os: "macos",
      platform: "electron",
      macApps: { openItem, icons: async () => ({}) },
    } as Parameters<typeof installNativeBridgeMock>[0]);

    render(<MessageMacAppItemCards message={{ parts }} />);

    expect(screen.getByText("Design review")).toBeVisible();
    expect(screen.getByText("Work")).toBeVisible();
    expect(screen.getByText("Send the weekly report")).toBeVisible();

    await userEvent.click(screen.getByRole("button", { name: "Open in Reminders" }));
    expect(openItem).toHaveBeenCalledWith({
      app: "reminders",
      itemId: "3C8C2A71-84BF-4C87-8EFD-BB4827650D15",
      title: "Send the weekly report",
    });
  });

  it("offers no opening outside the Mac", () => {
    installNativeBridgeMock({ platform: "web" } as Parameters<
      typeof installNativeBridgeMock
    >[0]);
    render(<MessageMacAppItemCards message={{ parts }} />);
    expect(screen.getByText("Design review")).toBeVisible();
    expect(screen.queryByRole("button", { name: /Open in/ })).toBeNull();
  });
});
