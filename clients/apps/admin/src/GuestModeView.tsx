import { Button } from "@comma/ui/components/Button";
import { CopyIcon } from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { Toggle } from "@comma/ui/components/toggle";
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
import { confirmationBusy } from "./adminModel";
import {
  guestModeForm,
  guestPolicyChanges,
  type GuestModeModel,
} from "./GuestModeModel";
import { messages } from "@comma/i18n";

export function GuestModeView({ model }: { model: GuestModeModel }) {
  const run = useAdminCommand();
  const state = useAdminState(model.state);
  const busy = useAdminState(model.confirmation.state, confirmationBusy);
  const { copiedTenantId, enabled, error, notice, policy } = state;
  const {
    canSave,
    concurrencyError,
    dailyError,
    difficultyError,
    lifetimeError,
    tenantId,
    tenantMissing,
  } = guestModeForm(state, busy);
  const changes = policy ? guestPolicyChanges(state, policy).length : 0;

  return (
    <section
      aria-label={messages.admin_section_guest()}
      className="admin-workspace admin-settings-page"
    >
      <AdminPageHeader
        title={messages.admin_section_guest()}
        description={messages.admin_guest_description()}
        actions={
          <Button
            hierarchy="secondary-gray"
            size="sm"
            isDisabled={busy}
            onPress={() => run(model.reload)}
          >
            {messages.admin_reload()}
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
        {error ? (
          <AdminState
            message={error}
            onAction={() => run(model.reload)}
            title={messages.admin_guest_load_failed()}
            tone="error"
          />
        ) : null}
        {notice ? (
          <AdminNotice
            message={notice.message}
            onDismiss={() => run(model.dismissNotice)}
            tone={notice.tone}
          />
        ) : null}
        {!policy && !error ? (
          <AdminState title={messages.admin_loading_guest()} />
        ) : null}
        {policy ? (
          <div className="admin-page-sections">
            <AdminSection
              action={
                <Button
                  hierarchy="secondary-gray"
                  isDisabled={busy}
                  onPress={() => run(model.reviewTenant)}
                  size="sm"
                >
                  {messages.admin_guest_create_tenant()}
                </Button>
              }
              title={messages.admin_guest_tenant()}
            >
              <AdminRow
                description={messages.admin_guest_tenant_body()}
                title={messages.admin_salix_tenant_id()}
              >
                {tenantId ? (
                  <>
                    <code className="admin-row-value">{tenantId}</code>
                    <Button
                      hierarchy="tertiary-gray"
                      iconLeading={<CopyIcon />}
                      onPress={() => run(model.copyTenantId)}
                      size="sm"
                    >
                      {copiedTenantId === tenantId
                        ? messages.admin_copied()
                        : messages.admin_copy_tenant_id()}
                    </Button>
                  </>
                ) : (
                  <span className="admin-row-value">
                    {messages.admin_guest_no_tenant()}
                  </span>
                )}
              </AdminRow>
              <AdminRow title={messages.admin_guest_created_today()}>
                <span className="admin-row-value admin-tabular-value">
                  {messages.admin_of_count({
                    limit: policy.daily_creation_limit,
                    used: policy.created_today,
                  })}
                </span>
              </AdminRow>
            </AdminSection>

            <AdminSection
              label={messages.admin_guest_policy()}
              title={messages.admin_policy()}
            >
              <AdminRow
                description={
                  tenantMissing ? (
                    <span role="alert">{messages.admin_guest_tenant_required()}</span>
                  ) : (
                    messages.admin_guest_enabled_hint()
                  )
                }
                title={messages.admin_guest_mode()}
              >
                <Toggle
                  aria-label={messages.admin_guest_enabled()}
                  checked={enabled}
                  disabled={busy}
                  onChange={(event) => run(model.setEnabled(event.target.checked))}
                  size="sm"
                />
              </AdminRow>
              <AdminRow
                description={messages.admin_guest_daily_hint()}
                title={messages.admin_guest_daily()}
              >
                <InputField
                  aria-label={messages.admin_guest_daily()}
                  className="admin-row-input"
                  inputMode="numeric"
                  onChange={(event) =>
                    run(model.setField("dailyLimit", event.target.value))
                  }
                  type="number"
                  value={state.dailyLimit}
                  {...(dailyError ? { errorMessage: dailyError } : {})}
                />
              </AdminRow>
              <AdminRow
                description={messages.admin_guest_concurrency_hint()}
                title={messages.admin_guest_concurrency()}
              >
                <InputField
                  aria-label={messages.admin_guest_concurrency()}
                  className="admin-row-input"
                  inputMode="numeric"
                  onChange={(event) =>
                    run(model.setField("concurrency", event.target.value))
                  }
                  type="number"
                  value={state.concurrency}
                  {...(concurrencyError ? { errorMessage: concurrencyError } : {})}
                />
              </AdminRow>
              <AdminRow
                description={messages.admin_guest_lifetime_hint()}
                title={messages.admin_guest_lifetime_days()}
              >
                <InputField
                  aria-label={messages.admin_guest_lifetime_days()}
                  className="admin-row-input"
                  inputMode="decimal"
                  onChange={(event) =>
                    run(model.setField("lifetimeDays", event.target.value))
                  }
                  type="number"
                  value={state.lifetimeDays}
                  {...(lifetimeError ? { errorMessage: lifetimeError } : {})}
                />
              </AdminRow>
              <AdminRow
                description={messages.admin_guest_pow_hint()}
                title={messages.admin_guest_pow_bits()}
              >
                <InputField
                  aria-label={messages.admin_guest_pow_bits()}
                  className="admin-row-input"
                  inputMode="numeric"
                  onChange={(event) =>
                    run(model.setField("powDifficulty", event.target.value))
                  }
                  type="number"
                  value={state.powDifficulty}
                  {...(difficultyError ? { errorMessage: difficultyError } : {})}
                />
              </AdminRow>
              <AdminRow
                description={messages.admin_free_note()}
                title={messages.admin_guest_models()}
              >
                <Button
                  hierarchy="secondary-gray"
                  onPress={() => run(model.openFreeRouterModels)}
                  size="sm"
                >
                  {messages.admin_open_free_models()}
                </Button>
              </AdminRow>
            </AdminSection>
          </div>
        ) : null}
      </ScrollArea>
      <AdminSaveBar
        canSave={canSave}
        changes={changes}
        disabled={busy}
        onDiscard={() => run(model.discard)}
        onSave={() => run(model.reviewPolicy)}
        saveLabel={messages.admin_save_guest_mode()}
      />
      <AdminConfirmationDialog confirmation={model.confirmation} />
    </section>
  );
}
