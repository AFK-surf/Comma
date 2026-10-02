import { getNativeBridge } from "@comma/native-bridge";
import { useCallback, useContext, useEffect, useRef, useState } from "react";
import type { CommaApiClient } from "../../api";
import type {
  SubscriptionAccount,
  SubscriptionOAuth,
} from "../../api/subscriptionAccounts";
import {
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../../runtime-chat/nativePlatformActions";
import { CommaAuthContext } from "../auth-context";

/** Sources that sign in on the web with a device code. */
const deviceSources = new Set(["codex", "grok", "kimi-code", "github-copilot"]);

/** Sources whose loopback callback the desktop app can receive itself. */
const nativeSources = new Set(["codex", "claude"]);

export type SignInState = {
  attempt: SubscriptionOAuth | undefined;
  /** The desktop app is waiting for the browser to return to it. */
  native: boolean;
  busy: boolean;
  error: unknown;
  code: string;
};

/**
 * Signs a subscription in through OAuth. The desktop app receives the
 * callback for Codex and Claude itself; elsewhere the backend chooses a device
 * code, which is polled, or a callback code the reader pastes back.
 * `onComplete` receives the new account when the backend returns it.
 */
export function useSubscriptionSignIn(
  api: CommaApiClient,
  workspace: string | undefined,
  onComplete: (account: SubscriptionAccount | undefined) => void | Promise<void>
) {
  const productLease = useContext(CommaAuthContext)?.productLease;
  const [attempt, setAttempt] = useState<SubscriptionOAuth>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>();
  const [code, setCode] = useState("");
  const generation = useRef(0);
  const nativeRequest = useRef<string | undefined>(undefined);
  const completed = useRef(onComplete);
  completed.current = onComplete;

  const cancelNative = useCallback(() => {
    if (nativeRequest.current && productLease) {
      void getNativeBridge()
        .subscriptionAuthorization.cancel({
          session: productLease,
          requestId: nativeRequest.current,
        })
        .catch(() => undefined);
    }
    nativeRequest.current = undefined;
  }, [productLease]);

  const reset = useCallback(() => {
    generation.current += 1;
    cancelNative();
    setAttempt(undefined);
    setBusy(false);
    setError(undefined);
    setCode("");
  }, [cancelNative]);

  useEffect(() => reset, [reset, workspace]);

  const finish = useCallback(
    async (current: number, account: SubscriptionAccount | undefined) => {
      if (current !== generation.current) return;
      nativeRequest.current = undefined;
      setAttempt(undefined);
      setCode("");
      await completed.current(account);
    },
    []
  );

  const fail = useCallback(
    (current: number, reason: unknown) => {
      if (current !== generation.current) return;
      cancelNative();
      setAttempt(undefined);
      setError(reason);
    },
    [cancelNative]
  );

  /**
   * Starts a sign-in. `reconnect` names the account it renews, so a fresh
   * sign-in replaces that account's credential instead of adding another.
   */
  const begin = useCallback(
    (source: string, reconnect?: { account_id: string; version: string }) => {
      if (!workspace || busy) return;
      const current = ++generation.current;
      setBusy(true);
      setError(undefined);
      void (async () => {
        const bridge = getNativeBridge();
        if (bridge.platform === "electron" && nativeSources.has(source)) {
          if (!productLease) throw new Error("authorization_unavailable");
          const requestId = crypto.randomUUID();
          nativeRequest.current = requestId;
          const result = await bridge.subscriptionAuthorization.start({
            session: productLease,
            requestId,
            workspaceId: workspace,
            provider: source as "codex" | "claude",
            ...(reconnect
              ? { accountId: reconnect.account_id, version: reconnect.version }
              : {}),
          });
          if (current !== generation.current) return;
          if (result.status === "failed") throw new Error(result.error);
          if (result.status === "complete") {
            await finish(current, undefined);
            return;
          }
          setAttempt({
            id: requestId,
            url: "",
            mode: "callback",
            expires_at: new Date(Date.now() + 900_000).toISOString(),
          });
        } else if (deviceSources.has(source)) {
          // A device code is shown first; the reader opens the page with it.
          const result = await api.beginSubscriptionOAuth(workspace, {
            provider: source,
            mode: "device",
            ...reconnect,
          });
          if (current === generation.current) setAttempt(result);
        } else {
          await openNativePlatformExternalUrlFromUserAction(async () => {
            const result = await api.beginSubscriptionOAuth(workspace, {
              provider: source,
              ...reconnect,
            });
            if (current !== generation.current)
              throw new Error("Authorization cancelled");
            setAttempt(result);
            return result.url;
          });
        }
      })()
        .catch((reason: unknown) => fail(current, reason))
        .finally(() => {
          if (current === generation.current) setBusy(false);
        });
    },
    [api, busy, fail, finish, productLease, workspace]
  );

  // Device codes and the desktop callback finish on their own; poll them.
  useEffect(() => {
    if (!attempt || !workspace) return;
    const native = nativeRequest.current;
    if (attempt.mode !== "device" && !native) return;
    const current = generation.current;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      try {
        if (Date.now() >= Date.parse(attempt.expires_at))
          throw new Error("authorization_expired");
        if (native) {
          if (!productLease) throw new Error("authorization_unavailable");
          const result = await getNativeBridge().subscriptionAuthorization.status({
            session: productLease,
            requestId: native,
          });
          if (stopped) return;
          if (result.status === "pending") timer = setTimeout(poll, 1000);
          else if (result.status === "complete") await finish(current, undefined);
          else throw new Error(result.error ?? "authorization_failed");
          return;
        }
        const result = await api.pollSubscriptionOAuth(workspace, attempt.id);
        if (stopped) return;
        if ("id" in result) await finish(current, result);
        else timer = setTimeout(poll, result.interval * 1000);
      } catch (reason) {
        if (!stopped) fail(current, reason);
      }
    };
    timer = setTimeout(poll, native ? 1000 : (attempt.interval ?? 5) * 1000);
    return () => {
      stopped = true;
      clearTimeout(timer);
    };
  }, [api, attempt, fail, finish, productLease, workspace]);

  /** Finishes a callback sign-in with the pasted code, or `pasted` when given. */
  const complete = useCallback(
    (pasted?: string) => {
      const value = pasted ?? code;
      if (!workspace || !attempt || !value.trim() || busy) return;
      const current = generation.current;
      setBusy(true);
      void api
        .completeSubscriptionOAuth(workspace, attempt.id, value)
        .then((account) => finish(current, account))
        .catch((reason: unknown) => fail(current, reason))
        .finally(() => {
          if (current === generation.current) setBusy(false);
        });
    },
    [api, attempt, busy, code, fail, finish, workspace]
  );

  const openAuthorization = useCallback(() => {
    if (attempt?.url) void openNativePlatformExternalUrl(attempt.url);
  }, [attempt]);

  const state: SignInState = {
    attempt,
    native: !!attempt && !!nativeRequest.current,
    busy,
    error,
    code,
  };
  return { state, begin, complete, reset, setCode, openAuthorization };
}
