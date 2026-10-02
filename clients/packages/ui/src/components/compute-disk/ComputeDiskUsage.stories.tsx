import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import { ComputeDiskUsage } from "./ComputeDiskUsage";

const labels = {
  used: "Used",
  remaining: "Remaining",
  otherUsed: "Other used",
  detailUnavailable: "Environment detail unavailable",
  summary: (used: string, capacity: string) => `${used} used of ${capacity}`,
};
const collectedAt = "2026-10-01T10:00:00Z";
const meta = {
  title: "App components/Compute disk",
  component: ComputeDiskUsage,
  parameters: { layout: "padded" },
  args: {
    usedBytes: "4294967296",
    capacityBytes: "17179869184",
    collectedAt,
    environments: [
      {
        key: "local",
        label: "Local environment",
        bytes: "1073741824",
        sampledAt: collectedAt,
      },
      {
        key: "remote",
        label: "Remote environment",
        bytes: "536870912",
        sampledAt: collectedAt,
      },
    ],
    labels,
    onSelect: () => {},
  },
} satisfies Meta<typeof ComputeDiskUsage>;
export default meta;
type Story = StoryObj<typeof meta>;
export const PartialDetail: Story = {
  render: (args) => {
    const [selected, setSelected] = useState<string>();
    return (
      <div style={{ maxWidth: 680 }}>
        <ComputeDiskUsage {...args} onSelect={setSelected} />
        <output>
          {selected
            ? `Selected ${selected}`
            : "Select an environment to view its local summary"}
        </output>
      </div>
    );
  },
};
export const TotalOnly: Story = { args: { environments: [] } };
export const StaleDetail: Story = {
  args: {
    environments: [
      {
        key: "old",
        label: "Old environment",
        bytes: "1073741824",
        sampledAt: "2026-10-01T09:59:00Z",
      },
    ],
  },
};
