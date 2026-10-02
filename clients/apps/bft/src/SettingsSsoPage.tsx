import { Button, Dropdown } from "@comma/ui";
import { useState } from "react";
import {
  provisioningPolicies,
  ssoProviders,
  ssoRoles,
  type BftSettingsSso,
  type BftSsoChecks,
  type BftSsoProvider,
} from "./api";
import { CodeBlock, CopyButton } from "./dialogs";
import { humanize } from "./format";
import { messages } from "./messages";
import { useApi } from "./resource";
import { orgHref, settingsPaths } from "./navSpec";
import { spaLinkClick } from "./router";
import {
  FieldError,
  FormActions,
  FormSection,
  SaveButton,
  SecretField,
  TextField,
  useWrite,
} from "./settingsForm";

const t = messages.settings.sso;

type Role = (typeof ssoRoles)[number];
type Policy = (typeof provisioningPolicies)[number];

/** The form fields of a stored connection; secrets always start blank. */
export function ssoDraft(data: BftSettingsSso) {
  const connection = data.connection;
  return {
    provider: connection?.provider ?? ("generic_oidc" as BftSsoProvider),
    issuer: connection?.issuer ?? "",
    client_id: connection?.client_id ?? "",
    client_secret: "",
    allowed_domains: connection?.allowed_domains.join(", ") ?? "",
    default_role: connection?.default_role ?? ("member" as Role),
    scope: connection?.provider_config.scope ?? "",
    provisioning_policy:
      connection?.provider_config.provisioning_policy ?? ("jit" as Policy),
  };
}

type Draft = ReturnType<typeof ssoDraft>;

/**
 * The write body for the chosen provider. A Feishu connection takes its App
 * ID and secret from the Feishu app enabled for sign-in, so it sends neither.
 */
export function ssoBody(draft: Draft): Record<string, unknown> {
  if (draft.provider === "feishu") {
    return {
      provider: "feishu",
      default_role: draft.default_role,
      provider_config: {
        scope: draft.scope.trim(),
        provisioning_policy: draft.provisioning_policy,
      },
    };
  }
  return {
    provider: "generic_oidc",
    issuer: draft.issuer.trim(),
    client_id: draft.client_id.trim(),
    allowed_domains: draft.allowed_domains,
    default_role: draft.default_role,
    ...(draft.client_secret ? { client_secret: draft.client_secret } : {}),
  };
}

const gateTone = (status: string) =>
  status === "ok" || status === "ready"
    ? "ok"
    : status === "fail"
      ? "error"
      : status === "skipped" || status === "disabled"
        ? "neutral"
        : "warn";

export function SettingsSsoPage({
  org,
  data: initial,
}: {
  org: string;
  data: BftSettingsSso;
}) {
  const api = useApi();
  const [data, setData] = useState(initial);
  const [draft, setDraft] = useState(() => ssoDraft(initial));
  const [checks, setChecks] = useState<BftSsoChecks>();
  const write = useWrite();
  const checking = useWrite();
  const set = (patch: Partial<Draft>) => setDraft((value) => ({ ...value, ...patch }));
  const feishu = draft.provider === "feishu";
  const secretConfigured =
    data.connection?.provider === "generic_oidc" &&
    data.connection.client_secret_configured;
  const integrations = orgHref(org, `${settingsPaths.integrations}#feishu`);
  const roleField = (
    <div className="bft-form-field">
      <Dropdown
        className="bft-form-field"
        items={ssoRoles.map((role) => ({ id: role, label: t.roles[role] }))}
        label={t.defaultRole}
        onChange={(value) => set({ default_role: value as Role })}
        size="sm"
        value={draft.default_role}
      />
      <FieldError message={write.fields.default_role} />
    </div>
  );

  return (
    <>
      <FormSection title={t.connectionTitle}>
        <Dropdown
          className="bft-form-field"
          hint={t.providerHint}
          items={ssoProviders.map((provider) => ({
            id: provider,
            label: t.providers[provider],
          }))}
          label={t.provider}
          onChange={(value) => set({ provider: value as BftSsoProvider })}
          size="sm"
          value={draft.provider}
        />
        {feishu ? (
          <>
            <div className="bft-form-field">
              <span className="bft-field-label">{t.feishuApp}</span>
              {data.feishu_app ? (
                <div className="bft-setting-row">
                  <span className="bft-setting-row-main">
                    <span className="bft-truncate">
                      {data.feishu_app.display_name ?? data.feishu_app.app_id}
                    </span>
                    <span className="bft-setting-row-sub bft-truncate">
                      {data.feishu_app.app_secret_configured
                        ? `${data.feishu_app.app_id} · ${t.feishuAppReused}`
                        : `${data.feishu_app.app_id} · ${t.secretMissing}`}
                    </span>
                  </span>
                  <a className="bft-link" href={integrations} onClick={spaLinkClick}>
                    {t.manageFeishu}
                  </a>
                </div>
              ) : (
                <div className="bft-notice">
                  <p>{t.feishuAppMissing}</p>
                  <p>{t.feishuAppMissingHint}</p>
                  <a className="bft-link" href={integrations} onClick={spaLinkClick}>
                    {t.manageFeishu}
                  </a>
                </div>
              )}
            </div>
            <TextField
              error={write.fields.provider_config}
              hint={t.scopeHint(data.default_feishu_scope)}
              label={t.scope}
              onChange={(scope) => set({ scope })}
              placeholder={data.default_feishu_scope}
              value={draft.scope}
            />
            <Dropdown
              className="bft-form-field"
              items={provisioningPolicies.map((policy) => ({
                id: policy,
                label: t.policies[policy],
              }))}
              label={t.provisioning}
              onChange={(value) => set({ provisioning_policy: value as Policy })}
              size="sm"
              value={draft.provisioning_policy}
            />
            {roleField}
          </>
        ) : (
          <>
            <TextField
              error={write.fields.issuer}
              label={t.issuer}
              onChange={(issuer) => set({ issuer })}
              placeholder="https://idp.example.com"
              value={draft.issuer}
            />
            <TextField
              error={write.fields.client_id}
              label={t.clientId}
              onChange={(client_id) => set({ client_id })}
              value={draft.client_id}
            />
            <SecretField
              configured={secretConfigured}
              error={write.fields.client_secret}
              label={t.clientSecret}
              onChange={(client_secret) => set({ client_secret })}
              value={draft.client_secret}
            />
            <TextField
              error={write.fields.allowed_domains}
              hint={t.allowedDomainsHint}
              label={t.allowedDomains}
              onChange={(allowed_domains) => set({ allowed_domains })}
              placeholder="example.com, sub.example.com"
              value={draft.allowed_domains}
            />
            {roleField}
          </>
        )}
        <div className="bft-command">
          <div className="bft-command-head">
            <span className="bft-command-label">{t.redirectUri}</span>
            <CopyButton
              label={messages.common.copyLabel(t.redirectUri)}
              text={data.redirect_uri}
            />
          </div>
          <CodeBlock label={t.redirectUri} text={data.redirect_uri} />
          <p className="bft-form-section-note">{t.redirectUriHint}</p>
        </div>
        <FormActions write={write}>
          <Button
            disabled={checking.busy || !data.connection}
            hierarchy="secondary-gray"
            onPress={() => checking.run(() => api.runSsoChecks(org), setChecks)}
            size="sm"
          >
            {checking.busy ? t.running : t.runChecks}
          </Button>
          <SaveButton
            busy={write.busy}
            onPress={() =>
              write.run(
                () => api.updateSettingsSso(org, ssoBody(draft)),
                (next) => {
                  setData(next);
                  setDraft(ssoDraft(next));
                }
              )
            }
          />
        </FormActions>
      </FormSection>
      {checks || checking.error ? (
        <FormSection title={t.checksTitle}>
          <FieldError message={checking.error ?? checks?.warning ?? undefined} />
          {checks ? (
            <ul className="bft-list bft-setting-rows">
              {checks.checks.gates.map((gate) => (
                <li className="bft-setting-row" key={gate.gate_id}>
                  <span className="bft-setting-row-main">
                    <span className="bft-status" data-tone={gateTone(gate.status)}>
                      <span className="bft-truncate">{gate.label}</span>
                    </span>
                    {gate.next_action ? (
                      <span className="bft-setting-row-sub">{gate.next_action}</span>
                    ) : null}
                  </span>
                  <span className="bft-setting-row-sub">
                    {t.gateStatuses[gate.status] ?? humanize(gate.status)}
                  </span>
                </li>
              ))}
            </ul>
          ) : null}
        </FormSection>
      ) : null}
    </>
  );
}
