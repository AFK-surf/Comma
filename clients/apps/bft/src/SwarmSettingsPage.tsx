import { Button } from "@comma/ui/components/Button";
import { Dropdown } from "@comma/ui/components/dropdown";
import { InputField } from "@comma/ui/components/input";
import { useEffect, useState } from "react";
import type {
  BftSwarmAccessPage,
  BftSwarmAccessRole,
  BftSwarmAccessWrite,
  BftSwarmMember,
  BftSwarmSettings,
  BftSwarmTaskPlace,
} from "./api";
import { CopyButton } from "./dialogs";
import { showFlash } from "./flash";
import { formatRelative } from "./format";
import { messages } from "./messages";
import { State } from "./ProjectOverviewPage";
import { useApi } from "./resource";
import { navigate } from "./router";
import {
  PlaceFields,
  TargetsUnavailable,
  useAgentTargets,
  type PlaceLocation,
} from "./StationTargetPicker";
import { Skeleton } from "./states";
import { ChoiceModelField } from "./SwarmAgentsPage";
import {
  FormActions,
  FormDialog,
  FormSection,
  SaveButton,
  TextField,
  useConfirm,
  useWrite,
} from "./settingsForm";

const t = messages.swarmSettings;

const memberName = (member: BftSwarmMember) =>
  member.name ?? member.email ?? messages.members.unnamed;

/**
 * An Agent Swarm's Settings: its name and runtime ids, the default Task model,
 * the default place to run Tasks, the Access list, and archiving. Members see
 * the same page read-only. Every write answers the whole
 * page, which replaces the loaded one; it carries the caller's role read again,
 * so a self-demotion drops the admin controls. A caller who removed their own
 * access is sent to the swarms list with a notice.
 */
export function SwarmSettingsPage({
  org,
  project,
  data: loaded,
}: {
  org: string;
  project: string;
  data: BftSwarmSettings;
}) {
  const [data, setData] = useState(loaded);
  const manage = data.project.role === "admin";
  const applyAccess = (result: BftSwarmAccessWrite) => {
    if ("redirect" in result) {
      showFlash({ kind: "info", text: result.notice }, result.redirect);
      navigate(result.redirect);
    } else setData(result);
  };

  // `/access` addresses (and `#access` links) land on the Access section.
  useEffect(() => {
    if (window.location.hash === "#access")
      document.getElementById("access")?.scrollIntoView({ block: "start" });
  }, []);

  return (
    <>
      <General
        data={data}
        manage={manage}
        // The shell re-reads its swarm list after the write.
        onSaved={setData}
        org={org}
        project={project}
      />
      <TaskModel
        data={data}
        manage={manage}
        onSaved={setData}
        org={org}
        project={project}
      />
      <TaskPlace
        data={data}
        manage={manage}
        onSaved={setData}
        org={org}
        project={project}
      />
      <Access
        data={data}
        manage={manage}
        onChange={applyAccess}
        org={org}
        project={project}
      />
      {manage ? <DangerZone data={data} org={org} project={project} /> : null}
    </>
  );
}

function General({
  org,
  project,
  data,
  manage,
  onSaved,
}: {
  org: string;
  project: string;
  data: BftSwarmSettings;
  manage: boolean;
  onSaved: (data: BftSwarmSettings) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [name, setName] = useState(data.project.name);
  const ids: [string, string | null][] = [
    [t.orgRuntimeId, data.org_runtime_id],
    [t.swarmRuntimeId, data.project.runtime_id],
  ];

  return (
    <FormSection title={t.generalTitle}>
      {manage ? (
        <>
          <TextField
            disabled={write.busy}
            error={write.fields.name}
            hint={t.nameHint}
            label={t.name}
            onChange={setName}
            value={name}
          />
          <FormActions
            write={write.fields.name ? { ...write, error: undefined } : write}
          >
            <SaveButton
              busy={write.busy}
              disabled={name.trim() === data.project.name}
              onPress={() =>
                write.run(() => api.renameSwarm(org, project, name.trim()), onSaved)
              }
            />
          </FormActions>
        </>
      ) : null}
      <dl className="bft-kv">
        {manage ? null : (
          <div>
            <dt>{t.name}</dt>
            <dd title={data.project.name}>{data.project.name}</dd>
          </div>
        )}
        <div>
          <dt>{t.slug}</dt>
          <dd className="bft-mono">{data.project.slug ?? "—"}</dd>
        </div>
        <div>
          <dt>{t.status}</dt>
          <dd>
            <State value={data.project.status} />
          </dd>
        </div>
        {ids.map(([label, value]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd className="bft-id-row">
              <span className="bft-mono bft-truncate" title={value ?? undefined}>
                {value ?? "—"}
              </span>
              {value ? (
                <CopyButton label={messages.common.copyLabel(label)} text={value} />
              ) : null}
            </dd>
          </div>
        ))}
      </dl>
    </FormSection>
  );
}

/**
 * The model a Task runs when the Router names none. Until an admin sets one,
 * each Task runs the org default Task model; choosing that row (key "") clears
 * the default again.
 */
function TaskModel({
  org,
  project,
  data,
  manage,
  onSaved,
}: {
  org: string;
  project: string;
  data: BftSwarmSettings;
  manage: boolean;
  onSaved: (data: BftSwarmSettings) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const model = data.task_model;
  const [chosen, setChosen] = useState(model.key);
  const row = model.models.find(
    (candidate) => candidate.key === chosen && !candidate.disabled
  );

  return (
    <FormSection description={t.taskModelNote} title={t.taskModelTitle}>
      {model.status === "unavailable" ? (
        <p className="bft-quiet bft-quiet-inline">{t.taskModelUnavailable}</p>
      ) : manage ? (
        <>
          <ChoiceModelField
            busy={write.busy}
            chosen={chosen}
            label={t.taskModelLabel}
            models={model.models}
            onChange={setChosen}
          />
          <FormActions write={write}>
            <SaveButton
              busy={write.busy}
              disabled={chosen === model.key || !row}
              onPress={() => {
                const choice = row?.choice;
                if (choice)
                  write.run(() => api.setSwarmTaskModel(org, project, choice), onSaved);
                else if (row)
                  write.run(() => api.clearSwarmTaskModel(org, project), onSaved);
              }}
            />
          </FormActions>
        </>
      ) : (
        <dl className="bft-kv">
          <div>
            <dt>{t.taskModelLabel}</dt>
            <dd title={model.label ?? undefined}>{model.label ?? "—"}</dd>
          </div>
        </dl>
      )}
    </FormSection>
  );
}

/**
 * Where a Task runs when the Router names no place: Salix (also when none is
 * set), the Cloud VM or one of the swarm's stations.
 */
function TaskPlace({
  org,
  project,
  data,
  manage,
  onSaved,
}: {
  org: string;
  project: string;
  data: BftSwarmSettings;
  manage: boolean;
  onSaved: (data: BftSwarmSettings) => void;
}) {
  const setting = data.task_place;
  return (
    <FormSection description={t.taskPlaceNote} title={t.taskPlaceTitle}>
      {setting.status === "unavailable" || !setting.place ? (
        <p className="bft-quiet bft-quiet-inline">{t.taskPlaceUnavailable}</p>
      ) : manage ? (
        <TaskPlaceForm
          current={setting.place}
          onSaved={onSaved}
          org={org}
          project={project}
        />
      ) : (
        <dl className="bft-kv">
          <div>
            <dt>{t.taskPlaceLabel}</dt>
            <dd title={setting.label ?? undefined}>{setting.label ?? "—"}</dd>
          </div>
        </dl>
      )}
    </FormSection>
  );
}

const placeOf = (
  location: PlaceLocation,
  deviceId: string
): BftSwarmTaskPlace | null =>
  location === "station"
    ? deviceId
      ? { kind: "station", device_id: deviceId }
      : null
    : { kind: location };

function TaskPlaceForm({
  org,
  project,
  current,
  onSaved,
}: {
  org: string;
  project: string;
  current: BftSwarmTaskPlace;
  onSaved: (data: BftSwarmSettings) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [targets, retry] = useAgentTargets(org, project);
  const [location, setLocation] = useState<PlaceLocation>(current.kind);
  const [deviceId, setDeviceId] = useState(
    current.kind === "station" ? current.device_id : ""
  );
  if (targets.state === "loading") return <Skeleton height={32} />;
  if (targets.state === "error") return <TargetsUnavailable retry={retry} />;
  // A station that is gone or no longer selectable is not a choice to save.
  const station = targets.data.stations.find(
    (item) => item.id === deviceId && item.selectable
  );
  const chosen = placeOf(location, station?.id ?? "");
  const unchanged =
    chosen?.kind === current.kind &&
    (chosen.kind !== "station" ||
      (current.kind === "station" && chosen.device_id === current.device_id));
  return (
    <>
      <PlaceFields
        deviceId={deviceId}
        disabled={write.busy}
        location={location}
        locations={["salix", "station", "cloud_vm"]}
        onLocation={setLocation}
        onStation={setDeviceId}
        targets={targets.data}
      />
      <FormActions write={write}>
        <SaveButton
          busy={write.busy}
          disabled={!chosen || unchanged}
          onPress={() => {
            if (chosen)
              write.run(() => api.setSwarmTaskPlace(org, project, chosen), onSaved);
          }}
        />
      </FormActions>
    </>
  );
}

function Access({
  org,
  project,
  data,
  manage,
  onChange,
}: {
  org: string;
  project: string;
  data: BftSwarmSettings;
  manage: boolean;
  onChange: (result: BftSwarmAccessWrite) => void;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const roleWrite = useWrite();
  const [adding, setAdding] = useState(false);
  const more = useAccessPages(org, project, data.access);
  const { members } = more;

  return (
    <FormSection
      action={
        manage ? (
          <Button hierarchy="secondary-gray" onPress={() => setAdding(true)} size="xs">
            {t.addUser}
          </Button>
        ) : undefined
      }
      description={t.accessNote}
      id="access"
      title={t.accessTitle}
    >
      {members.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.accessEmpty}</p>
      ) : (
        <ul className="bft-list">
          {members.map((member) => {
            const name = memberName(member);
            const granted = member.granted_at && formatRelative(member.granted_at);
            return (
              <li className="bft-setting-row" key={member.id}>
                <span className="bft-setting-row-main">
                  <span className="bft-truncate" title={name}>
                    {name}
                  </span>
                  <span className="bft-setting-row-sub bft-truncate">
                    {[
                      member.name ? member.email : null,
                      granted ? t.granted(granted) : null,
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </span>
                </span>
                {manage ? (
                  <>
                    <Dropdown
                      ariaLabel={t.roleFor(name)}
                      disabled={roleWrite.busy}
                      items={(["admin", "user"] as const).map((role) => ({
                        id: role,
                        label: t.roles[role],
                      }))}
                      onChange={(role) => {
                        if (role !== member.role)
                          roleWrite.run(
                            () =>
                              api.changeSwarmAccess(
                                org,
                                project,
                                member.id,
                                role as BftSwarmAccessRole
                              ),
                            onChange
                          );
                      }}
                      size="xs"
                      value={member.role}
                      width="content"
                    />
                    <Button
                      aria-label={t.removeFor(name)}
                      hierarchy="tertiary-gray"
                      onPress={() =>
                        confirm.ask({
                          title: t.removeTitle,
                          description: t.removeBody(name, data.project.name),
                          confirmLabel: t.remove,
                          action: () =>
                            api
                              .removeSwarmAccess(org, project, member.id)
                              .then(onChange),
                        })
                      }
                      size="xs"
                    >
                      {t.remove}
                    </Button>
                  </>
                ) : (
                  <span className="bft-role-text">{t.roles[member.role]}</span>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {roleWrite.error ? (
        <p className="bft-dialog-error" role="alert">
          {roleWrite.error}
        </p>
      ) : null}
      {more.failed ? (
        <div className="bft-quiet-row" role="alert">
          <p className="bft-quiet bft-quiet-inline">{t.loadMoreGrantsFailed}</p>
          <button className="bft-btn bft-btn-sm" onClick={more.load} type="button">
            {messages.states.retry}
          </button>
        </div>
      ) : more.cursor ? (
        <div>
          <Button
            disabled={more.loading}
            hierarchy="secondary-gray"
            onPress={more.load}
            size="xs"
          >
            {more.loading ? t.loadingMoreGrants : t.loadMoreGrants}
          </Button>
        </div>
      ) : null}
      {adding ? (
        <AddUserDialog
          onAdded={(next) => {
            onChange(next);
            setAdding(false);
          }}
          onClose={() => setAdding(false)}
          org={org}
          project={project}
          swarm={data.project.name}
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

function AddUserDialog({
  org,
  project,
  swarm,
  onAdded,
  onClose,
}: {
  org: string;
  project: string;
  swarm: string;
  onAdded: (result: BftSwarmAccessWrite) => void;
  onClose: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<BftSwarmAccessRole>("user");
  const [missing, setMissing] = useState(false);

  const submit = () => {
    if (!email.trim()) {
      setMissing(true);
      return;
    }
    setMissing(false);
    write.run(
      () => api.grantSwarmAccess(org, project, { email: email.trim(), role }),
      onAdded
    );
  };

  return (
    <FormDialog
      description={t.addBody(swarm)}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={submit}
      submitLabel={t.addUser}
      title={t.addTitle}
      write={write.fields.email ? { ...write, error: undefined } : write}
    >
      <InputField
        autoComplete="off"
        className="w-full"
        disabled={write.busy}
        fieldSize="sm"
        label={t.emailLabel}
        name="email"
        onChange={(event) => setEmail(event.target.value)}
        placeholder={t.emailPlaceholder}
        type="email"
        value={email}
        wrapperClassName="bft-form-field"
        {...(missing || write.fields.email
          ? { errorMessage: missing ? t.emailRequired : write.fields.email }
          : {})}
      />
      <Dropdown
        className="bft-form-field"
        disabled={write.busy}
        items={(["user", "admin"] as const).map((option) => ({
          id: option,
          label: t.roles[option],
          subtitle: t.roleHints[option],
        }))}
        label={t.roleLabel}
        onChange={(value) => setRole(value as BftSwarmAccessRole)}
        size="sm"
        value={role}
      />
    </FormDialog>
  );
}

interface AccessPages {
  from: BftSwarmAccessPage;
  members: BftSwarmMember[];
  cursor: string | null;
  loading: boolean;
  failed: boolean;
}

/**
 * The Access list past its first page, loaded on request. A write answers a
 * new first page, which starts the list over.
 */
function useAccessPages(org: string, project: string, first: BftSwarmAccessPage) {
  const api = useApi();
  const fresh = (): AccessPages => ({
    from: first,
    members: [],
    cursor: first.next_cursor,
    loading: false,
    failed: false,
  });
  const [state, setState] = useState(fresh);
  const current = state.from === first ? state : fresh();
  const load = () => {
    const cursor = current.cursor;
    if (!cursor || current.loading) return;
    const update = (next: (previous: AccessPages) => AccessPages) =>
      setState((previous) => (previous.from === first ? next(previous) : previous));
    setState({ ...current, loading: true, failed: false });
    api.swarmAccess(org, project, cursor).then(
      (page) =>
        update((previous) => {
          const seen = new Set(
            [...first.members, ...previous.members].map((member) => member.id)
          );
          return {
            ...previous,
            members: [
              ...previous.members,
              ...page.members.filter((member) => !seen.has(member.id)),
            ],
            cursor: page.next_cursor,
            loading: false,
          };
        }),
      () => update((previous) => ({ ...previous, loading: false, failed: true }))
    );
  };
  return {
    members: [...first.members, ...current.members],
    cursor: current.cursor,
    loading: current.loading,
    failed: current.failed,
    load,
  };
}

function DangerZone({
  org,
  project,
  data,
}: {
  org: string;
  project: string;
  data: BftSwarmSettings;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const archived = data.project.status === "archived";

  return (
    <FormSection
      description={archived ? t.archived : t.archiveNote}
      title={t.dangerTitle}
    >
      {archived ? null : (
        <div>
          <Button
            hierarchy="secondary-gray"
            onPress={() =>
              confirm.ask({
                title: t.archiveTitle,
                description: t.archiveBody(data.project.name),
                confirmLabel: t.archive,
                action: () =>
                  api.archiveSwarm(org, project).then(({ redirect, notice }) => {
                    showFlash({ kind: "info", text: notice }, redirect);
                    navigate(redirect);
                  }),
              })
            }
            size="sm"
          >
            {t.archive}
          </Button>
        </div>
      )}
      {confirm.dialog}
    </FormSection>
  );
}
