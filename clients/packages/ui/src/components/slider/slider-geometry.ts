export const THUMB_SIZE = 20;
export const THUMB_RADIUS = THUMB_SIZE / 2;

export const valueToPercent = (value: number, min: number, max: number) =>
  max === min ? 0 : ((value - min) / (max - min)) * 100;

export const percentToThumbLeft = (percent: number) =>
  `calc(${THUMB_RADIUS}px + (100% - ${THUMB_SIZE}px) * ${percent / 100})`;

export const singleFillWidth = (percent: number) =>
  `calc(${THUMB_RADIUS}px + (100% - ${THUMB_SIZE}px) * ${percent / 100})`;

export const rangeFillLeft = (startPercent: number) =>
  `calc(${THUMB_RADIUS}px + (100% - ${THUMB_SIZE}px) * ${startPercent / 100})`;

export const rangeFillWidth = (startPercent: number, endPercent: number) =>
  `calc((100% - ${THUMB_SIZE}px) * ${(endPercent - startPercent) / 100})`;

export const pointerRatio = (clientX: number, rect: DOMRect) => {
  const usableWidth = rect.width - THUMB_SIZE;
  if (usableWidth <= 0) return 0;
  return Math.min(Math.max((clientX - rect.left - THUMB_RADIUS) / usableWidth, 0), 1);
};
