import { Button } from "@comma/ui/components/Button";
import { XIcon } from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { confirmationBusy } from "./adminModel";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import {
  AdminConfirmationDialog,
  AdminNotice,
  AdminPageHeader,
  AdminRow,
  AdminSaveBar,
  AdminSection,
  AdminState,
} from "./adminUi";
import {
  canAddFreeRouterModel,
  freeRouterModelChanges,
  freeRouterModelsChanged,
  type FreeRouterModelsModel,
} from "./FreeRouterModelsModel";
import { messages } from "@comma/i18n";

/** The Free Router models page: edit the list, then save it after review. */
export function FreeRouterModelsView({ model }: { model: FreeRouterModelsModel }) {
  const run = useAdminCommand();
  const state = useAdminState(model.state);
  const busy = useAdminState(model.confirmation.state, confirmationBusy);
  const { error, models, notice, policy, provider, sku } = state;
  const { added, removed } = freeRouterModelChanges(state);

  return (
    <section
      aria-label={messages.admin_section_free_models()}
      className="admin-workspace admin-settings-page"
    >
      <AdminPageHeader
        actions={
          <Button
            hierarchy="secondary-gray"
            isDisabled={busy}
            onPress={() => run(model.reload)}
            size="sm"
          >
            {messages.admin_reload()}
          </Button>
        }
        description={messages.admin_free_description()}
        title={messages.admin_section_free_models()}
      />
      <ScrollArea
        className="admin-page-scroll"
        contentClassName="admin-page-scroll-content"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
      >
        {error ? (
          <AdminState
            message={error}
            onAction={() => run(model.reload)}
            title={messages.admin_free_load_failed()}
            tone="error"
          />
        ) : null}
        {notice ? (
          <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
        ) : null}
        {!policy && !error ? (
          <AdminState title={messages.admin_loading_models()} />
        ) : null}
        {policy ? (
          <div className="admin-page-sections">
            <AdminSection
              action={
                <span className="admin-section-note">{models.length} of 100</span>
              }
              label={messages.admin_free_list()}
              title={messages.admin_models()}
            >
              {models.length === 0 ? (
                <AdminRow title={messages.admin_free_none()} />
              ) : (
                models.map((entry, index) => {
                  const name = `${entry.provider}/${entry.sku}`;
                  return (
                    <AdminRow
                      {...(added.includes(name)
                        ? { description: messages.admin_added_unsaved() }
                        : {})}
                      key={name}
                      title={<code>{name}</code>}
                    >
                      <Button
                        aria-label={messages.admin_remove_named({ name: entry.sku })}
                        hierarchy="tertiary-gray"
                        iconLeading={<XIcon />}
                        iconOnly
                        isDisabled={busy}
                        onPress={() => run(model.removeModel(index))}
                        size="sm"
                      />
                    </AdminRow>
                  );
                })
              )}
              {removed.length ? (
                <AdminRow
                  description={messages.admin_removed_unsaved()}
                  title={removed.join(", ")}
                />
              ) : null}
            </AdminSection>

            <AdminSection title={messages.admin_add_model_section()}>
              <form
                className="admin-row admin-row-form"
                onSubmit={(event) => {
                  event.preventDefault();
                  run(model.addModel);
                }}
              >
                <InputField
                  className="w-full"
                  hint={messages.admin_provider_hint()}
                  label={messages.admin_provider()}
                  maxLength={200}
                  onChange={(event) =>
                    run(model.setField("provider", event.target.value))
                  }
                  placeholder="openai"
                  value={provider}
                />
                <InputField
                  className="w-full"
                  hint={messages.admin_sku_hint()}
                  label={messages.admin_sku()}
                  maxLength={200}
                  onChange={(event) => run(model.setField("sku", event.target.value))}
                  placeholder="gpt-5.6-luna"
                  value={sku}
                />
                <div className="admin-row-end">
                  <Button
                    hierarchy="secondary-gray"
                    isDisabled={busy || !canAddFreeRouterModel(state)}
                    size="sm"
                    type="submit"
                  >
                    {messages.admin_add_model()}
                  </Button>
                </div>
              </form>
            </AdminSection>
          </div>
        ) : null}
      </ScrollArea>
      <AdminSaveBar
        canSave={freeRouterModelsChanged(state)}
        changes={added.length + removed.length}
        disabled={busy}
        onDiscard={() => run(model.discard)}
        onSave={() => run(model.review)}
        saveLabel={messages.admin_save_free_models()}
      />
      <AdminConfirmationDialog confirmation={model.confirmation} />
    </section>
  );
}
