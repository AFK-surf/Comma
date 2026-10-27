import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * Cua Driver (github.com/trycua/cua, MIT): Computer Use on Windows. The
 * station reaches it over MCP (systems/station/src/connector/computer-use-windows.ts).
 * It is fetched, not built, and every archive is checked against the SHA-256
 * its release publishes in checksums.txt before anything in it is used.
 */
export const cuaDriverVersion = "0.37.0";

export const cuaDriverReleaseBaseUrl = `https://github.com/trycua/cua/releases/download/cua-driver-rs-v${cuaDriverVersion}`;

/** Keyed by `${platform}/${arch}` in Node's own vocabulary: the release's binary-only archives. */
export const cuaDriverArchives: Record<string, { archive: string; sha256: string }> = {
  "win32/x64": {
    archive: `cua-driver-rs-${cuaDriverVersion}-windows-x86_64-binary.zip`,
    sha256: "40481b55073f1225b0010235b30217bd640ef1f323e982aec0a5f6131d3e4a99",
  },
  "win32/arm64": {
    archive: `cua-driver-rs-${cuaDriverVersion}-windows-arm64-binary.zip`,
    sha256: "0fce682b251775e25fd76bf29ff856f7f5ab5aae5759d6b76a40f8312a194a5a",
  },
};

/**
 * The agent cursor in the brand blue (brand-500, #1040F2), as a theme the
 * driver loads (native/windows/cua-driver). It is Cua's default cursor built
 * by its build_default_theme.py with that fill and the id `comma.brand`, then
 * compiled by this version's `cua-cursor-theme.exe build`.
 */
export const cuaCursorTheme = "comma.brand.cua-theme";

/** The driver and the helpers it starts beside itself (UI Automation worker, cursor theme). */
export const cuaDriverExecutables = [
  "cua-driver.exe",
  "cua-driver-uia.exe",
  "cua-cursor-theme.exe",
];

const sha256Of = (path: string) =>
  createHash("sha256").update(readFileSync(path)).digest("hex");

/**
 * Puts the pinned driver's executables in `outputDir`, from a cached archive
 * when it matches its pin.
 */
export async function fetchCuaDriver({
  platform,
  arch,
  outputDir,
  cacheDir,
}: {
  platform: string;
  arch: string;
  outputDir: string;
  cacheDir: string;
}) {
  const pinned = cuaDriverArchives[`${platform}/${arch}`];
  if (!pinned)
    throw new Error(
      `No Cua Driver ${cuaDriverVersion} archive is published for ${platform}/${arch}.`
    );
  mkdirSync(cacheDir, { recursive: true });
  const cached = join(cacheDir, pinned.archive);
  if (!existsSync(cached) || sha256Of(cached) !== pinned.sha256) {
    const url = `${cuaDriverReleaseBaseUrl}/${pinned.archive}`;
    console.log(`Fetching ${url}`);
    const response = await fetch(url, { redirect: "follow" });
    if (!response.ok)
      throw new Error(`Fetching ${url} failed: HTTP ${response.status}`);
    // Another build may read the same cache: the archive appears whole or not at all.
    const staged = `${cached}.${process.pid}.tmp`;
    writeFileSync(staged, Buffer.from(await response.arrayBuffer()));
    renameSync(staged, cached);
  }
  const actual = sha256Of(cached);
  if (actual !== pinned.sha256) {
    rmSync(cached, { force: true });
    throw new Error(
      `${pinned.archive} does not match its pinned SHA-256 (expected ${pinned.sha256}, got ${actual}).`
    );
  }

  const extractDir = mkdtempSync(join(tmpdir(), "comma-cua-driver-"));
  try {
    // System32's bsdtar reads the .zip; a Git Bash's GNU tar first on PATH would read `C:` as a host.
    const tar =
      process.platform === "win32"
        ? join(process.env.SystemRoot ?? "C:\\Windows", "System32", "tar.exe")
        : "tar";
    const extracted = spawnSync(tar, ["-xf", cached, "-C", extractDir], {
      stdio: "inherit",
    });
    if (extracted.status !== 0) throw new Error(`Extracting ${pinned.archive} failed`);
    const files = new Set(readdirSync(extractDir));
    mkdirSync(outputDir, { recursive: true });
    for (const name of cuaDriverExecutables) {
      if (!files.has(name))
        throw new Error(`${pinned.archive} does not contain ${name}.`);
      const staged = join(outputDir, `${name}.tmp`);
      copyFileSync(join(extractDir, name), staged);
      renameSync(staged, join(outputDir, name));
    }
  } finally {
    rmSync(extractDir, { force: true, recursive: true });
  }
  console.log(`Cua Driver ${cuaDriverVersion} ready for ${platform}/${arch}.`);
}
