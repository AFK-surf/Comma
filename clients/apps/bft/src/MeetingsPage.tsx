import { Button, Checkbox, Dialog, Dropdown, ScrollArea } from "@comma/ui";
import { useRef, useState, type ReactNode } from "react";
import type {
  BftMeetingConnect,
  BftMeetingRecord,
  BftMeetingSeries,
  BftMeetingStatus,
  BftMeetingsOverview,
} from "./api";
import { writeErrorMessage } from "./dialogs";
import { showFlash } from "./flash";
import { formatDateTime } from "./format";
import { messages } from "./messages";
import { meetingsPaths, orgHref, projectHref } from "./navSpec";
import { useApi, useResource, type Resource } from "./resource";
import { navigate, type MeetingsView } from "./router";
import {
  FormActions,
  FormSection,
  SaveButton,
  SettingsPage,
  useWrite,
} from "./settingsForm";
import { Skeleton } from "./states";

const t = messages.meetings;

export interface Swarm {
  id: string;
  name: string;
}

// The choice made last per organization and address parameter: sidebar links
// carry no `?project=` (Meetings, Data policy) or `?agent=` (Slack triage).
const chosen = new Map<string, string>();

/**
 * The item in `?<param>=`, else the one chosen last, else the first. `missing`
 * is set when the address asked for an item that is not in `items`.
 */
export function useSwarmChoice<T extends { id: string }>(
  org: string,
  items: readonly T[],
  param = "project"
) {
  const key = `${param}:${org}`;
  const [requested] = useState(() =>
    new URLSearchParams(window.location.search).get(param)
  );
  const [id, setId] = useState(() => requested ?? chosen.get(key));
  const choose = (next: string) => {
    chosen.set(key, next);
    setId(next);
    const url = new URL(window.location.href);
    url.searchParams.set(param, next);
    window.history.replaceState(null, "", url);
  };
  const item = items.find((candidate) => candidate.id === id) ?? items[0];
  const missing =
    requested !== null &&
    id === requested &&
    items.length > 0 &&
    item?.id !== requested;
  return [item, choose, missing] as const;
}

export function SwarmPicker({
  swarms,
  value,
  onChange,
}: {
  swarms: readonly Swarm[];
  value: string | undefined;
  onChange: (id: string) => void;
}) {
  return swarms.length > 1 ? (
    <Dropdown
      ariaLabel={t.swarm}
      items={swarms.map((swarm) => ({ id: swarm.id, label: swarm.name }))}
      onChange={onChange}
      size="sm"
      width="content"
      {...(value ? { value } : {})}
    />
  ) : null;
}

/** A page with no Agent Swarm to show yet. */
export function NoSwarms({ body }: { body: string }) {
  return (
    <div className="bft-state">
      <h2>{t.noSwarmsTitle}</h2>
      <p>{body}</p>
    </div>
  );
}

const meta: Record<MeetingsView, [string, string]> = {
  upcoming: [t.upcomingTitle, t.upcomingDescription],
  past: [t.pastTitle, t.pastDescription],
  settings: [t.settingsTitle, t.settingsDescription],
};

export function MeetingsPage({
  org,
  view,
  swarms,
}: {
  org: string;
  view: MeetingsView;
  swarms: readonly Swarm[];
}) {
  const api = useApi();
  const [swarm, choose] = useSwarmChoice(org, swarms);
  const project = swarm?.id ?? "";
  const [cursors, setCursors] = useState<string[]>([]);
  const cursor = cursors[cursors.length - 1] ?? null;
  // Upcoming and Settings read the overview; Past reads one history page.
  const [resource, retry] = useResource<unknown>(
    `meetings:${view}:${org}:${project}:${cursor ?? ""}`,
    (signal) =>
      !swarm
        ? Promise.resolve(null)
        : view === "past"
          ? api.meetingHistory(org, project, cursor, signal)
          : api.meetings(org, project, signal)
  );
  const [title, description] = meta[view];

  return (
    <SettingsPage
      actions={
        <>
          <SwarmPicker
            onChange={(id) => {
              setCursors([]);
              choose(id);
            }}
            swarms={swarms}
            value={swarm?.id}
          />
          {swarm && view !== "settings" ? (
            <button className="bft-btn" onClick={retry} type="button">
              {t.refresh}
            </button>
          ) : null}
        </>
      }
      description={description}
      onRetry={retry}
      resource={resource}
      title={title}
      wide
    >
      {(data) =>
        data === null ? (
          <NoSwarms body={t.noSwarmsBody} />
        ) : view === "past" ? (
          <History
            cursors={cursors}
            history={data as Parameters<typeof History>[0]["history"]}
            onPage={setCursors}
          />
        ) : view === "upcoming" ? (
          <Upcoming
            org={org}
            overview={data as BftMeetingsOverview}
            project={project}
          />
        ) : (
          <SettingsForm
            key={project}
            org={org}
            overview={data as BftMeetingsOverview}
            project={project}
          />
        )
      }
    </SettingsPage>
  );
}

const tones: Partial<Record<BftMeetingStatus, string>> = {
  ready: "ok",
  queued: "ok",
  failed: "warn",
  timed_out: "warn",
  not_sent: "warn",
};

function Upcoming({
  org,
  project,
  overview,
}: {
  org: string;
  project: string;
  overview: BftMeetingsOverview;
}) {
  const [open, setOpen] = useState<BftMeetingsOverview["events"][number] | null>(null);
  const { settings, events } = overview;
  const status = (event: { status: BftMeetingStatus }) =>
    t.statuses[event.status] ?? ["", ""];

  return (
    <div className="bft-settings-grid">
      <FormSection
        action={<span className="bft-count">{events.length}</span>}
        description={t.localTime}
        title={t.next24}
      >
        {events.length === 0 ? (
          <div className="bft-quiet bft-quiet-inline">
            <p>{t.emptyTitle}</p>
            <p>{t.emptyBody}</p>
          </div>
        ) : (
          <ul className="bft-list">
            {events.map((event) => (
              <li key={event.meeting_plan_id}>
                <button
                  className="bft-plugin-row bft-meeting-row"
                  onClick={() => setOpen(event)}
                  type="button"
                >
                  <time>{formatDateTime(event.start_ms)}</time>
                  <span className="bft-setting-row-main">
                    <span className="bft-plugin-name">{event.title ?? t.untitled}</span>
                    <span className="bft-plugin-description">{status(event)[1]}</span>
                  </span>
                  <span className="bft-status" data-tone={tones[event.status]}>
                    {status(event)[0]}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
        {["degraded", "unavailable", "pending"].includes(
          overview.calendar_health ?? ""
        ) ? (
          <p className="bft-notice">{t.healthIncomplete}</p>
        ) : null}
        {overview.truncated ? <p className="bft-notice">{t.truncated}</p> : null}
      </FormSection>
      <FormSection title={t.statusTitle}>
        <p className="bft-status" data-tone={settings.enabled ? "ok" : undefined}>
          {settings.enabled ? t.enabled : t.disabled}
        </p>
        {settings.enabled ? (
          <dl className="bft-kv">
            <div>
              <dt>{t.channel}</dt>
              <dd>
                #{(settings.channel ?? settings.channel_id ?? "").replace(/^#/, "")}
              </dd>
            </div>
            <div>
              <dt>{t.calendars}</dt>
              <dd>
                {settings.calendar_selections
                  .map((calendar) => calendar.name ?? calendar.calendar_id)
                  .join(", ")}
              </dd>
            </div>
            <div>
              <dt>{t.lead}</dt>
              <dd>{t.minutesBefore(settings.preparation_lead_minutes ?? 10)}</dd>
            </div>
            <div>
              <dt>{t.scope}</dt>
              <dd>{settings.series.length ? t.scopeSeries : t.scopeAll}</dd>
            </div>
          </dl>
        ) : (
          <p className="bft-quiet bft-quiet-inline">{t.notConfigured}</p>
        )}
        {overview.runtime_enabled ? null : (
          <p className="bft-notice">{t.runtimeDisabled}</p>
        )}
      </FormSection>
      {open ? (
        <ReportDialog
          description={status(open)[1]}
          onClose={() => setOpen(null)}
          org={org}
          plan={open.meeting_plan_id}
          project={project}
          title={open.title ?? t.untitled}
        />
      ) : null}
    </div>
  );
}

function ReportDialog({
  org,
  project,
  plan,
  title,
  description,
  onClose,
}: {
  org: string;
  project: string;
  plan: string;
  title: string;
  description: string;
  onClose: () => void;
}) {
  const api = useApi();
  const [report] = useResource(`meeting-report:${project}:${plan}`, () =>
    api.meetingReport(org, project, plan)
  );
  return (
    <DetailDialog description={description} onClose={onClose} title={title}>
      <h3 className="bft-field-label">{t.sharedPreparation}</h3>
      {report.state === "loading" ? (
        <Skeleton height={14} />
      ) : report.state === "error" ? (
        <p className="bft-dialog-error">{t.reportFailed}</p>
      ) : report.data ? (
        <p className="bft-report">{report.data}</p>
      ) : (
        <p className="bft-dialog-note">{t.noReport}</p>
      )}
      <p className="bft-form-section-note">{t.teamOnly}</p>
    </DetailDialog>
  );
}

/** A read-only detail in the shared dialog, scrolling inside its body. */
export function DetailDialog({
  title,
  description,
  onClose,
  children,
}: {
  title: string;
  description: string;
  onClose: () => void;
  children: ReactNode;
}) {
  return (
    <Dialog
      actions={[{ label: t.close, hierarchy: "secondary-gray", onPress: onClose }]}
      className="bft-dialog-wide"
      description={description}
      isOpen
      onOpenChange={(isOpen) => {
        if (!isOpen) onClose();
      }}
      title={title}
    >
      <ScrollArea
        className="bft-dialog-body"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-dialog-scroll"
      >
        <div className="bft-form">{children}</div>
      </ScrollArea>
    </Dialog>
  );
}

function History({
  history,
  cursors,
  onPage,
}: {
  history: {
    channel: string | null;
    meetings: BftMeetingRecord[];
    next_cursor: string | null;
  };
  cursors: string[];
  onPage: (cursors: string[]) => void;
}) {
  const [open, setOpen] = useState<BftMeetingRecord | null>(null);
  const recording = (record: BftMeetingRecord) =>
    t.recordings[record.recording_status ?? "none"] ?? t.recordings.none ?? ["", ""];
  const facts = (record: BftMeetingRecord) =>
    [
      t.recordStatuses[record.status ?? ""],
      recording(record)[0],
      record.canvas_url && t.canvas,
    ]
      .filter(Boolean)
      .join(" · ");

  return (
    <FormSection
      description={history.channel ? t.historyChannel(history.channel) : undefined}
      title={history.channel ? `#${history.channel}` : t.pastTitle}
    >
      {history.meetings.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.historyEmpty}</p>
      ) : (
        <ul className="bft-list">
          {history.meetings.map((record) => (
            <li key={record.meeting_id}>
              <button
                className="bft-plugin-row bft-meeting-row"
                onClick={() => setOpen(record)}
                type="button"
              >
                <time>{formatDateTime(record.start_ms)}</time>
                <span className="bft-setting-row-main">
                  <span className="bft-plugin-name">{record.title ?? t.untitled}</span>
                  <span className="bft-plugin-description">{facts(record)}</span>
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {cursors.length > 0 || history.next_cursor ? (
        <div className="bft-form-actions">
          {cursors.length > 0 ? (
            <Button hierarchy="secondary-gray" onPress={() => onPage([])} size="sm">
              {t.firstPage}
            </Button>
          ) : null}
          {history.next_cursor ? (
            <Button
              hierarchy="secondary-gray"
              onPress={() => onPage([...cursors, history.next_cursor ?? ""])}
              size="sm"
            >
              {t.nextPage}
            </Button>
          ) : null}
        </div>
      ) : null}
      {open ? (
        <DetailDialog
          description={[
            history.channel && `#${history.channel}`,
            t.recordStatuses[open.status ?? ""],
            formatDateTime(open.start_ms),
          ]
            .filter(Boolean)
            .join(" · ")}
          onClose={() => setOpen(null)}
          title={open.title ?? t.untitled}
        >
          <dl className="bft-plugin-facts">
            <dt>{t.recording}</dt>
            <dd>
              {open.recording_url ? (
                <a
                  className="bft-link"
                  href={open.recording_url}
                  rel="noopener noreferrer"
                  target="_blank"
                >
                  {t.openRecording}
                </a>
              ) : (
                recording(open)[1]
              )}
            </dd>
            <dt>{t.canvas}</dt>
            <dd>
              {open.canvas_url ? (
                <a
                  className="bft-link"
                  href={open.canvas_url}
                  rel="noopener noreferrer"
                  target="_blank"
                >
                  {t.openCanvas}
                </a>
              ) : (
                t.noCanvas
              )}
            </dd>
          </dl>
          <p className="bft-form-section-note">{t.linkAccess}</p>
          {open.thread_url ? (
            <a
              className="bft-link"
              href={open.thread_url}
              rel="noopener noreferrer"
              target="_blank"
            >
              {t.openThread}
            </a>
          ) : null}
        </DetailDialog>
      ) : null}
    </FormSection>
  );
}

const calendarKey = (calendar: { account_id: string; calendar_id: string }) =>
  JSON.stringify([calendar.account_id, calendar.calendar_id]);
const seriesKey = (series: BftMeetingSeries) =>
  JSON.stringify([series.account_id, series.calendar_id, series.event_id]);
const botName = (bot: BftMeetingConnect) =>
  bot.app_name ?? bot.bot_username ?? t.botUnnamed;
const botMeta = (bot: BftMeetingConnect) => {
  const workspace = bot.workspace_name ?? t.workspaceUnknown;
  return bot.app_name && bot.bot_username && bot.app_name !== bot.bot_username
    ? `@${bot.bot_username} · ${workspace}`
    : workspace;
};
const botStates = ["connected", "unconnected", "unavailable"];
// The picker keeps at most 500 channels in one interactive page.
const channelLimit = 500;

function SettingsForm({
  org,
  project,
  overview,
}: {
  org: string;
  project: string;
  overview: BftMeetingsOverview;
}) {
  const api = useApi();
  const write = useWrite();
  const saved = overview.settings;
  const [draft, setDraft] = useState(() => ({
    connect:
      saved.connect_id ??
      overview.connects.find((bot) => bot.state === "connected")?.connect_id ??
      "",
    calendars: saved.calendar_selections.map(calendarKey),
    series: saved.series[0] ? seriesKey(saved.series[0]) : "",
    scope: saved.series.length ? "series" : "all",
    seriesCalendar: "",
    lead: String(saved.preparation_lead_minutes ?? 10),
    channel: saved.channel_id ?? "",
    research: saved.research_enabled !== false,
    writeback: saved.calendar_writeback === true,
    autojoin: saved.mode === "join",
    personal: Boolean(saved.connect_id) && saved.personal_preparation !== false,
  }));
  const set = (patch: Partial<typeof draft>) =>
    setDraft((value) => ({ ...value, ...patch }));
  const [catalog, reload] = useResource(
    `meeting-catalog:${project}:${draft.connect}`,
    () =>
      draft.connect
        ? api.meetingCatalog(org, project, draft.connect)
        : Promise.resolve(null)
  );
  const [more, setMore] = useState<{
    channels: { id: string; name: string }[];
    next: string | null;
  }>();
  const [seriesPage, setSeriesPage] =
    useState<Resource<{ meetings: BftMeetingSeries[]; next_cursor: string | null }>>();
  const [invalid, setInvalid] = useState<string>();
  // Each load-more remembers the request it answers; a bot or calendar change
  // starts a new one, so a late page for the previous choice is dropped.
  const channelRequest = useRef(0);
  const seriesRequest = useRef(0);
  const [channelsLoading, setChannelsLoading] = useState(false);
  const ready = catalog.state === "ready" ? catalog.data : null;
  const bot = overview.connects.find((item) => item.connect_id === draft.connect);
  const scopesReady = bot?.missing_scopes?.length === 0;
  const calendars = ready?.calendars ?? [];
  const accounts = [
    ...new Set(calendars.map((calendar) => calendar.account_name ?? "")),
  ];
  const channels = [
    ...(saved.channel_id
      ? [{ id: saved.channel_id, name: saved.channel ?? saved.channel_id }]
      : []),
    ...(ready?.channels ?? []),
    ...(more?.channels ?? []),
  ].filter(
    (channel, index, all) => all.findIndex((c) => c.id === channel.id) === index
  );
  const nextChannels = more ? more.next : (ready?.next_cursor ?? null);
  const seriesOptions = [
    ...saved.series,
    ...(seriesPage?.state === "ready" ? seriesPage.data.meetings : []),
  ].filter(
    (item, index, all) =>
      all.findIndex((s) => seriesKey(s) === seriesKey(item)) === index
  );

  const changeBot = (connect: string) => {
    // A different bot needs its own permission check for attendee DMs.
    setDraft((value) => ({ ...value, connect, personal: false }));
    channelRequest.current += 1;
    seriesRequest.current += 1;
    setChannelsLoading(false);
    setMore(undefined);
    setSeriesPage(undefined);
  };

  const changeSeriesCalendar = (seriesCalendar: string) => {
    set({ seriesCalendar });
    if (seriesCalendar === draft.seriesCalendar) return;
    seriesRequest.current += 1;
    setSeriesPage(undefined);
  };

  const loadSeries = (cursor: string | null) => {
    const calendar = calendars.find(
      (item) => calendarKey(item) === draft.seriesCalendar
    );
    if (!calendar) {
      setSeriesPage({ state: "error", error: t.needCalendarFirst });
      return;
    }
    const previous =
      seriesPage?.state === "ready" && cursor ? seriesPage.data.meetings : [];
    const request = ++seriesRequest.current;
    setSeriesPage({ state: "loading" });
    api.meetingSeries(org, project, calendar, cursor).then(
      (page) => {
        if (request !== seriesRequest.current) return;
        setSeriesPage({
          state: "ready",
          data: { ...page, meetings: [...previous, ...page.meetings] },
        });
      },
      (error: unknown) => {
        if (request !== seriesRequest.current) return;
        setSeriesPage({ state: "error", error: writeErrorMessage(error) });
      }
    );
  };

  const loadChannels = () => {
    if (!nextChannels || channelsLoading) return;
    const request = ++channelRequest.current;
    setChannelsLoading(true);
    api.meetingChannels(org, project, draft.connect, nextChannels).then(
      (page) => {
        if (request !== channelRequest.current) return;
        setChannelsLoading(false);
        const known = [...(more?.channels ?? []), ...page.channels];
        const room = channelLimit - (ready?.channels.length ?? 0);
        setMore({
          channels: known.slice(0, room),
          next: known.length < room ? page.next_cursor : null,
        });
      },
      (error: unknown) => {
        if (request !== channelRequest.current) return;
        setChannelsLoading(false);
        setInvalid(writeErrorMessage(error));
      }
    );
  };

  const done = () => {
    const upcoming = orgHref(org, meetingsPaths.upcoming);
    showFlash({ kind: "info", text: t.savedNotice }, upcoming);
    navigate(`${upcoming}?project=${encodeURIComponent(project)}`);
  };

  const submit = () => {
    const selections = calendars
      .filter((calendar) => draft.calendars.includes(calendarKey(calendar)))
      .map(({ account_id, calendar_id }) => ({ account_id, calendar_id }));
    const series = seriesOptions.filter((item) => seriesKey(item) === draft.series);
    if (selections.length === 0) return setInvalid(t.needCalendar);
    if (draft.scope === "series" && series.length === 0)
      return setInvalid(t.needSeries);
    setInvalid(undefined);
    write.run(
      () =>
        api.saveMeetings(org, project, {
          enabled: true,
          connect_id: draft.connect,
          channel_id: draft.channel,
          calendar_selections: selections,
          preparation_lead_minutes: Number(draft.lead),
          research_enabled: draft.research,
          calendar_writeback: draft.writeback,
          autojoin: draft.autojoin,
          personal_preparation: draft.personal,
          series: draft.scope === "series" ? series : [],
        }),
      done
    );
  };

  const connections = projectHref(org, project, "/connections");
  const busy = write.busy;

  return (
    <div className="bft-settings-grid">
      <div>
        <FormSection title={t.botTitle}>
          {overview.connects.length === 0 ? (
            <p className="bft-quiet bft-quiet-inline">{t.noBots}</p>
          ) : (
            <Dropdown
              ariaLabel={t.botTitle}
              className="bft-form-field"
              disabled={busy}
              items={overview.connects
                .toSorted(
                  (a, b) => botStates.indexOf(a.state) - botStates.indexOf(b.state)
                )
                .map((item) => ({
                  id: item.connect_id,
                  label: botName(item),
                  subtitle: `${botMeta(item)} · ${t.botPreparation[item.preparation] ?? ""}`,
                  group: t.botGroups[item.state] ?? item.state,
                }))}
              onChange={changeBot}
              size="sm"
              {...(draft.connect ? { value: draft.connect } : {})}
            />
          )}
        </FormSection>
        <FormSection
          action={
            <button
              className="bft-btn bft-btn-sm"
              disabled={busy}
              onClick={reload}
              type="button"
            >
              {t.reload}
            </button>
          }
          description={t.calendarsHint}
          title={t.calendarsTitle}
        >
          {catalog.state === "loading" ? (
            <Skeleton height={14} />
          ) : catalog.state === "error" ? (
            <p className="bft-dialog-error" role="alert">
              {writeErrorMessage(catalog.error)}
            </p>
          ) : (
            accounts.map((account) => (
              <div className="bft-checklist" key={account}>
                <p className="bft-field-label">{t.googleCalendar(account)}</p>
                {calendars
                  .filter((calendar) => (calendar.account_name ?? "") === account)
                  .map((calendar) => {
                    const key = calendarKey(calendar);
                    return (
                      <Checkbox
                        checked={draft.calendars.includes(key)}
                        disabled={busy}
                        key={key}
                        label={calendar.name ?? calendar.calendar_id}
                        onChange={(event) =>
                          set({
                            calendars: event.target.checked
                              ? [...draft.calendars, key]
                              : draft.calendars.filter((value) => value !== key),
                          })
                        }
                        size="sm"
                      />
                    );
                  })}
              </div>
            ))
          )}
          <a
            className="bft-link bft-setting-row-link"
            href={connections}
            rel="noopener noreferrer"
            target="_blank"
          >
            {t.connectCalendar}
          </a>
        </FormSection>
        <FormSection title={t.scopeLabel}>
          <Dropdown
            ariaLabel={t.scopeLabel}
            className="bft-form-field"
            disabled={busy}
            items={[
              { id: "all", label: t.scopeAll },
              { id: "series", label: t.scopeSeries },
            ]}
            onChange={(scope) => set({ scope })}
            size="sm"
            value={draft.scope}
          />
          {draft.scope === "series" ? (
            <>
              <div className="bft-route-connect">
                <Dropdown
                  className="bft-form-field"
                  disabled={busy}
                  items={calendars
                    .filter((calendar) =>
                      draft.calendars.includes(calendarKey(calendar))
                    )
                    .map((calendar) => ({
                      id: calendarKey(calendar),
                      label: calendar.name ?? calendar.calendar_id,
                    }))}
                  label={t.seriesCalendar}
                  onChange={changeSeriesCalendar}
                  placeholder={t.selectCalendar}
                  size="sm"
                  {...(draft.seriesCalendar ? { value: draft.seriesCalendar } : {})}
                />
                <Button
                  disabled={busy || seriesPage?.state === "loading"}
                  hierarchy="secondary-gray"
                  onPress={() => loadSeries(null)}
                  size="sm"
                >
                  {t.browse}
                </Button>
              </div>
              {seriesPage?.state === "error" ? (
                <p className="bft-dialog-error" role="alert">
                  {String(seriesPage.error ?? "")}
                </p>
              ) : null}
              <Dropdown
                disabled={busy}
                items={seriesOptions.map((item) => ({
                  id: seriesKey(item),
                  label: item.title ?? item.event_id,
                }))}
                label={t.seriesLabel}
                onChange={(series) => set({ series })}
                placeholder={t.selectSeries}
                size="sm"
                {...(draft.series ? { value: draft.series } : {})}
              />
              {seriesPage?.state === "ready" && seriesPage.data.next_cursor ? (
                <button
                  className="bft-btn bft-btn-sm"
                  onClick={() => loadSeries(seriesPage.data.next_cursor)}
                  type="button"
                >
                  {t.moreSeries}
                </button>
              ) : null}
              <p className="bft-form-section-note">{t.seriesHint}</p>
            </>
          ) : null}
        </FormSection>
      </div>
      <div>
        <FormSection description={t.contentHint} title={t.contentTitle}>
          <Checkbox
            checked={draft.research}
            disabled={busy}
            label={t.research}
            onChange={(event) => set({ research: event.target.checked })}
            size="sm"
          />
        </FormSection>
        <FormSection description={t.deliveryHint} title={t.deliveryTitle}>
          <Dropdown
            className="bft-form-field"
            disabled={busy}
            items={[10, 15, 30, 60].map((minutes) => ({
              id: String(minutes),
              label: t.minutesBefore(minutes),
            }))}
            label={t.leadLabel}
            onChange={(lead) => set({ lead })}
            size="sm"
            value={draft.lead}
          />
          <Dropdown
            className="bft-form-field"
            disabled={busy}
            items={channels.map((channel) => ({
              id: channel.id,
              label: `#${channel.name.replace(/^#/, "")}`,
            }))}
            label={t.channelLabel}
            onChange={(channel) => set({ channel })}
            placeholder={t.selectChannel}
            size="sm"
            {...(draft.channel ? { value: draft.channel } : {})}
          />
          {nextChannels ? (
            <button
              className="bft-btn bft-btn-sm"
              disabled={channelsLoading}
              onClick={loadChannels}
              type="button"
            >
              {t.moreChannels}
            </button>
          ) : null}
          <Checkbox
            checked={draft.personal}
            disabled={busy || (!scopesReady && !draft.personal)}
            hint={
              scopesReady
                ? t.scopesReady
                : bot?.missing_scopes
                  ? t.scopesMissing(bot.missing_scopes.join(", "))
                  : t.scopesUnknown
            }
            label={t.attendeeDms}
            onChange={(event) => set({ personal: event.target.checked })}
            size="sm"
          />
          {scopesReady ? null : (
            <a
              className="bft-link bft-setting-row-link"
              href={connections}
              rel="noopener noreferrer"
              target="_blank"
            >
              {t.manageSlack}
            </a>
          )}
        </FormSection>
        <FormSection title={t.moreTitle}>
          <Checkbox
            checked={draft.writeback}
            disabled={busy}
            label={t.writeback}
            onChange={(event) => set({ writeback: event.target.checked })}
            size="sm"
          />
          <Checkbox
            checked={draft.autojoin}
            disabled={busy}
            label={t.autojoin}
            onChange={(event) => set({ autojoin: event.target.checked })}
            size="sm"
          />
        </FormSection>
        <FormActions write={invalid ? { ...write, error: invalid } : write}>
          {saved.enabled ? (
            <Button
              disabled={busy}
              hierarchy="secondary-gray"
              onPress={() =>
                write.run(
                  () => api.saveMeetings(org, project, { enabled: false }),
                  done
                )
              }
              size="sm"
            >
              {t.pause}
            </Button>
          ) : null}
          <SaveButton busy={busy} disabled={!ready} label={t.save} onPress={submit} />
        </FormActions>
        <p className="bft-form-section-note">{t.footnote}</p>
      </div>
    </div>
  );
}
