import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import type { AirDropState, AirDropTransfer } from "@comma/native-bridge";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { Toaster } from "@comma/ui";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AirDropToasts } from "../AirDropToasts";

const requestId = "11111111-1111-4111-8111-111111111111";
const offer: AirDropTransfer = {
  canReveal: false,
  chatTitle: "Design review",
  files: [{ kind: "image", name: "IMG_0001.HEIC", size: 2048 }],
  linkCount: 0,
  phase: "offer",
  requestId,
  senderName: "Zanwei’s iPhone",
  surfaceId: "win_main",
  unattachedCount: 0,
};

function mountWithState(initial: AirDropState, windowId = "win_main") {
  let publish: ((state: AirDropState) => void) | undefined;
  const bridge = installNativeBridgeMock({
    os: "macos",
    platform: "electron",
    self: { role: "main-window", windowId },
  });
  vi.mocked(bridge.airDrop.preview).mockResolvedValue({
    image: new Uint8Array([1, 2, 3]),
    mediaType: "image/jpeg",
    status: "ready",
  });
  vi.mocked(bridge.airDrop.state.subscribe).mockImplementation((listener) => {
    publish = listener;
    listener(initial);
    return () => undefined;
  });
  render(
    <CommaI18nProvider locale="en">
      <Toaster />
      <AirDropToasts />
    </CommaI18nProvider>
  );
  return {
    bridge,
    publish: (state: AirDropState) => act(() => publish?.(state)),
  };
}

describe("AirDropToasts", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
  });

  it("asks in the destination window, then shows what arrived", async () => {
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:airdrop-preview");
    const revokeObjectURL = vi.spyOn(URL, "revokeObjectURL").mockReturnValue();
    const { bridge, publish } = mountWithState({ revision: 1, transfers: [offer] });

    expect(await screen.findByText("AirDrop from Zanwei’s iPhone")).toBeVisible();
    expect(screen.getByText("Adds to “Design review”")).toBeVisible();
    expect(screen.getByText("IMG_0001.HEIC")).toBeVisible();

    await userEvent.click(screen.getByRole("button", { name: "Accept" }));
    expect(bridge.airDrop.act).toHaveBeenCalledWith({ action: "accept", requestId });

    publish({
      revision: 2,
      transfers: [
        {
          ...offer,
          phase: "receiving",
          progress: 0.42,
        },
      ],
    });
    expect(
      await screen.findByRole("progressbar", { name: "Receiving from Zanwei’s iPhone" })
    ).toHaveAttribute("value", "42");
    expect(screen.getByText("42%")).toBeVisible();

    publish({
      revision: 3,
      transfers: [
        {
          ...offer,
          files: [
            {
              kind: "image",
              name: "IMG_0001.HEIC",
              preview: { height: 180, mediaType: "image/jpeg", width: 240 },
            },
          ],
          phase: "completed",
        },
      ],
    });
    expect(await screen.findByText("Added to “Design review”")).toBeVisible();
    // The image bytes come over the binary preview command, not the state.
    expect(await screen.findByRole("img", { name: "IMG_0001.HEIC" })).toHaveAttribute(
      "src",
      "blob:airdrop-preview"
    );
    expect(bridge.airDrop.preview).toHaveBeenCalledWith({ index: 0, requestId });
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument();

    publish({ revision: 4, transfers: [] });
    await waitFor(() =>
      expect(screen.queryByText("Added to “Design review”")).not.toBeInTheDocument()
    );
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:airdrop-preview");
    createObjectURL.mockRestore();
    revokeObjectURL.mockRestore();
  });

  it("lays several files out on one strip, each with its own preview", async () => {
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:airdrop-preview");
    const revokeObjectURL = vi.spyOn(URL, "revokeObjectURL").mockReturnValue();
    const tile = { height: 96, mediaType: "image/jpeg" as const, width: 96 };
    const { bridge } = mountWithState({
      revision: 1,
      transfers: [
        {
          ...offer,
          files: [
            { kind: "image", name: "IMG_0001.HEIC", preview: tile },
            { kind: "image", name: "IMG_0002.HEIC", preview: tile },
            { kind: "image", name: "IMG_0003.HEIC", preview: tile },
            { kind: "image", name: "IMG_0004.HEIC", preview: tile },
            {
              kind: "document",
              name: "Q3 report.pdf",
              preview: { ...tile, mediaType: "image/png", width: 68 },
            },
            { kind: "archive", name: "design-assets.zip" },
          ],
          phase: "completed",
        },
      ],
    });

    const strip = await screen.findByLabelText("Files");
    expect(within(strip).getAllByRole("listitem")).toHaveLength(6);
    // Past the first four: every previewed file asks Main for its own bytes.
    expect(
      await within(strip).findByRole("img", { name: "Q3 report.pdf" })
    ).toHaveAttribute("src", "blob:airdrop-preview");
    expect(bridge.airDrop.preview).toHaveBeenCalledWith({ index: 4, requestId });
    expect(bridge.airDrop.preview).not.toHaveBeenCalledWith({ index: 5, requestId });
    // A file without a preview is its kind and name.
    expect(within(strip).getByText("design-assets.zip")).toBeVisible();

    // Main keeps the result while the pointer is on it.
    const card = screen.getByTestId(`comma-airdrop-${requestId}`);
    await userEvent.hover(card);
    expect(bridge.airDrop.act).toHaveBeenLastCalledWith({ action: "hold", requestId });
    await userEvent.unhover(card);
    expect(bridge.airDrop.act).toHaveBeenLastCalledWith({
      action: "release",
      requestId,
    });
    createObjectURL.mockRestore();
    revokeObjectURL.mockRestore();
  });

  it("lets a transfer go once the focused control that held it is gone", async () => {
    const { bridge, publish } = mountWithState({ revision: 1, transfers: [offer] });
    const accept = await screen.findByRole("button", { name: "Accept" });
    act(() => accept.focus());
    expect(bridge.airDrop.act).toHaveBeenLastCalledWith({ action: "hold", requestId });

    // Answering the offer removes the focused button, and a removed element never blurs.
    publish({ revision: 2, transfers: [{ ...offer, phase: "receiving" }] });
    await waitFor(() =>
      expect(bridge.airDrop.act).toHaveBeenLastCalledWith({
        action: "release",
        requestId,
      })
    );
  });

  it("leaves another window's transfer to that window", async () => {
    const { bridge } = mountWithState(
      { revision: 1, transfers: [offer] },
      "win_dynamic_2"
    );

    await waitFor(() => expect(bridge.airDrop.state.subscribe).toHaveBeenCalled());
    expect(screen.queryByText("AirDrop from Zanwei’s iPhone")).not.toBeInTheDocument();
  });
});
