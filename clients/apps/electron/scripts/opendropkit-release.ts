import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import pinnedRelease from "./opendropkit-release.json";

export interface OpenDropKitRelease {
  tag: string;
  archives: Record<string, { archive: string; sha256: string }>;
}

const openDropKitRepository = "AFK-surf/OpenDropKit";

/**
 * Downloads one asset of an OpenDropKit release. The repository is private, so
 * a token that can read its contents (CI's `OPENDROPKIT_RELEASE_TOKEN` secret,
 * or `gh auth token` locally) goes through the GitHub API. Without one, the
 * public download URL is the only route.
 */
export async function downloadOpenDropKitAsset(
  tag: string,
  name: string,
  {
    fetch: request = fetch,
    token,
  }: { fetch?: typeof fetch; token?: string | undefined } = {}
): Promise<Buffer> {
  const credential = token?.trim();
  if (!credential) {
    const url = `https://github.com/${openDropKitRepository}/releases/download/${tag}/${name}`;
    console.log(`Fetching ${url}`);
    const response = await request(url, { redirect: "follow" });
    if (!response.ok)
      throw new Error(
        `Fetching OpenDropKit failed: HTTP ${response.status}. The repository is private; set OPENDROPKIT_RELEASE_TOKEN to a token that can read its releases.`
      );
    return Buffer.from(await response.arrayBuffer());
  }
  const api = `https://api.github.com/repos/${openDropKitRepository}/releases`;
  // A token that cannot see the private repository gets 404, not 403.
  const refused = (status: number) =>
    status === 401 || status === 403 || status === 404
      ? ` Check that OPENDROPKIT_RELEASE_TOKEN is valid, is owned by AFK-surf, and can read ${openDropKitRepository} contents.`
      : "";
  const authorization = {
    Authorization: `Bearer ${credential}`,
    "X-GitHub-Api-Version": "2022-11-28",
  };
  console.log(`Fetching OpenDropKit ${tag} ${name} through the GitHub API`);
  const release = await request(`${api}/tags/${encodeURIComponent(tag)}`, {
    headers: { ...authorization, Accept: "application/vnd.github+json" },
  });
  if (!release.ok)
    throw new Error(
      `Fetching OpenDropKit release ${tag} failed: HTTP ${release.status}.${refused(release.status)}`
    );
  const { assets = [] } = (await release.json()) as {
    assets?: { id: number; name: string }[];
  };
  const asset = assets.find((candidate) => candidate.name === name);
  if (!asset) throw new Error(`OpenDropKit release ${tag} has no ${name}.`);
  // The API redirects to signed storage, which must not receive the token.
  const answer = await request(`${api}/assets/${asset.id}`, {
    headers: { ...authorization, Accept: "application/octet-stream" },
    redirect: "manual",
  });
  const location =
    answer.status >= 300 && answer.status < 400 && answer.headers.get("location");
  const response = location ? await request(location, { redirect: "follow" }) : answer;
  if (!response.ok)
    throw new Error(
      `Fetching OpenDropKit failed: HTTP ${response.status}.${refused(response.status)}`
    );
  return Buffer.from(await response.arrayBuffer());
}

// Comma's reviewed pin owns the expected download bytes. This build-time check
// rejects a changed archive or corrupt cache before extraction. It does not
// independently authenticate the release publisher.
export async function fetchOpenDropKit(options: {
  appDir: string;
  platform: string;
  arch: string;
  binaryOverride?: string | undefined;
  release?: OpenDropKitRelease;
  fetch?: typeof fetch;
  /** Reads the private release; see `downloadOpenDropKitAsset`. */
  token?: string | undefined;
}) {
  const { appDir, platform, arch } = options;
  if (platform !== "darwin") throw new Error("AirDrop requires macOS.");
  const output = join(appDir, "dist/native", platform, arch);
  mkdirSync(output, { recursive: true });
  const release: OpenDropKitRelease = options.release ?? pinnedRelease;
  const override = options.binaryOverride?.trim();

  // Comma ships only the anonymous helper. A copy signed with the release's
  // AirDrop identity entitlements is private-entitled, and macOS refuses to
  // launch such a binary unless the Mac relaxes signature enforcement.
  function install(binary: string, bundle: string) {
    const license = "OpenDropKit-LICENSE";
    copyFileSync(join(bundle, license), join(output, `${license}.tmp`));
    renameSync(join(output, `${license}.tmp`), join(output, license));
    const staged = join(output, "opendropkit.tmp");
    try {
      copyFileSync(binary, staged);
      chmodSync(staged, 0o755);
      execFileSync("codesign", ["--force", "--sign", "-", staged], {
        stdio: "inherit",
      });
      renameSync(staged, join(output, "opendropkit"));
    } finally {
      rmSync(staged, { force: true });
    }
  }

  if (override) {
    install(override, dirname(override));
    console.log(`OpenDropKit copied from COMMA_OPENDROPKIT_BINARY (${override}).`);
    return;
  }
  const selected = release.archives[`${platform}/${arch}`];
  if (!selected) throw new Error(`No OpenDropKit release for ${platform}/${arch}.`);
  const { archive, sha256 } = selected;
  const cache = join(appDir, ".native-cache/opendropkit");
  mkdirSync(cache, { recursive: true });
  const cached = join(cache, archive);
  const digest = () => createHash("sha256").update(readFileSync(cached)).digest("hex");
  if (!existsSync(cached) || digest() !== sha256) {
    writeFileSync(
      cached,
      await downloadOpenDropKitAsset(release.tag, archive, {
        ...(options.fetch ? { fetch: options.fetch } : {}),
        token: options.token,
      })
    );
  }
  if (digest() !== sha256) {
    rmSync(cached, { force: true });
    throw new Error(`${archive} does not match Comma's pinned SHA-256.`);
  }
  const extracted = mkdtempSync(join(tmpdir(), "comma-opendropkit-"));
  try {
    execFileSync("tar", ["-xzf", cached, "-C", extracted]);
    const bundle = join(extracted, archive.replace(/\.tar\.gz$/u, ""));
    install(join(bundle, "opendropkit"), bundle);
  } finally {
    rmSync(extracted, { force: true, recursive: true });
  }
  console.log(`OpenDropKit ${release.tag} ready for ${platform}/${arch}.`);
}
