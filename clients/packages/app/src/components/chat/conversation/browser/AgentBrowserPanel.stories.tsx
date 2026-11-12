import type { Meta, StoryObj } from "@storybook/react-vite";
import { CoreClient, CoreProvider } from "@comma/core-client";
import type { BrowserViewValue } from "@comma/core/contract";
import { useState } from "react";
import "../../../../styles.css";
import { AgentBrowserPanel } from "./AgentBrowserPanel";

const binding = {
  agent_id: "agent",
  session_id: "session",
  status: "ready",
  control: "agent" as const,
  busy: false,
  shared_storage: true,
  updated_at: "2026-11-02T00:00:00.000000Z",
};

const tabs = [
  {
    tab_id: "console",
    title: "App Store Connect",
    url: "https://appstoreconnect.apple.com/apps",
  },
  {
    tab_id: "docs",
    title: "Developer Documentation",
    url: "https://developer.apple.com",
  },
];

/** A page the remote tab could show, drawn as the server streams it: a JPEG frame. */
function pageFrame(): BrowserViewValue["frame"] {
  const surface = document.createElement("canvas");
  surface.width = 1280;
  surface.height = 720;
  const context = surface.getContext("2d");
  // A DOM without a canvas (jsdom) paints no page.
  if (!context) return null;
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, 1280, 720);
  context.fillStyle = "#f5f5f7";
  context.fillRect(0, 0, 1280, 64);
  context.fillStyle = "#1d1d1f";
  context.font = "600 22px -apple-system, sans-serif";
  context.fillText("App Store Connect", 48, 40);
  context.font = "600 40px -apple-system, sans-serif";
  context.fillText("Apps", 48, 150);
  for (const [index, name] of ["Comma", "Comma Beta", "Comma for Teams"].entries()) {
    const x = 48 + index * 300;
    context.fillStyle = "#e8e8ed";
    context.beginPath();
    context.roundRect(x, 200, 120, 120, 28);
    context.fill();
    context.fillStyle = "#1d1d1f";
    context.font = "500 20px -apple-system, sans-serif";
    context.fillText(name, x, 360);
    context.fillStyle = "#86868b";
    context.font = "16px -apple-system, sans-serif";
    context.fillText("iOS · macOS", x, 388);
  }
  const data = surface.toDataURL("image/jpeg", 0.9).split(",")[1]!;
  return { seq: 1, data, width: 1280, height: 720 };
}

/** The panel as the core would show it: `view` over an agent working on its first tab; `page` paints a frame. */
function Panel({
  view,
  page = false,
}: {
  view: Partial<BrowserViewValue>;
  page?: boolean;
}) {
  const [client] = useState(() => {
    const value = {
      tabs: [tabs[0]!],
      tab: "console",
      status: "agent",
      controlling: false,
      error: null,
      pending: false,
      frame: page ? pageFrame() : null,
      ...view,
    } satisfies BrowserViewValue;
    return new CoreClient(
      (onMessage) => ({
        post(raw) {
          const message = raw as {
            id: number;
            call?: string;
            subscribe?: { topic: string };
          };
          const answer = (data: unknown) => queueMicrotask(() => onMessage(data));
          if (message.subscribe?.topic === "browserView")
            answer({ id: message.id, value });
          else if (message.call === "browserView.command")
            answer({ id: message.id, ok: { closed: false } });
          else if (message.call) answer({ id: message.id, ok: null });
        },
        close() {},
      }),
      { schedule: () => undefined }
    );
  });
  return (
    <CoreProvider client={client}>
      <div className="flex w-[880px] flex-col bg-main-panel-bg py-lg">
        <AgentBrowserPanel
          workspaceId="workspace"
          id="agent-browser"
          binding={binding}
          onRefresh={() => {}}
        />
      </div>
    </CoreProvider>
  );
}

const meta = {
  title: "App/Chat/AgentBrowserPanel",
  component: Panel,
  parameters: { layout: "centered" },
} satisfies Meta<typeof Panel>;

export default meta;
type Story = StoryObj<typeof meta>;

export const AgentWorking: Story = { args: { view: {}, page: true } };

export const YouInControl: Story = {
  args: { view: { tabs, status: "human", controlling: true }, page: true },
};

export const Connecting: Story = {
  args: { view: { tabs: [], tab: "", status: "loading" } },
};

export const StillBusy: Story = {
  args: { view: { tabs: [], tab: "", status: "disconnected", error: "busy" } },
};

export const TakeoverRefused: Story = {
  args: { view: { error: "busy" }, page: true },
};

export const StreamStopped: Story = {
  args: {
    view: {
      status: "disconnected",
      error: "stream",
      storageError: "browser_storage_partially_saved",
    },
    page: true,
  },
};
