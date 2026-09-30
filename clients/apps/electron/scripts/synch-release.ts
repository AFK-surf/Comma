/**
 * The synchronicity release Comma ships. One node daemon per install, bundled
 * the way salix-connect is: a single static binary under
 * `dist/native/<platform>/<arch>/`, fetched from the GitHub release rather
 * than built, because the source tree is not expected to be present.
 *
 * The client and the daemon are the same binary, and the control protocol
 * only speaks to its own build (`x-synch-control-version`), so the version
 * is pinned here in one place and every archive is checked against the
 * SHA-256 the release publishes beside it.
 */
export const synchReleaseTag = "v0.1.13";

export const synchControlProtocol = {
  releaseTag: "v0.1.13",
  sha256: "d9c1acad7f1ad2ac15b857f7419c09def9c0bf9db19466d97387492eeabf0fce",
  wireVersion: "6",
} as const;

export const synchReleaseBaseUrl = `https://github.com/AFK-surf/synchronicity/releases/download/${synchReleaseTag}`;

type SynchArchive = {
  archive: string;
  sha256: string;
};

/** Keyed by `${platform}/${arch}` in Node's own vocabulary. */
export const synchReleaseArchives: Record<string, SynchArchive> = {
  "darwin/arm64": {
    archive: `synchronicity-${synchReleaseTag}-aarch64-apple-darwin.tar.gz`,
    sha256: "3339505b6245ed35937c582005993bf64a0cc4d4ba16dea353c5c3e689d41ad8",
  },
  "darwin/x64": {
    archive: `synchronicity-${synchReleaseTag}-x86_64-apple-darwin.tar.gz`,
    sha256: "3e9f51d9c51e9062209771cd9a611165158e90a499fd48a5d393173adb08ba97",
  },
  "linux/arm64": {
    archive: `synchronicity-${synchReleaseTag}-aarch64-unknown-linux-gnu.tar.gz`,
    sha256: "9f418698b943cfb8cdd9c3b64afa337002e1dad4385c1639a297ac277e522508",
  },
  "linux/x64": {
    archive: `synchronicity-${synchReleaseTag}-x86_64-unknown-linux-gnu.tar.gz`,
    sha256: "f958f4a0eb518f7f1159894d6a5c9abe99bce3cd4ed2fe67ee55fbb255d99cdf",
  },
  "win32/x64": {
    archive: `synchronicity-${synchReleaseTag}-x86_64-pc-windows-gnullvm.zip`,
    sha256: "6e4f63064b283db98232db31f2e90e93a91943836a6ba202cbd28d88f9fa6f06",
  },
};

export function synchReleaseArchive(platform: string, arch: string): SynchArchive {
  const archive = synchReleaseArchives[`${platform}/${arch}`];
  if (!archive) {
    throw new Error(
      `No synchronicity ${synchReleaseTag} release archive is published for ${platform}/${arch}.`
    );
  }
  return archive;
}
