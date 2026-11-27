import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { render, screen } from "@testing-library/react";
import { beforeEach, expect, it, vi } from "vitest";
import { TaskLabelsPage } from "../TaskLabelsSettings";

beforeEach(() => {
  initializeCommaI18n(["en"]);
});

it("reports an unsaved label policy on its own row, not as a catalog error", () => {
  render(
    <CommaI18nProvider locale="en">
      <TaskLabelsPage
        approvalPolicy={{
          value: "ask",
          disabled: false,
          failed: true,
          onChange: vi.fn(),
        }}
        busy={undefined}
        catalog={{ approval_policy: "ask", labels: [], updated_at: "1" } as never}
        counts={undefined}
        error={undefined}
        loading={false}
        locale="en"
        onCreate={vi.fn()}
        onDelete={vi.fn()}
        onResolveProposal={vi.fn()}
        onRetry={vi.fn()}
        onUpdate={vi.fn()}
        onViewProposalTask={vi.fn()}
        onViewTasks={vi.fn()}
        pendingProposals={[]}
        proposalTitle={() => ""}
      />
    </CommaI18nProvider>
  );
  screen.getByText("Couldn’t save this setting. Try again.");
  // The empty catalog still reads as empty: no table error, no retry.
  expect(screen.queryByTestId("task-labels-error")).toBeNull();
  expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
});
