import type { KeepAwakeWhenLidClosedStatus } from "@comma/native-bridge";
import {
  sleepGuardPlistName,
  sleepGuardServiceName,
  type SleepGuardAddon,
  type SleepGuardDaemonStatus,
} from "../../native/macos/SleepGuard";

export type LidSleepGuardFailure = "unavailable" | "failed";

export class LidSleepGuardError extends Error {
  constructor(
    readonly reason: LidSleepGuardFailure,
    message: string
  ) {
    super(message);
    this.name = "LidSleepGuardError";
  }
}

/**
 * Keeps the Mac awake with the lid closed through Comma's privileged sleep
 * guard daemon (native/macos/SleepGuard). The daemon holds the kernel's
 * `SleepDisabled` flag only while this process stays connected, so a quit or
 * crash restores normal sleep without Comma's help.
 */
export class LidSleepGuard {
  readonly #addon: SleepGuardAddon | undefined;
  readonly #plistName: string;
  readonly #serviceName: string;

  constructor({
    addon,
    appBundleId,
  }: {
    addon: SleepGuardAddon | undefined;
    appBundleId: string;
  }) {
    this.#addon = addon;
    this.#plistName = sleepGuardPlistName(appBundleId);
    this.#serviceName = sleepGuardServiceName(appBundleId);
  }

  /** Whether macOS lets the daemon run, as Login Items shows it. */
  status(): KeepAwakeWhenLidClosedStatus {
    return this.#addon
      ? keepAwakeWhenLidClosedStatus(this.#addon.status(this.#plistName))
      : "unavailable";
  }

  /**
   * Holds or releases the flag and resolves the daemon's status. Turning on
   * registers a daemon Comma has not registered yet, but holds the flag only
   * after the user allows the daemon in Login Items. Until then it resolves
   * the status that Settings explains to the user. `atLaunch` resumes only an
   * approved daemon: it never registers one.
   */
  async set(
    enabled: boolean,
    { atLaunch = false }: { atLaunch?: boolean } = {}
  ): Promise<KeepAwakeWhenLidClosedStatus> {
    const addon = this.#addon;
    if (!addon) {
      if (!enabled) return "unavailable";
      throw new LidSleepGuardError(
        "unavailable",
        "The sleep guard is not part of this build."
      );
    }
    let status = this.status();
    if (enabled && status === "not-registered" && !atLaunch) {
      status = this.#register(addon);
    }
    if (enabled && status !== "available") return status;
    const reply = await addon.setSleepDisabled(this.#serviceName, enabled);
    if (!reply.ok) {
      throw new LidSleepGuardError(
        "failed",
        reply.error ?? "The sleep guard refused the request."
      );
    }
    return status;
  }

  /** Opens Login Items, where the user allows the daemon. */
  openLoginItemsSettings() {
    if (!this.#addon) return { opened: false };
    this.#addon.openLoginItemsSettings();
    return { opened: true };
  }

  #register(addon: SleepGuardAddon) {
    const { status, error } = addon.register(this.#plistName);
    const registered = keepAwakeWhenLidClosedStatus(status);
    if (registered === "not-registered") {
      throw new LidSleepGuardError(
        "unavailable",
        `macOS did not register the sleep guard${error ? `: ${error}` : "."}`
      );
    }
    return registered;
  }
}

function keepAwakeWhenLidClosedStatus(
  status: SleepGuardDaemonStatus
): KeepAwakeWhenLidClosedStatus {
  switch (status) {
    case "enabled":
      return "available";
    case "requiresApproval":
      return "requires-approval";
    // macOS reports a daemon that was never registered as notFound, not
    // only as notRegistered.
    case "notRegistered":
    case "notFound":
      return "not-registered";
  }
}
