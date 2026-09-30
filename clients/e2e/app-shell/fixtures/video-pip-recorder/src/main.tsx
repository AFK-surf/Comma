import "@comma/ui/styles.css";

import {
  ChatPanelVideo,
  ChatPanelVideoPictureInPictureProvider,
  DraggableRecorder,
  MeetingRecordingBlock,
  ScrollArea,
} from "@comma/ui";
import { StrictMode, useState } from "react";
import { createRoot } from "react-dom/client";

const videoSource = new URL(
  "../../../../../packages/ui/src/components/chat-panel/assets/generated-video-preview.webm",
  import.meta.url
).href;
const poster =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='1112' height='642'%3E%3Crect width='1112' height='642' fill='%230f40f2'/%3E%3C/svg%3E";

const idle = () => undefined;

/**
 * The app shell around a chat video and a live recording: a rail, then the
 * content surface (its own stacking context, like `.comma-content`) holding the
 * route area and the recorder. Stop ends the recording like the host does.
 */
function VideoPictureInPictureRecorderFixture() {
  const [area, setArea] = useState<HTMLDivElement | null>(null);
  const [recording, setRecording] = useState(true);
  return (
    <div style={{ display: "flex", height: "100vh" }}>
      <nav aria-label="Rail" style={{ flex: "none", width: 200 }} />
      <section
        style={{
          containerType: "inline-size",
          display: "flex",
          flex: 1,
          minWidth: 0,
          overflow: "clip",
          position: "relative",
          zIndex: 1,
        }}
      >
        <ChatPanelVideoPictureInPictureProvider containment={area}>
          <div
            data-testid="route-area"
            ref={setArea}
            style={{ display: "flex", flex: 1, minHeight: 0, minWidth: 0 }}
          >
            <ScrollArea className="min-h-0 flex-1" data-testid="thread">
              <div style={{ padding: "240px 24px 2400px" }}>
                <ChatPanelVideo
                  alt="Walkthrough"
                  poster={poster}
                  previewTitle="Walkthrough"
                  src={videoSource}
                />
              </div>
            </ScrollArea>
          </div>
          {recording && area ? (
            <DraggableRecorder containment={area} label="Meeting recorder">
              <MeetingRecordingBlock
                level={0.4}
                onPause={idle}
                onResume={idle}
                onStop={() => setRecording(false)}
                paused={false}
              />
            </DraggableRecorder>
          ) : null}
        </ChatPanelVideoPictureInPictureProvider>
      </section>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <VideoPictureInPictureRecorderFixture />
  </StrictMode>
);
