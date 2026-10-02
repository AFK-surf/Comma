import { Dropdown } from "@comma/ui";
import { useState } from "react";
import type {
  BftDataPolicy,
  BftDataPolicyChange,
  BftDataPolicyConnect,
  BftDataPolicyScope,
} from "./api";
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
const principalLabel = (key: string) => key.split("|")[2] ?? key;
const scopeName = (scope: BftDataPolicyScope) =>
  scope.display_name?.trim() || scope.scope_id;

type Apply = (change: BftDataPolicyChange) => Promise<BftDataPolicy>;
type Open =
  | { kind: "classify"; connect: string; scope: BftDataPolicyScope }
  | { kind: "grant"; connect: string };

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
          <>
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
            {open?.kind === "classify" ? (
              <ClassifyDialog
                apply={apply}
                audiences={policy.audience_modes}
                connect={open.connect}
                onClose={() => setOpen(null)}
                scope={open.scope}
              />
            ) : null}
            {open?.kind === "grant" ? (
              <GrantDialog
                apply={apply}
                connect={open.connect}
                onClose={() => setOpen(null)}
              />
            ) : null}
          </>
        )
      }
    </SettingsPage>
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
                    <span className="bft-setting-row-main">
                      <span>{principalLabel(principal)}</span>
                      <span className="bft-setting-row-sub">{tag}</span>
                    </span>
                    <button
                      aria-label={t.withdraw(principalLabel(principal), tag)}
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
                    <span className="bft-setting-row-main">
                      <span>{principal.id}</span>
                      <span className="bft-setting-row-sub">
                        {t.providerSays(placement(principal.observed))}
                      </span>
                    </span>
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
}: {
  apply: Apply;
  connect: string;
  onClose: () => void;
}) {
  const write = useWrite();
  const [tag, setTag] = useState("");
  const [user, setUser] = useState("");

  return (
    <FormDialog
      description={t.grantBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={() =>
        write.run(
          () => apply({ kind: "grant", connect, tag: tag.trim(), user: user.trim() }),
          onClose
        )
      }
      submitLabel={t.grant}
      title={t.grant}
      write={write}
    >
      <TextField disabled={write.busy} label={t.tag} onChange={setTag} value={tag} />
      <TextField
        disabled={write.busy}
        hint={t.userHint}
        label={t.user}
        onChange={setUser}
        value={user}
      />
    </FormDialog>
  );
}
