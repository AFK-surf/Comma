import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { Toaster, toast } from "@comma/ui/components/toast";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it } from "vitest";
import { OUT_OF_CREDITS_TOAST_ID, showOutOfCreditsToast } from "../outOfCredits";

// Sonner's store outlives each render, so every case dismisses what it raised.
describe("showOutOfCreditsToast", () => {
  const previousHash = window.location.hash;

  afterEach(() => {
    window.location.hash = previousHash;
    act(() => {
      toast.dismissAll();
    });
  });

  it("names the empty balance and leaves for billing from its one action", async () => {
    const user = userEvent.setup();
    render(<Toaster />);
    act(() => {
      showOutOfCreditsToast("en");
      // A second refusal replaces the toast instead of stacking another.
      showOutOfCreditsToast("en");
    });

    const toastShell = await screen.findByTestId(OUT_OF_CREDITS_TOAST_ID);
    expect(screen.getAllByTestId(OUT_OF_CREDITS_TOAST_ID)).toHaveLength(1);
    expect(toastShell).toHaveTextContent("Out of Comma credits");
    expect(toastShell).toHaveTextContent(
      "This request is paid with Comma credits. Add credits or change plan, then retry."
    );

    // A toast action does not close its toast on its own; this one must, or
    // the refusal would still be showing over the billing page it opened.
    await user.click(screen.getByRole("button", { name: "Add credits" }));
    expect(window.location.hash).toBe("#/settings?category=usage-billing");
    await waitFor(() =>
      expect(screen.queryByTestId(OUT_OF_CREDITS_TOAST_ID)).not.toBeInTheDocument()
    );
  });
});
