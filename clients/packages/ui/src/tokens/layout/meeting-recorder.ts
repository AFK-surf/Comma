/**
 * Meeting recorder layout tokens — Comma Design System.
 *
 * The recorder is a single-row floating card pinned to the top centre of the
 * main window, in the spirit of Notion's "Meeting detected" popup: wide
 * enough for a title, a timer, microphone selection and recording controls on one line.
 */
export const meetingRecorderLayout = {
  /** Shared expanded width across phases; unattended recording has its own compact width. */
  width: 370,
  /** Figma 1453:17404, Frame 1686557472 — recording without hover. */
  compactWidth: 227,
  compactHeight: 42,
  /** Figma 1453:17299, Buttons/Button xs / Secondary gray. */
  startButtonHeight: 26,
  /** Clears the 44px hidden-inset titlebar plus one `lg` step of breathing room. */
  viewportInsetTop: 56,
} as const;

export type MeetingRecorderLayoutKey = keyof typeof meetingRecorderLayout;
