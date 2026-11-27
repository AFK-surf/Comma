import { initializeCommaI18n } from "@comma/i18n";
import { flush } from "@comma/test-utils/fake-clock";
import { render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CommaRecommendationLinkPreview } from "@comma/core/api-schemas";
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
  it("renders an Outlook event start as a localized time, not Graph's raw string", () => {
    const startsAt = Date.UTC(2026, 9, 6, 9);
    render(
      <LinkPreviewCard
        preview={{
          excerpt: "Agenda",
          href: "https://outlook.office.com/calendar/item/AAEv1",
          kind: "outlook_event",
          sender: null,
          startsAt,
          title: "Planning",
        }}
      />
    );

    const card = screen.getByTestId("recommendation-link-card");
    expect(card).toHaveTextContent("Planning");
    expect(card).toHaveTextContent("Agenda");
    expect(card).not.toHaveTextContent("2026-10-06T09:00");
    expect(card.querySelector("time")).toHaveAttribute(
      "datetime",
      new Date(startsAt).toISOString()
    );
  });

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

  it("renders an Outlook message with sender, received time, excerpt, logo, and click hint", () => {
    pinNoon();
    render(
      <LinkPreviewCard
        preview={{
          kind: "outlook_message",
          href: "https://outlook.live.com/owa/?ItemID=AAMk1",
          title: "Q4 Invoice",
          excerpt: "Your invoice is due Friday.",
          sender: "Billing <billing@example.com>",
          recipients: "peng@example.com",
          receivedAt: new Date(2026, 7, 22, 10).getTime(),
          body: "Hello Peng, your invoice is due Friday.",
          startsAt: null,
        }}
      />
    );

    const card = screen.getByTestId("recommendation-link-card");
    expect(card).toHaveAttribute("data-kind", "outlook_message");
    expect(card).toHaveTextContent("Billing <billing@example.com>");
    expect(card).toHaveTextContent("2h ago");
    expect(card).toHaveTextContent("Q4 Invoice");
    expect(card).toHaveTextContent("Your invoice is due Friday.");
    expect(card).toHaveTextContent("Click to read email");
    expect(card.querySelector('svg[data-provider-logo="outlook"]')).not.toBeNull();
  });

  it("renders a Gmail message with sender, received time, excerpt, logo, and click hint", () => {
    pinNoon();
    render(
      <LinkPreviewCard
        preview={{
          kind: "gmail_message",
          href: "https://mail.google.com/mail/u/0/#inbox/198f2ab4",
          title: "Launch approval",
          excerpt: "Can you sign off before 5pm?",
          sender: "Dana Wu <dana@example.com>",
          recipients: "peng@example.com",
          receivedAt: new Date(2026, 7, 22, 11).getTime(),
          body: "Hi Peng, can you sign off before 5pm?",
        }}
      />
    );

    const card = screen.getByTestId("recommendation-link-card");
    expect(card).toHaveAttribute("data-kind", "gmail_message");
    expect(card).toHaveTextContent("Dana Wu <dana@example.com>");
    expect(card).toHaveTextContent("1h ago");
    expect(card).toHaveTextContent("Launch approval");
    expect(card).toHaveTextContent("Can you sign off before 5pm?");
    expect(card).toHaveTextContent("Click to read email");
    expect(card.querySelector('svg[data-provider-logo="gmail"]')).not.toBeNull();
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
    expect(providerFromHref("https://outlook.live.com/owa/?ItemID=AAMk1")).toEqual({
      appId: "outlook",
      appName: "Outlook",
    });
    expect(providerFromHref("https://outlook.office.com/mail/id/AAMk1")).toEqual({
      appId: "outlook",
      appName: "Outlook",
    });
    expect(providerFromHref("https://outlook.office365.com/mail/id/AAMk1")).toEqual({
      appId: "outlook",
      appName: "Outlook",
    });
    expect(providerFromHref("https://mail.google.com/mail/u/0/#inbox/m1")).toEqual({
      appId: "gmail",
      appName: "Gmail",
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

const pullRequestPreview = {
  additions: 12,
  author: {
    avatarRef: "v1.YQ.Yg",
    avatarUrl: "https://avatars.githubusercontent.com/u/1?v=4",
    login: "CatsJuice",
  },
  changedFiles: 3,
  deletions: 4,
  href: "https://github.com/AFK-surf/Comma/pull/845",
  kind: "github_pull_request",
  number: 845,
  repository: "AFK-surf/Comma",
  state: "merged",
  title: "feat(chat): add inline task elements",
  updatedAt: new Date(2026, 7, 22, 10).getTime(),
} satisfies CommaRecommendationLinkPreview;

describe("LinkCardPerson", () => {
  it("reads a pull request author's avatar through the core by the preview's reference", async () => {
    pinNoon();
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:avatar");
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined);
    const core = createScriptedCore({
      calls: (name) =>
        name === "files.read"
          ? { bytes: new Uint8Array([137, 80, 78, 71]), type: "image/png" }
          : null,
    });
    render(
      core.wrap(
        <LinkPreviewCard
          preview={pullRequestPreview}
          source={{ appId: "github", appName: "GitHub" }}
        />
      )
    );
    await flush();

    expect(core.sentTo("files.read")).toEqual([
      { source: "link-preview-avatar", ref: "v1.YQ.Yg" },
    ]);
    const card = screen.getByTestId("recommendation-link-card");
    expect(card).toHaveTextContent("CatsJuice");
    expect(
      card.querySelector(".comma-recommendation-link-card-avatar img")
    ).toHaveAttribute("src", "blob:avatar");
  });

  it("stands the author's initials in for an avatar the preview does not carry", async () => {
    pinNoon();
    const core = createScriptedCore({});
    render(
      core.wrap(
        <LinkPreviewCard
          preview={{
            ...pullRequestPreview,
            author: { avatarRef: null, avatarUrl: null, login: "CatsJuice" },
          }}
        />
      )
    );
    await flush();

    const avatar = screen
      .getByTestId("recommendation-link-card")
      .querySelector(".comma-recommendation-link-card-avatar");
    expect(avatar).toHaveTextContent("C");
    expect(avatar?.querySelector("img")).toBeNull();
    expect(core.sentTo("files.read")).toEqual([]);
  });

  it("renders a still.fail chat preview with status, station name, latest excerpt, and brand icon", () => {
    render(
      <LinkPreviewCard
        preview={{
          kind: "stillfail_chat",
          href: "https://app.youdid.wtf/o/ws/st-1/chat%3Ac-1",
          ref: "station:st-1:chat:c-1",
          title: "Duo monoid 发热排查",
          stationName: "pengx17",
          status: "need",
          note: "决定是否重签重装",
          updatedAt: null,
          offline: false,
          messages: [
            {
              seq: 1,
              authorKind: "agent",
              author: "agent",
              text: "定位到轮询间隔太短，已修完并通过单测。",
              createdAt: null,
              card: {
                type: "options",
                choice: null,
                closed: false,
                options: ["重签并安装", "先不装"],
              },
            },
          ],
        }}
      />
    );

    const card = screen.getByTestId("recommendation-link-card");
    expect(card).toHaveAttribute("data-kind", "stillfail_chat");
    expect(card).toHaveTextContent("Waiting for you");
    expect(card).toHaveTextContent("pengx17");
    expect(card).toHaveTextContent("Duo monoid 发热排查");
    expect(card).toHaveTextContent("定位到轮询间隔太短，已修完并通过单测。");
    expect(card.querySelector('svg[data-provider-logo="stillfail"]')).not.toBeNull();
    expect(providerFromHref("https://app.youdid.wtf/o/ws/st-1/chat%3Ac-1")).toEqual({
      appId: "stillfail",
      appName: "still.fail",
    });
    expect(providerFromHref("https://still.fail/o/ws/st-1/chat%3Ac-1")).toEqual({
      appId: "stillfail",
      appName: "still.fail",
    });
  });
});
