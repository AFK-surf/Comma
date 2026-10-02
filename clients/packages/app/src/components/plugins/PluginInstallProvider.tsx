import { useCommaMessages } from "@comma/i18n/react";
import { toast } from "@comma/ui";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { CommaApiError, type CommaApiClient, type CommaPlugin } from "../../api";
import { openNativePlatformExternalUrl } from "../../runtime-chat/nativePlatformActions";

const requestTimeoutMs = 30_000;
const authorizationTimeoutMs = 120_000;

/**
 * Where the install was started: the Plugins page, or the onboarding, which
 * calls a plugin an app and has no Plugins page to return to.
 */
export type PluginInstallOrigin = "plugins" | "onboarding";
type Target = {
  pluginId: string;
  workspaceId: string;
  connectionId?: string;
  origin?: PluginInstallOrigin;
};
type Operation = "install" | "reauthorize";
type Continuation = Target & {
  authorizationState: string;
  expiresAt: number;
  operation: Operation;
};
type Request = Target & { controller: AbortController };
/**
 * An install the user is authorizing in the browser. The install happens only
 * when a window verifies it, so a window that closes hands it to another.
 */
export type PluginAuthorization = {
  workspaceId: string;
  pluginId: string;
  authorizationState: string;
  /** Epoch milliseconds. */
  expiresAt: number;
};
type InstallContext = {
  cancel(target: Target): void;
  install(target: Target): Promise<void>;
  reauthorize(target: Target & { connectionId: string }): Promise<void>;
  /** The install this window is waiting to verify, if any. */
  authorization: PluginAuthorization | undefined;
  /** Takes over verifying an install another window started. */
  resume(authorization: PluginAuthorization, origin?: PluginInstallOrigin): void;
  pending: Target | undefined;
  result: (Target & { plugin: CommaPlugin }) | undefined;
  completionVersion: number;
};

const PluginInstallContext = createContext<InstallContext | undefined>(undefined);

class InstallTimeoutError extends Error {}

/** One authorization per signed-in window, independent of the current route. */
export function PluginInstallProvider({
  api,
  children,
  sessionSignal,
}: {
  api: CommaApiClient;
  children: ReactNode;
  sessionSignal?: AbortSignal;
}) {
  const messages = useCommaMessages();
  const requestRef = useRef<Request | undefined>(undefined);
  const continuationRef = useRef<Continuation | undefined>(undefined);
  const [continuation, setContinuation] = useState<Continuation>();
  const [pending, setPending] = useState<Target>();
  const [result, setResult] = useState<InstallContext["result"]>();
  const [completionVersion, setCompletionVersion] = useState(0);

  const reset = useCallback(() => {
    requestRef.current?.controller.abort();
    requestRef.current = undefined;
    continuationRef.current = undefined;
    setContinuation(undefined);
    setPending(undefined);
    setResult(undefined);
  }, []);

  useEffect(() => {
    sessionSignal?.addEventListener("abort", reset, { once: true });
    return () => {
      sessionSignal?.removeEventListener("abort", reset);
      reset();
    };
  }, [api, reset, sessionSignal]);

  const perform = useCallback(
    async (
      target: Target,
      previous?: Continuation,
      operation: Operation = "install"
    ) => {
      if (sessionSignal?.aborted || requestRef.current) return;
      if (previous && continuationRef.current !== previous) return;
      const controller = new AbortController();
      const request = { ...target, controller };
      requestRef.current = request;
      setPending(target);
      const remainingMs = previous
        ? Math.min(requestTimeoutMs, previous.expiresAt - Date.now())
        : requestTimeoutMs;
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        // Race as well as abort: a transport that settles late must neither hold
        // Add indefinitely nor replace a newer attempt's result.
        const response = await Promise.race([
          operation === "reauthorize"
            ? api.reauthorizeWorkspacePlugin(target.workspaceId, target.pluginId, {
                ...(target.connectionId ? { connectionId: target.connectionId } : {}),
                signal: controller.signal,
                ...(previous
                  ? {
                      authorizationState: previous.authorizationState,
                      verifyOnly: true,
                    }
                  : {}),
              })
            : api.installWorkspacePlugin(target.workspaceId, target.pluginId, {
                signal: controller.signal,
                ...(previous
                  ? {
                      authorizationState: previous.authorizationState,
                      verifyOnly: true,
                    }
                  : {}),
              }),
          new Promise<never>((_resolve, reject) => {
            timer = setTimeout(
              () => {
                reject(new InstallTimeoutError());
                controller.abort();
              },
              Math.max(0, remainingMs)
            );
          }),
        ]);
        if (
          requestRef.current !== request ||
          controller.signal.aborted ||
          sessionSignal?.aborted ||
          (previous && Date.now() >= previous.expiresAt)
        )
          return;

        setResult({ ...target, plugin: response.plugin });
        if (response.authorization) {
          const authorization = response.authorization;
          const sameAttempt = authorization.state === previous?.authorizationState;
          const next = {
            ...target,
            operation,
            authorizationState: authorization.state,
            expiresAt: sameAttempt
              ? previous.expiresAt
              : Date.now() + authorizationTimeoutMs,
          };
          continuationRef.current = next;
          setContinuation(next);
          if (!sameAttempt && authorization.authorizationUrl) {
            await openNativePlatformExternalUrl(authorization.authorizationUrl);
          }
        } else {
          continuationRef.current = undefined;
          setContinuation(undefined);
          // The owner stays where they added the connection, usually Plugins
          // opened from Routine settings, and sees it installed there.
          if (operation === "reauthorize")
            setCompletionVersion((version) => version + 1);
        }
      } catch (error) {
        if (requestRef.current !== request || sessionSignal?.aborted) return;
        if (
          error instanceof CommaApiError &&
          error.body?.error === "member_account_not_personal"
        ) {
          reset();
          toast.error(messages.plugins_personal_source_not_personal());
          return;
        }
        // A failed read does not cancel the provider's authorization. The same
        // attempt remains eligible for the next check until its absolute deadline.
        if (previous) return;
        const app = target.origin === "onboarding";
        if (error instanceof InstallTimeoutError) {
          toast.error(
            app
              ? messages.plugins_install_request_timed_out_app()
              : messages.plugins_install_request_timed_out()
          );
          return;
        }
        toast.error(
          operation === "reauthorize"
            ? messages.plugins_reauthorize_failed()
            : app
              ? messages.plugins_install_failed_app()
              : messages.plugins_install_failed(),
          { description: installErrorDescription(error, messages) }
        );
      } finally {
        clearTimeout(timer);
        if (requestRef.current === request) {
          requestRef.current = undefined;
          setPending(undefined);
        }
      }
    },
    [api, messages, reset, sessionSignal]
  );

  const install = useCallback(
    async (target: Target) => {
      if (
        requestRef.current?.pluginId === target.pluginId &&
        requestRef.current.workspaceId === target.workspaceId
      )
        return;
      reset();
      setResult(undefined);
      await perform(target);
    },
    [perform, reset]
  );

  const reauthorize = useCallback(
    async (target: Target & { connectionId: string }) => {
      reset();
      setResult(undefined);
      await perform(target, undefined, "reauthorize");
    },
    [perform, reset]
  );

  const cancel = useCallback(
    (target: Target) => {
      const active = requestRef.current ?? continuationRef.current;
      if (
        active?.workspaceId === target.workspaceId &&
        active.pluginId === target.pluginId
      ) {
        const activeContinuation = continuationRef.current;
        if (activeContinuation?.operation === "reauthorize") {
          void api
            .cancelPluginOperation(
              target.workspaceId,
              target.pluginId,
              activeContinuation.authorizationState
            )
            .catch(() => undefined);
        }
        reset();
      }
      setResult((current) =>
        current?.workspaceId === target.workspaceId &&
        current.pluginId === target.pluginId
          ? undefined
          : current
      );
    },
    [api, reset]
  );

  const resume = useCallback(
    (
      { authorizationState, expiresAt, pluginId, workspaceId }: PluginAuthorization,
      origin?: PluginInstallOrigin
    ) => {
      if (Date.now() >= expiresAt) return;
      reset();
      const next: Continuation = {
        authorizationState,
        expiresAt,
        operation: "install",
        pluginId,
        workspaceId,
        ...(origin ? { origin } : {}),
      };
      continuationRef.current = next;
      setContinuation(next);
    },
    [reset]
  );

  useEffect(() => {
    if (!continuation) return;
    const timer = setTimeout(
      () => {
        if (continuationRef.current !== continuation) return;
        reset();
        toast.error(
          continuation.origin === "onboarding"
            ? messages.plugins_install_authorization_timed_out_app()
            : messages.plugins_install_authorization_timed_out()
        );
      },
      Math.max(0, continuation.expiresAt - Date.now())
    );
    return () => clearTimeout(timer);
  }, [continuation, messages, reset]);

  useEffect(() => {
    if (!continuation) return;
    const verify = () => {
      if (Date.now() < continuation.expiresAt)
        void perform(continuation, continuation, continuation.operation);
    };
    // At most one request per signed-in window; a two-second interval and a
    // two-minute deadline allow at most 60 scheduled checks, with no child scan.
    const timer = setTimeout(verify, 2_000);
    window.addEventListener("focus", verify);
    return () => {
      clearTimeout(timer);
      window.removeEventListener("focus", verify);
    };
  }, [continuation, pending, perform]);

  const authorization: PluginAuthorization | undefined =
    continuation?.operation === "install"
      ? {
          authorizationState: continuation.authorizationState,
          expiresAt: continuation.expiresAt,
          pluginId: continuation.pluginId,
          workspaceId: continuation.workspaceId,
        }
      : undefined;

  return (
    <PluginInstallContext.Provider
      value={{
        authorization,
        cancel,
        completionVersion,
        install,
        pending,
        reauthorize,
        result,
        resume,
      }}
    >
      {children}
    </PluginInstallContext.Provider>
  );
}

type Messages = ReturnType<typeof useCommaMessages>;

/**
 * Why an install or reconnect failed, in the reader's words. The server's
 * error is a machine code (`upstream_unavailable`) or an untranslated
 * sentence, so it is never shown; a code or status with no wording of its
 * own reads as a general failure.
 */
function installErrorDescription(error: unknown, messages: Messages) {
  if (!(error instanceof CommaApiError)) return messages.plugins_error_generic();
  const code = error.body?.error;
  switch (code) {
    case "authorization_callback_in_progress":
    case "stale_plugin_operation":
      return messages.plugins_error_busy();
    case "missing_oauth_client":
    case "not_configured":
      return messages.plugins_error_not_configured();
    case "forbidden":
      return messages.plugins_error_forbidden();
    case "not_found":
      return messages.plugins_error_not_found();
  }
  if (code?.endsWith("_unavailable")) return messages.plugins_error_unavailable();
  switch (error.status) {
    case 403:
      return messages.plugins_error_forbidden();
    case 404:
      return messages.plugins_error_not_found();
    case 409:
      return messages.plugins_error_busy();
    case 412:
      return messages.plugins_error_not_configured();
    case 502:
    case 503:
    case 504:
      return messages.plugins_error_unavailable();
    default:
      return messages.plugins_error_generic();
  }
}

export function usePluginInstall() {
  const context = useContext(PluginInstallContext);
  if (!context) throw new Error("PluginsRoute requires PluginInstallProvider");
  return context;
}
