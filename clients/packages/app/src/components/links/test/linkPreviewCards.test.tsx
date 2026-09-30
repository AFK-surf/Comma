import { initializeCommaI18n } from "@comma/i18n";
import { render, screen } from "@comma/test-utils/render";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CommaRecommendationLinkPreview } from "../../../api";
import {
  isPrivateMailLink,
  LinkPreviewCard,
  providerFromHref,
} from "../linkPreviewCards";

afterEach(() => {
  vi.restoreAllMocks();
  initializeCommaI18n(["en"]);
});

// Card times are relative within the local day only; pin "now" to a local
// noon so "2h ago" cannot roll into "yesterday" on CI.
const pinNoon = () =>
  vi.spyOn(Date, "now").mockReturnValue(new Date(2026, 7, 22, 12).getTime());

const slackMessagePreview = {
  author: { avatarUrl: null, name: "Dana Wu" },
  channel: { id: "C01234567", name: "eng-core" },
  href: "https://comma-local.slack.com/archives/C01234567/p1786900000000000",
  kind: "slack_message",
  postedAt: new Date(2026, 7, 22, 10).getTime(),
  text: "Deploy is green — canary at 2% and holding. Rollout continues after lunch.",
} satisfies CommaRecommendationLinkPreview;

const driveFilePreview = {
  fileKind: "spreadsheet",
  href: "https://docs.google.com/spreadsheets/d/1AbC_dEf-9/edit",
  kind: "google_drive_file",
  modifiedAt: new Date(2026, 7, 22, 9).getTime(),
  owner: { avatarUrl: null, name: "zanwei" },
  size: 48_128,
  title: "Launch metrics",
} satisfies CommaRecommendationLinkPreview;

describe("LinkPreviewCard", () => {
  it("renders a Slack message as channel, clamped excerpt and author", () => {
    pinNoon();
    render(
      <LinkPreviewCard
        preview={slackMessagePreview}
        source={{ appId: "slack", appName: "Slack" }}
      />
    );

    const card = screen.getByTestId("recommendation-link-card");
    expect(card).toHaveAttribute("data-kind", "slack_message");
    expect(card).toHaveTextContent("#eng-core");
    expect(card).toHaveTextContent("2h ago");
    expect(
      card.querySelector(".comma-recommendation-link-card-excerpt")
    ).toHaveTextContent("Deploy is green — canary at 2% and holding.");
    const author = card.querySelector(".comma-recommendation-link-card-person");
    expect(author).toHaveTextContent("Dana Wu");
    expect(author).toHaveAttribute("title", "From: Dana Wu");
    expect(card.querySelector('svg[data-provider-logo="slack"]')).not.toBeNull();
    // No workflow state to pill for a message.
    expect(card.querySelector(".comma-recommendation-link-card-state")).toBeNull();
  });

  it("falls back to the channel id and drops the author row when Slack shares neither", () => {
    render(
      <LinkPreviewCard
        preview={{
          ...slackMessagePreview,
          author: null,
          channel: { id: "C01234567", name: null },
          postedAt: null,
        }}
      />
    );

    const card = screen.getByTestId("recommendation-link-card");
    expect(card).toHaveTextContent("#C01234567");
    expect(card.querySelector(".comma-recommendation-link-card-person")).toBeNull();
    expect(card.querySelector("time")).toBeNull();
  });

  it("renders a Google Drive file as kind, title and owner", () => {
    pinNoon();
    render(
      <LinkPreviewCard
        preview={driveFilePreview}
        source={{ appId: "googledrive", appName: "Google Drive" }}
      />
    );

    const card = screen.getByTestId("recommendation-link-card");
    expect(card).toHaveAttribute("data-kind", "google_drive_file");
    expect(card).toHaveTextContent("Spreadsheet");
    expect(card).toHaveTextContent("3h ago");
    expect(card).toHaveTextContent("Launch metrics");
    const owner = card.querySelector(".comma-recommendation-link-card-person");
    expect(owner).toHaveTextContent("zanwei");
    expect(owner).toHaveAttribute("title", "Owner: zanwei");
    expect(card.querySelector('svg[data-provider-logo="google-drive"]')).not.toBeNull();
  });

  it("labels every Drive file kind", () => {
    const labels = {
      document: "Document",
      file: "File",
      folder: "Folder",
      form: "Form",
      pdf: "PDF",
      presentation: "Presentation",
      spreadsheet: "Spreadsheet",
    } as const;
    for (const [fileKind, label] of Object.entries(labels)) {
      const { unmount } = render(
        <LinkPreviewCard
          preview={{
            ...driveFilePreview,
            fileKind: fileKind as keyof typeof labels,
            owner: null,
          }}
        />
      );
      expect(screen.getByTestId("recommendation-link-card")).toHaveTextContent(label);
      unmount();
    }
  });
});

describe("providerFromHref", () => {
  it("names the provider for every rich link host and nothing else", () => {
    expect(providerFromHref("https://github.com/AFK-surf/Comma/pull/845")).toEqual({
      appId: "github",
      appName: "GitHub",
    });
    expect(providerFromHref("https://linear.app/comma/issue/COMMA-143")).toEqual({
      appId: "linear",
      appName: "Linear",
    });
    expect(
      providerFromHref("https://www.notion.so/comma/Q3-plan-4b8e7d0d9f1a4ed89d6b")
    ).toEqual({ appId: "notion", appName: "Notion" });
    expect(
      providerFromHref("https://calendar.google.com/calendar/u/0/r/eventedit/ZXZ0")
    ).toEqual({ appId: "googlecalendar", appName: "Google Calendar" });
    expect(providerFromHref("https://www.google.com/calendar/event?eid=ZXZ0")).toEqual({
      appId: "googlecalendar",
      appName: "Google Calendar",
    });
    expect(
      providerFromHref(
        "https://comma-local.slack.com/archives/C01234567/p1786900000000000"
      )
    ).toEqual({ appId: "slack", appName: "Slack" });
    expect(
      providerFromHref("https://docs.google.com/document/d/1AbC_dEf-9/edit")
    ).toEqual({ appId: "googledrive", appName: "Google Drive" });
    expect(providerFromHref("https://drive.google.com/open?id=1AbC_dEf-9")).toEqual({
      appId: "googledrive",
      appName: "Google Drive",
    });

    expect(providerFromHref("https://example.com/pull/845")).toBeUndefined();
    expect(providerFromHref("https://www.google.com/search?q=comma")).toBeUndefined();
    expect(providerFromHref("not a url")).toBeUndefined();
  });
});

describe("isPrivateMailLink", () => {
  it("treats Gmail sources and mail.google.com links as private", () => {
    expect(isPrivateMailLink("https://example.com/thread/1", { appId: "gmail" })).toBe(
      true
    );
    expect(isPrivateMailLink("https://mail.google.com/mail/#all/198f2ab4")).toBe(true);
    expect(
      isPrivateMailLink("https://github.com/AFK-surf/Comma/pull/845", {
        appId: "github",
      })
    ).toBe(false);
    expect(isPrivateMailLink("https://github.com/AFK-surf/Comma/pull/845")).toBe(false);
    expect(isPrivateMailLink("not a url")).toBe(false);
  });
});
