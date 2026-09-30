import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { Pane } from "tweakpane";
import { Button } from "../Button";
import { Slider } from "../slider";
import { Toggle } from "../toggle";
import { createMarkdownStreamDocumentNodes, MarkdownStream } from "./MarkdownStream";

const comprehensiveMarkdown = [
  "# Streaming Markdown Fixture",
  "",
  "Comma renders **assistant output** while it is still arriving. This fixture covers _emphasis_, **strong text**, ~~deleted text~~, ==highlighted text==, ++inserted text++, `inlineCode()`, ~subscript~, and ^superscript^.",
  "",
  "Visit [Comma](https://comma.ai), jump to [the table](#tables), or mail [support](mailto:support@example.com). Emoji aliases: :sparkles: :rocket:.",
  "",
  "Hard break follows.  ",
  "This line starts after a Markdown hard break.",
  "",
  "![Markdown preview image](https://placehold.co/640x180/png?text=Comma+Markdown+Stream)",
  "",
  "> Streaming markdown should stay readable even when a block is incomplete.",
  ">",
  "> Nested **formatting** and `inline code` still render inside blockquotes.",
  "",
  "## Lists",
  "",
  "- Plain unordered item",
  "- Item with **bold**, _italic_, and `code`",
  "  - Nested child item",
  "- [x] Completed task",
  "- [ ] Pending task",
  "",
  "1. First ordered item",
  "2. Second ordered item",
  "3. Third ordered item",
  "",
  "Term",
  ": Definition list content with **nested emphasis**.",
  "",
  "Renderer",
  ": A scoped React component map layered over Markstream nodes.",
  "",
  "::: warning Streaming edge",
  "Partially typed block containers should stay stable while text is arriving.",
  ":::",
  "",
  "## Tables",
  "",
  "| Node | Owner |",
  "| --- | --- |",
  "| Parser | Markstream |",
  "| Styling | Comma UI |",
  "| Animation | Blur stream |",
  "",
  "---",
  "",
  "## Code",
  "",
  "```tsx",
  "type Status = 'streaming' | 'done'",
  "",
  "export function MarkdownStatus({ status }: { status: Status }) {",
  "  return <span data-status={status}>Ready</span>",
  "}",
  "```",
  "",
  "```json",
  "{",
  '  "renderer": "markstream-react",',
  '  "styleOwner": "Comma UI",',
  '  "streaming": true',
  "}",
  "```",
  "",
  "```diff",
  "- import Streamdown from 'streamdown'",
  "+ import { MarkdownStream } from '@comma/ui'",
  "```",
  "",
  "```mermaid",
  "flowchart TD",
  "  Start[Token arrives] --> Parse[Parse streaming markdown]",
  "  Parse --> Render[Render Comma nodes]",
  "  Render --> Animate[Blur in new text]",
  "```",
  "",
  "```d2",
  "direction: right",
  "SSE -> Parser: chunk",
  "Parser -> Renderer: nodes",
  "Renderer -> UI: animated spans",
  "```",
  "",
  "```infographic",
  "title: Streaming renderer",
  "steps: Parse, Render, Animate",
  "```",
  "",
  "## Math and HTML",
  "",
  "Inline math $E = mc^2$ and block math:",
  "",
  "$$",
  "\\int_0^1 x^2 dx = \\frac{1}{3}",
  "$$",
  "",
  "Raw HTML is escaped by default: <kbd>⌘</kbd><kbd>K</kbd>.",
  "",
  "Footnotes work during streaming too.[^stream]",
  "",
  "[^stream]: This footnote is intentionally near the end of the streamed content.",
  "",
  "## Long response stress section",
  "",
  "Streaming renderers tend to fail in boring places, so this section repeats ordinary assistant output with enough length to make scrolling, partial paragraphs, and nested formatting visible. The first paragraph is intentionally long and includes **bold claims**, _soft emphasis_, `inline identifiers`, and a [reference link](https://example.com/docs/streaming-markdown) that should not trigger a full node refresh while the rest of the paragraph is still arriving.",
  "",
  "A second paragraph adds more normal prose. It describes a practical review checklist: keep completed text stable, animate only appended text, keep code block headers fixed, avoid layout jumps in tables, and make sure scroll behavior is controlled by the consumer rather than hidden inside the renderer.",
  "",
  "> Long blockquotes should keep their border and spacing stable while the streamed content grows.",
  ">",
  "> The quote also contains **nested strong text**, _nested emphasis_, and `inline code` so the renderer has to reconcile multiple inline nodes in the same block.",
  "",
  "### Nested list stress",
  "",
  "- Preserve existing DOM where possible",
  "  - Do not replay enter animations for settled nodes",
  "  - Do not reset scroll unless auto scroll is enabled",
  "- Keep partial syntax readable",
  "  - Incomplete code fences should still have a stable shell",
  "  - Incomplete lists should not collapse surrounding paragraphs",
  "- Keep controls responsive",
  "  - The progress slider can jump to any point",
  "  - The speed slider can slow the mock stream down for visual review",
  "",
  "### Wider table stress",
  "",
  "| Case | Stream state | Expected behavior |",
  "| --- | --- | --- |",
  "| Plain paragraph | Appending words | Only the new words animate |",
  "| Code fence | Header appears early | Header stays stable while code grows |",
  "| Table | Rows arrive gradually | Existing cells do not flash |",
  "| Scroll container | Auto scroll enabled | View follows the latest content |",
  "| Scroll container | Auto scroll disabled | User position is preserved |",
  "",
  "```yaml",
  "renderer:",
  "  package: markstream-react",
  "  mode: custom-components",
  "  animation:",
  "    owner: comma-ui",
  "    type: character-blur",
  "  controls:",
  "    progress: draggable",
  "    speed: adjustable",
  "    autoScroll: true",
  "```",
  "",
  "```bash",
  "pnpm --filter @comma/ui storybook",
  "pnpm --filter @comma/ui build-storybook",
  "```",
  "",
  "A final long paragraph keeps the tail of the stream active for a while. This gives enough runway to test the slowest speed, drag the progress slider backward and forward, toggle auto scroll off, and confirm that the renderer does not flash already settled content when new markdown arrives.",
  "",
  "Final line.",
].join("\n");

const collapsibleCodeMarkdown = [
  "## Collapsible code block",
  "",
  "The code is intentionally long enough to exercise the collapsed state.",
  "",
  "```ts",
  "type TaskStatus = 'backlog' | 'in_progress' | 'done';",
  "",
  "interface Task {",
  "  id: string;",
  "  title: string;",
  "  status: TaskStatus;",
  "  updatedAt: Date;",
  "}",
  "",
  "const statusOrder: TaskStatus[] = [",
  "  'backlog',",
  "  'in_progress',",
  "  'done',",
  "];",
  "",
  "const tasks: Task[] = [",
  "  {",
  "    id: 'task-001',",
  "    title: 'Audit markdown rendering',",
  "    status: 'done',",
  "    updatedAt: new Date('2026-08-09T09:00:00Z'),",
  "  },",
  "  {",
  "    id: 'task-002',",
  "    title: 'Polish code block controls',",
  "    status: 'in_progress',",
  "    updatedAt: new Date('2026-08-10T10:30:00Z'),",
  "  },",
  "  {",
  "    id: 'task-003',",
  "    title: 'Verify collapsed state',",
  "    status: 'backlog',",
  "    updatedAt: new Date('2026-08-11T12:00:00Z'),",
  "  },",
  "];",
  "",
  "export const groupTasksByStatus = (items: Task[]) =>",
  "  statusOrder.map((status) => ({",
  "    status,",
  "    tasks: items",
  "      .filter((task) => task.status === status)",
  "      .sort((left, right) =>",
  "        right.updatedAt.getTime() - left.updatedAt.getTime(),",
  "      ),",
  "  }));",
  "",
  "export const taskGroups = groupTasksByStatus(tasks);",
  "```",
].join("\n");

const streamSlice = (progress: number) =>
  comprehensiveMarkdown.slice(
    0,
    Math.round((comprehensiveMarkdown.length * progress) / 100)
  );

const streamIntervalMs = 80;

const formatSpeed = (value: number) => {
  const text = Number.isInteger(value) ? String(value) : value.toFixed(2);
  return `${text.replace(/0+$/, "").replace(/\.$/, "")}x`;
};

const defaultBlurDebug = {
  activeCharacters: 80,
  blurRadiusPx: 6,
  characterDelayMs: 10,
  durationMs: 280,
  initialOpacity: 0.28,
  maxAnimatedCharacters: 220,
  translateYEm: 0.4,
};

const meta = {
  title: "App components/Markdown stream",
  component: MarkdownStream,
  parameters: {
    layout: "padded",
  },
  args: {
    content: comprehensiveMarkdown,
    final: true,
  },
} satisfies Meta<typeof MarkdownStream>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: (args, { globals }) => (
    <div className="max-h-[760px] w-[720px] overflow-auto rounded-xl border-[0.5px] border-primary bg-main-panel-bg p-2xl">
      <MarkdownStream {...args} isDark={globals.theme === "dark"} />
    </div>
  ),
};

export const CollapsibleCodeBlock: Story = {
  name: "Collapsible code block",
  args: {
    content: collapsibleCodeMarkdown,
    final: true,
  },
  render: (args, { globals }) => (
    <div className="w-[720px] rounded-xl border-[0.5px] border-primary bg-main-panel-bg p-2xl">
      <MarkdownStream {...args} isDark={globals.theme === "dark"} />
    </div>
  ),
};

export const Streaming: Story = {
  render: (_args, { globals }) => {
    const [progress, setProgress] = useState(0);
    const [playing, setPlaying] = useState(true);
    const [speed, setSpeed] = useState(1);
    const [autoScroll, setAutoScroll] = useState(true);
    const [ensureBlurAnimation, setEnsureBlurAnimation] = useState(false);
    const [blurDebug, setBlurDebug] = useState(defaultBlurDebug);
    const blurDebugRef = useRef({ ...defaultBlurDebug });
    const blurPaneRef = useRef<HTMLDivElement>(null);
    const renderedContentRef = useRef<HTMLDivElement>(null);
    const scrollFrameRef = useRef<number | null>(null);
    const scrollContainerRef = useRef<HTMLDivElement>(null);
    const blurAnimation = useMemo(
      () => ({
        activeCharacters: blurDebug.activeCharacters,
        blurRadiusPx: blurDebug.blurRadiusPx,
        characterDelayMs: blurDebug.characterDelayMs,
        durationMs: blurDebug.durationMs,
        initialOpacity: blurDebug.initialOpacity,
        translateYEm: blurDebug.translateYEm,
      }),
      [blurDebug]
    );

    useEffect(() => {
      if (!playing) return;
      const timer = window.setInterval(
        () => {
          setProgress((current) => {
            if (current >= 100) {
              window.clearInterval(timer);
              return 100;
            }
            return Math.min(current + 1, 100);
          });
        },
        Math.max(24, Math.round(streamIntervalMs / speed))
      );
      return () => window.clearInterval(timer);
    }, [playing, speed]);

    useEffect(() => {
      const container = blurPaneRef.current;
      if (!container) return undefined;

      const params = blurDebugRef.current;
      const pane = new Pane({
        container,
        title: "Blur debug",
      });
      const updateDebugState = () => {
        setBlurDebug({ ...params });
      };

      pane.on("change", updateDebugState);
      pane
        .addBinding(params, "blurRadiusPx", {
          label: "Strength",
          max: 16,
          min: 0,
          step: 0.5,
        })
        .on("change", updateDebugState);
      pane
        .addBinding(params, "durationMs", {
          label: "Duration",
          max: 1200,
          min: 80,
          step: 20,
        })
        .on("change", updateDebugState);
      pane
        .addBinding(params, "characterDelayMs", {
          label: "Reveal gap",
          max: 120,
          min: 0,
          step: 2,
        })
        .on("change", updateDebugState);
      pane
        .addBinding(params, "activeCharacters", {
          label: "Tail window",
          max: 128,
          min: 1,
          step: 1,
        })
        .on("change", updateDebugState);
      pane
        .addBinding(params, "maxAnimatedCharacters", {
          label: "Max chars",
          max: 240,
          min: 8,
          step: 4,
        })
        .on("change", updateDebugState);
      pane
        .addBinding(params, "initialOpacity", {
          label: "Start alpha",
          max: 1,
          min: 0,
          step: 0.05,
        })
        .on("change", updateDebugState);
      pane
        .addBinding(params, "translateYEm", {
          label: "Y offset",
          max: 0.4,
          min: 0,
          step: 0.01,
        })
        .on("change", updateDebugState);
      pane.addButton({ title: "Reset blur" }).on("click", () => {
        Object.assign(params, defaultBlurDebug);
        pane.refresh();
        updateDebugState();
      });

      return () => pane.dispose();
    }, []);

    const content = streamSlice(progress);
    const final = progress >= 100;

    const cancelScheduledAutoScroll = useCallback(() => {
      if (scrollFrameRef.current !== null) {
        window.cancelAnimationFrame(scrollFrameRef.current);
        scrollFrameRef.current = null;
      }
    }, []);

    const scrollToBottom = useCallback(() => {
      const container = scrollContainerRef.current;
      if (!container) return;
      container.scrollTop = container.scrollHeight;
    }, []);

    const shouldFollowRenderedChange = useCallback(() => {
      if (!autoScroll) return false;
      if (!final) return true;
      return Boolean(
        renderedContentRef.current?.querySelector(".markdown-stream-char-enter")
      );
    }, [autoScroll, final]);

    const scheduleAutoScroll = useCallback(() => {
      if (scrollFrameRef.current !== null) return;

      scrollFrameRef.current = window.requestAnimationFrame(() => {
        scrollFrameRef.current = null;
        scrollToBottom();
      });
    }, [scrollToBottom]);

    useEffect(() => {
      return cancelScheduledAutoScroll;
    }, [cancelScheduledAutoScroll]);

    useEffect(() => {
      if (!autoScroll) {
        cancelScheduledAutoScroll();
        return;
      }
      scheduleAutoScroll();
    }, [
      autoScroll,
      cancelScheduledAutoScroll,
      content,
      ensureBlurAnimation,
      scheduleAutoScroll,
    ]);

    useEffect(() => {
      if (!autoScroll) return;
      const renderedContent = renderedContentRef.current;
      if (!renderedContent) return;

      if (typeof ResizeObserver !== "undefined") {
        const resizeObserver = new ResizeObserver(() => {
          if (shouldFollowRenderedChange()) {
            scheduleAutoScroll();
          }
        });
        resizeObserver.observe(renderedContent);
        return () => resizeObserver.disconnect();
      }

      const mutationObserver = new MutationObserver(() => {
        if (shouldFollowRenderedChange()) {
          scheduleAutoScroll();
        }
      });
      mutationObserver.observe(renderedContent, {
        characterData: true,
        childList: true,
        subtree: true,
      });
      return () => mutationObserver.disconnect();
    }, [autoScroll, scheduleAutoScroll, shouldFollowRenderedChange]);

    return (
      <div className="flex w-[760px] flex-col gap-xl rounded-xl border-[0.5px] border-primary bg-main-panel-bg p-2xl">
        <div className="flex flex-col gap-lg">
          <div className="flex items-center gap-lg">
            <Button
              hierarchy="secondary-gray"
              onPress={() => setPlaying((current) => !current)}
              size="sm"
            >
              {playing ? "Pause" : "Play"}
            </Button>
            <Button
              hierarchy="tertiary-gray"
              onPress={() => {
                setPlaying(false);
                setProgress(0);
              }}
              size="sm"
            >
              Reset
            </Button>
            <div className="min-w-0 flex-1">
              <Slider
                className="w-full"
                formatValue={(value) => `${value}%`}
                max={100}
                min={0}
                onValueChange={(value) => {
                  setPlaying(false);
                  setProgress(value);
                }}
                step={1}
                value={progress}
              />
            </div>
            <span className="w-12 text-right text-sm leading-5 text-markdown-text-tool-primary">
              {progress}%
            </span>
          </div>
          <div className="flex items-center gap-xl">
            <div className="flex min-w-0 flex-1 items-center gap-md">
              <span className="w-12 text-sm leading-5 text-markdown-text-tool-primary">
                Stream
              </span>
              <Slider
                className="w-full"
                formatValue={formatSpeed}
                max={3}
                min={0.05}
                onValueChange={setSpeed}
                step={0.05}
                value={speed}
              />
              <span className="w-12 text-right text-sm leading-5 text-markdown-text-tool-primary">
                {formatSpeed(speed)}
              </span>
            </div>
            <Toggle
              checked={autoScroll}
              label="Auto scroll"
              onChange={(event) => setAutoScroll(event.target.checked)}
              size="sm"
              slim
            />
            <Toggle
              checked={ensureBlurAnimation}
              label="Complete blur"
              onChange={(event) => setEnsureBlurAnimation(event.target.checked)}
              size="sm"
              slim
            />
          </div>
          <div ref={blurPaneRef} className="fixed right-4 top-4 z-50 w-[280px]" />
        </div>
        <div
          ref={scrollContainerRef}
          className="max-h-[680px] overflow-auto rounded-md border-[0.5px] border-primary p-xl"
        >
          <div ref={renderedContentRef}>
            <MarkdownStream
              blurAnimation={blurAnimation}
              content={content}
              ensureBlurAnimation={ensureBlurAnimation}
              final={final}
              isDark={globals.theme === "dark"}
              maxAnimatedCharacters={blurDebug.maxAnimatedCharacters}
              smoothStreaming={false}
              streamId="storybook-streaming"
            />
          </div>
        </div>
      </div>
    );
  },
};

const cjkLabelMarkdown = [
  "- **做什么：**它是模型。",
  "- **和普通大模型有什么不同：**它返回结构化结果。",
  "- **为什么引人关注：**主打速度和成本。",
  "- **怎么用：**发布说明。",
  "",
  "`**代码：**正文`",
].join("\n");

export const CjkBoldLabels: Story = {
  render: () => {
    const [expanded, setExpanded] = useState(false);
    const [final, setFinal] = useState(false);
    const [compiled, setCompiled] = useState(false);
    const nodes = useMemo(
      () =>
        createMarkdownStreamDocumentNodes([
          { type: "markdown", text: cjkLabelMarkdown },
        ]),
      []
    );
    return (
      <>
        <Button onClick={() => setExpanded(true)}>Append prose</Button>
        <Button onClick={() => setFinal(true)}>Finish stream</Button>
        <Button onClick={() => setCompiled(true)}>Use compiled nodes</Button>
        <MarkdownStream
          {...(compiled
            ? { nodes }
            : { content: expanded ? cjkLabelMarkdown : "- **做什么：**" })}
          final={final}
          streamId="cjk-bold-labels"
        />
      </>
    );
  },
};
