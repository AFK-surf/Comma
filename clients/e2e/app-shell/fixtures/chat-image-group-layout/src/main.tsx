import "@comma/ui/styles.css";
import "../../../../../packages/app/src/styles.css";

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import type {
  ChatImagePreviewRef,
  ChatMessage,
  LocalFilePreview,
} from "../../../../../packages/app/src/components/chat/model/conversationChannel";
import { ConversationThread } from "../../../../../packages/app/src/components/chat/thread/ConversationThread";
import { CommaUiThemeProvider } from "../../../../../packages/app/src/components/commaUiTheme";

declare global {
  interface Window {
    chatImageGroupLayoutFixture?: {
      pendingRefs: () => string[];
      requestedCount: () => number;
      resolve: (index: number) => boolean;
      resolveAll: () => void;
    };
  }
}

const COLORS = [
  "#5b8def",
  "#e0785a",
  "#59b47c",
  "#b46fd6",
  "#e8b04a",
  "#4fb3c9",
  "#d65a7a",
];

const refFor = (index: number) => `lfi1_${String.fromCharCode(97 + index).repeat(43)}`;

function imageDataUrl(index: number) {
  const canvas = document.createElement("canvas");
  canvas.width = 600;
  canvas.height = 800;
  const context = canvas.getContext("2d")!;
  context.fillStyle = COLORS[index % COLORS.length]!;
  context.fillRect(0, 0, 600, 800);
  context.fillStyle = "rgba(255,255,255,0.92)";
  context.font = "bold 260px system-ui";
  context.textAlign = "center";
  context.textBaseline = "middle";
  context.fillText(String(index + 1), 300, 400);
  return canvas.toDataURL("image/png");
}

const previewUrl = new Map<string, string>();
for (let index = 0; index < 7; index += 1) {
  previewUrl.set(refFor(index), imageDataUrl(index));
}

// Previews stay pending until the spec releases them one at a time, so every
// intermediate state of a settling message is observable and deterministic.
const pending = new Map<string, (preview: LocalFilePreview | undefined) => void>();
let requestedCount = 0;

const onPreviewLocalFile = (
  previewRef: ChatImagePreviewRef,
  signal?: AbortSignal
): Promise<LocalFilePreview | undefined> =>
  new Promise((resolve) => {
    if (typeof previewRef !== "string") {
      resolve(undefined);
      return;
    }
    requestedCount += 1;
    const settle = (preview: LocalFilePreview | undefined) => {
      pending.delete(previewRef);
      resolve(preview);
    };
    pending.set(previewRef, settle);
    signal?.addEventListener("abort", () => settle(undefined));
  });

window.chatImageGroupLayoutFixture = {
  pendingRefs: () => [...pending.keys()],
  requestedCount: () => requestedCount,
  resolve: (index) => {
    const ref = refFor(index);
    const settle = pending.get(ref);
    if (!settle) return false;
    settle({ release() {}, url: previewUrl.get(ref)! });
    return true;
  },
  resolveAll: () => {
    // Settling removes the entry, so iterate over a snapshot of the map.
    const entries = Array.from(pending.entries());
    for (const [ref, settle] of entries) {
      settle({ release() {}, url: previewUrl.get(ref)! });
    }
  },
};

function imageAttachment(index: number): ChatMessage["attachments"][number] {
  return {
    blockType: "image",
    fileName: `photo-${index + 1}.png`,
    localFileRef: refFor(index),
    mimeType: "image/png",
    size: 120_000 + index,
  };
}

function message(
  messageId: string,
  role: "user" | "assistant",
  text: string,
  attachments: ChatMessage["attachments"] = []
): ChatMessage {
  return {
    attachments,
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId,
    parts: [{ kind: "markdown", text }],
    refs: [],
    role,
    source: "server",
    status: "completed",
    text,
  };
}

// Enough transcript below the image messages to carry them past the 720px
// retention band when the thread sits at its bottom.
const filler = Array.from(
  { length: 16 },
  (_, index) =>
    `Paragraph ${index + 1}: filler prose that pushes the image messages above out of the preview retention band once the thread scrolls to its latest turn.`
).join("\n\n");

const messages: ChatMessage[] = [
  message("m1", "user", "Photos from last week", [0, 1, 2, 3].map(imageAttachment)),
  message("m2", "assistant", "Looking at the four photos now."),
  message(
    "m3",
    "user",
    "And three more from the venue",
    [4, 5, 6].map(imageAttachment)
  ),
  message("m4", "assistant", filler),
  message("m5", "user", "Go with that"),
  message("m6", "assistant", "Drafting the report."),
];

function ChatImageGroupLayoutFixture() {
  return (
    <CommaUiThemeProvider theme="Light mode">
      <main
        style={{
          background: "var(--color-bg-primary)",
          boxSizing: "border-box",
          minHeight: "100vh",
          padding: 24,
        }}
      >
        <section
          className="comma-chat-route"
          data-testid="chat-image-group-layout-fixture"
          data-variant="route"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            display: "flex",
            flexDirection: "column",
            height: 680,
            margin: "0 auto",
            overflow: "hidden",
            width: 760,
          }}
        >
          <ConversationThread
            groupId="grp-image-layout-e2e"
            messages={messages}
            onDiscard={() => undefined}
            onPreviewLocalFile={onPreviewLocalFile}
            onRetry={() => undefined}
            workspaceId="wsp-image-layout-e2e"
          />
        </section>
      </main>
    </CommaUiThemeProvider>
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <ChatImageGroupLayoutFixture />
  </StrictMode>
);
