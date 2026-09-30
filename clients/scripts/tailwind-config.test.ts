import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

describe("Tailwind config loading", () => {
  it.each([
    ["electron", "vite.renderer.config.ts", "bundle"],
    ["web", "vite.config.ts", "bundle"],
    ["web", "vite.config.ts", "runner"],
    ["admin", "vite.config.ts", "runner"],
  ])(
    "loads plugins through the real %s config with %s via %s",
    (app, config, loader) => {
      // Use Node outside Vitest's module transform. Electron's CommonJS config
      // and the web ESM config must both import the ESM-only Tailwind package.
      const output = execFileSync(
        process.execPath,
        [
          "--input-type=module",
          "-e",
          `import { loadConfigFromFile } from "vite";
const loaded = await loadConfigFromFile(
  { command: "build", mode: "production" }, ${JSON.stringify(config)},
  undefined, undefined, undefined, ${JSON.stringify(loader)}
);
const plugins = (await Promise.all(loaded.config.plugins)).flat(Infinity);
console.log(JSON.stringify(plugins.filter(Boolean).map(plugin => plugin.name)));`,
        ],
        {
          cwd: resolve(import.meta.dirname, "../apps", app),
          encoding: "utf8",
          timeout: 30_000,
          env: { ...process.env, COMMA_BUILD_FLAVOR: "dev" },
        }
      );
      const plugins = JSON.parse(output.trim().split("\n").at(-1)!);
      expect(plugins).toContain("@tailwindcss/vite:generate:build");
      expect(plugins).toContain("comma:local-group-selectors");
      expect(plugins.indexOf("comma:local-group-selectors")).toBeGreaterThan(
        plugins.indexOf("@tailwindcss/vite:generate:build")
      );
    }
  );
});
