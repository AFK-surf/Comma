import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, within } from "storybook/test";
import {
  HomeIcon,
  InboxIcon,
  LeftRail,
  ListChecksIcon,
  PuzzleIcon,
  SettingsIcon,
} from "../index";

const meta = {
  title: "App components/Left Rail",
  component: LeftRail,
  parameters: {
    layout: "centered",
  },
  decorators: [
    (Story) => (
      <div className="flex h-[600px] bg-window">
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof LeftRail>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  args: {},
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await expect(canvas.getByRole("button", { name: "Home" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    await expect(canvas.getByRole("button", { name: "Plugins" })).not.toHaveAttribute(
      "aria-current"
    );
    await expect(canvas.getByRole("button", { name: "Settings" })).toBeVisible();
  },
};

export const SettingsActive: Story = {
  args: {
    footerItem: {
      icon: <SettingsIcon />,
      id: "settings",
      label: "Settings",
      selected: true,
    },
    items: [
      { icon: <HomeIcon />, id: "home", label: "Home" },
      { icon: <InboxIcon />, id: "inbox", label: "Inbox" },
      { icon: <ListChecksIcon mode="raw" />, id: "tasks", label: "Tasks" },
      { icon: <PuzzleIcon />, id: "plugins", label: "Plugins" },
    ],
  },
};

export const InboxUnread: Story = {
  args: {
    items: [
      { icon: <HomeIcon />, id: "home", label: "Home", selected: true },
      { badge: true, icon: <InboxIcon />, id: "inbox", label: "Inbox" },
      { icon: <ListChecksIcon mode="raw" />, id: "tasks", label: "Tasks" },
      { icon: <PuzzleIcon />, id: "plugins", label: "Plugins" },
    ],
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const inbox = canvas.getByRole("button", { name: "Inbox" });
    await expect(
      inbox.querySelector('[data-slot="left-rail-item-badge"]')
    ).not.toBeNull();
  },
};
