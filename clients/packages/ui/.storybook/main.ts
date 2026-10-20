import type { UserConfig } from "vite";
import type { StorybookConfig } from "@storybook/react-vite";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../../vite/comma-tailwind.ts";
import { commaI18nVitePlugin } from "@comma/i18n/vite";
import { layoutInspectorSourcePlugin } from "../../layout-inspector/src/vite.ts";
import { resolve } from "node:path";
import { mergeConfig } from "vite";

type BuildOnLog = NonNullable<
  NonNullable<NonNullable<UserConfig["build"]>["rolldownOptions"]>["onLog"]
>;

/**
 * Storybook's react-docgen plugin parses every source module the stories
 * import, following each export to its definition. On the generated message
 * catalog (packages/i18n/src/paraglide/messages/_index.js, thousands of
 * exports) that took three minutes of the four the static build took. Props
 * are documented only for components, which live in .tsx and .jsx files.
 */
function onlyDocumentComponentFiles(viteConfig: UserConfig): UserConfig {
  const plugins = (viteConfig.plugins ?? []).flat() as {
    name?: string;
    transform?: (this: unknown, code: string, id: string) => unknown;
  }[];
  for (const plugin of plugins) {
    if (plugin?.name !== "storybook:react-docgen-plugin" || !plugin.transform) continue;
    const transform = plugin.transform;
    plugin.transform = function (code, id) {
      return /\.[jt]sx$/.test(id.split("?")[0]!)
        ? transform.call(this, code, id)
        : undefined;
    };
  }
  return viteConfig;
}

const config: StorybookConfig = {
  stories: ["../src/**/*.stories.@(ts|tsx)", "../../app/src/**/*.stories.@(ts|tsx)"],
  addons: ["@storybook/addon-docs", "@storybook/addon-a11y", "@storybook/addon-vitest"],
  framework: {
    name: "@storybook/react-vite",
    options: {},
  },
  viteFinal: async (viteConfig) =>
    mergeConfig(onlyDocumentComponentFiles(viteConfig), {
      plugins: [
        layoutInspectorSourcePlugin({
          enabled: true,
          root: resolve(import.meta.dirname, "../../../.."),
        }),
        // Story tests read the messages that `pnpm install` compiled. The
        // plugin compiles again at each Vite server start with other runtime
        // options, so it rewrites the generated files while the browser is
        // importing them, and a story file then fails with a SyntaxError.
        process.env.VITEST ? [] : commaI18nVitePlugin(),
        tailwindcss(),
        localGroupSelectors(),
      ],
      build: {
        // The static build is a story catalog, not a shipped bundle.
        chunkSizeWarningLimit: 4096,
        rolldownOptions: {
          onLog(...[level, log, handler]: Parameters<BuildOnLog>) {
            // Build timings on a shared CI runner are noise.
            if (log.code === "PLUGIN_TIMINGS") return;
            // markstream-react ships minified code whose `@__PURE__` comments
            // Rolldown cannot place; it repeats one warning per comment.
            if (
              log.code === "INVALID_ANNOTATION" &&
              log.message.includes("/node_modules/")
            ) {
              return;
            }
            handler(level, log);
          },
        },
      },
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
            find: /^@comma\/ui(?=\/|$)/,
            replacement: resolve(import.meta.dirname, "../src"),
          },
        ],
      },
    }),
};

export default config;
