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

type Target = { pluginId: string; workspaceId: string; connectionId?: string };
type Operation = "install" | "reauthorize";
type Continuation = Target & {
  authorizationState: string;
  expiresAt: number;
  operation: Operation;
};
type Request = Target & { controller: AbortController };
type InstallContext = {
  cancel(target: Target): void;
  install(target: Target): Promise<void>;
  reauthorize(target: Target & { connectionId: string }): Promise<void>;
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
        toast.error(
          error instanceof InstallTimeoutError
            ? messages.plugins_install_request_timed_out()
            : operation === "reauthorize"
              ? messages.plugins_reauthorize_failed()
              : messages.plugins_install_failed(),
          error instanceof Error && error.message ? { description: error.message } : {}
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

  useEffect(() => {
    if (!continuation) return;
    const timer = setTimeout(
      () => {
        if (continuationRef.current !== continuation) return;
        reset();
        toast.error(messages.plugins_install_authorization_timed_out());
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

  return (
    <PluginInstallContext.Provider
      value={{ cancel, install, reauthorize, pending, result, completionVersion }}
    >
      {children}
    </PluginInstallContext.Provider>
  );
}

export function usePluginInstall() {
  const context = useContext(PluginInstallContext);
  if (!context) throw new Error("PluginsRoute requires PluginInstallProvider");
  return context;
}
