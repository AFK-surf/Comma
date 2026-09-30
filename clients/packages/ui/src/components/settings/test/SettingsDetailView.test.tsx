import userEvent from "@testing-library/user-event";
import { render, screen, waitFor } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { SettingsDetailView } from "../SettingsDetailView";

describe("SettingsDetailView", () => {
  it("keeps focus on the page when its opener hands focus back to the modal", async () => {
    const back = vi.fn();
    render(
      <div>
        <button type="button" data-testid="modal">
          Modal
        </button>
        <SettingsDetailView
          id="devices.rename"
          title="Rename device"
          backLabel="Devices"
          onBack={back}
        >
          <input aria-label="Device name" />
        </SettingsDetailView>
      </div>
    );
    const page = document.querySelector('[data-slot="settings-detail"]');
    expect(document.activeElement).toBe(page);

    /*
     * A menu closing after this page mounted restores focus to a control that
     * no longer exists, which lands it on the modal above. Escape there closes
     * Settings outright, so the page takes focus back on the next frame.
     */
    screen.getByTestId("modal").focus();
    await waitFor(() => expect(document.activeElement).toBe(page));

    await userEvent.keyboard("{Escape}");
    expect(back).toHaveBeenCalledOnce();
  });
});
