import "@comma/ui/styles.css";

import "./styles.css";

import {
  ChatPanel,
  ChatPanelAudio,
  ChatPanelFile,
  ChatPanelImage,
  ChatPanelVideo,
  downloadMediaSource,
  type ChatPanelMediaDownloadCapability,
  type ChatPanelMessage,
} from "@comma/ui";
import { StrictMode, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

const mediaArtwork =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='960' height='540' viewBox='0 0 960 540'%3E%3Crect width='960' height='540' fill='%230f40f2'/%3E%3Ccircle cx='720' cy='180' r='210' fill='%231a1b1e'/%3E%3Ctext x='56' y='440' fill='white' font-size='64' font-family='sans-serif'%3EGenerated media%3C/text%3E%3C/svg%3E";
const audioSource = new URL(
  "../../../../../packages/ui/src/components/chat-panel/assets/generated-audio-preview.mp3",
  import.meta.url
).href;
const videoSource = new URL(
  "../../../../../packages/ui/src/components/chat-panel/assets/generated-video-preview.webm",
  import.meta.url
).href;
function ChatPanelMediaFixture() {
  const [copyCount, setCopyCount] = useState(0);
  const [sourceRevision, setSourceRevision] = useState(0);
  const fixtureParameters = useMemo(
    () => new URLSearchParams(window.location.search),
    []
  );
  const crossOriginAudioSource = fixtureParameters.get("crossOriginAudio");
  const downloadEndpoint = fixtureParameters.get("downloadEndpoint");
  const configuredDownloadFailures = Number.parseInt(
    fixtureParameters.get("downloadFailures") ?? "0",
    10
  );
  const configuredDownloadDelay = Number.parseInt(
    fixtureParameters.get("downloadDelay") ?? "0",
    10
  );
  const downloadDelay = Number.isFinite(configuredDownloadDelay)
    ? Math.max(0, configuredDownloadDelay)
    : 0;
  const remainingDownloadFailuresRef = useRef(
    Number.isFinite(configuredDownloadFailures)
      ? Math.max(0, configuredDownloadFailures)
      : 0
  );
  const downloadAttemptsRef = useRef(0);
  const currentAudioSource =
    crossOriginAudioSource ?? `${audioSource}?revision=${sourceRevision}`;
  const currentVideoSource = `${videoSource}?revision=${sourceRevision}`;
  const downloadCapability = useMemo(
    () =>
      ({
        async execute(request) {
          downloadAttemptsRef.current += 1;
          (
            window as typeof window & {
              chatPanelMediaDownloadAttempts?: number;
            }
          ).chatPanelMediaDownloadAttempts = downloadAttemptsRef.current;
          if (downloadDelay > 0) {
            await new Promise((resolve) => setTimeout(resolve, downloadDelay));
          }
          if (remainingDownloadFailuresRef.current > 0) {
            remainingDownloadFailuresRef.current -= 1;
            return {
              code: "network",
              retryable: true,
              status: "error",
            };
          }

          const source = downloadEndpoint ?? request.source;
          if (!source) {
            return { code: "unsupported", retryable: false, status: "error" };
          }

          try {
            await downloadMediaSource({ fileName: request.fileName, source });
            return { status: "success" };
          } catch {
            return {
              code: "network",
              retryable: true,
              status: "error",
            };
          }
        },
      }) satisfies ChatPanelMediaDownloadCapability,
    [downloadDelay, downloadEndpoint]
  );
  const messages = useMemo<ChatPanelMessage[]>(
    () => [
      {
        id: "generated-media",
        kind: "assistant",
        content: (
          <div className="flex flex-col gap-xl">
            <ChatPanelAudio
              download={{
                capability: downloadCapability,
                fileName: "generated-audio-preview.mp3",
              }}
              src={currentAudioSource}
            />
            <ChatPanelImage
              alt="Generated artwork"
              download={{
                capability: downloadCapability,
                fileName: "generated-image.svg",
              }}
              onCopy={() => setCopyCount((count) => count + 1)}
              src={mediaArtwork}
            />
            <ChatPanelFile
              fileName="launch-plan.key"
              fileSize="3.5MB"
              typeLabel="KEY"
            />
            <ChatPanelVideo
              alt="Generated video artwork"
              download={{
                capability: downloadCapability,
                fileName: "generated-video-preview.webm",
              }}
              poster={mediaArtwork}
              src={currentVideoSource}
            />
          </div>
        ),
      },
    ],
    [currentAudioSource, currentVideoSource, downloadCapability]
  );

  return (
    <main>
      <ChatPanel
        className="h-[1008px] w-[1134px]"
        messages={messages}
        title="Generated media fixture with a deliberately long responsive title"
      />
      <button
        onClick={() => setSourceRevision((revision) => revision + 1)}
        type="button"
      >
        Refresh media sources
      </button>
      <output data-testid="copy-count">Copy count: {copyCount}</output>
      <output data-testid="source-revision">Source revision: {sourceRevision}</output>
    </main>
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <ChatPanelMediaFixture />
  </StrictMode>
);
