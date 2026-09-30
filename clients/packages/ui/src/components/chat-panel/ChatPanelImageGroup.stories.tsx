import type { Meta, StoryObj } from "@storybook/react-vite";
import { ResizeContainer } from "../../dev";
import {
  ChatPanel,
  ChatPanelAttachmentPill,
  ChatPanelImageGroup,
  downloadMediaSource,
  type ChatPanelImageGroupImage,
  type ChatPanelMediaDownloadCapability,
} from "../index";

const generatedImagePreview = new URL(
  "./assets/generated-image-preview.png",
  import.meta.url
).href;
const delayedImagePreview = new URL(
  "./assets/generated-image-preview.png?filmstrip-delay",
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

const downloadAction = (fileName: string) => ({
  capability: browserDownloadCapability,
  fileName,
});

const svgImage = (label: string, background: string, width: number, height: number) =>
  `data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">` +
      `<rect width="${width}" height="${height}" fill="${background}"/>` +
      `<circle cx="${width * 0.72}" cy="${height * 0.26}" r="${Math.min(width, height) * 0.12}" fill="rgba(255,255,255,0.55)"/>` +
      `<text x="${width / 2}" y="${height / 2}" fill="rgba(255,255,255,0.9)" font-family="sans-serif" font-size="${Math.min(width, height) * 0.14}" text-anchor="middle" dominant-baseline="middle">${label}</text>` +
      `</svg>`
  )}`;

const portrait = (label: string, background: string): ChatPanelImageGroupImage => ({
  alt: `${label} sample photo`,
  download: downloadAction(`${label.toLowerCase()}-sample-photo.svg`),
  src: svgImage(label, background, 600, 800),
});

const landscape = (label: string, background: string): ChatPanelImageGroupImage => ({
  alt: `${label} sample photo`,
  download: downloadAction(`${label.toLowerCase()}-sample-photo.svg`),
  src: svgImage(label, background, 800, 500),
});

const fiveImages: ChatPanelImageGroupImage[] = [
  {
    alt: "Generated editorial poster",
    download: downloadAction("generated-editorial-poster.png"),
    src: generatedImagePreview,
  },
  portrait("Harbor", "#5b7c99"),
  portrait("Forest", "#4f7350"),
  landscape("Desert", "#b3855b"),
  portrait("Night", "#3d4460"),
];

const meta = {
  title: "App components/Chat panel image group",
  component: ChatPanelImageGroup,
  parameters: {
    layout: "centered",
  },
  decorators: [
    // Mirrors the right-aligned user-message column so toggling demonstrates
    // the fixed top-right anchor instead of re-centering jumps.
    (Story) => (
      <div className="flex w-[640px] max-w-full flex-col items-end">
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof ChatPanelImageGroup>;

export default meta;
type Story = StoryObj<typeof meta>;

export const TwoImages: Story = {
  args: {
    images: [portrait("Harbor", "#5b7c99"), landscape("Desert", "#b3855b")],
  },
};

export const FiveImagesStack: Story = {
  args: {
    images: fiveImages,
  },
};

export const DelayedSecondImage: Story = {
  args: {
    images: [
      portrait("Ready", "#5b7c99"),
      landscape("Loaded", "#4f7350"),
      { alt: "Delayed sample photo", src: delayedImagePreview },
    ],
  },
};

export const PortraitLandscapeMix: Story = {
  args: {
    images: [
      portrait("One", "#5b7c99"),
      landscape("Two", "#b3855b"),
      portrait("Three", "#4f7350"),
      landscape("Four", "#8a5f7d"),
      portrait("Five", "#3d4460"),
      landscape("Six", "#736b52"),
      portrait("Seven", "#54707a"),
      landscape("Eight", "#7d5648"),
    ],
  },
};

export const ExpandedByDefault: Story = {
  args: {
    defaultExpanded: true,
    images: fiveImages,
  },
};

/**
 * Composite user message from the reference layout: the image stack sits above
 * a separate row of file pills and the text bubble, right-aligned with the
 * standard 8px column gap. Files never join the image layout, and only the
 * text bubble takes part in outgoing-message animations.
 */
export const CompositeMessage: Story = {
  args: {
    images: fiveImages,
  },
  render: (args) => (
    <div className="flex w-[720px] max-w-full flex-col items-end gap-md">
      <ChatPanelImageGroup {...args} />
      <div className="flex max-w-[540px] flex-wrap justify-end gap-md">
        <ChatPanelAttachmentPill attachment={{ id: "file-1", label: "Openai.pdf" }} />
        <ChatPanelAttachmentPill
          attachment={{ id: "file-2", label: "research-notes.docx" }}
        />
      </div>
      <div className="max-w-[450px] rounded-xl bg-markdown-bg-message px-lg py-md text-sm leading-5 text-markdown-text-primary">
        Using the attached screenshots as a reference, please do a full pass on the
        gallery layout and keep the files out of the image stack.
      </div>
    </div>
  ),
};

/** The group living inside the real chat panel via `ChatPanelMessage.images`. */
export const InChatPanel: Story = {
  args: {
    images: fiveImages,
  },
  parameters: {
    layout: "fullscreen",
  },
  render: (args) => (
    <ResizeContainer
      centered
      clipContent={false}
      defaultMode="relative"
      defaultRect={{ width: 720, height: 640 }}
      defaultResizable
      minHeight={320}
      minWidth={288}
    >
      <div className="size-full select-text">
        <ChatPanel
          messages={[
            {
              attachments: [
                { id: "file-1", label: "Openai.pdf" },
                { id: "file-2", label: "research-notes.docx" },
              ],
              content:
                "Using the attached screenshots as a reference, please do a full pass on the gallery layout and keep the files out of the image stack.",
              id: "user",
              images: args.images,
              kind: "user",
            },
            {
              content:
                "Reviewing the gallery layout now — the uploaded photos stay stacked and the files render as separate pills.",
              id: "assistant",
              kind: "assistant",
            },
          ]}
        />
      </div>
    </ResizeContainer>
  ),
};
