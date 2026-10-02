import {
  Button,
  ChevronDownSmallIcon,
  Dialog,
  Dropdown,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  MoreHorizontalIcon,
  ScrollArea,
  SubscriptionCredentialInput,
  Toggle,
} from "@comma/ui";
import { useEffect, useRef, useState } from "react";
import {
  BftApiError,
  subscriptionProviders,
  type BftAccount,
  type BftAccountsPage,
  type BftAccountUsage,
  type BftOAuthAttempt,
  type BftResetResult,
  type BftSubscriptionProvider,
} from "./api";
import { ConfirmDialog, CopyButton, DialogError, writeErrorMessage } from "./dialogs";
import { formatRelative, humanize } from "./format";
import { messages } from "./messages";
import { useApi, useResource } from "./resource";
import {
  FormDialog,
  FormSection,
  SecretField,
  TextAreaField,
  TextField,
  Unavailable,
  useConfirm,
  useWrite,
} from "./settingsForm";
import { Skeleton } from "./states";

const t = messages.settings.models.accounts;

const maxCredentialBytes = 2 * 1024 * 1024;

type DialogState =
  | { kind: "connect"; account: BftAccount | null }
  | { kind: "import"; account: BftAccount | null }
  | { kind: "key" | "name" | "connection"; account: BftAccount | null }
  | { kind: "usage" | "reset"; account: BftAccount };

const isKey = (account: BftAccount) => account.credential_kind === "provider_api_key";
const identity = (account: BftAccount) =>
  account.name ?? account.email ?? t.identityUnknown;
const providerName = (provider: string | null) =>
  (provider && t.providers[provider]) ?? provider ?? "";
const resetPending = (account: BftAccount) =>
  account.reset_attempt?.outcome === "pending";
const resetCount = (account: BftAccount) =>
  account.quota?.reset_credits?.available_count ?? null;
const resetAvailable = (account: BftAccount) =>
  account.provider === "codex" &&
  account.status === "active" &&
  (resetPending(account) || (resetCount(account) ?? 0) > 0);

/** The weekly window when there is one, then the monthly one, then the first. */
function primaryWindow(account: BftAccount) {
  const windows = account.quota?.windows ?? [];
  return (
    windows.find((window) => window.period === "week") ??
    windows.find((window) => window.period === "month") ??
    windows[0]
  );
}

const percent = (value: number) => `${Math.round(value * 10) / 10}%`;

/** The second line of a row: what the account is and how much of it is left. */
function accountDetail(account: BftAccount) {
  if (isKey(account)) {
    const runtimes = account.compatible_runtimes
      .map((runtime) => (runtime === "pi" ? runtime : humanize(runtime)))
      .join(", ");
    return [
      t.providerKey,
      account.connection?.endpoint,
      account.connection &&
        (t.protocols[account.connection.protocol] ?? account.connection.protocol),
      runtimes,
    ];
  }
  const window = primaryWindow(account);
  const plan = account.quota?.plan_type?.trim();
  return [
    providerName(account.provider),
    t.plan(plan ? humanize(plan) : null),
    window?.remaining_percent != null
      ? t.quota(
          percent(window.remaining_percent),
          t.periods[window.period ?? ""] ?? window.period ?? ""
        )
      : t.notChecked,
    account.provider === "claude" ? t.resetUnsupported : t.resets(resetCount(account)),
  ];
}

function quotaTimes(account: BftAccount) {
  const window = primaryWindow(account);
  const resetsAt = window?.reset_at;
  const observedAt = account.quota?.observed_at;
  return [
    resetsAt && Date.parse(resetsAt) > Date.now()
      ? t.resetsAt(formatRelative(resetsAt) ?? resetsAt)
      : undefined,
    observedAt ? t.updatedAt(formatRelative(observedAt) ?? observedAt) : undefined,
  ]
    .filter(Boolean)
    .join(" · ");
}

/** A request id for one reset attempt; the server accepts 16 to 128 URL-safe characters. */
function newRequestId() {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

/**
 * The organization's subscriptions and Provider API keys. Each write returns
 * the refreshed page, so a row change needs no second read.
 */
export function AccountsSection({ org }: { org: string }) {
  const api = useApi();
  const [cursor, setCursor] = useState<string | null>(null);
  const [resource, retry] = useResource(`accounts:${org}:${cursor ?? ""}`, (signal) =>
    api.modelAccounts(org, cursor, signal)
  );
  const [written, setWritten] = useState<BftAccountsPage | null>(null);
  const [dialog, setDialog] = useState<DialogState | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const rowWrite = useWrite();
  const confirm = useConfirm();
  const page = written ?? (resource.state === "ready" ? resource.data : null);

  const goTo = (next: string | null) => {
    setWritten(null);
    setNotice(null);
    setCursor(next);
  };
  const apply = (next: BftAccountsPage) => setWritten(next);
  const replaceAccount = (account: BftAccount) =>
    page &&
    setWritten({
      ...page,
      accounts: page.accounts.map((old) => (old.id === account.id ? account : old)),
    });
  const reload = () => {
    setWritten(null);
    retry();
  };
  // A 409 or 404 means another admin changed this list: re-read it so the
  // next attempt carries the current versions.
  const fresh = <T,>(write: Promise<T>) =>
    write.catch((error: unknown) => {
      if (
        error instanceof BftApiError &&
        (error.status === 409 || error.status === 404)
      )
        reload();
      throw error;
    });
  const rowAction = (action: () => Promise<BftAccountsPage>) => {
    setNotice(null);
    rowWrite.run(action, apply);
  };

  // Disabling a Provider API key starts removing it from runtimes: ask first.
  const toggle = (account: BftAccount) => {
    const change = { version: account.version, disabled: !account.disabled };
    const write = () => fresh(api.updateModelAccount(org, account.id, change, cursor));
    if (isKey(account) && !account.disabled) {
      confirm.ask({
        title: t.disableTitle,
        description: t.disableBody,
        confirmLabel: t.disableConfirm,
        action: () => write().then(apply),
      });
    } else rowAction(write);
  };

  const remove = (account: BftAccount) =>
    confirm.ask({
      title: isKey(account) ? t.removeKeyTitle : t.removeTitle,
      description: isKey(account) ? t.removeKeyBody : t.removeBody,
      confirmLabel: t.remove,
      action: () => fresh(api.deleteModelAccount(org, account, cursor)).then(apply),
    });

  return (
    <FormSection
      action={
        <MenuTrigger>
          <Button
            hierarchy="secondary-gray"
            iconTrailing={<ChevronDownSmallIcon />}
            size="xs"
          >
            {t.add}
          </Button>
          <MenuPopover className="bft-menu-popover" placement="bottom end">
            <Menu aria-label={t.add}>
              <MenuItem
                id="connect"
                onAction={() => setDialog({ kind: "connect", account: null })}
              >
                {t.connect}
              </MenuItem>
              <MenuItem
                id="import"
                onAction={() => setDialog({ kind: "import", account: null })}
              >
                {t.import}
              </MenuItem>
              <MenuItem
                id="key"
                onAction={() => setDialog({ kind: "key", account: null })}
              >
                {t.addKey}
              </MenuItem>
            </Menu>
          </MenuPopover>
        </MenuTrigger>
      }
      description={t.description}
      id="accounts"
      title={t.title}
    >
      {notice ? (
        <output className="bft-notice">
          <p>{notice}</p>
        </output>
      ) : null}
      <DialogError message={rowWrite.error} />
      {resource.state === "error" && !written ? (
        <Unavailable onRetry={retry} />
      ) : page === null ? (
        <Skeleton height={32} />
      ) : page.accounts.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.empty}</p>
      ) : (
        <ul
          aria-busy={rowWrite.busy}
          aria-label={t.listLabel}
          className="bft-list bft-setting-rows"
        >
          {page.accounts.map((account) => (
            <AccountRow
              account={account}
              busy={rowWrite.busy}
              key={account.id}
              onAction={(action) => {
                switch (action) {
                  case "toggle":
                    return toggle(account);
                  case "quota":
                    return rowAction(() =>
                      fresh(api.refreshAccountQuota(org, account.id, cursor))
                    );
                  case "remove":
                    return remove(account);
                  case "reauthorize":
                    return setDialog({ kind: "connect", account });
                  case "replace":
                    return setDialog({ kind: "import", account });
                  case "name":
                  case "connection":
                    return setDialog({ kind: action, account });
                  case "usage":
                  case "reset":
                    return setDialog({ kind: action, account });
                }
              }}
            />
          ))}
        </ul>
      )}
      {page && (cursor !== null || page.next !== null) ? (
        <div className="bft-inline-actions">
          {cursor !== null ? (
            <Button hierarchy="secondary-gray" onPress={() => goTo(null)} size="xs">
              {t.firstPage}
            </Button>
          ) : null}
          {page.next !== null ? (
            <Button
              hierarchy="secondary-gray"
              onPress={() => goTo(page.next)}
              size="xs"
            >
              {t.nextPage}
            </Button>
          ) : null}
        </div>
      ) : null}
      {dialog?.kind === "connect" ? (
        <ConnectDialog
          account={dialog.account}
          onClose={() => setDialog(null)}
          onConnected={() => {
            setDialog(null);
            reload();
          }}
          org={org}
        />
      ) : dialog?.kind === "import" ? (
        <ImportDialog
          account={dialog.account}
          onClose={() => setDialog(null)}
          save={(credentials, provider) =>
            fresh(
              dialog.account
                ? api.updateModelAccount(
                    org,
                    dialog.account.id,
                    { version: dialog.account.version, credentials },
                    cursor
                  )
                : api.createModelAccount(
                    org,
                    { kind: "subscription", provider, credentials },
                    cursor
                  )
            ).then((next) => {
              apply(next);
              setDialog(null);
            })
          }
        />
      ) : dialog?.kind === "key" ||
        dialog?.kind === "name" ||
        dialog?.kind === "connection" ? (
        <KeyDialog
          account={dialog.account}
          mode={dialog.kind}
          onClose={() => setDialog(null)}
          save={(changes) =>
            fresh(
              dialog.account
                ? api.updateModelAccount(
                    org,
                    dialog.account.id,
                    { ...changes, version: dialog.account.version },
                    cursor
                  )
                : api.createModelAccount(
                    org,
                    { ...changes, kind: "provider_api_key" },
                    cursor
                  )
            ).then((next) => {
              apply(next);
              setDialog(null);
            })
          }
        />
      ) : dialog?.kind === "usage" ? (
        <UsageDialog
          load={(next, signal) =>
            api.accountUsage(org, dialog.account.id, next, signal)
          }
          onClose={() => setDialog(null)}
        />
      ) : dialog?.kind === "reset" ? (
        <ResetDialog
          account={dialog.account}
          onClose={() => setDialog(null)}
          onPending={(account) => {
            replaceAccount(account);
            setDialog({ kind: "reset", account });
          }}
          onReset={(result) => {
            replaceAccount(result.account);
            setNotice(
              [
                t.outcomes[result.outcome] ?? result.outcome,
                result.quota_refreshed ? t.quotaRefreshed : t.quotaNotRefreshed,
              ].join(" ")
            );
            setDialog(null);
          }}
          reset={(account, requestId) =>
            fresh(api.resetAccountQuota(org, account, requestId))
          }
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

type RowAction =
  | "toggle"
  | "quota"
  | "reset"
  | "reauthorize"
  | "replace"
  | "remove"
  | "usage"
  | "name"
  | "connection";

function AccountRow({
  account,
  busy,
  onAction,
}: {
  account: BftAccount;
  busy: boolean;
  onAction: (action: RowAction) => void;
}) {
  const name = identity(account);
  const key = isKey(account);
  const items: [RowAction, string, boolean?][] = key
    ? [
        ["usage", t.usage],
        ["name", t.editName],
        ["connection", t.editConnection],
      ]
    : [
        ["quota", t.refresh],
        ...(account.provider === "codex"
          ? [
              [
                "reset",
                resetPending(account) ? t.resetPending : t.reset,
                !resetAvailable(account),
              ] as [RowAction, string, boolean],
            ]
          : []),
        ["reauthorize", t.reauthorize],
        ["replace", t.replace],
      ];
  return (
    <li className="bft-setting-row" data-disabled={account.disabled || undefined}>
      <Toggle
        aria-label={t.enableFor(name)}
        checked={!account.disabled}
        disabled={busy}
        onChange={() => onAction("toggle")}
        size="sm"
      />
      <span className="bft-setting-row-main">
        <span className="bft-row-title">
          <span className="bft-truncate" title={account.id}>
            {name}
          </span>
          {account.status === "reauthorization_required" ? (
            <span className="bft-tag bft-tag-warn">{t.reauthRequired}</span>
          ) : null}
          {account.disabled ? <span className="bft-tag">{t.disabled}</span> : null}
        </span>
        <span
          className="bft-setting-row-sub bft-truncate"
          title={key ? account.connection?.endpoint : quotaTimes(account) || undefined}
        >
          {accountDetail(account).filter(Boolean).join(" · ")}
        </span>
      </span>
      <MenuTrigger>
        <Button
          aria-label={t.actionsFor(name)}
          disabled={busy}
          hierarchy="tertiary-gray"
          iconLeading={<MoreHorizontalIcon />}
          iconOnly
          size="xs"
        />
        <MenuPopover className="bft-menu-popover" placement="bottom end">
          <Menu aria-label={t.actionsFor(name)}>
            {items.map(([id, label, disabled]) => (
              <MenuItem
                id={id}
                isDisabled={disabled === true}
                key={id}
                onAction={() => onAction(id)}
              >
                {label}
              </MenuItem>
            ))}
            <MenuSeparator />
            <MenuItem
              id="remove"
              onAction={() => onAction("remove")}
              tone="destructive"
            >
              {t.remove}
            </MenuItem>
          </Menu>
        </MenuPopover>
      </MenuTrigger>
    </li>
  );
}

const providerItems = subscriptionProviders.map((id) => ({
  id,
  label: t.providers[id] ?? id,
}));

/**
 * Codex signs in with a device code that this dialog polls for; Claude opens
 * a sign-in page and the admin pastes the callback URL back. The Claude tab
 * opens during the click, before the request, so the browser does not block it.
 */
function ConnectDialog({
  org,
  account,
  onClose,
  onConnected,
}: {
  org: string;
  account: BftAccount | null;
  onClose: () => void;
  onConnected: () => void;
}) {
  const api = useApi();
  const [provider, setProvider] = useState<BftSubscriptionProvider>(
    account?.provider === "claude" ? "claude" : "codex"
  );
  const [attempt, setAttempt] = useState<BftOAuthAttempt | null>(null);
  const [code, setCode] = useState("");
  const [pollError, setPollError] = useState<string | undefined>();
  const write = useWrite();
  const popup = useRef<Window | null>(null);
  const connected = useRef(onConnected);
  connected.current = onConnected;
  const label = t.providers[provider] ?? provider;

  const closePopup = () => {
    if (popup.current && !popup.current.closed) popup.current.close();
    popup.current = null;
  };
  useEffect(() => closePopup, []);

  // One poll per provider interval (at least 5 s) for the 15-minute attempt.
  useEffect(() => {
    if (attempt?.mode !== "device") return undefined;
    let timer: number | undefined;
    let stopped = false;
    const poll = (interval: number) => {
      timer = window.setTimeout(
        () => {
          api.completeAccountOAuth(org, attempt.id, "").then(
            (result) => {
              if (stopped) return;
              if (result.status === "connected") connected.current();
              else poll(result.interval ?? interval);
            },
            (error: unknown) => {
              if (stopped) return;
              setAttempt(null);
              setPollError(writeErrorMessage(error));
            }
          );
        },
        Math.max(5, interval) * 1000
      );
    };
    poll(attempt.interval);
    return () => {
      stopped = true;
      window.clearTimeout(timer);
    };
  }, [api, org, attempt]);

  const begin = () => {
    setPollError(undefined);
    if (provider === "claude" && !popup.current) {
      popup.current = window.open("about:blank", "_blank");
      if (popup.current) popup.current.opener = null;
    }
    write.run(
      () =>
        api
          .beginAccountOAuth(
            org,
            account
              ? { provider, account_id: account.id, version: account.version }
              : { provider }
          )
          .catch((error: unknown) => {
            closePopup();
            throw error;
          }),
      (next) => {
        setAttempt(next);
        if (next.mode === "callback" && popup.current && !popup.current.closed) {
          popup.current.location.replace(next.href);
        }
        popup.current = null;
      }
    );
  };

  const title = account ? t.reauthorizeTitle : t.connectTitle;

  if (attempt?.mode === "device") {
    return (
      <Dialog
        actions={[
          {
            label: messages.common.cancel,
            hierarchy: "secondary-gray",
            onPress: onClose,
          },
        ]}
        description={t.codexBody}
        isOpen
        onOpenChange={(open) => {
          if (!open) onClose();
        }}
        title={title}
      >
        <div className="bft-form">
          <div className="bft-command">
            <div className="bft-command-head">
              <span className="bft-command-label">{t.deviceCode}</span>
              <CopyButton
                label={messages.common.copyLabel(t.deviceCode)}
                text={attempt.user_code ?? ""}
              />
            </div>
            <p className="bft-device-code">{attempt.user_code}</p>
          </div>
          <a
            className="bft-link"
            href={attempt.href}
            rel="noopener noreferrer"
            target="_blank"
          >
            {t.openAuthorization(label)}
          </a>
          <output className="bft-dialog-note">{t.deviceWaiting}</output>
        </div>
      </Dialog>
    );
  }

  if (attempt) {
    return (
      <FormDialog
        description={t.callbackHint}
        onClose={onClose}
        onSubmit={() =>
          write.run(
            () => api.completeAccountOAuth(org, attempt.id, code.trim()),
            (result) => {
              if (result.status === "connected") onConnected();
            }
          )
        }
        submitLabel={t.connectTitle}
        title={title}
        write={write}
      >
        <a
          className="bft-link"
          href={attempt.href}
          rel="noopener noreferrer"
          target="_blank"
        >
          {t.openAuthorization(label)}
        </a>
        <TextAreaField label={t.callback} mono onChange={setCode} value={code} />
      </FormDialog>
    );
  }

  return (
    <FormDialog
      description={provider === "codex" ? t.codexBody : t.claudeBody}
      onClose={onClose}
      onSubmit={begin}
      submitLabel={t.continueWith(label)}
      title={title}
      write={write}
    >
      {account ? null : (
        <Dropdown
          className="bft-form-field"
          items={providerItems}
          label={t.provider}
          onChange={(value) => setProvider(value as BftSubscriptionProvider)}
          size="sm"
          value={provider}
        />
      )}
      <DialogError message={pollError} />
    </FormDialog>
  );
}

/** Import a subscription's credential file, or replace an account's credentials. */
function ImportDialog({
  account,
  save,
  onClose,
}: {
  account: BftAccount | null;
  save: (
    credentials: Record<string, unknown>,
    provider: BftSubscriptionProvider
  ) => Promise<void>;
  onClose: () => void;
}) {
  const [provider, setProvider] = useState<BftSubscriptionProvider>("codex");
  const [file, setFile] = useState<File | null>(null);
  const [pasted, setPasted] = useState("");
  const [invalid, setInvalid] = useState<string | undefined>();
  const write = useWrite();

  const submit = async () => {
    setInvalid(undefined);
    const text = pasted.trim();
    if (file && text) return setInvalid(t.bothInputs);
    if (!file && !text) return setInvalid(t.noInput);
    if (file && (file.size > maxCredentialBytes || !/\.json$/i.test(file.name))) {
      return setInvalid(t.badFile);
    }
    let credentials: unknown;
    try {
      credentials = JSON.parse(file ? await file.text() : text);
    } catch {
      credentials = null;
    }
    if (!credentials || typeof credentials !== "object" || Array.isArray(credentials)) {
      return setInvalid(t.badJson);
    }
    write.run(
      () => save(credentials as Record<string, unknown>, provider),
      () => undefined
    );
  };

  return (
    <FormDialog
      description={t.importBody}
      onClose={onClose}
      onSubmit={() => void submit()}
      submitLabel={account ? t.replace : t.importSubmit}
      title={account ? t.replaceTitle : t.importTitle}
      write={write}
    >
      {account ? null : (
        <Dropdown
          className="bft-form-field"
          items={providerItems}
          label={t.provider}
          onChange={(value) => setProvider(value as BftSubscriptionProvider)}
          size="sm"
          value={provider}
        />
      )}
      <SubscriptionCredentialInput
        busy={write.busy}
        fileLabel={t.file}
        fileName={file?.name ?? ""}
        fileSource={t.fileHint}
        jsonLabel={t.paste}
        onChange={setPasted}
        onFile={setFile}
        value={pasted}
      />
      {file ? (
        <div className="bft-inline-actions">
          <Button hierarchy="tertiary-gray" onPress={() => setFile(null)} size="xs">
            {t.removeFile}
          </Button>
        </div>
      ) : null}
      <DialogError message={invalid} />
    </FormDialog>
  );
}

const protocolItems = Object.entries(t.protocols).map(([id, label]) => ({ id, label }));
const authItems = Object.entries(t.authSchemes).map(([id, label]) => ({ id, label }));

/** Add a Provider API key, rename one, or change its connection and key. */
function KeyDialog({
  mode,
  account,
  save,
  onClose,
}: {
  mode: "key" | "name" | "connection";
  account: BftAccount | null;
  save: (changes: Record<string, unknown>) => Promise<void>;
  onClose: () => void;
}) {
  const [name, setName] = useState(account?.name ?? "");
  const [endpoint, setEndpoint] = useState(account?.connection?.endpoint ?? "");
  const [protocol, setProtocol] = useState(
    account?.connection?.protocol ?? "anthropic_messages"
  );
  const [auth, setAuth] = useState(account?.connection?.auth_scheme ?? "bearer");
  const [apiKey, setApiKey] = useState("");
  const write = useWrite();
  const withName = mode !== "connection";
  const withConnection = mode !== "name";

  const changes = () => ({
    ...(withName ? { name: name.trim() } : {}),
    ...(withConnection
      ? {
          connection: { endpoint: endpoint.trim(), protocol, auth_scheme: auth },
          credentials: { api_key: apiKey },
        }
      : {}),
  });

  return (
    <FormDialog
      description={t.keyBody}
      onClose={onClose}
      onSubmit={() =>
        write.run(
          () => save(changes()),
          () => undefined
        )
      }
      title={
        mode === "key" ? t.keyTitle : mode === "name" ? t.nameTitle : t.connectionTitle
      }
      write={write}
    >
      {withName ? <TextField label={t.name} onChange={setName} value={name} /> : null}
      {withConnection ? (
        <>
          {mode === "key" ? (
            <div className="bft-inline-actions">
              <Button
                hierarchy="secondary-gray"
                onPress={() => {
                  setEndpoint("https://openrouter.ai/api");
                  setProtocol("anthropic_messages");
                  setAuth("bearer");
                }}
                size="xs"
              >
                {t.useOpenRouter}
              </Button>
            </div>
          ) : null}
          <TextField
            label={t.endpoint}
            onChange={setEndpoint}
            placeholder="https://"
            value={endpoint}
          />
          <Dropdown
            className="bft-form-field"
            items={protocolItems}
            label={t.protocol}
            onChange={setProtocol}
            size="sm"
            value={protocol}
          />
          <Dropdown
            className="bft-form-field"
            items={authItems}
            label={t.authScheme}
            onChange={setAuth}
            size="sm"
            value={auth}
          />
          <SecretField
            configured={false}
            label={t.apiKey}
            onChange={setApiKey}
            value={apiKey}
          />
        </>
      ) : null}
    </FormDialog>
  );
}

/** The workloads bound to a Provider API key, a page at a time. */
function UsageDialog({
  load,
  onClose,
}: {
  load: (cursor: number | null, signal?: AbortSignal) => Promise<BftAccountUsage>;
  onClose: () => void;
}) {
  const [first, retry] = useResource("usage", (signal) => load(null, signal));
  const [more, setMore] = useState<BftAccountUsage[]>([]);
  const write = useWrite();
  const pages = first.state === "ready" ? [first.data, ...more] : [];
  const last = pages.at(-1);
  const bindings = pages.flatMap((page) => page.bindings);
  const hidden = pages.reduce((sum, page) => sum + page.hidden_count, 0);

  return (
    <Dialog
      actions={[
        ...(last?.next != null
          ? [
              {
                label: write.busy ? messages.common.working : t.nextPage,
                hierarchy: "secondary-gray" as const,
                disabled: write.busy,
                onPress: () => {
                  const next = last.next;
                  write.run(
                    () => load(next),
                    (page) => setMore((loaded) => [...loaded, page])
                  );
                },
              },
            ]
          : []),
        { label: t.close, hierarchy: "secondary-gray", onPress: onClose },
      ]}
      description=""
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={t.usageTitle}
    >
      <ScrollArea
        className="bft-dialog-body"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-dialog-scroll"
      >
        <div className="bft-form">
          {first.state === "error" ? (
            <Unavailable onRetry={retry} />
          ) : first.state === "loading" ? (
            <Skeleton height={32} />
          ) : bindings.length === 0 && hidden === 0 ? (
            <p className="bft-dialog-note">{t.usageEmpty}</p>
          ) : (
            <ul className="bft-list bft-setting-rows">
              {bindings.map((binding) => (
                <li
                  className="bft-setting-row"
                  key={`${binding.project.id}:${binding.workload_id}`}
                >
                  <span className="bft-setting-row-main">
                    {binding.href ? (
                      <a className="bft-link bft-truncate" href={binding.href}>
                        {binding.project.name}
                      </a>
                    ) : (
                      <span className="bft-truncate">{binding.project.name}</span>
                    )}
                    <span className="bft-setting-row-sub bft-truncate">
                      {t.workload(binding.workload_id)}
                    </span>
                  </span>
                </li>
              ))}
            </ul>
          )}
          {hidden > 0 ? <p className="bft-dialog-note">{t.usageHidden}</p> : null}
          <DialogError message={write.error} />
        </div>
      </ScrollArea>
    </Dialog>
  );
}

/**
 * Use one Codex reset credit. An unconfirmed result keeps its request id on
 * the account, and the next attempt sends the same id, so a retry checks that
 * reset instead of spending another credit.
 */
function ResetDialog({
  account,
  reset,
  onReset,
  onPending,
  onClose,
}: {
  account: BftAccount;
  reset: (account: BftAccount, requestId: string) => Promise<BftResetResult>;
  onReset: (result: BftResetResult) => void;
  onPending: (account: BftAccount) => void;
  onClose: () => void;
}) {
  const write = useWrite();
  const pending = resetPending(account);
  const confirmReset = () => {
    const requestId = (pending && account.reset_attempt?.request_id) || newRequestId();
    write.run(
      () =>
        reset(account, requestId).catch((error: unknown) => {
          if (
            error instanceof BftApiError &&
            (error.code === "reset_pending" || error.code === "runtime_unavailable")
          ) {
            onPending({
              ...account,
              reset_attempt: { request_id: requestId, outcome: "pending" },
            });
          }
          throw error;
        }),
      onReset
    );
  };
  return (
    <ConfirmDialog
      busy={write.busy}
      confirmLabel={pending ? t.resetCheck : t.reset}
      description={t.resetBody(t.resets(resetCount(account)))}
      error={write.error}
      onClose={onClose}
      onConfirm={confirmReset}
      title={t.resetTitle}
    >
      {pending ? <p className="bft-dialog-note">{t.resetPendingBody}</p> : null}
    </ConfirmDialog>
  );
}
