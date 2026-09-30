import {
  type MouseEvent,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { isReducedMotionEnabled, motionDuration, motionEasing } from "../../tokens";
import { ArrowLeftIcon, ArrowRightIcon } from "../icons";
import {
  computeImageFilmstripFits,
  imageFilmstripBounds,
  imageFilmstripClipPath,
  imageFilmstripPaintWidth,
  imageFilmstripTranslateX,
  type ImageFilmstripBounds,
  type ImageFilmstripFit,
} from "./imageFilmstripGeometry";
import { usePointerPressFeedback } from "./usePointerPressFeedback";

export interface ChatPanelImageFilmstripImage {
  alt: string;
  onContextMenu?: (event: MouseEvent<HTMLElement>) => void;
  src: string;
}

export interface ChatPanelImageFilmstripProps {
  images: ChatPanelImageFilmstripImage[];
  index: number;
  onNavigate: (step: 1 | -1) => void;
}

interface FilmstripLayout {
  bounds: ImageFilmstripBounds;
  fits: ImageFilmstripFit[];
  stageWidth: number;
}

/** Connected-filmstrip curves with Comma's product-tuned navigation duration. */
const NAVIGATION_EASING = "cubic-bezier(0.5, 0, 0, 1)";
const RETARGET_EASING = "cubic-bezier(0.05, 0.7, 0.1, 1)";
const REDUCED_MOTION_DURATION_MS = 150;
const FALLBACK_IMAGE_WIDTH = 1200;
const FALLBACK_IMAGE_HEIGHT = 900;

const watchImageTerminal = (
  image: HTMLImageElement,
  onTerminal: () => void
): (() => void) => {
  if (image.complete) {
    onTerminal();
    return () => undefined;
  }

  const finish = () => {
    image.removeEventListener("load", finish);
    image.removeEventListener("error", finish);
    onTerminal();
  };
  image.addEventListener("load", finish, { once: true });
  image.addEventListener("error", finish, { once: true });
  return () => {
    image.removeEventListener("load", finish);
    image.removeEventListener("error", finish);
  };
};

/**
 * A React port of connected-filmstrip's image switcher. All images remain on
 * one rigid, zero-gap strip; a clip window and the strip translation share a
 * WAAPI timeline so the outgoing and incoming images read as one surface.
 */
export const ChatPanelImageFilmstrip = ({
  images,
  index,
  onNavigate,
}: ChatPanelImageFilmstripProps) => {
  const messages = useCommaMessages();
  const [ready, setReady] = useState(false);
  const stageRef = useRef<HTMLDivElement | null>(null);
  const boundsRef = useRef<HTMLDivElement | null>(null);
  const frameRef = useRef<HTMLDivElement | null>(null);
  const stripRef = useRef<HTMLDivElement | null>(null);
  const imageElementsRef = useRef<(HTMLImageElement | null)[]>([]);
  const previousButtonRef = useRef<HTMLButtonElement | null>(null);
  const nextButtonRef = useRef<HTMLButtonElement | null>(null);
  const deferredLayoutRef = useRef(false);
  const flushDeferredLayoutRef = useRef<() => void>(() => undefined);
  const layoutRef = useRef<FilmstripLayout | null>(null);
  const animationsRef = useRef<Animation[]>([]);
  const navigationGenerationRef = useRef(0);
  const settledIndexRef = useRef<number | null>(null);
  const indexRef = useRef(index);
  const previousPressFeedback = usePointerPressFeedback<HTMLButtonElement>();
  const nextPressFeedback = usePointerPressFeedback<HTMLButtonElement>();

  indexRef.current = index;

  const cancelAnimations = useCallback(() => {
    const animations = animationsRef.current;
    animationsRef.current = [];
    for (const animation of animations) animation.cancel();
  }, []);

  const setSlideSeamOverlap = useCallback((enabled: boolean) => {
    const fits = layoutRef.current?.fits;
    if (!fits) return;

    for (let itemIndex = 0; itemIndex < fits.length; itemIndex += 1) {
      const image = imageElementsRef.current[itemIndex];
      const fit = fits[itemIndex];
      if (!image || !fit) continue;
      image.style.width = `${enabled ? imageFilmstripPaintWidth(fit) : fit.width}px`;
    }

    const stage = stageRef.current;
    if (stage) {
      if (enabled) stage.dataset.seamOverlap = "true";
      else delete stage.dataset.seamOverlap;
    }
  }, []);

  const settle = useCallback(
    (targetIndex: number) => {
      const frame = frameRef.current;
      const strip = stripRef.current;
      const layout = layoutRef.current;
      const fit = layout?.fits[targetIndex];
      if (!frame || !strip || !layout || !fit) return;

      cancelAnimations();
      setSlideSeamOverlap(false);
      frame.style.clipPath = imageFilmstripClipPath(
        fit,
        layout.stageWidth,
        layout.bounds
      );
      strip.style.transform = `translateX(${imageFilmstripTranslateX(fit)}px)`;
      settledIndexRef.current = targetIndex;
      delete stageRef.current?.dataset.motion;
    },
    [cancelAnimations, setSlideSeamOverlap]
  );

  const layoutAndSettle = useCallback(() => {
    const stage = stageRef.current;
    const contentBounds = boundsRef.current;
    if (!stage || !contentBounds) return false;

    const stageWidth = stage.clientWidth;
    const stageHeight = stage.clientHeight;
    const maxSlideWidth = contentBounds.clientWidth;
    if (stageWidth <= 0 || stageHeight <= 0 || maxSlideWidth <= 0) return false;

    const itemSizes = images.map((_, itemIndex) => {
      const image = imageElementsRef.current[itemIndex];
      return {
        height: image?.naturalHeight || FALLBACK_IMAGE_HEIGHT,
        width: image?.naturalWidth || FALLBACK_IMAGE_WIDTH,
      };
    });
    const fits = computeImageFilmstripFits(
      itemSizes,
      stageWidth,
      stageHeight,
      maxSlideWidth
    );
    const bounds = imageFilmstripBounds(fits, stageHeight);

    for (let itemIndex = 0; itemIndex < fits.length; itemIndex += 1) {
      const image = imageElementsRef.current[itemIndex];
      const fit = fits[itemIndex];
      if (!image || !fit) continue;
      image.style.left = `${fit.offset}px`;
      image.style.top = `${fit.y}px`;
      image.style.width = `${fit.width}px`;
      image.style.height = `${fit.height}px`;
    }

    layoutRef.current = { bounds, fits, stageWidth };
    settle(indexRef.current);
    return true;
  }, [images, settle]);

  useLayoutEffect(() => {
    let disposed = false;
    setReady(false);

    const applyLayout = () => {
      if (disposed) return;
      const laidOut = layoutAndSettle();
      const activeIndex = indexRef.current;
      const activeImage = imageElementsRef.current[activeIndex];
      const activeReady = Boolean(laidOut && activeImage?.complete);
      setReady(activeReady);
    };
    const refreshLayout = () => {
      if (animationsRef.current.length > 0) {
        deferredLayoutRef.current = true;
        return;
      }
      deferredLayoutRef.current = false;
      applyLayout();
    };
    flushDeferredLayoutRef.current = () => {
      if (!deferredLayoutRef.current) return;
      deferredLayoutRef.current = false;
      applyLayout();
    };
    refreshLayout();

    const imageElements = imageElementsRef.current
      .slice(0, images.length)
      .filter((image): image is HTMLImageElement => image !== null);

    const stopWatchingImages = imageElements.map((image) =>
      watchImageTerminal(image, refreshLayout)
    );

    const handleResize = () => refreshLayout();
    window.addEventListener("resize", handleResize);
    return () => {
      disposed = true;
      deferredLayoutRef.current = false;
      flushDeferredLayoutRef.current = () => undefined;
      for (const stopWatching of stopWatchingImages) stopWatching();
      window.removeEventListener("resize", handleResize);
      navigationGenerationRef.current += 1;
      cancelAnimations();
    };
  }, [cancelAnimations, images.length, layoutAndSettle]);

  useLayoutEffect(() => {
    if (index === 0 && document.activeElement === previousButtonRef.current) {
      nextButtonRef.current?.focus({ preventScroll: true });
    } else if (
      index === images.length - 1 &&
      document.activeElement === nextButtonRef.current
    ) {
      previousButtonRef.current?.focus({ preventScroll: true });
    }
  }, [images.length, index]);

  useLayoutEffect(() => {
    const targetImage = imageElementsRef.current[index];
    if (!targetImage?.complete) {
      if (ready) setReady(false);
      return;
    }
    if (!ready) {
      setReady(true);
      return;
    }
    if (settledIndexRef.current === index && animationsRef.current.length === 0) {
      return;
    }

    const frame = frameRef.current;
    const strip = stripRef.current;
    const layout = layoutRef.current;
    const fit = layout?.fits[index];
    if (!frame || !strip || !layout || !fit) return;

    const generation = navigationGenerationRef.current + 1;
    navigationGenerationRef.current = generation;
    const activeAnimation = animationsRef.current[0];
    const active = activeAnimation !== undefined;
    const progress = activeAnimation?.effect?.getComputedTiming().progress ?? 1;
    const fromClipPath = active
      ? getComputedStyle(frame).clipPath
      : frame.style.clipPath;
    const fromTransform = active
      ? getComputedStyle(strip).transform
      : strip.style.transform;
    const fromOpacity = getComputedStyle(frame).opacity;

    cancelAnimations();
    setSlideSeamOverlap(false);
    frame.style.clipPath = fromClipPath;
    strip.style.transform = fromTransform;

    if (isReducedMotionEnabled() && typeof frame.animate === "function") {
      stageRef.current?.setAttribute("data-motion", "fade");
      const halfDuration = REDUCED_MOTION_DURATION_MS / 2;
      const fadeOut = frame.animate([{ opacity: fromOpacity }, { opacity: 0 }], {
        duration: halfDuration,
        easing: motionEasing.smoothOut,
        fill: "forwards",
      });
      animationsRef.current = [fadeOut];
      void fadeOut.finished.then(
        () => {
          if (navigationGenerationRef.current !== generation) return;
          settle(index);
          stageRef.current?.setAttribute("data-motion", "fade");
          const fadeIn = frame.animate([{ opacity: 0 }, { opacity: 1 }], {
            duration: halfDuration,
            easing: motionEasing.smoothOut,
          });
          animationsRef.current = [fadeIn];
          void fadeIn.finished.then(
            () => {
              if (
                navigationGenerationRef.current === generation &&
                animationsRef.current.includes(fadeIn)
              ) {
                animationsRef.current = [];
                delete stageRef.current?.dataset.motion;
                flushDeferredLayoutRef.current();
              }
            },
            () => undefined
          );
        },
        () => undefined
      );
      return;
    }

    if (
      isReducedMotionEnabled() ||
      typeof frame.animate !== "function" ||
      typeof strip.animate !== "function"
    ) {
      settle(index);
      flushDeferredLayoutRef.current();
      return;
    }

    const interruptedDuringVisiblePhase = active && progress < 0.5;
    const timing: KeyframeAnimationOptions = {
      duration: motionDuration.imageFilmstrip,
      easing: interruptedDuringVisiblePhase ? RETARGET_EASING : NAVIGATION_EASING,
      fill: "forwards",
    };
    setSlideSeamOverlap(true);
    stageRef.current?.setAttribute("data-motion", "spatial");
    const animations = [
      frame.animate(
        [
          { clipPath: fromClipPath },
          {
            clipPath: imageFilmstripClipPath(fit, layout.stageWidth, layout.bounds),
          },
        ],
        timing
      ),
      strip.animate(
        [
          { transform: fromTransform },
          { transform: `translateX(${imageFilmstripTranslateX(fit)}px)` },
        ],
        timing
      ),
    ];
    animationsRef.current = animations;
    void Promise.all(animations.map((animation) => animation.finished)).then(
      () => {
        if (navigationGenerationRef.current === generation) {
          settle(indexRef.current);
          flushDeferredLayoutRef.current();
        }
      },
      () => undefined
    );
  }, [cancelAnimations, index, ready, setSlideSeamOverlap, settle]);

  useEffect(
    () => () => {
      navigationGenerationRef.current += 1;
      cancelAnimations();
    },
    [cancelAnimations]
  );

  // Arrow keys browse the strip wherever it is mounted. The filmstrip only
  // ever lives inside an open preview, so the listener's lifetime is the
  // preview's and no host has to wire the shortcut itself.
  useEffect(() => {
    if (images.length <= 1) return undefined;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) {
        return;
      }
      if (event.key === "ArrowLeft") {
        event.preventDefault();
        onNavigate(-1);
      } else if (event.key === "ArrowRight") {
        event.preventDefault();
        onNavigate(1);
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [images.length, onNavigate]);

  const activeImage = images[index];
  const hasMultipleImages = images.length > 1;
  // A strip end is an aria-disabled state, never the native attribute: the
  // browser blurs an element the moment it is natively disabled, and the
  // control the viewer just pressed is exactly the one that turns unusable —
  // focus would land on the body, outside the dialog, with Escape dead.
  const atStart = index === 0;
  const atEnd = index === images.length - 1;

  return (
    <div
      className="chat-panel-image-filmstrip"
      data-active-index={index}
      data-ready={ready ? "true" : "false"}
      ref={stageRef}
    >
      <div aria-hidden className="chat-panel-image-filmstrip-bounds" ref={boundsRef} />
      <div
        className="chat-panel-image-filmstrip-frame"
        data-filmstrip-layer="clip"
        ref={frameRef}
      >
        <div
          className="chat-panel-image-filmstrip-strip"
          data-filmstrip-layer="strip"
          ref={stripRef}
        >
          {images.map((image, itemIndex) => (
            // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- The image owns its context menu, including the keyboard context-menu gesture.
            <img
              alt={image.alt}
              aria-hidden={itemIndex === index ? undefined : true}
              className="chat-panel-image-filmstrip-slide"
              draggable={false}
              data-media-context-menu={image.onContextMenu ? "true" : undefined}
              onContextMenu={image.onContextMenu}
              // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- Focus enables Shift+F10 on the displayed image without adding a second activation action.
              tabIndex={image.onContextMenu && itemIndex === index ? 0 : undefined}
              key={`${image.src}:${itemIndex}`}
              ref={(element) => {
                imageElementsRef.current[itemIndex] = element;
              }}
              src={image.src}
            />
          ))}
        </div>
      </div>
      {hasMultipleImages ? (
        <>
          <button
            aria-disabled={atStart || undefined}
            aria-label={messages.chat_image_group_previous()}
            className="chat-panel-image-filmstrip-navigation"
            data-side="start"
            {...previousPressFeedback}
            onClick={() => {
              if (atStart) return;
              onNavigate(-1);
            }}
            ref={previousButtonRef}
            type="button"
          >
            <ArrowLeftIcon className="size-2xl" />
          </button>
          <button
            aria-disabled={atEnd || undefined}
            aria-label={messages.chat_image_group_next()}
            className="chat-panel-image-filmstrip-navigation"
            data-side="end"
            {...nextPressFeedback}
            onClick={() => {
              if (atEnd) return;
              onNavigate(1);
            }}
            ref={nextButtonRef}
            type="button"
          >
            <ArrowRightIcon className="size-2xl" />
          </button>
        </>
      ) : null}
      <output aria-live="polite" className="sr-only">
        {activeImage
          ? messages.chat_image_group_position({
              alt: activeImage.alt,
              count: String(images.length),
              position: String(index + 1),
            })
          : ""}
      </output>
    </div>
  );
};
