import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  downloadOpenDropKitAsset,
  fetchOpenDropKit,
  type OpenDropKitRelease,
} from "../scripts/opendropkit-release";
import pin from "../scripts/opendropkit-release.json";

const archivePath = process.env.COMMA_OPENDROPKIT_TEST_ARCHIVE;
const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe("OpenDropKit release asset download", () => {
  const api = "https://api.github.com/repos/AFK-surf/OpenDropKit/releases";

  it("reads the private release through the API and keeps the token from storage", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(
        Response.json({
          assets: [
            { id: 7, name: "SHA256SUMS" },
            { id: 8, name: "opendropkit.tar.gz" },
          ],
        })
      )
      .mockResolvedValueOnce(
        new Response(null, {
          status: 302,
          headers: { location: "https://release-assets.example/signed" },
        })
      )
      .mockResolvedValueOnce(new Response("archive bytes"));

    const bytes = await downloadOpenDropKitAsset("v0.1.2", "opendropkit.tar.gz", {
      fetch,
      token: " release-token ",
    });

    expect(bytes.toString("utf8")).toBe("archive bytes");
    expect(fetch.mock.calls[0]?.[0]).toBe(`${api}/tags/v0.1.2`);
    expect(fetch.mock.calls[0]?.[1]?.headers).toMatchObject({
      Authorization: "Bearer release-token",
    });
    expect(fetch.mock.calls[1]?.[0]).toBe(`${api}/assets/8`);
    expect(fetch.mock.calls[1]?.[1]).toMatchObject({
      headers: {
        Accept: "application/octet-stream",
        Authorization: "Bearer release-token",
      },
      redirect: "manual",
    });
    // Signed storage gets only its own URL.
    expect(fetch.mock.calls[2]).toEqual([
      "https://release-assets.example/signed",
      { redirect: "follow" },
    ]);
  });

  it("names the token when the public route is refused and reports a missing asset", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(new Response("Not Found", { status: 404 }));
    await expect(
      downloadOpenDropKitAsset("v0.1.2", "SHA256SUMS", { fetch })
    ).rejects.toThrow("OPENDROPKIT_RELEASE_TOKEN");
    expect(fetch).toHaveBeenCalledWith(
      "https://github.com/AFK-surf/OpenDropKit/releases/download/v0.1.2/SHA256SUMS",
      { redirect: "follow" }
    );

    // A token that cannot see the private repository also gets 404.
    fetch.mockResolvedValueOnce(
      Response.json({ message: "Not Found" }, { status: 404 })
    );
    await expect(
      downloadOpenDropKitAsset("v0.1.2", "SHA256SUMS", {
        fetch,
        token: "release-token",
      })
    ).rejects.toThrow("Check that OPENDROPKIT_RELEASE_TOKEN is valid");

    fetch.mockResolvedValueOnce(Response.json({ assets: [] }));
    await expect(
      downloadOpenDropKitAsset("v0.1.2", "SHA256SUMS", {
        fetch,
        token: "release-token",
      })
    ).rejects.toThrow("has no SHA256SUMS");
  });
});

describe.skipIf(!archivePath || process.platform !== "darwin")(
  "OpenDropKit release download",
  () => {
    function fixture() {
      const appDir = mkdtempSync(join(tmpdir(), "comma-airdrop-download-"));
      roots.push(appDir);
      const release: OpenDropKitRelease = pin;
      const selected = release.archives[`darwin/${process.arch}`]!;
      const fetch = vi.fn<typeof globalThis.fetch>();
      return {
        options: { appDir, platform: "darwin", arch: process.arch, release, fetch },
        archive: readFileSync(archivePath!),
        fetch,
        cached: join(appDir, ".native-cache/opendropkit", selected.archive),
        helper: join(appDir, "dist/native/darwin", process.arch, "opendropkit"),
        native: join(appDir, "dist/native/darwin", process.arch, "opendropkit-native"),
      };
    }

    it("downloads the pinned archive, installs one runnable helper, and reuses the cache offline", async () => {
      const f = fixture();
      f.fetch.mockResolvedValueOnce(new Response(new Uint8Array(f.archive)));
      await fetchOpenDropKit(f.options);
      execFileSync("codesign", ["--verify", "--strict", f.helper]);
      expect(execFileSync(f.helper, ["--help"], { encoding: "utf8" })).toContain(
        "AirDrop"
      );
      // A copy signed with the AirDrop identity entitlements cannot launch on a
      // Mac that enforces signatures, so Comma never installs one.
      expect(existsSync(f.native)).toBe(false);
      f.fetch.mockRejectedValue(new Error("offline"));
      await fetchOpenDropKit(f.options);
      expect(f.fetch).toHaveBeenCalledTimes(1);
      // The development override uses the same release bundle layout.
      await fetchOpenDropKit({ ...f.options, binaryOverride: f.helper });
      expect(f.fetch).toHaveBeenCalledTimes(1);
    });

    it("replaces a corrupt cache and rejects altered downloads before installing a helper", async () => {
      const f = fixture();
      f.fetch.mockResolvedValueOnce(new Response(new Uint8Array(f.archive)));
      await fetchOpenDropKit(f.options);
      writeFileSync(f.cached, "corrupt cache");
      f.fetch.mockResolvedValueOnce(new Response(new Uint8Array(f.archive)));
      await fetchOpenDropKit(f.options);
      expect(f.fetch).toHaveBeenCalledTimes(2);

      const invalid = fixture();
      invalid.fetch.mockResolvedValueOnce(new Response("altered archive"));
      await expect(fetchOpenDropKit(invalid.options)).rejects.toThrow("pinned SHA-256");
      expect(existsSync(invalid.cached)).toBe(false);
      expect(existsSync(invalid.helper)).toBe(false);
    });

    it("fails a build when the selected release is unavailable", async () => {
      const f = fixture();
      f.fetch.mockResolvedValueOnce(new Response("missing", { status: 404 }));
      await expect(fetchOpenDropKit(f.options)).rejects.toThrow("HTTP 404");
      expect(existsSync(f.helper)).toBe(false);
    });
  }
);
