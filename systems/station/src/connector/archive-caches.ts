// Generated caches under an archived home: rebuilt on demand, so archives skip them and the operator cleanup removes
// them. Paths are relative to the home directory.
export const ARCHIVE_HOME_CACHE_DIRS = new Set([
  // Codex rebuilds temporary launch links, which can point outside the workspace.
  ".codex/tmp",
  ".cache", ".ccache", ".npm/_cacache",
  ".cargo/registry/cache", ".cargo/registry/src", ".cargo/git/checkouts",
  ".gradle/caches", ".gradle/daemon", ".gradle/wrapper/dists",
  ".android/cache", ".android/build-cache",
  ".m2/repository", ".ivy2/cache", ".sbt/boot",
  ".hex/packages", ".rebar3/cache",
  ".yarn/cache", ".yarn/berry/cache", ".pnpm-store",
  ".local/share/pnpm/store", "go/pkg/mod", ".nuget/packages",
  ".pub-cache", "Library/Caches",
  "Library/Developer/Xcode/DerivedData",
]);

/** A generated file (not directory) under the home. */
export const ARCHIVE_HOME_CACHE_FILES = new Set([".hex/cache.ets"]);
