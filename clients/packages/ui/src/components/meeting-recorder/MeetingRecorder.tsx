/* oxlint-disable jsx-a11y/prefer-tag-over-role -- A floating status card groups controls rather than forming a page landmark. */
/* oxlint-disable jsx-a11y/no-noninteractive-tabindex -- The recording group is a keyboard entry point: focusing it reveals its otherwise hover-only controls. */
import { useCommaMessages } from "@comma/i18n/react";
import { useEffect, useRef, useState } from "react";
import { Button as AriaButton } from "react-aria-components";
import { Button } from "../Button";
import { CommaMark } from "../login/BrandMarks";
import {
  CircleCheckIcon,
  CircleXIcon,
  LoadingCircleIcon,
  PauseIcon,
  PlayIcon,
  VoiceRecordIcon,
  VideoIcon,
  XIcon,
} from "../icons";
import { cx } from "../utils";
import { formatMeetingRecorderDuration } from "./duration";
import { RecorderMicrophone, RecorderStopMenu } from "./RecorderMenus";
import { RecorderMotion } from "./RecorderMotion";
import type { MeetingRecorderProps } from "./types";

/** Controlled recorder: menus report intent; Main owns capture and device changes. */
export const MeetingRecorder = (props: MeetingRecorderProps) => {
  const {
    phase,
    appName,
    appIconUrl,
    durationMs = 0,
    permission,
    callEnded,
    fileName,
    errorMessage,
    fileActionPending,
    fileActionError,
    microphoneError,
    onStart,
    onDismiss,
    onPause,
    onResume,
    onStop,
    onOpenPermissionSettings,
    onRevealInDrive,
    onOpenFile,
    onClose,
    className,
    testId,
  } = props;
  const m = useCommaMessages();
  const [canHover, setCanHover] = useState(false);
  const [hovered, setHovered] = useState(false);
  const [keyboardFocus, setKeyboardFocus] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [menuDismissed, setMenuDismissed] = useState(false);
  const menuDismissedRef = useRef(false);
  const cardRef = useRef<HTMLDivElement>(null);
  const handleMenuOpenChange = (open: boolean) => {
    setMenuOpen(open);
    props.onMenuOpenChange?.(open);
    menuDismissedRef.current = !open;
    setMenuDismissed(!open);
    // Give the menu scope a stable restoration target before it mounts. Its
    // trigger becomes inert on close, whereas the compact card stays focusable.
    if (open && canHover && props.collapseWhenIdle !== false && phase === "recording") {
      cardRef.current?.focus({ preventScroll: true });
    }
    if (!open) {
      setHovered(false);
      setKeyboardFocus(false);
    }
  };
  useEffect(() => {
    const query = window.matchMedia?.("(hover: hover) and (pointer: fine)");
    if (!query) return;
    const update = () => setCanHover(query.matches);
    update();
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  const live = phase === "recording" || phase === "paused";
  useEffect(() => {
    if (!live) {
      setMenuOpen(false);
      setMenuDismissed(false);
      menuDismissedRef.current = false;
    }
  }, [live]);
  const busy = phase === "starting" || phase === "saving";
  const timer = formatMeetingRecorderDuration(durationMs);
  const titles = {
    detected: m.ui_meeting_recorder_detected_title(),
    starting: m.ui_meeting_recorder_starting(),
    recording: m.ui_meeting_recorder_recording(),
    paused: m.ui_meeting_recorder_paused(),
    saving: m.ui_meeting_recorder_saving(),
    saved: m.ui_meeting_recorder_saved(),
    error: m.ui_meeting_recorder_failed(),
  };
  // Permission and failure details stay actionable without extra showcase variants.
  const notice =
    live && permission === "suspected_denied"
      ? m.ui_meeting_recorder_permission_title()
      : live && callEnded
        ? m.ui_meeting_recorder_call_ended()
        : live
          ? microphoneError
          : undefined;
  const compact =
    props.collapseWhenIdle !== false &&
    phase === "recording" &&
    canHover &&
    !menuOpen &&
    (menuDismissed || (!hovered && !keyboardFocus)) &&
    !notice;
  return (
    <RecorderMotion
      phase={phase}
      compact={compact}
      layoutKey={`${phase}:${compact}:${appName}:${fileName}:${notice ?? ""}:${errorMessage ?? ""}:${fileActionError ?? ""}`}
    >
      {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Hover reveals this focusable control group's buttons; keyboard focus also expands it. The group is not itself an action. */}
      <div
        ref={cardRef}
        aria-label={m.ui_meeting_recorder_label()}
        role="group"
        className={cx("comma-meeting-recorder", className)}
        data-phase={phase}
        data-compact={compact || undefined}
        tabIndex={phase === "recording" ? 0 : undefined}
        onPointerEnter={(event) => {
          if (menuDismissedRef.current) return;
          if (
            event.pointerType !== "touch" &&
            event.target instanceof Node &&
            event.currentTarget.contains(event.target)
          ) {
            menuDismissedRef.current = false;
            setMenuDismissed(false);
            setHovered(true);
            setKeyboardFocus(false);
          }
        }}
        onMouseLeave={(event) => {
          // Portal menu events must not change the card's pointer state.
          if (
            !(event.target instanceof Node) ||
            !event.currentTarget.contains(event.target)
          )
            return;
          setHovered(false);
        }}
        onKeyDownCapture={() => {
          menuDismissedRef.current = false;
          setMenuDismissed(false);
          setKeyboardFocus(true);
        }}
        onMouseMoveCapture={(event) => {
          // Electron's click-through window forwards mouse motion before it
          // restores hit testing; that motion need not include pointer-enter.
          // Expand on the first forwarded move, without waiting for another.
          // Closing a portal can synthesize pointer-enter without pointer motion.
          // A fresh physical move over the card starts the next hover interaction.
          if (
            (!menuDismissedRef.current ||
              event.movementX !== 0 ||
              event.movementY !== 0) &&
            event.target instanceof Node &&
            event.currentTarget.contains(event.target)
          ) {
            menuDismissedRef.current = false;
            setMenuDismissed(false);
            setHovered(true);
          }
        }}
        onPointerDownCapture={() => setKeyboardFocus(false)}
        onFocusCapture={(event) => {
          if (!menuDismissedRef.current && event.target.matches(":focus-visible"))
            setKeyboardFocus(true);
        }}
        onBlurCapture={(event) => {
          if (!menuOpen && !event.currentTarget.contains(event.relatedTarget))
            setKeyboardFocus(false);
        }}
        data-slot="meeting-recorder"
        {...(testId ? { "data-testid": testId } : {})}
      >
        <div
          aria-hidden
          className="comma-recorder-surface"
          data-recorder-motion="surface"
        />
        <div
          aria-hidden
          className="comma-recorder-logo"
          data-slot="meeting-recorder-leading"
          data-recorder-motion="logo"
        >
          {phase === "saved" ? (
            <CircleCheckIcon className="size-2xl text-fg-success-primary" />
          ) : phase === "error" ? (
            <CircleXIcon className="size-2xl text-fg-error-primary" />
          ) : (
            <CommaMark
              className="text-primary"
              viewBox="3.75 4.44 40.56 40.56"
              data-slot="meeting-recorder-static-logo"
            />
          )}
        </div>
        <div className="comma-recorder-copy">
          <p
            aria-live="polite"
            className={cx(
              "comma-recorder-title",
              (busy || phase === "recording") && "comma-shiny-text"
            )}
            data-slot="meeting-recorder-title"
            data-recorder-motion="title"
            data-recorder-presence
          >
            {titles[phase]}
          </p>
          {phase === "detected" && (
            <p
              className="comma-recorder-subtitle"
              data-slot="meeting-recorder-subtitle"
              data-recorder-motion="subtitle"
              data-recorder-presence
            >
              {appName && (
                <span className="comma-recorder-product" aria-hidden>
                  {appIconUrl ? (
                    <img src={appIconUrl} alt="" width={16} height={16} />
                  ) : (
                    <VideoIcon className="size-4" />
                  )}
                </span>
              )}
              {appName
                ? m.ui_meeting_recorder_detected_app({ app: appName })
                : m.ui_meeting_recorder_detected_generic()}
            </p>
          )}
          {phase === "saved" && (
            <p
              className="comma-recorder-subtitle break-words [overflow-wrap:anywhere]"
              data-slot="meeting-recorder-subtitle"
            >
              {[fileName, timer].filter(Boolean).join(" · ")}
            </p>
          )}
          {phase === "error" && errorMessage && (
            <p
              className="comma-recorder-subtitle text-error-primary"
              data-tone="error"
              role="alert"
            >
              {errorMessage}
            </p>
          )}
          {phase === "saved" && (onRevealInDrive || onOpenFile) && (
            <div
              aria-busy={fileActionPending !== undefined}
              className="mt-sm flex flex-wrap items-center gap-md"
              data-slot="meeting-recorder-file-actions"
            >
              {onRevealInDrive && (
                <Button
                  hierarchy="secondary-gray"
                  size="xs"
                  data-slot="meeting-recorder-reveal-in-drive"
                  isDisabled={fileActionPending !== undefined}
                  isPending={fileActionPending === "reveal"}
                  {...(fileActionPending === "reveal"
                    ? { iconLeading: <LoadingCircleIcon className="animate-spin" /> }
                    : {})}
                  onPress={onRevealInDrive}
                >
                  {m.ui_meeting_recorder_show_in_drive()}
                </Button>
              )}
              {onOpenFile && (
                <Button
                  hierarchy="tertiary-gray"
                  size="xs"
                  data-slot="meeting-recorder-open-file"
                  isDisabled={fileActionPending !== undefined}
                  isPending={fileActionPending === "open"}
                  {...(fileActionPending === "open"
                    ? { iconLeading: <LoadingCircleIcon className="animate-spin" /> }
                    : {})}
                  onPress={onOpenFile}
                >
                  {m.ui_meeting_recorder_open_file()}
                </Button>
              )}
            </div>
          )}
          {phase === "saved" && fileActionError && (
            <p
              className="comma-recorder-subtitle mt-xs text-error-primary"
              role="alert"
            >
              {fileActionError}
            </p>
          )}
        </div>
        {live && (
          <div className="comma-recorder-live-controls">
            <span
              aria-label={m.ui_meeting_recorder_elapsed({ time: timer })}
              role="timer"
              className="comma-recorder-timer"
              data-recorder-motion="timer"
              data-recorder-presence
            >
              {timer}
            </span>
            <RecorderMicrophone
              {...props}
              compact={compact}
              onMenuOpenChange={handleMenuOpenChange}
            />
            {(phase === "paused" ? onResume : onPause) && (
              <AriaButton
                aria-label={
                  phase === "paused"
                    ? m.ui_meeting_recorder_resume()
                    : m.ui_meeting_recorder_pause()
                }
                className="comma-recorder-control comma-recorder-pause"
                data-slot={
                  phase === "paused"
                    ? "meeting-recorder-resume"
                    : "meeting-recorder-pause"
                }
                data-recorder-motion="pause"
                data-recorder-presence=""
                inert={compact}
                aria-hidden={compact || undefined}
                onPress={() => (phase === "paused" ? onResume : onPause)?.()}
              >
                <span key={phase} className="comma-recorder-icon-swap">
                  {phase === "paused" ? (
                    <PlayIcon className="size-4" />
                  ) : (
                    <PauseIcon className="size-4" />
                  )}
                </span>
              </AriaButton>
            )}
            {onStop && (
              <div
                className="comma-recorder-stop"
                data-recorder-motion="stop"
                data-recorder-presence
              >
                <span
                  aria-hidden
                  className="comma-recorder-stop-surface"
                  data-recorder-motion="stop-surface"
                />
                <AriaButton
                  aria-label={m.ui_meeting_recorder_stop()}
                  className="comma-recorder-control comma-recorder-stop-main"
                  data-slot="meeting-recorder-stop"
                  onPress={onStop}
                >
                  <span
                    className="comma-recorder-stop-icon"
                    data-recorder-motion="stop-icon"
                  >
                    <VoiceRecordIcon className="size-4" />
                  </span>
                  <span
                    className="comma-recorder-stop-label-wrap"
                    aria-hidden={compact || undefined}
                  >
                    <span
                      className="comma-recorder-stop-label"
                      data-recorder-motion="stop-label"
                      data-recorder-presence=""
                    >
                      {m.ui_meeting_recorder_stop()}
                    </span>
                  </span>
                </AriaButton>
                <RecorderStopMenu
                  {...props}
                  compact={compact}
                  onMenuOpenChange={handleMenuOpenChange}
                />
              </div>
            )}
          </div>
        )}
        {phase === "detected" && (
          <div
            className="comma-recorder-actions"
            data-recorder-motion="actions"
            data-recorder-presence
          >
            {onStart && (
              <Button
                size="xs"
                hierarchy="secondary-gray"
                className="comma-recorder-start"
                data-slot="meeting-recorder-start"
                onPress={onStart}
              >
                {m.ui_meeting_recorder_start()}
              </Button>
            )}
            {onDismiss && (
              <AriaButton
                aria-label={m.ui_meeting_recorder_not_now()}
                className="comma-recorder-control comma-recorder-close"
                onPress={onDismiss}
              >
                <XIcon className="size-4" />
              </AriaButton>
            )}
          </div>
        )}
        {(phase === "saved" || phase === "error") && onClose && (
          <AriaButton
            aria-label={m.ui_meeting_recorder_dismiss()}
            className="comma-recorder-control comma-recorder-close self-start"
            data-slot="meeting-recorder-close"
            onPress={onClose}
          >
            <XIcon className="size-4" />
          </AriaButton>
        )}
        {notice && (
          <p
            className="comma-recorder-notice"
            data-slot="meeting-recorder-subtitle"
            data-tone="warning"
            role="status"
          >
            {notice}
            {permission === "suspected_denied" && onOpenPermissionSettings && (
              <Button
                size="xs"
                hierarchy="link-gray"
                onPress={onOpenPermissionSettings}
              >
                {m.ui_meeting_recorder_open_settings()}
              </Button>
            )}
          </p>
        )}
      </div>
    </RecorderMotion>
  );
};
