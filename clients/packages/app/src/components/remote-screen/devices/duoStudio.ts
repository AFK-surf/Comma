// The studio the 3D iPhone Duo's metal reflects: a bright white room with white strip lights and a few thin dark lines, as
// an equirectangular picture (the phone app draws the same, DuoStageView.studio). Polished metal mirrors it bright, with
// crisp dark lines along its rounded edges, which is what reads as a polished frame; a soft, even room reads matte.

/** The frame's polished metal: a light silver champagne (sRGB), as the device's light finish. */
export const DUO_METAL_LIGHT = { r: 0.85, g: 0.84, b: 0.81 } as const;
/** How rough each metal of the model is, by its material's name: near mirror for the frame, keys and lens rings. */
export const DUO_METAL_ROUGHNESS: Readonly<Record<string, number>> = {
  Frame: 0.06,
  CameraKey: 0.05,
  LensRing: 0.06,
  CameraPlate: 0.14,
};

export function duoStudioCanvas(document: Document): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  const w = 2048;
  const h = 1024;
  canvas.width = w;
  canvas.height = h;
  const g = canvas.getContext("2d");
  if (!g) return canvas;
  const sky = g.createLinearGradient(0, 0, 0, h);
  sky.addColorStop(0, "rgb(250,250,250)");
  sky.addColorStop(0.5, "rgb(226,226,226)");
  sky.addColorStop(1, "rgb(160,160,160)");
  g.fillStyle = sky;
  g.fillRect(0, 0, w, h);
  const band = (x: number, y: number, width: number, height: number, white: number) => {
    const v = Math.round(white * 255);
    g.fillStyle = `rgb(${v},${v},${v})`;
    g.fillRect(x, y, width, height);
  };
  // thin dark lines: where the walls meet the ceiling and the floor, and a few stands: what draws the metal's edges
  for (const y of [0.3, 0.42, 0.62]) band(0, h * y, w, h * 0.02, 0.06);
  for (const x of [0.07, 0.33, 0.47, 0.72])
    band(w * x, h * 0.12, w * 0.016, h * 0.6, 0.08);
  // white strip lights: overhead, tall ones, the horizon
  band(0, h * 0.05, w, h * 0.04, 1);
  for (const x of [0.22, 0.6, 0.9]) band(w * x, h * 0.12, w * 0.03, h * 0.36, 1);
  band(0, h * 0.495, w, h * 0.01, 1);
  return canvas;
}
