import { useState, type ReactNode } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, userEvent, waitFor, within } from "storybook/test";
import { ResizeContainer } from "../../dev";
import {
  AiInput,
  FileIcon,
  GithubProviderLogo,
  LinearProviderLogo,
  NotionProviderLogo,
  PaperclipIcon,
  PuzzleIcon,
  CubeIcon,
  createAiInputRichValue,
  taskStatusIcon,
  type AiInputAttachment,
  type AiInputMenuGroup,
  type AiInputMenuItem,
  type AiInputMenuRegistration,
  type AiInputRichValue,
} from "../index";

/** Two distinct fills so the staged-image preview has something to browse. */
const stagedImageSource = new URL(
  "../chat-panel/assets/generated-video-poster.png",
  import.meta.url
).href;
const stagedPosterSource = new URL(
  "../chat-panel/assets/generated-image-preview.png",
  import.meta.url
).href;

const sampleAttachments: AiInputAttachment[] = [
  {
    id: "image-1",
    type: "image",
    name: "Generated asset",
    thumbnailSrc: stagedImageSource,
  },
  {
    id: "image-2",
    type: "image",
    name: "Reference poster",
    thumbnailSrc: stagedPosterSource,
  },
  {
    id: "file-1",
    type: "file",
    name: "Openai",
    meta: "PDF",
  },
];

const manyAttachmentFiles = [
  ["Product requirements", "PDF"],
  ["Research notes", "DOCX"],
  ["Meeting transcript", "TXT"],
  ["Design system", "FIG"],
  ["Budget forecast", "XLSX"],
  ["Architecture overview", "PDF"],
  ["Launch checklist", "DOCX"],
  ["User interviews", "PDF"],
  ["Release notes", "MD"],
  ["Openai", "PDF"],
] as const;

const manyAttachments: AiInputAttachment[] = manyAttachmentFiles.map(
  ([name, meta], index): AiInputAttachment => ({
    id: `file-${index + 1}`,
    type: "file",
    name,
    meta,
  })
);

const designDnaDescription =
  'Extract, define, and apply design DNA across three dimensions: design system (tokens), design style (qualitative feel), and visual effects (Canvas, WebGL, 3D, particles, shaders, scroll effects, etc.). Use this skill when: (1) a user wants to see the full 3-dimension design structure/schema, (2) a user provides images, screenshots, or URLs of reference designs and wants them analyzed into a structured JSON profile covering all three dimensions, (3) a user has a Design DNA JSON and content and wants a design generated from it, or (4) any combination of these phases. Triggers on "design DNA", "extract design style", "analyze design".';

const richTextMenus: AiInputMenuRegistration[] = [
  {
    id: "skills",
    trigger: "/",
    label: "Skills",
    groups: [
      {
        id: "workspace-skills",
        label: "Skills",
        items: [
          {
            id: "image-gen",
            label: "image-gen",
            description: "Generate or edit images",
            icon: <CubeIcon />,
            descriptionPlacement: "inline",
          },
          {
            id: "design-skill",
            label: "Design Dna",
            description: designDnaDescription,
            icon: <CubeIcon />,
            descriptionPlacement: "inline",
          },
        ],
      },
    ],
  },
  {
    id: "plugins",
    trigger: "@",
    label: "Plugins",
    groups: [
      {
        id: "plugins",
        label: "Plugins",
        items: [
          {
            id: "codex",
            label: "codex",
            description: "Write and review code",
            icon: <PuzzleIcon />,
          },
          {
            id: "claude",
            label: "claude",
            description: "Analyze and write content",
            icon: <PuzzleIcon />,
          },
        ],
      },
    ],
  },
];

/** Figma 1292:12415 — the "@" panel with Add, Tasks, Routines, and Plugins. */
const mentionMenuRegistration = (
  overrides: { loading?: boolean; onAdd?: () => void } = {}
): AiInputMenuRegistration => ({
  id: "mentions",
  trigger: "@",
  label: "Mentions",
  maxItems: Number.POSITIVE_INFINITY,
  groups: [
    {
      id: "add",
      label: "Add",
      items: [
        {
          id: "add-files-or-folders",
          label: "Add files or folders",
          icon: <PaperclipIcon />,
          keywords: ["upload", "attach"],
          action: overrides.onAdd ?? (() => {}),
        },
      ],
    },
    {
      id: "tasks",
      label: "Tasks",
      ...(overrides.loading ? { status: "loading" as const } : {}),
      items: overrides.loading
        ? []
        : [
            {
              id: "task:cnv1_done",
              label: "Translate this sentence",
              icon: taskStatusIcon("done"),
              plainText: "[Translate this sentence](comma:task/cnv1_done)",
            },
            {
              id: "task:cnv1_running",
              label: "Summarize the Q3 report",
              icon: taskStatusIcon("in_progress"),
              plainText: "[Summarize the Q3 report](comma:task/cnv1_running)",
            },
          ],
    },
    {
      id: "routines",
      label: "Routines",
      ...(overrides.loading ? { status: "loading" as const } : {}),
      items: overrides.loading
        ? []
        : [
            {
              id: "routine:comma-151",
              label: "Comma-151",
              icon: <LinearProviderLogo />,
              plainText: "[Comma-151](https://linear.app/comma/issue/COMMA-151)",
            },
            {
              id: "routine:q3-plan",
              label: "The Q3 Plan",
              icon: <NotionProviderLogo />,
              plainText: "[The Q3 Plan](https://notion.so/q3-plan)",
            },
          ],
    },
    {
      id: "plugins",
      label: "Plugins",
      ...(overrides.loading ? { status: "loading" as const } : {}),
      items: overrides.loading
        ? []
        : [
            {
              id: "plugin:github",
              label: "GitHub",
              icon: <GithubProviderLogo />,
              plainText: "@github",
            },
            {
              id: "plugin:linear",
              label: "Linear",
              icon: <LinearProviderLogo />,
              plainText: "@linear",
            },
            {
              id: "plugin:notion",
              label: "Notion",
              icon: <NotionProviderLogo />,
              plainText: "@notion",
            },
          ],
    },
  ],
});

const longMentionMenuRegistration: AiInputMenuRegistration = {
  id: "mentions",
  trigger: "@",
  label: "Mentions",
  maxItems: Number.POSITIVE_INFINITY,
  groups: [
    {
      id: "tasks",
      label: "Tasks",
      items: Array.from({ length: 400 }, (_, index) => ({
        id: `task:cnv1_${index}`,
        label: `Task ${index + 1} — follow up on thread`,
        icon: taskStatusIcon(index % 3 === 0 ? "done" : "in_progress"),
        plainText: `[Task ${index + 1}](comma:task/cnv1_${index})`,
      })),
    },
  ],
};

const typeMentionTrigger = async (editor: HTMLElement, text: string) => {
  await userEvent.click(editor);
  await userEvent.keyboard(text);
};

const initialRichValue = createAiInputRichValue([
  { type: "text", text: "First generate the assets with " },
  {
    type: "token",
    instanceId: "skill-image-gen",
    menuId: "skills",
    itemId: "image-gen",
    trigger: "/",
    label: "image-gen",
    description: "Generate or edit images from a prompt and reference assets.",
    plainText: "/image-gen",
  },
  { type: "text", text: ", then use " },
  {
    type: "token",
    instanceId: "plugin-codex",
    menuId: "plugins",
    itemId: "codex",
    trigger: "@",
    label: "codex",
    description: "Write, review, and update code in the current workspace.",
    plainText: "@codex",
  },
  { type: "text", text: " to build it." },
]);

const initialSmallRichValue = createAiInputRichValue([
  {
    type: "token",
    instanceId: "skill-design-dna",
    menuId: "skills",
    itemId: "design-skill",
    trigger: "/",
    label: "Design Dna",
    description: designDnaDescription,
    plainText: "/design-skill",
  },
]);

const ComposerPreview = ({ children }: { children: ReactNode }) => (
  <ResizeContainer
    centered
    clipContent={false}
    defaultCenterMode
    defaultMode="pixel"
    defaultRect={{ width: 320, height: 520 }}
    defaultResizable
    minHeight={160}
    minWidth={288}
  >
    <div
      className="flex size-full select-text items-end"
      data-testid="ai-input-story-preview"
    >
      {children}
    </div>
  </ResizeContainer>
);

const expectPreviewWidthToken = (canvasElement: HTMLElement) => {
  const preview = within(canvasElement).getByTestId("ai-input-story-preview");
  const resizeContent = preview.closest<HTMLElement>('[data-slot="resize-content"]');
  const resizeViewport = preview.closest<HTMLElement>('[data-slot="resize-viewport"]');
  const resizeCanvas = preview.closest<HTMLElement>('[data-slot="resize-canvas"]');
  const rootStyle = getComputedStyle(canvasElement.ownerDocument.documentElement);
  const tokenWidth = Number.parseFloat(rootStyle.getPropertyValue("--container-xxs"));
  const previewWidth = preview.getBoundingClientRect().width;
  const expectedWidth = Math.min(tokenWidth, resizeCanvas?.clientWidth ?? tokenWidth);

  expect(resizeContent).not.toBeNull();
  expect(resizeViewport).not.toBeNull();
  expect(resizeCanvas).not.toBeNull();
  expect(getComputedStyle(resizeViewport!).overflow).toBe("visible");
  expect(resizeContent?.getBoundingClientRect().width).toBe(expectedWidth);
  expect(previewWidth).toBe(expectedWidth);
  expect(preview.firstElementChild).toHaveClass("shadow-xs");
  expect(preview.firstElementChild?.getBoundingClientRect().width).toBe(previewWidth);
  expect(resizeContent).toHaveAttribute("data-locked", "false");
};

const meta = {
  title: "App components/AI Input",
  component: AiInput,
  parameters: {
    layout: "fullscreen",
  },
} satisfies Meta<typeof AiInput>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(() =>
      createAiInputRichValue([])
    );
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={richTextMenus}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
        />
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    expectPreviewWidthToken(canvasElement);
  },
};

export const Small: Story = {
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(() =>
      createAiInputRichValue([])
    );
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={richTextMenus}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
          size="small"
        />
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    expectPreviewWidthToken(canvasElement);
  },
};

export const VoiceRecording: Story = {
  render: () => (
    <ComposerPreview>
      <AiInput onAttachPress={() => {}} onVoicePress={() => {}} size="small" />
    </ComposerPreview>
  ),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await userEvent.click(canvas.getByRole("button", { name: "Voice input" }));
    await waitFor(() => {
      expect(canvas.getByRole("img", { name: "Voice recording" })).toBeVisible();
      expect(canvas.getByText("0:00")).toBeVisible();
    });
  },
};

export const SmallWithAttachments: Story = {
  render: () => {
    const [attachments, setAttachments] =
      useState<AiInputAttachment[]>(sampleAttachments);

    return (
      <ComposerPreview>
        <AiInput
          attachments={attachments}
          onAttachPress={() => {}}
          onAttachmentRemove={(attachment) => {
            setAttachments((current) =>
              current.filter((item) => item.id !== attachment.id)
            );
          }}
          onVoicePress={() => {}}
          size="small"
        />
      </ComposerPreview>
    );
  },
};

export const PreviewAttachmentLifecycle: Story = {
  name: "Preview attachment lifecycle",
  render: () => {
    const [previewable, setPreviewable] = useState(true);
    const attachment: AiInputAttachment = {
      id: "lifecycle-image",
      name: "Lifecycle image",
      state: previewable ? "ready" : "loading",
      thumbnailSrc: stagedImageSource,
      type: "image",
    };

    return (
      <div className="flex min-h-screen flex-col gap-md p-xl">
        <div className="flex gap-sm">
          <button
            data-testid="make-preview-unavailable"
            onClick={() => setPreviewable(false)}
            type="button"
          >
            Make preview unavailable
          </button>
          <button
            data-testid="restore-preview"
            onClick={() => setPreviewable(true)}
            type="button"
          >
            Restore preview
          </button>
        </div>
        <ComposerPreview>
          <AiInput attachments={[attachment]} size="small" />
        </ComposerPreview>
      </div>
    );
  },
};

export const SmallWithTenAttachments: Story = {
  render: () => {
    const [attachments, setAttachments] =
      useState<AiInputAttachment[]>(manyAttachments);

    return (
      <ComposerPreview>
        <AiInput
          attachments={attachments}
          onAttachPress={() => {}}
          onAttachmentRemove={(attachment) => {
            setAttachments((current) =>
              current.filter((item) => item.id !== attachment.id)
            );
          }}
          onVoicePress={() => {}}
          size="small"
        />
      </ComposerPreview>
    );
  },
};

export const RichText: Story = {
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(initialRichValue);
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={richTextMenus}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
        />
      </ComposerPreview>
    );
  },
};

export const SmallRichText: Story = {
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(initialSmallRichValue);
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={richTextMenus}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
          size="small"
        />
      </ComposerPreview>
    );
  },
};

export const MentionMenu: Story = {
  name: "Mention menu (@)",
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(() =>
      createAiInputRichValue([])
    );
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={[mentionMenuRegistration()]}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
        />
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const editor = canvas.getByRole("textbox", { name: "AI prompt" });
    await typeMentionTrigger(editor, "@");

    const panel = await canvas.findByRole("listbox", { name: "Mentions" });
    // The panel fades in from opacity 0; visibility settles with the enter
    // transition, so these assertions wait it out.
    await waitFor(() => expect(panel).toBeVisible());
    expect(canvas.getByText("Add")).toBeVisible();
    expect(canvas.getByText("Tasks")).toBeVisible();
    expect(canvas.getByText("Routines")).toBeVisible();
    expect(canvas.getByText("Plugins")).toBeVisible();
    expect(canvas.getByRole("option", { name: "Add files or folders" })).toBeVisible();
    expect(canvas.getByRole("option", { name: "Comma-151" })).toBeVisible();
    expect(canvas.getByRole("option", { name: "GitHub" })).toBeVisible();
  },
};

export const MentionMenuSearching: Story = {
  name: "Mention menu searching",
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(() =>
      createAiInputRichValue([])
    );
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={[mentionMenuRegistration({ loading: true })]}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
        />
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const editor = canvas.getByRole("textbox", { name: "AI prompt" });
    await typeMentionTrigger(editor, "@tra");

    await canvas.findByRole("listbox", { name: "Mentions" });
    const searching = await canvas.findByTestId("ai-input-menu-searching");
    expect(searching).toHaveTextContent("Searching...");
  },
};

export const MentionMenuNoResults: Story = {
  name: "Mention menu no results",
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(() =>
      createAiInputRichValue([])
    );
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={[mentionMenuRegistration()]}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
        />
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const editor = canvas.getByRole("textbox", { name: "AI prompt" });
    await typeMentionTrigger(editor, "@zzzz");

    await canvas.findByRole("listbox", { name: "Mentions" });
    const empty = await canvas.findByTestId("ai-input-menu-no-results");
    expect(empty).toHaveTextContent("No results");
  },
};

/**
 * A Drive with four folders, newest file first: the menu shows five rows and
 * "View more"; the panel behind it lists every folder with its own search.
 */
const driveMentionMenuRegistration = (
  overrides: { empty?: boolean } = {}
): AiInputMenuRegistration => {
  const folders = [
    ["Design / handoff", ["home-v4.fig", "rail-spec.pdf", "tokens.json", "icons.zip"]],
    ["Recordings", ["standup-0904.wav", "retro.m4a", "interview-cut.mp4"]],
    ["Folder A / drafts / q3", ["q3-plan.md", "budget.xlsx", "okrs.docx", "cover.png"]],
    ["Shared", ["launch-cut.mp4", "press-kit.zip", "brand-guide.pdf", "notes.txt"]],
  ] as const;
  let modifiedAt = Date.now();
  const entries = folders.map(([label, names], folderIndex) => ({
    label,
    items: names.map((name): AiInputMenuItem => {
      modifiedAt -= 37 * 60_000;
      return {
        id: `drive:${folderIndex}/${name}`,
        label: name,
        description: `${Math.round((Date.now() - modifiedAt) / 60_000)}m ago`,
        icon: <FileIcon />,
        keywords: [label],
        action: () => {},
      };
    }),
  }));
  const sections: AiInputMenuGroup[] = entries.map(({ items, label }, folderIndex) => ({
    id: `drive/${folderIndex}`,
    label,
    items,
  }));
  const recent = entries.flatMap(({ items, label }) =>
    items.map((item) => ({ ...item, description: label }))
  );
  return {
    id: "mentions",
    trigger: "@",
    label: "Mentions",
    maxItems: Number.POSITIVE_INFINITY,
    groups: [
      {
        id: "add",
        label: "Add",
        items: [
          {
            id: "add-files-or-folders",
            label: "Add files or folders",
            icon: <PaperclipIcon />,
            action: () => {},
          },
        ],
      },
      {
        id: "drive",
        label: "Drive",
        limit: 5,
        items: overrides.empty ? [] : recent,
        browse: {
          label: "View more",
          title: "Drive",
          searchPlaceholder: "Search files",
          emptyLabel: "No files",
          noResultsLabel: "No results found",
          groups: overrides.empty ? [] : sections,
        },
      },
      {
        id: "plugins",
        label: "Plugins",
        items: [
          {
            id: "plugin:github",
            label: "GitHub",
            icon: <GithubProviderLogo />,
            plainText: "@github",
          },
        ],
      },
    ],
  };
};

export const MentionMenuDrive: Story = {
  name: "Mention menu Drive browse",
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(() =>
      createAiInputRichValue([])
    );
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={[driveMentionMenuRegistration()]}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
        />
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const editor = canvas.getByRole("textbox", { name: "AI prompt" });
    await typeMentionTrigger(editor, "@");

    const panel = await canvas.findByRole("listbox", { name: "Mentions" });
    await waitFor(() => expect(panel).toBeVisible());
    // Five newest files, then the door to the rest.
    expect(
      canvas.getByRole("option", { name: "home-v4.fig Design / handoff" })
    ).toBeVisible();
    expect(canvas.queryByRole("option", { name: /interview-cut/ })).toBeNull();
    const viewMore = canvas.getByRole("option", { name: "View more" });
    expect(viewMore).toBeVisible();

    // ArrowRight on "View more" steps into the Drive panel.
    await userEvent.keyboard("{ArrowDown}".repeat(6));
    await waitFor(() => expect(viewMore).toHaveAttribute("aria-selected", "true"));
    await userEvent.keyboard("{ArrowRight}");
    const search = await canvas.findByRole("combobox", { name: "Drive" });
    await waitFor(() => expect(search).toHaveFocus());
    // The panel paints its sections a frame after the search takes focus, so
    // the folder heading is waited for rather than read once.
    await waitFor(() => expect(canvas.getByText("Recordings")).toBeVisible());

    await userEvent.keyboard("q3");
    await waitFor(() =>
      expect(canvas.getByRole("option", { name: /q3-plan/ })).toHaveAttribute(
        "aria-selected",
        "true"
      )
    );
  },
};

export const MentionMenuDriveEmpty: Story = {
  name: "Mention menu Drive empty",
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(() =>
      createAiInputRichValue([])
    );
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={[driveMentionMenuRegistration({ empty: true })]}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
        />
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const editor = canvas.getByRole("textbox", { name: "AI prompt" });
    await typeMentionTrigger(editor, "@");
    await canvas.findByRole("listbox", { name: "Mentions" });
    await userEvent.click(canvas.getByRole("option", { name: "View more" }));
    const empty = await canvas.findByTestId("ai-input-menu-browse-empty");
    expect(empty).toHaveTextContent("No files");
  },
};

export const MentionMenuLongList: Story = {
  name: "Mention menu long list",
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(() =>
      createAiInputRichValue([])
    );
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={[longMentionMenuRegistration]}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
        />
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const editor = canvas.getByRole("textbox", { name: "AI prompt" });
    await typeMentionTrigger(editor, "@");

    await canvas.findByRole("listbox", { name: "Mentions" });
    // 400 tasks exist, but the panel lazily renders only the first chunk;
    // scrolling commits more without ever mounting the whole list.
    const options = canvas.getAllByRole("option");
    expect(options.length).toBeLessThanOrEqual(48);
    expect(options.length).toBeGreaterThan(0);
  },
};

export const Filled: Story = {
  render: () => {
    const [value, setValue] = useState(
      "Based on the first example we discussed yesterday, generate the assets and build it."
    );
    const [attachments, setAttachments] =
      useState<AiInputAttachment[]>(sampleAttachments);

    return (
      <ComposerPreview>
        <AiInput
          attachments={attachments}
          onAttachPress={() => {}}
          onAttachmentRemove={(attachment) => {
            setAttachments((current) =>
              current.filter((item) => item.id !== attachment.id)
            );
          }}
          onValueChange={setValue}
          onVoicePress={() => {}}
          value={value}
        />
      </ComposerPreview>
    );
  },
};

export const Disabled: Story = {
  render: () => (
    <ComposerPreview>
      <AiInput
        attachments={sampleAttachments}
        defaultValue="Waiting for access before this can be sent."
        disabled
      />
    </ComposerPreview>
  ),
};

export const TextEditContextMenu: Story = {
  name: "Text edit context menu",
  render: () => {
    const [value, setValue] = useState<AiInputRichValue>(() =>
      createAiInputRichValue([{ type: "text", text: "Hello world from Comma" }])
    );
    return (
      <ComposerPreview>
        <AiInput
          menuRegistrations={richTextMenus}
          onAttachPress={() => {}}
          onRichValueChange={setValue}
          onVoicePress={() => {}}
          richValue={value}
        />
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const editor = canvas.getByRole("textbox", { name: "AI prompt" });

    editor.focus();
    const textNode = editor.firstChild;
    if (textNode) {
      const selection = canvasElement.ownerDocument.defaultView?.getSelection();
      const range = canvasElement.ownerDocument.createRange();
      range.setStart(textNode, 0);
      range.setEnd(textNode, Math.min(5, textNode.textContent?.length ?? 0));
      selection?.removeAllRanges();
      selection?.addRange(range);
    }

    const contextMenuEvent = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: 160,
      clientY: 40,
    });
    editor.dispatchEvent(contextMenuEvent);

    expect(contextMenuEvent.defaultPrevented).toBe(true);
    await waitFor(() =>
      expect(editor).toHaveAttribute("data-context-menu-open", "true")
    );
    expect(await page.findByRole("menuitem", { name: "Copy" })).toBeInTheDocument();
    expect(page.getByRole("menuitem", { name: "Paste" })).toBeInTheDocument();
    expect(page.getByRole("menuitem", { name: "Cut" })).toBeInTheDocument();
    expect(page.getByRole("menuitem", { name: "Select All" })).toBeInTheDocument();

    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(page.queryByRole("menu")).not.toBeInTheDocument());
    expect(editor).toHaveAttribute("data-context-menu-open", "false");
    expect(editor).toHaveFocus();
  },
};

export const TextEditContextMenuKeyboard: Story = {
  name: "Text edit context menu (keyboard)",
  tags: ["!dev", "!autodocs"],
  render: () => {
    const [value, setValue] = useState("Select this prompt and open the edit menu");
    return (
      <ComposerPreview>
        <AiInput
          onAttachPress={() => {}}
          onValueChange={setValue}
          onVoicePress={() => {}}
          value={value}
        />
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const textarea = canvas.getByRole("textbox", {
      name: "AI prompt",
    }) as HTMLTextAreaElement;

    textarea.focus();
    textarea.setSelectionRange(0, 6);
    await userEvent.keyboard("{Shift>}{F10}{/Shift}");

    expect(await page.findByRole("menuitem", { name: "Copy" })).toHaveFocus();
    expect(textarea).toHaveAttribute("data-context-menu-open", "true");

    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(page.queryByRole("menu")).not.toBeInTheDocument());
    expect(textarea).toHaveFocus();
    expect(textarea).toHaveAttribute("data-context-menu-open", "false");
  },
};

export const DropTarget: Story = {
  render: () => {
    const [droppedNames, setDroppedNames] = useState<string[]>([]);
    return (
      <ComposerPreview>
        <div className="flex w-full flex-col gap-md">
          <AiInput
            onAccessPress={() => {}}
            onAttachPress={() => {}}
            onDropFiles={(dataTransfer) => {
              setDroppedNames(Array.from(dataTransfer.files).map((file) => file.name));
            }}
            onVoicePress={() => {}}
            showAccessButton
            value={droppedNames.length > 0 ? `Dropped: ${droppedNames.join(", ")}` : ""}
          />
        </div>
      </ComposerPreview>
    );
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const shell = canvas.getByTestId("ai-input-shell");
    const textarea = canvas.getByRole("textbox", { name: "AI prompt" });

    const dataTransfer = new DataTransfer();
    dataTransfer.items.add(
      new File(["hello"], "story-note.txt", { type: "text/plain" })
    );
    shell.dispatchEvent(
      new DragEvent("dragenter", {
        bubbles: true,
        cancelable: true,
        dataTransfer,
      })
    );

    await waitFor(() => expect(shell).toHaveAttribute("data-drop-active", "true"));
    const overlay = canvas.getByTestId("ai-input-drop-overlay");
    expect(overlay).toHaveAttribute("data-drop-active", "true");
    expect(overlay).toHaveTextContent("Drop anything here");
    expect(overlay).toHaveTextContent("Docs, images, videos and more");
    expect(shell.className).toMatch(/shadow-xs/);
    expect(shell.className).not.toMatch(/shadow-focus-brand/);
    expect(textarea).toHaveAttribute("placeholder", "Do anything");
    expect(canvas.getByRole("button", { name: "Add attachment" })).toBeDisabled();
    expect(canvas.getByRole("button", { name: "Full-access" })).toBeDisabled();
    expect(canvas.getByRole("button", { name: "Voice input" })).toBeDisabled();
  },
};
