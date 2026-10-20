import type { BrowserViewValue } from "@comma/core-client";
import { useEffect, useRef } from "react";
import type { BrowserViewport } from "./browserInput";

/**
 * Draws the newest frame the core streamed onto the canvas. A frame that
 * arrives while one is still being decoded is skipped; the next one draws.
 */
export function useBrowserStream(frame: BrowserViewValue["frame"]) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const viewport = useRef<BrowserViewport>({ width: 1280, height: 720 });
  const drawing = useRef(false);
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  const seq = frame?.seq;
  useEffect(() => {
    if (!frame || drawing.current) return;
    viewport.current = { width: frame.width, height: frame.height };
    drawing.current = true;
    const image = new Image();
    image.addEventListener("load", () => {
      if (alive.current && canvas.current) {
        const surface = canvas.current;
        surface.width = image.naturalWidth;
        surface.height = image.naturalHeight;
        surface.style.aspectRatio = `${image.naturalWidth}/${image.naturalHeight}`;
        surface.getContext("2d")?.drawImage(image, 0, 0);
      }
      drawing.current = false;
    });
    image.addEventListener("error", () => {
      drawing.current = false;
    });
    image.src = `data:image/jpeg;base64,${frame.data}`;
    // A frame is drawn once, when it arrives.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [seq]);
  return { canvas, viewport };
}
