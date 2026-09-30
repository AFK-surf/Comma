import { LayoutInspector } from "@comma/layout-inspector";
import type { Decorator } from "@storybook/react-vite";

export const LayoutInspectorDecorator: Decorator = (Story, { globals }) => (
  <>
    <Story />
    {globals.layoutInspector === "enabled" ? <LayoutInspector defaultActive /> : null}
  </>
);

export const layoutInspectorToolbarItems = [
  { value: "disabled", title: "Inspector off", icon: "circlehollow" },
  { value: "enabled", title: "Inspector on", icon: "search" },
] as const;
