import { useEffect, useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, fn, userEvent, within } from "storybook/test";
import { ExpandSimpleIcon, GlobeIcon, ListChecksIcon, PanelRightIcon } from "../icons";
import { ScrollArea } from "../scroll-area";
import {
  RIGHT_SIDEBAR_DEFAULT_WIDTH,
  RightSidebar,
  RightSidebarToolbarButton,
  type RightSidebarProps,
  type RightSidebarTab,
} from "./RightSidebar";
import { RightSidebarBrowserToolbar } from "./RightSidebarBrowserToolbar";

const chatTab: RightSidebarTab = {
  closable: true,
  icon: <ListChecksIcon className="size-5" />,
  id: "chat",
  label: "Chat",
  panelId: "storybook-chat-panel",
};

const browserTab: RightSidebarTab = {
  closable: true,
  icon: <GlobeIcon className="size-5" />,
  id: "browser",
  label: "docs.comma.app/launch",
  panelId: "storybook-browser-panel",
};

const longBrowserTab: RightSidebarTab = {
  closable: true,
  icon: <GlobeIcon className="size-5" />,
  id: "long-browser",
  label: "New tab New tab New tab New tab",
  panelId: "storybook-browser-panel",
};

const meta = {
  title: "App components/Right Sidebar",
  component: RightSidebar,
  args: {
    activeTab: "chat",
    ariaLabel: "Chat sidebar",
    onAddTab: fn(),
    onTabChange: fn(),
    onTabClose: fn(),
    onWidthChange: fn(),
    open: true,
    tabs: [chatTab, browserTab],
    width: RIGHT_SIDEBAR_DEFAULT_WIDTH,
  },
  parameters: {
    layout: "centered",
  },
  render: (args) => <RightSidebarStoryFrame {...args} />,
} satisfies Meta<typeof RightSidebar>;

export default meta;
type Story = StoryObj<typeof meta>;

export const ChatAndBrowser: Story = {
  play: async ({ args, canvasElement }) => {
    const canvas = within(canvasElement);
    const sidebar = canvas.getByRole("complementary", { name: "Chat sidebar" });

    await expect(canvas.getByRole("tab", { name: "Chat" })).toHaveAttribute(
      "aria-selected",
      "true"
    );
    await userEvent.click(canvas.getByRole("tab", { name: "docs.comma.app/launch" }));
    await expect(
      canvas.getByRole("tab", { name: "docs.comma.app/launch" })
    ).toHaveAttribute("aria-selected", "true");

    const resizeHandle = canvas.getByRole("separator", {
      name: "Resize chat sidebar",
    });
    await userEvent.hover(resizeHandle);
    await expect(
      await within(canvasElement.ownerDocument.body).findByTestId(
        "comma-chat-sidebar-resize-tooltip"
      )
    ).toHaveTextContent("Drag to resize");

    resizeHandle.focus();
    await userEvent.keyboard("{ArrowLeft}");
    await expect(
      sidebar.style.getPropertyValue("--comma-right-sidebar-rendered-width")
    ).toContain("456px");
    await expect(args.onWidthChange).toHaveBeenLastCalledWith(456);
  },
};

export const BrowserSelected: Story = {
  args: {
    activeTab: "browser",
    tabs: [browserTab, longBrowserTab],
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const address = canvas.getByRole("textbox", { name: "Address" });

    await expect(address).toHaveAttribute("placeholder", "Search or enter URL");
    await expect(canvas.getByRole("button", { name: "Forward" })).toBeDisabled();
    await expect(canvas.queryByRole("button", { name: "Go" })).not.toBeInTheDocument();
    await expect(canvas.getByRole("button", { name: "New tab" })).toBeEnabled();
    await expect(canvas.queryByRole("tab", { name: "Chat" })).not.toBeInTheDocument();

    const longTab = canvas.getByRole("tab", {
      name: "New tab New tab New tab New tab",
    });
    await expect(longTab).toHaveClass("max-w-[180px]");

    await userEvent.click(canvas.getByRole("button", { name: "Reload" }));
    await expect(canvas.getByRole("button", { name: "Stop loading" })).toBeEnabled();
    await expect(
      canvas.getByRole("progressbar", { name: "Loading page" })
    ).toBeInTheDocument();
  },
};

export const Closed: Story = {
  args: {
    open: false,
  },
};

/** The browser toolbar with history in both directions, so both arrows can be pressed. */
export const BrowserToolbarHistory: Story = {
  parameters: { layout: "padded" },
  render: () => (
    <div className="w-[440px]">
      <RightSidebarBrowserToolbar
        address="docs.comma.app/launch"
        canGoBack
        canGoForward
        loading={false}
        onAddressChange={() => undefined}
        onAddressSubmit={() => undefined}
        onBack={() => undefined}
        onForward={() => undefined}
        onReload={() => undefined}
        onStop={() => undefined}
      />
    </div>
  ),
};

const RightSidebarStoryFrame = ({
  activeTab: initialActiveTab,
  onAddTab,
  onTabChange,
  onTabClose,
  onWidthChange,
  open: initiallyOpen,
  tabs: initialTabs,
  width: initialWidth,
  ...sidebarProps
}: RightSidebarProps) => {
  const [activeTab, setActiveTab] = useState(initialActiveTab);
  const [open, setOpen] = useState(initiallyOpen);
  const [tabs, setTabs] = useState(() => [...initialTabs]);
  const [width, setWidth] = useState(initialWidth);

  useEffect(() => setActiveTab(initialActiveTab), [initialActiveTab]);
  useEffect(() => setOpen(initiallyOpen), [initiallyOpen]);
  useEffect(() => setTabs([...initialTabs]), [initialTabs]);
  useEffect(() => setWidth(initialWidth), [initialWidth]);

  const handleTabChange = (tabId: string) => {
    setActiveTab(tabId);
    onTabChange(tabId);
  };
  const handleTabClose = (tabId: string) => {
    onTabClose?.(tabId);
    setTabs((current) => {
      const next = current.filter((tab) => tab.id !== tabId);
      if (activeTab === tabId) {
        setActiveTab(next[0]?.id ?? activeTab);
      }
      return next;
    });
  };
  const handleAddTab = () => {
    onAddTab?.();
    const id = `browser-${tabs.length + 1}`;
    const nextTab: RightSidebarTab = {
      closable: true,
      icon: <GlobeIcon className="size-5" />,
      id,
      label: "New tab",
      panelId: "storybook-browser-panel",
    };
    setTabs((current) => [...current, nextTab]);
    setActiveTab(id);
  };
  const handleWidthChange = (nextWidth: number) => {
    setWidth(nextWidth);
    onWidthChange(nextWidth);
  };

  return (
    <div className="flex h-[720px] w-[1134px] overflow-hidden rounded-2xl border-[0.5px] border-primary bg-window shadow-sm">
      <main className="flex min-w-0 flex-1 flex-col bg-main-panel-bg">
        <header className="flex h-11 shrink-0 items-center border-b-[0.5px] border-primary px-3">
          <h1 className="text-sm font-medium text-primary">Comma workspace</h1>
          <button
            aria-controls="storybook-right-sidebar"
            aria-expanded={open}
            aria-label="Toggle chat sidebar"
            className="ml-auto inline-flex size-8 items-center justify-center rounded-sm text-tertiary outline-none hover:bg-secondary hover:text-primary focus-visible:shadow-focus-gray"
            onClick={() => setOpen((currentOpen) => !currentOpen)}
            type="button"
          >
            <PanelRightIcon className="size-5" />
          </button>
        </header>
        <div className="flex min-h-0 flex-1 items-center justify-center p-3xl">
          <div className="w-full max-w-[448px] rounded-2xl border border-primary bg-primary p-3xl shadow-xs">
            <p className="m-0 text-sm leading-5 text-secondary">
              The application owns the current chat and browser session. The right
              sidebar owns its tabs, toolbar, resize behavior, and panel frame.
            </p>
          </div>
        </div>
      </main>

      <RightSidebar
        {...sidebarProps}
        activeTab={activeTab}
        headerActions={
          activeTab === "chat" ? (
            <RightSidebarToolbarButton aria-label="Open chat in main view">
              <ExpandSimpleIcon className="size-4" />
            </RightSidebarToolbarButton>
          ) : null
        }
        id="storybook-right-sidebar"
        onAddTab={handleAddTab}
        onTabChange={handleTabChange}
        onTabClose={handleTabClose}
        onWidthChange={handleWidthChange}
        open={open}
        tabs={tabs}
        width={width}
      >
        {activeTab === "chat" ? <StoryChatPanel /> : <StoryBrowserPanel />}
      </RightSidebar>
    </div>
  );
};

const StoryChatPanel = () => (
  <section
    aria-label="Chat"
    className="flex min-h-0 min-w-0 flex-1 flex-col"
    id="storybook-chat-panel"
    role="tabpanel"
  >
    <div className="flex h-10 shrink-0 items-center gap-2 border-b-[0.5px] border-primary px-4 text-xs font-medium text-secondary">
      <ListChecksIcon className="size-4 shrink-0 text-tertiary" />
      <span className="truncate">Review launch checklist</span>
    </div>
    <ScrollArea
      className="min-h-0 flex-1"
      contentClassName="flex min-h-full flex-col gap-lg p-4"
      edgeEffect="mask"
      edgeMask={{ endSize: 20, startSize: 20 }}
      orientation="vertical"
    >
      <div className="max-w-[84%] self-start rounded-xl bg-secondary px-3 py-2 text-sm leading-5 text-primary">
        I checked the release plan and found two items that still need owners.
      </div>
      <div className="max-w-[84%] self-end rounded-xl bg-fg-brand-primary px-3 py-2 text-sm leading-5 text-white">
        Add them to the checklist and assign the launch team.
      </div>
      <div className="max-w-[84%] self-start rounded-xl bg-secondary px-3 py-2 text-sm leading-5 text-primary">
        Done. The security review and rollback rehearsal are now assigned.
      </div>
    </ScrollArea>
    <div className="shrink-0 border-t-[0.5px] border-primary p-3">
      <div className="flex min-h-10 items-center rounded-xl border border-primary bg-primary px-3 text-sm text-placeholder shadow-xs">
        Reply to this task…
      </div>
    </div>
  </section>
);

const StoryBrowserPanel = () => {
  const [address, setAddress] = useState("docs.comma.app/launch");
  const [loading, setLoading] = useState(false);

  return (
    <section
      aria-label="Browser"
      className="flex min-h-0 min-w-0 flex-1 flex-col"
      id="storybook-browser-panel"
      role="tabpanel"
    >
      <RightSidebarBrowserToolbar
        address={address}
        canGoBack
        canGoForward={false}
        loading={loading}
        onAddressChange={setAddress}
        onAddressSubmit={() => setLoading(true)}
        onBack={() => undefined}
        onForward={() => undefined}
        onReload={() => setLoading(true)}
        onStop={() => setLoading(false)}
      />
      <div className="flex min-h-0 flex-1 flex-col bg-primary p-3xl">
        <p className="m-0 text-xs font-medium uppercase tracking-wide text-tertiary">
          Comma documentation
        </p>
        <h2 className="mb-md mt-lg text-2xl font-medium text-primary">
          Launch checklist
        </h2>
        <p className="m-0 w-full max-w-[384px] text-sm leading-6 text-secondary">
          Prepare, verify, and monitor each stage of a production release.
        </p>
        <div className="mt-3xl flex flex-col gap-md">
          {["Prepare release", "Run verification", "Monitor rollout"].map(
            (section, index) => (
              <div
                className="flex items-center gap-md rounded-xl border border-primary p-3"
                key={section}
              >
                <span className="flex size-6 items-center justify-center rounded-full bg-secondary text-xs font-medium text-secondary">
                  {index + 1}
                </span>
                <span className="text-sm font-medium text-primary">{section}</span>
              </div>
            )
          )}
        </div>
      </div>
    </section>
  );
};
