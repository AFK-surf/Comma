import {
  appPreferencesSchema,
  commaClientSettingsSchema,
  defaultAppPreferences,
  defaultCommaClientSettings,
  withoutRetiredAppPreferences,
} from "@comma/native-bridge";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Records first-launch onboarding as finished for `userIds` in the Electron
 * profile at `userDataDir`, as the app does when they finish or close it.
 * A signed-in account meets the onboarding until its profile holds this
 * record, and every spec launches from a fresh `--user-data-dir`, so a spec
 * that signs in records it before launch to land on the shell. Onboarding
 * specs leave it out.
 *
 * It writes Main's own preferences file and keeps what the profile already
 * holds. Synchronous, so a launch-environment helper can call it.
 */
export function recordElectronOnboardingCompleted(
  userDataDir: string,
  userIds: readonly string[]
) {
  updateElectronPreferences(userDataDir, (stored) => {
    const clientSettings = commaClientSettingsSchema.parse(
      stored.clientSettings ?? defaultCommaClientSettings
    );
    return {
      ...stored,
      clientSettings: {
        ...clientSettings,
        onboardingCompletedUserIds: [
          ...new Set([...clientSettings.onboardingCompletedUserIds, ...userIds]),
        ],
      },
    };
  });
}

function updateElectronPreferences(
  userDataDir: string,
  change: (stored: StoredPreferences) => StoredPreferences
) {
  const filePath = join(userDataDir, "app-preferences.json");
  // Main's own bookkeeping beside the preferences, kept as it is.
  const { defaultsRevision, ...stored } = readStoredPreferences(filePath);
  const preferences = change(stored);
  // Main reads a file it cannot parse as all defaults, which would drop the
  // record without a trace. Refuse to write one.
  appPreferencesSchema.parse(preferences);
  mkdirSync(userDataDir, { recursive: true });
  writeFileSync(
    filePath,
    `${JSON.stringify(
      defaultsRevision === undefined
        ? preferences
        : { ...preferences, defaultsRevision },
      null,
      2
    )}\n`
  );
}

type StoredPreferences = Record<string, unknown> & { clientSettings?: unknown };

/** The file as Main keeps it: stored choices only, no revision or readbacks. */
function readStoredPreferences(filePath: string): StoredPreferences {
  try {
    return withoutRetiredAppPreferences(JSON.parse(readFileSync(filePath, "utf8")));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    const { revision: _revision, ...stored } = defaultAppPreferences;
    return stored;
  }
}
