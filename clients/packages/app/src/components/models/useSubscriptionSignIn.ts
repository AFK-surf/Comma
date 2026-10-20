import {
  useCall,
  type ModelProfile,
  type SubscriptionSignIn,
} from "@comma/core-client";
import { getNativeBridge } from "@comma/native-bridge";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../../nativePlatformActions";

/** Sources whose loopback callback the desktop app can receive itself. */
const nativeSources = new Set(["codex", "claude"]);

export type SignInState = {
  attempt: SubscriptionSignIn | undefined;
  /** The desktop app is waiting for the browser to return to it. */
  native: boolean;
  busy: boolean;
  error: unknown;
  code: string;
};

/**
 * Signs a subscription in through OAuth. In the desktop app the browser
 * returns Codex and Claude to the core's loopback listener
 * (`models.signIn.loopback`, which waits for it); elsewhere the core starts
 * the sign-in: a device code, which the core waits on, or a callback code the
 * reader pastes back. `onComplete` receives the new account when the
 * backend returns it; the core has read the profiles again by then.
 */
export function useSubscriptionSignIn(
  workspace: string | undefined,
  onComplete: (account: ModelProfile | undefined) => void | Promise<void>
) {
  const call = useCall();
  const [attempt, setAttempt] = useState<SubscriptionSignIn>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>();
  const [code, setCode] = useState("");
  const generation = useRef(0);
  /** The desktop sign-in under way: aborting it cancels the core's call (its listener closes). */
  const nativeRequest = useRef<AbortController | undefined>(undefined);
  const completed = useRef(onComplete);
  completed.current = onComplete;

  const cancelNative = useCallback(() => {
    nativeRequest.current?.abort();
    nativeRequest.current = undefined;
  }, []);

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
    async (current: number, account: ModelProfile | undefined) => {
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
   * Starts a sign-in. `device`: the plan signs in with a device code, shown
   * here first. `reconnect` names the account it renews, so a fresh sign-in
   * replaces that account's credential instead of adding another.
   */
  const begin = useCallback(
    (
      source: string,
      options: { device: boolean; reconnect?: { account_id: string; version: string } }
    ) => {
      if (!workspace || busy) return;
      const { device, reconnect } = options;
      const current = ++generation.current;
      setBusy(true);
      setError(undefined);
      const started = () =>
        call("models.signIn.begin", {
          workspace,
          provider: source,
          ...(reconnect
            ? { account: reconnect.account_id, version: reconnect.version }
            : {}),
        });
      void (async () => {
        const bridge = getNativeBridge();
        if (bridge.platform === "electron" && nativeSources.has(source)) {
          const controller = new AbortController();
          nativeRequest.current = controller;
          setAttempt({ id: "loopback", url: "", mode: "callback", expires_at: "" });
          setBusy(false);
          const account = await call(
            "models.signIn.loopback",
            {
              workspace,
              provider: source as "codex" | "claude",
              ...(reconnect
                ? { account: reconnect.account_id, version: reconnect.version }
                : {}),
            },
            controller.signal
          );
          if (current === generation.current) await finish(current, account);
        } else if (device) {
          // A device code is shown first; the reader opens the page with it.
          const result = await started();
          if (current === generation.current) setAttempt(result);
        } else {
          await openNativePlatformExternalUrlFromUserAction(async () => {
            const result = await started();
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
    [busy, call, fail, finish, workspace]
  );

  // A device code finishes on its own: the core asks about it until it does.
  useEffect(() => {
    if (!attempt || !workspace || attempt.mode !== "device") return;
    const current = generation.current;
    const controller = new AbortController();
    call(
      "models.signIn.wait",
      { workspace, attempt: attempt.id },
      controller.signal
    ).then(
      (account) => finish(current, account),
      (reason: unknown) => {
        if (!controller.signal.aborted) fail(current, reason);
      }
    );
    return () => controller.abort();
  }, [attempt, call, fail, finish, workspace]);

  /** Finishes a callback sign-in with the pasted code, or `pasted` when given. */
  const complete = useCallback(
    (pasted?: string) => {
      const value = pasted ?? code;
      if (!workspace || !attempt || !value.trim() || busy) return;
      const current = generation.current;
      setBusy(true);
      call("models.signIn.complete", { workspace, attempt: attempt.id, code: value })
        .then((account) => finish(current, account))
        .catch((reason: unknown) => fail(current, reason))
        .finally(() => {
          if (current === generation.current) setBusy(false);
        });
    },
    [attempt, busy, call, code, fail, finish, workspace]
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
