import { baseLocale, messages as commaMessages, type CommaLocale } from "@comma/i18n";
import { useCommaMessages } from "@comma/i18n/react";
import { useCall, useTopic, type CoreClient } from "@comma/core-client";
import type { WorkspaceChat, WorkspaceChatValue } from "@comma/core/contract";
import type { ChatWorkspaceResolution } from "@comma/chat-contract";
import type { SessionProductLease } from "@comma/session-contract";
import { useCallback, useEffect, useMemo } from "react";
import type { CommaConversation } from "@comma/core/api-schemas";
import { useSelectWorkspace } from "../activeWorkspace";

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

export type WorkspaceChatState =
  | WorkspaceChatResolution
  | {
      status: "loading";
    }
  | {
      status: "error";
      message: string;
    };

/**
 * The account's chat with Comma as the client core resolves it (`workspaceChat`): it waits out a workspace still being
 * made and shows the chat this device found before until the server confirms it. With `routeWorkspaceId` (and not
 * `nativeDefault`), that workspace's chat.
 */
export function useWorkspaceChat({
  activateWorkspace = true,
  nativeDefault = false,
  routeWorkspaceId,
}: {
  // A ready resolution normally makes the resolved Workspace the shell-wide
  // active one (`workspace.select`), which rescopes every route that
  // subscribes to the active Workspace. Pass false for background resolution
  // that must not change what the user is looking at — e.g. the route-
  // independent Home conversation target bootstrap.
  activateWorkspace?: boolean | undefined;
  nativeDefault?: boolean | undefined;
  routeWorkspaceId?: string | undefined;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const selectWorkspace = useSelectWorkspace();
  const workspace = nativeDefault ? undefined : routeWorkspaceId;
  const { value, error } = useTopic({
    topic: "workspaceChat",
    ...(workspace ? { workspace } : {}),
  });
  const defaultTitle = messages.chat_default_title();
  const unavailableMessage = messages.chat_unavailable();
  const state = useMemo(
    (): WorkspaceChatState =>
      workspaceChatState(value, error !== null, defaultTitle, unavailableMessage),
    [defaultTitle, error, unavailableMessage, value]
  );
  const readyWorkspaceId = state.status === "ready" ? state.workspaceId : undefined;
  useEffect(() => {
    if (readyWorkspaceId && activateWorkspace) selectWorkspace(readyWorkspaceId);
  }, [activateWorkspace, readyWorkspaceId, selectWorkspace]);
  const retry = useCallback(() => {
    void call("workspaceChat.retry", workspace ? { workspace } : {}).catch(
      () => undefined
    );
  }, [call, workspace]);
  return { retry, state };
}

function workspaceChatState(
  value: WorkspaceChatValue | undefined,
  failed: boolean,
  defaultTitle: string,
  unavailableMessage: string
): WorkspaceChatState {
  // A chat found before is shown while the server cannot confirm it.
  if (value?.chat && (value.status === "ready" || value.status === "error"))
    return {
      conversation: workspaceConversation(value.chat, defaultTitle),
      groupId: value.chat.groupId,
      status: "ready",
      workspaceId: value.chat.workspaceId,
    };
  if (failed || value?.status === "error")
    // Provider and server failures may contain request internals or untrusted upstream prose: never shown.
    return { status: "error", message: unavailableMessage };
  if (value?.status === "provisioning" && value.provisioning)
    return { status: "provisioning", ...value.provisioning };
  if (value?.status === "hidden" || value?.status === "unauthorized")
    return { status: value.status };
  return { status: "loading" };
}

function workspaceConversation(
  chat: WorkspaceChat,
  defaultTitle: string
): CommaConversation {
  return {
    ...(chat.createdAt === undefined ? {} : { created_at: chat.createdAt }),
    group_id: chat.groupId,
    id: chat.conversationId,
    kind: "user_chat",
    messages: [],
    status: "open",
    title: defaultTitle,
    ...(chat.updatedAt === undefined ? {} : { updated_at: chat.updatedAt }),
  };
}

export async function resolveWorkspaceChat({
  locale = baseLocale,
  core,
  defaultTitle = commaMessages.chat_default_title({}, { locale }),
  exactWorkspace = false,
  session,
  signal,
  workspaceId,
  afterProvisioning,
}: {
  /** The server's wait from a provisioning answer: the core waits it out before it asks again. */
  afterProvisioning?: number | undefined;
  /** The core that resolves it. */
  core: CoreClient;
  defaultTitle?: string;
  exactWorkspace?: boolean | undefined;
  locale?: CommaLocale;
  session?: SessionProductLease | undefined;
  signal?: AbortSignal;
  workspaceId?: string | undefined;
}): Promise<WorkspaceChatResolution> {
  if (!session) {
    throw new Error(
      "Workspace Chat resolution requires the active Session product lease."
    );
  }
  // The client core resolves it: the default workspace's chat, or the exact workspace asked for.
  const resolution = await abortable(
    core.call("chat.resolveWorkspaceChat", {
      session,
      ...(exactWorkspace && workspaceId ? { workspaceId } : {}),
      ...(afterProvisioning === undefined ? {} : { afterProvisioning }),
    }) as Promise<ChatWorkspaceResolution>,
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
