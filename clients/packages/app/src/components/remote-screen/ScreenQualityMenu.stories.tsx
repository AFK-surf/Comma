import type { ScreenQuality } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import { expect, userEvent, within } from "storybook/test";
import "../../styles.css";
import {
  ScreenQualityMenu,
  ScreenStreamFullscreenAction,
  ScreenStreamName,
  ScreenStreamTargetAction,
} from "./ScreenStreamChrome";

/** The side panel's toolbar as ScreenStreamPanel lays it out, its 画质 menu beside Watch and Control. */
function Toolbar({ initial }: { initial?: ScreenQuality }) {
  const messages = useCommaMessages();
  const [quality, setQuality] = useState(initial);
  return (
    <div
      className="comma-remote-screen-panel"
      data-state="live"
      style={{ width: 720, height: 320 }}
    >
      <header className="comma-remote-screen-header">
        <div className="comma-remote-screen-toolbar">
          <div className="comma-remote-screen-toolbar-lead">
            <ScreenStreamName line="Live · Direct" title="Mac mini" />
            <fieldset
              aria-label={messages.remote_screen_control()}
              className="comma-remote-screen-segments"
            >
              <Button
                aria-pressed
                className="bg-sidebar-bg-item"
                hierarchy="tertiary-gray"
                size="xs"
              >
                {messages.remote_screen_watch()}
              </Button>
              <Button aria-pressed={false} hierarchy="tertiary-gray" size="xs">
                {messages.remote_screen_control()}
              </Button>
            </fieldset>
          </div>
          <div className="comma-remote-screen-toolbar-tools">
            <ScreenQualityMenu onChoose={setQuality} quality={quality} />
            <span className="comma-remote-screen-action-group">
              <ScreenStreamTargetAction onToggle={() => undefined} target="display" />
              <ScreenStreamFullscreenAction full={false} onToggle={() => undefined} />
            </span>
          </div>
        </div>
      </header>
    </div>
  );
}

const meta = {
  title: "App components/Remote screen/Quality menu",
  component: Toolbar,
  parameters: { layout: "fullscreen" },
  args: { initial: "hd" },
  decorators: [
    (Story) => (
      <div style={{ padding: 16, minHeight: 360 }}>
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof Toolbar>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Open: Story = {
  play: async ({ canvasElement }) => {
    const page = within(canvasElement.ownerDocument.body);
    await userEvent.click(within(canvasElement).getByTestId("remote-screen-quality"));
    const menu = page.getByRole("menu");
    await expect(within(menu).getAllByRole("menuitemradio")).toHaveLength(4);
  },
};
