import {
  useCall,
  useTopic,
  type PluginFailureReason,
  type PluginInstallOrigin,
  type PluginNotice,
} from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { toast } from "@comma/ui/components/toast";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { openNativePlatformExternalUrl } from "../../nativePlatformActions";
import { PluginCredentialsDialog } from "./PluginCredentialsDialog";

export type { PluginInstallOrigin };

type Target = { pluginId: string; workspaceId: string; origin?: PluginInstallOrigin };

/**
 * Installs, reconnects and stops plugins through the client core, which owns
 * each one from the request to the browser authorization it may need: it goes
 * on whichever window started it closes. A window opens the authorization page
 * the core answers with.
 */
export function usePluginInstall() {
  const call = useCall();
  const open = useCallback(
    async (answer: { authorizationUrl?: string } | undefined) => {
      if (answer?.authorizationUrl)
        await openNativePlatformExternalUrl(answer.authorizationUrl);
    },
    []
  );
  return useMemo(
    () => ({
      install: ({ pluginId, workspaceId, origin }: Target) =>
        call("plugin.install", {
          plugin: pluginId,
          workspace: workspaceId,
          ...(origin ? { origin } : {}),
        })
          .then(open)
          // A failure is said by the core's notices (PluginNotices); a cancel says nothing.
          .catch(() => undefined),
      reauthorize: ({
        pluginId,
        workspaceId,
        connectionId,
      }: Target & { connectionId: string }) =>
        call("plugin.reauthorize", {
          connection: connectionId,
          plugin: pluginId,
          workspace: workspaceId,
        })
          .then(open)
          .catch(() => undefined),
      cancel: ({ pluginId, workspaceId }: Target) =>
        void call("plugin.cancel", { plugin: pluginId, workspace: workspaceId }).catch(
          () => undefined
        ),
    }),
    [call, open]
  );
}

type Messages = ReturnType<typeof useCommaMessages>;

/** Why an install or reconnect failed, in the reader's words. */
function reasonDescription(
  reason: PluginFailureReason | undefined,
  messages: Messages
) {
  switch (reason) {
    case "busy":
      return messages.plugins_error_busy();
    case "not_configured":
      return messages.plugins_error_not_configured();
    case "forbidden":
      return messages.plugins_error_forbidden();
    case "not_found":
      return messages.plugins_error_not_found();
    case "unavailable":
      return messages.plugins_error_unavailable();
    case "credential_rejected":
      return messages.plugins_credentials_rejected();
    default:
      return messages.plugins_error_generic();
  }
}

function sayNotice(notice: PluginNotice, messages: Messages) {
  const app = notice.origin === "onboarding";
  switch (notice.kind) {
    case "configure":
      return;
    case "authorize":
      if (notice.url) void openNativePlatformExternalUrl(notice.url);
      return;
    case "not_personal":
      toast.error(messages.plugins_personal_source_not_personal());
      return;
    case "install_timed_out":
      toast.error(
        app
          ? messages.plugins_install_request_timed_out_app()
          : messages.plugins_install_request_timed_out()
      );
      return;
    case "authorization_timed_out":
      toast.error(
        app
          ? messages.plugins_install_authorization_timed_out_app()
          : messages.plugins_install_authorization_timed_out()
      );
      return;
    case "install_failed":
      toast.error(
        app ? messages.plugins_install_failed_app() : messages.plugins_install_failed(),
        {
          description: reasonDescription(notice.reason, messages),
        }
      );
      return;
    case "reauthorize_failed":
      toast.error(messages.plugins_reauthorize_failed(), {
        description: reasonDescription(notice.reason, messages),
      });
      return;
    case "uninstall_failed":
      toast.error(
        messages.plugins_uninstall_failed(),
        notice.message ? { description: notice.message } : {}
      );
  }
}

/**
 * Says what went wrong with an install the person started, once: the window
 * that claims the core's notice says it (or opens the authorization page its
 * next step needs). A window that gets the focus back
 * from the browser has the core check an authorization under way at once.
 * Mount it once per window that has a toast stack.
 */
export function PluginNotices() {
  const messages = useCommaMessages();
  const call = useCall();
  const { value } = useTopic({ topic: "pluginNotices" });
  const { value: session } = useTopic({ topic: "session" });
  const sessionId = session?.phase === "signed_in" ? session.sessionId : undefined;
  const sessionRef = useRef(sessionId);
  sessionRef.current = sessionId;
  type Credentials = NonNullable<PluginNotice["configuration"]> & {
    id: number;
    sessionId: string;
    pending: boolean;
    error?: string;
  };
  const [credentials, setCredentials] = useState<Credentials>();
  const active = useRef<Credentials | undefined>(undefined);
  const showCredentials = useCallback((next: Credentials | undefined) => {
    active.current = next;
    setCredentials(next);
  }, []);
  const claimed = useRef(new Set<number>());

  useEffect(() => {
    if (active.current?.sessionId !== sessionId) showCredentials(undefined);
    return () => {
      active.current = undefined;
    };
  }, [sessionId, showCredentials]);

  useEffect(() => {
    if (!sessionId) return;
    for (const notice of value?.notices ?? []) {
      if (claimed.current.has(notice.id)) continue;
      claimed.current.add(notice.id);
      void call("plugin.notice.claim", { id: notice.id })
        .then((mine) => {
          if (!mine || sessionRef.current !== sessionId) return;
          if (notice.kind === "configure" && notice.configuration && sessionId) {
            showCredentials({
              ...notice.configuration,
              id: notice.id,
              sessionId,
              pending: false,
            });
          } else {
            sayNotice(notice, messages);
          }
        })
        .catch(() => undefined);
    }
  }, [call, messages, value, sessionId, showCredentials]);

  useEffect(() => {
    const check = () =>
      void call("plugin.authorization.check", {}).catch(() => undefined);
    window.addEventListener("focus", check);
    return () => window.removeEventListener("focus", check);
  }, [call]);

  if (!credentials || credentials.sessionId !== sessionId) return null;

  return (
    <PluginCredentialsDialog
      key={credentials.id}
      plugin={credentials.plugin}
      configuration={credentials.setup}
      pending={credentials.pending}
      {...(credentials.error ? { error: credentials.error } : {})}
      onClose={() => showCredentials(undefined)}
      onSubmit={(configValues) => {
        if (
          active.current !== credentials ||
          sessionRef.current !== credentials.sessionId
        )
          return;
        showCredentials({ ...credentials, pending: true });
        void call("plugin.install", {
          workspace: credentials.workspace,
          plugin: credentials.plugin.id,
          configValues,
        })
          .then((answer) => {
            if (
              active.current?.id !== credentials.id ||
              sessionRef.current !== credentials.sessionId
            )
              return;
            if (answer.failure)
              showCredentials({
                ...credentials,
                pending: false,
                error: reasonDescription(answer.failure, messages),
              });
            else showCredentials(undefined);
          })
          .catch(() => {
            if (
              active.current?.id === credentials.id &&
              sessionRef.current === credentials.sessionId
            )
              showCredentials({
                ...credentials,
                pending: false,
                error: messages.plugins_error_generic(),
              });
          });
      }}
    />
  );
}
