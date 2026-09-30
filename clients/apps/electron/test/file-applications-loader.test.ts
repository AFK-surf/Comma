import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  fileApplicationsCandidateBinaryPaths,
  loadFileApplicationsAddon,
} from "../native/macos/FileApplications";

describe("file applications native adapter", () => {
  it("uses only the shipped addon in packaged applications", () => {
    expect(
      fileApplicationsCandidateBinaryPaths({
        cwd: "/untrusted/check-out",
        environmentPath: "/untrusted/addon.node",
        isPackaged: true,
        resourcesPath: "/Applications/Comma.app/Contents/Resources",
      })
    ).toEqual([
      "/Applications/Comma.app/Contents/Resources/native/macos/comma-file-applications.node",
    ]);
  });

  it("exposes the AppKit adapter and does not make up associations off macOS", async () => {
    const addon = loadFileApplicationsAddon({
      binaryPath: resolve(
        process.cwd(),
        "apps/electron/test/fixtures/file-applications.cjs"
      ),
      platform: "darwin",
    });
    expect(addon.loaded).toBe(true);
    await expect(addon.listApplicationsForFileName("report.pdf")).resolves.toEqual([
      {
        applicationPath: "/Applications/Preview.app",
        name: "Preview",
        isDefault: true,
      },
    ]);
    const unsupported = loadFileApplicationsAddon({ platform: "win32" });
    expect(unsupported.loaded).toBe(false);
    await expect(
      unsupported.listApplicationsForFileName("report.pdf")
    ).resolves.toBeNull();
    await expect(unsupported.openFileWithApplication("file.pdf", "app")).resolves.toBe(
      false
    );
  });

  it("fails closed when the installed native binary does not provide the API", async () => {
    const addon = loadFileApplicationsAddon({
      binaryPath: resolve(
        process.cwd(),
        "apps/electron/test/fixtures/notification-authorization-denied.cjs"
      ),
      platform: "darwin",
    });
    expect(addon.loaded).toBe(false);
    await expect(addon.listApplicationsForFileName("report.pdf")).resolves.toBeNull();
  });
});
