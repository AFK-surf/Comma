import { Checkbox, Dropdown } from "@comma/ui";
import { useEffect, useState } from "react";
import type { BftSettingsModels } from "./api";
import { messages } from "./messages";
import { AccountsSection } from "./ModelAccounts";
import { PrivateTemplatesSection } from "./PrivateTemplates";
import { useApi } from "./resource";
import {
  FieldError,
  FormActions,
  FormSection,
  SaveButton,
  Unavailable,
  useWrite,
} from "./settingsForm";

const t = messages.settings.models;

// Dropdown ids cannot be null; this one stands for "follow the platform".
const platform = "platform";

type Role = "worker" | "router";

const fieldOf: Record<Role, "default_template_id" | "default_router_template_id"> = {
  worker: "default_template_id",
  router: "default_router_template_id",
};

/**
 * The allowlist IDs the form can show. Once the catalog loaded, IDs of models
 * no longer in it are dropped, so clearing every box allows all models.
 */
const shownAllowed = (data: BftSettingsModels) => {
  if (data.catalog_status !== "ok") return data.allowed_template_ids;
  const known = new Set(data.catalog.map((template) => template.template_id));
  return data.allowed_template_ids.filter((id) => known.has(id));
};

export function SettingsModelsPage({
  org,
  data: initial,
}: {
  org: string;
  data: BftSettingsModels;
}) {
  const api = useApi();
  const [data, setData] = useState(initial);
  const [allowed, setAllowed] = useState(() => shownAllowed(data));
  const [defaults, setDefaults] = useState<Record<Role, string | null>>({
    worker: data.default_template_id,
    router: data.default_router_template_id,
  });
  const write = useWrite();
  const unavailable = data.catalog_status === "unavailable";

  // The retired template and account pages land on their section.
  useEffect(() => {
    const section = window.location.hash.slice(1);
    if (section) document.getElementById(section)?.scrollIntoView({ block: "start" });
  }, []);

  // A template save or delete changes the catalog; unsaved choices stay.
  const reloadCatalog = () => {
    api.settingsModels(org).then(
      (next) => {
        setData(next);
        const known = new Set(next.catalog.map((template) => template.template_id));
        setAllowed((ids) => ids.filter((id) => known.has(id)));
      },
      () => undefined
    );
  };

  const toggle = (id: string, on: boolean) =>
    setAllowed((ids) => (on ? [...ids, id] : ids.filter((value) => value !== id)));

  const submit = () =>
    write.run(
      () =>
        api.updateSettingsModels(org, {
          allowed_template_ids: allowed,
          default_template_id: defaults.worker,
          default_router_template_id: defaults.router,
        }),
      (next) => {
        setData(next);
        setAllowed(shownAllowed(next));
        setDefaults({
          worker: next.default_template_id,
          router: next.default_router_template_id,
        });
      }
    );

  return (
    <>
      <FormSection description={t.allowedHint} title={t.allowedTitle}>
        {unavailable ? (
          <Unavailable />
        ) : data.catalog.length === 0 ? (
          <p className="bft-quiet bft-quiet-inline">{t.catalogEmpty}</p>
        ) : (
          <div className="bft-checklist">
            {data.catalog.map((template) => (
              <Checkbox
                checked={allowed.includes(template.template_id)}
                key={template.template_id}
                label={template.label}
                onChange={(event) => toggle(template.template_id, event.target.checked)}
                size="sm"
              />
            ))}
          </div>
        )}
      </FormSection>
      <FormSection description={t.defaultsHint} title={t.defaultsTitle}>
        {(["worker", "router"] as const).map((role) => (
          <div className="bft-form-field" key={role}>
            <Dropdown
              className="bft-form-field"
              destructive={Boolean(write.fields[fieldOf[role]])}
              disabled={unavailable}
              items={[
                {
                  id: platform,
                  label: t.platformDefault(data.platform_defaults[role]?.label),
                },
                ...data.default_options[role].map((option) => ({
                  id: option.value,
                  label: option.label,
                })),
              ]}
              label={t[role]}
              onChange={(value) =>
                setDefaults((current) => ({
                  ...current,
                  [role]: value === platform ? null : value,
                }))
              }
              size="sm"
              value={defaults[role] ?? platform}
            />
            <FieldError message={write.fields[fieldOf[role]]} />
          </div>
        ))}
        <FormActions write={write}>
          <SaveButton busy={write.busy} disabled={unavailable} onPress={submit} />
        </FormActions>
      </FormSection>
      <PrivateTemplatesSection
        defaultIds={[data.default_template_id, data.default_router_template_id]}
        onChanged={reloadCatalog}
        org={org}
      />
      <AccountsSection org={org} />
    </>
  );
}
