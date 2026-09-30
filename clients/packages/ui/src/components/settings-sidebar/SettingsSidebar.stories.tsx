import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, within } from "storybook/test";
import { SettingsIcon } from "../icons";
import { SettingsSidebar } from "./SettingsSidebar";

const meta = {
  title: "App components/Settings Sidebar",
  component: SettingsSidebar,
  args: {
    ariaLabel: "Settings sections",
    items: [
      {
        href: "#/settings",
        icon: <SettingsIcon className="size-4.5" />,
        id: "general",
        label: "General",
        selected: true,
      },
    ],
    title: "Settings",
    searchAriaLabel: "Search settings",
    searchPlaceholder: "Search settings",
  },
  parameters: {
    layout: "centered",
  },
  render: (args) => (
    <div className="h-[1008px] w-[286px] bg-main-panel-bg">
      <SettingsSidebar {...args} />
    </div>
  ),
} satisfies Meta<typeof SettingsSidebar>;

export default meta;
type Story = StoryObj<typeof meta>;

export const General: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);

    await expect(
      canvas.getByRole("complementary", { name: "Settings sections" })
    ).toBeInTheDocument();
    // Settings is a modal over the product now, so the sidebar carries no way
    // back to the app: the modal's own close control is that.
    await expect(canvas.queryByRole("link", { name: "Back to app" })).toBeNull();
    const searchbox = canvas.getByRole("searchbox", {
      name: "Search settings",
    });
    await expect(searchbox).toBeInTheDocument();
    const searchForm = searchbox.closest("form");
    await expect(searchForm).not.toBeNull();
    await expect(getComputedStyle(searchForm!).paddingLeft).toBe("0px");
    await expect(getComputedStyle(searchForm!).paddingRight).toBe("0px");
    await expect(canvas.getByRole("link", { name: "General" })).toHaveAttribute(
      "aria-current",
      "page"
    );
  },
};
