import { Button, Dropdown } from "@comma/ui";
import { useRef, useState } from "react";
import type { BftCli, BftSettingsGeneral } from "./api";
import { CodeBlock, CopyButton } from "./dialogs";
import { formatRelative } from "./format";
import { messages } from "./messages";
import { useApi } from "./resource";
import {
  FieldError,
  FormActions,
  FormSection,
  SaveButton,
  TextField,
  useConfirm,
  useWrite,
} from "./settingsForm";

const t = messages.settings.general;

type Organization = BftSettingsGeneral["organization"];

// The server stores `icon` as a data URL of at most 512,000 characters,
// prefix included. The hint rounds the limit down to 374 KB.
const maxIconChars = 512_000;
const iconDataUrlLength = (file: File) =>
  `data:${file.type};base64,`.length + 4 * Math.ceil(file.size / 3);
const iconTypes = ["image/png", "image/jpeg", "image/gif", "image/webp"];
const browserLocale = "browser";

/** The profile fields that differ from what the server holds. */
export function organizationChanges(saved: Organization, draft: Organization) {
  return Object.fromEntries(
    (Object.keys(draft) as (keyof Organization)[])
      .filter((key) => (draft[key] ?? "") !== (saved[key] ?? ""))
      .map((key) => [key, draft[key] ?? ""])
  ) as Partial<Organization>;
}

export function SettingsGeneralPage({
  org,
  data,
  onSaved,
}: {
  org: string;
  data: BftSettingsGeneral;
  /** Called with the saved profile, so the shell can follow a new slug. */
  onSaved: (general: BftSettingsGeneral) => void;
}) {
  const api = useApi();
  const [cli, setCli] = useState(data.cli);
  return (
    <>
      <OrganizationForm
        data={data}
        onSaved={onSaved}
        update={(changes) => api.updateSettingsGeneral(org, changes)}
      />
      <CliSection
        cli={cli}
        onRevoke={(id) => api.revokeCliSession(org, id).then(setCli)}
      />
    </>
  );
}

function OrganizationForm({
  data,
  update,
  onSaved,
}: {
  data: BftSettingsGeneral;
  update: (changes: Partial<Organization>) => Promise<BftSettingsGeneral>;
  onSaved: (general: BftSettingsGeneral) => void;
}) {
  const [saved, setSaved] = useState(data.organization);
  const [draft, setDraft] = useState(data.organization);
  const [iconError, setIconError] = useState<string>();
  const file = useRef<HTMLInputElement>(null);
  const write = useWrite();
  const changes = organizationChanges(saved, draft);
  const set = (patch: Partial<Organization>) =>
    setDraft((value) => ({ ...value, ...patch }));

  const pickIcon = (picked: File | undefined) => {
    if (file.current) file.current.value = "";
    if (!picked) return;
    if (!iconTypes.includes(picked.type)) return setIconError(t.iconNotImage);
    if (iconDataUrlLength(picked) > maxIconChars) return setIconError(t.iconTooLarge);
    setIconError(undefined);
    const reader = new FileReader();
    reader.addEventListener("load", () => {
      if (typeof reader.result === "string") set({ icon: reader.result });
    });
    reader.readAsDataURL(picked);
  };

  const save = () =>
    write.run(
      () => update(changes),
      (general) => {
        setSaved(general.organization);
        setDraft(general.organization);
        onSaved(general);
      }
    );

  return (
    <FormSection title={t.orgTitle}>
      <TextField
        error={write.fields.name}
        label={t.name}
        onChange={(name) => set({ name })}
        value={draft.name}
      />
      <TextField
        error={write.fields.slug}
        hint={t.slugHint}
        label={t.slug}
        onChange={(slug) => set({ slug })}
        value={draft.slug}
      />
      <div className="bft-form-field">
        <span className="bft-field-label">{t.icon}</span>
        <div className="bft-icon-field">
          {draft.icon ? (
            <img alt="" className="bft-org-icon" src={draft.icon} />
          ) : (
            <span className="bft-quiet bft-quiet-inline">{t.iconNone}</span>
          )}
          <input
            accept={iconTypes.join(",")}
            aria-label={t.iconUpload}
            className="bft-sr-only"
            onChange={(event) => pickIcon(event.target.files?.[0])}
            ref={file}
            type="file"
          />
          <Button
            hierarchy="secondary-gray"
            onPress={() => file.current?.click()}
            size="xs"
          >
            {t.iconUpload}
          </Button>
          {draft.icon ? (
            <Button
              hierarchy="tertiary-gray"
              onPress={() => set({ icon: null })}
              size="xs"
            >
              {t.iconRemove}
            </Button>
          ) : null}
        </div>
        <p className="bft-form-section-note">{t.iconHint}</p>
        <FieldError message={iconError ?? write.fields.icon} />
      </div>
      <div className="bft-form-field">
        <Dropdown
          className="bft-form-field"
          items={[
            { id: browserLocale, label: t.localeBrowser },
            ...data.locale_options.map((option) => ({
              id: option.value,
              label: option.label,
            })),
          ]}
          label={t.locale}
          onChange={(value) =>
            set({ default_locale: value === browserLocale ? null : value })
          }
          size="sm"
          value={draft.default_locale ?? browserLocale}
        />
        <FieldError message={write.fields.default_locale} />
      </div>
      <FormActions write={write}>
        <SaveButton
          busy={write.busy}
          disabled={Object.keys(changes).length === 0}
          onPress={save}
        />
      </FormActions>
    </FormSection>
  );
}

const sessionName = (session: BftCli["sessions"][number]) =>
  [session.client_name ?? t.sessionName, session.device].filter(Boolean).join(" · ");

function CliSection({
  cli,
  onRevoke,
}: {
  cli: BftCli;
  onRevoke: (sessionId: string) => Promise<unknown>;
}) {
  const confirm = useConfirm();
  return (
    <FormSection description={t.cliDescription} title={t.cliTitle}>
      {(
        [
          [t.install, cli.install_command],
          [t.login, cli.login_command],
        ] as const
      ).map(([label, command]) => (
        <div className="bft-command" key={label}>
          <div className="bft-command-head">
            <span className="bft-command-label">{label}</span>
            <CopyButton label={messages.common.copyLabel(label)} text={command} />
          </div>
          <CodeBlock label={label} text={command} />
        </div>
      ))}
      <h3 className="bft-field-label">{t.sessionsTitle}</h3>
      {cli.sessions.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.sessionsEmpty}</p>
      ) : (
        <ul className="bft-list bft-setting-rows">
          {cli.sessions.map((session) => {
            const name = sessionName(session);
            const seen = session.last_seen_at
              ? formatRelative(session.last_seen_at)
              : undefined;
            const expires = session.expires_at
              ? formatRelative(session.expires_at)
              : undefined;
            return (
              <li className="bft-setting-row" key={session.id}>
                <span className="bft-setting-row-main">
                  <span className="bft-truncate">{name}</span>
                  <span className="bft-setting-row-sub bft-truncate">
                    {t.sessionMeta(seen, expires)}
                  </span>
                </span>
                <Button
                  aria-label={t.revokeFor(name)}
                  hierarchy="tertiary-gray"
                  onPress={() =>
                    confirm.ask({
                      title: t.revokeTitle,
                      description: t.revokeBody(name),
                      confirmLabel: t.revoke,
                      action: () => onRevoke(session.id),
                    })
                  }
                  size="xs"
                >
                  {t.revoke}
                </Button>
              </li>
            );
          })}
        </ul>
      )}
      {cli.sessions_truncated ? (
        <p className="bft-form-section-note">
          {t.sessionsTruncated(cli.sessions.length)}
        </p>
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}
