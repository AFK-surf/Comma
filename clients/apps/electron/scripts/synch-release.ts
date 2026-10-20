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
export const synchReleaseTag = "v0.1.16";

export const synchControlProtocol = {
  releaseTag: "v0.1.16",
  sha256: "40fae0e07894cfbf5fbc18207a7ff2fe9990e041cad9ffe16f1637eb72fb6dce",
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
    sha256: "2ce3abf366e4e715e1a8bad04cdc0a4ab6eae61ed9bb58401bc43c2e1abad7d0",
  },
  "linux/arm64": {
    archive: `synchronicity-${synchReleaseTag}-aarch64-unknown-linux-gnu.tar.gz`,
    sha256: "aa100d0283e0aa8744d83de73e8585bc254fe192ef3ddda8e49ce85d12dac060",
  },
  "linux/x64": {
    archive: `synchronicity-${synchReleaseTag}-x86_64-unknown-linux-gnu.tar.gz`,
    sha256: "e384aa48f143e2a2f8a3d6d149db8dbfa2e6430f5c6723b765a5a3969c771e2a",
  },
  "win32/x64": {
    archive: `synchronicity-${synchReleaseTag}-x86_64-pc-windows-gnullvm.zip`,
    sha256: "36b0c5716306343401dedc8d522f030e6d27d1c515af97277c02f032b544582d",
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
