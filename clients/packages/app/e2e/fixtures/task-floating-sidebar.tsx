import { createRoot } from "react-dom/client";
import { initializeCommaI18n } from "@comma/i18n";
import { getNativeBridge } from "@comma/native-bridge";
import type { ChatRuntimeSnapshot } from "@comma/chat-contract";
import { SideChatTestWindow } from "../../src/components/chat/side-chat/SideChatTestWindow";
import { CommaSessionHostProvider } from "../../src/session/react";
import { CommaWebClientSettingsProvider } from "../../src/components/commaClientSettings";
import {
  createTestSessionHostController,
  signedInSessionSnapshot,
} from "../../src/test/sessionHostHarness";
import "../../src/styles.css";

const chatState: ChatRuntimeSnapshot = {
  protocolVersion: 3,
  revision: 1,
  sessions: [
    {
      conversationId: "cnv_parent",
      groupId: "grp_1",
      key: "grp_1/cnv_parent",
      refs: 1,
      revision: 1,
      state: {
        awaitingReply: false,
        awaitingTimedOut: false,
        connection: "live",
        conversation: {
          groupId: "grp_1",
          id: "cnv_parent",
          kind: "agent_task",
          status: "open",
          title: "Parent task",
          workspaceId: "wsp_1",
        },
        draft: "",
        draftAttachments: [],
        lastBackoffMs: 0,
        messages: [
          {
            attachments: [],
            delivery: "sent",
            messageId: "msg_nested_task",
            parts: [
              { kind: "markdown", text: "[Preview](https://example.com/preview)" },
              {
                kind: "inline-task",
                task: {
                  conversationId: "cnv_nested",
                  title: "Nested task",
                  unavailable: false,
                },
              },
            ],
            refs: [],
            role: "assistant",
            source: "server",
            text: "Preview",
          },
        ],
        pending: [],
        serverMessages: [],
        status: "ready",
      },
      workspaceId: "wsp_1",
    },
  ],
};

initializeCommaI18n(["en"]);
const bridge = getNativeBridge();
const envelope = {
  session: {
    audience: "https://api.comma.test",
    authorityInstanceId: "test-electron-main",
    generation: 1,
    sessionId: "11111111-1111-4111-8111-111111111111",
  },
  snapshot: chatState,
};
const get = async () => envelope;
globalThis.commaNative = {
  ...bridge,
  platform: "electron",
  self: { role: "side-chat-test-window", windowId: "floating-fixture" },
  chat: {
    ...bridge.chat,
    state: Object.assign(get, { get, subscribe: () => () => {} }),
  },
};
createRoot(document.getElementById("root")!).render(
  <CommaWebClientSettingsProvider>
    <CommaSessionHostProvider
      controller={createTestSessionHostController({ initial: signedInSessionSnapshot })}
    >
      <SideChatTestWindow />
    </CommaSessionHostProvider>
  </CommaWebClientSettingsProvider>
);
