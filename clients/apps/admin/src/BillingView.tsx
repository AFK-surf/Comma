import { Badge } from "@comma/ui/components/Badge";
import { Button } from "@comma/ui/components/Button";
import { InputField } from "@comma/ui/components/input";
import { PlusIcon, SearchIcon } from "@comma/ui/components/icons";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import type { AdminPackageVersion } from "./adminApi";
import { lookupMatchLabel, lookupSubtitle } from "./AdminSearchPalette";
import { confirmationBusy } from "./adminModel";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import {
  AdminConfirmationDialog,
  AdminDrawer,
  AdminNotice,
  AdminPageHeader,
  AdminState,
  DetailList,
  NativeField,
  StatusBadge,
  displayText,
  formatIso,
} from "./adminUi";
import type {
  ApplyCodeModel,
  BillingModel,
  CatalogState,
  CreateCodeModel,
  RedeemCodeModel,
  RedemptionsState,
} from "./BillingModel";
import {
  billingViewLimit,
  packageLabel,
  packageVersionKey,
  redemptionOwner,
  scopeLabel,
  selectedPackage,
  type CatalogRedeemCode,
} from "./redeemCodeCatalog";

export {
  withoutRedeemCodePlaintext,
  type CatalogRedeemCode,
} from "./redeemCodeCatalog";
import { messages } from "@comma/i18n";

export function BillingView({ model }: { model: BillingModel }) {
  const run = useAdminCommand();
  const { catalog: state, drawer, notice } = useAdminState(model.state);
  const closeDrawer = () => run(model.closeDrawer);

  const ready = state.status === "ready" ? state : undefined;

  return (
    <section
      aria-label={messages.admin_billing_region()}
      className="admin-workspace"
      data-testid="admin-billing"
    >
      <AdminPageHeader
        actions={
          <div className="admin-heading-buttons">
            <Button
              hierarchy="secondary-gray"
              isDisabled={!ready?.codes.length}
              onPress={() => run(model.openApply)}
            >
              {messages.admin_apply_code()}
            </Button>
            <Button
              iconLeading={<PlusIcon />}
              isDisabled={!ready?.packages.length}
              onPress={() => run(model.openCreate)}
            >
              {messages.admin_new_code()}
            </Button>
          </div>
        }
        description={messages.admin_codes_description()}
        title={messages.admin_section_billing()}
      />

      <ScrollArea
        className="admin-page-scroll"
        contentClassName="admin-page-scroll-content"
        data-testid="admin-billing-scroll"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
      >
        {notice ? (
          <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
        ) : null}

        <div className="admin-table-card admin-table-card--flow">
          <div className="admin-table-card-header">
            <div>
              <h2>{messages.admin_code_records()}</h2>
              <p>{messages.admin_latest_codes({ count: billingViewLimit })}</p>
            </div>
            <Button
              hierarchy="secondary-gray"
              onPress={() => run(model.reload)}
              size="sm"
            >
              {messages.admin_refresh()}
            </Button>
          </div>

          <CatalogContent
            onRetry={() => run(model.reload)}
            onSelect={(code) => run(model.openCode(code))}
            state={state}
          />
        </div>
      </ScrollArea>

      {drawer?.kind === "create" && ready ? (
        <CreateCodeDrawer model={drawer.model} onClose={closeDrawer} />
      ) : null}

      {drawer?.kind === "apply" && ready ? (
        <ApplyCodeDrawer model={drawer.model} onClose={closeDrawer} />
      ) : null}

      {drawer?.kind === "code" && ready ? (
        <RedeemCodeDrawer
          model={drawer.model}
          onClose={closeDrawer}
          packages={ready.packages}
        />
      ) : null}
    </section>
  );
}

function CatalogContent({
  onRetry,
  onSelect,
  state,
}: {
  onRetry: () => void;
  onSelect: (code: CatalogRedeemCode) => void;
  state: CatalogState;
}) {
  if (state.status === "loading") {
    return <AdminState title={messages.admin_loading_codes()} />;
  }
  if (state.status === "error") {
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title={messages.admin_codes_load_failed()}
        tone="error"
      />
    );
  }
  if (state.codes.length === 0) {
    return (
      <>
        {state.packageNotice ? (
          <output className="admin-inline-notice">{state.packageNotice}</output>
        ) : null}
        <AdminState
          message={messages.admin_codes_none_body()}
          title={messages.admin_codes_none()}
        />
      </>
    );
  }

  return (
    <>
      {state.packageNotice ? (
        <output className="admin-inline-notice">{state.packageNotice}</output>
      ) : null}
      <ScrollArea
        className="admin-table-scroll"
        contentClassName="admin-table-content"
        edgeEffect="none"
        orientation="both"
        scrollbarVisibility="hover"
        viewportClassName="admin-table-viewport"
      >
        <table
          aria-label={messages.admin_section_billing()}
          className="admin-data-table"
        >
          <thead>
            <tr>
              <th scope="col">{messages.admin_column_code()}</th>
              <th scope="col">{messages.admin_column_package()}</th>
              <th scope="col">{messages.admin_column_status()}</th>
              <th scope="col">{messages.admin_column_scope()}</th>
              <th scope="col">{messages.admin_column_expires()}</th>
              <th aria-label={messages.admin_manage_code()} scope="col" />
            </tr>
          </thead>
          <tbody>
            {state.codes.map((code) => (
              <tr key={code.id}>
                <th
                  aria-label={messages.admin_code_named({
                    name: displayText(code.display_prefix),
                  })}
                  scope="row"
                >
                  <div className="admin-primary-cell">
                    <strong>{displayText(code.display_prefix)}</strong>
                    <span>{displayText(code.code_type)}</span>
                  </div>
                </th>
                <td>{packageLabel(code, state.packages)}</td>
                <td>
                  <StatusBadge status={code.status} />
                </td>
                <td>{scopeLabel(code)}</td>
                <td>{formatIso(code.expires_at)}</td>
                <td className="admin-row-action-cell">
                  <Button
                    hierarchy="secondary-gray"
                    onPress={() => onSelect(code)}
                    size="sm"
                  >
                    {messages.admin_manage()}
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </ScrollArea>
      <div className="admin-table-footer">
        <p>
          Showing the latest {state.codes.length} of up to {billingViewLimit} code
          records
        </p>
      </div>
    </>
  );
}

function CreateCodeDrawer({
  model,
  onClose,
}: {
  model: CreateCodeModel;
  onClose: () => void;
}) {
  const run = useAdminCommand();
  const {
    copied,
    created,
    customCode,
    expiresAt,
    maxRedemptions,
    packageKey,
    perAccountLimit,
  } = useAdminState(model.state);
  const commandBusy = useAdminState(model.confirmation.state, confirmationBusy);
  const { packages } = model;
  const selected = selectedPackage(packages, packageKey);

  if (created) {
    if (created.kind === "recovered_redacted") {
      const record = created.record;

      return (
        <AdminDrawer
          eyebrow={messages.admin_section_billing()}
          onClose={onClose}
          title={messages.admin_code_recovered_title()}
        >
          <section
            aria-label={messages.admin_code_recovered_region()}
            className="admin-secret-panel"
          >
            <Badge color="gray" size="sm" type="pill-color">
              {messages.admin_recovered()}
            </Badge>
            <div>
              <h3>{displayText(record.display_prefix)}</h3>
              <p>{messages.admin_code_recovered_body()}</p>
            </div>
            <DetailList
              items={[
                { label: messages.admin_code_id(), value: record.id },
                {
                  label: messages.admin_package(),
                  value: `${record.package_code}@${record.package_version}`,
                },
                { label: messages.admin_type(), value: displayText(record.code_type) },
              ]}
            />
            <div className="admin-command-actions">
              <Button onPress={onClose}>{messages.admin_done()}</Button>
            </div>
          </section>
        </AdminDrawer>
      );
    }

    const record = created.record;

    return (
      <AdminDrawer
        eyebrow={messages.admin_section_billing()}
        onClose={onClose}
        title={messages.admin_code_created()}
      >
        <section
          aria-label={messages.admin_code_once_region()}
          className="admin-secret-panel"
        >
          <Badge color="warning" size="sm" type="pill-color">
            {messages.admin_shown_once()}
          </Badge>
          <div>
            <h3>{displayText(record.display_prefix)}</h3>
            <p>{messages.admin_code_once_body()}</p>
          </div>
          <code>{record.code}</code>
          <DetailList
            items={[
              { label: messages.admin_code_id(), value: record.id },
              {
                label: messages.admin_package(),
                value: `${record.package_code}@${record.package_version}`,
              },
              { label: messages.admin_type(), value: displayText(record.code_type) },
            ]}
          />
          <div className="admin-command-actions">
            <Button hierarchy="secondary-gray" onPress={() => run(model.copyCode)}>
              {copied ? messages.admin_copied() : messages.admin_copy_code()}
            </Button>
            <Button onPress={onClose}>{messages.admin_done_and_clear()}</Button>
          </div>
        </section>
      </AdminDrawer>
    );
  }

  return (
    <AdminDrawer
      eyebrow={messages.admin_section_billing()}
      isDismissable={!commandBusy}
      onClose={onClose}
      title={messages.admin_new_redeem_code()}
    >
      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          run(model.review);
        }}
      >
        <NativeField label={messages.admin_package_version()}>
          <select
            onChange={(event) => run(model.setField("packageKey", event.target.value))}
            value={packageKey}
          >
            {packages.map((item) => (
              <option key={item.id} value={packageVersionKey(item)}>
                {item.package_name || item.package_code} · {item.version}
              </option>
            ))}
          </select>
        </NativeField>
        <InputField
          hint={messages.admin_custom_code_hint()}
          label={messages.admin_custom_code()}
          minLength={9}
          onChange={(event) => run(model.setField("customCode", event.target.value))}
          value={customCode}
        />
        <div className="admin-form-grid">
          <InputField
            label={messages.admin_max_redemptions()}
            min={1}
            onChange={(event) =>
              run(model.setLimit("maxRedemptions", Number(event.target.value)))
            }
            type="number"
            value={String(maxRedemptions)}
          />
          <InputField
            label={messages.admin_per_account_limit()}
            min={1}
            onChange={(event) =>
              run(model.setLimit("perAccountLimit", Number(event.target.value)))
            }
            type="number"
            value={String(perAccountLimit)}
          />
        </div>
        <InputField
          label={messages.admin_expires_optional()}
          onChange={(event) => run(model.setField("expiresAt", event.target.value))}
          type="datetime-local"
          value={expiresAt}
        />
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onClose}>
            {messages.admin_cancel()}
          </Button>
          <Button
            isDisabled={
              !selected ||
              (customCode.trim().length > 0 && customCode.trim().length < 9)
            }
            type="submit"
          >
            {messages.admin_review_command()}
          </Button>
        </div>
      </form>

      <AdminConfirmationDialog confirmation={model.confirmation} />
    </AdminDrawer>
  );
}

function ApplyCodeDrawer({
  model,
  onClose,
}: {
  model: ApplyCodeModel;
  onClose: () => void;
}) {
  const run = useAdminCommand();
  const { codeId, target } = useAdminState(model.state);
  const commandBusy = useAdminState(model.confirmation.state, confirmationBusy);
  const { codes } = model;
  const activeCodes = codes.filter((code) => code.status === "active");
  const selected = codes.find((code) => code.id === codeId);

  return (
    <AdminDrawer
      eyebrow={messages.admin_section_billing()}
      isDismissable={!commandBusy}
      onClose={onClose}
      title={messages.admin_apply_redeem_code_title()}
    >
      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          run(model.review);
        }}
      >
        <NativeField label={messages.admin_active_code()}>
          <select
            onChange={(event) => run(model.setCode(event.target.value))}
            value={codeId}
          >
            {activeCodes.map((code) => (
              <option key={code.id} value={code.id}>
                {displayText(code.display_prefix)} · {code.package_code}@
                {code.package_version}
              </option>
            ))}
          </select>
        </NativeField>
        {target ? (
          <div className="admin-apply-target">
            <DetailList
              items={[
                ...(target.accountLabel
                  ? [
                      {
                        label: messages.admin_apply_account(),
                        value: target.accountLabel,
                      },
                    ]
                  : []),
                {
                  label: messages.admin_target_workspace(),
                  value: target.workspaceName || target.productOwnerId,
                },
                { label: messages.admin_workspace_id(), value: target.productOwnerId },
                {
                  label: messages.admin_billing_account(),
                  value: target.billingAccountId,
                },
              ]}
            />
            {target.accountLabel ? (
              <Button
                hierarchy="link-gray"
                onPress={() => run(model.changeAccount)}
                size="sm"
              >
                {messages.admin_apply_change_account()}
              </Button>
            ) : null}
          </div>
        ) : (
          <ApplyAccountPicker model={model} />
        )}
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onClose}>
            {messages.admin_cancel()}
          </Button>
          <Button isDisabled={!selected || !target} type="submit">
            {messages.admin_review_command()}
          </Button>
        </div>
      </form>

      <AdminConfirmationDialog confirmation={model.confirmation} />
    </AdminDrawer>
  );
}

/** Finds the account a code goes to by email or any id, the way ⌘K does, and reads its Workspace. */
function ApplyAccountPicker({ model }: { model: ApplyCodeModel }) {
  const run = useAdminCommand();
  const { account } = useAdminState(model.state);
  const { query, results } = useAdminState(model.search.state);
  const status =
    account.status === "loading"
      ? messages.admin_apply_account_loading({ email: account.email })
      : results.status === "idle"
        ? messages.admin_search_hint()
        : results.status === "loading"
          ? messages.admin_searching()
          : results.status === "error"
            ? results.message
            : results.results.length === 0
              ? messages.admin_search_empty()
              : undefined;

  return (
    <div className="admin-account-picker">
      <InputField
        className="admin-account-search"
        label={messages.admin_apply_account()}
        leadingIcon={<SearchIcon />}
        onChange={(event) => run(model.search.setQuery(event.target.value))}
        placeholder={messages.admin_search_placeholder()}
        value={query}
      />
      {account.status === "error" ? (
        <p className="admin-account-picker-note" role="alert">
          {account.message}
        </p>
      ) : status ? (
        <p className="admin-account-picker-note">{status}</p>
      ) : null}
      {results.status === "ready" && results.results.length > 0 ? (
        <ul
          aria-label={messages.admin_search_results()}
          className="admin-account-results"
        >
          {results.results.map((result) => (
            <li key={`${result.match}:${result.user.id}`}>
              <button
                disabled={account.status === "loading"}
                onClick={() => run(model.chooseAccount(result))}
                type="button"
              >
                <span className="admin-account-result-copy">
                  <strong>{displayText(result.user.email ?? result.user.id)}</strong>
                  <span>{lookupSubtitle(result)}</span>
                </span>
                <span className="admin-account-result-match">
                  {lookupMatchLabel(result)}
                </span>
              </button>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function RedeemCodeDrawer({
  model,
  onClose,
  packages,
}: {
  model: RedeemCodeModel;
  onClose: () => void;
  packages: ReadonlyArray<AdminPackageVersion>;
}) {
  const run = useAdminCommand();
  const { code, redemptions } = useAdminState(model.state);
  const commandBusy = useAdminState(model.confirmation.state, confirmationBusy);
  const resolvedPackageLabel = packageLabel(code, packages);

  return (
    <AdminDrawer
      eyebrow={messages.admin_section_billing()}
      isDismissable={!commandBusy}
      onClose={onClose}
      title={displayText(code.display_prefix)}
    >
      <div className="admin-drawer-summary">
        <div>
          <h3>{resolvedPackageLabel}</h3>
          <p>{displayText(code.code_type)}</p>
        </div>
        <StatusBadge status={code.status} />
      </div>

      <DetailList
        items={[
          { label: messages.admin_code_id(), value: code.id },
          {
            label: messages.admin_display_prefix(),
            value: displayText(code.display_prefix),
          },
          { label: messages.admin_package(), value: resolvedPackageLabel },
          { label: messages.admin_surface(), value: displayText(code.surface) },
          { label: messages.admin_column_scope(), value: scopeLabel(code) },
          {
            label: messages.admin_max_redemptions(),
            value: code.max_redemptions ?? messages.admin_unlimited(),
          },
          {
            label: messages.admin_per_account_limit(),
            value: code.per_account_limit ?? messages.admin_unlimited(),
          },
          { label: messages.admin_valid_from(), value: formatIso(code.valid_from) },
          { label: messages.admin_expires(), value: formatIso(code.expires_at) },
        ]}
      />

      {code.status === "active" ? (
        <section className="admin-danger-zone">
          <div>
            <h3>{messages.admin_disable_code()}</h3>
            <p>{messages.admin_disable_code_body()}</p>
          </div>
          <Button hierarchy="destructive" onPress={() => run(model.reviewDisable)}>
            {messages.admin_disable_code()}
          </Button>
        </section>
      ) : null}

      <section
        className="admin-drawer-section"
        aria-label={messages.admin_redemptions()}
      >
        <div className="admin-drawer-section-header">
          <div>
            <h3>{messages.admin_redemptions()}</h3>
            <p>{messages.admin_redemptions_scope({ count: billingViewLimit })}</p>
          </div>
          <Button
            hierarchy="secondary-gray"
            onPress={() => run(model.reload)}
            size="sm"
          >
            {messages.admin_refresh()}
          </Button>
        </div>
        <RedemptionsContent onRetry={() => run(model.reload)} state={redemptions} />
      </section>

      <AdminConfirmationDialog confirmation={model.confirmation} />
    </AdminDrawer>
  );
}

function RedemptionsContent({
  onRetry,
  state,
}: {
  onRetry: () => void;
  state: RedemptionsState;
}) {
  if (state.status === "loading") {
    return <AdminState title={messages.admin_loading()} />;
  }
  if (state.status === "error") {
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title={messages.admin_redemptions_load_failed()}
        tone="error"
      />
    );
  }
  if (state.redemptions.length === 0) {
    return (
      <AdminState
        message={messages.admin_redemptions_none_body()}
        title={messages.admin_redemptions_none()}
      />
    );
  }

  return (
    <>
      <ScrollArea
        className="admin-nested-table-scroll"
        contentClassName="admin-table-content"
        edgeEffect="none"
        orientation="both"
        scrollbarVisibility="hover"
        viewportClassName="admin-table-viewport"
      >
        <table
          aria-label={messages.admin_redemptions_for_code()}
          className="admin-data-table"
        >
          <thead>
            <tr>
              <th scope="col">{messages.admin_column_billing_account()}</th>
              <th scope="col">{messages.admin_column_owner()}</th>
              <th scope="col">{messages.admin_column_source()}</th>
              <th scope="col">{messages.admin_column_status()}</th>
            </tr>
          </thead>
          <tbody>
            {state.redemptions.map((redemption) => (
              <tr key={redemption.id}>
                <td>{redemption.billing_account_id}</td>
                <td>{redemptionOwner(redemption)}</td>
                <td>{displayText(redemption.source_type)}</td>
                <td>
                  <StatusBadge status={redemption.status} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </ScrollArea>
      <p className="admin-bounded-caption">
        Showing the latest {state.redemptions.length} of up to {billingViewLimit} scoped
        records
      </p>
    </>
  );
}
