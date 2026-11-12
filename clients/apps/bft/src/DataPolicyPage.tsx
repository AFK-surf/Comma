import { Button } from "@comma/ui/components/Button";
import { Dropdown } from "@comma/ui/components/dropdown";
import { createContext, useContext, useEffect, useState } from "react";
import type {
  BftDataPolicy,
  BftDataPolicyChange,
  BftDataPolicyConnect,
  BftDataPolicyPerson,
  BftDataPolicyScope,
} from "./api";
import { writeErrorMessage } from "./dialogs";
import { messages } from "./messages";
import { NoSwarms, SwarmPicker, useSwarmChoice, type Swarm } from "./MeetingsPage";
import { useApi, useResource } from "./resource";
import {
  FormDialog,
  FormSection,
  SettingsPage,
  TextField,
  useWrite,
} from "./settingsForm";

const t = messages.dataPolicy;

// A principal key is `provider_user|<connect>|<id>`; people read the id.
const principalId = (key: string) => key.split("|")[2] ?? key;

type People = Record<string, Record<string, BftDataPolicyPerson>>;
// The name and email of every person the page shows, by connect and id.
const PeopleContext = createContext<People>({});

/** A person as the page shows them: name first, email beside it, else the id. */
function usePerson(connect: string, id: string) {
  const person = useContext(PeopleContext)[connect]?.[id];
  const main = person?.name ?? person?.email ?? id;
  const sub = person?.name ? person.email : null;
  return { main, sub, label: [main, sub].filter(Boolean).join(" · ") };
}

/** The names and emails of the people the page shows: one read per connect. */
function usePeople(org: string, project: string, policy: BftDataPolicy | null) {
  const api = useApi();
  const [described, setDescribed] = useState<People>({});

  useEffect(() => {
    if (!policy) return;
    let current = true;
    for (const connect of policy.connects) {
      const id = connect.connect_id;
      const shown = [
        ...policy.supervisors.filter((s) => s.connect_id === id).map((s) => s.id),
        ...connect.clearances.flatMap((c) => c.principals.map(principalId)),
        ...connect.principals.map((p) => p.id),
      ];
      const ids = [...new Set(shown)];
      if (ids.length === 0) continue;
      api.dataPolicyDescribe(org, project, id, ids.slice(0, 50)).then(
        (people) => {
          if (current)
            setDescribed((value) => ({ ...value, [id]: { ...value[id], ...people } }));
        },
        () => undefined
      );
    }
    return () => {
      current = false;
    };
  }, [api, org, project, policy]);

  return described;
}
const scopeName = (scope: BftDataPolicyScope) =>
  scope.display_name?.trim() || scope.scope_id;

type Apply = (change: BftDataPolicyChange) => Promise<BftDataPolicy>;
type Open =
  | { kind: "classify"; connect: string; scope: BftDataPolicyScope }
  | { kind: "grant"; connect: string }
  | { kind: "supervisor" }
  | { kind: "ssh_host"; host: BftDataPolicy["ssh_hosts"][number] };

export function DataPolicyPage({
  org,
  swarms,
}: {
  org: string;
  swarms: readonly Swarm[];
}) {
  const api = useApi();
  const [swarm, choose] = useSwarmChoice(org, swarms);
  const key = `data-policy:${org}:${swarm?.id ?? ""}`;
  const [resource, retry] = useResource(key, (signal) =>
    swarm ? api.dataPolicy(org, swarm.id, signal) : Promise.resolve(null)
  );
  // A write answers with the settings read again; they replace the page's
  // copy until the next read (a retry, or coming back to this swarm), which
  // is a new resource and always wins.
  const [written, setWritten] = useState<{
    base: typeof resource;
    data: BftDataPolicy;
  }>();
  const write = useWrite();
  const [open, setOpen] = useState<Open | null>(null);
  const shown =
    resource.state === "ready" && written?.base === resource
      ? { state: "ready" as const, data: written.data }
      : resource;
  const people = usePeople(
    org,
    swarm?.id ?? "",
    shown.state === "ready" ? shown.data : null
  );

  const apply: Apply = (change) =>
    api.changeDataPolicy(org, swarm?.id ?? "", change).then((data) => {
      setWritten({ base: resource, data });
      return data;
    });
  const change = (next: BftDataPolicyChange) =>
    write.run(
      () => apply(next),
      () => undefined
    );

  return (
    <SettingsPage
      actions={
        <SwarmPicker
          onChange={(id) => {
            write.reset();
            choose(id);
          }}
          swarms={swarms}
          value={swarm?.id}
        />
      }
      description={t.description}
      onRetry={retry}
      resource={shown}
      title={t.title}
      wide
    >
      {(policy) =>
        policy === null ? (
          <NoSwarms body={t.noSwarms} />
        ) : (
          <PeopleContext.Provider value={people}>
            {write.error ? (
              <p className="bft-dialog-error" role="alert">
                {write.error}
              </p>
            ) : null}
            <FormSection title={t.checking}>
              <div className="bft-settings-grid">
                <div className="bft-form">
                  <Dropdown
                    disabled={write.busy}
                    items={Object.entries(t.modes).map(([id, label]) => ({
                      id,
                      label,
                    }))}
                    label={t.modeLabel}
                    onChange={(mode) => change({ kind: "group", mode })}
                    size="sm"
                    value={policy.mode}
                  />
                  <p className="bft-form-section-note">{t.modeNotes[policy.mode]}</p>
                </div>
                <div className="bft-form">
                  <Dropdown
                    disabled={write.busy}
                    items={Object.entries(t.languages).map(([id, label]) => ({
                      id,
                      label,
                    }))}
                    label={t.languageLabel}
                    onChange={(language) => change({ kind: "group", language })}
                    size="sm"
                    value={policy.language}
                  />
                  <p className="bft-form-section-note">{t.languageNote}</p>
                </div>
              </div>
            </FormSection>
            <Supervisors
              busy={write.busy}
              onChange={change}
              onOpen={setOpen}
              policy={policy}
            />
            {policy.connects.length === 0 ? (
              <p className="bft-quiet bft-quiet-inline">{t.noConnects}</p>
            ) : null}
            {policy.connects.map((connect) => (
              <Workspace
                busy={write.busy}
                connect={connect}
                key={connect.connect_id}
                onChange={change}
                onOpen={setOpen}
              />
            ))}
            <SshHosts busy={write.busy} onOpen={setOpen} policy={policy} />
            {open?.kind === "classify" ? (
              <ClassifyDialog
                apply={apply}
                audiences={policy.audience_modes}
                connect={open.connect}
                onClose={() => setOpen(null)}
                scope={open.scope}
              />
            ) : null}
            {open?.kind === "supervisor" ? (
              <SupervisorDialog
                apply={apply}
                onClose={() => setOpen(null)}
                org={org}
                policy={policy}
                project={swarm?.id ?? ""}
              />
            ) : null}
            {open?.kind === "ssh_host" ? (
              <SshHostDialog
                apply={apply}
                host={open.host}
                onClose={() => setOpen(null)}
              />
            ) : null}
            {open?.kind === "grant" ? (
              <GrantDialog
                apply={apply}
                connect={open.connect}
                onClose={() => setOpen(null)}
                org={org}
                project={swarm?.id ?? ""}
              />
            ) : null}
          </PeopleContext.Provider>
        )
      }
    </SettingsPage>
  );
}

const connectName = (policy: BftDataPolicy, id: string) => {
  const connect = policy.connects.find((item) => item.connect_id === id);
  return connect?.name || connect?.provider || id;
};

function SupervisorName({
  policy,
  supervisor,
}: {
  policy: BftDataPolicy;
  supervisor: BftDataPolicy["supervisors"][number];
}) {
  const person = usePerson(supervisor.connect_id, supervisor.id);
  return (
    <span className="bft-setting-row-main">
      <span>{person.main}</span>
      <span className="bft-setting-row-sub">
        {[person.sub, connectName(policy, supervisor.connect_id)]
          .filter(Boolean)
          .join(" · ")}
      </span>
    </span>
  );
}

function Supervisors({
  policy,
  busy,
  onChange,
  onOpen,
}: {
  policy: BftDataPolicy;
  busy: boolean;
  onChange: (change: BftDataPolicyChange) => void;
  onOpen: (open: Open) => void;
}) {
  const { supervisors } = policy;

  return (
    <FormSection
      action={
        policy.connects.length > 0 ? (
          <button
            className="bft-btn bft-btn-sm"
            disabled={busy}
            onClick={() => onOpen({ kind: "supervisor" })}
            type="button"
          >
            {t.addSupervisor}
          </button>
        ) : null
      }
      description={t.supervisorsHint}
      title={t.supervisors}
    >
      {supervisors.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.noSupervisors}</p>
      ) : (
        <ul className="bft-list">
          {supervisors.map((supervisor) => (
            <li
              className="bft-setting-row"
              key={`${supervisor.connect_id}|${supervisor.id}`}
            >
              <SupervisorName policy={policy} supervisor={supervisor} />
              <button
                aria-label={t.removeSupervisor(supervisor.id)}
                className="bft-btn bft-btn-sm"
                disabled={busy}
                onClick={() =>
                  onChange({
                    kind: "supervisors",
                    supervisors: supervisors.filter((item) => item !== supervisor),
                  })
                }
                type="button"
              >
                {messages.common.remove}
              </button>
            </li>
          ))}
        </ul>
      )}
    </FormSection>
  );
}

function SupervisorDialog({
  apply,
  policy,
  onClose,
  org,
  project,
}: {
  apply: Apply;
  policy: BftDataPolicy;
  onClose: () => void;
  org: string;
  project: string;
}) {
  const write = useWrite();
  const [connect, setConnect] = useState(policy.connects[0]?.connect_id ?? "");
  const [person, setPerson] = useState<BftDataPolicyPerson | null>(null);
  const [missing, setMissing] = useState(false);

  return (
    <FormDialog
      description={t.addSupervisorBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={() => {
        if (!person) return setMissing(true);
        write.run(
          () =>
            apply({
              kind: "supervisors",
              supervisors: [
                ...policy.supervisors,
                { connect_id: connect, id: person.id },
              ],
            }),
          onClose
        );
      }}
      submitLabel={t.addSupervisor}
      title={t.addSupervisor}
      write={write}
    >
      <Dropdown
        className="bft-form-field"
        disabled={write.busy}
        items={policy.connects.map((item) => ({
          id: item.connect_id,
          label: connectName(policy, item.connect_id),
        }))}
        label={t.workspace}
        onChange={(next) => {
          // A different workspace has other people.
          setConnect(next);
          setPerson(null);
        }}
        size="sm"
        value={connect}
      />
      <PersonPicker
        connect={connect}
        disabled={write.busy}
        key={connect}
        onChange={(chosen) => {
          setPerson(chosen);
          if (chosen) setMissing(false);
        }}
        org={org}
        project={project}
        value={person}
      />
      {missing ? (
        <p className="bft-dialog-error" role="alert">
          {t.personRequired}
        </p>
      ) : null}
    </FormDialog>
  );
}

function Workspace({
  connect,
  busy,
  onChange,
  onOpen,
}: {
  connect: BftDataPolicyConnect;
  busy: boolean;
  onChange: (change: BftDataPolicyChange) => void;
  onOpen: (open: Open) => void;
}) {
  const id = connect.connect_id;
  const placement = (value: string | null) =>
    (value && t.placementWords[value]) ?? t.unknown;
  const clearances = connect.clearances.flatMap(({ tag, principals }) =>
    principals.map((principal) => ({ tag, principal }))
  );

  return (
    <FormSection
      action={
        connect.available ? (
          <button
            className="bft-btn bft-btn-sm"
            disabled={busy}
            onClick={() => onOpen({ kind: "grant", connect: id })}
            type="button"
          >
            {t.grant}
          </button>
        ) : null
      }
      description={
        !connect.available
          ? t.connectUnavailable
          : connect.truncated
            ? t.truncated
            : undefined
      }
      title={connect.name || connect.provider || id}
    >
      {connect.available ? (
        <div className="bft-settings-grid">
          <div className="bft-form">
            <p className="bft-field-label">{t.conversations}</p>
            {connect.scopes.length === 0 ? (
              <p className="bft-quiet bft-quiet-inline">{t.noConversations}</p>
            ) : (
              <ul className="bft-list">
                {connect.scopes.map((scope) => (
                  <li key={scope.scope_id}>
                    <button
                      className="bft-plugin-row"
                      disabled={busy}
                      onClick={() => onOpen({ kind: "classify", connect: id, scope })}
                      type="button"
                    >
                      <span className="bft-plugin-name">{scopeName(scope)}</span>
                      <span className="bft-plugin-description">
                        {[
                          t.kinds[scope.kind ?? ""] ?? t.kindUnknown,
                          t.audiences[scope.audience_mode] ?? scope.audience_mode,
                          ...scope.tags,
                          scope.sealed && t.sealed,
                          !scope.classified && t.defaults,
                          scope.observed_at === null && t.notSeen,
                        ]
                          .filter(Boolean)
                          .join(" · ")}
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
          <div className="bft-form">
            <p className="bft-field-label">{t.clearances}</p>
            <p className="bft-form-section-note">{t.clearancesHint}</p>
            {clearances.length === 0 ? (
              <p className="bft-quiet bft-quiet-inline">{t.noClearances}</p>
            ) : (
              <ul className="bft-list">
                {clearances.map(({ tag, principal }) => (
                  <li className="bft-setting-row" key={`${tag}|${principal}`}>
                    <ClearanceName connect={id} principal={principal} tag={tag} />
                    <button
                      aria-label={t.withdraw(principalId(principal), tag)}
                      className="bft-btn bft-btn-sm"
                      disabled={busy}
                      onClick={() =>
                        onChange({ kind: "withdraw", connect: id, tag, principal })
                      }
                      type="button"
                    >
                      {messages.common.remove}
                    </button>
                  </li>
                ))}
              </ul>
            )}
            <p className="bft-field-label">{t.placements}</p>
            <p className="bft-form-section-note">{t.placementsHint}</p>
            {connect.principals.length === 0 ? (
              <p className="bft-quiet bft-quiet-inline">{t.noPrincipals}</p>
            ) : (
              <ul className="bft-list">
                {connect.principals.map((principal) => (
                  <li className="bft-setting-row" key={principal.id}>
                    <PrincipalName
                      connect={id}
                      id={principal.id}
                      note={t.providerSays(placement(principal.observed))}
                    />
                    <Dropdown
                      ariaLabel={t.placementFor(principal.id)}
                      className="bft-placement"
                      disabled={busy}
                      items={Object.entries(t.placementOptions).map(
                        ([value, label]) => ({
                          id: value,
                          label,
                        })
                      )}
                      onChange={(value) =>
                        onChange({
                          kind: "place",
                          connect: id,
                          user: principal.id,
                          placement: value === "provider" ? "" : value,
                        })
                      }
                      size="sm"
                      value={principal.override ?? "provider"}
                    />
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      ) : null}
    </FormSection>
  );
}

function ClearanceName({
  connect,
  principal,
  tag,
}: {
  connect: string;
  principal: string;
  tag: string;
}) {
  const person = usePerson(connect, principalId(principal));
  return (
    <span className="bft-setting-row-main">
      <span>{person.main}</span>
      <span className="bft-setting-row-sub">
        {[person.sub, tag].filter(Boolean).join(" · ")}
      </span>
    </span>
  );
}

function PrincipalName({
  connect,
  id,
  note,
}: {
  connect: string;
  id: string;
  note: string;
}) {
  const person = usePerson(connect, id);
  return (
    <span className="bft-setting-row-main">
      <span>{person.main}</span>
      <span className="bft-setting-row-sub">
        {[person.sub, note].filter(Boolean).join(" · ")}
      </span>
    </span>
  );
}

/**
 * Finds a person of one connect by name, email or user id. A pasted id or
 * email is looked up too, so the person shows by name before it is saved.
 */
const personLabel = (person: BftDataPolicyPerson) =>
  [person.name ?? person.id, person.email].filter(Boolean).join(" · ");

function PersonPicker({
  org,
  project,
  connect,
  value,
  onChange,
  disabled,
}: {
  org: string;
  project: string;
  connect: string;
  value: BftDataPolicyPerson | null;
  onChange: (person: BftDataPolicyPerson | null) => void;
  disabled: boolean;
}) {
  const api = useApi();
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<BftDataPolicyPerson[] | null>(null);
  const [error, setError] = useState<string>();
  const [loading, setLoading] = useState(false);

  const search = () => {
    if (!query.trim() || !connect) return;
    setLoading(true);
    setError(undefined);
    api.dataPolicyPeople(org, project, connect, query.trim()).then(
      (people) => {
        setLoading(false);
        setFound(people);
      },
      (failure: unknown) => {
        setLoading(false);
        setError(writeErrorMessage(failure) ?? undefined);
      }
    );
  };

  return (
    <div className="bft-form">
      <div className="bft-route-connect">
        <TextField
          disabled={disabled || loading}
          hint={t.personSearchHint}
          label={t.personSearchLabel}
          onChange={setQuery}
          placeholder={t.personSearchPlaceholder}
          value={query}
        />
        <Button
          disabled={disabled || loading || !query.trim()}
          hierarchy="secondary-gray"
          onPress={search}
          size="sm"
        >
          {t.personSearch}
        </Button>
      </div>
      {error ? (
        <p className="bft-dialog-error" role="alert">
          {error}
        </p>
      ) : found === null ? null : found.length === 0 ? (
        <p className="bft-form-section-note">{t.personNoResults}</p>
      ) : (
        <Dropdown
          className="bft-form-field"
          disabled={disabled}
          items={found.map((person) => ({
            id: person.id,
            label: person.name ?? person.email ?? person.id,
            ...(person.name && person.email ? { subtitle: person.email } : {}),
          }))}
          label={t.personChoose}
          onChange={(id) => onChange(found.find((person) => person.id === id) ?? null)}
          placeholder={t.personChoosePlaceholder}
          size="sm"
          {...(value ? { value: value.id } : {})}
        />
      )}
      {value ? (
        <p className="bft-form-section-note">{t.personChosen(personLabel(value))}</p>
      ) : null}
    </div>
  );
}

function ClassifyDialog({
  apply,
  connect,
  scope,
  audiences,
  onClose,
}: {
  apply: Apply;
  connect: string;
  scope: BftDataPolicyScope;
  audiences: string[];
  onClose: () => void;
}) {
  const write = useWrite();
  const [tags, setTags] = useState(scope.tags.join(", "));
  const [audience, setAudience] = useState(scope.audience_mode);
  const [sealed, setSealed] = useState(String(scope.sealed));
  const save = () =>
    write.run(
      () =>
        apply({
          kind: "classify",
          connect,
          scope: scope.scope_id,
          tags: tags
            .split(",")
            .map((tag) => tag.trim())
            .filter(Boolean),
          audience_mode: audience,
          sealed: sealed === "true",
        }),
      onClose
    );

  return (
    <FormDialog
      description={t.classifyBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={save}
      title={t.classifyTitle(scopeName(scope))}
      write={write}
    >
      <TextField
        disabled={write.busy}
        hint={t.tagsHint}
        label={t.tags}
        onChange={setTags}
        value={tags}
      />
      <Dropdown
        className="bft-form-field"
        disabled={write.busy}
        items={audiences.map((id) => ({ id, label: t.audiences[id] ?? id }))}
        label={t.audience}
        onChange={setAudience}
        size="sm"
        value={audience}
      />
      <Dropdown
        className="bft-form-field"
        disabled={write.busy}
        items={Object.entries(t.sealedOptions).map(([id, label]) => ({ id, label }))}
        label={t.sealedLabel}
        onChange={setSealed}
        size="sm"
        value={sealed}
      />
      {scope.classified ? (
        <div>
          <button
            className="bft-btn bft-btn-sm"
            disabled={write.busy}
            onClick={() =>
              write.run(
                () => apply({ kind: "reset", connect, scope: scope.scope_id }),
                onClose
              )
            }
            type="button"
          >
            {t.reset}
          </button>
        </div>
      ) : null}
    </FormDialog>
  );
}

function GrantDialog({
  apply,
  connect,
  onClose,
  org,
  project,
}: {
  apply: Apply;
  connect: string;
  onClose: () => void;
  org: string;
  project: string;
}) {
  const write = useWrite();
  const [tag, setTag] = useState("");
  const [person, setPerson] = useState<BftDataPolicyPerson | null>(null);
  const [missing, setMissing] = useState(false);

  return (
    <FormDialog
      description={t.grantBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={() => {
        if (!person) return setMissing(true);
        write.run(
          () => apply({ kind: "grant", connect, tag: tag.trim(), user: person.id }),
          onClose
        );
      }}
      submitLabel={t.grant}
      title={t.grant}
      write={write}
    >
      <TextField disabled={write.busy} label={t.tag} onChange={setTag} value={tag} />
      <PersonPicker
        connect={connect}
        disabled={write.busy}
        onChange={(chosen) => {
          setPerson(chosen);
          if (chosen) setMissing(false);
        }}
        org={org}
        project={project}
        value={person}
      />
      {missing ? (
        <p className="bft-dialog-error" role="alert">
          {t.personRequired}
        </p>
      ) : null}
    </FormDialog>
  );
}

function SshHosts({
  policy,
  busy,
  onOpen,
}: {
  policy: BftDataPolicy;
  busy: boolean;
  onOpen: (open: Open) => void;
}) {
  return (
    <FormSection
      description={policy.ssh_hosts_available ? t.sshHostsHint : t.sshHostsUnavailable}
      title={t.sshHosts}
    >
      {!policy.ssh_hosts_available ? null : policy.ssh_hosts.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.noSshHosts}</p>
      ) : (
        <ul className="bft-list">
          {policy.ssh_hosts.map((host) => (
            <li className="bft-setting-row" key={host.name}>
              <span className="bft-setting-row-main">
                <span>{host.name}</span>
                <span className="bft-setting-row-sub">
                  {[
                    host.tag ? t.sshRestricted(host.tag) : t.sshAnyone,
                    host.fingerprint,
                  ].join(" · ")}
                </span>
              </span>
              <button
                aria-label={t.restrictTitle(host.name)}
                className="bft-btn bft-btn-sm"
                disabled={busy}
                onClick={() => onOpen({ kind: "ssh_host", host })}
                type="button"
              >
                {t.restrict}
              </button>
            </li>
          ))}
        </ul>
      )}
    </FormSection>
  );
}

function SshHostDialog({
  apply,
  host,
  onClose,
}: {
  apply: Apply;
  host: BftDataPolicy["ssh_hosts"][number];
  onClose: () => void;
}) {
  const write = useWrite();
  const [tag, setTag] = useState(host.tag ?? "");

  return (
    <FormDialog
      description={t.restrictBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={() =>
        write.run(
          () =>
            apply({ kind: "ssh_host", fingerprint: host.fingerprint, tag: tag.trim() }),
          onClose
        )
      }
      title={t.restrictTitle(host.name)}
      write={write}
    >
      <TextField disabled={write.busy} label={t.tag} onChange={setTag} value={tag} />
    </FormDialog>
  );
}
