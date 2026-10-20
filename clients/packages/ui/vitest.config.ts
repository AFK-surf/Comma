import { globSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { storybookTest } from "@storybook/addon-vitest/vitest-plugin";
import { loadCsf } from "storybook/internal/csf-tools";
import { defineConfig, type Plugin } from "vitest/config";
import { noDependencySourceMapsPlugin } from "../../vite/no-dependency-source-maps";
import {
  parseFailureWatchPlugin,
  playwrightWithParseFailureWatch,
} from "../../vite/parse-failure-watch";
import storybookConfig from "./.storybook/main";

const dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * Stories run in jsdom with the unit tests (`src/storybook/test/stories.test.tsx`)
 * unless they carry the `browser` tag, because their play functions or rendering
 * need real layout, CSS, canvas or browser APIs. This project runs only those.
 */
const BROWSER_TAG = "browser";

/**
 * The story files that hold a `browser`-tagged story. The plugin builds its test
 * list from every story file, so a file with no browser story would still load
 * in Chromium only to collect zero tests. Tags are read statically, as the
 * plugin reads them to filter stories.
 */
function browserStoryFiles(): string[] {
  const configDir = path.join(dirname, ".storybook");
  const { stories } = storybookConfig;
  if (!Array.isArray(stories)) throw new Error("Storybook stories must be a list");
  return stories
    .flatMap((pattern) => {
      if (typeof pattern !== "string") throw new Error("Use string story globs");
      // Node's glob has no extglob: `.@(ts|tsx)` becomes `.{ts,tsx}`.
      const glob = pattern.replace(
        /\.@\((.*)\)$/,
        (_, extensions: string) => `.{${extensions.replaceAll("|", ",")}}`
      );
      return globSync(path.resolve(configDir, glob));
    })
    .filter((file) =>
      loadCsf(readFileSync(file, "utf8"), {
        fileName: file,
        makeTitle: (title) => title,
      })
        .parse()
        .indexInputs.some((story) => story.tags?.includes(BROWSER_TAG))
    )
    .map((file) => path.relative(dirname, file))
    .toSorted();
}

const onlyBrowserStoryFiles: Plugin = {
  name: "comma:storybook-browser-story-files",
  enforce: "post",
  config(config) {
    config.test ??= {};
    config.test.include = browserStoryFiles();
  },
};

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
            tags: { include: [BROWSER_TAG] },
          }),
          decodeStoryModuleUrl,
          noDependencySourceMapsPlugin(),
          parseFailureWatchPlugin(),
          onlyBrowserStoryFiles,
        ],
        // Effect is plain ES modules; served as its own files, no response is
        // a 4 MB bundle (clients/vite/no-dependency-source-maps.ts).
        optimizeDeps: { exclude: ["effect"] },
        test: {
          name: "storybook",
          // Chromium keeps frame state for every story iframe a page has
          // removed (vitest-dev/vitest#10300), so a page's renderer grows with
          // each file it runs and long runs end in "Browser connection was
          // closed while running tests". Vitest opens `cpus - 1` pages: the
          // 4-vCPU CI runner pushes every story file through 3 pages while a
          // 12-core laptop spreads them over 11, which is why the run has only
          // ever died in CI. Pin the page count so no page carries more than
          // a handful of files anywhere.
          maxWorkers: 8,
          browser: {
            enabled: true,
            headless: true,
            // Stories render into one iframe per page instead of a fresh one
            // per file: the preview's setup (styles, decorators, messages)
            // ran again for every file, five times the stories' own time.
            isolate: false,
            provider: playwrightWithParseFailureWatch(),
            instances: [{ browser: "chromium" }],
          },
        },
      },
    ],
  },
});
