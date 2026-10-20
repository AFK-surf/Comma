import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { build } from "vite";
import type { TestProject } from "vitest/node";
import { appShellPagesBuild, appShellPagesDir } from "../../../vitest.config";

declare module "vitest" {
  interface ProvidedContext {
    crossOriginMediaOrigin: string;
    appShellPages: "built" | "dev";
    /** The port the run's server listens on: no page sees it (vite/app-shell-origin.ts). */
    browserServerPort: number;
  }
}

/**
 * Another origin for generated media. No server answers it: the tests' fake
 * media answers its fetches in the page (./fake-media), with and without CORS.
 */
export default async function setup(project: TestProject) {
  project.provide("crossOriginMediaOrigin", "http://cross-origin-media.test");
  project.provide("browserServerPort", Number(project.config.browser.api.port));
  // The tests' pages load from one build of their entry and fixtures
  // (vitest.config.ts, appShellPagesBuild).
  const pages = process.env.COMMA_APP_SHELL_PAGES === "dev" ? "dev" : "built";
  // Runs that start together (CI shards) share one build made before them
  // (../pages.vite.config.ts); a run that finds none builds its own.
  const prebuilt =
    process.env.COMMA_APP_SHELL_PAGES === "prebuilt" &&
    existsSync(resolve(appShellPagesDir, "runtime-child.js"));
  if (pages === "built" && !prebuilt) await build(appShellPagesBuild());
  project.provide("appShellPages", pages);
}
