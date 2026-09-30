import type { Decorator } from "@storybook/react-vite";
import { useEffect } from "react";
import {
  applyDocumentReducedMotion,
  type StorybookMotionPreference,
} from "../src/storybook/reducedMotion";

export const ReducedMotionDecorator: Decorator = (Story, { globals }) => {
  const preference =
    (globals.motionPreference as StorybookMotionPreference | undefined) ?? "full";

  useEffect(() => {
    applyDocumentReducedMotion(preference);
    return () => applyDocumentReducedMotion("full");
  }, [preference]);

  return <Story />;
};
