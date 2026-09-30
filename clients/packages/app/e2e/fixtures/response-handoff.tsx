// Browser-only fixture for the real ConversationView/Thread in surfaces that
// the web shell cannot open (SideChat is an Electron renderer).
import { useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  RouterProvider,
} from "@tanstack/react-router";
import { SideChatCardsPanel, SideChatPanel } from "@comma/ui";
import { initializeCommaI18n } from "@comma/i18n";
import {
  ConversationView,
  type ConversationViewActions,
} from "../../src/components/chat/conversation/ConversationView";
import { createCommaApi, type CommaApiSessionTransport } from "../../src/api";
import type { ConversationChannelState } from "../../src/components/chat/model/conversationChannel";
import { fixedDraftSource } from "../../src/components/chat/composer/conversationDraft";
import {
  CommaAuthContext,
  type CommaAuthContextValue,
} from "../../src/components/auth-context";
import "../../src/styles.css";

initializeCommaI18n(["en"]);
const profileSignal = new AbortController().signal;
const profileTransport: CommaApiSessionTransport = {
  credentials: "include",
  signal: profileSignal,
  applyHeaders: () => undefined,
  reportSessionRejection: () => undefined,
};
const profile: CommaAuthContextValue | undefined = new URL(
  location.href
).searchParams.has("profile")
  ? {
      api: createCommaApi({
        baseUrl: location.origin,
        sessionTransport: profileTransport,
        token: "",
      }),
      apiBaseUrl: location.origin,
      avatarRevision: "reply-avatar",
      authenticated: true,
      productLease: {
        audience: location.origin,
        authorityInstanceId: "reply-fixture",
        generation: 1,
        sessionId: "reply-fixture-session",
      },
      sessionSignal: profileSignal,
      sessionTransport: profileTransport,
      signOut: () => undefined,
      userId: "reply-user",
      userDisplayName: "Ada Lovelace",
      userEmail: "ada@example.test",
    }
  : undefined;
const variant =
  new URL(location.href).searchParams.get("surface") === "side-chat"
    ? "side-chat"
    : "route";
const cardsSurface =
  new URL(location.href).searchParams.get("surface")?.startsWith("tasks") ?? false;
const motionSurface =
  new URL(location.href).searchParams.get("surface") === "tasks-motion";
if (motionSurface) {
  document.documentElement.dataset.commaWindowRole = "side-chat";
  document.body.dataset.commaWindowRole = "side-chat";
  document.getElementById("root")!.style.height = "100vh";
}
const initial: ConversationChannelState = {
  activity: undefined,
  assistantDraft: undefined,
  awaitingReply: false,
  awaitingSince: undefined,
  awaitingTimedOut: false,
  connection: "live",
  conversation: {
    id: "handoff",
    group_id: "group",
    kind: "user_chat",
    title: "Reply handoff",
    status: "completed",
  },
  draft: "",
  draftAttachments: [],
  errorKind: undefined,
  lastBackoffMs: 0,
  messages: [],
  pending: [],
  participantStatus: undefined,
  serverMessages: [],
  status: "ready",
  syncWarning: undefined,
};
const actions: ConversationViewActions = {
  attachFiles() {},
  discard() {},
  refresh() {},
  removeAttachment() {},
  retry() {},
  retryAttachment() {},
  send() {},
  setDraft() {},
};
const fixture = window as unknown as {
  lastSentText?: string;
  setHandoffState: (state: Partial<ConversationChannelState>) => void;
};
function Surface() {
  const [state, setState] = useState(initial);
  const draftSource = useMemo(() => fixedDraftSource(state.draft), [state.draft]);
  const [cardsHeight, setCardsHeight] = useState(274);
  const sendingActions = useMemo<ConversationViewActions>(
    () => ({
      ...actions,
      setDraft(draft) {
        setState((current) => ({ ...current, draft }));
      },
      send(text) {
        fixture.lastSentText = text;
        setState((current) => ({
          ...current,
          draft: "",
          awaitingReply: true,
          awaitingSince: Date.now(),
          messages: [
            ...current.messages,
            {
              messageId: `sent-${current.messages.length}`,
              clientRequestId: `sent-${current.messages.length}`,
              role: "user",
              text,
              parts: [{ kind: "markdown", text }],
              attachments: [],
              refs: [],
              blocksKey: undefined,
              createdBy: undefined,
              error: undefined,
              status: "active",
              createdAt: Date.now(),
              delivery: "sending",
              source: "pending",
            },
          ],
        }));
      },
    }),
    []
  );
  fixture.setHandoffState = (next) => setState({ ...initial, ...next });
  return (
    <div
      className={
        variant === "side-chat" || cardsSurface ? "comma-side-chat-host" : undefined
      }
      style={{
        position: motionSurface ? "absolute" : "relative",
        width: "100%",
        height: motionSurface ? cardsHeight : "100vh",
        bottom: motionSurface ? -9 : "auto",
        left: "auto",
        display: "flex",
      }}
    >
      {cardsSurface ? (
        <SideChatPanel
          cardsVisible
          cards={
            <SideChatCardsPanel
              onRequiredHeight={(height) => {
                if (motionSurface)
                  setCardsHeight(Math.min(600, Math.max(274, height + 75)));
              }}
              capability={{
                status: "ready",
                tasks: state.messages.map((msg) => ({
                  id: msg.messageId,
                  activityStatus: "idle",
                  conversationId: msg.messageId,
                  groupId: "group",
                  workspaceId: "workspace",
                  title: msg.text,
                  createdAt: 1,
                  statusBucket: msg.role === "user" ? "in_progress" : "done",
                })),
              }}
            />
          }
        >
          {null}
        </SideChatPanel>
      ) : (
        <ConversationView
          actions={sendingActions}
          draftSource={draftSource}
          state={state}
          variant={variant}
        />
      )}
    </div>
  );
}
const root = createRootRoute({ component: Outlet });
const route = createRoute({
  getParentRoute: () => root,
  path: "/",
  component: Surface,
});
const router = createRouter({
  routeTree: root.addChildren([route]),
  history: createMemoryHistory({ initialEntries: ["/"] }),
});
createRoot(document.getElementById("root")!).render(
  <CommaAuthContext.Provider value={profile}>
    <RouterProvider router={router} />
  </CommaAuthContext.Provider>
);
