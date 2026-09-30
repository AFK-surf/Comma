import { getNativeBridge, type CommaNativeBridge } from "@comma/native-bridge";

export type RendererRecommendationMediaResult =
  | { bytes: Uint8Array; mediaType: "image/png"; status: "ready" }
  | { status: "unavailable" };

/**
 * Electron Main is the only V1 runtime trusted to resolve and pin a public
 * network target. Web deliberately keeps the media row's text fallback rather
 * than initiating an unpinned renderer request.
 */
export async function loadRecommendationMedia(
  url: string,
  {
    bridge = getNativeBridge(),
    signal,
  }: {
    bridge?: Pick<CommaNativeBridge, "platform" | "recommendationMedia">;
    signal?: AbortSignal | undefined;
  } = {}
): Promise<RendererRecommendationMediaResult> {
  if (bridge.platform !== "electron" || signal?.aborted) {
    return { status: "unavailable" };
  }

  try {
    const result = await bridge.recommendationMedia.load({ url });
    if (signal?.aborted) return { status: "unavailable" };
    return result.status === "ready"
      ? { bytes: result.pngImage, mediaType: "image/png", status: "ready" }
      : { status: "unavailable" };
  } catch {
    return { status: "unavailable" };
  }
}
