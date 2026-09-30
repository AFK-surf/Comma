import { useState } from "react";
import { createRoot } from "react-dom/client";
import {
  createMemoryHistory,
  createRootRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import { initializeCommaI18n } from "@comma/i18n";
import type { CommaApiClient } from "../../src/api";
import { ConversationThread } from "../../src/components/chat/thread/ConversationThread";
import type { ChatMessage } from "../../src/components/chat/model/conversationChannel";
import { LocalFilePreviewCache } from "../../src/runtime-chat/channel/preview/LocalFilePreviewCache";
import "../../src/styles.css";

initializeCommaI18n(["en"]);
const imageSource = new URL(
  "../../../ui/src/components/chat-panel/assets/generated-image-preview.png",
  import.meta.url
).href;
const videoSource = new URL("./file-preview/sample.mp4", import.meta.url).href;
const metrics = { imageLoads: 0, imageReleases: 0, videoLoads: 0 };
const cache = new LocalFilePreviewCache({
  load: async () => {
    metrics.imageLoads += 1;
    return new Uint8Array(await (await fetch(imageSource)).arrayBuffer());
  },
});
const loadPreview = async (...args: Parameters<typeof cache.acquire>) => {
  const lease = await cache.acquire(...args);
  if (!lease) return undefined;
  return {
    url: lease.url,
    release: () => {
      metrics.imageReleases += 1;
      lease.release();
    },
  };
};
const api = {
  fetchConversationAttachment: async () => {
    metrics.videoLoads += 1;
    return (await fetch(videoSource)).blob();
  },
} as unknown as CommaApiClient;
function message(messageId: string, text: string, role = "assistant"): ChatMessage {
  return {
    attachments: [],
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
const imageMessage = {
  ...message("image", "An image that has already loaded must keep its source."),
  attachments: [
    {
      blockType: "image" as const,
      fileName: "original.png",
      localFileRef: `lfi1_${"a".repeat(43)}`,
      mimeType: "image/png",
      size: 456,
      title: undefined,
    },
  ],
};
const videoMessage = {
  ...message("video", "An inline video must keep its playback state."),
  attachments: [
    {
      blockType: "file" as const,
      attachmentIndex: 0,
      fileName: "sample.mp4",
      mimeType: "video/mp4",
      size: 8192,
      title: undefined,
    },
  ],
};
const basicMessages = [
  message("request", "Show the media.", "user"),
  imageMessage,
  videoMessage,
  message(
    "spacer",
    Array.from({ length: 120 }, (_, i) => `History paragraph ${i}.\n\n`).join("")
  ),
  message("tail", "End of conversation."),
];
const stressCount = Number(new URLSearchParams(location.search).get("images") ?? 0);
const messages = stressCount
  ? [
      message("request", "Read every image.", "user"),
      ...Array.from({ length: stressCount }, (_, index) => ({
        ...message(`image-${index}`, `Image ${index}`),
        attachments: [
          {
            ...imageMessage.attachments[0]!,
            fileName: `image-${index}.png`,
            localFileRef: `lfi1_${index.toString(36).padStart(43, "0")}`,
          },
        ],
      })),
    ]
  : basicMessages;
const noop = () => {};
function Fixture() {
  const [mounted, setMounted] = useState(true);
  Object.assign(window, {
    mediaRetention: { metrics, unmount: () => setMounted(false) },
  });
  return (
    <div style={{ display: "flex", height: "100vh" }}>
      {mounted ? (
        <ConversationThread
          api={api}
          conversationId="conversation"
          groupId="group"
          workspaceId="workspace"
          messages={messages}
          onDiscard={noop}
          onRetry={noop}
          onPreviewLocalFile={loadPreview}
        />
      ) : null}
    </div>
  );
}
const route = createRootRoute({ component: Fixture });
const router = createRouter({
  routeTree: route,
  history: createMemoryHistory({ initialEntries: ["/"] }),
});
createRoot(document.getElementById("root")!).render(<RouterProvider router={router} />);
