import { Button, InputField } from "@comma/ui";
import { useEffect, useState } from "react";
import {
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type FreeRouterPolicy,
} from "./adminApi";
import { AdminConfirmationDialog, AdminNotice, ReasonField } from "./adminUi";
import { adminErrorMessage, guardedAdminCommand } from "./adminErrors";

export function FreeRouterModelsPanel({
  api,
  onAccessDenied,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
}) {
  const [policy, setPolicy] = useState<FreeRouterPolicy>();
  const [models, setModels] = useState<FreeRouterPolicy["models"]>([]);
  const [provider, setProvider] = useState("");
  const [sku, setSku] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const [reload, setReload] = useState(0);
  const [review, setReview] = useState(false);
  const [busy, setBusy] = useState(false);
  const [commandKey, setCommandKey] = useState("");

  useEffect(() => {
    const controller = new AbortController();
    setPolicy(undefined);
    setError(undefined);
    void api
      .getFreeRouterModels({ signal: controller.signal })
      .then((value) => {
        if (controller.signal.aborted) return;
        setPolicy(value);
        setModels(value.models);
      })
      .catch((cause: unknown) => {
        if (controller.signal.aborted || isAdminSessionRejection(cause)) return;
        if (isAdminAccessDenied(cause)) return onAccessDenied();
        setError(adminErrorMessage(cause, "Unable to load free Router models."));
      });
    return () => controller.abort();
  }, [api, onAccessDenied, reload]);

  const changed = policy && JSON.stringify(models) !== JSON.stringify(policy.models);
  return (
    <section className="admin-drawer-section" aria-label="Free Router models">
      <div className="admin-drawer-section-header">
        <div>
          <h3>Free Router models</h3>
          <p>
            Applies to Router main-model calls in all Comma Workspaces. Workers, tools,
            compute, and storage retain their charges.
          </p>
        </div>
        <Button
          hierarchy="secondary-gray"
          size="sm"
          isDisabled={busy}
          onPress={() => setReload((value) => value + 1)}
        >
          Reload
        </Button>
      </div>
      {error ? <p role="alert">{error}</p> : null}
      {notice ? (
        <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
      ) : null}
      {!policy && !error ? <p>Loading models…</p> : null}
      {policy ? (
        <>
          {models.length === 0 ? (
            <p>No models are free under this policy.</p>
          ) : (
            <ul>
              {models.map((model, index) => (
                <li key={`${model.provider}/${model.sku}`}>
                  <span>
                    {model.provider} / {model.sku}
                  </span>{" "}
                  <Button
                    hierarchy="tertiary-gray"
                    size="sm"
                    isDisabled={busy}
                    onPress={() =>
                      setModels((current) => current.filter((_, i) => i !== index))
                    }
                  >
                    Remove {model.sku}
                  </Button>
                </li>
              ))}
            </ul>
          )}
          <form
            className="admin-form-grid"
            onSubmit={(event) => {
              event.preventDefault();
              const next = {
                provider: provider.trim().toLowerCase(),
                sku: sku.trim().toLowerCase(),
              };
              if (!next.provider || !next.sku || models.length >= 100) return;
              if (
                !models.some(
                  (model) => model.provider === next.provider && model.sku === next.sku
                )
              )
                setModels([...models, next]);
              setProvider("");
              setSku("");
            }}
          >
            <InputField
              label="Provider"
              value={provider}
              maxLength={200}
              onChange={(event) => setProvider(event.target.value)}
              placeholder="openai"
            />
            <InputField
              label="Model SKU"
              value={sku}
              maxLength={200}
              onChange={(event) => setSku(event.target.value)}
              placeholder="gpt-5.6-luna"
            />
            <Button
              type="submit"
              hierarchy="secondary-gray"
              isDisabled={
                busy || !provider.trim() || !sku.trim() || models.length >= 100
              }
            >
              Add model
            </Button>
          </form>
          <p>
            Use exact provider and model identifiers. Models without a catalog price can
            also be free. Maximum 100 entries.
          </p>
          <ReasonField value={reason} onChange={setReason} />
          <Button
            isDisabled={!changed || busy || reason.trim().length < 3}
            onPress={() => {
              setCommandKey(createIdempotencyKey("free-router-models"));
              setReview(true);
            }}
          >
            Save free Router models
          </Button>
        </>
      ) : null}
      <AdminConfirmationDialog
        expected="update-free-router-models:comma"
        isOpen={review}
        onOpenChange={setReview}
        onBusyChange={setBusy}
        title="Save free Router models?"
        onConfirm={async () => {
          if (!policy) return;
          const saved = await guardedAdminCommand(
            api.updateFreeRouterModels(
              { revision: policy.revision, models },
              {
                confirmation: "update-free-router-models:comma",
                idempotencyKey: commandKey,
                reason: reason.trim(),
              }
            ),
            onAccessDenied
          );
          setPolicy(saved);
          setModels(saved.models);
          setReason("");
          setNotice(
            "Saved. New Router calls use this policy. Calls already in progress keep their billing decision."
          );
        }}
      />
    </section>
  );
}
