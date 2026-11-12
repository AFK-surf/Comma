import { writeDocumentReducedMotion } from "../tokens";

export type StorybookMotionPreference = "full" | "reduced";

export const applyDocumentReducedMotion = (preference: StorybookMotionPreference) => {
  writeDocumentReducedMotion(preference === "reduced");
};

export const reducedMotionToolbarItems = [
  { value: "full", title: "Full motion", icon: "lightning" },
  { value: "reduced", title: "Reduced motion", icon: "lightningoff" },
] as const;
