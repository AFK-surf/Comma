import type {
  RecommendationAction,
  RecommendationDocumentPart,
  RecommendationEnvelope,
  RecommendationGeneratedCard,
} from "@comma/recommendation-contract";
import previewImage from "../../../../ui/src/components/chat-panel/assets/generated-image-preview.png";
import type { CommaApiClient } from "../../api";
import type React from "react";
import "../../styles.css";
import {
  RecommendationCardView,
  RecommendationMediaListCard,
  RecommendationRail,
  RecommendationLinkPreviewProvider,
  RecommendationSummary,
  RecommendationTextListCard,
} from "./RecommendationRail";

const noop = () => undefined;
const performAction = (_action: RecommendationAction) => undefined;
const previewImageUrl = new URL(previewImage, window.location.href).href;

// A routine card: one source, a stable id, the app's own name as title, and
// pre-task rows - the thing you would hand to Comma next, phrased like a Task
// title with the entity chip inside; the row's action is that task.
const textListCard = {
  fallbackText: "Review PR #365 and PR #375; Check Comma/repo status",
  footerAction: {
    label: "Check Comma/repo status",
    prompt: "Check Comma/repo status",
    requiresConfirmation: false,
    type: "open_task_form",
  },
  id: "github",
  items: [
    {
      action: {
        label: "Review #365",
        prompt:
          "Dana asked for your review before the release cut. Review AFK-surf/Comma #365.",
        requiresConfirmation: true,
        type: "send_to_comma",
      },
      id: "review-365",
      parts: [
        { kind: "markdown", text: "Review AFK-surf/Comma " },
        {
          kind: "inline-link",
          link: {
            href: "https://github.com/AFK-surf/Comma/pull/365",
            label: "#365",
            sourceId: "github",
          },
        },
        { kind: "markdown", text: " before the release cut" },
      ],
    },
    {
      action: {
        label: "Give #375 a final look",
        prompt:
          "CI went green overnight; it only needs a final look. Review AFK-surf/Comma #375.",
        requiresConfirmation: true,
        type: "send_to_comma",
      },
      id: "review-375",
      parts: [
        { kind: "markdown", text: "Give AFK-surf/Comma " },
        {
          kind: "inline-link",
          link: {
            href: "https://github.com/AFK-surf/Comma/pull/375",
            label: "#375",
            sourceId: "github",
          },
        },
        { kind: "markdown", text: " a final look" },
      ],
    },
  ],
  sourceIds: ["github"],
  template: "text-list@1",
  title: "GitHub",
} satisfies RecommendationGeneratedCard;

const mediaListCard = {
  fallbackText: "What's news today; News of OpenAI and Anthropic",
  id: "website-report",
  items: [
    {
      action: {
        href: "https://openai.com/news/",
        label: "Open article",
        requiresConfirmation: false,
        type: "open_url",
      },
      description: "Collect the latest updates on various AI products and research.",
      id: "news-today",
      imageUrl: previewImageUrl,
      title: "What’s news today",
    },
    {
      action: {
        href: "https://openai.com/news/",
        label: "Open article",
        requiresConfirmation: false,
        type: "open_url",
      },
      description: "Health iBill would let Homeland Security check AI systems.",
      id: "openai-anthropic",
      imageUrl: previewImageUrl,
      title: "News of OpenAI and Anthropic",
    },
  ],
  sourceIds: ["web"],
  template: "media-list@1",
  title: "Website report",
} satisfies RecommendationGeneratedCard;

// The brief is the ten-second heads-up above the cards, one thought per
// paragraph: the most pressing item first with who/what/when, one citation
// per paragraph. The cards below carry the full list.
const summary = [
  {
    kind: "markdown",
    text: "Good morning, Zanwei.\n\nDana is waiting on your review of ",
  },
  {
    kind: "inline-link",
    link: {
      href: "https://github.com/AFK-surf/Comma/pull/15436",
      label: "#15436",
      sourceId: "github",
    },
  },
  {
    kind: "markdown",
    text: " before this afternoon's release cut.\n\n",
  },
  {
    kind: "inline-task",
    task: {
      conversationId: "comma-143",
      label: "COMMA-143",
      sourceId: "linear",
    },
  },
  {
    kind: "markdown",
    text: " moved into review too. Worth a look right after the PR, while the context is fresh.\n\nNothing else needs you before ",
  },
  {
    kind: "inline-link",
    link: {
      href: "https://calendar.google.com",
      label: "Comma Team’s Meeting",
      sourceId: "google-calendar",
    },
  },
  { kind: "markdown", text: " at 3pm, so the morning is yours." },
] satisfies RecommendationDocumentPart[];

const envelope = {
  settings: {
    autoEnableNewSources: true,
    schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
    sourceRevision: 1,
    sources: [
      {
        appId: "linear",
        appName: "Linear",
        connectionId: "linear",
        enabled: true,
        kind: "composio",
        label: "Linear",
      },
      {
        appId: "github",
        appName: "GitHub",
        connectionId: "github",
        enabled: true,
        kind: "native_mcp_oauth",
        label: "GitHub",
      },
      {
        appId: "google-calendar",
        appName: "Google Calendar",
        connectionId: "google-calendar",
        enabled: true,
        kind: "composio",
        label: "Google Calendar",
      },
    ],
    sourcesCheckedAt: "2026-08-17T03:00:00.000Z",
  },
  snapshot: {
    cards: [textListCard, mediaListCard],
    generatedAt: 1_786_935_660_543,
    generation: 1,
    protocolVersion: 1,
    sourceRevision: 1,
    summary,
    templateCatalogVersion: 1,
    warnings: [],
  },
  state: "fresh",
} satisfies RecommendationEnvelope;

// Hovering the PR inline link resolves this through the workspace API.
const pullRequestPreview = {
  additions: 12_593,
  author: { avatarUrl: null, login: "CatsJuice" },
  changedFiles: 147,
  deletions: 829,
  href: "https://github.com/AFK-surf/Comma/pull/845",
  kind: "github_pull_request" as const,
  number: 845,
  repository: "AFK-surf/Comma",
  state: "merged" as const,
  title: "feat(chat): add inline task elements",
  updatedAt: Date.now() - 8 * 24 * 60 * 60_000,
};

const linearIssuePreview = {
  assignee: { avatarUrl: null, name: "zanwei" },
  href: "https://linear.app/comma/issue/COMMA-143",
  identifier: "COMMA-143",
  kind: "linear_issue" as const,
  priority: 2,
  priorityLabel: "High",
  project: "Launch",
  state: { color: "#f2c94c", name: "In Progress", type: "started" as const },
  team: "COMMA",
  title: "Fix onboarding crash on first launch",
  updatedAt: Date.now() - 3 * 60 * 60_000,
};

const notionPagePreview = {
  archived: false,
  createdAt: Date.now() - 21 * 24 * 60 * 60_000,
  href: "https://www.notion.so/comma/Q3-plan-4b8e7d0d9f1a4ed89d6ba8d11080a812",
  icon: "🗺️",
  kind: "notion_page" as const,
  parent: "database" as const,
  title: "Q3 plan",
  updatedAt: Date.now() - 26 * 60 * 60_000,
};

const calendarEventPreview = {
  allDay: false,
  attendeeCount: 6,
  endsAt: Date.now() + 5 * 60 * 60_000 + 45 * 60_000,
  href: "https://www.google.com/calendar/event?eid=ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA",
  kind: "google_calendar_event" as const,
  location: "Room 4",
  meetingUrl: "https://meet.google.com/abc-defg-hij",
  organizer: { name: "Dana Wu" },
  startsAt: Date.now() + 5 * 60 * 60_000,
  status: "confirmed" as const,
  title: "Launch review",
  updatedAt: Date.now() - 60 * 60_000,
};

const slackMessagePreview = {
  author: { avatarUrl: null, name: "Dana Wu" },
  channel: { id: "C01234567", name: "eng-core" },
  href: "https://comma-local.slack.com/archives/C01234567/p1786900000000000",
  kind: "slack_message" as const,
  postedAt: Date.now() - 2 * 60 * 60_000,
  text: "Deploy is green — canary at 2% and holding. Rollout continues after lunch; ping me if the error budget moves.",
};

const driveFilePreview = {
  fileKind: "spreadsheet" as const,
  href: "https://docs.google.com/spreadsheets/d/1AbC_dEf-9/edit",
  kind: "google_drive_file" as const,
  modifiedAt: Date.now() - 5 * 60 * 60_000,
  owner: { avatarUrl: null, name: "zanwei" },
  size: 48_128,
  title: "Launch metrics",
};

const railApi = (railEnvelope: RecommendationEnvelope) =>
  ({
    getRecommendationLinkPreview: async (
      _workspaceId: string,
      link: { href: string }
    ) => {
      if (link.href.includes("linear.app/"))
        return { ...linearIssuePreview, href: link.href };
      if (link.href.includes("notion.so/"))
        return { ...notionPagePreview, href: link.href };
      if (link.href.includes("calendar/event")) {
        return { ...calendarEventPreview, href: link.href };
      }
      if (link.href.includes(".slack.com/archives/"))
        return { ...slackMessagePreview, href: link.href };
      if (
        link.href.includes("docs.google.com/") ||
        link.href.includes("drive.google.com/")
      ) {
        return { ...driveFilePreview, href: link.href };
      }
      if (/\/pull\/\d+/.test(link.href)) {
        return {
          ...pullRequestPreview,
          href: link.href,
          number: Number(
            /\/pull\/(\d+)/.exec(link.href)?.[1] ?? pullRequestPreview.number
          ),
        };
      }
      throw new Error("no preview");
    },
    getRecommendations: async () => railEnvelope,
    refreshRecommendations: async () => ({
      envelope: railEnvelope,
      run: { id: "run-1" },
    }),
  }) as unknown as CommaApiClient;
const api = railApi(envelope);

// Nothing connected yet (Figma 1204:13306): sample app marks, copy and the
// "Connect apps" action, centered like the Tasks rail's "No tasks".
const emptyEnvelope = {
  settings: { ...envelope.settings, sources: [] },
  snapshot: null,
  state: "fresh",
} satisfies RecommendationEnvelope;
// Sources connected, first briefing still being generated (Figma 1204:13307):
// the connected apps' marks above the shining "Generating your briefing…".
const generatingEnvelope = {
  settings: envelope.settings,
  snapshot: null,
  state: "refreshing",
} satisfies RecommendationEnvelope;
// Generation failed (Figma 1205:13333): copy and a "Try again" action that
// runs a refresh.
const unavailableEnvelope = {
  settings: envelope.settings,
  snapshot: null,
  state: "error",
} satisfies RecommendationEnvelope;
// Sources connected, nothing generated yet: prompt to refresh.
const readyEnvelope = {
  settings: envelope.settings,
  snapshot: null,
  state: "fresh",
} satisfies RecommendationEnvelope;

const RailFrame = ({ children }: { children: React.ReactNode }) => (
  <div
    style={{
      blockSize: 820,
      display: "flex",
      inlineSize: 350,
    }}
  >
    {children}
  </div>
);

export default {
  title: "App components/Recommendations",
  component: RecommendationCardView,
  parameters: {
    layout: "centered",
    docs: {
      description: {
        component:
          "Comma Center recommendation templates and rail composition. Card examples follow the Comma-App sidebar reference; the summary follows Figma node 929:13114.",
      },
    },
  },
};

export const MediaList = {
  render: () => (
    <div style={{ inlineSize: 318 }}>
      <RecommendationMediaListCard card={mediaListCard} onAction={performAction} />
    </div>
  ),
};

export const TextList = {
  render: () => (
    <div style={{ inlineSize: 318 }}>
      <RecommendationTextListCard
        card={textListCard}
        onAction={performAction}
        onOpenTask={noop}
        onOpenUrl={noop}
        sources={envelope.settings.sources}
      />
    </div>
  ),
};

export const Summary = {
  render: () => (
    <RecommendationLinkPreviewProvider api={api} workspaceId="wsp_story">
      <div style={{ inlineSize: 350 }}>
        <RecommendationSummary
          fallbackTitle="Good morning."
          onOpenTask={noop}
          onOpenUrl={noop}
          parts={summary}
          sources={envelope.settings.sources}
        />
      </div>
    </RecommendationLinkPreviewProvider>
  ),
};

// One inline link per rich preview kind, plus a Gmail link that gets no hover
// card at all (mail is private). Hover each chip.
export const LinkPreviews = {
  render: () => (
    <RecommendationLinkPreviewProvider api={api} workspaceId="wsp_story">
      <div style={{ inlineSize: 350 }}>
        <RecommendationSummary
          fallbackTitle="Good morning."
          onOpenTask={noop}
          onOpenUrl={noop}
          parts={[
            { kind: "markdown", text: "Good morning.\n\nGitHub needs your review on " },
            {
              kind: "inline-link",
              link: {
                href: "https://github.com/AFK-surf/Comma/pull/1003",
                label: "#1003",
                sourceId: "github",
              },
            },
            { kind: "markdown", text: ". Linear moved " },
            {
              kind: "inline-link",
              link: {
                href: "https://linear.app/comma/issue/COMMA-143",
                label: "COMMA-143",
                sourceId: "linear",
              },
            },
            { kind: "markdown", text: " to In Progress, the " },
            {
              kind: "inline-link",
              link: {
                href: "https://www.notion.so/comma/Q3-plan-4b8e7d0d9f1a4ed89d6ba8d11080a812",
                label: "Q3 plan",
                sourceId: "notion",
              },
            },
            { kind: "markdown", text: " was edited, and " },
            {
              kind: "inline-link",
              link: {
                href: "https://www.google.com/calendar/event?eid=ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA",
                label: "Launch review",
                sourceId: "googlecalendar",
              },
            },
            { kind: "markdown", text: " starts in five hours. Dana posted " },
            {
              kind: "inline-link",
              link: {
                href: "https://comma-local.slack.com/archives/C01234567/p1786900000000000",
                label: "the deploy update",
                sourceId: "slack",
              },
            },
            { kind: "markdown", text: " in #eng-core, " },
            {
              kind: "inline-link",
              link: {
                href: "https://docs.google.com/spreadsheets/d/1AbC_dEf-9/edit",
                label: "Launch metrics",
                sourceId: "googledrive",
              },
            },
            { kind: "markdown", text: " changed, and Dana’s " },
            {
              kind: "inline-link",
              link: {
                href: "https://mail.google.com/mail/#all/198f2ab4c7d3e011",
                label: "launch approval email",
                sourceId: "gmail",
              },
            },
            { kind: "markdown", text: " is waiting." },
          ]}
          sources={(
            [
              "github",
              "linear",
              "notion",
              "googlecalendar",
              "slack",
              "googledrive",
              "gmail",
            ] as const
          ).map((appId) => ({
            appId,
            appName: {
              github: "GitHub",
              gmail: "Gmail",
              googlecalendar: "Google Calendar",
              googledrive: "Google Drive",
              linear: "Linear",
              notion: "Notion",
              slack: "Slack",
            }[appId],
            connectionId: appId,
            enabled: true,
            kind: "composio" as const,
            label: appId,
          }))}
        />
      </div>
    </RecommendationLinkPreviewProvider>
  ),
};

export const FullRail = {
  render: () => (
    <RailFrame>
      <RecommendationRail
        api={api}
        onOpenTask={noop}
        onOpenUrl={noop}
        onUsePrompt={noop}
        workspaceId="storybook-workspace"
      />
    </RailFrame>
  ),
};

export const EmptyState = {
  render: () => (
    <RailFrame>
      <RecommendationRail
        api={railApi(emptyEnvelope)}
        onConnectApps={noop}
        onOpenTask={noop}
        onOpenUrl={noop}
        onUsePrompt={noop}
        workspaceId="storybook-workspace-empty"
      />
    </RailFrame>
  ),
};

export const Generating = {
  render: () => (
    <RailFrame>
      <RecommendationRail
        api={railApi(generatingEnvelope)}
        onOpenTask={noop}
        onOpenUrl={noop}
        onUsePrompt={noop}
        workspaceId="storybook-workspace-generating"
      />
    </RailFrame>
  ),
};

export const Unavailable = {
  render: () => (
    <RailFrame>
      <RecommendationRail
        api={railApi(unavailableEnvelope)}
        onOpenTask={noop}
        onOpenUrl={noop}
        onUsePrompt={noop}
        workspaceId="storybook-workspace-unavailable"
      />
    </RailFrame>
  ),
};

export const ReadyToGenerate = {
  render: () => (
    <RailFrame>
      <RecommendationRail
        api={railApi(readyEnvelope)}
        onOpenTask={noop}
        onOpenUrl={noop}
        onUsePrompt={noop}
        workspaceId="storybook-workspace-ready"
      />
    </RailFrame>
  ),
};
