import {
  type CommaLocale,
  formatDate,
  formatDateRange,
  formatNumber,
  formatRelativeDate,
} from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  CircleCheckIcon,
  CircleDashedIcon,
  CircleInfoIcon,
  CircleXIcon,
  LoaderIcon,
  MergedIcon,
  PullRequestClosedIcon,
  PullRequestIcon,
  PuzzleIcon,
  resolveProviderBrandLogo,
} from "@comma/ui";
import { type ReactNode, useEffect, useState } from "react";
import type { CommaRecommendationLinkPreview } from "../../api";
import { loadRecommendationMedia } from "../recommendations/recommendationMedia";

// One card language for every rich link (Figma 1211-13555 … 1211-13953): a
// tinted state pill (or the provider mark) and a short reference with the
// time on the right; the single-line title (or a clamped excerpt); then the
// person's real avatar and name, and a few facts as chips. Shared by every
// surface that previews inline links — the recommendation rail and chat —
// so the cards only ever depend on the preview payload plus a structural
// source descriptor, never on rail state.

export type { CommaRecommendationLinkPreview };

/**
 * The slice of a connected source the cards actually read.
 * `RecommendationSource` is structurally assignable; chat synthesizes one
 * from its own connection metadata or passes `undefined` — every use falls
 * back (puzzle mark, plain destination).
 */
export type LinkPreviewSourceLike = {
  appId?: string;
  appName?: string;
  iconUrl?: string | null | undefined;
};

export type PullRequestPreview = Extract<
  CommaRecommendationLinkPreview,
  { kind: "github_pull_request" }
>;
export type LinearIssuePreview = Extract<
  CommaRecommendationLinkPreview,
  { kind: "linear_issue" }
>;
export type NotionPagePreview = Extract<
  CommaRecommendationLinkPreview,
  { kind: "notion_page" }
>;
export type CalendarEventPreview = Extract<
  CommaRecommendationLinkPreview,
  { kind: "google_calendar_event" }
>;
export type SlackMessagePreview = Extract<
  CommaRecommendationLinkPreview,
  { kind: "slack_message" }
>;
export type DriveFilePreview = Extract<
  CommaRecommendationLinkPreview,
  { kind: "google_drive_file" }
>;

export function LinkPreviewCard({
  preview,
  source,
}: {
  preview: CommaRecommendationLinkPreview;
  source?: LinkPreviewSourceLike | undefined;
}) {
  switch (preview.kind) {
    case "github_pull_request":
      return <PullRequestPreviewCard preview={preview} source={source} />;
    case "linear_issue":
      return <LinearIssuePreviewCard preview={preview} source={source} />;
    case "notion_page":
      return <NotionPagePreviewCard preview={preview} source={source} />;
    case "google_calendar_event":
      return <CalendarEventPreviewCard preview={preview} />;
    case "slack_message":
      return <SlackMessagePreviewCard preview={preview} source={source} />;
    case "google_drive_file":
      return <DriveFilePreviewCard preview={preview} source={source} />;
  }
}

function LinkCard({
  children,
  kind,
}: {
  children: ReactNode;
  kind: CommaRecommendationLinkPreview["kind"];
}) {
  return (
    <div
      className="comma-recommendation-link-card"
      data-kind={kind}
      data-testid="recommendation-link-card"
    >
      {children}
    </div>
  );
}

// Relative only within today ("6h ago", "in 5h"), then "yesterday" /
// "tomorrow", then the plain date.
function LinkCardTime({ at, locale }: { at: number | null; locale: CommaLocale }) {
  if (at === null) return null;
  return (
    <time
      className="comma-recommendation-link-card-time"
      dateTime={new Date(at).toISOString()}
    >
      {formatRelativeDate(at, locale)}
    </time>
  );
}

// A tinted pill with an 18px Central glyph and the state name; the palette
// is pinned per `data-state` in styles.css.
function LinkCardState({
  children,
  icon,
  state,
}: {
  children: ReactNode;
  icon: ReactNode;
  state: string;
}) {
  return (
    <span className="comma-recommendation-link-card-state" data-state={state}>
      <span aria-hidden="true" className="comma-recommendation-link-card-state-icon">
        {icon}
      </span>
      {children}
    </span>
  );
}

function LinkCardChip({ children, tone }: { children: ReactNode; tone?: "diff" }) {
  return (
    <span
      className="comma-recommendation-link-card-chip"
      {...(tone ? { "data-tone": tone } : {})}
    >
      {children}
    </span>
  );
}

// Provider mark, the person's real avatar and their name. Avatars ride the
// pinned media loader (Electron Main fetches the public image); web, which
// makes no unpinned renderer requests, and failed loads show a neutral disc.
function LinkCardPerson({
  avatarUrl,
  gap,
  name,
  source,
  title,
}: {
  avatarUrl: string | null;
  gap?: "sm";
  name: string;
  source?: LinkPreviewSourceLike | undefined;
  title: string;
}) {
  const safeAvatarUrl = useLinkPreviewMediaUrl(avatarUrl ?? undefined);
  return (
    <span
      className="comma-recommendation-link-card-person"
      title={title}
      {...(gap ? { "data-gap": gap } : {})}
    >
      {source ? (
        <span aria-hidden="true" className="comma-recommendation-link-card-mark">
          <LinkProviderIcon source={source} />
        </span>
      ) : null}
      {safeAvatarUrl ? (
        <img
          alt=""
          className="comma-recommendation-link-card-avatar"
          src={safeAvatarUrl}
        />
      ) : (
        <span aria-hidden="true" className="comma-recommendation-link-card-avatar" />
      )}
      <span className="comma-recommendation-link-card-person-name">{name}</span>
    </span>
  );
}

const pullRequestStateIcons = {
  closed: PullRequestClosedIcon,
  draft: PullRequestIcon,
  merged: MergedIcon,
  open: PullRequestIcon,
} as const satisfies Record<PullRequestPreview["state"], typeof PullRequestIcon>;

function PullRequestPreviewCard({
  preview,
  source,
}: {
  preview: PullRequestPreview;
  source: LinkPreviewSourceLike | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const Icon = pullRequestStateIcons[preview.state];
  const stateLabel = {
    closed: messages.recommendations_pr_state_closed(),
    draft: messages.recommendations_pr_state_draft(),
    merged: messages.recommendations_pr_state_merged(),
    open: messages.recommendations_pr_state_open(),
  }[preview.state];
  const hasDiff = preview.additions !== null || preview.deletions !== null;
  const hasChips = hasDiff || preview.changedFiles !== null;

  return (
    <LinkCard kind="github_pull_request">
      <div className="comma-recommendation-link-card-meta">
        <LinkCardState icon={<Icon />} state={preview.state}>
          {stateLabel}
        </LinkCardState>
        <span className="comma-recommendation-link-card-ref">
          {preview.repository} #{preview.number}
        </span>
        <LinkCardTime at={preview.updatedAt} locale={locale} />
      </div>
      <div className="comma-recommendation-link-card-body">
        <span className="comma-recommendation-link-card-title">{preview.title}</span>
        {preview.author || hasChips ? (
          <div className="comma-recommendation-link-card-facts">
            {preview.author ? (
              <LinkCardPerson
                avatarUrl={preview.author.avatarUrl}
                name={preview.author.login}
                source={source}
                title={messages.recommendations_pr_author({
                  login: preview.author.login,
                })}
              />
            ) : null}
            {hasChips ? (
              <span className="comma-recommendation-link-card-chips">
                {hasDiff ? (
                  <LinkCardChip tone="diff">
                    <span data-tone="additions">
                      +{formatNumber(preview.additions ?? 0, locale)}
                    </span>
                    <span data-tone="deletions">
                      -{formatNumber(preview.deletions ?? 0, locale)}
                    </span>
                  </LinkCardChip>
                ) : null}
                {preview.changedFiles === null ? null : (
                  <LinkCardChip>
                    {messages.recommendations_pr_files({
                      count: formatNumber(preview.changedFiles, locale),
                    })}
                  </LinkCardChip>
                )}
              </span>
            ) : null}
          </div>
        ) : null}
      </div>
    </LinkCard>
  );
}

// Linear workflow states map onto the designed pills by type, with "In
// Review"-style started states getting their own (yellow, info) treatment.
const linearStateIcons = {
  backlog: CircleDashedIcon,
  canceled: CircleXIcon,
  completed: CircleCheckIcon,
  review: CircleInfoIcon,
  started: LoaderIcon,
} as const;

function linearStateKey(
  state: NonNullable<LinearIssuePreview["state"]>
): keyof typeof linearStateIcons {
  switch (state.type) {
    case "completed":
      return "completed";
    case "canceled":
      return "canceled";
    case "started":
      return /review/i.test(state.name) ? "review" : "started";
    default:
      return "backlog";
  }
}

function LinearIssuePreviewCard({
  preview,
  source,
}: {
  preview: LinearIssuePreview;
  source: LinkPreviewSourceLike | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const showPriority = preview.priorityLabel !== null && (preview.priority ?? 0) > 0;
  const stateKey = preview.state ? linearStateKey(preview.state) : undefined;
  const StateIcon = stateKey ? linearStateIcons[stateKey] : undefined;

  return (
    <LinkCard kind="linear_issue">
      <div className="comma-recommendation-link-card-meta">
        {preview.state && stateKey && StateIcon ? (
          <LinkCardState icon={<StateIcon />} state={stateKey}>
            {preview.state.name}
          </LinkCardState>
        ) : null}
        <span className="comma-recommendation-link-card-ref">
          {preview.identifier}
          {preview.project ? ` · ${preview.project}` : ""}
        </span>
        <LinkCardTime at={preview.updatedAt} locale={locale} />
      </div>
      <div className="comma-recommendation-link-card-body">
        <span className="comma-recommendation-link-card-title">{preview.title}</span>
        {preview.assignee || showPriority ? (
          <div className="comma-recommendation-link-card-facts">
            {preview.assignee ? (
              <LinkCardPerson
                avatarUrl={preview.assignee.avatarUrl}
                name={preview.assignee.name}
                source={source}
                title={messages.recommendations_link_assignee({
                  name: preview.assignee.name,
                })}
              />
            ) : null}
            {showPriority ? (
              <span className="comma-recommendation-link-card-chips">
                <LinkCardChip>{preview.priorityLabel}</LinkCardChip>
              </span>
            ) : null}
          </div>
        ) : null}
      </div>
    </LinkCard>
  );
}

function NotionPagePreviewCard({
  preview,
  source,
}: {
  preview: NotionPagePreview;
  source: LinkPreviewSourceLike | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const parentLabel = {
    database: messages.recommendations_notion_database_page(),
    page: messages.recommendations_notion_subpage(),
    workspace: messages.recommendations_notion_page(),
  }[preview.parent];

  return (
    <LinkCard kind="notion_page">
      <div className="comma-recommendation-link-card-meta">
        <span aria-hidden="true" className="comma-recommendation-link-card-mark">
          <LinkProviderIcon source={source} />
        </span>
        <span className="comma-recommendation-link-card-ref">
          {source?.appName ?? "Notion"} · {parentLabel}
        </span>
        <LinkCardTime at={preview.updatedAt} locale={locale} />
      </div>
      <div className="comma-recommendation-link-card-body">
        <span className="comma-recommendation-link-card-title">
          {preview.icon ? (
            <span aria-hidden="true" className="comma-recommendation-link-card-emoji">
              {preview.icon}
            </span>
          ) : null}
          {preview.title}
        </span>
        {preview.archived ? (
          <div className="comma-recommendation-link-card-facts">
            <span className="comma-recommendation-link-card-chips">
              <LinkCardChip>{messages.recommendations_notion_archived()}</LinkCardChip>
            </span>
          </div>
        ) : null}
      </div>
    </LinkCard>
  );
}

function CalendarEventPreviewCard({ preview }: { preview: CalendarEventPreview }) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const statusLabel = {
    cancelled: messages.recommendations_event_status_cancelled(),
    confirmed: messages.recommendations_event_status_confirmed(),
    tentative: messages.recommendations_event_status_tentative(),
  }[preview.status];
  const when = describeEventTime(
    preview,
    locale,
    messages.recommendations_event_all_day()
  );

  // Figma 1211-14102: status pill · start time, then title over the time
  // range, then the organizer.
  return (
    <LinkCard kind="google_calendar_event">
      <div className="comma-recommendation-link-card-meta">
        <span
          className="comma-recommendation-link-card-state"
          data-state={preview.status}
        >
          {statusLabel}
        </span>
        <LinkCardTime at={preview.startsAt} locale={locale} />
      </div>
      <div className="comma-recommendation-link-card-stack">
        <span className="comma-recommendation-link-card-title">{preview.title}</span>
        {when ? (
          <span className="comma-recommendation-link-card-detail">{when}</span>
        ) : null}
      </div>
      {preview.organizer ? (
        <LinkCardPerson
          avatarUrl={null}
          gap="sm"
          name={preview.organizer.name}
          title={messages.recommendations_event_organizer({
            name: preview.organizer.name,
          })}
        />
      ) : null}
    </LinkCard>
  );
}

// Slack message: no state to pill, so the provider mark leads the meta row
// (the Notion pattern), then the #channel and when it was posted; the
// server-trimmed message text is the body, clamped to three lines.
function SlackMessagePreviewCard({
  preview,
  source,
}: {
  preview: SlackMessagePreview;
  source: LinkPreviewSourceLike | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();

  return (
    <LinkCard kind="slack_message">
      <div className="comma-recommendation-link-card-meta">
        <span aria-hidden="true" className="comma-recommendation-link-card-mark">
          <LinkProviderIcon source={source} />
        </span>
        <span className="comma-recommendation-link-card-ref">
          #{preview.channel.name ?? preview.channel.id}
        </span>
        <LinkCardTime at={preview.postedAt} locale={locale} />
      </div>
      <div className="comma-recommendation-link-card-body">
        <span className="comma-recommendation-link-card-excerpt">{preview.text}</span>
        {preview.author ? (
          <div className="comma-recommendation-link-card-facts">
            <LinkCardPerson
              avatarUrl={preview.author.avatarUrl}
              gap="sm"
              name={preview.author.name}
              title={messages.recommendations_slack_author({
                name: preview.author.name,
              })}
            />
          </div>
        ) : null}
      </div>
    </LinkCard>
  );
}

// Google Drive file: provider mark in the meta row (the Notion pattern),
// the file kind as the reference, when it changed, the file name, and the
// owner when Drive shares one.
function DriveFilePreviewCard({
  preview,
  source,
}: {
  preview: DriveFilePreview;
  source: LinkPreviewSourceLike | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const kindLabel = {
    document: messages.recommendations_drive_kind_document(),
    file: messages.recommendations_drive_kind_file(),
    folder: messages.recommendations_drive_kind_folder(),
    form: messages.recommendations_drive_kind_form(),
    pdf: messages.recommendations_drive_kind_pdf(),
    presentation: messages.recommendations_drive_kind_presentation(),
    spreadsheet: messages.recommendations_drive_kind_spreadsheet(),
  }[preview.fileKind];

  return (
    <LinkCard kind="google_drive_file">
      <div className="comma-recommendation-link-card-meta">
        <span aria-hidden="true" className="comma-recommendation-link-card-mark">
          <LinkProviderIcon source={source} />
        </span>
        <span className="comma-recommendation-link-card-ref">{kindLabel}</span>
        <LinkCardTime at={preview.modifiedAt} locale={locale} />
      </div>
      <div className="comma-recommendation-link-card-body">
        <span className="comma-recommendation-link-card-title">{preview.title}</span>
        {preview.owner ? (
          <div className="comma-recommendation-link-card-facts">
            <LinkCardPerson
              avatarUrl={preview.owner.avatarUrl}
              gap="sm"
              name={preview.owner.name}
              title={messages.recommendations_drive_owner({
                name: preview.owner.name,
              })}
            />
          </div>
        ) : null}
      </div>
    </LinkCard>
  );
}

// "Mon, Aug 24 · 9:00 – 9:45 AM" (all-day: "Mon, Aug 24 · All day").
function describeEventTime(
  preview: CalendarEventPreview,
  locale: CommaLocale,
  allDayLabel: string
) {
  if (preview.startsAt === null) return null;
  if (preview.allDay) {
    const day = formatDate(preview.startsAt, locale, {
      day: "numeric",
      month: "short",
      timeZone: "UTC",
      weekday: "short",
    });
    return `${day} · ${allDayLabel}`;
  }
  const day = formatDate(preview.startsAt, locale, {
    day: "numeric",
    month: "short",
    weekday: "short",
  });
  const timeOptions = { hour: "numeric", minute: "2-digit" } as const;
  return preview.endsAt === null
    ? `${day} · ${formatDate(preview.startsAt, locale, timeOptions)}`
    : `${day} · ${formatDateRange(preview.startsAt, preview.endsAt, locale, timeOptions)}`;
}

export function isPrivateMailLink(
  href: string,
  source?: LinkPreviewSourceLike | undefined
) {
  if (source?.appId?.toLowerCase() === "gmail") return true;
  try {
    return new URL(href).hostname === "mail.google.com";
  } catch {
    return false;
  }
}

// "host/path" without scheme, query or trailing slash — enough to tell where
// a link goes without echoing the full URL.
/**
 * The rich card's own shape while its preview loads (Figma 1305-12956): the
 * meta row, two lines of copy and the facts row, drawn as bars.
 */
export function LinkPreviewSkeleton() {
  return (
    <div
      className="comma-recommendation-link-card comma-recommendation-link-card-skeleton"
      data-testid="recommendation-link-card-skeleton"
    >
      <div className="comma-recommendation-link-card-meta">
        <span className="comma-recommendation-link-card-bar" data-bar="state" />
        <span className="comma-recommendation-link-card-bar" data-bar="time" />
      </div>
      <div className="comma-recommendation-link-card-body">
        <span className="comma-recommendation-link-card-bar" data-bar="title" />
        <span className="comma-recommendation-link-card-bar" data-bar="detail" />
        <div className="comma-recommendation-link-card-facts">
          <span className="comma-recommendation-link-card-bar" data-bar="person" />
          <span className="comma-recommendation-link-card-bar" data-bar="chip" />
        </div>
      </div>
    </div>
  );
}

export function describeLinkDestination(href: string) {
  try {
    const url = new URL(href);
    const path = url.pathname.replace(/\/$/, "");
    return `${url.host}${path}`;
  } catch {
    return href;
  }
}

function hostWithin(hostname: string, domain: string) {
  return hostname === domain || hostname.endsWith(`.${domain}`);
}

/**
 * Provider identity read off the link itself, for surfaces (chat) that have
 * no connected-source metadata to pass as `source`. Hosts mirror the rich
 * link shapes; anything unrecognized stays `undefined`, which the cards
 * render as the puzzle mark.
 */
export function providerFromHref(href: string): LinkPreviewSourceLike | undefined {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return undefined;
  }
  const hostname = url.hostname.toLowerCase();
  if (hostWithin(hostname, "github.com")) {
    return { appId: "github", appName: "GitHub" };
  }
  if (hostWithin(hostname, "linear.app")) {
    return { appId: "linear", appName: "Linear" };
  }
  if (hostWithin(hostname, "notion.so")) {
    return { appId: "notion", appName: "Notion" };
  }
  if (
    hostname === "calendar.google.com" ||
    ((hostname === "www.google.com" || hostname === "google.com") &&
      url.pathname.startsWith("/calendar"))
  ) {
    return { appId: "googlecalendar", appName: "Google Calendar" };
  }
  if (hostname.endsWith(".slack.com")) {
    return { appId: "slack", appName: "Slack" };
  }
  if (hostname === "docs.google.com" || hostname === "drive.google.com") {
    return { appId: "googledrive", appName: "Google Drive" };
  }
  return undefined;
}

// The provider's brand logo when @comma/ui ships one, else the connection's
// own icon, else the puzzle mark.
export function LinkProviderIcon({
  source,
}: {
  source: LinkPreviewSourceLike | undefined;
}) {
  const [failedIconUrl, setFailedIconUrl] = useState<string>();
  const ProviderLogo = resolveProviderBrandLogo(source?.appId);

  if (ProviderLogo) {
    return <ProviderLogo />;
  }

  if (source?.iconUrl && failedIconUrl !== source.iconUrl) {
    return (
      <img
        alt=""
        aria-hidden="true"
        draggable={false}
        onError={() => setFailedIconUrl(source.iconUrl ?? undefined)}
        src={source.iconUrl}
      />
    );
  }

  return <PuzzleIcon aria-hidden="true" />;
}

// Remote images ride the pinned media loader: Electron Main fetches and
// re-encodes the bytes, the renderer only ever sees a local blob URL. Web
// returns "unavailable", so callers keep their neutral fallback.
export function useLinkPreviewMediaUrl(sourceUrl: string | undefined) {
  const [safeUrl, setSafeUrl] = useState<string>();

  useEffect(() => {
    const controller = new AbortController();
    let objectUrl: string | undefined;
    setSafeUrl(undefined);
    if (!sourceUrl) return;

    void loadRecommendationMedia(sourceUrl, { signal: controller.signal }).then(
      (result) => {
        if (controller.signal.aborted || result.status !== "ready") return;
        try {
          objectUrl = URL.createObjectURL(
            new Blob([Uint8Array.from(result.bytes)], { type: result.mediaType })
          );
          if (controller.signal.aborted) {
            URL.revokeObjectURL(objectUrl);
            objectUrl = undefined;
            return;
          }
          setSafeUrl(objectUrl);
        } catch {
          objectUrl = undefined;
        }
      }
    );

    return () => {
      controller.abort();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [sourceUrl]);

  return safeUrl;
}
