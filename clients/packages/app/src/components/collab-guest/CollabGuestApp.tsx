import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { Button } from "@comma/ui/components/Button";
import { CommaLogoAnimation } from "@comma/ui/components/comma-mascot";
import { Dialog } from "@comma/ui/components/dialog";
import { useCallback, useEffect, useState } from "react";
import {
  clearStoredGuestSession,
  CollabGuestError,
  normalizeGuestMessage,
  readStoredGuestSession,
  writeStoredGuestSession,
  type CollabGuestClient,
  type CollabGuestFilesData,
  type CollabGuestInvite,
  type CollabGuestMessage,
  type CollabGuestTaskData,
  type CollabGuestVerifyResult,
} from "./collabGuestApi";
import {
  CollabGuestOtpGate,
  CollabGuestStatusScreen,
  FULL_COMMA_HREF,
} from "./CollabGuestOtpGate";
import { CollabGuestWorkspace } from "./CollabGuestWorkspace";

type ViewState =
  | { kind: "loading" }
  | { kind: "status"; reason: "expired" | "not_found" | "revoked" | "unavailable" }
  | { kind: "otp"; invite: CollabGuestInvite }
  | {
      kind: "active";
      sessionToken: string;
      taskData: CollabGuestTaskData;
      messages: CollabGuestMessage[];
      filesData: CollabGuestFilesData;
    };

const SSE_BACKOFF_MS = [1_000, 2_000, 4_000, 8_000, 15_000];

const EMPTY_FILES: CollabGuestFilesData = { entries: [] };

function mergeMessages(
  current: CollabGuestMessage[],
  incoming: CollabGuestMessage
): CollabGuestMessage[] {
  const index = current.findIndex((m) => m.id === incoming.id);
  if (index >= 0) {
    const next = current.slice();
    next[index] = incoming;
    return next;
  }
  return [...current, incoming];
}

/**
 * Standalone external email guest web app (`/c/:token`).
 * Renders a persistent top bar (task title, Guest badge, host name, Leave action,
 * and "Use full Comma" CTA) above either the OTP verification gate or the live
 * collaborative task workspace.
 */
export function CollabGuestApp({
  client,
  inviteToken,
}: {
  client: CollabGuestClient;
  inviteToken: string;
}) {
  const messages = useCommaMessages();
  const [state, setState] = useState<ViewState>({ kind: "loading" });
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [leaveOpen, setLeaveOpen] = useState(false);
  const [leaving, setLeaving] = useState(false);

  const handleRevoked = useCallback(() => {
    clearStoredGuestSession(inviteToken);
    setLeaveOpen(false);
    setState({ kind: "status", reason: "revoked" });
  }, [inviteToken]);

  const loadWorkspace = useCallback(
    async (sessionToken: string, signal?: AbortSignal) => {
      const [taskData, filesData] = await Promise.all([
        client.getTask(sessionToken, signal ? { signal } : {}),
        client.listFiles(sessionToken, signal).catch((err) => {
          if (err instanceof CollabGuestError && err.code === "guest_session_revoked") {
            throw err;
          }
          return EMPTY_FILES;
        }),
      ]);
      if (signal?.aborted) return;
      const normalized = taskData.messages.map((raw, idx) =>
        normalizeGuestMessage(raw, `msg-${idx}`)
      );
      setState({
        kind: "active",
        sessionToken,
        taskData,
        messages: normalized,
        filesData,
      });
    },
    [client]
  );

  const bootstrap = useCallback(
    async (signal?: AbortSignal) => {
      if (!inviteToken) {
        setState({ kind: "status", reason: "not_found" });
        return;
      }
      setState({ kind: "loading" });
      const stored = readStoredGuestSession(inviteToken);
      if (stored?.token) {
        try {
          await loadWorkspace(stored.token, signal);
          return;
        } catch (error) {
          if (signal?.aborted) return;
          if (error instanceof CollabGuestError) {
            if (error.code === "guest_session_revoked") {
              clearStoredGuestSession(inviteToken);
            } else if (error.code === "invite_expired") {
              clearStoredGuestSession(inviteToken);
              setState({ kind: "status", reason: "expired" });
              return;
            }
          }
        }
      }

      try {
        const invite = await client.getInvite(signal);
        if (signal?.aborted) return;
        setState({ kind: "otp", invite });
      } catch (error) {
        if (signal?.aborted) return;
        if (error instanceof CollabGuestError) {
          if (error.code === "invite_expired") {
            setState({ kind: "status", reason: "expired" });
            return;
          }
          if (error.code === "not_found") {
            setState({ kind: "status", reason: "not_found" });
            return;
          }
        }
        setState({ kind: "status", reason: "unavailable" });
      }
    },
    [client, inviteToken, loadWorkspace]
  );

  useEffect(() => {
    const controller = new AbortController();
    void bootstrap(controller.signal);
    return () => controller.abort();
  }, [bootstrap]);

  useEffect(() => {
    if (state.kind === "active") {
      document.title = state.taskData.task.title;
    } else if (state.kind === "otp") {
      document.title = state.invite.title;
    }
  }, [state]);

  // Live SSE stream while active, with exponential reconnect backoff.
  const activeSessionToken = state.kind === "active" ? state.sessionToken : null;
  useEffect(() => {
    if (!activeSessionToken) return;
    let closed = false;
    let backoffIndex = 0;
    let sseSeq = 0;
    let hasSeenResync = false;
    let needsReconnectResync = false;
    let refreshInFlight = false;
    let refreshQueued = false;
    let cancelReconnect: (() => void) | undefined;
    let source: EventSource | null = null;
    const refreshController = new AbortController();

    const triggerRefresh = () => {
      if (closed) return;
      if (refreshInFlight) {
        refreshQueued = true;
        return;
      }
      refreshInFlight = true;
      void (async () => {
        try {
          do {
            refreshQueued = false;
            const [taskData, filesData] = await Promise.all([
              client.getTask(activeSessionToken, {
                signal: refreshController.signal,
              }),
              client
                .listFiles(activeSessionToken, refreshController.signal)
                .catch((err) => {
                  if (
                    err instanceof CollabGuestError &&
                    err.code === "guest_session_revoked"
                  ) {
                    throw err;
                  }
                  return null;
                }),
            ]);
            if (closed || refreshController.signal.aborted) return;
            const normalized = taskData.messages.map((raw, idx) =>
              normalizeGuestMessage(raw, `msg-${idx}`)
            );
            setState((prev) =>
              prev.kind === "active"
                ? {
                    ...prev,
                    taskData,
                    messages: normalized,
                    filesData: filesData ?? prev.filesData,
                  }
                : prev
            );
          } while (refreshQueued);
        } catch (err) {
          if (closed || refreshController.signal.aborted) return;
          if (err instanceof CollabGuestError && err.code === "guest_session_revoked") {
            closed = true;
            source?.close();
            handleRevoked();
          }
        } finally {
          refreshInFlight = false;
        }
      })();
    };

    const connect = () => {
      if (closed) return;
      const es = client.openEvents(activeSessionToken);
      if (!es) return;
      source = es;

      es.addEventListener("open", () => {
        backoffIndex = 0;
      });

      es.addEventListener("resync", () => {
        if (hasSeenResync || needsReconnectResync) {
          needsReconnectResync = false;
          triggerRefresh();
        } else {
          hasSeenResync = true;
        }
      });

      es.addEventListener("task_updated", () => {
        triggerRefresh();
      });

      es.addEventListener("revoked", () => {
        closed = true;
        es.close();
        handleRevoked();
      });

      const handleMessagePayload = (event: MessageEvent<string>) => {
        let parsed: unknown;
        try {
          parsed = JSON.parse(event.data);
        } catch {
          return;
        }
        if (!parsed || typeof parsed !== "object") return;
        const payload = parsed as Record<string, unknown>;
        if (payload.type === "revoked" || payload.event === "revoked") {
          closed = true;
          es.close();
          handleRevoked();
          return;
        }
        if (
          payload.type === "task_updated" ||
          payload.type === "task_resync_required"
        ) {
          triggerRefresh();
          return;
        }
        if (payload.type === "files_updated") {
          void client
            .listFiles(activeSessionToken)
            .then((filesData) => {
              setState((prev) =>
                prev.kind === "active" ? { ...prev, filesData } : prev
              );
            })
            .catch((err) => {
              if (
                err instanceof CollabGuestError &&
                err.code === "guest_session_revoked"
              ) {
                handleRevoked();
              }
            });
          return;
        }
        if (payload.type === "delta" && typeof payload.delta === "string") {
          const id =
            typeof payload.message_id === "string"
              ? payload.message_id
              : "streaming-assistant";
          setState((prev) => {
            if (prev.kind !== "active") return prev;
            const existing = prev.messages.find((m) => m.id === id);
            const updated: CollabGuestMessage = existing
              ? {
                  ...existing,
                  text: `${existing.text}${payload.delta as string}`,
                  streaming: true,
                }
              : {
                  id,
                  role: "assistant",
                  senderName: null,
                  isGuestSender: false,
                  isSelf: false,
                  text: payload.delta as string,
                  miniApps: [],
                  attachments: [],
                  streaming: true,
                };
            return { ...prev, messages: mergeMessages(prev.messages, updated) };
          });
          return;
        }
        const rawMessage = payload.message ?? payload;
        if (
          rawMessage &&
          typeof rawMessage === "object" &&
          ("content" in rawMessage || "text" in rawMessage || "id" in rawMessage)
        ) {
          const normalized = normalizeGuestMessage(rawMessage, `sse-${++sseSeq}`);
          setState((prev) =>
            prev.kind === "active"
              ? { ...prev, messages: mergeMessages(prev.messages, normalized) }
              : prev
          );
        }
      };

      es.addEventListener("message", handleMessagePayload);
      es.addEventListener("message_created", handleMessagePayload);
      es.addEventListener("message_updated", handleMessagePayload);
      es.addEventListener("delta", handleMessagePayload);

      es.addEventListener("error", () => {
        es.close();
        if (closed) return;
        needsReconnectResync = true;
        const delay =
          SSE_BACKOFF_MS[Math.min(backoffIndex, SSE_BACKOFF_MS.length - 1)]!;
        backoffIndex++;
        cancelReconnect = uiClock.after(delay, connect);
      });
    };

    connect();
    return () => {
      closed = true;
      cancelReconnect?.();
      refreshController.abort();
      source?.close();
    };
  }, [activeSessionToken, client, handleRevoked]);

  const handleVerified = async (result: CollabGuestVerifyResult) => {
    writeStoredGuestSession(inviteToken, {
      token: result.token,
      expiresAt: result.expires_at,
      guest: result.guest,
    });
    setState({ kind: "loading" });
    try {
      await loadWorkspace(result.token);
    } catch (error) {
      if (error instanceof CollabGuestError && error.code === "guest_session_revoked") {
        handleRevoked();
        return;
      }
      setState({ kind: "status", reason: "unavailable" });
    }
  };

  const handleSendMessage = async (text: string, mentionComma: boolean) => {
    if (state.kind !== "active") return;
    setSending(true);
    try {
      const sent = await client.sendMessage(state.sessionToken, {
        text,
        mentionComma,
      });
      setState((prev) =>
        prev.kind === "active"
          ? { ...prev, messages: mergeMessages(prev.messages, sent) }
          : prev
      );
    } catch (error) {
      if (error instanceof CollabGuestError && error.code === "guest_session_revoked") {
        handleRevoked();
        return;
      }
      throw error;
    } finally {
      setSending(false);
    }
  };

  const handleUploadFile = async (file: File) => {
    if (state.kind !== "active") return;
    setUploading(true);
    setUploadError(null);
    try {
      await client.uploadFile(state.sessionToken, file);
      const filesData = await client.listFiles(state.sessionToken);
      setState((prev) => (prev.kind === "active" ? { ...prev, filesData } : prev));
    } catch (error) {
      if (error instanceof CollabGuestError) {
        if (error.code === "guest_session_revoked") {
          handleRevoked();
          return;
        }
        if (error.code === "file_too_large") {
          setUploadError(messages.collab_guest_files_error_too_large());
          return;
        }
      }
      setUploadError(messages.collab_guest_files_error_generic());
    } finally {
      setUploading(false);
    }
  };

  const handleConfirmLeave = async () => {
    if (state.kind !== "active" || leaving) return;
    setLeaving(true);
    try {
      await client.leaveTask(state.sessionToken);
    } catch {
      // Clear local access regardless of network/401 race.
    } finally {
      setLeaving(false);
      handleRevoked();
    }
  };

  return (
    <>
      {state.kind === "otp" ? (
        <CollabGuestOtpGate
          client={client}
          invite={state.invite}
          onExpired={() => setState({ kind: "status", reason: "expired" })}
          onVerified={(result) => void handleVerified(result)}
        />
      ) : (
        // The app window, as a shared Task's page draws it: the gray canvas with one rounded content surface.
        <div className="comma-app-shell flex h-dvh min-h-0 w-full min-w-0 flex-col bg-window px-xs pb-xs text-primary @min-[640px]/comma-window:px-md @min-[640px]/comma-window:pb-md">
          <header
            className="flex h-10 shrink-0 items-center gap-sm px-xs"
            data-testid="collab-guest-topbar"
          >
            <a
              aria-label="Comma"
              className="flex min-w-0 flex-1 items-center gap-sm"
              href={FULL_COMMA_HREF}
            >
              <img alt="" className="size-5 rounded-sm" src="/brand/comma/icon.png" />
              <span className="text-sm font-medium text-secondary">Comma</span>
            </a>
            {state.kind === "active" ? (
              <Button
                data-testid="collab-guest-use-full-comma"
                hierarchy="secondary-gray"
                onPress={() => window.location.assign(FULL_COMMA_HREF)}
                size="xs"
              >
                {messages.collab_guest_use_full_comma()}
              </Button>
            ) : null}
          </header>
          <main className="comma-content relative flex min-h-0 min-w-0 flex-1 flex-col overflow-clip bg-main-panel-bg">
            {state.kind === "loading" ? (
              <output
                aria-busy="true"
                aria-label={messages.collab_guest_loading()}
                className="flex flex-1 items-center justify-center p-xl"
              >
                <span className="size-8 text-disabled">
                  <CommaLogoAnimation aria-hidden="true" style={{ color: "inherit" }} />
                </span>
              </output>
            ) : state.kind === "status" ? (
              <CollabGuestStatusScreen
                kind={state.reason}
                onRetry={
                  state.reason === "unavailable" ? () => void bootstrap() : undefined
                }
              />
            ) : (
              <CollabGuestWorkspace
                client={client}
                filesData={state.filesData}
                messagesList={state.messages}
                onClearUploadError={() => setUploadError(null)}
                onLeave={() => setLeaveOpen(true)}
                onSendMessage={handleSendMessage}
                onUploadFile={handleUploadFile}
                sending={sending}
                sessionToken={state.sessionToken}
                taskData={state.taskData}
                uploadError={uploadError}
                uploading={uploading}
              />
            )}
          </main>
        </div>
      )}

      {leaveOpen ? (
        <Dialog
          actions={[
            {
              label: messages.collab_guest_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setLeaveOpen(false),
            },
            {
              label: messages.collab_guest_leave_confirm_action(),
              hierarchy: "primary",
              disabled: leaving,
              onPress: () => void handleConfirmLeave(),
            },
          ]}
          description={messages.collab_guest_leave_confirm_body()}
          isOpen
          onOpenChange={(isOpen) => {
            if (!isOpen && !leaving) setLeaveOpen(false);
          }}
          title={messages.collab_guest_leave_confirm_title()}
        />
      ) : null}
    </>
  );
}
