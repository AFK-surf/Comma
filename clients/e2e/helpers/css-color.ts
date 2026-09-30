export interface CssRgbaColor {
  a: number;
  b: number;
  g: number;
  r: number;
}

const cssNumber = String.raw`[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?`;
const cssNumberOrPercentage = String.raw`${cssNumber}%?`;

const legacyRgbColorPattern = new RegExp(
  String.raw`^rgba?\(\s*(${cssNumberOrPercentage})\s*,\s*(${cssNumberOrPercentage})\s*,\s*(${cssNumberOrPercentage})(?:\s*,\s*(${cssNumberOrPercentage}))?\s*\)$`,
  "i"
);
const modernRgbColorPattern = new RegExp(
  String.raw`^rgba?\(\s*(${cssNumberOrPercentage})\s+(${cssNumberOrPercentage})\s+(${cssNumberOrPercentage})(?:\s*\/\s*(${cssNumberOrPercentage}))?\s*\)$`,
  "i"
);
const srgbColorPattern = new RegExp(
  String.raw`^color\(\s*srgb\s+(${cssNumberOrPercentage})\s+(${cssNumberOrPercentage})\s+(${cssNumberOrPercentage})(?:\s*\/\s*(${cssNumberOrPercentage}))?\s*\)$`,
  "i"
);
const oklchColorPattern = new RegExp(
  String.raw`^oklch\(\s*(${cssNumber})\s+(${cssNumber})\s+(${cssNumber})(?:deg)?(?:\s*\/\s*(${cssNumberOrPercentage}))?\s*\)$`,
  "i"
);

// Chrome resolves `color-mix()` in Oklab, so a mixed token computes to
// `oklab()` rather than the `oklch()` its source was written in.
const oklabColorPattern = new RegExp(
  String.raw`^oklab\(\s*(${cssNumber})\s+(${cssNumber})\s+(${cssNumber})(?:\s*\/\s*(${cssNumberOrPercentage}))?\s*\)$`,
  "i"
);

const parseAlpha = (token: string | undefined) => {
  if (token == null) return 1;
  const value = Number.parseFloat(token);
  return token.endsWith("%") ? value / 100 : value;
};

const parseRgbChannel = (token: string) => {
  const value = Number.parseFloat(token);
  return token.endsWith("%") ? (value / 100) * 255 : value;
};

const parseSrgbChannel = (token: string) => {
  const value = Number.parseFloat(token);
  return (token.endsWith("%") ? value / 100 : value) * 255;
};

const linearToSrgb8 = (channel: number) => {
  const clipped = Math.min(1, Math.max(0, channel));
  const encoded =
    clipped <= 0.0031308 ? 12.92 * clipped : 1.055 * clipped ** (1 / 2.4) - 0.055;
  return Math.round(encoded * 255);
};

const oklchToRgb = (lightness: number, chroma: number, hueDeg: number) => {
  const hue = (hueDeg * Math.PI) / 180;
  const a = chroma * Math.cos(hue);
  const b = chroma * Math.sin(hue);
  const lRoot = lightness + 0.3963377774 * a + 0.2158037573 * b;
  const mRoot = lightness - 0.1055613458 * a - 0.0638541728 * b;
  const sRoot = lightness - 0.0894841775 * a - 1.291485548 * b;
  const l = lRoot ** 3;
  const m = mRoot ** 3;
  const s = sRoot ** 3;
  return {
    b: linearToSrgb8(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
    g: linearToSrgb8(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    r: linearToSrgb8(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
  };
};

export const parseCssColor = (cssColor: string): CssRgbaColor => {
  const normalizedColor = cssColor.trim();
  const rgb =
    legacyRgbColorPattern.exec(normalizedColor) ??
    modernRgbColorPattern.exec(normalizedColor);
  if (rgb) {
    return {
      a: parseAlpha(rgb[4]),
      b: parseRgbChannel(rgb[3]!),
      g: parseRgbChannel(rgb[2]!),
      r: parseRgbChannel(rgb[1]!),
    };
  }

  const srgb = srgbColorPattern.exec(normalizedColor);
  if (srgb) {
    return {
      a: parseAlpha(srgb[4]),
      b: parseSrgbChannel(srgb[3]!),
      g: parseSrgbChannel(srgb[2]!),
      r: parseSrgbChannel(srgb[1]!),
    };
  }

  const oklch = oklchColorPattern.exec(normalizedColor);
  if (oklch) {
    return {
      a: parseAlpha(oklch[4]),
      ...oklchToRgb(
        Number.parseFloat(oklch[1]!),
        Number.parseFloat(oklch[2]!),
        Number.parseFloat(oklch[3]!)
      ),
    };
  }

  const oklab = oklabColorPattern.exec(normalizedColor);
  if (oklab) {
    const a = Number.parseFloat(oklab[2]!);
    const b = Number.parseFloat(oklab[3]!);
    return {
      a: parseAlpha(oklab[4]),
      ...oklchToRgb(
        Number.parseFloat(oklab[1]!),
        Math.hypot(a, b),
        (Math.atan2(b, a) * 180) / Math.PI
      ),
    };
  }

  if (normalizedColor.toLowerCase() === "transparent") {
    return { a: 0, b: 0, g: 0, r: 0 };
  }

  throw new Error(`Could not resolve CSS color: ${cssColor}`);
};
