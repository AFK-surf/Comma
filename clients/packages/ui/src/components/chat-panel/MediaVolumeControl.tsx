import {
  type CSSProperties,
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
} from "react";
import { VolumeFullIcon, VolumeHalfIcon, VolumeOffIcon } from "../icons";
import { cx } from "../utils";
import { MediaControlTooltip, mediaControlShortcuts } from "./MediaControlTooltip";
import { usePointerPressFeedback } from "./usePointerPressFeedback";

/** How loud the volume icon draws a volume: muted, then thirds of the range. */
export type MediaVolumeLevel = 0 | 1 | 2 | 3;

export const mediaVolumeLevel = (volume: number): MediaVolumeLevel =>
  volume === 0 ? 0 : volume <= 0.33 ? 1 : volume <= 0.66 ? 2 : 3;

/**
 * M on its own mutes, or brings the sound back. The host listens for it
 * wherever its sound is in play: the media player over its controls, a
 * surface with one sound over the whole surface.
 */
export const isMediaMuteShortcut = (
  event: Pick<
    KeyboardEvent,
    "altKey" | "ctrlKey" | "defaultPrevented" | "key" | "metaKey" | "repeat"
  >
) =>
  !event.defaultPrevented &&
  !event.repeat &&
  !event.metaKey &&
  !event.ctrlKey &&
  !event.altKey &&
  (event.key === "m" || event.key === "M");

/** What the control and its slider are called, in the host's words. */
export interface MediaVolumeControlLabels {
  /** The button while there is sound, from the volume in percent. */
  volume: (percent: number) => string;
  /** The button while muted. */
  muted: string;
  /** The button's tooltip while there is sound. */
  mute: string;
  /** The button's tooltip while muted. */
  unmute: string;
  /** The popover that holds the slider. */
  popover: string;
  /** The slider. */
  slider: string;
}

export interface MediaVolumeControlProps {
  /** From 0, muted, to 1. */
  volume: number;
  onVolumeChange: (volume: number) => void;
  /** Mutes, or brings back the volume the sound had before. */
  onToggleMuted: () => void;
  labels: MediaVolumeControlLabels;
  /** Whether the slider is open. Left out, the control keeps it itself. */
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  /**
   * Where the slider opens: above the button, or below it. The tooltip shows
   * on the same side; a press closes it before the slider opens.
   */
  placement?: "bottom" | "top";
  tone?: "dark" | "light";
  /**
   * Holds the button's tooltip closed: for a host whose layout can move the
   * button under a pointer that did not move to it.
   */
  tooltipDisabled?: boolean;
  /**
   * Applies a change the user made. `withoutMotion` when it came from the
   * keyboard: the change then lands without animating, and a host that
   * animates around the control (the media player) drops its own motion for
   * it too.
   */
  runInteraction?: (withoutMotion: boolean, action: () => void) => void;
  className?: string;
  buttonClassName?: string;
  popoverClassName?: string;
}

const applyAtOnce = (_withoutMotion: boolean, action: () => void) => action();

/**
 * The speaker drawn once, with the waves for each level layered over it; only
 * the current level's waves show, so the speaker never redraws as the volume
 * changes.
 */
const VolumeStateIcon = ({ level }: { level: MediaVolumeLevel }) => {
  const state = level === 0 ? "off" : level === 3 ? "loud" : "half";

  return (
    <span
      aria-hidden="true"
      className="chat-panel-media-volume-icon size-2xl"
      data-level={level}
      data-state={state}
    >
      <VolumeFullIcon className="chat-panel-media-volume-base size-2xl" mode="raw" />
      <span className="chat-panel-media-volume-states">
        <span className="chat-panel-media-volume-state" data-volume-state="loud">
          <VolumeFullIcon
            className="chat-panel-media-volume-state-glyph size-2xl"
            mode="raw"
          />
        </span>
        <span className="chat-panel-media-volume-state" data-volume-state="half">
          <VolumeHalfIcon
            className="chat-panel-media-volume-state-glyph size-2xl"
            mode="raw"
          />
        </span>
        <span className="chat-panel-media-volume-state" data-volume-state="off">
          <VolumeOffIcon
            className="chat-panel-media-volume-state-glyph size-2xl"
            mode="raw"
          />
        </span>
      </span>
    </span>
  );
};

/**
 * The media player's volume control: a button that shows the volume, and a
 * popover with a vertical slider. The first press opens the slider; a press
 * while it is open mutes, or brings the sound back. A press or focus outside
 * closes it, and so does Escape, which returns the focus to the button.
 * Shared by the media player and any surface with a sound of its own.
 */
export const MediaVolumeControl = ({
  buttonClassName,
  className,
  labels,
  onOpenChange,
  onToggleMuted,
  onVolumeChange,
  open: openProp,
  placement = "top",
  popoverClassName,
  runInteraction = applyAtOnce,
  tone = "light",
  tooltipDisabled = false,
  volume,
}: MediaVolumeControlProps) => {
  const [ownOpen, setOwnOpen] = useState(false);
  const open = openProp ?? ownOpen;
  const [instantMotion, setInstantMotion] = useState(false);
  const pressFeedback = usePointerPressFeedback<HTMLButtonElement>();
  const inputWasKeyboardRef = useRef(false);
  const anchorRef = useRef<HTMLSpanElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const popoverId = useId();
  const volumePercent = Math.round(volume * 100);
  const volumeStyle = {
    "--chat-panel-media-volume": `${volumePercent}%`,
  } as CSSProperties;

  const setOpen = useCallback(
    (next: boolean) => {
      if (openProp === undefined) setOwnOpen(next);
      onOpenChange?.(next);
    },
    [onOpenChange, openProp]
  );

  useEffect(() => {
    if (!open) return;
    const anchor = anchorRef.current;
    const button = buttonRef.current;
    if (!anchor || !button) return;
    const ownerDocument = anchor.ownerDocument;

    const closeFromPointer = (event: PointerEvent) => {
      if (event.target instanceof Node && anchor.contains(event.target)) return;
      setOpen(false);
    };
    const closeFromFocus = (event: FocusEvent) => {
      if (event.target instanceof Node && anchor.contains(event.target)) return;
      setOpen(false);
    };
    const closeFromKeyboard = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      setInstantMotion(true);
      setOpen(false);
      button.focus();
    };

    ownerDocument.addEventListener("pointerdown", closeFromPointer, true);
    ownerDocument.addEventListener("focusin", closeFromFocus, true);
    ownerDocument.addEventListener("keydown", closeFromKeyboard, true);
    return () => {
      ownerDocument.removeEventListener("pointerdown", closeFromPointer, true);
      ownerDocument.removeEventListener("focusin", closeFromFocus, true);
      ownerDocument.removeEventListener("keydown", closeFromKeyboard, true);
    };
  }, [open, setOpen]);

  return (
    <span className={cx("chat-panel-media-volume-anchor", className)} ref={anchorRef}>
      <MediaControlTooltip
        content={volumePercent === 0 ? labels.unmute : labels.mute}
        isDisabled={tooltipDisabled}
        placement={placement}
        shortcut={mediaControlShortcuts.mute}
      >
        <button
          aria-controls={popoverId}
          aria-expanded={open}
          aria-haspopup="dialog"
          aria-keyshortcuts="M"
          aria-label={volumePercent === 0 ? labels.muted : labels.volume(volumePercent)}
          className={buttonClassName}
          {...pressFeedback}
          onClick={(event) => {
            const withoutMotion = event.detail === 0;
            setInstantMotion(withoutMotion);
            if (!open) {
              setOpen(true);
              return;
            }
            runInteraction(withoutMotion, onToggleMuted);
          }}
          ref={buttonRef}
          type="button"
        >
          <VolumeStateIcon level={mediaVolumeLevel(volume)} />
        </button>
      </MediaControlTooltip>
      <dialog
        aria-hidden={!open}
        aria-label={labels.popover}
        className={cx(
          "chat-panel-media-volume-popover",
          instantMotion && "is-instant",
          popoverClassName
        )}
        data-open={open ? "true" : "false"}
        data-placement={placement === "bottom" ? placement : undefined}
        data-tone={tone}
        id={popoverId}
        open
      >
        <div className="chat-panel-media-volume-dialog">
          <input
            aria-label={labels.slider}
            aria-orientation="vertical"
            aria-valuetext={`${volumePercent}%`}
            className="chat-panel-media-volume-slider"
            data-no-press-feedback
            max={1}
            min={0}
            onBlur={() => {
              inputWasKeyboardRef.current = false;
            }}
            onChange={(event) => {
              const next = Number(event.currentTarget.value);
              runInteraction(inputWasKeyboardRef.current, () => onVolumeChange(next));
            }}
            onKeyDown={(event) => {
              inputWasKeyboardRef.current = true;
              if (event.key === "Escape") setInstantMotion(true);
            }}
            onKeyUp={() => {
              inputWasKeyboardRef.current = false;
            }}
            onPointerDown={() => {
              inputWasKeyboardRef.current = false;
              setInstantMotion(false);
            }}
            step={0.01}
            style={volumeStyle}
            tabIndex={open ? 0 : -1}
            type="range"
            value={volume}
          />
        </div>
      </dialog>
    </span>
  );
};
