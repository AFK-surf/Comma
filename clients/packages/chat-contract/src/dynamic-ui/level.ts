/**
 * The level of the widget runtime this client carries. ui.create gives each
 * widget the lowest level that shows it, as the `version` of its block and of
 * its payload. A client shows the summary of a widget above its own level, so
 * an older client never draws a widget it cannot show in full.
 *
 * Raise the level in the change that lets the runtime show something an older
 * runtime cannot show, or shows only in part. Give the new level to what the
 * change touches: a card kind in `cardKindLevels` (cardContract.ts), a feature
 * below, or the base level for a change ui.create cannot see in a widget.
 * `pnpm generate:card-contract` then renders the levels for ui.create.
 */
export const dynamicUiLevel = 2;

/**
 * The level every widget needs. Level 1 is the runtime of release v1.0.14,
 * the last that shows only version 1. What that runtime does not show in full
 * has a higher level.
 */
export const dynamicUiBaseLevel = 1;

/**
 * What a widget can use besides card kinds, and the level that first shows it.
 * ui.create has a check for each name.
 */
export const dynamicUiFeatureLevels = {
  // comma.chart with several named series.
  chartSeries: 2,
} as const;

/** Whether this client's runtime shows a widget of that version. */
export const showsDynamicUiVersion = (version: unknown): boolean =>
  typeof version === "number" &&
  Number.isInteger(version) &&
  version >= 1 &&
  version <= dynamicUiLevel;
