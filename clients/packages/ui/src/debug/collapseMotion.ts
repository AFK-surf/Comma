export type CubicBezier = {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
};

export type CollapseMotionLayer = {
  durationMs: number;
  bezier: CubicBezier;
};

export type CollapseContentHiddenTransform = {
  opacity: number;
  scale: number;
  translateX: number;
  translateY: number;
};

export type CollapseContentMotion = CollapseMotionLayer & {
  hidden: CollapseContentHiddenTransform;
};

export type CollapseMotionParams = {
  container: CollapseMotionLayer;
  content: CollapseContentMotion;
};

export const defaultCollapseMotion: CollapseMotionParams = {
  container: {
    durationMs: 180,
    bezier: { x1: 0.006, y1: 0.522, x2: 0.252, y2: 0.968 },
  },
  content: {
    durationMs: 200,
    bezier: { x1: 0.004, y1: 0.505, x2: 0.202, y2: 0.918 },
    hidden: {
      opacity: 0,
      scale: 0.98,
      translateX: 0,
      translateY: -10,
    },
  },
};

export const formatCubicBezier = ({ x1, y1, x2, y2 }: CubicBezier) =>
  `${x1.toFixed(3)}, ${y1.toFixed(3)}, ${x2.toFixed(3)}, ${y2.toFixed(3)}`;

export const formatCubicBezierCss = (value: CubicBezier) =>
  `cubic-bezier(${formatCubicBezier(value)})`;

/** Editor-visible range — maps 1:1 to the SVG plot so handles never leave the canvas. */
export const cubicBezierEditorBounds = {
  xMin: 0,
  xMax: 1,
  yMin: -0.25,
  yMax: 1.25,
} as const;

export const clampCubicBezierToEditor = (value: CubicBezier): CubicBezier => ({
  x1: clamp(value.x1, cubicBezierEditorBounds.xMin, cubicBezierEditorBounds.xMax),
  y1: clamp(value.y1, cubicBezierEditorBounds.yMin, cubicBezierEditorBounds.yMax),
  x2: clamp(value.x2, cubicBezierEditorBounds.xMin, cubicBezierEditorBounds.xMax),
  y2: clamp(value.y2, cubicBezierEditorBounds.yMin, cubicBezierEditorBounds.yMax),
});

const clamp = (value: number, min: number, max: number) =>
  Math.min(max, Math.max(min, value));

const collapseMotionLayerVars = {
  container: "collapse-container",
  content: "collapse-content",
} as const;

const applyLayerMotionToDocument = (
  root: HTMLElement,
  layer: keyof typeof collapseMotionLayerVars,
  { durationMs, bezier }: CollapseMotionLayer
) => {
  const prefix = collapseMotionLayerVars[layer];
  root.style.setProperty(`--${prefix}-duration`, `${durationMs}ms`);
  root.style.setProperty(`--${prefix}-bezier-x1`, String(bezier.x1));
  root.style.setProperty(`--${prefix}-bezier-y1`, String(bezier.y1));
  root.style.setProperty(`--${prefix}-bezier-x2`, String(bezier.x2));
  root.style.setProperty(`--${prefix}-bezier-y2`, String(bezier.y2));
};

const resetLayerMotionToDocument = (
  root: HTMLElement,
  layer: keyof typeof collapseMotionLayerVars
) => {
  const prefix = collapseMotionLayerVars[layer];
  root.style.removeProperty(`--${prefix}-duration`);
  root.style.removeProperty(`--${prefix}-bezier-x1`);
  root.style.removeProperty(`--${prefix}-bezier-y1`);
  root.style.removeProperty(`--${prefix}-bezier-x2`);
  root.style.removeProperty(`--${prefix}-bezier-y2`);
};

const contentHiddenVarNames = [
  "opacity-hidden",
  "scale-hidden",
  "translate-x-hidden",
  "translate-y-hidden",
] as const;

const applyContentHiddenTransformToDocument = (
  root: HTMLElement,
  hidden: CollapseContentHiddenTransform
) => {
  root.style.setProperty("--collapse-content-opacity-hidden", String(hidden.opacity));
  root.style.setProperty("--collapse-content-scale-hidden", String(hidden.scale));
  root.style.setProperty(
    "--collapse-content-translate-x-hidden",
    `${hidden.translateX}px`
  );
  root.style.setProperty(
    "--collapse-content-translate-y-hidden",
    `${hidden.translateY}px`
  );
};

const resetContentHiddenTransformOnDocument = (root: HTMLElement) => {
  for (const name of contentHiddenVarNames) {
    root.style.removeProperty(`--collapse-content-${name}`);
  }
};

export const applyCollapseMotionToDocument = (params: CollapseMotionParams) => {
  const root = document.documentElement;
  applyLayerMotionToDocument(root, "container", params.container);
  applyLayerMotionToDocument(root, "content", params.content);
  applyContentHiddenTransformToDocument(root, params.content.hidden);
};

export const resetCollapseMotionOnDocument = () => {
  const root = document.documentElement;
  resetLayerMotionToDocument(root, "container");
  resetLayerMotionToDocument(root, "content");
  resetContentHiddenTransformOnDocument(root);
};

export const serializeCollapseMotionParams = (params: CollapseMotionParams) =>
  JSON.stringify(params, null, 2);

export const copyTextToClipboard = async (text: string) => {
  try {
    await navigator.clipboard.writeText(text);
    return;
  } catch {
    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "true");
    textarea.style.position = "fixed";
    textarea.style.left = "-9999px";
    document.body.appendChild(textarea);
    textarea.select();
    document.execCommand("copy");
    textarea.remove();
  }
};
