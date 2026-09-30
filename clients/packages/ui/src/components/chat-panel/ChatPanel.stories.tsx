import type { Meta, StoryObj } from "@storybook/react-vite";
import type { ReactNode } from "react";
import { ResizeContainer } from "../../dev";
import {
  ChatPanel,
  ChatPanelAudio,
  ChatPanelFile,
  ChatPanelImage,
  ChatPanelVideo,
  downloadMediaSource,
  type ChatPanelMediaDownloadAction,
  type ChatPanelMediaDownloadCapability,
  type ChatPanelMessage,
} from "../index";
const generatedImagePreview = new URL(
  "./assets/generated-image-preview.png",
  import.meta.url
).href;
const generatedAudioPreview = new URL(
  "./assets/generated-audio-preview.mp3",
  import.meta.url
).href;
const generatedVideoPoster = new URL(
  "./assets/generated-video-poster.png",
  import.meta.url
).href;
const generatedVideoPreview = new URL(
  "./assets/generated-video-preview.webm",
  import.meta.url
).href;

const browserDownloadCapability = {
  async execute(request) {
    // Media cards always address their bytes by URL; the file card is the one
    // downloadable whose capability closes over its own source instead.
    if (!request.source) {
      return { code: "unsupported", retryable: false, status: "error" };
    }
    try {
      await downloadMediaSource({ ...request, source: request.source });
      return { status: "success" };
    } catch {
      return {
        code: "network",
        retryable: true,
        status: "error",
      };
    }
  },
} satisfies ChatPanelMediaDownloadCapability;

const generatedAudioDownload = {
  capability: browserDownloadCapability,
  fileName: "generated-audio-preview.mp3",
  fileSize: "1.2MB",
} satisfies ChatPanelMediaDownloadAction;

const generatedImageDownload = {
  capability: browserDownloadCapability,
  fileName: "generated-image-preview.png",
  fileSize: "840KB",
} satisfies ChatPanelMediaDownloadAction;

const generatedVideoDownload = {
  capability: browserDownloadCapability,
  fileName: "generated-video-preview.webm",
  fileSize: "4.8MB",
} satisfies ChatPanelMediaDownloadAction;

const meta = {
  title: "App components/Chat panel",
  component: ChatPanel,
  parameters: {
    layout: "fullscreen",
  },
} satisfies Meta<typeof ChatPanel>;

export default meta;
type Story = StoryObj<typeof meta>;

const ChatPanelPreview = ({ children }: { children: ReactNode }) => (
  <ResizeContainer
    centered
    clipContent={false}
    defaultMode="relative"
    defaultRect={{ width: 720, height: 640 }}
    defaultResizable
    minHeight={320}
    minWidth={288}
  >
    <div className="size-full select-text">{children}</div>
  </ResizeContainer>
);

export const Default: Story = {
  render: () => (
    <ChatPanelPreview>
      <ChatPanel />
    </ChatPanelPreview>
  ),
};

const generatedMediaMessages: ChatPanelMessage[] = [
  {
    id: "request",
    kind: "user",
    content:
      "Create an audio summary, a cover image, the source document, and a short video.",
  },
  {
    id: "generated-media",
    kind: "assistant",
    content: (
      <div className="flex w-full flex-col gap-xl">
        <p className="m-0">Here are the generated assets.</p>
        <ChatPanelAudio download={generatedAudioDownload} src={generatedAudioPreview} />
        <ChatPanelImage
          alt="A blue editorial poster for Victor Narrow"
          download={generatedImageDownload}
          src={generatedImagePreview}
        />
        <ChatPanelFile
          fileName="research-notes.docx"
          fileSize={2 * 1024 * 1024}
          mimeType="application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        />
        <ChatPanelVideo
          alt="A chill rap video cover"
          download={generatedVideoDownload}
          poster={generatedVideoPoster}
          src={generatedVideoPreview}
        />
      </div>
    ),
  },
];

export const GeneratedMedia: Story = {
  render: () => (
    <ChatPanelPreview>
      <ChatPanel
        messages={generatedMediaMessages}
        subtitle="Mac mini"
        title="Generate launch assets"
      />
    </ChatPanelPreview>
  ),
};
