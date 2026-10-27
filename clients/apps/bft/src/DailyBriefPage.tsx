import { Button } from "@comma/ui/components/Button";
import { Dropdown } from "@comma/ui/components/dropdown";
import { InputField } from "@comma/ui/components/input";
import { Toggle } from "@comma/ui/components/toggle";
import { useState } from "react";
import type { BftDailyBrief, BftDailyBriefMember, BftDailyBriefSync } from "./api";
import { calendarDays } from "./dailyBriefCalendar";
import { Runs, Today } from "./DailyBriefOps";
import { formatRelative } from "./format";
import { NoSwarms, type Swarm } from "./MeetingsPage";
import { messages } from "./messages";
import { useApi, useResource } from "./resource";
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

/** The organization's daily brief: settings, linked members, today and the latest runs. */
export function DailyBriefPage({
  org,
  swarms,
}: {
  org: string;
  swarms: readonly Swarm[];
}) {
  const api = useApi();
  const [resource, retry, refresh] = useResource(`daily-brief:${org}`, (signal) =>
    api.dailyBrief(org, signal)
  );
  const request = (member: string) =>
    api.requestDailyBrief(org, member).then((result) => {
      refresh();
      return result;
    });

  // Set up first; once configured, the operations come first.
  const settingsForm = (data: BftDailyBrief) => (
    <div className="bft-settings-grid">
      <SettingsForm
        onSaved={refresh}
        org={org}
        settings={data.settings}
        swarms={swarms}
      />
    </div>
  );

  return (
    <SettingsPage
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
            />
            {data.settings ? settingsForm(data) : null}
          </>
        )
      }
    </SettingsPage>
  );
}

function SettingsForm({
  org,
  settings,
  swarms,
  onSaved,
}: {
  org: string;
  settings: BftDailyBrief["settings"];
  swarms: readonly Swarm[];
  onSaved: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [draft, setDraft] = useState(() => ({
    enabled: settings?.enabled ?? false,
    project: settings?.project_id ?? swarms[0]?.id ?? "",
    connect: settings?.slack_connect_id ?? "",
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
  // The Swarm's Slack bots, as the Meetings settings list them.
  const [bots] = useResource(`daily-brief-bots:${org}:${draft.project}`, (signal) =>
    draft.project
      ? api.meetings(org, draft.project, signal).then((overview) => overview.connects)
      : Promise.resolve([])
  );
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
    if (teamChannel && !/^C[A-Z0-9]{2,32}$/.test(teamChannel))
      return setInvalid(t.teamChannelInvalid);
    setInvalid(undefined);
    write.run(
      () =>
        api.saveDailyBrief(org, {
          project_id: draft.project,
          slack_connect_id: draft.connect,
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
      <Dropdown
        className="bft-form-field"
        disabled={busy}
        items={swarms.map((swarm) => ({ id: swarm.id, label: swarm.name }))}
        label={t.swarm}
        onChange={(project) => {
          if (project !== draft.project) set({ project, connect: "" });
        }}
        size="sm"
        {...(draft.project ? { value: draft.project } : {})}
      />
      {bots.state === "loading" ? (
        <Skeleton height={32} />
      ) : bots.state === "error" ? (
        <TextField
          disabled={busy}
          error={write.fields.slack_connect_id}
          hint={t.botsUnavailable}
          label={t.connectId}
          onChange={(connect) => set({ connect })}
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
            ...(bot.workspace_name ? { subtitle: bot.workspace_name } : {}),
          }))}
          label={t.slackBot}
          onChange={(connect) => set({ connect })}
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
      <TextField
        disabled={busy}
        error={write.fields.team_channel_id}
        hint={t.teamChannelHint}
        label={t.teamChannel}
        onChange={(teamChannel) => set({ teamChannel })}
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

function Members({
  org,
  members,
  configured,
  enabled,
  onSynced,
  onRequest,
}: {
  org: string;
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
      () => api.syncDailyBriefMembers(org),
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
            <p>{t.unresolved(result.unresolved.join(", "))}</p>
          ) : null}
        </output>
      ) : null}
      {members.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.membersEmpty}</p>
      ) : (
        <table className="bft-table bft-members">
          <thead>
            <tr>
              <th scope="col">{t.columnMember}</th>
              <th scope="col">{t.columnSlack}</th>
              <th scope="col">{t.columnDelivery}</th>
              <th scope="col">{t.columnLastBrief}</th>
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
                onRequest={onRequest}
              />
            ))}
          </tbody>
        </table>
      )}
    </FormSection>
  );
}

function MemberRow({
  member,
  canSend,
  onRequest,
}: {
  member: BftDailyBriefMember;
  canSend: boolean;
  onRequest: (member: string) => Promise<unknown>;
}) {
  const write = useWrite();
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
      <td className="bft-truncate">{member.slack_user_id ?? "—"}</td>
      <td className="bft-truncate" title={member.timezone ?? undefined}>
        {member.enabled
          ? [time, member.timezone].filter(Boolean).join(" · ") || "—"
          : t.paused}
      </td>
      <td className="bft-truncate" title={member.last_brief_at ?? undefined}>
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
