import { describe, expect, it, vi } from "vitest";
import { windowsFileApplications } from "../modules/files/windows-file-applications";

const path = "C:\\Users\\test\\Downloads\\clip; $(rm) [1].mp4";

describe("windowsFileApplications", () => {
  it("copies a file through System32's PowerShell, the path passed as data and never as script", async () => {
    const run = vi.fn(async () => undefined);
    const applications = windowsFileApplications({
      env: { PATH: "C:\\evil", SystemRoot: "C:\\Windows" },
      run,
    });

    expect(await applications.copyFileToClipboard?.(path)).toBe(true);
    expect(run).toHaveBeenCalledWith(
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
      [
        "-NoProfile",
        "-NonInteractive",
        "-STA",
        "-Command",
        "Set-Clipboard -ErrorAction Stop -LiteralPath $env:COMMA_COPY_FILE_PATH",
      ],
      expect.objectContaining({
        env: {
          COMMA_COPY_FILE_PATH: path,
          PATH: "C:\\evil",
          SystemRoot: "C:\\Windows",
        },
        windowsHide: true,
      })
    );
  });

  it("reports a copy PowerShell fails or does not finish as unavailable", async () => {
    const applications = windowsFileApplications({
      env: { SystemRoot: "C:\\Windows" },
      run: async () => {
        throw new Error("Set-Clipboard failed");
      },
    });

    expect(await applications.copyFileToClipboard?.(path)).toBe(false);
  });

  it("offers no other applications to open a file with", async () => {
    const applications = windowsFileApplications({ run: vi.fn() });

    expect(await applications.listApplicationsForFileName("clip.mp4")).toBeNull();
    expect(await applications.listApplicationsForFile(path)).toBeNull();
    expect(await applications.openFileWithApplication(path, "C:\\app.exe")).toBe(false);
  });
});
