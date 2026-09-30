import type { Meta, StoryObj } from "@storybook/react-vite";
import { useMemo, useState, type ReactNode } from "react";
import { ResizeContainer } from "../../dev";
import {
  Button,
  ChatPanelAudio,
  ChatPanelFile,
  ChatPanelVideo,
  Tooltip,
  downloadMediaSource,
  mediaControlShortcuts,
  resolveMediaFullWindowShortcut,
  type ChatPanelFileOpenInAction,
  type ChatPanelMediaDownloadAction,
  type ChatPanelMediaDownloadCapability,
} from "../index";

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

const generatedVideoDownload = {
  capability: browserDownloadCapability,
  fileName: "generated-video-preview.webm",
  fileSize: "4.8MB",
} satisfies ChatPanelMediaDownloadAction;

const MediaPreview = ({ children }: { children: ReactNode }) => (
  <ResizeContainer
    centered
    clipContent={false}
    defaultMode="relative"
    defaultRect={{ width: 720, height: 420 }}
    defaultResizable
    minHeight={240}
    minWidth={288}
  >
    <div className="flex size-full items-center justify-center p-3xl">{children}</div>
  </ResizeContainer>
);

const meta = {
  title: "App components/Chat panel media",
  parameters: {
    layout: "fullscreen",
  },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

export const Audio: Story = {
  render: () => (
    <MediaPreview>
      <div className="w-full max-w-[540px]">
        <ChatPanelAudio download={generatedAudioDownload} src={generatedAudioPreview} />
      </div>
    </MediaPreview>
  ),
};

export const Video: Story = {
  render: () => (
    <MediaPreview>
      <div className="w-full max-w-[540px]">
        <ChatPanelVideo
          alt="A chill rap video cover"
          download={generatedVideoDownload}
          poster={generatedVideoPoster}
          src={generatedVideoPreview}
        />
      </div>
    </MediaPreview>
  ),
};

export const ControlShortcuts: Story = {
  render: () => (
    <div className="flex min-h-[520px] flex-col items-center gap-5xl bg-main-panel-bg p-5xl">
      <div className="flex flex-wrap items-start justify-center gap-5xl">
        <Tooltip
          defaultOpen
          delay={0}
          content="Play"
          placement="top"
          shortcut={mediaControlShortcuts.play}
        >
          <Button hierarchy="tertiary-gray">Play</Button>
        </Tooltip>
        <Tooltip
          defaultOpen
          delay={0}
          content="Mute"
          placement="top"
          shortcut={mediaControlShortcuts.mute}
        >
          <Button hierarchy="tertiary-gray">Mute</Button>
        </Tooltip>
        <Tooltip
          defaultOpen
          delay={0}
          content="Playback speed"
          placement="top"
          shortcut={mediaControlShortcuts.playbackSpeed}
        >
          <Button hierarchy="tertiary-gray">Speed</Button>
        </Tooltip>
        <Tooltip
          defaultOpen
          delay={0}
          content="Download"
          placement="top"
          suffix="1.2MB"
        >
          <Button hierarchy="tertiary-gray">Download</Button>
        </Tooltip>
        <Tooltip
          defaultOpen
          delay={0}
          content="Full window"
          placement="top"
          shortcut={resolveMediaFullWindowShortcut().keys}
        >
          <Button hierarchy="tertiary-gray">Video</Button>
        </Tooltip>
      </div>
      <div className="flex w-full max-w-[540px] flex-col gap-3xl">
        <ChatPanelAudio download={generatedAudioDownload} src={generatedAudioPreview} />
        <ChatPanelVideo
          alt="A chill rap video cover"
          download={generatedVideoDownload}
          poster={generatedVideoPoster}
          src={generatedVideoPreview}
        />
      </div>
    </div>
  ),
};

const FileActionsPreview = () => {
  const [result, setResult] = useState("");
  // Storybook fixtures exercise the presentation without impersonating a native bridge.
  const openIn = useMemo<ChatPanelFileOpenInAction>(
    () => ({
      listApplications: async () => [
        { id: "preview", name: "Preview", isDefault: true },
        { id: "reader", name: "Adobe Acrobat Reader" },
        { id: "photoshop", name: "Adobe Photoshop 2023" },
        { id: "illustrator", name: "Adobe Illustrator 2022" },
      ],
      openApplication: async (id) => {
        setResult(`Open application: ${id}`);
      },
      reveal: {
        label: "Show in Finder",
        run: async () => {
          setResult("Show in Finder");
        },
      },
    }),
    []
  );
  return (
    <div className="flex min-h-[460px] flex-col items-center gap-xl bg-main-panel-bg p-3xl">
      <div className="w-full max-w-[640px]">
        <ChatPanelFile
          fileName="Apple-公司简介.pdf"
          fileSize={482400}
          mimeType="application/pdf"
          onPreview={() => setResult("Preview file")}
          openIn={openIn}
        />
      </div>
      <output aria-live="polite" className="text-xs text-tertiary">
        {result}
      </output>
    </div>
  );
};

export const FileActions: Story = { render: () => <FileActionsPreview /> };
