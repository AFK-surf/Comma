import { describe, expect, it } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import { ComputeDiskUsage } from "../ComputeDiskUsage";

const labels = {
  used: "Used",
  remaining: "Remaining",
  otherUsed: "Other",
  imageRuntime: "Images & runtime",
  buildCache: "Build cache",
  privateData: "Private data",
  detailUnavailable: "Details unavailable",
  summary: (used: string, capacity: string) => `${used} used of ${capacity}`,
};
const collectedAt = "2026-10-01T10:00:00Z";
const breakdown = {
  imageRuntimeBytes: "700",
  buildCacheBytes: "300",
  privateBytes: "1",
  otherBytes: "23",
  breakdownSampledAt: collectedAt,
};
function show(detail = breakdown, usedBytes = "1024") {
  render(
    <ComputeDiskUsage
      usedBytes={usedBytes}
      capacityBytes="4096"
      collectedAt={collectedAt}
      breakdown={detail}
      labels={labels}
    />
  );
}
describe("local compute data disk", () => {
  it("shows the physical partition with readable tiny private usage and remaining capacity", () => {
    show();
    expect(screen.getByRole("group")).toHaveAccessibleName("1 KiB used of 4 KiB");
    for (const text of [
      "Images & runtime: 700 B",
      "Build cache: 300 B",
      "Private data: 1 B",
      "Other: 23 B",
      "Remaining: 3 KiB",
    ]) {
      expect(screen.getByText(text)).toBeInTheDocument();
    }
    expect(screen.queryByText("Details unavailable")).not.toBeInTheDocument();
  });
  it("omits a zero residual but keeps measured zero categories", () => {
    show({
      ...breakdown,
      imageRuntimeBytes: "1024",
      buildCacheBytes: "0",
      privateBytes: "0",
      otherBytes: "0",
    });
    expect(screen.getByText("Private data: 0 B")).toBeInTheDocument();
    expect(screen.queryByText(/^Other:/)).not.toBeInTheDocument();
  });
  it.each([
    undefined,
    { ...breakdown, breakdownSampledAt: "2026-10-01T09:59:00Z" },
    { ...breakdown, privateBytes: "2000" },
    { ...breakdown, privateBytes: "-1" },
    { ...breakdown, privateBytes: "18446744073709551616" },
    { ...breakdown, privateBytes: undefined },
  ])(
    "keeps totals without presenting an unknown or inconsistent partition (%j)",
    (detail) => {
      render(
        <ComputeDiskUsage
          usedBytes="1024"
          capacityBytes="4096"
          collectedAt={collectedAt}
          breakdown={detail}
          labels={labels}
        />
      );
      expect(screen.getByRole("group")).toHaveAccessibleName("1 KiB used of 4 KiB");
      expect(screen.getByText("Used: 1 KiB")).toBeInTheDocument();
      expect(screen.queryByText(/^Private data:/)).not.toBeInTheDocument();
      expect(screen.getByText("Details unavailable")).toBeInTheDocument();
    }
  );
  it("shows unavailable totals instead of a negative bar or render exception", () => {
    show(breakdown, "invalid");
    expect(screen.queryByRole("group")).not.toBeInTheDocument();
    expect(screen.getByText("Details unavailable")).toBeInTheDocument();
  });
});
