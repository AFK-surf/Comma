import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

const copied = vi.hoisted(() => [] as { from: string; to: string }[]);
vi.mock("node:fs", async (original) => ({
  ...(await original<typeof import("node:fs")>()),
  cpSync: (from: string, to: string) => void copied.push({ from, to }),
}));

const { default: config } = await import("../forge.config");

type AfterCopy = (
  buildPath: string,
  electronVersion: string,
  platform: string,
  arch: string,
  done: (error?: Error) => void
) => void;

// The per-triple packages resolve only where they are installed: the macOS arm64 build machines.
describe.runIf(process.platform === "darwin" && process.arch === "arm64")(
  "the packaged app",
  () => {
    it("carries in node_modules the installed packages loaded outside the bundle, and the station's natives as resources", async () => {
      const buildPath = join(tmpdir(), "comma-forge-config", "app");
      const afterCopy = config.packagerConfig?.afterCopy?.[0] as AfterCopy;
      await new Promise<void>((resolve, reject) =>
        afterCopy(buildPath, "0.0.0", "darwin", "arm64", (error) =>
          error ? reject(error) : resolve()
        )
      );
      const names = [
        "velopack",
        "@neon-rs/load",
        "@recappi/sdk",
        "@recappi/sdk-darwin-arm64",
      ];
      expect(copied.map(({ to }) => to)).toEqual(
        names.map((name) => join(buildPath, "node_modules", ...name.split("/")))
      );
      expect(
        copied.map(
          ({ from }) =>
            (
              JSON.parse(readFileSync(join(from, "package.json"), "utf8")) as {
                name: string;
              }
            ).name
        )
      ).toEqual(names);
      // The station the app carries, with the mesh addon the core's endpoint is on (build-native.ts).
      expect(config.packagerConfig?.extraResource).toContain("dist/native");
    });
  }
);
