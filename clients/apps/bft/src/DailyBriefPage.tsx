import { Button } from "@comma/ui/components/Button";
import { Dropdown, SearchSelect } from "@comma/ui/components/dropdown";
import { InputField } from "@comma/ui/components/input";
import { Toggle } from "@comma/ui/components/toggle";
import { useState } from "react";
import type {
  BftDailyBrief,
  BftDailyBriefChannels,
  BftDailyBriefMember,
  BftDailyBriefProvider,
  BftDailyBriefSync,
} from "./api";
import { calendarDays } from "./dailyBriefCalendar";
import { Runs, Today } from "./DailyBriefOps";
import { formatRelative } from "./format";
import { NoSwarms, type Swarm, SwarmPicker } from "./MeetingsPage";
import { messages } from "./messages";
import { type Resource, useApi, useResource } from "./resource";
import {
  FormActions,
  FormSection,
  SaveButton,
  SettingsPage,
  TextField,
  useWrite,
} from "./settingsForm";
import { Skeleton } from "./states";

const t = messages.dailyBrief;

/**
 * The Swarm in `?project=`, else the one chosen last on this page, else none:
 * the server then shows the organization's current settings.
 */
const chosenSwarm = new Map<string, string>();

function useBriefSwarm(org: string) {
  const [project, setProject] = useState<string | null>(
    () =>
      new URLSearchParams(window.location.search).get("project") ??
      chosenSwarm.get(org) ??
      null
  );
  const choose = (next: string) => {
    chosenSwarm.set(org, next);
    setProject(next);
    const url = new URL(window.location.href);
    url.searchParams.set("project", next);
    window.history.replaceState(null, "", url);
  };
  return [project, choose] as const;
}

/**
 * One Agent Swarm's daily brief: its settings, today and latest runs, and the
 * organization's linked members, each with the Swarm whose bot sends their
 * one brief.
 */
export function DailyBriefPage({
  org,
  swarms,
}: {
  org: string;
  swarms: readonly Swarm[];
}) {
  const api = useApi();
  const [project, choose] = useBriefSwarm(org);
  const [resource, retry, refresh] = useResource(
    `daily-brief:${org}:${project ?? ""}`,
    (signal) => api.dailyBrief(org, project, signal)
  );
  const request = (member: string) =>
    api.requestDailyBrief(org, member).then((result) => {
      refresh();
      return result;
    });
  // The Swarm shown: the one asked for, else, once read, the one the server
  // chose (the first Swarm when none has settings yet).
  const shown =
    project ??
    (resource.state === "ready"
      ? (resource.data.settings?.project_id ?? swarms[0]?.id)
      : undefined);

  // Set up first; once configured, the operations come first. A form is the
  // shown Swarm's own: another Swarm starts from its own saved settings.
  const settingsForm = (data: BftDailyBrief) => (
    <div className="bft-settings-grid">
      <SettingsForm
        key={shown ?? ""}
        onSaved={refresh}
        org={org}
        project={shown}
        settings={data.settings}
        swarms={swarms}
      />
    </div>
  );

  return (
    <SettingsPage
      actions={
        shown ? <SwarmPicker onChange={choose} swarms={swarms} value={shown} /> : null
      }
      description={t.description}
      onRetry={retry}
      resource={resource}
      title={t.title}
      wide
    >
      {(data) =>
        swarms.length === 0 && !data.settings ? (
          <NoSwarms body={t.noSwarmsBody} />
        ) : (
          <>
            {data.today ? <Today today={data.today} /> : null}
            {data.settings ? null : (
              <div className="bft-state">
                <h2>{t.emptyTitle}</h2>
                <p>{t.emptyBody}</p>
              </div>
            )}
            {data.settings ? null : settingsForm(data)}
            {data.settings ? <Runs onRequest={request} runs={data.runs} /> : null}
            <Members
              configured={data.settings !== null}
              enabled={data.settings?.enabled === true}
              members={data.members}
              onRequest={request}
              onSynced={refresh}
              org={org}
              project={data.settings ? (shown ?? null) : null}
              provider={data.settings?.provider ?? "slack"}
              senders={sendingSwarms(data, swarms)}
            />
            {data.settings ? settingsForm(data) : null}
          </>
        )
      }
    </SettingsPage>
  );
}

/**
 * The Swarms that can send a member's brief: those with the brief on through
 * a bot of the shown settings' IM. A choice shows only when there are two.
 */
function sendingSwarms(data: BftDailyBrief, swarms: readonly Swarm[]) {
  const provider = data.settings?.provider;
  const ids = new Set(
    data.configured_projects
      .filter((swarm) => swarm.enabled && swarm.provider === provider)
      .map((swarm) => swarm.project_id)
  );
  const listed = swarms.filter((swarm) => ids.has(swarm.id));
  return listed.length > 1 ? listed : [];
}

function SettingsForm({
  org,
  project,
  settings,
  swarms,
  onSaved,
}: {
  org: string;
  /** The Swarm the page shows; its settings are the ones saved. */
  project: string | undefined;
  settings: BftDailyBrief["settings"];
  swarms: readonly Swarm[];
  onSaved: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [draft, setDraft] = useState(() => ({
    enabled: settings?.enabled ?? false,
    project: project ?? settings?.project_id ?? swarms[0]?.id ?? "",
    provider: settings?.provider ?? ("slack" as BftDailyBriefProvider),
    connect: settings?.connect_id ?? settings?.slack_connect_id ?? "",
    teamNames: settings?.team_names ?? "hidden",
    retention: String(settings?.retention_days ?? 90),
    offDays: (settings?.off_days ?? []).join(", "),
    workDays: (settings?.work_days ?? []).join(", "),
    teamChannel: settings?.team_channel_id ?? "",
    teamPostAt: (settings?.team_post_at ?? "10:20:00").slice(0, 5),
  }));
  const set = (patch: Partial<typeof draft>) =>
    setDraft((value) => ({ ...value, ...patch }));
  const [invalid, setInvalid] = useState<string>();
  // The Swarm's Slack, Feishu and Lark bots, as the Meetings settings list them.
  const [bots] = useResource(`daily-brief-bots:${org}:${draft.project}`, (signal) =>
    draft.project
      ? api.meetings(org, draft.project, signal).then((overview) => overview.connects)
      : Promise.resolve([])
  );
  // The groups or channels the chosen bot can post the team brief to.
  const [channels] = useResource(
    `daily-brief-channels:${org}:${draft.project}:${draft.provider}:${draft.connect}`,
    (signal) =>
      draft.project && draft.connect
        ? api.dailyBriefChannels(
            org,
            {
              project_id: draft.project,
              provider: draft.provider,
              connect_id: draft.connect,
            },
            signal
          )
        : Promise.resolve({ channels: [], complete: true })
  );
  const providerName = (provider: string) => t.providerNames[provider] ?? provider;
  const busy = write.busy;
  const retention = Number(draft.retention);

  const submit = () => {
    if (!draft.project || !draft.connect) return setInvalid(t.needBot);
    if (!Number.isInteger(retention) || retention < 1 || retention > 90)
      return setInvalid(t.retentionInvalid);
    const offDays = calendarDays(draft.offDays);
    const workDays = calendarDays(draft.workDays);
    if (!offDays || !workDays) return setInvalid(t.datesInvalid);
    const teamChannel = draft.teamChannel.trim();
    if (teamChannel && !teamChannelPattern(draft.provider).test(teamChannel))
      return setInvalid(t.teamChannelInvalid(draft.provider));
    setInvalid(undefined);
    write.run(
      () =>
        api.saveDailyBrief(org, {
          project_id: draft.project,
          provider: draft.provider,
          connect_id: draft.connect,
          slack_connect_id: draft.provider === "slack" ? draft.connect : null,
          enabled: draft.enabled,
          retention_days: retention,
          team_names: draft.teamNames,
          off_days: offDays,
          work_days: workDays,
          team_channel_id: teamChannel || null,
          team_post_at: `${draft.teamPostAt || "10:20"}:00`,
        }),
      () => onSaved()
    );
  };

  return (
    <FormSection title={t.settingsTitle}>
      <Toggle
        checked={draft.enabled}
        disabled={busy}
        label={t.enabled}
        onChange={(event) => set({ enabled: event.target.checked })}
        size="sm"
      />
      {swarms.length > 1 ? null : (
        // With several Swarms, the page's picker chooses the Swarm.
        <Dropdown
          className="bft-form-field"
          disabled={busy}
          items={swarms.map((swarm) => ({ id: swarm.id, label: swarm.name }))}
          label={t.swarm}
          onChange={(next) => {
            if (next !== draft.project)
              set({ project: next, connect: "", teamChannel: "" });
          }}
          size="sm"
          {...(draft.project ? { value: draft.project } : {})}
        />
      )}
      {bots.state === "loading" ? (
        <Skeleton height={32} />
      ) : bots.state === "error" ? (
        <TextField
          disabled={busy}
          error={write.fields.slack_connect_id}
          hint={t.botsUnavailable}
          label={t.connectId}
          onChange={(connect) => set({ connect, teamChannel: "" })}
          value={draft.connect}
        />
      ) : bots.data.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.noBots}</p>
      ) : (
        <Dropdown
          className="bft-form-field"
          disabled={busy}
          items={bots.data.map((bot) => ({
            id: bot.connect_id,
            label: bot.app_name ?? bot.bot_username ?? bot.connect_id,
            subtitle: [providerName(bot.provider), bot.workspace_name]
              .filter(Boolean)
              .join(" · "),
          }))}
          label={t.bot}
          onChange={(connect) => {
            if (connect === draft.connect) return;
            const provider =
              bots.data.find((bot) => bot.connect_id === connect)?.provider ?? "slack";
            // A group belongs to its bot: another bot starts with none.
            set({ connect, provider, teamChannel: "" });
          }}
          placeholder={t.selectBot}
          size="sm"
          {...(draft.connect ? { value: draft.connect } : {})}
        />
      )}
      <Dropdown
        className="bft-form-field"
        disabled={busy}
        items={[
          { id: "hidden", label: t.teamNamesHidden },
          { id: "shown", label: t.teamNamesShown },
        ]}
        label={t.teamNames}
        onChange={(teamNames) => set({ teamNames: teamNames as "hidden" | "shown" })}
        size="sm"
        value={draft.teamNames}
      />
      <InputField
        className="w-full"
        disabled={busy}
        fieldSize="sm"
        hint={t.retentionHint}
        label={t.retention}
        max={90}
        min={1}
        onChange={(event) => set({ retention: event.target.value })}
        type="number"
        value={draft.retention}
        wrapperClassName="bft-form-field"
        {...(write.fields.retention_days
          ? { errorMessage: write.fields.retention_days }
          : {})}
      />
      <TeamChannelPicker
        channels={channels}
        disabled={busy || !draft.connect}
        error={write.fields.team_channel_id}
        onChange={(teamChannel) => set({ teamChannel })}
        provider={draft.provider}
        value={draft.teamChannel}
      />
      <InputField
        className="w-full"
        disabled={busy}
        fieldSize="sm"
        hint={t.teamPostAtHint}
        label={t.teamPostAt}
        onChange={(event) => set({ teamPostAt: event.target.value })}
        type="time"
        value={draft.teamPostAt}
        wrapperClassName="bft-form-field"
        {...(write.fields.team_post_at
          ? { errorMessage: write.fields.team_post_at }
          : {})}
      />
      <TextField
        disabled={busy}
        error={write.fields.off_days}
        hint={t.offDaysHint}
        label={t.offDays}
        onChange={(offDays) => set({ offDays })}
        value={draft.offDays}
      />
      <TextField
        disabled={busy}
        error={write.fields.work_days}
        hint={t.workDaysHint}
        label={t.workDays}
        onChange={(workDays) => set({ workDays })}
        value={draft.workDays}
      />
      <FormActions write={invalid ? { ...write, error: invalid } : write}>
        <SaveButton busy={busy} label={t.save} onPress={submit} />
      </FormActions>
    </FormSection>
  );
}

const teamChannelPattern = (provider: BftDailyBriefProvider) =>
  provider === "slack" ? /^C[A-Z0-9]{2,32}$/ : /^oc_[A-Za-z0-9_]{2,64}$/;

/**
 * The team brief's group: one trigger, the same as the other fields, and a
 * panel that searches the bot's public groups or channels by name. A pasted
 * ID is offered as an option when the list does not have it, and a saved ID
 * the list does not name still shows as itself.
 */
function TeamChannelPicker({
  provider,
  channels,
  value,
  onChange,
  disabled,
  error,
}: {
  provider: BftDailyBriefProvider;
  channels: Resource<BftDailyBriefChannels>;
  value: string;
  onChange: (id: string) => void;
  disabled: boolean;
  error: string | undefined;
}) {
  const loading = channels.state === "loading";
  const listed = channels.state === "ready" ? channels.data.channels : [];
  const named = listed.find((channel) => channel.id === value);
  const display = loading
    ? t.teamChannelLoading
    : !value
      ? t.teamChannelNone
      : (named?.name ?? t.teamChannelSavedId(value));
  const hint =
    channels.state === "error"
      ? t.teamChannelPasteHint(provider)
      : channels.state === "ready" && !channels.data.complete
        ? `${t.teamChannelHint} ${t.teamChannelPartial}`
        : t.teamChannelHint;

  const items = (query: string) => {
    const needle = query.trim();
    const matches = (text: string) => text.toLowerCase().includes(needle.toLowerCase());
    const pasted =
      teamChannelPattern(provider).test(needle) &&
      !listed.some((channel) => channel.id === needle)
        ? needle
        : null;
    return [
      ...(!needle || matches(t.teamChannelNone)
        ? [{ id: none, label: t.teamChannelNone }]
        : []),
      ...(value && !named && value !== pasted && (!needle || value.includes(needle))
        ? [{ id: value, label: t.teamChannelSavedId(value) }]
        : []),
      ...listed
        .filter((channel) => !needle || matches(channel.name) || channel.id === needle)
        .map((channel) => ({
          id: channel.id,
          label: channel.name,
          detail: channel.id,
        })),
      ...(pasted ? [{ id: pasted, label: t.teamChannelUseId(pasted) }] : []),
    ];
  };

  return (
    <div className="bft-form-field">
      <SearchSelect
        className="bft-form-field"
        disabled={disabled || loading}
        display={display}
        emptyText={t.teamChannelNoMatches}
        hint={hint}
        items={items}
        label={t.teamChannel}
        muted={loading}
        onChange={(id) => onChange(id === none ? "" : id)}
        searchPlaceholder={t.teamChannelFilter}
        value={value || none}
      />
      {error ? (
        <p className="bft-dialog-error" role="alert">
          {error}
        </p>
      ) : null}
    </div>
  );
}

// The "no team brief" option; never a group id.
const none = "__none__";

function Members({
  org,
  project,
  members,
  configured,
  enabled,
  onSynced,
  onRequest,
  provider,
  senders,
}: {
  org: string;
  /** The Swarm whose bot finds the members. */
  project: string | null;
  provider: BftDailyBriefProvider;
  /** The Swarms a member's brief can be sent by; empty when there is no choice. */
  senders: readonly Swarm[];
  members: BftDailyBriefMember[];
  configured: boolean;
  /** Whether briefs are on, so one can be sent now. */
  enabled: boolean;
  onSynced: () => void;
  onRequest: (member: string) => Promise<unknown>;
}) {
  const api = useApi();
  const write = useWrite();
  const [result, setResult] = useState<BftDailyBriefSync>();

  const sync = () =>
    write.run(
      () => api.syncDailyBriefMembers(org, project),
      (synced) => {
        setResult(synced);
        onSynced();
      }
    );

  return (
    <FormSection
      action={
        <Button
          disabled={!configured || write.busy}
          hierarchy="secondary-gray"
          onPress={sync}
          size="sm"
        >
          {write.busy ? t.syncing : t.sync}
        </Button>
      }
      description={t.membersHint}
      title={t.membersTitle}
    >
      {write.error ? (
        <p className="bft-dialog-error" role="alert">
          {write.error}
        </p>
      ) : result ? (
        <output className="bft-notice" data-kind="info">
          <p>{t.synced(result.linked)}</p>
          {result.unresolved.length > 0 ? (
            <p>
              {t.unresolved(
                t.providerNames[provider] ?? provider,
                result.unresolved.join(", ")
              )}
            </p>
          ) : null}
        </output>
      ) : null}
      {members.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.membersEmpty}</p>
      ) : (
        // On a narrow page, a member's Swarm picker takes the place of their
        // account id, brief time and last brief.
        <table
          className="bft-table bft-members"
          {...(senders.length > 0 ? { "data-senders": "" } : {})}
        >
          <thead>
            <tr>
              <th scope="col">{t.columnMember}</th>
              <th className="bft-col-account" scope="col">
                {t.columnAccount(t.providerNames[provider] ?? provider)}
              </th>
              {senders.length > 0 ? (
                <th className="bft-col-sender" scope="col">
                  {t.swarm}
                </th>
              ) : null}
              <th className="bft-col-delivery" scope="col">
                {t.columnDelivery}
              </th>
              <th className="bft-col-last" scope="col">
                {t.columnLastBrief}
              </th>
              <th scope="col">
                <span className="bft-sr-only">{t.sendNow}</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {members.map((member) => (
              <MemberRow
                canSend={enabled}
                key={member.id}
                member={member}
                onMoved={onSynced}
                onRequest={onRequest}
                org={org}
                senders={senders}
              />
            ))}
          </tbody>
        </table>
      )}
    </FormSection>
  );
}

function MemberRow({
  org,
  member,
  canSend,
  onRequest,
  senders,
  onMoved,
}: {
  org: string;
  member: BftDailyBriefMember;
  canSend: boolean;
  onRequest: (member: string) => Promise<unknown>;
  senders: readonly Swarm[];
  onMoved: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const move = useWrite();
  const requested = member.requested_at !== null || write.saved;
  const name = member.name ?? member.email ?? member.id;
  const time = member.deliver_at?.slice(0, 5);
  return (
    <tr>
      <td>
        <span className="bft-setting-row-main">
          <span className="bft-member-name bft-truncate" title={name}>
            {name}
          </span>
          {member.name && member.email ? (
            <span className="bft-plugin-description bft-truncate" title={member.email}>
              {member.email}
            </span>
          ) : null}
        </span>
      </td>
      <td className="bft-col-account bft-truncate">
        {member.provider_user_id ?? member.slack_user_id ?? "—"}
      </td>
      {senders.length > 0 ? (
        <td className="bft-col-sender">
          {move.error ? (
            <span className="bft-dialog-error" role="alert" title={move.error}>
              {t.requestFailed}
            </span>
          ) : (
            <Dropdown
              ariaLabel={`${t.swarm} · ${name}`}
              disabled={move.busy}
              items={senders.map((swarm) => ({ id: swarm.id, label: swarm.name }))}
              onChange={(next) => {
                if (next === member.project_id) return;
                move.run(
                  () => api.setDailyBriefMemberSwarm(org, member.id, next),
                  () => onMoved()
                );
              }}
              placeholder="—"
              size="sm"
              width="content"
              {...(member.project_id ? { value: member.project_id } : {})}
            />
          )}
        </td>
      ) : null}
      <td
        className="bft-col-delivery bft-truncate"
        title={member.timezone ?? undefined}
      >
        {member.enabled
          ? [time, member.timezone].filter(Boolean).join(" · ") || "—"
          : t.paused}
      </td>
      <td
        className="bft-col-last bft-truncate"
        title={member.last_brief_at ?? undefined}
      >
        {member.last_brief_at ? (formatRelative(member.last_brief_at) ?? "—") : "—"}
      </td>
      <td>
        {write.error ? (
          <span className="bft-dialog-error" role="alert" title={write.error}>
            {t.requestFailed}
          </span>
        ) : (
          <Button
            disabled={!canSend || !member.enabled || requested || write.busy}
            hierarchy="secondary-gray"
            onPress={() =>
              write.run(
                () => onRequest(member.id),
                () => undefined
              )
            }
            size="sm"
          >
            {requested ? t.requested : t.sendNow}
          </Button>
        )}
      </td>
    </tr>
  );
}
