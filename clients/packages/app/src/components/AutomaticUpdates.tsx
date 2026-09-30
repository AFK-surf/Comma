import { useApplicationMenu } from "./application-menu/useApplicationMenu";
import { messages, type CommaLocale } from "@comma/i18n";
import { useCommaLocale } from "@comma/i18n/react";
import {
  getNativeBridge,
  type CommaNativeBridge,
  type UpdateAsset,
  type UpdateBridge,
  type UpdateInfo,
} from "@comma/native-bridge";
import { toast } from "@comma/ui";
import { useEffect, useRef, useState } from "react";
import {
  useSessionHostController,
  useSessionLifecycleSnapshot,
} from "../session/react";

const manualUpdateProgressToastId = "comma-manual-update-progress";
const updateReadyToastId = "comma-update-ready";
const automaticUpdateChecks = new WeakMap<
  UpdateBridge,
  Promise<ReadyUpdate | undefined>
>();
const automaticUpdateRetryDelaysMs = [5_000, 30_000] as const;

type ApplicableUpdate = UpdateInfo | UpdateAsset;

// An update sitting on disk, waiting for a window in which offering a restart
// is welcome. Carries its own bridge so the restart applies the release this
// check actually downloaded.
type ReadyUpdate = {
  productName: string;
  update: ApplicableUpdate;
  updates: UpdateBridge;
  version: string;
};

function reportUpdateFailure(stage: string, error: unknown) {
  console.error(`[automatic-updates] ${stage} failed`, error);
}

function showApplyFailure(productName: string, locale: CommaLocale) {
  toast.info(messages.update_install_failed_title(undefined, { locale }), {
    id: updateReadyToastId,
    description: messages.update_install_failed_description(
      { productName },
      { locale }
    ),
  });
}

function showUpdateReady(ready: ReadyUpdate, locale: CommaLocale) {
  const { productName, update, updates, version } = ready;
  let applying = false;

  toast.success(messages.update_ready_title(undefined, { locale }), {
    id: updateReadyToastId,
    description: messages.update_ready_description(
      { productName, version },
      { locale }
    ),
    actions: [
      {
        label: messages.update_restart_now(undefined, { locale }),
        onPress: () => {
          if (applying) return;
          applying = true;

          void updates
            .apply(update)
            .then((applied) => {
              if (!applied) {
                applying = false;
                showApplyFailure(productName, locale);
              }
            })
            .catch((error: unknown) => {
              applying = false;
              reportUpdateFailure("apply", error);
              showApplyFailure(productName, locale);
            });
        },
      },
    ],
  });
}

async function checkForAutomaticUpdate(updates: UpdateBridge, onDownload?: () => void) {
  const status = await updates.status();

  if (!status.configured) return undefined;
  if (status.error) {
    throw new Error(status.error);
  }

  const productName = status.productName ?? "Comma";
  if (status.pendingRestart) {
    return {
      productName,
      update: status.pendingRestart,
      updates,
      version: status.pendingRestart.Version,
    };
  }

  const update = await updates.check();
  if (!update) return undefined;

  onDownload?.();
  const downloaded = await updates.download(update);
  if (!downloaded) {
    throw new Error("The update bridge did not confirm the download.");
  }

  return {
    productName,
    update,
    updates,
    version: update.TargetFullRelease.Version,
  };
}

function waitForRetry(delayMs: number) {
  return new Promise<void>((resolve) => {
    window.setTimeout(resolve, delayMs);
  });
}

async function runAutomaticUpdateCheck(updates: UpdateBridge) {
  for (let attempt = 0; attempt <= automaticUpdateRetryDelaysMs.length; attempt += 1) {
    try {
      return await checkForAutomaticUpdate(updates);
    } catch (error: unknown) {
      reportUpdateFailure("check", error);

      const retryDelayMs = automaticUpdateRetryDelaysMs[attempt];
      if (retryDelayMs === undefined) {
        return undefined;
      }

      await waitForRetry(retryDelayMs);
    }
  }

  return undefined;
}

// Memoized on the bridge, so the once-per-launch check survives a remount and
// hands the same result to whoever asks next.
function startAutomaticUpdateCheck(bridge: CommaNativeBridge) {
  if (
    bridge.platform !== "electron" ||
    bridge.self.role !== "main-window" ||
    bridge.self.windowId !== "win_main"
  ) {
    return undefined;
  }

  const existingCheck = automaticUpdateChecks.get(bridge.updates);
  if (existingCheck) return existingCheck;

  const check = runAutomaticUpdateCheck(bridge.updates);
  automaticUpdateChecks.set(bridge.updates, check);
  return check;
}

export function AutomaticUpdates() {
  const locale = useCommaLocale();
  const controller = useSessionHostController();
  const signedIn =
    useSessionLifecycleSnapshot(controller.lifecycle).phase === "signed_in";
  const [ready, setReady] = useState<ReadyUpdate>();
  const [checking, setChecking] = useState(false);
  useApplicationMenu([
    {
      id: "check-updates",
      enabled: !checking,
      run: async () => {
        setChecking(true);
        toast.info(locale === "zh-CN" ? "正在检查更新…" : "Checking for updates…", {
          id: manualUpdateProgressToastId,
          duration: Number.POSITIVE_INFINITY,
        });
        try {
          const bridge = getNativeBridge();
          const status = await bridge.updates.status();
          if (!status.configured) {
            toast.info(
              locale === "zh-CN"
                ? "当前版本未配置更新源"
                : "Updates are not configured for this build"
            );
            return;
          }
          const next = await checkForAutomaticUpdate(bridge.updates, () => {
            toast.info(locale === "zh-CN" ? "正在下载更新…" : "Downloading update…", {
              id: manualUpdateProgressToastId,
              duration: Number.POSITIVE_INFINITY,
            });
          });
          if (next) setReady(next);
          else toast.info(locale === "zh-CN" ? "已是最新版本" : "You’re up to date");
        } catch (error: unknown) {
          reportUpdateFailure("manual check", error);
          toast.error(
            locale === "zh-CN" ? "检查更新失败" : "Could not check for updates",
            {
              description:
                locale === "zh-CN"
                  ? "请检查网络连接后重试。"
                  : "Check your connection and try again.",
            }
          );
        } finally {
          toast.dismiss(manualUpdateProgressToastId);
          setChecking(false);
        }
      },
    },
  ]);

  // Downloading is not the part that interrupts anyone, so it starts with the
  // renderer: by the time a sign-in finishes, the release is already on disk.
  useEffect(() => {
    let live = true;
    void startAutomaticUpdateCheck(getNativeBridge())?.then((next) => {
      if (live && next) setReady(next);
    });
    return () => {
      live = false;
    };
  }, []);

  // Offering the restart is. The prompt belongs to the product, so it waits for
  // a session and leaves with one: it never lands on the login screen, and
  // signing out takes it back down. Only an offer this window actually raised
  // is dismissed — sonner delivers a dismissal a frame late, so dismissing an
  // id preemptively can retire the very toast that arrives in between.
  const offered = useRef(false);

  useEffect(() => {
    if (signedIn && ready) {
      showUpdateReady(ready, locale);
      offered.current = true;
      return;
    }
    if (!signedIn && offered.current) {
      toast.dismiss(updateReadyToastId);
      offered.current = false;
    }
  }, [locale, ready, signedIn]);

  return null;
}
