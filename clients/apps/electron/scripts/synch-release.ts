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
export const synchReleaseTag = "v0.1.20";

export const synchControlProtocol = {
  releaseTag: "v0.1.20",
  sha256: "e8a39686952d183f923ee4e1a8d135eddf5af15e33054f30ca70ca3edc668e2c",
  wireVersion: "8",
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
    sha256: "8b21a64633e9c445e65eb17bfef55b748c271527a400a6fae76dde56345440d7",
  },
  "linux/arm64": {
    archive: `synchronicity-${synchReleaseTag}-aarch64-unknown-linux-gnu.tar.gz`,
    sha256: "30909310ca5678cba32ead76ba3178684f7d2ae49ad06b7d64305178f06c7400",
  },
  "linux/x64": {
    archive: `synchronicity-${synchReleaseTag}-x86_64-unknown-linux-gnu.tar.gz`,
    sha256: "de8e3c12ce36e21431f02f98023049a1ad5e2a84dbdc9d480a6c3014df25fdc7",
  },
  "win32/x64": {
    archive: `synchronicity-${synchReleaseTag}-x86_64-pc-windows-gnullvm.zip`,
    sha256: "c746ece20f19a40677ac9cf286f97f2e1d55aaa1b870988973c41253786dc200",
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
