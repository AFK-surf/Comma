import { Button, Checkbox, Dialog, Dropdown, InputField, ScrollArea } from "@comma/ui";
import { useEffect, useRef, useState } from "react";
import { BftApiError, type BftRuntimeAuthTarget } from "./api";
import { ConfirmDialog } from "./dialogs";
import { messages } from "./messages";
import { useApi } from "./resource";
import {
  activeAttempt,
  ceremonyLink,
  InvalidMaterialError,
  isObject,
  isOffer,
  maximumPlaintext,
  managedAuthPollDelay,
  runtimeAuthMaterial,
  runtimeAuthPollDelay,
  sealRuntimeAuth,
  type RuntimeAuthOffer,
} from "./runtimeAuth";

const t = messages.runtimeAuth;

type Json = Record<string, unknown>;
type Target = BftRuntimeAuthTarget["target"];

const list = (value: unknown): Json[] =>
  Array.isArray(value) ? value.filter(isObject) : [];
const text = (value: unknown) => (typeof value === "string" ? value : undefined);
const codeOf = (error: unknown) =>
  error instanceof BftApiError
    ? (error.code ?? "request_failed")
    : error instanceof InvalidMaterialError
      ? "invalid_format"
      : error instanceof Error
        ? error.message
        : "request_failed";

/**
 * One runtime's authentication: its organization-account binding when the
 * target supports one, and the browser-owned private controls (provider
 * sign-in, API key or auth file, verify) when the runtime configures itself.
 * Secret material is sealed in the browser; closing the dialog drops it.
 */
export function RuntimeAuthDialog({
  org,
  project,
  target,
  canManage,
  requestId,
  onClose,
}: {
  org: string;
  project: string;
  target: Pick<BftRuntimeAuthTarget, "id" | "provider" | "target" | "managed">;
  canManage: boolean;
  requestId: string | null;
  onClose: () => void;
}) {
  // A managed target shows its own sign-in only once the binding is known
  // to be self-configured.
  const [selfAuth, setSelfAuth] = useState(!target.managed);
  const device =
    target.target.kind === "connected_runtime" ? target.target.device_id : null;

  return (
    <Dialog
      actions={[{ label: t.close, hierarchy: "secondary-gray", onPress: onClose }]}
      className="bft-dialog-wide"
      isDismissable
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={t.title}
    >
      <ScrollArea
        className="bft-dialog-body"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-dialog-scroll"
      >
        <div className="bft-form bft-auth">
          <div className="bft-auth-target">
            <p className="bft-mono bft-break">{target.id}</p>
            {device ? <p className="bft-mono bft-break">{t.device(device)}</p> : null}
            <p>{t.shared(target.provider)}</p>
          </div>
          {target.managed ? (
            <ManagedAuth
              onSelfAuth={setSelfAuth}
              org={org}
              project={project}
              target={target.target}
            />
          ) : null}
          {selfAuth && canManage ? (
            <PrivateAuth
              org={org}
              project={project}
              requestId={requestId}
              target={target.target}
            />
          ) : null}
        </div>
      </ScrollArea>
    </Dialog>
  );
}

type ManagedAction = "refresh" | "bind" | "retry" | "unbind" | "accounts-next";

/** The organization-account binding; reads, binds, retries and unbinds. */
function ManagedAuth({
  org,
  project,
  target,
  onSelfAuth,
}: {
  org: string;
  project: string;
  target: Target;
  onSelfAuth: (visible: boolean) => void;
}) {
  const api = useApi();
  const [snapshot, setSnapshot] = useState<Json | null>(null);
  const [feedback, setFeedback] = useState("");
  const [busy, setBusy] = useState(false);
  const [chosenSource, setSource] = useState<"self_configured" | "organization">(
    "self_configured"
  );
  const [chosenAccount, setAccount] = useState<string>();
  const [confirmUnbind, setConfirmUnbind] = useState(false);
  const operation = useRef<AbortController | null>(null);
  const alive = useRef(true);
  const polls = useRef(0);
  const [pollTick, setPollTick] = useState(0);

  const state = text(snapshot?.state);
  const actions = Array.isArray(snapshot?.actions)
    ? (snapshot.actions as unknown[]).filter(
        (item): item is string => typeof item === "string"
      )
    : [];
  const binding = isObject(snapshot?.binding) ? snapshot.binding : null;
  const account = isObject(snapshot?.account) ? snapshot.account : null;
  const accounts = list(snapshot?.accounts);
  // A bound runtime is managed by its organization account.
  const source = state && state !== "unbound" ? "organization" : chosenSource;
  const organization = source === "organization";
  const selected = chosenAccount ?? text(binding?.account_id) ?? text(accounts[0]?.id);
  const selfVisible =
    !!snapshot &&
    !organization &&
    state === "unbound" &&
    (snapshot.can_self_configure ?? snapshot.can_configure) !== false;

  useEffect(() => onSelfAuth(selfVisible), [selfVisible, onSelfAuth]);

  const run = async (action: ManagedAction, poll = false) => {
    if (operation.current) return;
    const controller = new AbortController();
    operation.current = controller;
    setBusy(true);
    let mutated = false;
    const read = (accountCursor?: string) =>
      api.managedAuth(
        org,
        project,
        target,
        { method: "GET", ...(accountCursor ? { accountCursor } : {}) },
        controller.signal
      );
    try {
      let next: Json;
      if (action === "refresh") {
        next = await read();
      } else if (action === "bind") {
        const choice = accounts.find((item) => item.id === selected);
        if (!choice) throw new Error("account_required");
        mutated = true;
        next = await api.managedAuth(
          org,
          project,
          target,
          {
            method: "PUT",
            body: {
              account_id: choice.id,
              expected_account_version: choice.version,
              expected_binding: binding,
            },
          },
          controller.signal
        );
      } else if (action === "retry") {
        mutated = true;
        next = await api.managedAuth(
          org,
          project,
          target,
          {
            method: "PUT",
            body: {
              account_id: binding?.account_id,
              expected_account_version: account?.version,
              expected_binding: binding,
            },
          },
          controller.signal
        );
      } else if (action === "unbind") {
        mutated = true;
        next = await api.managedAuth(
          org,
          project,
          target,
          { method: "DELETE", body: { expected_binding: binding } },
          controller.signal
        );
      } else {
        const cursor = text(snapshot?.accounts_next);
        if (!cursor || !snapshot) return;
        const page = await read(cursor);
        next = { ...page, accounts: [...accounts, ...list(page.accounts)] };
      }
      if (!alive.current || controller.signal.aborted) return;
      // A poll keeps counting; anything the reader does starts over.
      if (!poll) polls.current = 0;
      setSnapshot(next);
      setFeedback(
        t.managedIssues[text(next.issue) ?? ""] ??
          (next.accounts_unavailable ? t.accountsUnavailable : "")
      );
    } catch (error) {
      if (!alive.current || controller.signal.aborted) return;
      if (mutated) {
        try {
          setSnapshot(await read());
          setFeedback(t.uncertain);
          return;
        } catch {
          // Fall through to the failure below.
        }
      }
      setFeedback(codeOf(error) === "forbidden" ? t.managedForbidden : t.managedFailed);
    } finally {
      if (operation.current === controller) operation.current = null;
      if (alive.current) setBusy(false);
    }
  };

  const runRef = useRef(run);
  runRef.current = run;

  useEffect(() => {
    alive.current = true;
    void runRef.current("refresh");
    const onVisibility = () => {
      if (!document.hidden && !operation.current) void runRef.current("refresh");
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      alive.current = false;
      operation.current?.abort();
      operation.current = null;
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, []);

  // An account change still in flight is read again every 5 s, for at most
  // five minutes, while the page is visible.
  useEffect(() => {
    const delay = managedAuthPollDelay(state, polls.current);
    if (delay === null || busy) return undefined;
    const timer = window.setTimeout(() => {
      if (document.hidden || operation.current) return setPollTick((tick) => tick + 1);
      polls.current += 1;
      void runRef.current("refresh", true);
    }, delay);
    return () => window.clearTimeout(timer);
  }, [snapshot, state, busy, pollTick]);

  const chooser = actions.includes("bind") && snapshot?.can_configure !== false;
  const summary = account
    ? [
        text(account.name) ?? text(account.email),
        isObject(account.connection) ? text(account.connection.endpoint) : undefined,
        isObject(account.connection) ? text(account.connection.protocol) : undefined,
      ]
        .filter(Boolean)
        .join(" · ")
    : "";

  return (
    <section aria-label={t.sources.organization} className="bft-auth-section">
      <p className="bft-auth-status">
        {snapshot
          ? (t.managedStates[state ?? ""] ?? t.managedUnknown)
          : t.managedLoading}
      </p>
      {snapshot && chooser ? (
        <>
          {state === "unbound" ? (
            <>
              <p className="bft-dialog-note">{t.unboundHelp}</p>
              <Dropdown
                className="bft-form-field"
                disabled={busy}
                items={(["self_configured", "organization"] as const).map((id) => ({
                  id,
                  label: t.sources[id],
                }))}
                label={t.sourceLabel}
                onChange={(id) => setSource(id as "self_configured" | "organization")}
                size="sm"
                value={source}
              />
            </>
          ) : null}
          {organization ? (
            <>
              <Dropdown
                className="bft-form-field"
                disabled={busy || accounts.length === 0}
                items={accounts.map((item) => ({
                  id: String(item.id),
                  label: text(item.name) ?? text(item.email) ?? String(item.id),
                }))}
                label={t.accountLabel}
                onChange={setAccount}
                size="sm"
                {...(selected ? { value: selected } : {})}
              />
              <div className="bft-rail-actions">
                {snapshot.accounts_next ? (
                  <Button
                    hierarchy="secondary-gray"
                    isDisabled={busy}
                    onPress={() => void run("accounts-next")}
                    size="xs"
                  >
                    {t.moreAccounts}
                  </Button>
                ) : null}
                <Button
                  hierarchy="primary"
                  isDisabled={busy}
                  onPress={() => void run("bind")}
                  size="xs"
                >
                  {binding ? t.changeAccount : t.bind}
                </Button>
              </div>
            </>
          ) : null}
        </>
      ) : null}
      {snapshot && state !== "unbound" ? (
        <div className="bft-auth-bound">
          {summary ? <p>{summary}</p> : null}
          <p className="bft-dialog-note">{t.boundNote}</p>
          <div className="bft-rail-actions">
            {actions.includes("retry") ? (
              <Button
                hierarchy="secondary-gray"
                isDisabled={busy}
                onPress={() => void run("retry")}
                size="xs"
              >
                {t.retry}
              </Button>
            ) : null}
            <Button
              hierarchy="secondary-gray"
              isDisabled={
                busy || snapshot.can_configure === false || !actions.includes("unbind")
              }
              onPress={() => setConfirmUnbind(true)}
              size="xs"
            >
              {t.unbind}
            </Button>
          </div>
        </div>
      ) : null}
      <div>
        <Button
          hierarchy="secondary-gray"
          isDisabled={busy}
          onPress={() => void run("refresh")}
          size="xs"
        >
          {t.recheck}
        </Button>
      </div>
      <output aria-live="polite" className="bft-auth-feedback">
        {feedback}
      </output>
      {confirmUnbind ? (
        <ConfirmDialog
          busy={false}
          confirmLabel={t.unbind}
          description={t.unbindBody}
          destructive
          error={undefined}
          onClose={() => setConfirmUnbind(false)}
          onConfirm={() => {
            setConfirmUnbind(false);
            void run("unbind");
          }}
          title={t.unbind}
        />
      ) : null}
    </section>
  );
}

type PrivateAction =
  | "refresh"
  | "login"
  | "complete-login"
  | "save"
  | "verify"
  | "cancel"
  | "finish-saved";

interface Method {
  backend: string;
  method: string;
  form: string;
}

const methodsOf = (status: Json | null): Method[] =>
  list(status?.methods).flatMap((item) =>
    typeof item.backend === "string" &&
    typeof item.method === "string" &&
    typeof item.form === "string"
      ? [{ backend: item.backend, method: item.method, form: item.form }]
      : []
  );

const methodKey = (method: Method) => `${method.backend}:${method.form}`;

/**
 * The runtime's own sign-in: provider login (device code or a Claude
 * authorization code), an API key or auth file sealed to the runtime, and
 * verification. An active attempt is read again every 5 s, for at most five
 * minutes; closing the dialog stops it and clears the material.
 */
function PrivateAuth({
  org,
  project,
  target,
  requestId,
}: {
  org: string;
  project: string;
  target: Target;
  requestId: string | null;
}) {
  const api = useApi();
  const [status, setStatus] = useState<Json | null>(null);
  const [feedback, setFeedback] = useState("");
  const [busy, setBusy] = useState(false);
  const [chosenMethod, setMethod] = useState<string>();
  const [saveVerify, setSaveVerify] = useState(false);
  const [secret, setSecret] = useState("");
  const [callbackCode, setCallbackCode] = useState("");
  const [expired, setExpired] = useState<string | null>(null);
  const [pending, setPending] = useState(requestId);
  const fileRef = useRef<HTMLInputElement>(null);
  const operation = useRef<AbortController | null>(null);
  const alive = useRef(true);
  const offer = useRef<RuntimeAuthOffer | null>(null);
  const request = useRef(requestId);
  const completionSent = useRef(false);
  const polls = useRef(0);
  const pollAttempt = useRef<string | null>(null);

  const methods = methodsOf(status);
  const imports = methods.filter((method) => method.method === "credential_import");
  const method =
    imports.find((item) => methodKey(item) === chosenMethod) ?? imports[0] ?? null;
  const verifiable = methods.some((item) => item.method === "verify");
  const canSaveVerify =
    !!method &&
    methods.some((item) => item.method === "verify" && item.backend === method.backend);
  const auth = isObject(status?.auth) ? status.auth : {};
  const attempt = isObject(status?.attempt) ? status.attempt : null;
  const ceremony = attempt?.owned === true ? attempt.ceremony : null;
  const link = ceremonyLink(ceremony);
  const attemptId = text(attempt?.attempt_id) ?? null;
  const showCeremony = !!link && expired !== attemptId;

  const clearMaterial = () => {
    setSecret("");
    setCallbackCode("");
    if (fileRef.current) fileRef.current.value = "";
  };

  const call = async (
    controller: AbortController,
    action: string,
    input: Json = {}
  ) => {
    if (!alive.current || operation.current !== controller || controller.signal.aborted)
      throw new Error("target_changed");
    const result = await api.runtimeAuth(
      org,
      project,
      { action, target, ...input },
      controller.signal
    );
    if (!alive.current || operation.current !== controller || controller.signal.aborted)
      throw new Error("target_changed");
    return result;
  };

  // Wakes the Router request this panel was opened for, once.
  const reportCompletion = async (
    outcome: "authenticated" | "canceled" | "saved_unverified"
  ) => {
    const id = request.current;
    if (!id || completionSent.current) return;
    completionSent.current = true;
    request.current = null;
    setPending(null);
    try {
      await api.completeRuntimeAuthRequest(org, project, id, outcome);
    } catch {
      throw new Error("completion_unknown");
    }
  };

  const readMaterial = async (chosen: Method) => {
    if (chosen.form === "api_key")
      return runtimeAuthMaterial(chosen.form, chosen.backend, secret);
    const file = fileRef.current?.files?.[0];
    if (!file || file.size > maximumPlaintext) throw new InvalidMaterialError();
    let content: string;
    try {
      content = new TextDecoder("utf-8", { fatal: true }).decode(
        await file.arrayBuffer()
      );
    } catch {
      throw new InvalidMaterialError();
    }
    return runtimeAuthMaterial(chosen.form, chosen.backend, content);
  };

  const run = async (action: PrivateAction) => {
    if (operation.current && action === "cancel") {
      operation.current.abort();
      operation.current = null;
    }
    if (operation.current) return;
    const controller = new AbortController();
    operation.current = controller;
    setBusy(true);
    let plaintext: Uint8Array | null = null;
    let submitted = false;
    let receipt: Json | null = null;
    setFeedback(action === "save" ? t.saving : t.reading);
    const settle = async () => {
      const next = await call(controller, "status");
      setStatus(next);
      if (isObject(next.auth) && next.auth.status === "authenticated")
        await reportCompletion("authenticated");
      return next;
    };
    try {
      let shown = "";
      if (action === "refresh") {
        await settle();
      } else if (action === "login") {
        const login = methods.find((item) => item.method === "native_login");
        if (!login) throw new InvalidMaterialError();
        const started = await call(controller, "login_start", {
          backend: login.backend,
          flow: login.form,
        });
        if (isOffer(started)) offer.current = started;
        await settle();
        shown =
          login.form === "authorization_code" ? t.loginCodePrompt : t.loginDevicePrompt;
      } else if (action === "complete-login") {
        const current = offer.current;
        if (!current || current.context.method !== "native_login")
          throw new InvalidMaterialError();
        plaintext = runtimeAuthMaterial(
          "authorization_code",
          "anthropic",
          callbackCode
        );
        const envelope = await sealRuntimeAuth(current, plaintext);
        plaintext.fill(0);
        plaintext = null;
        clearMaterial();
        submitted = true;
        receipt = await call(controller, "input_submit", {
          attempt_id: current.context.attempt_id,
          envelope,
        });
        offer.current = null;
        shown =
          receipt.save_result === "committed"
            ? receipt.issue
              ? t.nativeSavedIssue
              : t.nativeSaved
            : (t.issues[text(receipt.issue) ?? ""] ?? t.nativeIncomplete);
        await settle();
      } else if (action === "save") {
        if (!method) throw new InvalidMaterialError();
        plaintext = await readMaterial(method);
        const begun = await call(controller, "input_begin", {
          backend: method.backend,
          form: method.form,
        });
        if (!isOffer(begun)) throw new Error("target_changed");
        const context = begun.context;
        if (
          context.backend !== method.backend ||
          context.form !== method.form ||
          context.target_kind !== target.kind ||
          (target.kind === "compute_workload" &&
            context.workload_id !== target.workload_id) ||
          (target.kind === "connected_runtime" &&
            (context.device_id !== target.device_id ||
              context.runtime_id !== target.runtime_id))
        )
          throw new Error("target_changed");
        const envelope = await sealRuntimeAuth(begun, plaintext);
        plaintext.fill(0);
        plaintext = null;
        clearMaterial();
        if (!alive.current || controller.signal.aborted) return;
        submitted = true;
        receipt = await call(controller, "input_submit", {
          attempt_id: context.attempt_id,
          envelope,
        });
        shown =
          receipt.save_result === "committed"
            ? receipt.issue
              ? t.savedIssue
              : t.saved
            : receipt.save_result === "unknown"
              ? t.saveUnknown
              : (t.issues[text(receipt.issue) ?? ""] ?? t.notSaved);
        if (receipt.save_result === "committed" && !receipt.issue && saveVerify) {
          const verification = await call(controller, "verify", {
            backend: method.backend,
          });
          shown =
            verification.status === "authenticated"
              ? t.savedVerified
              : t.savedWith(
                  t.issues[text(verification.issue) ?? ""] ?? t.verifyIncomplete
                );
        }
        await settle();
      } else if (action === "verify") {
        const verify = methods.find((item) => item.method === "verify");
        if (!verify) throw new InvalidMaterialError();
        setFeedback(t.verifying);
        const result = await call(controller, "verify", { backend: verify.backend });
        shown =
          result.status === "authenticated"
            ? t.verified
            : (t.issues[text(result.issue) ?? ""] ?? t.verifyIncomplete);
        await settle();
      } else if (action === "cancel") {
        const current = await call(controller, "status");
        setStatus(current);
        const active = isObject(current.attempt) ? current.attempt : null;
        if (!active) {
          setFeedback("");
          return;
        }
        const result = await call(controller, "input_cancel", {
          attempt_id: active.attempt_id,
        });
        clearMaterial();
        offer.current = null;
        shown = result.save_result === "committed" ? t.cancelCommitted : t.canceled;
        setStatus(await call(controller, "status"));
        if (result.save_result !== "committed") await reportCompletion("canceled");
      } else {
        await reportCompletion("saved_unverified");
        shown = t.finishedSaved;
      }
      setFeedback(shown);
    } catch (error) {
      clearMaterial();
      offer.current = null;
      if (alive.current && operation.current === controller) {
        setFeedback(
          receipt?.save_result === "committed"
            ? t.savedIncomplete
            : submitted
              ? t.saveUnknown
              : (t.issues[codeOf(error)] ?? t.failed)
        );
      }
    } finally {
      plaintext?.fill(0);
      if (operation.current === controller) operation.current = null;
      if (alive.current) setBusy(false);
    }
  };

  const runRef = useRef(run);
  runRef.current = run;

  useEffect(() => {
    alive.current = true;
    void runRef.current("refresh");
    const dispose = () => {
      alive.current = false;
      operation.current?.abort();
      operation.current = null;
      offer.current = null;
    };
    window.addEventListener("pagehide", dispose);
    return () => {
      window.removeEventListener("pagehide", dispose);
      dispose();
    };
  }, []);

  // Another admin's attempt is said once the status arrives.
  useEffect(() => {
    if (attempt && attempt.owned !== true) setFeedback(t.otherAdmin);
  }, [attempt]);

  // A Claude sign-in carries its sealing offer in the ceremony.
  useEffect(() => {
    if (link?.claude && isOffer(isObject(ceremony) ? ceremony.input : null))
      offer.current = (ceremony as Json).input as RuntimeAuthOffer;
  }, [link?.claude, ceremony]);

  // The device code or sign-in link disappears when the attempt expires.
  useEffect(() => {
    if (!showCeremony || !attempt) return undefined;
    const expiresAt = typeof attempt.expires_at === "number" ? attempt.expires_at : 0;
    const timer = window.setTimeout(
      () => {
        setExpired(attemptId);
        setCallbackCode("");
        setFeedback(t.loginExpired);
      },
      Math.max(0, expiresAt - Date.now())
    );
    return () => window.clearTimeout(timer);
  }, [showCeremony, attempt, attemptId]);

  // One timer polls an active attempt; a new attempt starts the count over.
  useEffect(() => {
    if (!status) return undefined;
    const active = activeAttempt(attempt);
    if (active && pollAttempt.current !== attemptId) {
      pollAttempt.current = attemptId;
      polls.current = 0;
    } else if (!active) {
      pollAttempt.current = null;
      polls.current = 0;
    }
    const delay = runtimeAuthPollDelay(attempt, polls.current);
    if (delay === null) return undefined;
    const timer = window.setTimeout(() => {
      if (!alive.current || operation.current) return;
      polls.current += 1;
      void runRef.current("refresh");
    }, delay);
    return () => window.clearTimeout(timer);
  }, [status, attempt, attemptId]);

  const statusText = !status
    ? t.statusLoading
    : status.dispatch_ready
      ? t.statuses.verified
      : ((
          {
            configured: t.statuses.configured,
            pending: t.statuses.pending,
            unauthenticated: t.statuses.unauthenticated,
            authenticated: t.statuses.authenticated,
          } as Record<string, string>
        )[String(auth.status)] ?? t.statuses.unknown);
  const noImport = imports.length === 0;

  return (
    <section aria-label={t.nativeLogin} className="bft-auth-section">
      <p className="bft-auth-status" data-auth-status>
        {statusText}
      </p>
      {showCeremony && link ? (
        <div className="bft-auth-ceremony">
          <a
            className="bft-link"
            href={link.url}
            rel="noopener noreferrer"
            target="_blank"
          >
            {t.openLogin}
          </a>
          {link.claude ? (
            <>
              <InputField
                autoComplete="off"
                className="w-full"
                fieldSize="sm"
                label={t.callbackLabel}
                onChange={(event) => setCallbackCode(event.target.value)}
                spellCheck={false}
                type="password"
                value={callbackCode}
                wrapperClassName="bft-form-field"
              />
              <div>
                <Button
                  hierarchy="primary"
                  isDisabled={busy}
                  onPress={() => void run("complete-login")}
                  size="xs"
                >
                  {t.submitCode}
                </Button>
              </div>
            </>
          ) : (
            <>
              <p>
                {t.deviceCode}{" "}
                <code className="bft-mono">
                  {text(isObject(ceremony) ? ceremony.user_code : undefined)}
                </code>
              </p>
              <p className="bft-dialog-note">{t.loginHelp}</p>
            </>
          )}
        </div>
      ) : null}
      <Dropdown
        className="bft-form-field"
        disabled={noImport || busy}
        items={imports.map((item) => ({
          id: methodKey(item),
          label: t.methodOption(item.backend, item.form === "api_key"),
        }))}
        label={t.methodLabel}
        onChange={(next) => {
          // A secret entered for one method is never sent for another.
          clearMaterial();
          setMethod(next);
        }}
        size="sm"
        {...(method ? { value: methodKey(method) } : {})}
      />
      {method?.form === "api_key" || !method ? (
        <InputField
          autoComplete="off"
          className="w-full"
          disabled={noImport}
          fieldSize="sm"
          label={t.apiKey}
          onChange={(event) => setSecret(event.target.value)}
          spellCheck={false}
          type="password"
          value={secret}
          wrapperClassName="bft-form-field"
        />
      ) : (
        <label className="bft-file-field">
          <span>{t.authFile}</span>
          <input accept=".json,application/json" ref={fileRef} type="file" />
        </label>
      )}
      <Checkbox
        checked={canSaveVerify && saveVerify}
        disabled={!canSaveVerify}
        label={t.saveVerify}
        onChange={(event) => setSaveVerify(event.target.checked)}
      />
      <div className="bft-rail-actions">
        <Button
          hierarchy="secondary-gray"
          isDisabled={busy || !methods.some((item) => item.method === "native_login")}
          onPress={() => void run("login")}
          size="xs"
        >
          {t.nativeLogin}
        </Button>
        <Button
          hierarchy="primary"
          isDisabled={busy || noImport}
          onPress={() => void run("save")}
          size="xs"
        >
          {t.save}
        </Button>
        <Button
          hierarchy="secondary-gray"
          isDisabled={busy || !verifiable}
          onPress={() => void run("verify")}
          size="xs"
        >
          {t.verify}
        </Button>
        <Button
          hierarchy="secondary-gray"
          isDisabled={busy}
          onPress={() => void run("refresh")}
          size="xs"
        >
          {t.recheck}
        </Button>
        <Button
          hierarchy="secondary-gray"
          isDisabled={!busy && !activeAttempt(attempt)}
          onPress={() => void run("cancel")}
          size="xs"
        >
          {t.cancel}
        </Button>
        {pending && auth.status === "configured" ? (
          <Button
            hierarchy="secondary-gray"
            isDisabled={busy}
            onPress={() => void run("finish-saved")}
            size="xs"
          >
            {t.finishSaved}
          </Button>
        ) : null}
      </div>
      <p className="bft-dialog-note">{t.verifyNote}</p>
      <output aria-live="polite" className="bft-auth-feedback">
        {feedback}
      </output>
    </section>
  );
}
