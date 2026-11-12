/**
 * The Velopack feed a release publishes: the feed `vpk pack` wrote, merged with the feed clients read now.
 *
 * `vpk pack` writes `releases.<channel>.json` from the packages on disk, and the release job downloads only the
 * latest full package. So a packed feed has one delta: from the previous version to this one. Velopack 1.2.0's
 * client applies every delta newer than its installed version, one after the other, on top of its local full
 * package (`create_delta_update_strategy`, src/lib-rust/src/manager.rs). With only the newest delta listed, each
 * client more than one version behind applied a delta made from another version, failed the checksum, and
 * downloaded the full package (about 220 MB).
 *
 * The merge is Velopack's own `MergeAssets` (`_ObjectRepository.UploadMissingAssetsAsync`): the packed entries
 * first, then the remote entries whose FileName the packed feed does not have. Two limits are ours:
 * - Full packages come only from the packed feed. A client needs only the newest one; older ones would make the
 *   production sign-off hash 220 MB more for each listed version.
 * - The feed keeps the newest `deltaWindow` deltas. A client older than the oldest one downloads the full package.
 *   The older delta objects stay in R2.
 */

/**
 * 30 deltas: at about 5 MB each, a client 30 versions behind downloads about 150 MB, still less than one full
 * package. Staging publishes about 15 versions a day, so a staging client gets deltas for about two days; production
 * publishes far fewer. Production sign-off hashes every listed package, which the window also bounds.
 */
export const deltaWindow = 30;

function parseVersion(version) {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(
    version
  );
  if (!match) {
    return undefined;
  }
  return {
    core: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4]?.split(".") ?? [],
  };
}

function compareIdentifiers(left, right) {
  const leftNumeric = /^\d+$/.test(left);
  const rightNumeric = /^\d+$/.test(right);
  if (leftNumeric && rightNumeric) return Number(left) - Number(right);
  if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
  return left < right ? -1 : left > right ? 1 : 0;
}

/** SemVer 2 precedence, as Velopack orders versions. */
export function compareVersions(leftVersion, rightVersion) {
  const left = parseVersion(leftVersion);
  const right = parseVersion(rightVersion);
  if (!left || !right) {
    throw new Error(`Cannot compare release versions: ${leftVersion}, ${rightVersion}`);
  }
  for (let index = 0; index < 3; index += 1) {
    const difference = left.core[index] - right.core[index];
    if (difference !== 0) return difference;
  }
  if (left.prerelease.length === 0 || right.prerelease.length === 0) {
    return right.prerelease.length - left.prerelease.length;
  }
  const length = Math.min(left.prerelease.length, right.prerelease.length);
  for (let index = 0; index < length; index += 1) {
    const difference = compareIdentifiers(
      left.prerelease[index],
      right.prerelease[index]
    );
    if (difference !== 0) return difference;
  }
  return left.prerelease.length - right.prerelease.length;
}

function isDelta(asset) {
  return String(asset.Type).toLowerCase() === "delta";
}

function isFull(asset) {
  return String(asset.Type).toLowerCase() === "full";
}

/**
 * The packed feed's Assets with the remote feed's deltas added, within the window.
 * Both arguments are feed objects ({ Assets: [...] }) whose entries the caller has validated.
 * Returns the merged feed and the remote entries left out, with the reason for each.
 */
export function mergeReleaseFeed(localFeed, remoteFeed, { window = deltaWindow } = {}) {
  const localAssets = localFeed.Assets;
  const newestFull = localAssets
    .filter(isFull)
    .map((asset) => asset.Version)
    .toSorted(compareVersions)
    .at(-1);
  if (!newestFull) {
    throw new Error("The packed release feed has no Full package.");
  }
  const packageIds = new Set(localAssets.map((asset) => asset.PackageId));

  const fileNames = new Set(localAssets.map((asset) => asset.FileName));
  const added = [];
  const skipped = [];
  for (const asset of remoteFeed?.Assets ?? []) {
    if (fileNames.has(asset.FileName)) continue;
    if (!isDelta(asset)) {
      skipped.push({ fileName: asset.FileName, reason: "not a delta" });
    } else if (!packageIds.has(asset.PackageId)) {
      skipped.push({ fileName: asset.FileName, reason: `package ${asset.PackageId}` });
    } else if (!parseVersion(asset.Version)) {
      skipped.push({ fileName: asset.FileName, reason: `version ${asset.Version}` });
    } else if (compareVersions(asset.Version, newestFull) > 0) {
      // Newer than the release this feed publishes: not a step to it.
      skipped.push({ fileName: asset.FileName, reason: `newer than ${newestFull}` });
    } else {
      fileNames.add(asset.FileName);
      added.push(asset);
    }
  }

  const keptDeltas = new Set(
    [...localAssets.filter(isDelta), ...added]
      .toSorted((left, right) => compareVersions(right.Version, left.Version))
      .slice(0, window)
  );
  const assets = [...localAssets];
  for (const asset of added.toSorted((left, right) =>
    compareVersions(right.Version, left.Version)
  )) {
    if (keptDeltas.has(asset)) {
      assets.push(asset);
    } else {
      skipped.push({
        fileName: asset.FileName,
        reason: `older than the ${window} newest deltas`,
      });
    }
  }

  return {
    feed: { ...localFeed, Assets: assets },
    added: assets.length - localAssets.length,
    skipped,
  };
}
