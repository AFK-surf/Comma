import type { StorybookConfig } from "@storybook/react-vite";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../../vite/comma-tailwind";
import { commaI18nVitePlugin } from "@comma/i18n/vite";
import { layoutInspectorSourcePlugin } from "../../layout-inspector/src/vite.ts";
import { resolve } from "node:path";
import { mergeConfig } from "vite";

const config: StorybookConfig = {
  stories: ["../src/**/*.stories.@(ts|tsx)", "../../app/src/**/*.stories.@(ts|tsx)"],
  addons: ["@storybook/addon-docs", "@storybook/addon-a11y", "@storybook/addon-vitest"],
  framework: {
    name: "@storybook/react-vite",
    options: {},
  },
  viteFinal: async (viteConfig) =>
    mergeConfig(viteConfig, {
      plugins: [
        layoutInspectorSourcePlugin({
          enabled: true,
          root: resolve(import.meta.dirname, "../../../.."),
        }),
        commaI18nVitePlugin(),
        tailwindcss(),
        localGroupSelectors(),
      ],
      optimizeDeps: {
        include: [
          "@central-icons-react/round-outlined-radius-2-stroke-2/IconAudio",
          "@central-icons-react/round-outlined-radius-2-stroke-2/IconCmd",
          "@central-icons-react/round-outlined-radius-2-stroke-2/IconCreditCard2",
          "@central-icons-react/round-outlined-radius-2-stroke-2/IconDevices",
          "@central-icons-react/round-outlined-radius-2-stroke-2/IconPaintBrush",
          "@central-icons-react/round-outlined-radius-2-stroke-2/IconPeopleCircle",
          "@central-icons-react/round-outlined-radius-2-stroke-2/IconWindowCursor",
          // The markdown stream's highlight worker pulls shiki in only once a
          // story renders code. Discovered that late, the optimizer re-bundles
          // and reloads every story file mid-run, and vitest counts the
          // interrupted files as failed.
          "shiki",
        ],
      },
      resolve: {
        alias: [
          {
            find: "@comma/layout-inspector",
            replacement: resolve(
              import.meta.dirname,
              "../../layout-inspector/src/index.ts"
            ),
          },
          {
            find: /^@comma\/ui$/,
            replacement: resolve(import.meta.dirname, "../src/index.ts"),
          },
        ],
      },
    }),
};

export default config;
