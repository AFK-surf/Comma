import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { loadFileApplicationsAddon } from "../native/macos/FileApplications";
import { filesListOpenApplicationsResultSchema } from "@comma/native-bridge";
import { DownloadsService } from "../src/main/modules/files/downloads";

// Run against the built AppKit addon and real Launch Services, not the sandbox's
// empty association registry: COMMA_NATIVE_FILE_APPLICATIONS_SMOKE=1 vitest run ...
describe.skipIf(
  process.platform !== "darwin" ||
    process.env.COMMA_NATIVE_FILE_APPLICATIONS_SMOKE !== "1"
)("real AppKit file associations", () => {
  const addon = loadFileApplicationsAddon({
    binaryPath: resolve(
      process.cwd(),
      "apps/electron/dist/native/macos/comma-file-applications.node"
    ),
  });

  it("queries PDF, image, audio, video, web, and Markdown associations without opening apps", async () => {
    expect(addon.loaded).toBe(true);
    for (const fileName of [
      "report.pdf",
      "picture.png",
      "song.mp3",
      "clip.mp4",
      "index.html",
      "README.md",
    ]) {
      const applications = await addon.listApplicationsForFileName(fileName);
      expect(applications?.length).toBeGreaterThan(0);
      expect(applications!.length).toBeLessThanOrEqual(32);
      expect(
        applications!.every(({ applicationPath }) => applicationPath.startsWith("/"))
      ).toBe(true);
      expect(applications!.some(({ isDefault }) => isDefault)).toBe(true);
      const icon = applications!.find(({ isDefault }) => isDefault)?.iconDataUrl;
      expect(icon).toMatch(/^data:image\/png;base64,/);
      const png = Buffer.from(icon!.split(",")[1]!, "base64");
      expect(png.subarray(0, 8)).toEqual(
        Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])
      );
      expect([png.readUInt32BE(16), png.readUInt32BE(20)]).toEqual([32, 32]);
    }
  });

  it("keeps OS paths inside Main and queries handlers for the actual saved file", async () => {
    const directory = await mkdtemp(join(tmpdir(), "comma-file-applications-"));
    const service = new DownloadsService({
      applications: addon,
      openPath: async () => "",
      resolveDownloadsDirectory: () => directory,
      revealPath: () => {},
    });
    try {
      const menu = filesListOpenApplicationsResultSchema.parse(
        await service.listOpenApplications({ fileName: "report.pdf" })
      );
      expect(menu.status).toBe("available");
      expect(JSON.stringify(menu)).not.toContain("applicationPath");
      const file = join(directory, "report.pdf");
      await writeFile(file, "%PDF-1.4\n% association lookup fixture, not rendered\n");
      expect((await addon.listApplicationsForFile(file))!.length).toBeGreaterThan(0);
      await rm(file);
      expect(await addon.listApplicationsForFile(file)).toEqual([]);
    } finally {
      await rm(directory, { force: true, recursive: true });
    }
  });
});
