import type { Meta, StoryObj } from "@storybook/react-vite";
import { ComputeDiskUsage } from "./ComputeDiskUsage";

const labels = {
  used: "Used",
  imageRuntime: "Images & runtime",
  buildCache: "Build cache",
  privateData: "Private data",
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
    breakdown: {
      imageRuntimeBytes: "3220176896",
      buildCacheBytes: "1073741824",
      privateBytes: "1048576",
      otherBytes: "0",
      breakdownSampledAt: collectedAt,
    },
    labels,
  },
} satisfies Meta<typeof ComputeDiskUsage>;
export default meta;
type Story = StoryObj<typeof meta>;
export const Categories: Story = {};
export const TotalOnly: Story = { args: { breakdown: undefined } };
export const StaleDetail: Story = {
  args: {
    breakdown: { ...meta.args.breakdown, breakdownSampledAt: "2026-10-01T09:59:00Z" },
  },
};
