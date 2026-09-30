import type { ReactNode } from "react";
import { cx } from "../utils";
import { meetingRecorderViewport, meetingRecorderViewportCard } from "./styles";

/**
 * Pins a {@link MeetingRecorder} to the top centre of the window, above the
 * product frame and the settings overlay, clear of the titlebar drag strip.
 * Only the card itself takes pointer events, so the rest of the strip stays
 * click-through. Render it as a sibling of the app shell — never inside an
 * `overflow: hidden` ancestor — so `position: fixed` resolves to the viewport.
 */
export const MeetingRecorderViewport = ({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) => (
  <div
    className={cx(meetingRecorderViewport, className)}
    data-slot="meeting-recorder-viewport"
  >
    <div className={meetingRecorderViewportCard}>{children}</div>
  </div>
);
