import type { CSSProperties } from "react";

function hashWorkerIdentity(identity: string, salt: number) {
  let hash = (0x811c9dc5 ^ salt) >>> 0;

  for (let index = 0; index < identity.length; index += 1) {
    hash ^= identity.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
    hash ^= hash >>> 13;
  }

  hash = Math.imul(hash ^ (hash >>> 16), 0x85ebca6b) >>> 0;
  hash = Math.imul(hash ^ (hash >>> 13), 0xc2b2ae35) >>> 0;
  return (hash ^ (hash >>> 16)) >>> 0;
}

function channel(seed: number, shift: number, range: number, offset: number) {
  return offset + ((seed >>> shift) % range);
}

function meshColor(hue: number, saturation: number, lightness: number, alpha?: number) {
  const normalizedHue = ((hue % 360) + 360) % 360;
  return alpha === undefined
    ? `hsl(${normalizedHue} ${saturation}% ${lightness}%)`
    : `hsl(${normalizedHue} ${saturation}% ${lightness}% / ${alpha})`;
}

const workerPalettes = [
  { light: "#a5b4fc", accent: "#6366f1", depth: "#3730a3" },
  { light: "#7dd3fc", accent: "#0ea5e9", depth: "#075985" },
  { light: "#99f6e4", accent: "#14b8a6", depth: "#115e59" },
  { light: "#a7f3d0", accent: "#10b981", depth: "#065f46" },
  { light: "#fde68a", accent: "#f59e0b", depth: "#b45309" },
  { light: "#fed7aa", accent: "#f97316", depth: "#c2410c" },
  { light: "#fecdd3", accent: "#fb7185", depth: "#be123c" },
  { light: "#fbcfe8", accent: "#ec4899", depth: "#9d174d" },
  { light: "#ddd6fe", accent: "#8b5cf6", depth: "#5b21b6" },
  { light: "#c4b5fd", accent: "#7c3aed", depth: "#4338ca" },
] as const;

/**
 * A deterministic visual fingerprint for one public Worker identity.
 * Four independently salted hashes drive both the palette and mesh geometry;
 * no device-local randomness or persisted client state participates.
 */
export function workerMeshGradientStyle(actorId: string): CSSProperties {
  const seeds = [
    hashWorkerIdentity(actorId, 0x243f6a88),
    hashWorkerIdentity(actorId, 0x85a308d3),
    hashWorkerIdentity(actorId, 0x13198a2e),
    hashWorkerIdentity(actorId, 0x03707344),
  ];
  const palette = workerPalettes[seeds[0]! % workerPalettes.length]!;
  const lightPoint = {
    x: channel(seeds[1]!, 3, 30, 7),
    y: channel(seeds[1]!, 13, 25, 5),
  };
  const colorPoint = {
    x: channel(seeds[2]!, 4, 33, 57),
    y: channel(seeds[2]!, 15, 34, 52),
  };

  return {
    backgroundColor: palette.depth,
    backgroundImage: [
      `radial-gradient(circle at ${lightPoint.x}% ${lightPoint.y}%, hsl(0 0% 100% / 0.7) 0%, hsl(0 0% 100% / 0.12) 24%, transparent 48%)`,
      `radial-gradient(circle at ${colorPoint.x}% ${colorPoint.y}%, ${palette.light} 0%, transparent 58%)`,
      `linear-gradient(${125 + (seeds[3]! % 41)}deg, ${palette.light} 0%, ${palette.accent} 48%, ${palette.depth} 100%)`,
    ].join(", "),
    borderColor: meshColor(seeds[0]! % 360, 30, 24, 0.24),
    boxShadow:
      "inset 0 0 0 0.5px hsl(0 0% 100% / 0.32), inset 0 -3px 6px hsl(0 0% 0% / 0.08), 0 1px 2px hsl(0 0% 0% / 0.1)",
  };
}
