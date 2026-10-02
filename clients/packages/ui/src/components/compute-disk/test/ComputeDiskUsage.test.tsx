import { describe, expect, it, vi } from "vitest";
import userEvent from "@testing-library/user-event";
import { render, screen } from "@comma/test-utils/render";
import { ComputeDiskUsage } from "../ComputeDiskUsage";

const labels = {
  used: "Used",
  remaining: "Remaining",
  otherUsed: "Other used",
  detailUnavailable: "Details unavailable",
  summary: (used: string, capacity: string) => `${used} used of ${capacity}`,
};
const collectedAt = "2026-10-01T10:00:00Z";
describe("local compute data disk", () => {
  it("exposes honest totals and keyboard navigation without changing the selected environment", async () => {
    const select = vi.fn(),
      user = userEvent.setup();
    render(
      <ComputeDiskUsage
        usedBytes="1024"
        capacityBytes="4096"
        collectedAt={collectedAt}
        environments={[
          { key: "A", label: "Local A", bytes: "256", sampledAt: collectedAt },
        ]}
        labels={labels}
        onSelect={select}
      />
    );
    expect(screen.getByRole("group")).toHaveAccessibleName("1 KiB used of 4 KiB");
    expect(screen.getByText("Other used: 768 B")).toBeInTheDocument();
    expect(screen.getByText("Remaining: 3 KiB")).toBeInTheDocument();
    await user.tab();
    expect(screen.getByRole("button", { name: "Local A: 256 B" })).toHaveFocus();
    await user.keyboard("{Enter}");
    expect(select).toHaveBeenCalledExactlyOnceWith("A");
  });
  it("shows unavailable totals rather than a negative disk bar or a render exception", () => {
    render(
      <ComputeDiskUsage
        usedBytes="invalid"
        capacityBytes="4096"
        collectedAt={collectedAt}
        environments={[]}
        labels={labels}
        onSelect={vi.fn()}
      />
    );
    expect(screen.queryByRole("group")).not.toBeInTheDocument();
    expect(screen.getByText("Details unavailable")).toBeInTheDocument();
  });
  it.each(["stale", "exceeds", "duplicate", "invalid"])(
    "keeps the total and removes untrustworthy environment interaction when details are %s",
    (reason) => {
      const item = {
        key: "A",
        label: "Private A",
        bytes: reason === "exceeds" ? "2000" : reason === "invalid" ? "-1" : "256",
        sampledAt: reason === "stale" ? "2026-10-01T09:59:00Z" : collectedAt,
      };
      render(
        <ComputeDiskUsage
          usedBytes="1024"
          capacityBytes="4096"
          collectedAt={collectedAt}
          environments={reason === "duplicate" ? [item, item] : [item]}
          labels={labels}
          onSelect={vi.fn()}
        />
      );
      expect(screen.getByRole("group")).toHaveAccessibleName("1 KiB used of 4 KiB");
      expect(screen.queryByRole("button")).not.toBeInTheDocument();
      expect(screen.getByText("Used: 1 KiB")).toBeInTheDocument();
      expect(screen.getByText("Details unavailable")).toBeInTheDocument();
    }
  );
});
