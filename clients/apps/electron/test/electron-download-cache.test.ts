import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { electronDownloadCache } from "../scripts/electron-download-cache";

const require = createRequire(import.meta.url);
const { downloadArtifact } = createRequire(require.resolve("@electron/packager"))(
  "@electron/get"
);

it("reuses a verified archive after the runner's temporary disk is replaced", async () => {
  const host = await mkdtemp(join(tmpdir(), "comma-electron-host-"));
  const archive = Buffer.from("downloaded Electron archive fixture");
  const digest = createHash("sha256").update(archive).digest("hex");
  let archiveDownloads = 0;
  let checksumDownloads = 0;
  const downloader = {
    async download(url: string, destination: string) {
      if (url.endsWith("SHASUMS256.txt")) {
        checksumDownloads++;
        await writeFile(destination, `${digest} *electron-v42.4.1-darwin-arm64.zip\n`);
      } else {
        archiveDownloads++;
        await writeFile(destination, archive);
      }
    },
  };
  try {
    for (let round = 0; round < 2; round++) {
      const guest = await mkdtemp(join(tmpdir(), "comma-electron-guest-"));
      try {
        await downloadArtifact({
          version: "42.4.1",
          platform: "darwin",
          arch: "arm64",
          artifactName: "electron",
          cacheRoot:
            electronDownloadCache({ CI: "true", RUNNER_NAME: "tokyo 1" }, host) ??
            join(guest, "cache"),
          tempDirectory: guest,
          downloader,
        });
      } finally {
        await rm(guest, { recursive: true, force: true });
      }
    }
    expect(archiveDownloads).toBe(1);
    expect(checksumDownloads).toBe(2);
    expect(
      electronDownloadCache({ CI: "true", RUNNER_NAME: "tokyo 2" }, host)
    ).not.toBe(electronDownloadCache({ CI: "true", RUNNER_NAME: "tokyo 1" }, host));
  } finally {
    await rm(host, { recursive: true, force: true });
  }
});

it("keeps the default cache outside CI or without the host mount", () => {
  expect(electronDownloadCache({}, tmpdir())).toBeUndefined();
  expect(
    electronDownloadCache(
      { CI: "true", RUNNER_NAME: "tokyo 1" },
      join(tmpdir(), "comma-cache-mount-that-does-not-exist")
    )
  ).toBeUndefined();
});
