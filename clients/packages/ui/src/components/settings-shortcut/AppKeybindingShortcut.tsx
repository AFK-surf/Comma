import { keycapSymbol } from "./SettingsShortcutKeycaps";
import {
  useEffect,
  useRef,
  useState,
  type FocusEvent,
  type KeyboardEvent,
} from "react";
import { CircleMinusIcon } from "../icons";
import { cx } from "../utils";
import {
  APP_KEYBINDING_MAX_KEYCAPS,
  APP_KEYBINDING_SEQUENCE_TIMEOUT_MS,
  appKeyModifierKeycaps,
  appKeybindingKeycaps,
  appKeyCodeLabel,
  emptyAppKeyModifiers,
  formatAppKeybindingAria,
  hasPrimaryModifier,
  isValidAppKeybinding,
  modifierKeycapCount,
  modifiersFromKeyboardEvent,
  parseAppKeyCode,
  type AppKeybinding,
  type AppKeyCode,
  type AppKeybindingPlatform,
} from "./appKeybinding";

export interface AppKeybindingShortcutProps {
  ariaLabel: string;
  className?: string;
  clearLabel?: string;
  disabled?: boolean;
  emptyLabel?: string;
  errorMessage?: string;
  onChange?: (binding: AppKeybinding) => void;
  onClear?: () => void;
  platform?: AppKeybindingPlatform;
  recordingLabel?: string;
  value: AppKeybinding | null;
}

type CaptureState =
  | { kind: "idle" }
  | { kind: "editing"; keycaps?: readonly string[]; sequence?: readonly AppKeyCode[] }
  | {
      kind: "preview";
      binding: AppKeybinding;
      code: string;
      keycaps: readonly string[];
    };

const isModifierKey = (event: KeyboardEvent<HTMLButtonElement>) =>
  event.key === "Alt" ||
  event.key === "Control" ||
  event.key === "Meta" ||
  event.key === "Shift";

const emptyKeycaps = ["-", "-"] as const;

export const AppKeybindingShortcut = ({
  ariaLabel,
  className,
  clearLabel = "Clear shortcut",
  disabled = false,
  emptyLabel = "Not set",
  errorMessage,
  onChange,
  onClear,
  platform,
  recordingLabel = "Press shortcut",
  value,
}: AppKeybindingShortcutProps) => {
  const [capture, setCapture] = useState<CaptureState>({ kind: "idle" });
  const controlRef = useRef<HTMLButtonElement>(null);
  const sequenceTimerRef = useRef<number | undefined>(undefined);
  const recording = capture.kind !== "idle" && !disabled;
  const keycaps =
    capture.kind === "idle"
      ? value
        ? appKeybindingKeycaps(value, platform)
        : emptyKeycaps
      : (capture.keycaps ??
        (value ? appKeybindingKeycaps(value, platform) : emptyKeycaps));
  const visualState =
    recording && capture.kind === "editing"
      ? "editing"
      : recording && capture.kind === "preview"
        ? "recording"
        : errorMessage
          ? "error"
          : disabled
            ? "disabled"
            : "idle";
  const showClear =
    recording && capture.kind === "editing" && value !== null && onClear !== undefined;

  useEffect(() => {
    if (!disabled) return;
    setCapture((current) => (current.kind === "idle" ? current : { kind: "idle" }));
  }, [disabled]);

  useEffect(
    () => () => {
      if (sequenceTimerRef.current !== undefined) {
        window.clearTimeout(sequenceTimerRef.current);
      }
    },
    []
  );

  const clearSequenceTimer = () => {
    if (sequenceTimerRef.current !== undefined) {
      window.clearTimeout(sequenceTimerRef.current);
      sequenceTimerRef.current = undefined;
    }
  };

  const commitBinding = (binding: AppKeybinding) => {
    clearSequenceTimer();
    if (!isValidAppKeybinding(binding)) {
      setCapture({ kind: "editing" });
      return;
    }
    onChange?.(binding);
    setCapture({ kind: "idle" });
  };

  const clearShortcut = () => {
    if (disabled || !onClear || value === null) return;
    clearSequenceTimer();
    onClear();
    setCapture({ kind: "idle" });
    controlRef.current?.focus();
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    if (disabled || !recording) return;
    if (event.key === "Tab") return;

    event.preventDefault();
    event.stopPropagation();
    if (event.repeat) return;
    if (event.key === "Escape") {
      clearSequenceTimer();
      setCapture({ kind: "idle" });
      return;
    }

    if (
      (event.key === "Backspace" || event.key === "Delete") &&
      !event.altKey &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.shiftKey
    ) {
      clearShortcut();
      return;
    }

    const modifiers = modifiersFromKeyboardEvent(event);
    if (isModifierKey(event)) {
      const preview = appKeyModifierKeycaps(modifiers, platform);
      setCapture({
        kind: "editing",
        ...(preview.length > 0 ? { keycaps: preview } : {}),
        ...(capture.kind === "editing" && capture.sequence
          ? { sequence: capture.sequence }
          : {}),
      });
      return;
    }

    const code = parseAppKeyCode(event.code);
    if (!code) {
      setCapture({ kind: "editing" });
      return;
    }

    if (hasPrimaryModifier(modifiers)) {
      clearSequenceTimer();
      if (modifierKeycapCount(modifiers) + 1 > APP_KEYBINDING_MAX_KEYCAPS) {
        setCapture({
          kind: "editing",
          keycaps: appKeyModifierKeycaps(modifiers, platform),
        });
        return;
      }
      const binding: AppKeybinding = {
        kind: "chord",
        stroke: { code, modifiers },
      };
      setCapture({
        kind: "preview",
        binding,
        code: event.code,
        keycaps: appKeybindingKeycaps(binding, platform),
      });
      return;
    }

    const previousSequence =
      capture.kind === "editing" && capture.sequence ? capture.sequence : [];
    const nextSequence = [...previousSequence, code];
    if (nextSequence.length > APP_KEYBINDING_MAX_KEYCAPS) {
      setCapture({ kind: "editing" });
      return;
    }

    const labels = nextSequence.map(appKeyCodeLabel);
    if (nextSequence.length >= 2) {
      const binding: AppKeybinding = { kind: "sequence", codes: nextSequence };
      clearSequenceTimer();
      if (nextSequence.length >= APP_KEYBINDING_MAX_KEYCAPS) {
        commitBinding(binding);
        return;
      }
      setCapture({
        kind: "editing",
        keycaps: labels,
        sequence: nextSequence,
      });
      sequenceTimerRef.current = window.setTimeout(() => {
        commitBinding(binding);
      }, APP_KEYBINDING_SEQUENCE_TIMEOUT_MS);
      return;
    }

    setCapture({
      kind: "editing",
      keycaps: labels,
      sequence: nextSequence,
    });
  };

  const handleKeyUp = (event: KeyboardEvent<HTMLButtonElement>) => {
    if (disabled || !recording) return;
    event.preventDefault();
    event.stopPropagation();

    if (isModifierKey(event)) {
      if (capture.kind === "preview") return;
      const modifiers = modifiersFromKeyboardEvent(event);
      const preview = appKeyModifierKeycaps(
        modifiers.alt || modifiers.control || modifiers.meta || modifiers.shift
          ? modifiers
          : emptyAppKeyModifiers(),
        platform
      );
      setCapture({
        kind: "editing",
        ...(preview.length > 0 ? { keycaps: preview } : {}),
        ...(capture.kind === "editing" && capture.sequence
          ? { sequence: capture.sequence }
          : {}),
      });
      return;
    }

    if (capture.kind !== "preview" || capture.code !== event.code) return;
    commitBinding(capture.binding);
  };

  const handleControlBlur = (event: FocusEvent<HTMLDivElement>) => {
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) return;
    clearSequenceTimer();
    setCapture({ kind: "idle" });
  };

  return (
    <div className="settings-shortcut-field">
      <div className="settings-shortcut__control" onBlur={handleControlBlur}>
        <button
          aria-disabled={disabled || undefined}
          aria-label={`${ariaLabel}: ${
            recording
              ? recordingLabel
              : value === null
                ? emptyLabel
                : formatAppKeybindingAria(value, platform)
          }`}
          aria-pressed={recording}
          className={cx("settings-shortcut", className)}
          data-no-press-feedback
          data-slot="settings-keybinding"
          data-state={visualState}
          disabled={disabled}
          onClick={() => {
            if (disabled) return;
            setCapture((current) =>
              current.kind === "idle" ? { kind: "editing" } : current
            );
          }}
          onKeyDown={handleKeyDown}
          onKeyUp={handleKeyUp}
          ref={controlRef}
          type="button"
        >
          <span aria-hidden="true" className="settings-shortcut__keycaps">
            {keycaps.map((keycap, index) => (
              <span
                className="settings-shortcut__keycap-shell"
                key={`${keycap}-${index}`}
              >
                <kbd className="settings-shortcut__keycap">{keycapSymbol(keycap)}</kbd>
              </span>
            ))}
          </span>
        </button>
        {showClear ? (
          <button
            aria-label={clearLabel}
            className="settings-shortcut__clear"
            data-no-press-feedback
            data-slot="settings-keybinding-clear"
            onClick={clearShortcut}
            title={clearLabel}
            type="button"
          >
            <CircleMinusIcon className="settings-shortcut__clear-icon" />
          </button>
        ) : null}
      </div>
      {errorMessage && !recording ? (
        <p className="settings-shortcut__error" role="alert">
          {errorMessage}
        </p>
      ) : null}
    </div>
  );
};
