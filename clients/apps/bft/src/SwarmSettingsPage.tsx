import { Button, Dropdown, InputField } from "@comma/ui";
import { useEffect, useState } from "react";
import type {
  BftSwarmAccessPage,
  BftSwarmAccessRole,
  BftSwarmAccessWrite,
  BftSwarmMember,
  BftSwarmSettings,
} from "./api";
import { CopyButton } from "./dialogs";
import { showFlash } from "./flash";
import { formatRelative } from "./format";
import { messages } from "./messages";
import { State } from "./ProjectOverviewPage";
import { useApi } from "./resource";
import { navigate } from "./router";
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
 * An Agent Swarm's Settings: its name and runtime ids, the Access list, and
 * archiving. Members see the same page read-only. Every write answers the whole
 * page, which replaces the loaded one; it carries the caller's role read again,
 * so a self-demotion drops the admin controls. A caller who removed their own
 * access is sent to the swarms list with a notice.
 */
export function SwarmSettingsPage({
  org,
  project,
  data: loaded,
  onRenamed,
}: {
  org: string;
  project: string;
  data: BftSwarmSettings;
  /** The shell's swarm list shows the new name. */
  onRenamed: () => void;
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
        onSaved={(next) => {
          setData(next);
          onRenamed();
        }}
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
