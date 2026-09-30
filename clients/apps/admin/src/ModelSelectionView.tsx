import { Button, InputField, ScrollArea } from "@comma/ui";
import { useEffect, useMemo, useState } from "react";
import {
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type ModelSelectionPolicy,
  type PlatformTemplate,
} from "./adminApi";
import {
  AdminConfirmationDialog,
  AdminNotice,
  AdminPageHeader,
  ReasonField,
} from "./adminUi";
import { adminErrorMessage, guardedAdminCommand } from "./adminErrors";

export function ModelSelectionView({
  api,
  onAccessDenied,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
}) {
  const [policy, setPolicy] = useState<ModelSelectionPolicy>();
  const [templates, setTemplates] = useState<PlatformTemplate[]>([]);
  const [mode, setMode] = useState<ModelSelectionPolicy["mode"]>("all");
  const [ids, setIds] = useState<string[]>([]);
  const [query, setQuery] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const [review, setReview] = useState(false);
  const [busy, setBusy] = useState(false);
  const [commandKey, setCommandKey] = useState("");
  const [reload, setReload] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    setPolicy(undefined);
    setError(undefined);
    void Promise.all([
      api.getModelSelectionPolicy({ signal: controller.signal }),
      api.listPlatformTemplates({ signal: controller.signal }),
    ])
      .then(([nextPolicy, nextTemplates]) => {
        if (controller.signal.aborted) return;
        setPolicy(nextPolicy);
        setMode(nextPolicy.mode);
        const currentIds = new Set(
          nextTemplates.map((template) => template.template_id)
        );
        setIds(nextPolicy.allowed_template_ids.filter((id) => currentIds.has(id)));
        setTemplates(nextTemplates);
      })
      .catch((cause: unknown) => {
        if (controller.signal.aborted || isAdminSessionRejection(cause)) return;
        if (isAdminAccessDenied(cause)) return onAccessDenied();
        setError(adminErrorMessage(cause, "Unable to load model selection settings."));
      });
    return () => controller.abort();
  }, [api, onAccessDenied, reload]);

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return templates.filter((template) =>
      [template.name, template.model, template.template_id, template.model_vendor].some(
        (value) => value?.toLowerCase().includes(needle)
      )
    );
  }, [query, templates]);
  const changed =
    policy &&
    (mode !== policy.mode ||
      JSON.stringify(ids.toSorted()) !==
        JSON.stringify(policy.allowed_template_ids.toSorted()));

  return (
    <section aria-label="Models" className="admin-workspace">
      <AdminPageHeader
        eyebrow="Platform"
        title="Models"
        description="Choose which platform templates Comma users can select. Private templates and existing choices remain available."
        actions={
          <Button
            hierarchy="secondary-gray"
            size="sm"
            isDisabled={busy}
            onPress={() => setReload((value) => value + 1)}
          >
            Reload
          </Button>
        }
      />
      <ScrollArea
        className="admin-page-scroll"
        contentClassName="admin-page-scroll-content"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
      >
        <section className="admin-drawer-section" aria-label="Model selection policy">
          {error ? <p role="alert">{error}</p> : null}
          {notice ? (
            <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
          ) : null}
          {!policy && !error ? <p>Loading models…</p> : null}
          {policy ? (
            <>
              <div className="admin-drawer-section-header">
                <div>
                  <h3>User choices</h3>
                  <p>
                    Default is always available. Removing a template blocks new
                    selections only.
                  </p>
                </div>
              </div>
              <fieldset className="admin-model-policy-modes">
                <legend>Selection mode</legend>
                <label>
                  <input
                    type="radio"
                    name="model-selection-mode"
                    checked={mode === "all"}
                    onChange={() => setMode("all")}
                  />{" "}
                  All platform templates
                </label>
                <label>
                  <input
                    type="radio"
                    name="model-selection-mode"
                    checked={mode === "selected"}
                    onChange={() => setMode("selected")}
                  />{" "}
                  Selected templates only
                </label>
              </fieldset>
              {mode === "selected" ? (
                <>
                  <InputField
                    label="Search templates"
                    value={query}
                    onChange={(event) => setQuery(event.target.value)}
                    placeholder="Name, model, or template ID"
                  />
                  <p>
                    {ids.length} selected. An empty list blocks all new
                    platform-template choices.
                  </p>
                  {policy.allowed_template_ids.some(
                    (id) => !templates.some((template) => template.template_id === id)
                  ) ? (
                    <p>
                      Some saved templates are no longer in the catalog. Save to remove
                      their IDs.
                    </p>
                  ) : null}
                  <ScrollArea
                    className="admin-model-policy-list"
                    edgeEffect="none"
                    orientation="vertical"
                    scrollbarVisibility="hover"
                  >
                    {filtered.map((template) => (
                      <label
                        className="admin-model-policy-row"
                        key={template.template_id}
                      >
                        <input
                          type="checkbox"
                          aria-label={`Allow ${template.name} (${template.template_id})`}
                          checked={ids.includes(template.template_id)}
                          onChange={(event) =>
                            setIds((current) =>
                              event.target.checked
                                ? [...current, template.template_id]
                                : current.filter((id) => id !== template.template_id)
                            )
                          }
                        />
                        <span>
                          <strong>
                            {template.model_display_name || template.name}
                          </strong>
                          <small>
                            {template.model_vendor || template.provider} ·{" "}
                            {template.model} · {template.template_id}
                          </small>
                        </span>
                      </label>
                    ))}
                    {filtered.length === 0 ? <p>No matching templates.</p> : null}
                  </ScrollArea>
                </>
              ) : null}
              <ReasonField value={reason} onChange={setReason} />
              <Button
                isDisabled={!changed || busy || reason.trim().length < 3}
                onPress={() => {
                  setCommandKey(createIdempotencyKey("model-selection-policy"));
                  setReview(true);
                }}
              >
                Save model choices
              </Button>
            </>
          ) : null}
        </section>
      </ScrollArea>
      <AdminConfirmationDialog
        expected="update-model-selection-policy:comma"
        isOpen={review}
        onOpenChange={setReview}
        onBusyChange={setBusy}
        title="Save model choices?"
        onConfirm={async () => {
          if (!policy) return;
          const saved = await guardedAdminCommand(
            api.updateModelSelectionPolicy(
              { mode, allowed_template_ids: ids, revision: policy.revision },
              {
                confirmation: "update-model-selection-policy:comma",
                idempotencyKey: commandKey,
                reason: reason.trim(),
              }
            ),
            onAccessDenied
          );
          setPolicy(saved);
          setMode(saved.mode);
          setIds(saved.allowed_template_ids);
          setReason("");
          setNotice("Saved. New user selections now use this list.");
        }}
      />
    </section>
  );
}
