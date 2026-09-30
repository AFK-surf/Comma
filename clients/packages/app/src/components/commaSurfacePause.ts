export const COMMA_SURFACE_PAUSED_ATTRIBUTE = "data-comma-surface-paused";
export const COMMA_SURFACE_PAUSED_SELECTOR = `[${COMMA_SURFACE_PAUSED_ATTRIBUTE}='true']`;

export function isCommaSurfacePaused(element: Element | null | undefined) {
  return Boolean(element?.closest(COMMA_SURFACE_PAUSED_SELECTOR));
}
