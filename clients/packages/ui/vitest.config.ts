import path from "node:path";
import { fileURLToPath } from "node:url";

import { storybookTest } from "@storybook/addon-vitest/vitest-plugin";
import { playwright } from "@vitest/browser-playwright";
import { defineConfig, type Plugin } from "vitest/config";

const dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * `@storybook/addon-vitest` guards every generated story test with
 * `convertToFilePath(import.meta.url).includes(<absolute test path>)`, but that
 * helper only decodes `%20`. A repository path holding any other non-ASCII
 * character — an accented letter, CJK, an emoji — stays percent-encoded in the
 * browser module URL while Vitest reports the decoded path, so the guard is
 * always false and every story file collects zero tests. Decoding first is a
 * no-op for plain ASCII paths and restores the intended comparison otherwise.
 */
const decodeStoryModuleUrl: Plugin = {
  name: "comma:storybook-decode-module-url",
  enforce: "post",
  transform(code, id) {
    if (
      !id.includes(".stories.") ||
      !code.includes("convertToFilePath(import.meta.url)")
    )
      return;

    return {
      code: code.replace(
        "convertToFilePath(import.meta.url)",
        "convertToFilePath(decodeURIComponent(import.meta.url))"
      ),
      map: null,
    };
  },
};

export default defineConfig({
  test: {
    projects: [
      {
        extends: true,
        plugins: [
          storybookTest({
            configDir: path.join(dirname, ".storybook"),
          }),
          decodeStoryModuleUrl,
        ],
        test: {
          name: "storybook",
          // Chromium keeps frame state for every story iframe a page has
          // removed (vitest-dev/vitest#10300), so a page's renderer grows with
          // each file it runs and long runs end in "Browser connection was
          // closed while running tests". Vitest opens `cpus - 1` pages: the
          // 4-vCPU CI runner pushes all 55 story files through 3 pages while a
          // 12-core laptop spreads them over 11, which is why the run has only
          // ever died in CI. Pin the page count so no page carries more than
          // a handful of files anywhere.
          maxWorkers: 8,
          browser: {
            enabled: true,
            headless: true,
            provider: playwright({}),
            instances: [{ browser: "chromium" }],
          },
        },
      },
    ],
  },
});
