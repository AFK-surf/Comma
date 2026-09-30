import { describe, expect, it, vi } from "vitest";
import type { ReactElement, ReactNode } from "react";
import { isValidElement } from "react";
import { render, screen } from "@comma/test-utils/render";

const { showToast } = vi.hoisted(() => ({
  showToast: vi.fn<(title: ReactNode, data?: unknown) => string | number>(
    () => "toast-1"
  ),
}));

vi.mock("sonner", () => ({
  toast: Object.assign(showToast, {
    dismiss: vi.fn(),
  }),
}));

import { resolveToastVariant, toast } from "../toastApi";

describe("toast", () => {
  it("resolves toast variants from options", () => {
    expect(resolveToastVariant()).toBe("single");
    expect(resolveToastVariant({ description: "More detail" })).toBe("description");
    expect(resolveToastVariant({ actions: [{ label: "Undo" }] })).toBe("action");
  });

  it("renders comma toast content through sonner toast", () => {
    toast("Copied to clipboard", { description: "Ready to paste" });

    expect(showToast).toHaveBeenCalledTimes(1);

    const toastContent = showToast.mock.calls[0]?.[0] as ReactElement;
    expect(isValidElement(toastContent)).toBe(true);

    render(toastContent);

    expect(screen.getByText("Copied to clipboard")).toBeInTheDocument();
    expect(screen.getByText("Ready to paste")).toBeInTheDocument();
  });

  it("routes success helper through the success intent", () => {
    toast.success("Saved");

    const toastContent = showToast.mock.calls.at(-1)?.[0] as ReactElement;
    render(toastContent);

    expect(screen.getByText("Saved")).toBeInTheDocument();
  });

  it("forwards per-toast position to sonner", () => {
    toast("Bottom notice", { position: "bottom-center" });

    expect(showToast).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ position: "bottom-center" })
    );
  });
});
