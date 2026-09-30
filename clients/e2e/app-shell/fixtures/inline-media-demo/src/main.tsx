import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import { ChatPanelImage, ChatPanelVideo } from "@comma/ui";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

const svg = (width: number, height: number, fill: string, label: string) =>
  `data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><rect width="${width}" height="${height}" fill="${fill}"/><text x="24" y="${Math.min(60, height - 20)}" fill="white" font-size="28" font-family="sans-serif">${label}</text></svg>`
  )}`;

const panoramaArtwork = svg(1200, 200, "#0f40f2", "panorama 1200x200");
const posterArtwork = svg(300, 1200, "#111827", "poster 300x1200");
const videoSource = new URL(
  "../../../../../packages/ui/src/components/chat-panel/assets/generated-video-preview.webm",
  import.meta.url
).href;

function InlineMediaDemo() {
  const params = new URLSearchParams(window.location.search);
  const width = Number.parseInt(params.get("bubbleWidth") ?? "640", 10);
  return (
    <main style={{ padding: "24px" }}>
      <article className="comma-chat-message-assistant" data-testid="demo-message">
        <div className="comma-chat-assistant-response-body">
          <p>Here is the run output.</p>
          <div className="comma-chat-attachments" style={{ width: `${width}px` }}>
            <div className="comma-chat-inline-images">
              <ChatPanelImage
                alt="panorama.png"
                className="comma-chat-inline-image"
                src={panoramaArtwork}
              />
              <ChatPanelImage
                alt="poster.png"
                className="comma-chat-inline-image"
                src={posterArtwork}
              />
            </div>
            <div className="comma-chat-inline-video-frame">
              <ChatPanelVideo
                alt="clip.webm"
                className="comma-chat-inline-video"
                poster=""
                previewTitle="clip.webm"
                src={videoSource}
              />
            </div>
          </div>
        </div>
      </article>
      {params.has("sharedControls") ? (
        <section data-testid="shared-media-controls">
          <ChatPanelImage alt="Shared image" src={panoramaArtwork} />
          <ChatPanelVideo alt="Shared video" poster="" src={videoSource} />
        </section>
      ) : null}
    </main>
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <InlineMediaDemo />
  </StrictMode>
);
