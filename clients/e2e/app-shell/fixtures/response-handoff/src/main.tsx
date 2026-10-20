// Browser-only fixture for the real ConversationView/Thread on the test clock.
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
import { CoreProvider } from "@comma/core-client";
// A fixture page builds with the web app's aliases, which leave test packages out.
import { createScriptedCore } from "../../../../../packages/test-utils/src/scripted-core";
import { initializeCommaI18n } from "@comma/i18n";
import { fixtureSearch } from "../../../support/search";
import {
  ConversationView,
  type ConversationViewActions,
} from "../../../../../packages/app/src/components/chat/conversation/ConversationView";
import type { CommaApiSessionTransport } from "../../../../../packages/app/src/session/controller";
import type { ConversationChannelState } from "@comma/core/chat";
import { readState } from "../../coreReading";
import { fixedDraftSource } from "../../../../../packages/app/src/components/chat/composer/conversationDraft";
import {
  CommaAuthContext,
  type CommaAuthContextValue,
} from "../../../../../packages/app/src/components/auth-context";
import "../../../../../packages/app/src/styles.css";

initializeCommaI18n(["en"]);
const search = new URLSearchParams(fixtureSearch());
const profileSignal = new AbortController().signal;
const profileTransport: CommaApiSessionTransport = {
  credentials: "include",
  signal: profileSignal,
  applyHeaders: () => undefined,
  reportSessionRejection: () => undefined,
};
const profile: CommaAuthContextValue | undefined = search.has("profile")
  ? {
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
  // The core sends its reading of the conversation with it.
  const shown = useMemo(() => readState(state), [state]);
  fixture.setHandoffState = (next) => setState({ ...initial, ...next });
  return (
    <div
      style={{
        position: "relative",
        width: "100%",
        height: "100vh",
        display: "flex",
      }}
    >
      <ConversationView
        actions={sendingActions}
        draftSource={draftSource}
        state={shown}
        variant="route"
      />
    </div>
  );
}
// The profile's avatar: one pixel, counted as the core reads it.
const avatar = Uint8Array.from(
  atob(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
  ),
  (char) => char.charCodeAt(0)
);
const avatarFixture = window as unknown as { avatarReads: number };
avatarFixture.avatarReads = 0;
const core = createScriptedCore({
  calls: async (name, params) => {
    const source = params as { source?: string; revision?: string };
    if (name !== "files.read" || source.source !== "avatar") return null;
    if (source.revision !== "reply-avatar") return null;
    avatarFixture.avatarReads += 1;
    return { bytes: avatar, type: "image/png" };
  },
});
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
    <CoreProvider client={core.client}>
      <RouterProvider router={router} />
    </CoreProvider>
  </CommaAuthContext.Provider>
);
