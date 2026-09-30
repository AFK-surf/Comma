import type { Preview } from "@storybook/react-vite";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { createElement } from "react";
import "../src/styles.css";
import {
  LayoutInspectorDecorator,
  layoutInspectorToolbarItems,
} from "./LayoutInspectorDecorator";
import { reducedMotionToolbarItems } from "../src/storybook/reducedMotion";
import { ReducedMotionDecorator } from "./ReducedMotionDecorator";
import { ThemeDecorator, themeToolbarItems } from "./ThemeDecorator";

const locale = initializeCommaI18n(["en"]);

const preview: Preview = {
  decorators: [
    LayoutInspectorDecorator,
    ReducedMotionDecorator,
    ThemeDecorator,
    (Story) => createElement(CommaI18nProvider, { locale }, createElement(Story)),
  ],
  globalTypes: {
    layoutInspector: {
      description: "Inspect and preview story layout tokens",
      toolbar: {
        title: "Layout inspector",
        icon: "search",
        items: [...layoutInspectorToolbarItems],
        dynamicTitle: true,
      },
    },
    motionPreference: {
      description: "Preview stories with reduced motion",
      toolbar: {
        title: "Motion",
        icon: "lightning",
        items: [...reducedMotionToolbarItems],
        dynamicTitle: true,
      },
    },
    theme: {
      description: "Color theme",
      toolbar: {
        title: "Theme",
        icon: "circlehollow",
        items: [...themeToolbarItems],
        dynamicTitle: true,
      },
    },
  },
  initialGlobals: {
    layoutInspector: "disabled",
    motionPreference: "full",
    theme: "light",
  },
  parameters: {
    controls: {
      matchers: {
        color: /(background|color)$/i,
        date: /Date$/i,
      },
    },
    docs: {
      toc: true,
    },
    layout: "centered",
    options: {
      storySort: {
        order: [
          "Foundations",
          ["Colors", "Typography", "Effect styles", "Spacing", "Icons"],
          "Base components",
          [
            "Buttons",
            "Button groups",
            "Badges",
            "Tags",
            "Dropdown",
            "Inputs",
            "Toggles",
            "Checkboxes",
            "Checkbox groups",
            "Avatars",
            "Tooltips",
            "Indicators",
            "Sliders",
            "Collapse",
          ],
          "App components",
          [
            "Toast",
            "Dialog",
            "Plugins",
            "Status Indicator",
            "Left Sidebar",
            "Right Sidebar",
            "Recommendations",
            "Settings Sidebar",
          ],
          "Status feedback",
          ["Overview"],
          "Side Chat",
          ["Overview"],
          "Dev components",
          ["Resize Container"],
        ],
      },
    },
  },
};

export default preview;
