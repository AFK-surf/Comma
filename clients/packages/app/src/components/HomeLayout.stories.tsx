import type { Meta, StoryObj } from "@storybook/react-vite";
import type { RecommendationEnvelope } from "@comma/recommendation-contract";
import { GlobeIcon, HomeTasks, RightSidebar } from "@comma/ui";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import type { CommaApiClient } from "../api";
import "../styles.css";
import { RecommendationRail } from "./recommendations/RecommendationRail";
import { HomeRail } from "./RouteScreens";
import { HomeLayout, HomeRailFoldProvider, HomeRailFolds } from "./home/HomeRailFolds";
import { HomeRailCollapseHandle } from "./home/HomeRailHandle";
import {
  commaHomeGreetPreferredMinWidth,
  commaHomeRailFoldsOpen,
  commaHomeTasksPreferredWidth,
  type CommaHomeRailName,
} from "./shellGeometry";

const noop = () => undefined;

const envelope = {
  settings: {
    autoEnableNewSources: true,
    schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
    sourceRevision: 1,
    sources: [
      {
        appId: "linear",
        appName: "Linear",
        connectionId: "linear",
        enabled: true,
        kind: "composio",
        label: "Linear",
      },
      {
        appId: "github",
        appName: "GitHub",
        connectionId: "github",
        enabled: true,
        kind: "native_mcp_oauth",
        label: "GitHub",
      },
    ],
    sourcesCheckedAt: "2026-08-17T03:00:00.000Z",
  },
  snapshot: {
    cards: [],
    generatedAt: 1_786_935_660_543,
    generation: 1,
    protocolVersion: 1,
    sourceRevision: 1,
    summary: [
      {
        kind: "markdown",
        text: "Good morning.\n\nLinear has 2 updates for you. Review ",
      },
      {
        kind: "inline-link",
        link: {
          href: "https://linear.app/comma/issue/COMMA-143",
          label: "COMMA-143",
          sourceId: "linear",
        },
      },
      {
        kind: "markdown",
        text: ". GitHub needs review on ",
      },
      {
        kind: "inline-link",
        link: {
          href: "https://github.com/AFK-surf/Comma/pull/884",
          label: "PR #884",
          sourceId: "github",
        },
      },
      { kind: "markdown", text: "." },
    ],
    templateCatalogVersion: 1,
    warnings: [],
  },
  state: "fresh",
} satisfies RecommendationEnvelope;

const api = {
  getRecommendations: async () => envelope,
  refreshRecommendations: async () => ({ envelope, run: { id: "run-1" } }),
} as unknown as CommaApiClient;

const tasks = [
  {
    activityStatus: "running",
    freshness: "fresh",
    id: "task-summarize",
    statusBucket: "in_progress",
    title: "Summarize the latest OpenAI update",
    updatedAt: 1_778_112_000,
    worker: "claude",
  },
  {
    activityStatus: "queued",
    freshness: "fresh",
    id: "task-library",
    statusBucket: "backlog",
    title: "Start on the refraction UI library",
    updatedAt: 1_777_939_200,
  },
] as const;

type HomeLayoutStoryProps = {
  /** Width of the content area (the product shell without the app sidebar). */
  frameWidth: number;
  /** Initial Chat Sidebar width (320–720). Drag its left edge to resize. */
  sidebarWidth: number;
};

function HomeLayoutStory({ frameWidth, sidebarWidth }: HomeLayoutStoryProps) {
  const [width, setWidth] = useState(sidebarWidth);
  const [railWidths, setRailWidths] = useState({
    greet: commaHomeGreetPreferredMinWidth,
    tasks: commaHomeTasksPreferredWidth,
  });
  const setRailWidth = useCallback((rail: CommaHomeRailName, next: number) => {
    setRailWidths((current) =>
      current[rail] === next ? current : { ...current, [rail]: next }
    );
  }, []);
  const [folds, setFolds] = useState(commaHomeRailFoldsOpen);
  const [collapsed, setCollapsed] = useState(commaHomeRailFoldsOpen);
  const toggleCollapsed = useCallback((rail: CommaHomeRailName) => {
    setCollapsed((previous) => ({ ...previous, [rail]: !previous[rail] }));
  }, []);
  const [taskStatus, setTaskStatus] = useState<"backlog" | "in_progress">("backlog");
  const frameRef = useRef<HTMLDivElement | null>(null);
  const routeRef = useRef<HTMLElement | null>(null);
  const chatRef = useRef<HTMLDivElement | null>(null);
  const [readout, setReadout] = useState({
    chat: 0,
    home: 0,
    sidebar: 0,
    greet: 0,
    tasks: 0,
  });

  useEffect(() => setWidth(sidebarWidth), [sidebarWidth]);
  useEffect(() => {
    const route = routeRef.current;
    const chat = chatRef.current;
    const sidebar = frameRef.current?.querySelector<HTMLElement>(".comma-chat-sidebar");
    if (!route || !chat || !sidebar || typeof ResizeObserver === "undefined") {
      return undefined;
    }
    // Rendered widths: the sidebar may be capped below its requested width
    // once the Home route reaches its 425px minimum.
    const observer = new ResizeObserver(() => {
      setReadout({
        chat: Math.round(chat.getBoundingClientRect().width),
        home: Math.round(route.getBoundingClientRect().width),
        sidebar: Math.round(sidebar.getBoundingClientRect().width),
        greet: Math.round(
          route.querySelector(".comma-home-greet-rail")?.getBoundingClientRect()
            .width ?? 0
        ),
        tasks: Math.round(
          route.querySelector(".comma-home-tasks-rail")?.getBoundingClientRect()
            .width ?? 0
        ),
      });
    });
    observer.observe(route);
    observer.observe(chat);
    observer.observe(sidebar);
    return () => observer.disconnect();
  }, []);

  const railState = useMemo(
    () => ({
      collapsed,
      folds,
      toggleCollapsed,
      widths: railWidths,
      setWidth: setRailWidth,
    }),
    [collapsed, folds, toggleCollapsed, railWidths, setRailWidth]
  );
  const frameStyle = {
    "--comma-primary-content-min-width": "425px",
    blockSize: 760,
    inlineSize: frameWidth,
  } as CSSProperties;

  return (
    <div
      className="comma-content relative flex min-h-0 min-w-0 overflow-clip rounded-2xl border-[0.5px] border-primary bg-main-panel-bg shadow-sm"
      ref={frameRef}
      style={frameStyle}
    >
      <div className="comma-route-outlet relative flex min-h-0 min-w-0 flex-1">
        <section
          aria-label="Comma assistant"
          className="comma-chat-route flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
          data-variant="home"
          ref={routeRef}
        >
          <header className="comma-chat-header flex h-11 shrink-0 items-center gap-sm px-lg">
            <h1 className="comma-chat-title m-0 text-sm font-medium text-primary">
              Comma assistant
            </h1>
          </header>
          <HomeRailFolds
            active
            greetWidth={railWidths.greet}
            greetCollapsed={collapsed.greet}
            onStateChange={setFolds}
            routeRef={routeRef}
          />
          <HomeRailFoldProvider state={railState}>
            <HomeLayout>
              <HomeRail id="storybook-home-greet-panel" label="Greet" name="greet">
                <RecommendationRail
                  api={api}
                  onOpenTask={noop}
                  onOpenUrl={noop}
                  onUsePrompt={noop}
                  workspaceId="storybook-home-layout"
                />
              </HomeRail>
              <HomeRailCollapseHandle
                controls="storybook-home-greet-panel"
                label="Greet"
                name="greet"
              />
              <div className="comma-home-chat" ref={chatRef}>
                <ChatColumnPlaceholder
                  readout={readout}
                  requestedSidebarWidth={width}
                />
              </div>
              <HomeRailCollapseHandle
                controls="storybook-home-tasks-panel"
                label="Tasks"
                name="tasks"
              />
              <HomeRail id="storybook-home-tasks-panel" label="Tasks" name="tasks">
                <HomeTasks
                  onOpenTask={noop}
                  onStatusChange={(status) =>
                    setTaskStatus(status === "in_progress" ? "in_progress" : "backlog")
                  }
                  status={taskStatus}
                  tasks={[...tasks]}
                />
              </HomeRail>
            </HomeLayout>
          </HomeRailFoldProvider>
        </section>
      </div>
      <RightSidebar
        activeTab="browser"
        ariaLabel="Chat sidebar"
        // Like the app: the sidebar may grow until the route hits its 425px minimum.
        maxWidth={Math.max(320, frameWidth - 425)}
        onTabChange={noop}
        onWidthChange={setWidth}
        open
        tabs={[
          {
            closable: true,
            icon: <GlobeIcon className="size-5" />,
            id: "browser",
            label: "www.notion.so",
            panelId: "storybook-home-browser-panel",
          },
        ]}
        width={width}
      >
        <section
          aria-label="Browser"
          className="flex min-h-0 min-w-0 flex-1 flex-col"
          id="storybook-home-browser-panel"
          role="tabpanel"
        >
          <div className="m-lg flex flex-1 items-center justify-center rounded-xl border border-dashed border-primary text-sm text-tertiary">
            Drag my left edge
          </div>
        </section>
      </RightSidebar>
    </div>
  );
}

const describeRail = (width: number) =>
  width <= 0 ? "folded" : `${width}px${width <= 240 ? " (content floor)" : ""}`;

function ChatColumnPlaceholder({
  readout,
  requestedSidebarWidth,
}: {
  readout: {
    chat: number;
    home: number;
    sidebar: number;
    greet: number;
    tasks: number;
  };
  requestedSidebarWidth: number;
}) {
  // Use rendered widths, including manual resizing and collapse.
  return (
    <div className="flex min-h-0 flex-1 flex-col items-center justify-end p-3xl">
      <dl className="m-0 grid w-full max-w-[744px] grid-cols-[auto_1fr] gap-x-lg gap-y-xs rounded-xl border border-primary bg-primary p-lg text-xs leading-5 text-secondary shadow-xs">
        <dt className="text-tertiary">Chat Sidebar</dt>
        <dd className="m-0 tabular-nums">
          {readout.sidebar}px
          {readout.sidebar > 0 && readout.sidebar < requestedSidebarWidth
            ? ` (capped; ${requestedSidebarWidth}px requested)`
            : ""}
        </dd>
        <dt className="text-tertiary">Home route</dt>
        <dd className="m-0 tabular-nums">{readout.home}px</dd>
        <dt className="text-tertiary">Chat column</dt>
        <dd className="m-0 tabular-nums">{readout.chat}px (floor 393px)</dd>
        <dt className="text-tertiary">Tasks rail</dt>
        <dd className="m-0">{describeRail(readout.tasks)}</dd>
        <dt className="text-tertiary">Greet rail</dt>
        <dd className="m-0">{describeRail(readout.greet)}</dd>
      </dl>
    </div>
  );
}

const meta = {
  title: "App components/Home layout",
  component: HomeLayoutStory,
  parameters: {
    layout: "centered",
    docs: {
      description: {
        component:
          "Home rails resize from their full-height seams, with a 240px minimum. Drag inward past the minimum to collapse the whole section; click its indicator to expand. When the route narrows, Tasks folds first, then Greeting, preserving the chat column’s 393px floor.",
      },
    },
  },
  argTypes: {
    frameWidth: { control: { type: "range", min: 900, max: 1800, step: 10 } },
    sidebarWidth: { control: { type: "range", min: 320, max: 1200, step: 10 } },
  },
} satisfies Meta<typeof HomeLayoutStory>;

export default meta;
type Story = StoryObj<typeof meta>;

export const DragToFold: Story = {
  args: { frameWidth: 1440, sidebarWidth: 320 },
};

export const TasksNarrow: Story = {
  args: { frameWidth: 1440, sidebarWidth: 480 },
};

export const TasksFolded: Story = {
  args: { frameWidth: 1440, sidebarWidth: 620 },
};

export const GreetNarrow: Story = {
  args: { frameWidth: 1440, sidebarWidth: 770 },
};

export const ChatFloor: Story = {
  args: { frameWidth: 1000, sidebarWidth: 720 },
};
