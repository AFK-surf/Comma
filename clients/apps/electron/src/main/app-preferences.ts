import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import {
  appPreferencesSchema,
  commaClientSettingsSchema,
  defaultAppPreferences,
  defaultCommaClientSettings,
  type AppPreferences,
  type AppPreferencesPatch,
  type CommaClientSettings,
  type SystemNotificationsStatus,
  type SideChatShortcutBinding,
} from "@comma/native-bridge";
import type { LaunchAtLoginReadback } from "./launch-at-login";

export interface AppPreferencesPlatform {
  setOpenCommaShortcut?(shortcut: SideChatShortcutBinding): void;
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
    const persisted = await readPreferences(filePath);
    const preferences = withSystemNotificationsStatusReadback(
      withLaunchAtLoginReadback(persisted, platform.getLaunchAtLogin()),
      await platform.getSystemNotificationsStatus()
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
    return this.#enqueue(async () => {
      const status = await this.#platform.getSystemNotificationsStatus();
      const refreshed = withSystemNotificationsStatusReadback(
        this.#preferences,
        status
      );
      if (samePreferenceValues(refreshed, this.#preferences)) return this.state();
      this.#preferences = withNextRevision(refreshed, this.#preferences);
      const snapshot = this.state();
      this.#onStateChanged(snapshot);
      return snapshot;
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

  #enqueue(task: () => Promise<AppPreferences>) {
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
    if (
      samePreferenceValues(previous, next) &&
      !shouldApplyLaunchAtLogin &&
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

async function readPreferences(filePath: string): Promise<AppPreferences> {
  try {
    return appPreferencesSchema.parse(JSON.parse(await readFile(filePath, "utf8")));
  } catch {
    return { ...defaultAppPreferences };
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
    launchAtLogin: preferences.launchAtLogin,
    notchSideWidth: preferences.notchSideWidth,
    notificationSound: preferences.notificationSound,
    notifyRouterMessages: preferences.notifyRouterMessages,
    showInAirDrop: preferences.showInAirDrop,
    showInDock: preferences.showInDock,
    showInMenuBar: preferences.showInMenuBar,
    showInNotch: preferences.showInNotch,
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
    left.launchAtLogin === right.launchAtLogin &&
    left.launchAtLoginStatus === right.launchAtLoginStatus &&
    left.notchSideWidth === right.notchSideWidth &&
    left.notificationSound === right.notificationSound &&
    left.notifyRouterMessages === right.notifyRouterMessages &&
    left.showInAirDrop === right.showInAirDrop &&
    left.showInDock === right.showInDock &&
    left.showInMenuBar === right.showInMenuBar &&
    left.showInNotch === right.showInNotch &&
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
