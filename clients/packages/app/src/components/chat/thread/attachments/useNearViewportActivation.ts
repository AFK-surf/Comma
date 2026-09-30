import { useLayoutEffect, useRef, useState } from "react";
import { observeLocalImagePreview } from "./localImagePreviewObserver";

/**
 * Whether the attachments block sits near the viewport, and whether it ever
 * has: nearness gates unfinished acquisitions, activation stays once reached.
 */
export function useNearViewportActivation(
  previewImages: readonly unknown[],
  inlineVideos: readonly unknown[]
) {
  const previewElementRef = useRef<HTMLDivElement | null>(null);
  const [nearViewport, setNearViewport] = useState(
    () => typeof IntersectionObserver !== "function"
  );
  const [imageGroupActivated, setImageGroupActivated] = useState(
    () => typeof IntersectionObserver !== "function"
  );

  useLayoutEffect(() => {
    const element = previewElementRef.current;
    if (!element || (previewImages.length === 0 && inlineVideos.length === 0)) {
      setNearViewport(false);
      return undefined;
    }
    return observeLocalImagePreview(element, (visible) => {
      setNearViewport(visible);
      if (visible) setImageGroupActivated(true);
    });
  }, [inlineVideos.length, previewImages.length]);

  return { imageGroupActivated, nearViewport, previewElementRef };
}
