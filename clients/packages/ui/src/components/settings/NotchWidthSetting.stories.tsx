import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import { SettingsPanel } from "../settings-panel";
import { NotchWidthSetting, type NotchWidthSettingLabels } from "./NotchWidthSetting";

const range = { min: 32, default: 156, max: 240 };

const labels: NotchWidthSettingLabels = {
  preview: "Preview on notch",
  reset: "Reset",
  sampleTitle: "Summarize this week’s meetings",
  valueText: (points) => `${points} pt on each side`,
  width: "Notch width",
};

const NotchSettingsStory = ({
  initialWidth = range.default,
}: {
  initialWidth?: number;
}) => {
  const [visible, setVisible] = useState(true);
  const [width, setWidth] = useState(initialWidth);

  return (
    <SettingsPanel
      className="h-[720px] w-[760px]"
      sections={[
        {
          id: "general.application",
          title: "General",
          items: [
            {
              id: "app.dock",
              title: "Show in dock",
              description: "Keep Comma available in the macOS Dock.",
              control: { type: "toggle", defaultChecked: true },
            },
          ],
        },
        {
          id: "general.notch",
          title: "Notch",
          items: [
            {
              id: "app.notch",
              title: "Show in notch",
              description:
                "Show running tasks and AirDrop transfers beside the notch at the top of the screen.",
              control: {
                type: "toggle",
                checked: visible,
                onChange: (event) => setVisible(event.target.checked),
              },
              content: visible ? (
                <NotchWidthSetting
                  defaultValue={range.default}
                  labels={labels}
                  max={range.max}
                  min={range.min}
                  onPreview={() => undefined}
                  onValueCommit={setWidth}
                  value={width}
                />
              ) : null,
            },
          ],
        },
      ]}
    />
  );
};

const meta = {
  title: "App components/Settings/Notch width",
  component: NotchWidthSetting,
  args: {
    defaultValue: range.default,
    labels,
    max: range.max,
    min: range.min,
    onValueCommit: () => undefined,
    value: range.default,
  },
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof NotchWidthSetting>;

export default meta;
type Story = StoryObj<typeof meta>;

export const InSettings: Story = {
  render: () => <NotchSettingsStory />,
};

export const Narrow: Story = {
  render: () => <NotchSettingsStory initialWidth={range.min} />,
};

export const Wide: Story = {
  render: () => <NotchSettingsStory initialWidth={range.max} />,
};
