import type { CommaNativeBridge } from "@comma/native-bridge";
import { describe, expect, it, vi } from "vitest";

import { loadRecommendationMedia } from "../recommendationMedia";

describe("loadRecommendationMedia", () => {
  it("uses the generated native capability in Electron and returns its decoded PNG", async () => {
    const pngImage = new Uint8Array([137, 80, 78, 71]);
    const load = vi.fn(async () => ({ pngImage, status: "ready" as const }));

    await expect(
      loadRecommendationMedia("https://media.example/image.png", {
        bridge: electronBridge(load),
      })
    ).resolves.toEqual({ bytes: pngImage, mediaType: "image/png", status: "ready" });
    expect(load).toHaveBeenCalledWith({ url: "https://media.example/image.png" });
  });

  it("degrades native capability failures to the text-only media row", async () => {
    const load = vi.fn().mockRejectedValue(new Error("native unavailable"));

    await expect(
      loadRecommendationMedia("https://media.example/image.png", {
        bridge: electronBridge(load),
      })
    ).resolves.toEqual({ status: "unavailable" });
  });

  it("does not issue an unpinned fetch in the web runtime", async () => {
    const load = vi.fn();
    const fetchSpy = vi.spyOn(globalThis, "fetch");

    await expect(
      loadRecommendationMedia("https://media.example/image.png", {
        bridge: {
          platform: "web",
          recommendationMedia: { load },
        } as Pick<CommaNativeBridge, "platform" | "recommendationMedia">,
      })
    ).resolves.toEqual({ status: "unavailable" });
    expect(load).not.toHaveBeenCalled();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("ignores a native result after its renderer consumer has aborted", async () => {
    const controller = new AbortController();
    let finish:
      | ((value: { pngImage: Uint8Array; status: "ready" }) => void)
      | undefined;
    const load = vi.fn(
      () =>
        new Promise<{ pngImage: Uint8Array; status: "ready" }>((resolve) => {
          finish = resolve;
        })
    );
    const result = loadRecommendationMedia("https://media.example/image.png", {
      bridge: electronBridge(load),
      signal: controller.signal,
    });

    controller.abort();
    finish?.({ pngImage: new Uint8Array([1]), status: "ready" });

    await expect(result).resolves.toEqual({ status: "unavailable" });
  });
});

function electronBridge(
  load: CommaNativeBridge["recommendationMedia"]["load"]
): Pick<CommaNativeBridge, "platform" | "recommendationMedia"> {
  return {
    platform: "electron",
    recommendationMedia: { load },
  };
}
