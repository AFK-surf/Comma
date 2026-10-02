import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import {
  appPreferencesSchema,
  commaClientSettingsSchema,
  defaultAppPreferences,
  defaultCommaClientSettings,
  defaultOpenCommaShortcut,
  type AppPreferences,
  type AppPreferencesPatch,
  type CommaClientSettings,
  type KeepAwakeWhenLidClosedStatus,
  type SystemNotificationsStatus,
  type SideChatShortcutBinding,
} from "@comma/native-bridge";
import type { LaunchAtLoginReadback } from "./launch-at-login";

export interface AppPreferencesPlatform {
  setOpenCommaShortcut?(shortcut: SideChatShortcutBinding): void;
  /** macOS: whether the sleep guard daemon may run, as Login Items shows it. */
  getKeepAwakeWhenLidClosedStatus?(): KeepAwakeWhenLidClosedStatus;
  /**
   * Holds or releases the Mac's lid-closed wakefulness and resolves the
   * daemon's status. Turning on holds only an approved daemon; otherwise it
   * resolves the status that still needs the user.
   */
  setKeepAwakeWhenLidClosed?(
    enabled: boolean,
    options?: { atLaunch?: boolean }
  ): Promise<KeepAwakeWhenLidClosedStatus | void> | KeepAwakeWhenLidClosedStatus | void;
  /** macOS: opens Login Items, where the user allows the sleep guard daemon. */
  openLoginItemsSettings?(): { opened: boolean };
  /**
   * Asks the OS to let Comma notify and resolves once it has answered. macOS
   * prompts only while it has not asked the user about Comma yet.
   */
  authorizeSystemNotifications(): Promise<boolean> | boolean;
  getLaunchAtLogin(): LaunchAtLoginReadback;
  getSystemNotificationsStatus():
    | Promise<SystemNotificationsStatus>
    | SystemNotificationsStatus;
  setLaunchAtLogin(
    enabled: boolean
  ): Promise<LaunchAtLoginReadback> | LaunchAtLoginReadback;
  setShowInDock(enabled: boolean): Promise<void> | void;
  setShowInMenuBar(enabled: boolean): Promise<void> | void;
}

export class AppPreferencesService {
  readonly #filePath: string;
  readonly #onStateChanged: (preferences: AppPreferences) => void;
  readonly #platform: AppPreferencesPlatform;
  #closed = false;
  #mutationInFlight = false;
  #preferences: AppPreferences;
  #updateTail: Promise<void> = Promise.resolve();

  private constructor({
    filePath,
    onStateChanged,
    platform,
    preferences,
  }: {
    filePath: string;
    onStateChanged: (preferences: AppPreferences) => void;
    platform: AppPreferencesPlatform;
    preferences: AppPreferences;
  }) {
    this.#filePath = filePath;
    this.#onStateChanged = onStateChanged;
    this.#platform = platform;
    this.#preferences = preferences;
  }

  static async open({
    filePath,
    onStateChanged = () => undefined,
    platform,
  }: {
    filePath: string;
    onStateChanged?: (preferences: AppPreferences) => void;
    platform: AppPreferencesPlatform;
  }) {
    const { defaultsRevision, preferences: stored } =
      await readStoredPreferences(filePath);
    const persisted =
      defaultsRevision < currentDefaultsRevision ? withCurrentDefaults(stored) : stored;
    if (defaultsRevision < currentDefaultsRevision) {
      // Saved now, so a shortcut the user sets later is never moved again. A
      // failed write moves it again on the next launch, to the same value.
      await writePreferences(filePath, persisted).catch(() => undefined);
    }
    const preferences = withKeepAwakeWhenLidClosedStatusReadback(
      withSystemNotificationsStatusReadback(
        withLaunchAtLoginReadback(persisted, platform.getLaunchAtLogin()),
        await platform.getSystemNotificationsStatus()
      ),
      platform.getKeepAwakeWhenLidClosedStatus?.()
    );
    const service = new AppPreferencesService({
      filePath,
      onStateChanged,
      platform,
      preferences,
    });

    await Promise.all([
      platform.setShowInDock(preferences.showInDock),
      platform.setShowInMenuBar(preferences.showInMenuBar),
    ]);
    if (preferences.keepAwakeWhenLidClosed && platform.setKeepAwakeWhenLidClosed) {
      try {
        // A revoked approval keeps the choice: the status readback shows
        // the approval it waits for, and a later approval resumes it.
        service.#preferences = withKeepAwakeWhenLidClosedStatusReadback(
          service.#preferences,
          (await platform.setKeepAwakeWhenLidClosed(true, { atLaunch: true })) ??
            undefined
        );
      } catch {
        // A daemon that refuses must not prevent Comma from starting; the
        // setting shows off until the user turns it on again.
        service.#preferences.keepAwakeWhenLidClosed = false;
      }
    }
    if (platform.setOpenCommaShortcut) {
      try {
        const shortcut = (preferences.clientSettings ?? defaultCommaClientSettings)
          .openCommaShortcut;
        platform.setOpenCommaShortcut(shortcut);
        service.#preferences.openCommaShortcutStatus =
          shortcut === null ? "unset" : "registered";
      } catch {
        // An OS shortcut conflict must not prevent Comma from starting.
        service.#preferences.openCommaShortcutStatus = "unavailable";
      }
    }
    return service;
  }

  state() {
    if (!this.#mutationInFlight && this.#refreshLaunchAtLogin()) {
      this.#onStateChanged(clonePreferences(this.#preferences));
    }
    return clonePreferences(this.#preferences);
  }

  async close() {
    this.#closed = true;
    await this.#updateTail;
  }

  async update(patch: AppPreferencesPatch) {
    const queuedPatch = structuredClone(patch);
    return this.#enqueue(() => this.#update(queuedPatch));
  }

  /**
   * Reads whether the operating system lets Comma post notifications and
   * publishes the answer. Like the login item this is externally owned truth
   * read back on demand, never persisted, and it only advances the revision
   * when it actually moves.
   */
  async refreshSystemNotificationsStatus() {
    return this.#enqueue(async () =>
      this.#applySystemNotificationsStatus(
        await this.#platform.getSystemNotificationsStatus()
      )
    );
  }

  /**
   * Reads whether macOS lets the sleep guard daemon run and publishes the
   * answer. The user allows the daemon in Login Items, outside Comma, so this
   * is where a choice that waited for approval takes effect, and where a
   * revoked approval releases the hold. Like the other readbacks the status
   * is never persisted.
   */
  async refreshKeepAwakeWhenLidClosedStatus() {
    const platform = this.#platform;
    if (!platform.getKeepAwakeWhenLidClosedStatus) return this.state();
    return this.#enqueue(async () => {
      const previous = this.#preferences;
      const status = platform.getKeepAwakeWhenLidClosedStatus!();
      let next = withKeepAwakeWhenLidClosedStatusReadback(previous, status);
      const wasAvailable = previous.keepAwakeWhenLidClosedStatus === "available";
      if (previous.keepAwakeWhenLidClosed && platform.setKeepAwakeWhenLidClosed) {
        if (status === "available" && !wasAvailable) {
          try {
            await platform.setKeepAwakeWhenLidClosed(true, { atLaunch: true });
          } catch {
            // Shows off, as after a refused start; the user can turn it on again.
            next = { ...next, keepAwakeWhenLidClosed: false };
          }
        } else if (status !== "available" && wasAvailable) {
          // launchd stopped the daemon, which restored sleep. Drop the hold
          // so that a later reconnect cannot take it back without approval.
          try {
            await platform.setKeepAwakeWhenLidClosed(false);
          } catch {
            // Nothing is held: the daemon is gone.
          }
        }
      }
      if (samePreferenceValues(next, previous)) return this.state();
      this.#preferences = withNextRevision(next, previous);
      const snapshot = this.state();
      this.#onStateChanged(snapshot);
      return snapshot;
    });
  }

  /**
   * Asks the OS to let Comma notify, then reads the answer back and publishes
   * it like any other readback change. A prompt waits on the user, so the
   * question stays outside the mutation queue; only the re-read joins it.
   */
  async requestSystemNotificationsAuthorization() {
    await this.#platform.authorizeSystemNotifications();
    return this.#enqueue(async () => {
      const status = await this.#platform.getSystemNotificationsStatus();
      this.#applySystemNotificationsStatus(status);
      return status;
    });
  }

  async initializeClientSettings(settings: CommaClientSettings) {
    const initialSettings = commaClientSettingsSchema.parse(settings);
    return this.#enqueue(async () =>
      this.#preferences.clientSettings
        ? this.state()
        : await this.#update({ clientSettings: initialSettings })
    );
  }

  #enqueue<Result>(task: () => Promise<Result>): Promise<Result> {
    if (this.#closed) {
      return Promise.reject(new Error("Application preferences are closing."));
    }
    const queued = this.#updateTail.then(async () => {
      this.#mutationInFlight = true;
      try {
        if (this.#refreshLaunchAtLogin()) {
          this.#onStateChanged(clonePreferences(this.#preferences));
        }
        return await task();
      } finally {
        this.#mutationInFlight = false;
      }
    });
    this.#updateTail = queued.then(
      () => undefined,
      () => undefined
    );
    return queued;
  }

  #applySystemNotificationsStatus(status: SystemNotificationsStatus) {
    const refreshed = withSystemNotificationsStatusReadback(this.#preferences, status);
    if (samePreferenceValues(refreshed, this.#preferences)) return this.state();
    this.#preferences = withNextRevision(refreshed, this.#preferences);
    const snapshot = this.state();
    this.#onStateChanged(snapshot);
    return snapshot;
  }

  #refreshLaunchAtLogin() {
    const readback = this.#platform.getLaunchAtLogin();
    const refreshed = withLaunchAtLoginReadback(this.#preferences, readback);
    if (samePreferenceValues(refreshed, this.#preferences)) return false;
    this.#preferences = withNextRevision(refreshed, this.#preferences);
    return true;
  }

  async #update(patch: AppPreferencesPatch) {
    const previous = this.#preferences;
    const {
      clientSettings: clientSettingsPatch,
      launchAtLogin: requestedLaunchAtLogin,
      ...shellPatch
    } = patch;
    let next = appPreferencesSchema.parse({
      ...previous,
      ...shellPatch,
      ...(clientSettingsPatch
        ? {
            clientSettings: mergeClientSettings(
              previous.clientSettings,
              clientSettingsPatch
            ),
          }
        : {}),
    });
    const shouldApplyLaunchAtLogin =
      requestedLaunchAtLogin !== undefined &&
      requestedLaunchAtLogin !== launchAtLoginIntent(previous);
    // Turning keep-awake on again while it waits for approval asks the
    // daemon again: that registers one that is not registered yet.
    const shouldApplyKeepAwake =
      patch.keepAwakeWhenLidClosed !== undefined &&
      (patch.keepAwakeWhenLidClosed !== previous.keepAwakeWhenLidClosed ||
        (patch.keepAwakeWhenLidClosed && keepAwakeWhenLidClosedWaiting(previous)));
    if (
      samePreferenceValues(previous, next) &&
      !shouldApplyLaunchAtLogin &&
      !shouldApplyKeepAwake &&
      !(
        clientSettingsPatch?.openCommaShortcut !== undefined &&
        previous.openCommaShortcutStatus === "unavailable"
      )
    ) {
      return this.state();
    }

    const applied: Array<() => Promise<void>> = [];
    try {
      if (
        clientSettingsPatch?.openCommaShortcut !== undefined &&
        this.#platform.setOpenCommaShortcut
      ) {
        const oldShortcut = (previous.clientSettings ?? defaultCommaClientSettings)
          .openCommaShortcut;
        const newShortcut = (next.clientSettings ?? defaultCommaClientSettings)
          .openCommaShortcut;
        this.#platform.setOpenCommaShortcut(newShortcut);
        applied.push(async () =>
          this.#platform.setOpenCommaShortcut!(
            previous.openCommaShortcutStatus === "registered" ? oldShortcut : null
          )
        );
        next.openCommaShortcutStatus = newShortcut === null ? "unset" : "registered";
      }
      if (shouldApplyLaunchAtLogin) {
        const requested = requestedLaunchAtLogin;
        const readback = await this.#platform.setLaunchAtLogin(requested);
        next = withLaunchAtLoginReadback(next, readback);
        if (!sameLaunchAtLoginState(previous, readback)) {
          applied.push(async () => {
            const restored = await this.#platform.setLaunchAtLogin(
              launchAtLoginIntent(previous)
            );
            if (!restoredLaunchAtLogin(previous, restored)) {
              throw new Error(
                "Launch-at-login state could not be restored during native rollback."
              );
            }
          });
        }
      }
      if (next.showInMenuBar !== previous.showInMenuBar) {
        await this.#platform.setShowInMenuBar(next.showInMenuBar);
        applied.push(async () =>
          this.#platform.setShowInMenuBar(previous.showInMenuBar)
        );
      }
      if (next.showInDock !== previous.showInDock) {
        await this.#platform.setShowInDock(next.showInDock);
        applied.push(async () => this.#platform.setShowInDock(previous.showInDock));
      }
      if (shouldApplyKeepAwake && this.#platform.setKeepAwakeWhenLidClosed) {
        next = withKeepAwakeWhenLidClosedStatusReadback(
          next,
          (await this.#platform.setKeepAwakeWhenLidClosed(
            next.keepAwakeWhenLidClosed
          )) ?? undefined
        );
        if (next.keepAwakeWhenLidClosed !== previous.keepAwakeWhenLidClosed) {
          applied.push(async () => {
            await this.#platform.setKeepAwakeWhenLidClosed!(
              previous.keepAwakeWhenLidClosed,
              { atLaunch: true }
            );
          });
        }
      }
      if (samePreferenceValues(previous, next)) return this.state();
      next = withNextRevision(next, previous);
      await writePreferences(this.#filePath, next);
    } catch (error) {
      const rollbackErrors = await rollbackApplied(applied);
      if (this.#refreshLaunchAtLogin()) {
        this.#onStateChanged({ ...this.#preferences });
      }
      if (rollbackErrors.length > 0) {
        const rollbackFailure = new Error(
          `App preference update failed (${errorMessage(error)}) and native rollback did not fully restore the previous state.`,
          { cause: error }
        );
        Object.defineProperty(rollbackFailure, "rollbackErrors", {
          value: rollbackErrors,
        });
        throw rollbackFailure;
      }
      throw error;
    }

    this.#preferences = next;
    const snapshot = this.state();
    this.#onStateChanged(snapshot);
    return snapshot;
  }
}

async function rollbackApplied(applied: Array<() => Promise<void>>) {
  const errors: unknown[] = [];
  for (let index = applied.length - 1; index >= 0; index -= 1) {
    try {
      await applied[index]!();
    } catch (error) {
      errors.push(error);
    }
  }
  return errors;
}

/** The stored app language, read before Main builds its first surfaces. */
export async function readStoredLocalePreference(filePath: string) {
  return (await readPreferences(filePath)).clientSettings?.localePreference;
}

/**
 * The shipped defaults the preferences file has been carried onto, kept in the
 * file beside the preferences and never published. Main moves an older file
 * forward once as it opens it; a new install starts at the current one.
 * - 1: Open Comma moved from Option-Space to Option-Comma.
 */
const currentDefaultsRevision = 1;

/** Open Comma's default before revision 1. */
const optionSpace = {
  key: "space",
  modifiers: { alt: true, control: false, meta: false, shift: false },
} as const;

/**
 * Carries preferences onto the shipped defaults their file predates (see
 * `currentDefaultsRevision`). The first launch saved every client setting,
 * defaults included, so a setting still equal to an old default is one the
 * user never chose: it takes the new default. Anything the user set stays,
 * and so does whatever they set once this has run.
 */
function withCurrentDefaults(preferences: AppPreferences): AppPreferences {
  const settings = preferences.clientSettings;
  const openComma = settings?.openCommaShortcut;
  const untouched =
    openComma?.key === optionSpace.key &&
    (
      Object.keys(optionSpace.modifiers) as (keyof typeof optionSpace.modifiers)[]
    ).every(
      (modifier) => openComma.modifiers[modifier] === optionSpace.modifiers[modifier]
    );
  return settings && untouched
    ? {
        ...preferences,
        clientSettings: { ...settings, openCommaShortcut: defaultOpenCommaShortcut },
      }
    : preferences;
}

async function readPreferences(filePath: string): Promise<AppPreferences> {
  return (await readStoredPreferences(filePath)).preferences;
}

/** The file's preferences, and the defaults revision it was written at. */
async function readStoredPreferences(filePath: string) {
  let stored: unknown;
  try {
    stored = JSON.parse(await readFile(filePath, "utf8"));
  } catch {
    // No file yet: a new install, on the current defaults.
    return {
      defaultsRevision: currentDefaultsRevision,
      preferences: { ...defaultAppPreferences },
    };
  }
  const { defaultsRevision, ...rest } =
    typeof stored === "object" && stored !== null
      ? (stored as { defaultsRevision?: unknown })
      : {};
  try {
    return {
      defaultsRevision: typeof defaultsRevision === "number" ? defaultsRevision : 0,
      preferences: appPreferencesSchema.parse(rest),
    };
  } catch {
    return {
      defaultsRevision: currentDefaultsRevision,
      preferences: { ...defaultAppPreferences },
    };
  }
}

async function writePreferences(filePath: string, preferences: AppPreferences) {
  await mkdir(dirname(filePath), { recursive: true });
  const temporaryPath = `${filePath}.tmp`;
  const persisted = {
    ...(preferences.clientSettings
      ? { clientSettings: preferences.clientSettings }
      : {}),
    airDropName: preferences.airDropName,
    defaultsRevision: currentDefaultsRevision,
    keepAwakeWhenLidClosed: preferences.keepAwakeWhenLidClosed,
    launchAtLogin: preferences.launchAtLogin,
    notchSideWidth: preferences.notchSideWidth,
    notificationSound: preferences.notificationSound,
    notifyRouterMessages: preferences.notifyRouterMessages,
    showInAirDrop: preferences.showInAirDrop,
    showInDock: preferences.showInDock,
    showInMenuBar: preferences.showInMenuBar,
    showInNotch: preferences.showInNotch,
    sideChatEnabled: preferences.sideChatEnabled,
    systemNotifications: preferences.systemNotifications,
  };
  await writeFile(temporaryPath, `${JSON.stringify(persisted, null, 2)}\n`, {
    mode: 0o600,
  });
  await rename(temporaryPath, filePath);
}

// Modeled in tla/app-preferences/AppPreferences.tla: the serialized
// mutation, monotonic revision, rollback, replay ordering, and shutdown-drain
// invariants implemented by this service and its renderer consumer.
function samePreferenceValues(left: AppPreferences, right: AppPreferences) {
  return (
    sameClientSettings(left.clientSettings, right.clientSettings) &&
    left.openCommaShortcutStatus === right.openCommaShortcutStatus &&
    left.airDropName === right.airDropName &&
    left.keepAwakeWhenLidClosed === right.keepAwakeWhenLidClosed &&
    left.keepAwakeWhenLidClosedStatus === right.keepAwakeWhenLidClosedStatus &&
    left.launchAtLogin === right.launchAtLogin &&
    left.launchAtLoginStatus === right.launchAtLoginStatus &&
    left.notchSideWidth === right.notchSideWidth &&
    left.notificationSound === right.notificationSound &&
    left.notifyRouterMessages === right.notifyRouterMessages &&
    left.showInAirDrop === right.showInAirDrop &&
    left.showInDock === right.showInDock &&
    left.showInMenuBar === right.showInMenuBar &&
    left.showInNotch === right.showInNotch &&
    left.sideChatEnabled === right.sideChatEnabled &&
    left.systemNotifications === right.systemNotifications &&
    left.systemNotificationsStatus === right.systemNotificationsStatus
  );
}

function mergeClientSettings(
  current: CommaClientSettings | undefined,
  patch: NonNullable<AppPreferencesPatch["clientSettings"]>
) {
  const base = current ?? defaultCommaClientSettings;
  return commaClientSettingsSchema.parse({
    ...base,
    ...patch,
    appearance: {
      ...base.appearance,
      ...patch.appearance,
    },
  });
}

function sameClientSettings(
  left: CommaClientSettings | undefined,
  right: CommaClientSettings | undefined
) {
  if (!left || !right) return left === right;
  return JSON.stringify(left) === JSON.stringify(right);
}

function clonePreferences(preferences: AppPreferences): AppPreferences {
  return structuredClone(preferences);
}

function withNextRevision(
  preferences: AppPreferences,
  previous: AppPreferences
): AppPreferences {
  return { ...preferences, revision: previous.revision + 1 };
}

function withSystemNotificationsStatusReadback(
  preferences: AppPreferences,
  status: SystemNotificationsStatus
) {
  return appPreferencesSchema.parse({
    ...preferences,
    systemNotificationsStatus: status,
  });
}

/** An unknown status (no readback on this platform) leaves the last one. */
function withKeepAwakeWhenLidClosedStatusReadback(
  preferences: AppPreferences,
  status: KeepAwakeWhenLidClosedStatus | undefined
) {
  if (status === undefined) return preferences;
  return appPreferencesSchema.parse({
    ...preferences,
    keepAwakeWhenLidClosedStatus: status,
  });
}

/** The daemon still needs the user before keep-awake can take effect. */
function keepAwakeWhenLidClosedWaiting(preferences: AppPreferences) {
  return (
    preferences.keepAwakeWhenLidClosedStatus === "not-registered" ||
    preferences.keepAwakeWhenLidClosedStatus === "requires-approval"
  );
}

function withLaunchAtLoginReadback(
  preferences: AppPreferences,
  readback: LaunchAtLoginReadback
) {
  const { launchAtLoginStatus: _status, ...mutablePreferences } = preferences;
  return appPreferencesSchema.parse({
    ...mutablePreferences,
    launchAtLogin: readback.enabled,
    ...(readback.status ? { launchAtLoginStatus: readback.status } : {}),
  });
}

function sameLaunchAtLoginState(
  preferences: AppPreferences,
  readback: LaunchAtLoginReadback
) {
  return (
    preferences.launchAtLogin === readback.enabled &&
    preferences.launchAtLoginStatus === readback.status
  );
}

function restoredLaunchAtLogin(
  previous: AppPreferences,
  readback: LaunchAtLoginReadback
) {
  return sameLaunchAtLoginState(previous, readback);
}

function launchAtLoginIntent(preferences: AppPreferences) {
  return (
    preferences.launchAtLogin || preferences.launchAtLoginStatus === "requires-approval"
  );
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
