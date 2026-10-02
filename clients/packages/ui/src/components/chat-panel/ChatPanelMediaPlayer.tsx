import {
  type ChangeEvent,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactEventHandler,
  type RefCallback,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { Button as AriaButton } from "react-aria-components";
import {
  isReducedMotionEnabled,
  motionDuration,
  motionEasing,
  spacing,
  subscribeToReducedMotion,
} from "../../tokens";
import {
  CheckIcon,
  MediaDownloadIcon,
  MediaExpandIcon,
  PauseIcon,
  PlayIcon,
} from "../icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "../menu";
import {
  detectAppKeybindingPlatform,
  type AppKeybindingPlatform,
} from "../settings-shortcut/appKeybinding";
import { cx } from "../utils";
import {
  type ChatPanelMediaDownloadController,
  ChatPanelMediaDownloadControl,
} from "./ChatPanelMediaDownloadControl";
import { MediaControlTooltip, mediaControlShortcuts } from "./MediaControlTooltip";
import {
  isMediaMuteShortcut,
  mediaVolumeLevel,
  MediaVolumeControl,
} from "./MediaVolumeControl";
import { useKeyboardFocusMotion } from "./useKeyboardFocusMotion";
import { usePointerPressFeedback } from "./usePointerPressFeedback";

const playbackRates = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2] as const;
const maximumTransientPlayRetries = 2;
const mediaKeyboardSeekStepSeconds = 5;
const useBrowserLayoutEffect =
  typeof window === "undefined" ? useEffect : useLayoutEffect;

type MediaElement = HTMLAudioElement | HTMLVideoElement;
type MediaTone = "light" | "dark";

interface PlaybackControllerOptions {
  defaultCurrentTime?: number | undefined;
  defaultPlaying?: boolean | undefined;
  duration: number;
  sourceKey?: string | undefined;
}

export interface MediaPlaybackController {
  bindMediaElement: RefCallback<MediaElement>;
  beginScrubbing: () => void;
  currentTime: number;
  duration: number;
  endScrubbing: () => void;
  handleCanPlay: ReactEventHandler<MediaElement>;
  handleDurationChange: ReactEventHandler<MediaElement>;
  handleEmptied: ReactEventHandler<MediaElement>;
  handleEnded: ReactEventHandler<MediaElement>;
  handleLoadedMetadata: ReactEventHandler<MediaElement>;
  handlePause: ReactEventHandler<MediaElement>;
  handlePlay: ReactEventHandler<MediaElement>;
  handleRateChange: ReactEventHandler<MediaElement>;
  handleTimeUpdate: ReactEventHandler<MediaElement>;
  isPlaying: boolean;
  pause: () => void;
  playbackRate: number;
  setCurrentTime: (value: number) => void;
  setPlaybackRate: (value: number) => void;
  setVolume: (value: number) => void;
  toggleMuted: () => void;
  togglePlaying: () => void;
  volume: number;
  volumeLevel: number;
}

export interface ChatPanelMediaPlayerProps {
  controller: MediaPlaybackController;
  downloadController?: ChatPanelMediaDownloadController;
  kind: "audio" | "video";
  onExpand?: (event: ReactMouseEvent<HTMLButtonElement>) => void;
  tone?: MediaTone;
}

const clamp = (value: number, minimum: number, maximum: number) =>
  Math.min(maximum, Math.max(minimum, value));

const getReducedMotionServerSnapshot = () => false;

const usePrefersReducedMotion = () =>
  useSyncExternalStore(
    subscribeToReducedMotion,
    isReducedMotionEnabled,
    getReducedMotionServerSnapshot
  );

export const formatMediaTime = (seconds: number) => {
  const safeSeconds = Number.isFinite(seconds) ? Math.max(0, seconds) : 0;
  const minutes = Math.floor(safeSeconds / 60);
  const remainingSeconds = Math.floor(safeSeconds % 60);
  return `${String(minutes).padStart(2, "0")}:${String(remainingSeconds).padStart(
    2,
    "0"
  )}`;
};

const formatPlaybackRate = (rate: number) => `${rate}x`;

export { MediaControlTooltip, mediaControlShortcuts };

export const resolveMediaFullWindowShortcut = (
  platform: AppKeybindingPlatform = detectAppKeybindingPlatform()
) =>
  platform === "macos"
    ? ({ eventModifier: "metaKey", keys: ["⌘", "Click"] } as const)
    : ({ eventModifier: "ctrlKey", keys: ["Ctrl", "Click"] } as const);

const stepPlaybackRateValue = (current: number, direction: -1 | 1) => {
  const currentIndex = playbackRates.findIndex((rate) => rate === current);
  const index =
    currentIndex >= 0
      ? currentIndex
      : playbackRates.reduce((closestIndex, rate, candidateIndex) => {
          const closestRate = playbackRates[closestIndex]!;
          return Math.abs(rate - current) < Math.abs(closestRate - current)
            ? candidateIndex
            : closestIndex;
        }, 0);
  return playbackRates[clamp(index + direction, 0, playbackRates.length - 1)]!;
};

export const useMediaPlaybackController = ({
  defaultCurrentTime = 0,
  defaultPlaying = false,
  duration: durationFallback,
  sourceKey,
}: PlaybackControllerOptions): MediaPlaybackController => {
  const [currentTime, setCurrentTimeState] = useState(() =>
    clamp(defaultCurrentTime, 0, durationFallback)
  );
  const [duration, setDuration] = useState(durationFallback);
  const [isPlaying, setIsPlaying] = useState(defaultPlaying);
  const [playbackRate, setPlaybackRateState] = useState(1);
  const [volume, setVolumeState] = useState(1);
  const mediaElementRef = useRef<MediaElement | null>(null);
  const lastAudibleVolumeRef = useRef(1);
  const playRequestGenerationRef = useRef(0);
  const pendingPlayRequestRef = useRef<{
    element: MediaElement;
    generation: number;
  } | null>(null);
  const scheduledPlayRetryRef = useRef<{
    cancel: () => void;
    element: MediaElement;
  } | null>(null);
  const transientPlayRetryCountRef = useRef(0);
  const initializedMediaElementsRef = useRef(new WeakSet<MediaElement>());
  const isScrubbingRef = useRef(false);
  const resumeAfterScrubbingRef = useRef(false);
  const desiredPlayingRef = useRef(defaultPlaying);
  const playbackPhaseRef = useRef<"paused" | "playing" | "requesting">(
    defaultPlaying ? "requesting" : "paused"
  );
  const sourceKeyRef = useRef(sourceKey);
  const latestStateRef = useRef({
    currentTime,
    isPlaying,
    playbackRate,
    volume,
  });

  latestStateRef.current = {
    currentTime,
    isPlaying,
    playbackRate,
    volume,
  };

  const invalidatePlayRequests = useCallback(() => {
    playRequestGenerationRef.current += 1;
    pendingPlayRequestRef.current = null;
    scheduledPlayRetryRef.current?.cancel();
    scheduledPlayRetryRef.current = null;
  }, []);

  const setPlaybackPhase = useCallback((phase: "paused" | "playing" | "requesting") => {
    playbackPhaseRef.current = phase;
    const nextIsPlaying = phase !== "paused";
    latestStateRef.current.isPlaying = nextIsPlaying;
    setIsPlaying(nextIsPlaying);
  }, []);

  const requestPlay = useCallback(
    function attemptPlay(element: MediaElement) {
      if (
        mediaElementRef.current !== element ||
        !desiredPlayingRef.current ||
        pendingPlayRequestRef.current?.element === element ||
        scheduledPlayRetryRef.current?.element === element
      ) {
        return;
      }

      const requestGeneration = playRequestGenerationRef.current + 1;
      playRequestGenerationRef.current = requestGeneration;
      pendingPlayRequestRef.current = {
        element,
        generation: requestGeneration,
      };

      let playRequest: Promise<void> | undefined;
      try {
        playRequest = element.play();
      } catch {
        pendingPlayRequestRef.current = null;
        if (
          playRequestGenerationRef.current === requestGeneration &&
          mediaElementRef.current === element
        ) {
          desiredPlayingRef.current = false;
          setPlaybackPhase("paused");
        }
        return;
      }

      void Promise.resolve(playRequest)
        .then(() => {
          if (pendingPlayRequestRef.current?.generation === requestGeneration) {
            pendingPlayRequestRef.current = null;
          }
          if (mediaElementRef.current !== element) {
            element.pause();
            return;
          }
          if (!desiredPlayingRef.current) {
            element.pause();
            return;
          }
          if (playRequestGenerationRef.current === requestGeneration) {
            transientPlayRetryCountRef.current = 0;
            setPlaybackPhase("playing");
          }
        })
        .catch((error: unknown) => {
          if (pendingPlayRequestRef.current?.generation === requestGeneration) {
            pendingPlayRequestRef.current = null;
          }
          if (
            playRequestGenerationRef.current !== requestGeneration ||
            mediaElementRef.current !== element
          ) {
            return;
          }
          if (
            desiredPlayingRef.current &&
            error instanceof DOMException &&
            error.name === "AbortError"
          ) {
            setPlaybackPhase("requesting");
            if (transientPlayRetryCountRef.current >= maximumTransientPlayRetries) {
              desiredPlayingRef.current = false;
              setPlaybackPhase("paused");
              return;
            }

            transientPlayRetryCountRef.current += 1;
            const retryGeneration = playRequestGenerationRef.current;
            const retry = () => {
              scheduledPlayRetryRef.current = null;
              if (
                playRequestGenerationRef.current !== retryGeneration ||
                mediaElementRef.current !== element ||
                !desiredPlayingRef.current ||
                !element.paused
              ) {
                return;
              }
              attemptPlay(element);
            };
            const ownerWindow = element.ownerDocument.defaultView;
            const timeout = ownerWindow
              ? ownerWindow.setTimeout(retry, 0)
              : setTimeout(retry, 0);
            scheduledPlayRetryRef.current = {
              cancel: () =>
                ownerWindow ? ownerWindow.clearTimeout(timeout) : clearTimeout(timeout),
              element,
            };
            return;
          }
          desiredPlayingRef.current = false;
          setPlaybackPhase("paused");
        });
    },
    [setPlaybackPhase]
  );

  const bindMediaElement = useCallback<RefCallback<MediaElement>>(
    (element) => {
      if (!element) return;

      const previousElement = mediaElementRef.current;
      if (previousElement === element) return;

      invalidatePlayRequests();
      mediaElementRef.current = element;
      const latest = latestStateRef.current;
      const handoffTime =
        previousElement &&
        initializedMediaElementsRef.current.has(previousElement) &&
        Number.isFinite(previousElement.currentTime)
          ? previousElement.currentTime
          : latest.currentTime;
      try {
        element.currentTime = handoffTime;
      } catch {
        // A newly mounted media element applies the handoff seek after metadata.
      }
      latest.currentTime = handoffTime;
      element.playbackRate = latest.playbackRate;
      element.volume = latest.volume;
      if (previousElement && previousElement !== element && !previousElement.paused) {
        previousElement.pause();
      }
      if (desiredPlayingRef.current) {
        transientPlayRetryCountRef.current = 0;
        setPlaybackPhase("requesting");
        requestPlay(element);
      }

      return () => {
        if (mediaElementRef.current !== element) return;
        if (
          initializedMediaElementsRef.current.has(element) &&
          Number.isFinite(element.currentTime)
        ) {
          latestStateRef.current.currentTime = element.currentTime;
        }
        mediaElementRef.current = null;
        invalidatePlayRequests();
        if (!element.paused) element.pause();
      };
    },
    [invalidatePlayRequests, requestPlay, setPlaybackPhase]
  );

  const setCurrentTime = useCallback(
    (value: number) => {
      const nextValue = clamp(value, 0, duration);
      latestStateRef.current.currentTime = nextValue;
      setCurrentTimeState(nextValue);
      if (mediaElementRef.current) {
        mediaElementRef.current.currentTime = nextValue;
      }
    },
    [duration]
  );

  const pausePlayback = useCallback(
    (element = mediaElementRef.current) => {
      desiredPlayingRef.current = false;
      invalidatePlayRequests();
      setPlaybackPhase("paused");
      element?.pause();
    },
    [invalidatePlayRequests, setPlaybackPhase]
  );

  const beginScrubbing = useCallback(() => {
    if (isScrubbingRef.current) return;

    isScrubbingRef.current = true;
    resumeAfterScrubbingRef.current = desiredPlayingRef.current;
    if (!resumeAfterScrubbingRef.current) return;

    pausePlayback();
  }, [pausePlayback]);

  const endScrubbing = useCallback(() => {
    if (!isScrubbingRef.current) return;

    isScrubbingRef.current = false;
    const shouldResume = resumeAfterScrubbingRef.current;
    resumeAfterScrubbingRef.current = false;
    if (!shouldResume) return;

    desiredPlayingRef.current = true;
    transientPlayRetryCountRef.current = 0;
    setPlaybackPhase("requesting");
    const element = mediaElementRef.current;
    if (element) requestPlay(element);
  }, [requestPlay, setPlaybackPhase]);

  const resetForSource = useCallback(
    (element: MediaElement | null = mediaElementRef.current) => {
      isScrubbingRef.current = false;
      resumeAfterScrubbingRef.current = false;
      invalidatePlayRequests();
      desiredPlayingRef.current = false;
      setPlaybackPhase("paused");
      latestStateRef.current.currentTime = 0;
      latestStateRef.current.playbackRate = 1;
      setCurrentTimeState(0);
      setDuration(durationFallback);
      setPlaybackRateState(1);

      if (!element) return;
      element.pause();
      try {
        element.currentTime = 0;
      } catch {
        // A source can be between native load phases and reject a seek to zero.
      }
      element.playbackRate = 1;
    },
    [durationFallback, invalidatePlayRequests, setPlaybackPhase]
  );

  useBrowserLayoutEffect(() => {
    if (Object.is(sourceKeyRef.current, sourceKey)) return;
    sourceKeyRef.current = sourceKey;
    resetForSource();
  }, [resetForSource, sourceKey]);

  const setPlaybackRate = useCallback((value: number) => {
    setPlaybackRateState(value);
    latestStateRef.current.playbackRate = value;
    if (mediaElementRef.current) {
      mediaElementRef.current.playbackRate = value;
    }
  }, []);

  const setVolume = useCallback((value: number) => {
    const nextVolume = clamp(value, 0, 1);
    if (nextVolume > 0) lastAudibleVolumeRef.current = nextVolume;
    latestStateRef.current.volume = nextVolume;
    setVolumeState(nextVolume);
    if (mediaElementRef.current) {
      mediaElementRef.current.volume = nextVolume;
    }
  }, []);

  const toggleMuted = useCallback(() => {
    const currentVolume = latestStateRef.current.volume;
    if (currentVolume > 0) lastAudibleVolumeRef.current = currentVolume;
    const nextVolume =
      currentVolume > 0 ? 0 : clamp(lastAudibleVolumeRef.current || 1, 0, 1);
    latestStateRef.current.volume = nextVolume;
    setVolumeState(nextVolume);
    if (mediaElementRef.current) {
      mediaElementRef.current.volume = nextVolume;
    }
  }, []);

  const togglePlaying = useCallback(() => {
    const element = mediaElementRef.current;
    if (!element) return;

    if (playbackPhaseRef.current !== "paused") {
      pausePlayback(element);
      return;
    }

    if (element.ended || element.currentTime >= duration) {
      element.currentTime = 0;
      latestStateRef.current.currentTime = 0;
      setCurrentTimeState(0);
    }
    desiredPlayingRef.current = true;
    transientPlayRetryCountRef.current = 0;
    setPlaybackPhase("requesting");
    requestPlay(element);
  }, [duration, pausePlayback, requestPlay, setPlaybackPhase]);

  const retryDesiredPlayback = (element: MediaElement) => {
    if (
      element !== mediaElementRef.current ||
      !desiredPlayingRef.current ||
      !element.paused ||
      pendingPlayRequestRef.current?.element === element
    ) {
      return;
    }
    setPlaybackPhase("requesting");
    requestPlay(element);
  };

  return {
    bindMediaElement,
    beginScrubbing,
    currentTime,
    duration,
    endScrubbing,
    handleCanPlay: (event) => {
      retryDesiredPlayback(event.currentTarget);
    },
    handleDurationChange: (event) => {
      if (
        event.currentTarget === mediaElementRef.current &&
        Number.isFinite(event.currentTarget.duration)
      ) {
        setDuration(event.currentTarget.duration);
      }
    },
    handleEmptied: (event) => {
      if (event.currentTarget !== mediaElementRef.current) return;
      if (!initializedMediaElementsRef.current.has(event.currentTarget)) return;
      initializedMediaElementsRef.current.delete(event.currentTarget);
      resetForSource(event.currentTarget);
    },
    handleEnded: (event) => {
      if (event.currentTarget !== mediaElementRef.current) return;
      isScrubbingRef.current = false;
      resumeAfterScrubbingRef.current = false;
      invalidatePlayRequests();
      desiredPlayingRef.current = false;
      const endedAt = Number.isFinite(event.currentTarget.duration)
        ? event.currentTarget.duration
        : duration;
      latestStateRef.current.currentTime = endedAt;
      setCurrentTimeState(endedAt);
      setPlaybackPhase("paused");
    },
    handleLoadedMetadata: (event) => {
      const element = event.currentTarget;
      if (element !== mediaElementRef.current) return;

      initializedMediaElementsRef.current.add(element);
      const maximumTime = Number.isFinite(element.duration)
        ? element.duration
        : durationFallback;
      const handoffTime = clamp(latestStateRef.current.currentTime, 0, maximumTime);
      if (Math.abs(element.currentTime - handoffTime) > 0.05) {
        try {
          element.currentTime = handoffTime;
        } catch {
          // The native player will retain its current position if seeking is unavailable.
        }
      }
      latestStateRef.current.currentTime = handoffTime;
      setCurrentTimeState(handoffTime);
      retryDesiredPlayback(element);
    },
    handlePause: (event) => {
      if (event.currentTarget !== mediaElementRef.current) return;
      if (
        desiredPlayingRef.current &&
        (event.currentTarget.readyState === 0 ||
          playbackPhaseRef.current === "requesting" ||
          pendingPlayRequestRef.current?.element === event.currentTarget)
      ) {
        setPlaybackPhase("requesting");
        return;
      }
      desiredPlayingRef.current = false;
      invalidatePlayRequests();
      setPlaybackPhase("paused");
    },
    handlePlay: (event) => {
      if (event.currentTarget !== mediaElementRef.current) return;
      initializedMediaElementsRef.current.add(event.currentTarget);
      if (!desiredPlayingRef.current) {
        event.currentTarget.pause();
        return;
      }
      setPlaybackPhase("playing");
    },
    handleRateChange: (event) => {
      if (event.currentTarget !== mediaElementRef.current) return;
      const nextPlaybackRate = event.currentTarget.playbackRate;
      if (!Number.isFinite(nextPlaybackRate) || nextPlaybackRate <= 0) return;
      latestStateRef.current.playbackRate = nextPlaybackRate;
      setPlaybackRateState(nextPlaybackRate);
    },
    handleTimeUpdate: (event) => {
      if (event.currentTarget === mediaElementRef.current) {
        initializedMediaElementsRef.current.add(event.currentTarget);
        latestStateRef.current.currentTime = event.currentTarget.currentTime;
        setCurrentTimeState(event.currentTarget.currentTime);
      }
    },
    isPlaying,
    pause: () => pausePlayback(),
    playbackRate,
    setCurrentTime,
    setPlaybackRate,
    setVolume,
    toggleMuted,
    togglePlaying,
    volume,
    volumeLevel: mediaVolumeLevel(volume),
  };
};

const useInstantInteractionMotion = () => {
  const [instant, setInstant] = useState(false);
  const animationFramesRef = useRef<number[]>([]);

  useEffect(
    () => () => {
      for (const frame of animationFramesRef.current) cancelAnimationFrame(frame);
    },
    []
  );

  const run = useCallback((withoutMotion: boolean, action: () => void) => {
    for (const frame of animationFramesRef.current) cancelAnimationFrame(frame);
    animationFramesRef.current = [];
    setInstant(withoutMotion);
    action();
    if (!withoutMotion) return;

    const firstFrame = requestAnimationFrame(() => {
      const secondFrame = requestAnimationFrame(() => setInstant(false));
      animationFramesRef.current = [secondFrame];
    });
    animationFramesRef.current = [firstFrame];
  }, []);

  return { instant, run };
};

const PlayPauseIcon = ({ isPlaying }: { isPlaying: boolean }) => (
  <span
    aria-hidden="true"
    className="t-icon-swap size-2xl"
    data-state={isPlaying ? "b" : "a"}
  >
    <span className="t-icon inline-flex size-2xl" data-icon="a">
      <PlayIcon className="size-2xl" />
    </span>
    <span className="t-icon inline-flex size-2xl" data-icon="b">
      <PauseIcon className="size-2xl" />
    </span>
  </span>
);

const PlaybackRateValue = ({ animate, rate }: { animate: boolean; rate: number }) => {
  const label = formatPlaybackRate(rate);
  const prefersReducedMotion = usePrefersReducedMotion();
  const valueRef = useRef<HTMLSpanElement | null>(null);
  const previousRateRef = useRef(rate);
  const activeAnimationRef = useRef<Animation | null>(null);

  useEffect(
    () => () => {
      activeAnimationRef.current?.cancel();
    },
    []
  );

  useBrowserLayoutEffect(() => {
    const rateChanged = previousRateRef.current !== rate;
    previousRateRef.current = rate;

    const element = valueRef.current;
    if (!element) return;

    const activeAnimation = activeAnimationRef.current;
    if (!animate || prefersReducedMotion || typeof element.animate !== "function") {
      activeAnimation?.cancel();
      activeAnimationRef.current = null;
      return;
    }
    if (!rateChanged) return;
    if (
      activeAnimation &&
      activeAnimation.playState !== "finished" &&
      activeAnimation.playState !== "idle"
    ) {
      return;
    }

    const styles = getComputedStyle(element);
    const duration = Number.parseFloat(
      styles.getPropertyValue("--motion-duration-state-change")
    );
    const easing =
      styles.getPropertyValue("--icon-swap-ease").trim() ||
      motionEasing.generatedMediaSwap;
    const animation = element.animate(
      [
        {
          opacity: 0,
          transform: `translateY(${styles
            .getPropertyValue("--spacing-xs")
            .trim()}) scale(${styles
            .getPropertyValue("--motion-scale-pressed")
            .trim()})`,
        },
        { opacity: 1, transform: "translateY(0) scale(1)" },
      ],
      {
        duration: Number.isFinite(duration) ? duration : motionDuration.stateChange,
        easing,
        fill: "both",
      }
    );
    activeAnimationRef.current = animation;
    void animation.finished
      .then(() => {
        if (activeAnimationRef.current !== animation) return;
        animation.cancel();
        activeAnimationRef.current = null;
      })
      .catch(() => undefined);
  }, [animate, prefersReducedMotion, rate]);

  return (
    <span aria-hidden="true" className="chat-panel-media-speed-value" ref={valueRef}>
      {Array.from(label).map((character, index) => (
        <span className="chat-panel-media-speed-digit" key={`${character}-${index}`}>
          {character}
        </span>
      ))}
    </span>
  );
};

const controlBaseClassName =
  "chat-panel-media-control inline-flex h-3xl shrink-0 items-center justify-center border-0 p-xxs outline-none";
export const mediaControlClassName = `${controlBaseClassName} min-w-3xl focus-visible:shadow-focus-gray-shadow-xs`;

export const ChatPanelMediaPlayer = ({
  controller,
  downloadController,
  kind,
  onExpand,
  tone = "light",
}: ChatPanelMediaPlayerProps) => {
  const { instant, run } = useInstantInteractionMotion();
  const { beginScrubbing, endScrubbing } = controller;
  const keyboardFocusMotion = useKeyboardFocusMotion();
  const buttonPressFeedback = usePointerPressFeedback<HTMLButtonElement>();
  const [animateSpeedChange, setAnimateSpeedChange] = useState(false);
  const [rateMenuOpen, setRateMenuOpen] = useState(false);
  const [ratePopoverPresent, setRatePopoverPresent] = useState(false);
  const [rateMenuInstantMotion, setRateMenuInstantMotion] = useState(false);
  const [volumePopoverOpen, setVolumePopoverOpen] = useState(false);
  const progressElementRef = useRef<HTMLInputElement | null>(null);
  const progressRootElementRef = useRef<HTMLSpanElement | null>(null);
  const progressVisualElementRef = useRef<HTMLSpanElement | null>(null);
  const progressDragPointerIdRef = useRef<number | null>(null);
  const progressHoverFrameRef = useRef<number | null>(null);
  const rateInputWasKeyboardRef = useRef(false);
  const rateMenuOpenPendingRef = useRef(false);
  const ratePointerPressActiveRef = useRef(false);
  const controlsPinned = rateMenuOpen || ratePopoverPresent || volumePopoverOpen;
  const progress =
    controller.duration > 0
      ? clamp((controller.currentTime / controller.duration) * 100, 0, 100)
      : 0;
  const progressStyle = {
    "--chat-panel-media-progress": `${progress}%`,
  } as CSSProperties;
  const fullWindowShortcut = resolveMediaFullWindowShortcut();
  const mediaLabel = kind === "audio" ? "Audio" : "Video";
  const progressLabel = `${formatMediaTime(
    controller.currentTime
  )} of ${formatMediaTime(controller.duration)}`;

  useEffect(
    () => () => {
      if (progressHoverFrameRef.current !== null) {
        cancelAnimationFrame(progressHoverFrameRef.current);
      }
      if (progressDragPointerIdRef.current !== null) {
        progressDragPointerIdRef.current = null;
        endScrubbing();
      }
    },
    [endScrubbing]
  );

  const handleProgressChange = (event: ChangeEvent<HTMLInputElement>) => {
    controller.setCurrentTime(Number(event.currentTarget.value));
  };

  const handleProgressKeyDown = (event: ReactKeyboardEvent<HTMLInputElement>) => {
    const direction =
      event.key === "ArrowRight" || event.key === "ArrowUp"
        ? 1
        : event.key === "ArrowLeft" || event.key === "ArrowDown"
          ? -1
          : 0;
    if (direction === 0) return;

    event.preventDefault();
    controller.setCurrentTime(
      controller.currentTime + direction * mediaKeyboardSeekStepSeconds
    );
  };

  const handlePlayerKeyDown = (event: ReactKeyboardEvent<HTMLFieldSetElement>) => {
    if (event.defaultPrevented || event.repeat) return;
    if (event.metaKey || event.ctrlKey || event.altKey) return;

    const key = event.key;
    const target = event.target;
    const targetElement = target instanceof HTMLElement ? target : null;

    if (isMediaMuteShortcut(event)) {
      event.preventDefault();
      run(true, controller.toggleMuted);
      return;
    }

    if (key === "<" || key === ",") {
      event.preventDefault();
      run(true, () =>
        controller.setPlaybackRate(stepPlaybackRateValue(controller.playbackRate, -1))
      );
      return;
    }

    if (key === ">" || key === ".") {
      event.preventDefault();
      run(true, () =>
        controller.setPlaybackRate(stepPlaybackRateValue(controller.playbackRate, 1))
      );
      return;
    }

    if (key !== " " && key !== "Spacebar") return;
    if (targetElement?.closest("button")) return;

    event.preventDefault();
    run(true, controller.togglePlaying);
  };

  const clearProgressHoverIndicator = useCallback(() => {
    if (progressHoverFrameRef.current !== null) {
      cancelAnimationFrame(progressHoverFrameRef.current);
      progressHoverFrameRef.current = null;
    }
    progressElementRef.current?.removeAttribute("data-hover-indicator");
    progressRootElementRef.current?.removeAttribute("data-hover-indicator");
  }, []);

  const beginProgressDrag = useCallback(
    (event: ReactPointerEvent<HTMLInputElement>) => {
      if (!event.isPrimary || event.button !== 0) return;

      clearProgressHoverIndicator();
      if (progressDragPointerIdRef.current !== null) return;

      progressDragPointerIdRef.current = event.pointerId;
      try {
        event.currentTarget.setPointerCapture(event.pointerId);
      } catch {
        // Native range inputs can provide implicit pointer capture instead.
      }
      beginScrubbing();
    },
    [beginScrubbing, clearProgressHoverIndicator]
  );

  const endProgressDrag = useCallback(
    (event: ReactPointerEvent<HTMLInputElement>) => {
      if (progressDragPointerIdRef.current !== event.pointerId) return;

      progressDragPointerIdRef.current = null;
      endScrubbing();
    },
    [endScrubbing]
  );

  const ratePopoverPresenceRef = useCallback((element: HTMLDivElement | null) => {
    setRatePopoverPresent(element !== null);
  }, []);

  const handleRateMenuOpenChange = (isOpen: boolean) => {
    if (isOpen && ratePointerPressActiveRef.current) {
      rateMenuOpenPendingRef.current = true;
      return;
    }
    rateMenuOpenPendingRef.current = false;
    setRateMenuOpen(isOpen);
  };

  const cancelPendingRateMenuOpen = () => {
    rateMenuOpenPendingRef.current = false;
    ratePointerPressActiveRef.current = false;
  };

  const handleProgressPointerMove = useCallback(
    (event: ReactPointerEvent<HTMLInputElement>) => {
      if (event.pointerType !== "mouse") return;

      const element = event.currentTarget;
      const progressRoot = progressRootElementRef.current;
      const visualTrack = progressVisualElementRef.current;
      const bounds =
        visualTrack?.getBoundingClientRect() ?? element.getBoundingClientRect();
      if (bounds.width <= 0) return;
      const hoverPosition = clamp(
        ((event.clientX - bounds.left) / bounds.width) * 100,
        0,
        100
      );

      if (progressHoverFrameRef.current !== null) {
        cancelAnimationFrame(progressHoverFrameRef.current);
      }
      progressHoverFrameRef.current = requestAnimationFrame(() => {
        progressRoot?.style.setProperty(
          "--chat-panel-media-hover-position",
          `${hoverPosition}%`
        );
        element.dataset.hoverIndicator = "true";
        if (progressRoot) progressRoot.dataset.hoverIndicator = "true";
        progressHoverFrameRef.current = null;
      });
    },
    []
  );

  const handleProgressPointerUp = useCallback(
    (event: ReactPointerEvent<HTMLInputElement>) => {
      if (event.pointerType === "mouse" && event.currentTarget.matches(":hover")) {
        handleProgressPointerMove(event);
      } else {
        clearProgressHoverIndicator();
      }
      endProgressDrag(event);
    },
    [clearProgressHoverIndicator, endProgressDrag, handleProgressPointerMove]
  );

  const handleProgressPointerCancel = useCallback(
    (event: ReactPointerEvent<HTMLInputElement>) => {
      if (progressDragPointerIdRef.current !== event.pointerId) return;

      clearProgressHoverIndicator();
      endProgressDrag(event);
    },
    [clearProgressHoverIndicator, endProgressDrag]
  );

  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Shortcut keys bubble from focusable controls inside this playback group.
    <fieldset
      aria-label={`${mediaLabel} playback controls`}
      className="chat-panel-media-player @container"
      data-controls-pinned={controlsPinned ? "true" : "false"}
      data-instant-motion={instant ? "true" : "false"}
      data-kind={kind}
      data-playing={controller.isPlaying ? "true" : "false"}
      data-rate-popover-present={ratePopoverPresent ? "true" : "false"}
      data-tone={tone}
      {...keyboardFocusMotion}
      onKeyDown={handlePlayerKeyDown}
    >
      <div className="chat-panel-media-controls @max-xs:gap-xs @max-xs:px-md">
        <MediaControlTooltip
          content={controller.isPlaying ? "Pause" : "Play"}
          shortcut={mediaControlShortcuts.play}
        >
          <button
            aria-keyshortcuts="Space"
            aria-label={controller.isPlaying ? `Pause ${kind}` : `Play ${kind}`}
            className={mediaControlClassName}
            {...buttonPressFeedback}
            onClick={(event) =>
              run(event.detail === 0, () => controller.togglePlaying())
            }
            type="button"
          >
            <PlayPauseIcon isPlaying={controller.isPlaying} />
          </button>
        </MediaControlTooltip>
        <MediaVolumeControl
          buttonClassName={mediaControlClassName}
          labels={{
            muted: "Muted. Change volume",
            mute: "Mute",
            popover: `${mediaLabel} volume controls`,
            slider: `${mediaLabel} volume`,
            unmute: "Unmute",
            volume: (percent) => `Volume ${percent}%`,
          }}
          onOpenChange={setVolumePopoverOpen}
          onToggleMuted={controller.toggleMuted}
          onVolumeChange={controller.setVolume}
          open={volumePopoverOpen}
          runInteraction={run}
          tone={tone}
          volume={controller.volume}
        />
        <time className="chat-panel-media-time">
          {formatMediaTime(controller.currentTime)}
        </time>
        <span
          className="chat-panel-media-progress-root @max-xxs:min-w-3xl @max-xxs:max-w-6xl"
          ref={progressRootElementRef}
          style={progressStyle}
        >
          <span
            aria-hidden="true"
            className="chat-panel-media-progress-visual"
            ref={progressVisualElementRef}
          >
            <span className="chat-panel-media-progress-surface">
              <span className="chat-panel-media-progress-fill" />
              <span className="chat-panel-media-progress-hover-indicator" />
            </span>
            <span className="chat-panel-media-progress-thumb" />
          </span>
          <input
            aria-label={`${mediaLabel} playback position`}
            aria-valuetext={progressLabel}
            className="chat-panel-media-progress"
            data-no-press-feedback
            max={controller.duration}
            min={0}
            onChange={handleProgressChange}
            onKeyDown={handleProgressKeyDown}
            onLostPointerCapture={handleProgressPointerCancel}
            onPointerCancel={handleProgressPointerCancel}
            onPointerDown={beginProgressDrag}
            onPointerEnter={handleProgressPointerMove}
            onPointerLeave={clearProgressHoverIndicator}
            onPointerMove={handleProgressPointerMove}
            onPointerUp={handleProgressPointerUp}
            ref={progressElementRef}
            step="any"
            type="range"
            value={controller.currentTime}
          />
        </span>
        <time className="chat-panel-media-time">
          {formatMediaTime(controller.duration)}
        </time>
        <MediaControlTooltip
          composite
          content="Playback speed"
          shortcut={mediaControlShortcuts.playbackSpeed}
        >
          <MenuTrigger isOpen={rateMenuOpen} onOpenChange={handleRateMenuOpenChange}>
            <AriaButton
              aria-keyshortcuts="Comma Period"
              aria-label={`Playback speed ${formatPlaybackRate(controller.playbackRate)}`}
              className={cx(
                controlBaseClassName,
                "chat-panel-media-speed-control w-6xl min-w-6xl",
                !ratePopoverPresent && "@max-xs:hidden @max-xs:focus:inline-flex"
              )}
              {...buttonPressFeedback}
              onPointerCancelCapture={cancelPendingRateMenuOpen}
              onPointerDownCapture={(event) => {
                if (!event.isPrimary || event.button !== 0) return;
                ratePointerPressActiveRef.current = event.pointerType !== "touch";
              }}
              onPress={() => {
                ratePointerPressActiveRef.current = false;
                if (!rateMenuOpenPendingRef.current) return;
                rateMenuOpenPendingRef.current = false;
                setRateMenuOpen(true);
              }}
              onPressEnd={(event) => {
                if (event.pointerType === "touch" || event.pointerType === "keyboard") {
                  return;
                }
                queueMicrotask(() => {
                  if (ratePointerPressActiveRef.current) cancelPendingRateMenuOpen();
                });
              }}
              onPressStart={(event) => {
                rateInputWasKeyboardRef.current = event.pointerType === "keyboard";
                setRateMenuInstantMotion(event.pointerType === "keyboard");
              }}
            >
              <PlaybackRateValue
                animate={animateSpeedChange}
                rate={controller.playbackRate}
              />
            </AriaButton>
            <MenuPopover
              className={cx(
                "chat-panel-media-rate-popover",
                rateMenuInstantMotion && "is-instant"
              )}
              offset={-spacing["3xl"]}
              placement="top"
            >
              <div
                onKeyDownCapture={() => {
                  rateInputWasKeyboardRef.current = true;
                  setRateMenuInstantMotion(true);
                }}
                onPointerDownCapture={() => {
                  rateInputWasKeyboardRef.current = false;
                  setRateMenuInstantMotion(false);
                }}
                ref={ratePopoverPresenceRef}
              >
                <Menu
                  aria-label="Playback speed"
                  className="chat-panel-media-rate-menu text-xs"
                  disallowEmptySelection
                  onAction={(key) => {
                    const rate = Number(key);
                    setAnimateSpeedChange(!rateInputWasKeyboardRef.current);
                    run(rateInputWasKeyboardRef.current, () =>
                      controller.setPlaybackRate(rate)
                    );
                    rateInputWasKeyboardRef.current = false;
                  }}
                  selectedKeys={[String(controller.playbackRate)]}
                  selectionMode="single"
                >
                  {playbackRates.map((rate) => (
                    <MenuItem
                      id={String(rate)}
                      key={rate}
                      shortcut={
                        controller.playbackRate === rate ? (
                          <CheckIcon className="size-2xl" />
                        ) : undefined
                      }
                    >
                      {formatPlaybackRate(rate)}
                    </MenuItem>
                  ))}
                </Menu>
              </div>
            </MenuPopover>
          </MenuTrigger>
        </MediaControlTooltip>
        {downloadController ? (
          <ChatPanelMediaDownloadControl
            buttonClassName={mediaControlClassName}
            controller={downloadController}
            feedbackPlacement="above"
            icon={<MediaDownloadIcon className="size-2xl" />}
            kind={kind}
          />
        ) : null}
        {onExpand ? (
          <MediaControlTooltip content="Full window" shortcut={fullWindowShortcut.keys}>
            <button
              aria-label="Full window"
              className={mediaControlClassName}
              data-slot="chat-panel-video-expand"
              {...buttonPressFeedback}
              onClick={onExpand}
              type="button"
            >
              <MediaExpandIcon className="size-2xl" />
            </button>
          </MediaControlTooltip>
        ) : null}
      </div>
    </fieldset>
  );
};
