import { baseLocale, messages as commaMessages, type CommaLocale } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  CommaApiError,
  type CommaApiClient,
  type CommaConversation,
  type CommaWorkspace,
} from "../../api";
import { writeActiveWorkspaceId } from "../activeWorkspace";
import { useChatRegistry } from "./ChatProvider";
import { traceCommaNav } from "../../devtools/commaNavTrace";

export type WorkspaceChatResolution =
  | {
      status: "ready";
      groupId: string;
      workspaceId: string;
      conversation: CommaConversation;
    }
  | {
      status: "provisioning";
      groupId: string;
      workspaceId: string;
      retryAfterSeconds: number;
    }
  | {
      status: "hidden";
    }
  | {
      status: "unauthorized";
    };

const MAX_AUTOMATIC_BOOTSTRAP_RETRIES = 3;
const MAX_AUTOMATIC_BOOTSTRAP_DELAY_SECONDS = 10;

export type WorkspaceChatState =
  | WorkspaceChatResolution
  | {
      status: "loading";
    }
  | {
      status: "error";
      message: string;
    };

export function useWorkspaceChat({
  activateWorkspace = true,
  api,
  nativeDefault = false,
  routeWorkspaceId,
}: {
  // A ready resolution normally makes the resolved Workspace the shell-wide
  // active one (`writeActiveWorkspaceId`), which rescopes every route that
  // subscribes to the active Workspace. Pass false for background resolution
  // that must not change what the user is looking at — e.g. the route-
  // independent Home conversation target bootstrap.
  activateWorkspace?: boolean | undefined;
  api: CommaApiClient;
  nativeDefault?: boolean | undefined;
  routeWorkspaceId?: string | undefined;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const { productLease } = useChatRegistry();
  const [state, setState] = useState<WorkspaceChatState>({ status: "loading" });
  const [revision, setRevision] = useState(0);
  const automaticBootstrapRetries = useRef(0);
  const exactWorkspace = !nativeDefault && Boolean(routeWorkspaceId);
  const requestedWorkspaceId = nativeDefault ? undefined : routeWorkspaceId;
  const defaultTitle = messages.chat_default_title();
  const unavailableMessage = messages.chat_unavailable();

  useEffect(() => {
    automaticBootstrapRetries.current = 0;
  }, [api, exactWorkspace, requestedWorkspaceId]);

  useEffect(() => {
    let active = true;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    const controller = new AbortController();
    setState({ status: "loading" });
    const startedAt = performance.now();
    traceCommaNav("workspace-chat-resolve-start", {
      exactWorkspace,
      generation: productLease.generation,
      requestedWorkspaceId,
    });

    void resolveWorkspaceChat({
      api,
      defaultTitle,
      exactWorkspace,
      locale,
      session: productLease,
      signal: controller.signal,
      workspaceId: requestedWorkspaceId,
    })
      .then((resolution) => {
        if (!active) return;
        if (resolution.status === "ready" && activateWorkspace) {
          writeActiveWorkspaceId(resolution.workspaceId);
        }
        setState(resolution);
        traceCommaNav("workspace-chat-resolve-end", {
          ms: Math.round(performance.now() - startedAt),
          status: resolution.status,
        });
        if (
          resolution.status === "provisioning" &&
          automaticBootstrapRetries.current < MAX_AUTOMATIC_BOOTSTRAP_RETRIES
        ) {
          automaticBootstrapRetries.current += 1;
          const delaySeconds = Math.min(
            Math.max(resolution.retryAfterSeconds, 1),
            MAX_AUTOMATIC_BOOTSTRAP_DELAY_SECONDS
          );
          retryTimer = setTimeout(
            () => setRevision((current) => current + 1),
            delaySeconds * 1_000
          );
        }
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setState({
          status: "error",
          // Provider and server failures may contain request internals or
          // untrusted upstream prose. Never copy that text into product state.
          message: unavailableMessage,
        });
        traceCommaNav("workspace-chat-resolve-end", {
          ms: Math.round(performance.now() - startedAt),
          status: "error",
        });
      });

    return () => {
      active = false;
      controller.abort();
      if (retryTimer) clearTimeout(retryTimer);
    };
  }, [
    activateWorkspace,
    api,
    defaultTitle,
    exactWorkspace,
    locale,
    nativeDefault,
    productLease,
    requestedWorkspaceId,
    revision,
    unavailableMessage,
  ]);

  const retry = useCallback(() => {
    automaticBootstrapRetries.current = 0;
    setRevision((current) => current + 1);
  }, []);

  return { retry, state };
}

export async function resolveWorkspaceChat({
  api,
  locale = baseLocale,
  defaultTitle = commaMessages.chat_default_title({}, { locale }),
  exactWorkspace = false,
  session,
  signal,
  workspaceId,
}: {
  api: CommaApiClient;
  defaultTitle?: string;
  exactWorkspace?: boolean | undefined;
  locale?: CommaLocale;
  session?: SessionProductLease | undefined;
  signal?: AbortSignal;
  workspaceId?: string | undefined;
}): Promise<WorkspaceChatResolution> {
  const bridge = getNativeBridge();

  if (
    (bridge.platform === "electron" || bridge.runtimeHost === "shared-worker") &&
    !workspaceId
  ) {
    if (!session) {
      throw new Error(
        "Native Workspace Chat resolution requires the active Session product lease."
      );
    }
    const resolution = await abortable(
      bridge.chat.resolveWorkspaceChat({ session }),
      signal
    );
    if (resolution.status === "unauthorized") return resolution;
    if (resolution.status === "hidden") return resolution;
    if (resolution.status === "provisioning") {
      return {
        groupId: resolution.groupId,
        retryAfterSeconds: resolution.retryAfterSeconds,
        status: "provisioning",
        workspaceId: resolution.workspaceId,
      };
    }
    return {
      conversation: {
        ...(resolution.createdAt === undefined
          ? {}
          : { created_at: resolution.createdAt }),
        group_id: resolution.groupId,
        id: resolution.conversationId,
        kind: "user_chat",
        messages: [],
        status: "open",
        title: defaultTitle,
        ...(resolution.updatedAt === undefined
          ? {}
          : { updated_at: resolution.updatedAt }),
      },
      groupId: resolution.groupId,
      status: "ready",
      workspaceId: resolution.workspaceId,
    };
  }

  try {
    let workspace: CommaWorkspace | undefined;

    if (exactWorkspace) {
      const workspaces = signal
        ? await api.listWorkspaces({ signal })
        : await api.listWorkspaces();
      workspace = workspaces.find((candidate) => candidate.id === workspaceId);
    } else {
      const bootstrap = signal
        ? await api.bootstrapWorkspace({ signal })
        : await api.bootstrapWorkspace();
      if (bootstrap.status === "provisioning") {
        return {
          groupId: bootstrap.workspace.group_id,
          retryAfterSeconds: bootstrap.retry_after_seconds,
          status: "provisioning",
          workspaceId: bootstrap.workspace.id,
        };
      }
      workspace = bootstrap.workspace;
    }

    if (!workspace) return { status: "hidden" };

    const conversation = signal
      ? await api.ensureGroupChat(workspace.group_id, { signal })
      : await api.ensureGroupChat(workspace.group_id);
    return {
      conversation,
      groupId: workspace.group_id,
      status: "ready",
      workspaceId: workspace.id,
    };
  } catch (error) {
    if (error instanceof CommaApiError && error.status === 401) {
      return { status: "unauthorized" };
    }
    if (
      error instanceof CommaApiError &&
      (error.status === 403 || error.status === 404)
    ) {
      return { status: "hidden" };
    }
    throw error;
  }
}

function abortable<T>(promise: Promise<T>, signal: AbortSignal | undefined) {
  if (!signal) return promise;
  if (signal.aborted) return Promise.reject(abortError());

  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const settle = (callback: () => void) => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", onAbort);
      callback();
    };
    const onAbort = () => settle(() => reject(abortError()));
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => settle(() => resolve(value)),
      (error: unknown) => settle(() => reject(error))
    );
  });
}

function abortError() {
  const error = new Error("The chat resolution attempt was aborted.");
  error.name = "AbortError";
  return error;
}

function isAbortError(error: unknown) {
  return error instanceof Error && error.name === "AbortError";
}
