import QRCode from "qrcode";

/**
 * Store QR codes drawn the way comma.surf/download draws its own: round data
 * dots, concentric rounded finder squares and a cleared centre that carries a
 * one-colour platform mark. Both codes use one symbol version so their dots
 * share a pitch when they sit side by side.
 */
export type ShareQrMatrix = {
  size: number;
  /** Row-major dark-module flags (`1` = dark). */
  modules: Uint8Array;
};

export type ShareQrLogo = "apple" | "android";

/** Version 7 (45 × 45) holds either store URL at error-correction level H. */
const SHARE_QR_VERSION = 7;
const FINDER_SIZE = 7;
/** Modules cleared around the centre mark (comma.surf: 11 of 45). */
const CENTER_CLEAR_MODULES = 11;
/** Modules the centre mark spans (comma.surf: 9 of 45, 20% of the width). */
const CENTER_LOGO_MODULES = 9;
const DOT_RADIUS = 0.42;

/** Apple mark, viewBox 0 0 24 24 (comma.surf `#i-apple`). */
const APPLE_LOGO_PATH =
  "M15.0993 3.35783C14.3953 4.21083 13.2038 4.8472 12.256 4.8472C12.1477 4.8472 12.0394 4.83366 11.9717 4.82012C11.9581 4.76596 11.931 4.60348 11.931 4.44101C11.931 3.35783 12.4862 2.27466 13.0819 1.59768C13.8401 0.704062 15.1129 0.040619 16.1689 0C16.196 0.121857 16.2096 0.270793 16.2096 0.419729C16.2096 1.5029 15.7492 2.57253 15.0993 3.35783ZM15.844 5.07737C16.4397 5.07737 18.5925 5.13153 20.0007 7.16248C19.8788 7.25725 17.7395 8.46228 17.7395 11.1567C17.7395 14.2708 20.461 15.381 20.5423 15.4081C20.5287 15.4758 20.109 16.911 19.107 18.3868C18.2134 19.6731 17.2657 20.9729 15.844 20.9729C14.4088 20.9729 14.0432 20.1335 12.4049 20.1335C10.7937 20.1335 10.225 21 8.92523 21C7.61188 21 6.70473 19.795 5.66217 18.3327C4.44361 16.5996 3.46875 13.9188 3.46875 11.3733C3.46875 7.29787 6.12252 5.13153 8.73567 5.13153C10.1167 5.13153 11.2676 6.03868 12.1477 6.03868C12.9736 6.03868 14.2599 5.07737 15.844 5.07737Z";

/** Android head, viewBox 0 0 24 24 (comma.surf `#i-android`): even-odd body plus stroked antennae. */
const ANDROID_HEAD_PATH =
  "M1 18.5a11 11 0 0 1 22 0zm6.4-3a1.3 1.3 0 1 0 0-2.6 1.3 1.3 0 0 0 0 2.6zm9.2 0a1.3 1.3 0 1 0 0-2.6 1.3 1.3 0 0 0 0 2.6z";
const ANDROID_ANTENNAE_PATH = "M6.9 11.3 4.3 6.6M17.1 11.3 19.7 6.6";

export function encodeShareQr(url: string): ShareQrMatrix {
  const { modules } = QRCode.create(url, {
    errorCorrectionLevel: "H",
    version: SHARE_QR_VERSION,
  });
  return { size: modules.size, modules: Uint8Array.from(modules.data) };
}

function isFinderModule(size: number, row: number, col: number): boolean {
  const nearTop = row < FINDER_SIZE;
  const nearLeft = col < FINDER_SIZE;
  const nearBottom = row >= size - FINDER_SIZE;
  const nearRight = col >= size - FINDER_SIZE;
  return (nearTop && nearLeft) || (nearTop && nearRight) || (nearBottom && nearLeft);
}

/** Alignment-pattern centres for `version` (ISO/IEC 18004, Annex E). */
function alignmentCenters(version: number, size: number): number[] {
  if (version === 1) return [];
  const count = Math.floor(version / 7) + 2;
  const step = Math.floor((version * 8 + count * 3 + 5) / (count * 4 - 4)) * 2;
  const centers = [6];
  for (let pos = size - 7; centers.length < count; pos -= step)
    centers.splice(1, 0, pos);
  return centers;
}

function addRoundedSquare(
  path: Path2D,
  x: number,
  y: number,
  side: number,
  radius: number
) {
  path.moveTo(x + radius, y);
  path.lineTo(x + side - radius, y);
  path.arcTo(x + side, y, x + side, y + radius, radius);
  path.lineTo(x + side, y + side - radius);
  path.arcTo(x + side, y + side, x + side - radius, y + side, radius);
  path.lineTo(x + radius, y + side);
  path.arcTo(x, y + side, x, y + side - radius, radius);
  path.lineTo(x, y + radius);
  path.arcTo(x, y, x + radius, y, radius);
  path.closePath();
}

function drawCenterLogo(
  ctx: CanvasRenderingContext2D,
  logo: ShareQrLogo,
  x: number,
  y: number,
  side: number,
  color: string
) {
  const scale = side / 24;
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(scale, scale);
  ctx.fillStyle = color;
  if (logo === "apple") {
    // oxlint-disable-next-line unicorn/no-array-fill-with-reference-type -- CanvasRenderingContext2D.fill(Path2D), not Array.prototype.fill
    ctx.fill(new Path2D(APPLE_LOGO_PATH));
  } else {
    // oxlint-disable-next-line unicorn/no-array-fill-with-reference-type -- CanvasRenderingContext2D.fill(Path2D), not Array.prototype.fill
    ctx.fill(new Path2D(ANDROID_HEAD_PATH), "evenodd");
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.lineCap = "round";
    ctx.stroke(new Path2D(ANDROID_ANTENNAE_PATH));
  }
  ctx.restore();
}

/**
 * Draws `matrix` as vector geometry into the `side` × `side` square at
 * (`x`, `y`), in the context's current units. Nothing is resampled, so the
 * dots stay sharp at any export scale.
 */
export function drawShareQr(
  ctx: CanvasRenderingContext2D,
  matrix: ShareQrMatrix,
  options: { x: number; y: number; side: number; logo: ShareQrLogo; color: string }
) {
  if (typeof Path2D === "undefined") return;
  const { size, modules } = matrix;
  const { x, y, side, logo, color } = options;
  const unit = side / size;
  const clearStart = (size - CENTER_CLEAR_MODULES) / 2;
  const clearEnd = clearStart + CENTER_CLEAR_MODULES;
  const inCenter = (row: number, col: number) =>
    row >= clearStart && row < clearEnd && col >= clearStart && col < clearEnd;

  // Alignment patterns stay solid: drawn as dots they read like the data
  // around them, and a reader that locks onto the wrong one samples the grid
  // askew (jsQR fails about half the time at export size).
  const centers = alignmentCenters((size - 17) / 4, size);
  const alignments = centers
    .flatMap((row) => centers.map((col) => [row, col] as const))
    .filter(
      ([row, col]) =>
        !isFinderModule(size, row - 2, col - 2) &&
        !isFinderModule(size, row + 2, col + 2) &&
        !isFinderModule(size, row - 2, col + 2) &&
        !isFinderModule(size, row + 2, col - 2) &&
        !inCenter(row, col)
    );
  const inAlignment = (row: number, col: number) =>
    alignments.some(([ar, ac]) => Math.abs(row - ar) <= 2 && Math.abs(col - ac) <= 2);

  ctx.save();
  ctx.translate(x, y);
  ctx.scale(unit, unit);
  ctx.fillStyle = color;

  const dots = new Path2D();
  for (let row = 0; row < size; row += 1) {
    for (let col = 0; col < size; col += 1) {
      if (!modules[row * size + col]) continue;
      if (isFinderModule(size, row, col) || inCenter(row, col)) continue;
      if (inAlignment(row, col)) continue;
      dots.moveTo(col + 0.5 + DOT_RADIUS, row + 0.5);
      dots.arc(col + 0.5, row + 0.5, DOT_RADIUS, 0, Math.PI * 2);
    }
  }
  // oxlint-disable-next-line unicorn/no-array-fill-with-reference-type -- CanvasRenderingContext2D.fill(Path2D), not Array.prototype.fill
  ctx.fill(dots);

  const finders = new Path2D();
  const corners: Array<[number, number]> = [
    [0, 0],
    [size - FINDER_SIZE, 0],
    [0, size - FINDER_SIZE],
  ];
  for (const [fx, fy] of corners) {
    addRoundedSquare(finders, fx, fy, 7, 2);
    addRoundedSquare(finders, fx + 1, fy + 1, 5, 1.4);
    addRoundedSquare(finders, fx + 2, fy + 2, 3, 0.9);
  }
  for (const [row, col] of alignments) {
    addRoundedSquare(finders, col - 2, row - 2, 5, 1.4);
    addRoundedSquare(finders, col - 1, row - 1, 3, 0.9);
    addRoundedSquare(finders, col, row, 1, 0.5);
  }
  // oxlint-disable-next-line unicorn/no-array-fill-with-reference-type -- CanvasRenderingContext2D.fill(Path2D), not Array.prototype.fill
  ctx.fill(finders, "evenodd");
  ctx.restore();

  const logoStart = (size - CENTER_LOGO_MODULES) / 2;
  drawCenterLogo(
    ctx,
    logo,
    x + logoStart * unit,
    y + logoStart * unit,
    CENTER_LOGO_MODULES * unit,
    color
  );
}
