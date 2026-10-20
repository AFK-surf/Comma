import { Button } from "@comma/ui/components/Button";
import { Checkbox } from "@comma/ui/components/checkbox";
import { Dropdown } from "@comma/ui/components/dropdown";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from "react";
import { qqMenuScopes, type BftQqMenuItem } from "./api";
import type {
  BftRunChecks,
  BftSignalClaim,
  BftSlackCredentials,
  BftSlackInbound,
  BftSlackManifest,
  BftSwarmConnections,
  BftTailnetSection,
} from "./api";
import { useConnectionConfirm } from "./connectionConfirm";
import { CodeBlock, CopyButton, writeErrorMessage } from "./dialogs";
import { showFlash } from "./flash";
import { formatRelative, humanize } from "./format";
import { messages } from "./messages";
import { orgHref, projectHref } from "./navSpec";
import { useApi, useLastReady, type Resource } from "./resource";
import { navigate, spaLinkClick } from "./router";
import {
  FieldError,
  FormDialog,
  FormSection,
  SecretField,
  SettingsPage,
  TextField,
  useConfirm,
  useWrite,
} from "./settingsForm";
import { StaleNotice } from "./states";
import { RowMenu } from "./SwarmDevicesPage";
import { oauthFailed } from "./SwarmPluginsPage";

const t = messages.swarmConnections;

type Data = BftSwarmConnections;
type Feishu = NonNullable<Data["messaging"]["feishu"]>;
type Slack = NonNullable<Data["messaging"]["slack"]>;
type Lark = NonNullable<Data["messaging"]["lark"]>;
type Qq = NonNullable<Data["messaging"]["qq"]>;
type Tone = "ok" | "warn" | "error" | "neutral";

/** The messaging sections a `?provider=` address scrolls to. */
export const messagingProviders = ["feishu", "lark", "slack", "qq"] as const;

/** The section a `?provider=` deep link names, if it is one of this page's. */
export function providerSection(search: string) {
  const provider = new URLSearchParams(search).get("provider");
  return (messagingProviders as readonly string[]).includes(provider ?? "")
    ? provider
    : null;
}

const routeTones: Record<Feishu["route"]["status"], Tone> = {
  ready: "ok",
  disabled: "error",
  missing_router: "warn",
  not_connected: "neutral",
  unknown: "warn",
};

// Reasons a check is still settling rather than waiting on a person.
const pendingReasons = new Set([
  "calendar_initial_sync_pending",
  "calendar_enrollment_retrying",
  "calendar_source_maintenance_retrying",
]);

type Gate = BftRunChecks["checks"]["gates"][number];

/** A check's status word: a retrying calendar check is pending, not manual. */
export function gateStatus(gate: Pick<Gate, "status" | "reason_class">) {
  if (gate.status === "needs_manual" && pendingReasons.has(gate.reason_class ?? ""))
    return "pending";
  return ["ok", "needs_manual", "fail", "skipped"].includes(gate.status)
    ? gate.status
    : "skipped";
}

const gateTones: Record<string, Tone> = {
  ok: "ok",
  pending: "warn",
  needs_manual: "warn",
  fail: "error",
  skipped: "neutral",
};

/** An evidence value as text: lists of words joined, anything else as JSON. */
export function evidenceText(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value) && value.every((item) => typeof item === "string"))
    return value.join(", ");
  return JSON.stringify(value);
}

const evidenceRows = (evidence: Record<string, unknown>) =>
  Object.entries(evidence).filter(
    ([, value]) =>
      value !== null &&
      value !== "" &&
      !(Array.isArray(value) && value.length === 0) &&
      !(
        typeof value === "object" &&
        !Array.isArray(value) &&
        Object.keys(value).length === 0
      )
  );

const providerLabel = (provider: string) => t.providers[provider] ?? humanize(provider);
const toolkitLabel = (toolkit: string) =>
  t.toolkits[toolkit]?.label ?? humanize(toolkit);

function Status({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span className="bft-status" data-tone={tone}>
      <span className="bft-truncate">{children}</span>
    </span>
  );
}

interface Writes {
  org: string;
  project: string;
  manage: boolean;
  orgAdmin: boolean;
  notify: (notice: string) => void;
  fail: (error: unknown) => void;
}

/**
 * An Agent Swarm's connections: where people reach it (Feishu, Lark, Slack, QQ
 * and Signal), the third-party accounts its agents act with (managed OAuth
 * and Composio), and the organization's Tailscale network its agents reach.
 * Swarm admins connect and change them; everyone else reads.
 * `?provider=feishu|lark|slack|qq` opens the page at that messaging section.
 */
export function SwarmConnectionsPage({
  org,
  project,
  first,
  onRetry,
}: {
  org: string;
  project: string;
  first: Resource<Data>;
  onRetry: () => void;
}) {
  const { data, resource, stale } = useLastReady(first);
  const path = projectHref(org, project, "/connections");
  const notify = useCallback(
    (notice: string) => {
      showFlash({ kind: "info", text: notice }, path);
      onRetry();
    },
    [path, onRetry]
  );
  // A refused write is said above the page, which is read again.
  const fail = useCallback(
    (error: unknown) => {
      const text = writeErrorMessage(error);
      if (text) showFlash({ kind: "error", text }, path);
      onRetry();
    },
    [path, onRetry]
  );

  // The provider sends the browser back here; a failure says so once.
  useEffect(() => {
    if (!oauthFailed(window.location.search)) return;
    showFlash({ kind: "error", text: t.oauthFailed }, path);
    navigate(path, { replace: true });
  }, [path]);

  // A deep link to a messaging section scrolls there once the page is read.
  const scrolled = useRef(false);
  useEffect(() => {
    if (!data || scrolled.current) return;
    scrolled.current = true;
    const section = providerSection(window.location.search);
    if (section) document.getElementById(section)?.scrollIntoView({ block: "start" });
  }, [data]);

  return (
    <SettingsPage
      description={data ? t.description(data.project.name) : undefined}
      onRetry={onRetry}
      resource={resource}
      title={t.title}
      wide
    >
      {(page) => {
        const writes: Writes = {
          org,
          project,
          manage: page.project.role === "admin",
          orgAdmin: page.org_admin,
          notify,
          fail,
        };
        return (
          <>
            {stale ? <StaleNotice onRetry={onRetry} /> : null}
            <div className="bft-settings-grid">
              <Group note={t.messagingNote} title={t.messagingTitle}>
                {page.messaging.status === "ok" ? (
                  <>
                    {page.messaging.feishu ? (
                      <FeishuSection
                        feishu={page.messaging.feishu}
                        swarm={page.project.name}
                        writes={writes}
                      />
                    ) : null}
                    {page.messaging.lark ? (
                      <LarkSection lark={page.messaging.lark} writes={writes} />
                    ) : null}
                    {page.messaging.slack ? (
                      <SlackSection slack={page.messaging.slack} writes={writes} />
                    ) : null}
                    {page.messaging.qq ? (
                      <QqSection qq={page.messaging.qq} writes={writes} />
                    ) : null}
                  </>
                ) : (
                  <SectionState onRetry={onRetry} status={page.messaging.status} />
                )}
                <SignalSection signal={page.signal} writes={writes} />
              </Group>
              <Group note={t.accountsNote} title={t.accountsTitle}>
                <AccountsSection
                  accounts={page.accounts}
                  onRetry={onRetry}
                  writes={writes}
                />
                <ComposioSection composio={page.composio} writes={writes} />
              </Group>
              <Group note={t.networkNote} title={t.networkTitle}>
                <TailnetSection
                  onRetry={onRetry}
                  tailnet={page.tailnet}
                  writes={writes}
                />
              </Group>
            </div>
          </>
        );
      }}
    </SettingsPage>
  );
}

/** A titled column of sections. */
function Group({
  title,
  note,
  children,
}: {
  title: string;
  note: string;
  children: ReactNode;
}) {
  const id = useId();
  return (
    <section aria-labelledby={id} className="bft-connections-group">
      <div className="bft-connections-group-head">
        <h2 id={id}>{title}</h2>
        <p>{note}</p>
      </div>
      {children}
    </section>
  );
}

/** A runtime section that could not be read, said quietly with a retry. */
function SectionState({
  status,
  onRetry,
}: {
  status: "preparing" | "unavailable" | "ok";
  onRetry: () => void;
}) {
  return (
    <output className="bft-quiet-row bft-connections-state">
      <p className="bft-quiet bft-quiet-inline">
        {status === "preparing" ? t.preparing : t.unavailable}
      </p>
      <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
        {messages.states.retry}
      </button>
    </output>
  );
}

const flags = (pairs: [string, boolean][]) =>
  pairs.map(([name, on]) => t.flag(name, on)).join(" · ");

const relative = (iso: string | null) => (iso && formatRelative(iso)) || null;

// ---- Feishu ----

/** A Feishu, Lark, Slack or QQ connect's writes: turn it on or off, or delete it after confirming. */
function ConnectMenu({
  connect,
  writes,
  onAsk,
}: {
  connect: { connect_id: string; disabled: boolean };
  writes: Writes;
  onAsk: ReturnType<typeof useConfirm>["ask"];
}) {
  const api = useApi();
  const { org, project } = writes;
  const id = connect.connect_id;
  return (
    <RowMenu
      items={[
        {
          id: connect.disabled ? "enable" : "disable",
          label: connect.disabled ? t.enable : t.disable,
          onAction: () =>
            void api
              .setImConnectEnabled(org, project, id, connect.disabled)
              .then(({ notice }) => writes.notify(notice), writes.fail),
        },
        {
          id: "delete",
          label: t.delete,
          destructive: true,
          onAction: () =>
            onAsk({
              title: t.deleteTitle,
              description: t.deleteBody(id),
              confirmLabel: t.delete,
              action: () =>
                api
                  .deleteImConnect(org, project, id)
                  .then(({ notice }) => writes.notify(notice)),
            }),
        },
      ]}
      name={id}
    />
  );
}

function FeishuSection({
  feishu,
  swarm,
  writes,
}: {
  feishu: Feishu;
  swarm: string;
  writes: Writes;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const checks = useWrite();
  // A result belongs to the page read it ran on; any later read clears it.
  const [ran, setRan] = useState<{ from: Feishu; checks: BftRunChecks }>();
  const result = ran?.from === feishu ? ran.checks : undefined;
  const { org, project, manage } = writes;
  const route = feishu.route;

  return (
    <FormSection
      action={
        <Status tone={routeTones[route.status]}>{t.routeStatuses[route.status]}</Status>
      }
      description={t.feishuNote}
      id="feishu"
      level={3}
      title={t.feishuTitle}
    >
      {feishu.connects.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.feishuEmpty}</p>
      ) : (
        <ul aria-label={t.feishuConnects} className="bft-list bft-connects">
          {feishu.connects.map((connect) => (
            <li className="bft-connect" key={connect.connect_id}>
              <div className="bft-connect-head">
                <span className="bft-connect-main">
                  <span className="bft-mono bft-truncate">{connect.connect_id}</span>
                  <span className="bft-setting-row-sub">
                    {[
                      connect.disabled
                        ? t.disabledState
                        : (t.connectStatuses[connect.status] ??
                          humanize(connect.status)),
                      relative(connect.updated_at)
                        ? t.updated(relative(connect.updated_at) ?? "")
                        : null,
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </span>
                </span>
                {manage ? (
                  <ConnectMenu connect={connect} onAsk={confirm.ask} writes={writes} />
                ) : null}
              </div>
              {connect.webhook_url ? (
                <div className="bft-connect-url">
                  <span className="bft-field-label">{t.webhookUrl}</span>
                  <span className="bft-mono bft-truncate" title={connect.webhook_url}>
                    {connect.webhook_url}
                  </span>
                  <CopyButton
                    label={messages.common.copyLabel(t.webhookUrl)}
                    text={connect.webhook_url}
                  />
                </div>
              ) : null}
              <span className="bft-setting-row-sub">
                {flags([
                  [t.secret, connect.app_secret_configured],
                  [t.verification, connect.verification_token_configured],
                  [t.encryption, connect.encrypt_key_configured],
                ])}
              </span>
            </li>
          ))}
        </ul>
      )}
      <details className="bft-disclosure">
        <summary>{t.routeDetails}</summary>
        <p className="bft-form-section-note">{t.routeExplain}</p>
        <dl className="bft-kv">
          <div>
            <dt>{t.routeSwarm}</dt>
            <dd>{swarm}</dd>
          </div>
          <div>
            <dt>{t.routeRouter}</dt>
            <dd>{route.router ?? t.noRouter}</dd>
          </div>
          <div>
            <dt>{t.routeConnect}</dt>
            <dd className="bft-mono">{route.connect_id ?? t.notCreated}</dd>
          </div>
        </dl>
        <p className="bft-form-section-note">{t.routeNext[route.status]}</p>
      </details>
      {manage && feishu.connects.length > 0 ? (
        <div className="bft-connect-checks">
          <Button
            hierarchy="secondary-gray"
            isDisabled={checks.busy}
            onPress={() =>
              checks.run(
                () => api.runFeishuChecks(org, project),
                (value) => setRan({ from: feishu, checks: value })
              )
            }
            size="xs"
          >
            {checks.busy ? t.running : t.runChecks}
          </Button>
        </div>
      ) : null}
      {checks.error ? (
        <p className="bft-dialog-error" role="alert">
          {checks.error}
        </p>
      ) : null}
      {result ? <Checks result={result} title={t.checksTitle} /> : null}
      {manage ? <FeishuConnectForm feishu={feishu} writes={writes} /> : null}
      {confirm.dialog}
    </FormSection>
  );
}

function FeishuConnectForm({ feishu, writes }: { feishu: Feishu; writes: Writes }) {
  const api = useApi();
  const write = useWrite();
  const [appId, setAppId] = useState(feishu.apps[0]?.app_id);
  const [name, setName] = useState("");
  const chosen = feishu.apps.find((app) => app.app_id === appId) ?? feishu.apps[0];

  if (feishu.apps.length === 0) {
    return (
      <div className="bft-quiet-row bft-quiet-row-flush">
        <p className="bft-quiet bft-quiet-inline">
          {t.noFeishuApp} {writes.orgAdmin ? null : t.askOrgAdmin}
        </p>
        {writes.orgAdmin ? (
          <a
            className="bft-btn bft-btn-sm"
            href={orgHref(writes.org, "/settings/integrations#feishu")}
            onClick={spaLinkClick}
          >
            {t.setUpFeishuApp}
          </a>
        ) : null}
      </div>
    );
  }

  return (
    <div className="bft-connect-form">
      <h4 className="bft-field-label">{t.connectFeishu}</h4>
      <div className="bft-connect-fields">
        <Dropdown
          className="bft-form-field"
          disabled={write.busy}
          items={feishu.apps.map((app) => ({ id: app.app_id, label: app.name }))}
          label={t.feishuApp}
          onChange={setAppId}
          size="sm"
          {...(chosen ? { value: chosen.app_id } : {})}
        />
        <TextField
          disabled={write.busy}
          hint={t.connectNameHint}
          label={t.connectName}
          onChange={setName}
          placeholder={chosen?.name ?? ""}
          value={name}
        />
      </div>
      <div className="bft-form-actions">
        {write.error ? (
          <p className="bft-dialog-error" role="alert">
            {write.error}
          </p>
        ) : (
          <p className="bft-form-section-note">{t.feishuLimit}</p>
        )}
        <Button
          hierarchy="primary"
          isDisabled={!chosen || write.busy}
          onPress={() => {
            if (!chosen) return;
            write.run(
              () =>
                api.createFeishuConnect(writes.org, writes.project, {
                  app_id: chosen.app_id,
                  app_name: name.trim(),
                }),
              ({ notice }) => {
                setName("");
                writes.notify(notice);
              }
            );
          }}
          size="sm"
        >
          {write.busy ? messages.common.working : t.connect}
        </Button>
      </div>
    </div>
  );
}

// ---- Lark ----

/**
 * The swarm's Lark apps. An app is connected with its own credentials; the
 * request URL shown on the connect is then saved in the Lark Developer
 * Console. A Feishu connect, above, takes an app of the organization instead.
 */
function LarkSection({ lark, writes }: { lark: Lark; writes: Writes }) {
  const api = useApi();
  const confirm = useConfirm();
  const [adding, setAdding] = useState(false);
  const [checking, setChecking] = useState<string>();
  // A result belongs to the page read it ran on; any later read clears it.
  const [ran, setRan] = useState<{ from: Lark; app: string; checks: BftRunChecks }>();
  const result = ran?.from === lark ? ran : undefined;
  const [checkError, setCheckError] = useState<string>();
  const { org, project, manage } = writes;

  const runChecks = (connectId: string, app: string) => {
    setChecking(connectId);
    setCheckError(undefined);
    api.runLarkChecks(org, project, connectId).then(
      (checks) => {
        setChecking(undefined);
        setRan({ from: lark, app, checks });
      },
      (error: unknown) => {
        setChecking(undefined);
        setCheckError(writeErrorMessage(error));
      }
    );
  };

  return (
    <FormSection
      action={
        manage ? (
          <Button hierarchy="primary" onPress={() => setAdding(true)} size="xs">
            {t.addLark}
          </Button>
        ) : (
          <Status tone={routeTones[lark.route.status]}>
            {t.routeStatuses[lark.route.status]}
          </Status>
        )
      }
      description={t.larkNote}
      id="lark"
      level={3}
      title={t.larkTitle}
    >
      {lark.connects.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.larkEmpty}</p>
      ) : (
        <ul aria-label={t.larkConnects} className="bft-list bft-connects">
          {lark.connects.map((connect) => {
            const app = connect.app_name ?? connect.app_id ?? connect.connect_id;
            return (
              <li className="bft-connect" key={connect.connect_id}>
                <div className="bft-connect-head">
                  <span className="bft-connect-main">
                    <span className="bft-connect-title">
                      <span className="bft-truncate">{app}</span>
                      <Status tone={connect.disabled ? "error" : "ok"}>
                        {connect.disabled
                          ? t.disabledState
                          : (t.connectStatuses[connect.status] ??
                            humanize(connect.status))}
                      </Status>
                    </span>
                    <span className="bft-setting-row-sub bft-truncate">
                      {[
                        connect.app_id ? t.larkAppIdValue(connect.app_id) : null,
                        relative(connect.updated_at)
                          ? t.updated(relative(connect.updated_at) ?? "")
                          : null,
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </span>
                  </span>
                  {manage ? (
                    <Button
                      aria-label={t.larkRunChecksFor(app)}
                      hierarchy="tertiary-gray"
                      isDisabled={checking !== undefined}
                      onPress={() => runChecks(connect.connect_id, app)}
                      size="xs"
                    >
                      {checking === connect.connect_id ? t.running : t.runChecks}
                    </Button>
                  ) : null}
                  {manage ? (
                    <ConnectMenu
                      connect={connect}
                      onAsk={confirm.ask}
                      writes={writes}
                    />
                  ) : null}
                </div>
                {connect.webhook_url ? (
                  <div className="bft-connect-url">
                    <span className="bft-field-label">{t.larkRequestUrl}</span>
                    <span className="bft-mono bft-truncate" title={connect.webhook_url}>
                      {connect.webhook_url}
                    </span>
                    <CopyButton
                      label={messages.common.copyLabel(t.larkRequestUrl)}
                      text={connect.webhook_url}
                    />
                  </div>
                ) : null}
                <span className="bft-setting-row-sub">
                  {flags([
                    [t.larkAppSecret, connect.app_secret_configured],
                    [t.larkVerificationToken, connect.verification_token_configured],
                    [t.larkEncryptKey, connect.encrypt_key_configured],
                  ])}
                </span>
              </li>
            );
          })}
        </ul>
      )}
      {checkError ? (
        <p className="bft-dialog-error" role="alert">
          {checkError}
        </p>
      ) : null}
      {result ? (
        <Checks result={result.checks} title={t.larkChecksFor(result.app)} />
      ) : null}
      {lark.connects.length > 0 ? (
        <>
          <p className="bft-form-section-note">{t.larkRequestUrlHint}</p>
          <p className="bft-form-section-note">{t.larkPublishHint}</p>
        </>
      ) : null}
      {lark.scope_json ? (
        <div className="bft-form-field">
          <h4 className="bft-field-label">{t.larkScopes}</h4>
          <ul className="bft-list bft-setting-rows">
            <li className="bft-setting-row">
              <span className="bft-setting-row-main">
                <span className="bft-truncate">{t.larkScopesPreset}</span>
                <span className="bft-setting-row-sub">{t.larkScopesHint}</span>
              </span>
              <CopyButton
                label={`${t.larkCopyScopes}: ${t.larkScopesPreset}`}
                text={lark.scope_json}
              >
                {t.larkCopyScopes}
              </CopyButton>
            </li>
          </ul>
        </div>
      ) : null}
      {adding ? (
        <LarkDialog
          onClose={() => setAdding(false)}
          onCreated={(notice) => {
            setAdding(false);
            writes.notify(notice);
          }}
          writes={writes}
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

const emptyLarkDraft = {
  app_id: "",
  app_secret: "",
  verification_token: "",
  encrypt_key: "",
};

/** What a Lark draft still lacks, by field; the server applies the same rule. */
function larkDraftErrors(draft: typeof emptyLarkDraft) {
  const errors: Partial<Record<keyof typeof emptyLarkDraft, string>> = {};
  if (!draft.app_id) errors.app_id = t.larkAppIdRequired;
  if (!draft.app_secret) errors.app_secret = t.larkAppSecretRequired;
  if (!draft.verification_token && !draft.encrypt_key)
    errors.verification_token = t.larkEventKeyRequired;
  return errors;
}

function LarkDialog({
  writes,
  onClose,
  onCreated,
}: {
  writes: Writes;
  onClose: () => void;
  onCreated: (notice: string) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [draft, setDraft] = useState(emptyLarkDraft);
  // What the last submit found missing; a refused write's field errors otherwise.
  const [missing, setMissing] = useState<ReturnType<typeof larkDraftErrors>>({});
  const errors = { ...write.fields, ...missing };
  const change = (patch: Partial<typeof emptyLarkDraft>) => {
    setDraft((value) => ({ ...value, ...patch }));
    setMissing({});
  };

  return (
    <FormDialog
      description={t.larkDialogNote}
      onClose={onClose}
      onSubmit={() => {
        const connect = {
          app_id: draft.app_id.trim(),
          app_secret: draft.app_secret.trim(),
          verification_token: draft.verification_token.trim(),
          encrypt_key: draft.encrypt_key.trim(),
        };
        const lacks = larkDraftErrors(connect);
        setMissing(lacks);
        if (Object.keys(lacks).length > 0) return;
        write.run(
          () => api.createLarkConnect(writes.org, writes.project, connect),
          ({ notice }) => onCreated(notice)
        );
      }}
      submitLabel={t.connect}
      title={t.addLark}
      write={write}
    >
      <TextField
        error={errors.app_id}
        label={t.larkAppId}
        onChange={(app_id) => change({ app_id })}
        value={draft.app_id}
      />
      <SecretField
        configured={false}
        error={errors.app_secret}
        label={t.larkAppSecret}
        onChange={(app_secret) => change({ app_secret })}
        value={draft.app_secret}
      />
      <p className="bft-form-section-note">{t.larkEventKeyNote}</p>
      <SecretField
        configured={false}
        error={errors.verification_token}
        label={t.larkVerificationToken}
        onChange={(verification_token) => change({ verification_token })}
        value={draft.verification_token}
      />
      <SecretField
        configured={false}
        error={errors.encrypt_key}
        label={t.larkEncryptKey}
        onChange={(encrypt_key) => change({ encrypt_key })}
        value={draft.encrypt_key}
      />
    </FormDialog>
  );
}

// ---- Slack ----

function SlackSection({ slack, writes }: { slack: Slack; writes: Writes }) {
  const api = useApi();
  const confirm = useConfirm();
  const [adding, setAdding] = useState(false);
  const [checking, setChecking] = useState<string>();
  // A result belongs to the page read it ran on, so disabling or deleting
  // the connect, or any later read, clears it.
  const [ran, setRan] = useState<{
    from: Slack;
    connectId: string;
    checks: BftRunChecks;
  }>();
  const result = ran?.from === slack ? ran : undefined;
  const [checkError, setCheckError] = useState<string>();
  const { org, project, manage } = writes;

  const runChecks = (connectId: string) => {
    setChecking(connectId);
    setCheckError(undefined);
    api.runSlackChecks(org, project, connectId).then(
      (checks) => {
        setChecking(undefined);
        setRan({ from: slack, connectId, checks });
      },
      (error: unknown) => {
        setChecking(undefined);
        setCheckError(writeErrorMessage(error));
      }
    );
  };

  return (
    <FormSection
      action={
        manage ? (
          <Button hierarchy="primary" onPress={() => setAdding(true)} size="xs">
            {t.addSlack}
          </Button>
        ) : undefined
      }
      description={t.slackNote}
      id="slack"
      level={3}
      title={t.slackTitle}
    >
      {slack.connects.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.slackEmpty}</p>
      ) : (
        <ul aria-label={t.slackConnects} className="bft-list bft-connects">
          {slack.connects.map((connect) => (
            <li className="bft-connect" key={connect.connect_id}>
              <div className="bft-connect-head">
                <span className="bft-connect-main">
                  <span className="bft-connect-title">
                    <span className="bft-mono bft-truncate">{connect.connect_id}</span>
                    <Status
                      tone={
                        connect.disabled ? "error" : connect.installed ? "ok" : "warn"
                      }
                    >
                      {connect.disabled
                        ? t.disabledState
                        : connect.installed
                          ? t.installed
                          : t.awaitingInstall}
                    </Status>
                  </span>
                  <span className="bft-setting-row-sub bft-truncate">
                    {[
                      connect.workspace,
                      connect.inbound_agent ? t.inboundTo(connect.inbound_agent) : null,
                      relative(connect.updated_at)
                        ? t.updated(relative(connect.updated_at) ?? "")
                        : null,
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </span>
                </span>
                {connect.install_url ? (
                  <a
                    className="bft-link bft-setting-row-link"
                    href={connect.install_url}
                    rel="noopener noreferrer"
                    target="_blank"
                  >
                    {t.openInstall}
                  </a>
                ) : null}
                {manage ? (
                  <Button
                    aria-label={t.runChecksFor(connect.connect_id)}
                    hierarchy="tertiary-gray"
                    isDisabled={checking !== undefined}
                    onPress={() => runChecks(connect.connect_id)}
                    size="xs"
                  >
                    {checking === connect.connect_id ? t.running : t.runChecks}
                  </Button>
                ) : null}
                {manage ? (
                  <ConnectMenu connect={connect} onAsk={confirm.ask} writes={writes} />
                ) : null}
              </div>
              <span className="bft-setting-row-sub">
                {flags([
                  [t.clientSecret, connect.client_secret_configured],
                  [t.signingSecret, connect.signing_secret_configured],
                ])}
              </span>
            </li>
          ))}
        </ul>
      )}
      {checkError ? (
        <p className="bft-dialog-error" role="alert">
          {checkError}
        </p>
      ) : null}
      {result ? (
        <Checks result={result.checks} title={t.checksFor(result.connectId)} />
      ) : null}
      {adding ? (
        <SlackDialog
          onClose={() => setAdding(false)}
          onCreated={(notice) => {
            setAdding(false);
            writes.notify(notice);
          }}
          slack={slack}
          writes={writes}
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

// ---- QQ ----

/**
 * The swarm's QQ bots. A bot is connected with its AppID and AppSecret; the
 * callback address shown on the connect is then saved in the QQ bot console.
 */
function QqSection({ qq, writes }: { qq: Qq; writes: Writes }) {
  const confirm = useConfirm();
  const [adding, setAdding] = useState(false);
  const [menuOf, setMenuOf] = useState<Qq["connects"][number] | null>(null);
  const { manage } = writes;

  return (
    <FormSection
      action={
        manage ? (
          <Button hierarchy="primary" onPress={() => setAdding(true)} size="xs">
            {t.addQq}
          </Button>
        ) : (
          <Status tone={routeTones[qq.route.status]}>
            {t.routeStatuses[qq.route.status]}
          </Status>
        )
      }
      description={t.qqNote}
      id="qq"
      level={3}
      title={t.qqTitle}
    >
      {qq.connects.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.qqEmpty}</p>
      ) : (
        <ul aria-label={t.qqConnects} className="bft-list bft-connects">
          {qq.connects.map((connect) => (
            <li className="bft-connect" key={connect.connect_id}>
              <div className="bft-connect-head">
                <span className="bft-connect-main">
                  <span className="bft-connect-title">
                    <span className="bft-truncate">
                      {connect.bot_name ?? connect.app_id ?? connect.connect_id}
                    </span>
                    <Status tone={connect.disabled ? "error" : "ok"}>
                      {connect.disabled
                        ? t.disabledState
                        : (t.connectStatuses[connect.status] ??
                          humanize(connect.status))}
                    </Status>
                  </span>
                  <span className="bft-setting-row-sub bft-truncate">
                    {[
                      connect.app_id ? t.qqAppIdValue(connect.app_id) : null,
                      relative(connect.updated_at)
                        ? t.updated(relative(connect.updated_at) ?? "")
                        : null,
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </span>
                </span>
                {manage ? (
                  <ConnectMenu connect={connect} onAsk={confirm.ask} writes={writes} />
                ) : null}
              </div>
              {connect.webhook_url ? (
                <div className="bft-connect-url">
                  <span className="bft-field-label">{t.qqCallbackUrl}</span>
                  <span className="bft-mono bft-truncate" title={connect.webhook_url}>
                    {connect.webhook_url}
                  </span>
                  <CopyButton
                    label={messages.common.copyLabel(t.qqCallbackUrl)}
                    text={connect.webhook_url}
                  />
                </div>
              ) : null}
              <div className="bft-connect-url">
                <span className="bft-field-label">{t.qqMenu}</span>
                <span className="bft-mono bft-truncate">
                  {[
                    "status",
                    "compact",
                    "help",
                    ...connect.command_menu.map((item) => item.name),
                  ]
                    .map((name) => `/${name}`)
                    .join(" ")}
                </span>
                {manage ? (
                  <Button
                    hierarchy="tertiary-gray"
                    onPress={() => setMenuOf(connect)}
                    size="xs"
                  >
                    {t.qqMenuEdit}
                  </Button>
                ) : null}
              </div>
              {qqMenuWarning(connect.command_menu_sync) ? (
                <span className="bft-setting-row-sub">
                  {qqMenuWarning(connect.command_menu_sync)}
                </span>
              ) : null}
              <span className="bft-setting-row-sub">
                {flags([[t.qqAppSecret, connect.app_secret_configured]])}
              </span>
            </li>
          ))}
        </ul>
      )}
      {qq.connects.length > 0 ? (
        <>
          <p className="bft-form-section-note">{t.qqCallbackHint}</p>
          <p className="bft-form-section-note">{t.qqRecordHint}</p>
        </>
      ) : null}
      {adding ? (
        <QqDialog
          onClose={() => setAdding(false)}
          onCreated={(notice) => {
            setAdding(false);
            writes.notify(notice);
          }}
          writes={writes}
        />
      ) : null}
      {menuOf ? (
        <QqMenuDialog
          connect={menuOf}
          onClose={() => setMenuOf(null)}
          onSaved={(notice) => {
            setMenuOf(null);
            writes.notify(notice);
          }}
          writes={writes}
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

/** What stops QQ from showing the menu, if anything. */
function qqMenuWarning(sync: Record<string, string>) {
  const outcomes = Object.values(sync);
  if (outcomes.includes("owner_panel")) return t.qqMenuOwnerPanel;
  if (outcomes.includes("failed")) return t.qqMenuFailed;
  return null;
}

const emptyQqMenuItem: BftQqMenuItem = {
  name: "",
  description: "",
  prompt: "",
  scope: "all",
  admin_only: false,
};

/**
 * The shortcuts of a QQ bot's command menu. The control commands are fixed;
 * saving replaces the shortcuts and sends the menu to QQ.
 */
function QqMenuDialog({
  connect,
  writes,
  onClose,
  onSaved,
}: {
  connect: Qq["connects"][number];
  writes: Writes;
  onClose: () => void;
  onSaved: (notice: string) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [items, setItems] = useState<BftQqMenuItem[]>(connect.command_menu);
  const change = (index: number, patch: Partial<BftQqMenuItem>) =>
    setItems((current) =>
      current.map((item, at) => (at === index ? { ...item, ...patch } : item))
    );

  return (
    <FormDialog
      description={t.qqMenuNote}
      onClose={onClose}
      onSubmit={() =>
        write.run(
          () =>
            api.updateQqMenu(
              writes.org,
              writes.project,
              connect.connect_id,
              items.map((item) => ({
                ...item,
                name: item.name.trim(),
                description: item.description.trim(),
                prompt: item.prompt.trim(),
              }))
            ),
          ({ notice }) => onSaved(notice)
        )
      }
      title={t.qqMenu}
      wide
      write={write}
    >
      <p className="bft-form-section-note">{t.qqMenuFixed}</p>
      {items.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.qqMenuEmpty}</p>
      ) : null}
      {items.map((item, index) => (
        // The position is the identity: a shortcut has no id until it is saved.
        // oxlint-disable-next-line react/no-array-index-key
        <fieldset
          aria-label={t.qqMenuItem(index + 1)}
          className="bft-form-group"
          key={index}
        >
          <TextField
            hint={t.qqMenuNameHint}
            label={t.qqMenuName}
            onChange={(name) => change(index, { name })}
            value={item.name}
          />
          <TextField
            hint={t.qqMenuDescriptionHint}
            label={t.qqMenuDescription}
            onChange={(description) => change(index, { description })}
            value={item.description}
          />
          <TextField
            hint={t.qqMenuPromptHint}
            label={t.qqMenuPrompt}
            onChange={(prompt) => change(index, { prompt })}
            value={item.prompt}
          />
          <Dropdown
            className="bft-form-field"
            items={qqMenuScopes.map((scope) => ({
              id: scope,
              label: t.qqMenuScopes[scope] ?? scope,
            }))}
            label={t.qqMenuScope}
            onChange={(scope) =>
              change(index, {
                scope: qqMenuScopes.find((known) => known === scope) ?? "all",
              })
            }
            size="sm"
            value={item.scope}
          />
          {item.scope === "private" ? null : (
            <Checkbox
              checked={item.admin_only}
              label={t.qqMenuAdminOnly}
              onChange={(event) => change(index, { admin_only: event.target.checked })}
              size="sm"
            />
          )}
          <Button
            hierarchy="tertiary-gray"
            onPress={() =>
              setItems((current) => current.filter((_, at) => at !== index))
            }
            size="xs"
          >
            {t.qqMenuRemove}
          </Button>
        </fieldset>
      ))}
      <Button
        hierarchy="secondary-gray"
        onPress={() => setItems((current) => [...current, emptyQqMenuItem])}
        size="xs"
      >
        {t.qqMenuAdd}
      </Button>
    </FormDialog>
  );
}

function QqDialog({
  writes,
  onClose,
  onCreated,
}: {
  writes: Writes;
  onClose: () => void;
  onCreated: (notice: string) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [draft, setDraft] = useState({ app_id: "", app_secret: "" });

  return (
    <FormDialog
      description={t.qqDialogNote}
      onClose={onClose}
      onSubmit={() =>
        write.run(
          () =>
            api.createQqConnect(writes.org, writes.project, {
              app_id: draft.app_id.trim(),
              app_secret: draft.app_secret.trim(),
            }),
          ({ notice }) => onCreated(notice)
        )
      }
      submitLabel={t.connect}
      title={t.addQq}
      write={write}
    >
      <TextField
        error={write.fields.app_id}
        label={t.qqAppId}
        onChange={(app_id) => setDraft((value) => ({ ...value, app_id }))}
        value={draft.app_id}
      />
      <SecretField
        configured={false}
        error={write.fields.app_secret}
        label={t.qqAppSecret}
        onChange={(app_secret) => setDraft((value) => ({ ...value, app_secret }))}
        value={draft.app_secret}
      />
    </FormDialog>
  );
}

/**
 * Where the Slack form delivers at first: the swarm's Router. Without a known
 * Router no choice is made, and the server delivers to the Router.
 */
function initialInbound(
  slack: Pick<Slack, "inbound_agents" | "default_inbound_agent_id">
) {
  const router = slack.default_inbound_agent_id;
  if (router && slack.inbound_agents.some((agent) => agent.id === router))
    return router;
  return slack.inbound_agents[0]?.id ?? null;
}

// Dropdown ids for "each new thread becomes a Task" and "the swarm's default
// Task model" (key ""); neither can collide with an agent id or a model key.
const inboundTasks = "__tasks";
const defaultTaskModel = "__default";

/** Step one creates the Slack app from its manifest; step two pastes its credentials. */
function SlackDialog({
  slack,
  writes,
  onClose,
  onCreated,
}: {
  slack: Slack;
  writes: Writes;
  onClose: () => void;
  onCreated: (notice: string) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [draft, setDraft] = useState<BftSlackCredentials>({
    app_name: slack.app_name,
    app_id: "",
    client_id: "",
    client_secret: "",
    signing_secret: "",
  });
  // A Router's id, `inboundTasks`, or null for the swarm's Router.
  const [inbound, setInbound] = useState(() => initialInbound(slack));
  const [modelKey, setModelKey] = useState("");
  const manifest = useManifest(writes.org, writes.project, draft.app_name, slack);
  const set = (patch: Partial<BftSlackCredentials>) =>
    setDraft((value) => ({ ...value, ...patch }));
  const target: BftSlackInbound =
    inbound === inboundTasks
      ? {
          inbound_tasks: {
            model:
              slack.task_models.find((row) => row.key === modelKey)?.choice ?? null,
          },
        }
      : { inbound_agent_id: inbound };

  return (
    <FormDialog
      description={t.slackDialogNote}
      onClose={onClose}
      onSubmit={() =>
        write.run(
          () =>
            api.createSlackConnect(writes.org, writes.project, {
              ...draft,
              app_name: draft.app_name.trim(),
              app_id: draft.app_id.trim(),
              client_id: draft.client_id.trim(),
              ...target,
            }),
          ({ notice }) => onCreated(notice)
        )
      }
      submitLabel={t.connect}
      title={t.addSlack}
      wide
      write={write}
    >
      <h3 className="bft-field-label">{t.stepCreate}</h3>
      <p className="bft-form-section-note">{t.stepCreateNote}</p>
      {manifest ? (
        <>
          {manifest.create_url ? (
            <div>
              <a
                className="bft-btn bft-btn-sm"
                href={manifest.create_url}
                rel="noopener noreferrer"
                target="_blank"
              >
                {t.createOnSlack}
              </a>
            </div>
          ) : null}
          <details className="bft-disclosure">
            <summary>{t.manifestDetails}</summary>
            <div className="bft-command">
              <div className="bft-command-head">
                <span className="bft-command-label">{t.manifestLabel}</span>
                <CopyButton
                  label={messages.common.copyLabel(t.manifestLabel)}
                  text={manifest.json}
                />
              </div>
              <ScrollArea
                className="bft-manifest"
                edgeEffect="none"
                orientation="vertical"
                scrollbarVisibility="hover"
                viewportClassName="bft-manifest-scroll"
              >
                <CodeBlock label={t.manifestLabel} text={manifest.json} />
              </ScrollArea>
            </div>
            <dl className="bft-kv bft-kv-wrap">
              {(
                [
                  [t.redirectUrl, manifest.redirect_url],
                  [t.eventsUrl, manifest.events_url],
                  [t.interactionsUrl, manifest.interactions_url],
                ] as const
              ).map(([label, url]) =>
                url ? (
                  <div key={label}>
                    <dt>{label}</dt>
                    <dd className="bft-mono">{url}</dd>
                  </div>
                ) : null
              )}
            </dl>
          </details>
        </>
      ) : (
        <p className="bft-quiet bft-quiet-inline">{t.manifestUnavailable}</p>
      )}
      <h3 className="bft-field-label">{t.stepCredentials}</h3>
      <div className="bft-connect-fields">
        <TextField
          error={write.fields.app_name}
          label={t.appName}
          onChange={(app_name) => set({ app_name })}
          placeholder="Comma"
          value={draft.app_name}
        />
        <TextField
          error={write.fields.app_id}
          label={t.appId}
          onChange={(app_id) => set({ app_id })}
          placeholder="A0123456789"
          value={draft.app_id}
        />
        <TextField
          error={write.fields.client_id}
          label={t.clientId}
          onChange={(client_id) => set({ client_id })}
          value={draft.client_id}
        />
        <SecretField
          configured={false}
          error={write.fields.client_secret}
          label={t.clientSecret}
          onChange={(client_secret) => set({ client_secret })}
          value={draft.client_secret}
        />
        <SecretField
          configured={false}
          error={write.fields.signing_secret}
          label={t.signingSecret}
          onChange={(signing_secret) => set({ signing_secret })}
          value={draft.signing_secret}
        />
        <div className="bft-form-field">
          <Dropdown
            className="bft-form-field"
            destructive={Boolean(write.fields.inbound_agent_id)}
            items={[
              ...slack.inbound_agents.map((agent) => ({
                id: agent.id,
                label: agent.label,
              })),
              { id: inboundTasks, label: t.inboundTasks, subtitle: t.inboundTasksHint },
            ]}
            label={t.inboundTarget}
            onChange={setInbound}
            size="sm"
            {...(inbound ? { value: inbound } : {})}
          />
          <FieldError message={write.fields.inbound_agent_id} />
        </div>
        {inbound === inboundTasks ? (
          <div className="bft-form-field">
            <Dropdown
              className="bft-form-field"
              destructive={Boolean(write.fields.inbound_tasks)}
              items={slack.task_models.map((row) => ({
                id: row.key === "" ? defaultTaskModel : row.key,
                label: row.label,
              }))}
              label={t.taskModel}
              onChange={(id) => setModelKey(id === defaultTaskModel ? "" : id)}
              size="sm"
              value={modelKey === "" ? defaultTaskModel : modelKey}
            />
            <FieldError message={write.fields.inbound_tasks} />
          </div>
        ) : null}
      </div>
    </FormDialog>
  );
}

/**
 * The manifest for the typed app name, read again 400 ms after typing stops;
 * the page's own manifest is the one for the default name.
 */
function useManifest(org: string, project: string, appName: string, slack: Slack) {
  const api = useApi();
  const [manifest, setManifest] = useState<{ name: string; value: BftSlackManifest }>({
    name: slack.app_name,
    value: slack.manifest,
  });
  useEffect(() => {
    if (appName === manifest.name) return undefined;
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      api.slackManifest(org, project, appName, controller.signal).then(
        (value) => setManifest({ name: appName, value }),
        () => undefined
      );
    }, 400);
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [api, org, project, appName, manifest.name]);
  return manifest.value;
}

// ---- Run checks ----

/** One Run checks result; it was also recorded for the Health page. */
function Checks({ result, title }: { result: BftRunChecks; title: string }) {
  const ran = relative(result.checks.ran_at);
  return (
    <section aria-label={title} className="bft-checks">
      <p className="bft-field-label">
        {title}
        {ran ? <span className="bft-muted"> · {ran}</span> : null}
      </p>
      {result.warning ? (
        <p className="bft-dialog-error" role="alert">
          {result.warning}
        </p>
      ) : null}
      <ul className="bft-list">
        {result.checks.gates.map((gate) => {
          const status = gateStatus(gate);
          const evidence = evidenceRows(gate.evidence);
          return (
            <li className="bft-check" key={gate.gate_id}>
              <div className="bft-check-head">
                <Status tone={gateTones[status] ?? "neutral"}>{gate.label}</Status>
                <span className="bft-setting-row-sub">{t.checkStatuses[status]}</span>
              </div>
              {gate.reason_class ? (
                <span className="bft-setting-row-sub">
                  {t.reason(gate.reason_class.replace(/[_-]+/g, " "))}
                </span>
              ) : null}
              {gate.next_action ? (
                <span className="bft-check-text">{gate.next_action}</span>
              ) : null}
              {evidence.length > 0 ? (
                <details className="bft-disclosure">
                  <summary>{t.evidence}</summary>
                  <dl className="bft-kv bft-kv-wrap">
                    {evidence.map(([key, value]) => (
                      <div key={key}>
                        <dt>{key.replace(/[_-]+/g, " ")}</dt>
                        <dd className="bft-mono">{evidenceText(value)}</dd>
                      </div>
                    ))}
                  </dl>
                </details>
              ) : null}
            </li>
          );
        })}
      </ul>
    </section>
  );
}

// ---- Signal ----

function SignalSection({ signal, writes }: { signal: Data["signal"]; writes: Writes }) {
  const api = useApi();
  const confirm = useConfirm();
  const write = useWrite();
  const [claim, setClaim] = useState<BftSignalClaim>();
  const { org, project, manage } = writes;
  const number = signal.number;

  return (
    <FormSection
      action={
        manage && number ? (
          <Button
            hierarchy="primary"
            isDisabled={write.busy}
            onPress={() =>
              write.run(() => api.createSignalClaim(org, project), setClaim)
            }
            size="xs"
          >
            {write.busy ? messages.common.working : t.newCode}
          </Button>
        ) : undefined
      }
      description={
        signal.status === "ok"
          ? t.signalNote(number ?? t.signalNumberFallback)
          : undefined
      }
      id="signal"
      level={3}
      title={t.signalTitle}
    >
      {signal.status !== "ok" ? (
        <p className="bft-quiet bft-quiet-inline">{t.signalUnavailable}</p>
      ) : (
        <>
          {write.error ? (
            <p className="bft-dialog-error" role="alert">
              {write.error}
            </p>
          ) : null}
          {claim ? (
            <div className="bft-notice bft-signal-code">
              <p>{t.codeNote(claim.number)}</p>
              <div className="bft-command bft-signal-command">
                <div className="bft-command-head">
                  <span className="bft-command-label">{t.codeLabel}</span>
                  <CopyButton
                    label={messages.common.copyLabel(t.codeLabel)}
                    text={claim.command}
                  />
                </div>
                <CodeBlock label={t.codeLabel} text={claim.command} />
              </div>
              <Button
                hierarchy="secondary-gray"
                onPress={() => setClaim(undefined)}
                size="xs"
              >
                {t.done}
              </Button>
            </div>
          ) : null}
          {signal.bindings.length === 0 ? (
            <p className="bft-quiet bft-quiet-inline">{t.signalEmpty}</p>
          ) : (
            <ul aria-label={t.signalChats} className="bft-list bft-setting-rows">
              {signal.bindings.map((binding) => {
                const name =
                  binding.display_name ??
                  (binding.kind === "group" ? t.signalGroup : t.person);
                return (
                  <li className="bft-setting-row" key={binding.binding_id}>
                    <span className="bft-setting-row-main">
                      <span className="bft-truncate">{name}</span>
                      <span className="bft-setting-row-sub bft-mono">
                        {binding.number ?? ""}
                      </span>
                    </span>
                    {manage ? (
                      <Button
                        aria-label={t.disconnectFor(name)}
                        hierarchy="tertiary-gray"
                        onPress={() =>
                          confirm.ask({
                            title: t.disconnectChatTitle,
                            description: t.disconnectChatBody(name),
                            confirmLabel: t.disconnect,
                            action: () =>
                              api
                                .removeSignalBinding(org, project, binding.binding_id)
                                .then(({ notice }) => writes.notify(notice)),
                          })
                        }
                        size="xs"
                      >
                        {t.disconnect}
                      </Button>
                    ) : null}
                  </li>
                );
              })}
            </ul>
          )}
          {signal.bindings_truncated ? (
            <p className="bft-form-section-note">
              {t.bindingsTruncated(signal.bindings.length)}
            </p>
          ) : null}
        </>
      )}
      {confirm.dialog}
    </FormSection>
  );
}

// ---- Tailscale ----

const tailnetTones: Record<string, Tone> = {
  running: "ok",
  idle: "ok",
  starting: "warn",
  needs_login: "warn",
  needs_approval: "warn",
  error: "error",
  disabled: "neutral",
};

/** Tags as typed in one field: comma- or space-separated. */
export function tailnetTags(text: string) {
  return text
    .split(/[\s,]+/)
    .map((tag) => tag.trim())
    .filter(Boolean);
}

function TailnetSection({
  tailnet,
  writes,
  onRetry,
}: {
  tailnet: BftTailnetSection;
  writes: Writes;
  onRetry: () => void;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const [editing, setEditing] = useState(false);
  const { org, project, manage } = writes;
  const waiting = ["needs_login", "needs_approval", "starting"].includes(tailnet.state);
  const owner =
    tailnet.login_name ??
    (tailnet.node_tags.length > 0 ? tailnet.node_tags.join(", ") : null);

  return (
    <FormSection
      action={
        manage && tailnet.status === "ok" ? (
          <span className="bft-inline-actions">
            {waiting ? (
              <Button hierarchy="secondary-gray" onPress={onRetry} size="xs">
                {t.tailnetCheckAgain}
              </Button>
            ) : null}
            <Button
              hierarchy={tailnet.enabled ? "secondary-gray" : "primary"}
              onPress={() => setEditing(true)}
              size="xs"
            >
              {tailnet.enabled ? t.tailnetSettings : t.tailnetConnect}
            </Button>
            {tailnet.enabled ? (
              <Button
                hierarchy="tertiary-gray"
                onPress={() =>
                  confirm.ask({
                    title: t.tailnetDisconnectTitle,
                    description: t.tailnetDisconnectBody,
                    confirmLabel: t.disconnect,
                    action: () =>
                      api
                        .disconnectTailnet(org, project)
                        .then(({ notice }) =>
                          writes.notify(notice ?? t.tailnetDisconnected)
                        ),
                  })
                }
                size="xs"
              >
                {t.disconnect}
              </Button>
            ) : null}
          </span>
        ) : undefined
      }
      description={t.tailnetNote}
      id="tailnet"
      level={3}
      title={t.tailnetTitle}
    >
      {tailnet.status !== "ok" ? (
        <p className="bft-quiet bft-quiet-inline">{t.tailnetUnavailable}</p>
      ) : (
        <>
          <Status tone={tailnetTones[tailnet.state] ?? "neutral"}>
            {t.tailnetStates[tailnet.state] ?? humanize(tailnet.state)}
          </Status>
          {tailnet.error?.message ? (
            <p className="bft-dialog-error" role="alert">
              {tailnet.error.message}
            </p>
          ) : null}
          {tailnet.state === "needs_login" ? (
            tailnet.login_url ? (
              <div className="bft-notice">
                <p>{t.tailnetLoginNote}</p>
                <div className="bft-command">
                  <div className="bft-command-head">
                    <span className="bft-command-label">{t.tailnetLoginLabel}</span>
                    <CopyButton
                      label={messages.common.copyLabel(t.tailnetLoginLabel)}
                      text={tailnet.login_url}
                    />
                  </div>
                  <CodeBlock label={t.tailnetLoginLabel} text={tailnet.login_url} />
                </div>
                <div>
                  <a
                    className="bft-btn bft-btn-sm"
                    href={tailnet.login_url}
                    rel="noopener noreferrer"
                    target="_blank"
                  >
                    {t.tailnetOpenLogin}
                  </a>
                </div>
              </div>
            ) : (
              <p className="bft-quiet bft-quiet-inline">{t.tailnetAskAdmin}</p>
            )
          ) : null}
          {tailnet.tailnet || tailnet.node_name ? (
            <dl className="bft-kv bft-kv-wrap">
              {(
                [
                  [t.tailnetName, tailnet.tailnet],
                  [t.tailnetNode, tailnet.node_name],
                  [t.tailnetOwner, owner],
                  [t.tailnetAddresses, tailnet.addresses.join(", ") || null],
                  [
                    t.tailnetKeyExpiry,
                    tailnet.key_expiry
                      ? formatRelative(tailnet.key_expiry)
                      : t.tailnetNever,
                  ],
                ] as const
              ).map(([label, value]) =>
                value ? (
                  <div key={label}>
                    <dt>{label}</dt>
                    <dd className="bft-mono">{value}</dd>
                  </div>
                ) : null
              )}
            </dl>
          ) : null}
        </>
      )}
      {editing ? (
        <TailnetDialog
          onClose={() => setEditing(false)}
          onSaved={() => {
            setEditing(false);
            onRetry();
          }}
          tailnet={tailnet}
          writes={writes}
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

function TailnetDialog({
  tailnet,
  writes,
  onClose,
  onSaved,
}: {
  tailnet: BftTailnetSection;
  writes: Writes;
  onClose: () => void;
  onSaved: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [tags, setTags] = useState(
    (tailnet.enabled ? tailnet.settings.tags : ["tag:comma-agent"]).join(", ")
  );
  const [expected, setExpected] = useState(tailnet.settings.expected_tailnet ?? "");
  const [acceptRoutes, setAcceptRoutes] = useState(tailnet.settings.accept_routes);

  return (
    <FormDialog
      description={t.tailnetDialogNote}
      onClose={onClose}
      onSubmit={() =>
        write.run(
          () =>
            api.connectTailnet(writes.org, writes.project, {
              tags: tailnetTags(tags),
              accept_routes: acceptRoutes,
              expected_tailnet: expected.trim() || null,
            }),
          onSaved
        )
      }
      {...(tailnet.enabled ? {} : { submitLabel: t.tailnetConnect })}
      title={t.tailnetDialogTitle}
      write={write}
    >
      <TextField
        error={write.fields.tags}
        hint={t.tailnetTagsHint}
        label={t.tailnetTags}
        onChange={setTags}
        value={tags}
      />
      <TextField
        error={write.fields.expected_tailnet}
        hint={t.tailnetExpectedHint}
        label={t.tailnetExpected}
        onChange={setExpected}
        placeholder="example.com"
        value={expected}
      />
      <Checkbox
        checked={acceptRoutes}
        label={t.tailnetAcceptRoutes}
        onChange={(event) => setAcceptRoutes(event.target.checked)}
        size="sm"
      />
    </FormDialog>
  );
}

// ---- Accounts ----

function AccountsSection({
  accounts,
  writes,
  onRetry,
}: {
  accounts: Data["accounts"];
  writes: Writes;
  onRetry: () => void;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const connection = useConnectionConfirm(writes.notify);
  const { org, project, manage } = writes;

  if (accounts.status !== "ok") {
    return (
      <FormSection id="accounts" level={3} title={t.accountsListTitle}>
        <SectionState onRetry={onRetry} status={accounts.status} />
      </FormSection>
    );
  }

  const setEnabled = (bindingId: string, enabled: boolean) =>
    api
      .setAccountEnabled(org, project, bindingId, enabled)
      .then(({ notice }) => writes.notify(notice), writes.fail);

  return (
    <>
      <FormSection id="accounts" level={3} title={t.accountsListTitle}>
        {accounts.connections.length === 0 ? (
          <p className="bft-quiet bft-quiet-inline">{t.accountsEmpty}</p>
        ) : (
          <ul aria-label={t.accountsListTitle} className="bft-list bft-setting-rows">
            {accounts.connections.map((account) => {
              const name = [providerLabel(account.provider), account.alias]
                .filter(Boolean)
                .join(" · ");
              return (
                <li className="bft-setting-row" key={account.binding_id}>
                  <span className="bft-setting-row-main">
                    <span className="bft-truncate">{name}</span>
                    <span className="bft-setting-row-sub bft-truncate">
                      {[account.account, account.scopes.join(", ")]
                        .filter(Boolean)
                        .join(" · ")}
                    </span>
                  </span>
                  <Status
                    tone={
                      !account.enabled
                        ? "neutral"
                        : account.status === "active"
                          ? "ok"
                          : "warn"
                    }
                  >
                    {account.enabled
                      ? (t.accountStatuses[account.status] ?? humanize(account.status))
                      : t.disabledState}
                  </Status>
                  {manage ? (
                    <RowMenu
                      items={[
                        account.enabled
                          ? {
                              id: "disable",
                              label: t.disable,
                              onAction: () =>
                                void setEnabled(account.binding_id, false),
                            }
                          : {
                              id: "enable",
                              label: t.enable,
                              onAction: () => void setEnabled(account.binding_id, true),
                            },
                        {
                          id: "disconnect",
                          label: t.disconnect,
                          destructive: true,
                          onAction: () =>
                            confirm.ask({
                              title: t.disconnectAccountTitle,
                              description: t.disconnectAccountBody(name),
                              confirmLabel: t.disconnect,
                              action: () =>
                                api
                                  .disconnectAccount(org, project, account.binding_id)
                                  .then(({ notice }) => writes.notify(notice)),
                            }),
                        },
                      ]}
                      name={name}
                    />
                  ) : null}
                </li>
              );
            })}
          </ul>
        )}
        {confirm.dialog}
      </FormSection>
      <FormSection
        description={t.platformsNote}
        id="platforms"
        level={3}
        title={t.platformsTitle}
      >
        {accounts.providers.length === 0 ? (
          <p className="bft-quiet bft-quiet-inline">{t.noPlatforms}</p>
        ) : (
          <ul aria-label={t.platformsTitle} className="bft-list bft-setting-rows">
            {accounts.providers.map((platform) => {
              const label = providerLabel(platform.provider);
              return (
                <li className="bft-setting-row" key={platform.provider}>
                  <span className="bft-setting-row-main">
                    <span className="bft-truncate">{label}</span>
                  </span>
                  <Status tone={platform.ready ? "ok" : "warn"}>
                    {platform.ready ? t.ready : t.setupRequired}
                  </Status>
                  {!manage ? null : platform.ready ? (
                    <Button
                      aria-label={t.connectFor(label)}
                      hierarchy="tertiary-gray"
                      onPress={() =>
                        connection.ask({
                          label,
                          kind: "managed_oauth",
                          action: "connect",
                          dependentMcps: [],
                          credentialConnected: false,
                          input: { label: t.labelOptional, placeholder: label },
                          run: (alias) =>
                            api.connectAccount(org, project, {
                              provider: platform.provider,
                              alias,
                            }),
                        })
                      }
                      size="xs"
                    >
                      {t.connect}
                    </Button>
                  ) : writes.orgAdmin ? (
                    <a
                      aria-label={t.configureFor(label)}
                      className="bft-link bft-setting-row-link"
                      href={orgHref(org, "/settings/integrations#oauth")}
                      onClick={spaLinkClick}
                    >
                      {t.configureInOrg}
                    </a>
                  ) : null}
                </li>
              );
            })}
          </ul>
        )}
        {!manage ? (
          <p className="bft-form-section-note">{t.adminsOnly}</p>
        ) : !writes.orgAdmin &&
          accounts.providers.some((platform) => !platform.ready) ? (
          <p className="bft-form-section-note">{t.orgAdminRequired}</p>
        ) : null}
        {connection.dialog}
      </FormSection>
    </>
  );
}

function ComposioSection({
  composio,
  writes,
}: {
  composio: Data["composio"];
  writes: Writes;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const connection = useConnectionConfirm(writes.notify);
  const { org, project, manage } = writes;

  return (
    <FormSection
      description={t.composioNote}
      id="composio"
      level={3}
      title={t.composioTitle}
    >
      {composio.status === "unavailable" ? (
        <p className="bft-quiet bft-quiet-inline">{t.composioUnavailable}</p>
      ) : null}
      <ul aria-label={t.composioTitle} className="bft-list bft-setting-rows">
        {composio.toolkits.map(({ toolkit, account_id: accountId }) => {
          const label = toolkitLabel(toolkit);
          return (
            <li className="bft-setting-row" key={toolkit}>
              <span className="bft-setting-row-main">
                <span className="bft-truncate">{label}</span>
                <span className="bft-setting-row-sub bft-truncate">
                  {t.toolkits[toolkit]?.description ?? ""}
                </span>
              </span>
              {accountId ? <Status tone="ok">{t.connected}</Status> : null}
              {!manage ? (
                accountId || !composio.configured ? null : (
                  <span className="bft-muted bft-setting-row-sub">
                    {t.askSwarmAdmin}
                  </span>
                )
              ) : accountId ? (
                <Button
                  aria-label={t.composioDisconnectFor(label)}
                  hierarchy="tertiary-gray"
                  onPress={() =>
                    confirm.ask({
                      title: t.disconnectAccountTitle,
                      description: t.disconnectAccountBody(label),
                      confirmLabel: t.disconnect,
                      action: () =>
                        api
                          .disconnectComposio(org, project, accountId)
                          .then(({ notice }) => writes.notify(notice)),
                    })
                  }
                  size="xs"
                >
                  {t.disconnect}
                </Button>
              ) : (
                <Button
                  aria-label={t.composioConnectFor(label)}
                  hierarchy="tertiary-gray"
                  isDisabled={!composio.configured}
                  onPress={() =>
                    connection.ask({
                      label,
                      kind: "composio",
                      action: "connect",
                      dependentMcps: [],
                      credentialConnected: false,
                      run: () => api.connectComposio(org, project, toolkit),
                    })
                  }
                  size="xs"
                >
                  {t.connect}
                </Button>
              )}
            </li>
          );
        })}
      </ul>
      {composio.configured ? null : (
        <div className="bft-quiet-row bft-quiet-row-flush">
          <p className="bft-quiet bft-quiet-inline">
            {t.composioNotConfigured} {writes.orgAdmin ? null : t.composioAskOrgAdmin}
          </p>
          {writes.orgAdmin ? (
            <a
              className="bft-link bft-setting-row-link"
              href={orgHref(org, "/settings/integrations#composio")}
              onClick={spaLinkClick}
            >
              {t.configureInOrg}
            </a>
          ) : null}
        </div>
      )}
      {connection.dialog}
      {confirm.dialog}
    </FormSection>
  );
}
