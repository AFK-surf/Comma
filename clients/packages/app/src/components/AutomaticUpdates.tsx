import { useApplicationMenu } from "./application-menu/useApplicationMenu";
import { useCall, useTopic, type CallFn } from "@comma/core-client";
import { messages, type CommaLocale } from "@comma/i18n";
import { useCommaLocale } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { toast } from "@comma/ui/components/toast";
import { useEffect, useRef, useState } from "react";
import {
  useSessionHostController,
  useSessionLifecycleSnapshot,
} from "../session/react";

const manualUpdateProgressToastId = "comma-manual-update-progress";
const updateReadyToastId = "comma-update-ready";

function showApplyFailure(productName: string, locale: CommaLocale) {
  toast.info(messages.update_install_failed_title(undefined, { locale }), {
    id: updateReadyToastId,
    description: messages.update_install_failed_description(
      { productName },
      { locale }
    ),
  });
}

function showUpdateReady(
  { productName, version }: { productName: string; version: string },
  call: CallFn,
  locale: CommaLocale
) {
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

          void call("appUpdate.apply", {})
            .then(({ applied }) => {
              if (!applied) {
                applying = false;
                showApplyFailure(productName, locale);
              }
            })
            .catch((error: unknown) => {
              applying = false;
              console.error("[automatic-updates] apply failed", error);
              showApplyFailure(productName, locale);
            });
        },
      },
    ],
  });
}

/**
 * The desktop app's update, as the core keeps it (the `appUpdate` topic: the core checks, retries and downloads on
 * its own clock): the restart offer, and the menu's Check for Updates with its progress.
 */
export function AutomaticUpdates() {
  const locale = useCommaLocale();
  const call = useCall();
  const controller = useSessionHostController();
  const signedIn =
    useSessionLifecycleSnapshot(controller.lifecycle).phase === "signed_in";
  const bridge = getNativeBridge();
  const desktop = bridge.platform === "electron";
  // The primary window offers the update the core found on its own; another offers one its own check found.
  const primary =
    desktop &&
    bridge.self.role === "main-window" &&
    bridge.self.windowId === "win_main";
  const { value: update } = useTopic(desktop ? { topic: "appUpdate" } : null);
  const [checking, setChecking] = useState(false);
  // Each manual check that ends with an update ready shows the offer again.
  const [asked, setAsked] = useState(0);
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
          const { outcome } = await call("appUpdate.check", {});
          if (outcome === "unconfigured")
            toast.info(
              locale === "zh-CN"
                ? "当前版本未配置更新源"
                : "Updates are not configured for this build"
            );
          else if (outcome === "current")
            toast.info(locale === "zh-CN" ? "已是最新版本" : "You’re up to date");
          else setAsked((count) => count + 1);
        } catch (error: unknown) {
          console.error("[automatic-updates] manual check failed", error);
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

  // A manual check that waits on a download says so.
  const downloading = update?.downloading === true;
  useEffect(() => {
    if (!checking || !downloading) return;
    toast.info(locale === "zh-CN" ? "正在下载更新…" : "Downloading update…", {
      id: manualUpdateProgressToastId,
      duration: Number.POSITIVE_INFINITY,
    });
  }, [checking, downloading, locale]);

  // The core checks on its own clock; a window coming back (focus, the network)
  // lets it catch up a check the computer slept through.
  useEffect(() => {
    if (!primary) return;
    const wake = () => void call("appUpdate.wake", {}).catch(() => undefined);
    window.addEventListener("focus", wake);
    window.addEventListener("online", wake);
    return () => {
      window.removeEventListener("focus", wake);
      window.removeEventListener("online", wake);
    };
  }, [call, primary]);

  // The restart prompt belongs to the product, so it waits for
  // a session and leaves with one: it never lands on the login screen, and
  // signing out takes it back down. Only an offer this window actually raised
  // is dismissed — sonner delivers a dismissal a frame late, so dismissing an
  // id preemptively can retire the very toast that arrives in between.
  const offered = useRef(false);
  const productName = update?.ready?.productName;
  const version = update?.ready?.version;
  const offers = primary || asked > 0;

  useEffect(() => {
    if (signedIn && offers && productName !== undefined && version !== undefined) {
      showUpdateReady({ productName, version }, call, locale);
      offered.current = true;
      return;
    }
    if (!signedIn && offered.current) {
      toast.dismiss(updateReadyToastId);
      offered.current = false;
    }
  }, [asked, call, locale, offers, productName, signedIn, version]);

  return null;
}
