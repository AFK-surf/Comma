/**
 * Geometry for the connected image-preview filmstrip.
 *
 * Ported from https://github.com/zanwei/connected-filmstrip (MIT): every
 * image is fitted on one rigid, zero-gap strip. At rest, the clip window and
 * the active image share integer-pixel edges so a neighbouring slide cannot
 * bleed through the seam.
 */

export interface ImageFilmstripItemSize {
  height: number;
  width: number;
}

export interface ImageFilmstripFit {
  height: number;
  offset: number;
  width: number;
  x: number;
  y: number;
}

export interface ImageFilmstripBounds {
  bottom: number;
  top: number;
}

/**
 * During spatial motion, adjacent logical boxes stay edge-to-edge while each
 * image paints one pixel into its neighbour. Chromium otherwise antialiases
 * both edges against the transparent strip when a parent transform lands
 * between device pixels. Resting slides keep their logical width so a taller
 * neighbour cannot leak into a shorter active image's letterbox area.
 */
const IMAGE_FILMSTRIP_SEAM_OVERLAP_PX = 1;

export const computeImageFilmstripFits = (
  items: ImageFilmstripItemSize[],
  stageWidth: number,
  stageHeight: number,
  maxSlideWidth: number
): ImageFilmstripFit[] => {
  let offset = 0;

  return items.map((item) => {
    const scale = Math.min(stageHeight / item.height, maxSlideWidth / item.width);
    const width = Math.round(item.width * scale);
    const height = Math.round(item.height * scale);
    const fit = {
      height,
      offset,
      width,
      x: Math.round((stageWidth - width) / 2),
      y: Math.round((stageHeight - height) / 2),
    };
    offset += width;
    return fit;
  });
};

/**
 * The clip window keeps the vertical union of every slide throughout a move.
 * A tall outgoing image therefore cannot be cropped by a shorter neighbour.
 */
export const imageFilmstripBounds = (
  fits: ImageFilmstripFit[],
  stageHeight: number
): ImageFilmstripBounds => ({
  bottom: Math.min(...fits.map((fit) => stageHeight - fit.y - fit.height)),
  top: Math.min(...fits.map((fit) => fit.y)),
});

export const imageFilmstripClipPath = (
  fit: ImageFilmstripFit,
  stageWidth: number,
  bounds: ImageFilmstripBounds
): string =>
  `inset(${bounds.top}px ${stageWidth - fit.x - fit.width}px ${bounds.bottom}px ${fit.x}px)`;

export const imageFilmstripTranslateX = (fit: ImageFilmstripFit): number =>
  fit.x - fit.offset;

export const imageFilmstripPaintWidth = (fit: ImageFilmstripFit): number =>
  fit.width + IMAGE_FILMSTRIP_SEAM_OVERLAP_PX;
