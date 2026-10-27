import { useBrowserSettingsCategory } from "./chat/useBrowserSettingsCategory";
import { useAirDropNameSetting } from "./useAirDropNameSetting";
import { useProactiveSetting } from "./recommendations/useProactiveSetting";
import { useComputerUsePermissions } from "./useComputerUsePermissions";
import { useWeChatIntegration } from "./useWeChatIntegration";
import { useModelsCategory } from "./models/useModelsCategory";
import { useArchivedTasksCategory } from "./tasks/useArchivedTasksCategory";
import { useSharedTasksCategory } from "./tasks/useSharedTasksCategory";
import { useMiniAppsSettingsCategory } from "./apps/useMiniAppsSettingsCategory";
import { useDeviceSettingsCategory } from "./devices/useDeviceSettingsCategory";
import { useTaskLabelsCategory } from "./tasks/useTaskLabelsCategory";
import { useCondensedWorkspaceCategory } from "./condensed-workspace/useCondensedWorkspaceCategory";
import { useRouterApiKeysCategory } from "./inbound-api/useRouterApiKeysCategory";
import { useVoiceSettingsCategory } from "./voice/useVoiceSettingsCategory";
import { useSignalIntegration } from "./signal/useSignalIntegration";
import { useIMessageIntegration } from "./imessage/useIMessageIntegration";
import { useTailscaleCategory } from "./tailscale/useTailscaleCategory";
import { useLinearIntegration } from "./linear/useLinearIntegration";
import { supportedLocales, type CommaLocale } from "@comma/i18n";
import {
  getNativeBridge,
  notchSideWidthRange,
  quickChatShortcutText,
  resolveQuickChatShortcut,
  type GlobalShortcut,
  type QuickChatShortcut,
} from "@comma/native-bridge";
import { useEffect, useMemo, useRef, useState } from "react";
import { getActiveCommaConfig } from "@comma/config";
import { useCall, useTopic } from "@comma/core-client";
import { useCommaI18n, useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { ChevronRightSmallIcon, VolumeFullIcon } from "@comma/ui/components/icons";
import {
  createSettingsRegistry,
  NotchWidthSetting,
  SettingsDialog,
  type SettingsCategoryDefinition,
  type SettingsCategoryGroupDefinition,
} from "@comma/ui/components/settings";
import { Dialog } from "@comma/ui/components/dialog";
import { fontFamily as fontFamilyTokens } from "@comma/ui/tokens";
import { TelegramProviderLogo } from "@comma/ui/components/provider-brand-logos";
import { toast } from "@comma/ui/components/toast";
import { Tooltip } from "@comma/ui/components/tooltip";
import {
  type AppKeybinding,
  detectAppKeybindingPlatform,
} from "@comma/ui/components/settings-shortcut";
import { type DropdownItem } from "@comma/ui/components/dropdown";
import {
  type SettingsControl,
  type SettingsPanelItem,
} from "@comma/ui/components/settings-panel";
import {
  type CommaRecommendationEnvelope,
  type CommaRecommendationSettingsPatch,
} from "@comma/core/api-schemas";
import { ThemePicker } from "./commaCustomThemeStudio";
import { WindowTransparencySetting } from "./WindowTransparencySetting";
import {
  commaFontFamilyStack,
  useCommaAppearance,
  type CommaFontSizePreference,
} from "./commaAppearance";
import { useLocalFontFamilies } from "./localFontFamilies";
import { useCommaAppPreferences } from "./commaAppPreferences";
import { isLabelProposalPolicy } from "./tasks/labelProposalPolicy";
import {
  isReplyStyle,
  useRouterReplyStyle,
} from "./router-identity/useRouterReplyStyle";
import { RouterInstructionsDialog } from "./router-identity/RouterInstructionsDialog";
import { useRouterInstructions } from "./router-identity/useRouterInstructions";
import {
  useCommaClientSettings,
  useCommaClientSettingsPending,
} from "./commaClientSettings";
import { playNotificationSound } from "./notifications/notificationSound";
import { ShellIconButtonControl } from "./ShellIconButton";
import { useCommaAuth } from "./auth-context";
import { useAppShortcutCopy } from "./shortcuts/appShortcutCopy";
import { UserAvatar } from "./UserAvatar";
import { LinkProviderIcon } from "./links/linkPreviewCards";
import { useProfileAvatarUrl } from "./useProfileAvatarUrl";
import { AvatarCropDialog } from "./profile/AvatarCropDialog";
import { avatarTypes, isAcceptedAvatarFile } from "./profile/avatarImage";
import { useOptionalCommandPalette } from "./search/CommandPaletteContext";
import { useCommaSettingsOverlay } from "./settingsOverlay";
import { useOnboardingReplaySection } from "./onboarding/useOnboardingReplaySection";
import { needsDesktopApp, requestDesktopApp } from "./DesktopAppPrompt";
import {
  appShortcutDefinitions,
  type AppShortcutId,
} from "./shortcuts/appShortcutRegistry";
import { useCommaAppShortcuts } from "./shortcuts/commaAppShortcuts";
import {
  appBindingConflictsWithGlobalShortcut,
  findAppShortcutConflictForGlobalShortcut,
  sameGlobalShortcut,
} from "./shortcuts/globalShortcutConflict";
import { useWorkspacePreference } from "./activeWorkspace";
import { useUsageBillingCategory } from "./billing/useUsageBillingCategory";
import {
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../nativePlatformActions";

const fontSizePreferences = ["small", "default", "large"] as const;
// Font menu keys. The prefix keeps a family named "default" apart from Comma's own.
const defaultFontFamilyKey = "default";
const fontFamilyKeyPrefix = "family:";
// Initial source discovery is one provider listing with an 8-second transport
// budget; wait it out here instead of reporting a load failure early.

function deviceTimeZone() {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

function formatDeliveryTime(hour: number, minute: number) {
  return `${hour.toString().padStart(2, "0")}:${minute.toString().padStart(2, "0")}`;
}

function isLocale(value: string): value is CommaLocale {
  return supportedLocales.some((locale) => locale === value);
}

function isFontSizePreference(value: string): value is CommaFontSizePreference {
  return fontSizePreferences.some((preference) => preference === value);
}

// A guest Session keeps only device-local preferences and its account row.
const guestSettingsCategoryIds = new Set([
  "general",
  "profile",
  "appearance",
  "notifications",
  "keyboard-shortcuts",
]);
const guestHiddenSettingsSectionIds = new Set([
  "general.permissions",
  "general.tone",
  "general.system-prompt",
  "general.airdrop",
  // A guest Session has no onboarding to replay.
  "general.onboarding",
]);
const guestHiddenShortcutIds = new Set<AppShortcutId>([
  "go-inbox",
  "go-drive",
  "go-tasks",
  "go-plugins",
  "toggle-right-sidebar",
]);

function guestSettingsGroups(
  groups: readonly SettingsCategoryGroupDefinition[],
  accountItems: SettingsPanelItem[]
): SettingsCategoryGroupDefinition[] {
  return groups.flatMap((group) => {
    const categories = group.categories
      .filter((category) => guestSettingsCategoryIds.has(category.id))
      .map((category): SettingsCategoryDefinition => {
        // General's overlay renames this device for AirDrop from the account.
        const { overlay: _overlay, ...withoutOverlay } = category;
        return {
          ...(category.id === "general" ? withoutOverlay : category),
          sections: category.sections
            .filter((section) => !guestHiddenSettingsSectionIds.has(section.id))
            .map((section) =>
              section.id === "profile.account"
                ? { ...section, items: accountItems }
                : section
            ),
        };
      });
    return categories.length > 0 ? [{ ...group, categories }] : [];
  });
}

// Read from the hash rather than the router: this route also renders in unit
// tests, which have no RouterProvider above it.
function readLinkedSettingsParam(name: "category" | "profile"): string | undefined {
  if (typeof window === "undefined") return undefined;
  const hash = window.location.hash;
  const queryStart = hash.indexOf("?");
  if (queryStart < 0) return undefined;
  const value = new URLSearchParams(hash.slice(queryStart + 1)).get(name);
  return value ? value : undefined;
}

function useLinkedSettingsParam(name: "category" | "profile"): string | undefined {
  const [value, setValue] = useState(() => readLinkedSettingsParam(name));
  useEffect(() => {
    if (typeof window === "undefined") return undefined;
    const sync = () => setValue(readLinkedSettingsParam(name));
    sync();
    window.addEventListener("hashchange", sync);
    window.addEventListener("popstate", sync);
    return () => {
      window.removeEventListener("hashchange", sync);
      window.removeEventListener("popstate", sync);
    };
  }, [name]);
  return value;
}

export function AppSettingsRoute({
  additionalSystemCategories = [],
}: {
  additionalSystemCategories?: readonly SettingsCategoryDefinition[];
}) {
  // `/#/settings?category=<id>` opens Settings on that category (the Routines
  // menu links straight to Routines). Local state still owns the
  // selection afterwards, so clicking another category does not fight the URL.
  const linkedCategoryId = useLinkedSettingsParam("category");
  // `&profile=<id>` with the models category opens that Profile, as a funding
  // stop's fix does for the key that ran out.
  const linkedProfileId = useLinkedSettingsParam("profile");
  const [selectedCategoryId, setActiveCategoryId] = useState(
    () => linkedCategoryId ?? "general"
  );
  useEffect(() => {
    if (linkedCategoryId) setActiveCategoryId(linkedCategoryId);
  }, [linkedCategoryId]);
  const m = useCommaMessages();
  const clientSettings = useCommaClientSettings();
  const clientSettingsPending = useCommaClientSettingsPending();
  const onboardingReplay = useOnboardingReplaySection();
  const auth = useCommaAuth();
  const guest = auth.isGuest === true;
  // Every category reader below keys off this id, so a guest never loads the
  // account-wide categories it cannot open.
  const activeCategoryId =
    guest && !guestSettingsCategoryIds.has(selectedCategoryId)
      ? "general"
      : selectedCategoryId === "compute-node"
        ? "devices"
        : selectedCategoryId;
  const [guestDiscardOpen, setGuestDiscardOpen] = useState(false);
  const [guestSignUpPending, setGuestSignUpPending] = useState(false);
  const beginGuestSignUp = () => {
    if (!auth.beginGuestSignUp || guestSignUpPending) return;
    setGuestSignUpPending(true);
    void auth
      .beginGuestSignUp()
      .catch((error: unknown) => {
        toast.error(error instanceof Error ? error.message : String(error));
      })
      .finally(() => setGuestSignUpPending(false));
  };
  const { closeSettings } = useCommaSettingsOverlay();
  // The palette opened over Settings renders inside the modal, so its focus
  // scope nests in the modal's rather than contending with it.
  const commandPalette = useOptionalCommandPalette();
  const claimPaletteHost = commandPalette?.claimPaletteHost;
  useEffect(() => claimPaletteHost?.(), [claimPaletteHost]);
  const browserCategory = useBrowserSettingsCategory();
  const models = useModelsCategory(activeCategoryId === "models");
  const openLinkedProfile = useRef(models.openProfile);
  openLinkedProfile.current = models.openProfile;
  useEffect(() => {
    if (linkedCategoryId === "models" && linkedProfileId) {
      openLinkedProfile.current(linkedProfileId);
    }
  }, [linkedCategoryId, linkedProfileId]);
  const devicesCategory = useDeviceSettingsCategory(
    activeCategoryId === "devices",
    setActiveCategoryId
  );
  const archivedTasksCategory = useArchivedTasksCategory(
    activeCategoryId === "archived-tasks"
  );
  const sharedTasksCategory = useSharedTasksCategory(
    activeCategoryId === "shared-tasks"
  );
  const miniAppsCategory = useMiniAppsSettingsCategory(activeCategoryId === "apps");
  const { category: taskLabelsCategory, approvalPolicy: labelProposalPolicy } =
    useTaskLabelsCategory(
      activeCategoryId === "labels",
      activeCategoryId === "general" && !guest
    );
  const replyStyle = useRouterReplyStyle(activeCategoryId === "general" && !guest);
  const instructions = useRouterInstructions(activeCategoryId === "general" && !guest);
  const [instructionsOpen, setInstructionsOpen] = useState(false);
  const condensedWorkspaceCategory = useCondensedWorkspaceCategory(
    activeCategoryId === "condensed-workspace"
  );
  const routerApiKeysCategory = useRouterApiKeysCategory(
    activeCategoryId === "inbound-api"
  );
  const voiceCategory = useVoiceSettingsCategory(
    activeCategoryId === "voice",
    clientSettings.settings.voiceLabsEnabled
  );
  const usageBillingCategory = useUsageBillingCategory(
    activeCategoryId === "usage-billing"
  );
  const proactive = useProactiveSetting(activeCategoryId === "recommendations");
  // The account's profile as the core keeps it, read while Profile shows.
  const { value: profileShown } = useTopic(
    activeCategoryId === "profile" && !guest ? { topic: "profile" } : null
  );
  const profile = profileShown?.profile ?? undefined;
  const [name, setName] = useState(auth.userDisplayName ?? "");
  const [nameDialogOpen, setNameDialogOpen] = useState(false);
  const [notificationPermissionDialogOpen, setNotificationPermissionDialogOpen] =
    useState(false);
  const [keepAwakeApprovalDialogOpen, setKeepAwakeApprovalDialogOpen] = useState(false);
  const profileLoading =
    activeCategoryId === "profile" &&
    !guest &&
    profileShown?.status !== "ready" &&
    profileShown?.status !== "error";
  const [avatarError, setAvatarError] = useState<string>();
  const [avatarCropFile, setAvatarCropFile] = useState<File>();
  const [nameError, setNameError] = useState<string>();
  // The core reads the briefing's settings while Routines shows; the first read waits out source discovery.
  const recommendationPreference = useWorkspacePreference();
  const recommendationLocale = useCommaI18n().locale;
  const { value: recommendationShown } = useTopic(
    activeCategoryId === "recommendations" && recommendationPreference !== undefined
      ? {
          topic: "recommendations",
          workspace: recommendationPreference,
          timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
          locale: recommendationLocale,
        }
      : null
  );
  const recommendationWorkspaceId = recommendationShown?.workspace ?? undefined;
  const recommendations: CommaRecommendationEnvelope | undefined =
    recommendationShown?.envelope && !recommendationShown.discovering
      ? recommendationShown.envelope
      : undefined;
  const [recommendationsSaving, setRecommendationsSaving] = useState(false);
  const recommendationsPending =
    recommendationsSaving ||
    (activeCategoryId === "recommendations" &&
      !recommendations &&
      recommendationShown?.failure !== "unavailable");
  const recommendationsError = recommendationShown?.failure === "unavailable";
  const [recommendationsSaveError, setRecommendationsSaveError] = useState(false);
  // Telegram, and the account's one workspace that WeChat and Signal show too: the core reads them while Channels shows.
  const call = useCall();
  const { value: telegram } = useTopic(
    activeCategoryId === "channels" ? { topic: "telegram" } : null
  );
  useEffect(() => {
    if (activeCategoryId === "channels")
      void call("telegram.refresh", {}).catch(() => undefined);
  }, [activeCategoryId, call]);
  const telegramWorkspaceId = telegram?.workspace ?? undefined;
  const telegramIntegration = telegram?.state ?? undefined;
  const telegramAttempt = telegram?.attempt ?? undefined;
  const telegramPending = telegram?.busy ?? false;
  const wechatItem = useWeChatIntegration(
    telegramWorkspaceId,
    activeCategoryId === "channels"
  );
  const signalChannel = useSignalIntegration(
    telegramWorkspaceId,
    activeCategoryId === "channels"
  );
  const linearChannel = useLinearIntegration(
    telegramWorkspaceId,
    activeCategoryId === "channels"
  );
  // Shown only where the server has Photon iMessage set up.
  const imessageItem = useIMessageIntegration(
    telegramWorkspaceId,
    activeCategoryId === "channels"
  );
  const tailscaleCategory = useTailscaleCategory(activeCategoryId === "tailscale");
  const channelsOverlay =
    signalChannel.overlay || linearChannel.overlay ? (
      <>
        {signalChannel.overlay}
        {linearChannel.overlay}
      </>
    ) : null;
  const [telegramReconnectOpen, setTelegramReconnectOpen] = useState(false);
  // What failed in this window rather than in the core: a blocked login window, a bot link that would not open.
  const [telegramFailedHere, setTelegramFailedHere] = useState(false);
  const telegramError = (telegram?.error ?? false) || telegramFailedHere;
  // The login window this window opened: a login whose window was closed is cancelled.
  const telegramLoginWindow = useRef<Window | undefined>(undefined);
  const fileInput = useRef<HTMLInputElement>(null);
  const avatarRevision = profile
    ? (profile.avatar_id ?? undefined)
    : auth.avatarRevision;
  const avatarUrl = useProfileAvatarUrl(avatarRevision);
  const { locale, setLocalePreference } = useCommaI18n();
  const {
    fontFamily,
    fontSize,
    pointerCursors,
    reducedMotion,
    setFontFamily,
    setFontSize,
    setPointerCursors,
    setReducedMotion,
    setWindowTranslucency,
    windowTranslucency,
  } = useCommaAppearance();
  const localFonts = useLocalFontFamilies(activeCategoryId === "appearance");
  const fontFamilyItems = useMemo((): DropdownItem[] => {
    const families = localFonts.families ?? [];
    // The saved family stays listed while the list loads or after its removal.
    const listed =
      fontFamily === null || families.includes(fontFamily)
        ? families
        : [fontFamily, ...families];
    return [
      {
        id: defaultFontFamilyKey,
        label: m.settings_default(),
        fontFamily: fontFamilyTokens.sans,
      },
      ...listed.map((family) => ({
        id: `${fontFamilyKeyPrefix}${family}`,
        label: family,
        fontFamily: commaFontFamilyStack(family),
      })),
    ];
  }, [fontFamily, localFonts.families, m]);
  const {
    bindings: appShortcutBindings,
    conflictFor,
    defaultBindings: defaultAppShortcutBindings,
    isDefault: appShortcutsAreDefault,
    resetAll: resetAppShortcuts,
    setBinding: setAppShortcutBinding,
  } = useCommaAppShortcuts();
  const [shortcutConflicts, setShortcutConflicts] = useState<
    Partial<Record<AppShortcutId, true>>
  >({});
  const electronRuntime = getNativeBridge().platform === "electron";
  // Only a main window Main drew over a system material (macOS, Windows 11)
  // has a translucent ground to turn off or tune (window-options.ts).
  const windowMaterial = getNativeBridge().windowMaterial !== undefined;
  // Quick Chat starts with a double tap of ⌘ on macOS and of Ctrl on Windows,
  // unless the person chose another modifier or a global shortcut.
  const quickChatOnWindows = detectAppKeybindingPlatform() === "windows";
  const quickChatPlatform = quickChatOnWindows ? "windows" : "macos";
  const quickChatShortcut = resolveQuickChatShortcut(
    clientSettings.settings.quickChatShortcut,
    quickChatPlatform
  );
  const quickChatChord = "tap" in quickChatShortcut ? null : quickChatShortcut;
  const quickChatTrigger =
    "tap" in quickChatShortcut
      ? m.quick_chat_trigger_double_tap({
          key: quickChatShortcutText(quickChatShortcut, quickChatPlatform),
        })
      : m.quick_chat_trigger_press({
          shortcut: quickChatShortcutText(quickChatShortcut, quickChatPlatform),
        });
  const [openCommaShortcutError, setOpenCommaShortcutError] = useState<
    "conflict" | "registration"
  >();
  const [openCommaShortcutPending, setOpenCommaShortcutPending] = useState(false);
  const setOpenCommaShortcut = async (shortcut: GlobalShortcut | null) => {
    if (
      findAppShortcutConflictForGlobalShortcut(appShortcutBindings, shortcut) ||
      sameGlobalShortcut(shortcut, quickChatChord)
    ) {
      setOpenCommaShortcutError("conflict");
      return;
    }
    setOpenCommaShortcutPending(true);
    setOpenCommaShortcutError(undefined);
    try {
      await clientSettings.update(
        { openCommaShortcut: shortcut },
        { throwOnError: true }
      );
    } catch {
      setOpenCommaShortcutError("registration");
    } finally {
      setOpenCommaShortcutPending(false);
    }
  };
  const [quickChatShortcutError, setQuickChatShortcutError] = useState<
    "conflict" | "registration"
  >();
  const [quickChatShortcutPending, setQuickChatShortcutPending] = useState(false);
  // The platform's own double tap is stored as null, so it follows the platform.
  const setQuickChatShortcut = async (shortcut: QuickChatShortcut) => {
    const chord = "tap" in shortcut ? null : shortcut;
    if (
      findAppShortcutConflictForGlobalShortcut(appShortcutBindings, chord) ||
      sameGlobalShortcut(chord, clientSettings.settings.openCommaShortcut)
    ) {
      setQuickChatShortcutError("conflict");
      return;
    }
    const platformDefault = resolveQuickChatShortcut(null, quickChatPlatform);
    setQuickChatShortcutPending(true);
    setQuickChatShortcutError(undefined);
    try {
      await clientSettings.update(
        {
          quickChatShortcut:
            "tap" in shortcut &&
            "tap" in platformDefault &&
            shortcut.tap === platformDefault.tap
              ? null
              : shortcut,
        },
        { throwOnError: true }
      );
    } catch {
      setQuickChatShortcutError("registration");
    } finally {
      setQuickChatShortcutPending(false);
    }
  };
  const computerUse = useComputerUsePermissions(activeCategoryId === "computer-use");
  // In a browser, the desktop app's controls stay live and offer the Mac app.
  const desktopOnly = needsDesktopApp();
  const permissionStatus = (granted: boolean | undefined) =>
    !computerUse.available
      ? m.settings_computer_use_macos_only()
      : granted === undefined
        ? m.settings_computer_use_unknown()
        : granted
          ? m.settings_computer_use_granted()
          : m.settings_computer_use_missing();

  const settingsShortcutDefinitions = appShortcutDefinitions.filter(
    (definition) => !(guest && guestHiddenShortcutIds.has(definition.id))
  );
  const generalShortcutCopy = useAppShortcutCopy();
  // `pending` covers a native write in flight from *any* Main window, which is
  // how concurrent preference updates are serialised — so it has to gate these
  // toggles. It used to flash them at 50% opacity on every click; that is fixed
  // in the toggle's own disabled styling, which now dims on a delay.
  const {
    availability: appPreferencesAvailability,
    pending: appPreferencesPending,
    preferences: appPreferences,
    showInSystemTray,
    update: updateAppPreferences,
    openLoginItemsSettings,
    openNotificationSettings,
  } = useCommaAppPreferences();
  const airDropName = useAirDropNameSetting({
    pending: appPreferencesPending,
    preferences: appPreferences,
    update: updateAppPreferences,
  });
  // A released width shows at once and stays until Main answers; a refused
  // write then glides back to the width Main kept.
  const [notchSideWidthDraft, setNotchSideWidthDraft] = useState<number>();
  const notchSideWidth =
    notchSideWidthDraft ??
    appPreferences?.notchSideWidth ??
    notchSideWidthRange.default;
  // Shows the width once where the Notch really sits, with the preview's title.
  const previewNotchSideWidth = (width: number) => {
    void getNativeBridge()
      .notch.preview({ sideWidth: width, title: m.settings_notch_preview_task() })
      .catch(() => undefined);
  };
  const commitNotchSideWidth = (width: number) => {
    setNotchSideWidthDraft(width);
    void updateAppPreferences({ notchSideWidth: width }).finally(() => {
      setNotchSideWidthDraft((draft) => (draft === width ? undefined : draft));
    });
  };

  // The name field starts from the account's name once it is read.
  const profileName = profile?.name;
  useEffect(() => {
    if (profileName !== undefined) setName(profileName ?? "");
  }, [profileName]);
  const profileLoadFailed =
    activeCategoryId === "profile" && profileShown?.status === "error";
  const avatarMessage =
    avatarError ?? (profileLoadFailed ? m.settings_profile_load_failed() : undefined);
  const nameMessage =
    nameError ?? (profileLoadFailed ? m.settings_profile_load_failed() : undefined);

  useEffect(() => {
    if (activeCategoryId !== "channels") setTelegramReconnectOpen(false);
    setTelegramFailedHere(false);
  }, [activeCategoryId]);

  // Each time the core has read the login, see whether its window was closed.
  const telegramChecks = telegram?.checks ?? 0;
  useEffect(() => {
    if (!telegramAttempt || !telegramLoginWindow.current?.closed) return;
    telegramLoginWindow.current = undefined;
    void call("telegram.cancel", { closed: true }).catch(() => undefined);
  }, [call, telegramAttempt, telegramChecks]);

  const connectTelegram = async () => {
    if (!telegramWorkspaceId || telegramPending) return;
    setTelegramFailedHere(false);
    try {
      const popup = await openNativePlatformExternalUrlFromUserAction(async () => {
        const attempt = await call("telegram.connect", {
          environment: getActiveCommaConfig().channel,
        });
        return attempt.authorizationUrl;
      });
      telegramLoginWindow.current = popup ?? undefined;
    } catch {
      // A blocked window never reached the core: say so here. A refused start the core says itself.
      setTelegramFailedHere(true);
    }
  };

  const cancelTelegramConnect = () => {
    telegramLoginWindow.current = undefined;
    void call("telegram.cancel", {}).catch(() => undefined);
  };

  const disconnectTelegram = () => {
    if (!telegramWorkspaceId || telegramPending) return;
    void call("telegram.disconnect", {}).catch(() => undefined);
  };

  // A card that works needs no subtitle; one shows only to report trouble or progress.
  function telegramConnectionDescription(): string | undefined {
    if (telegramError) return m.settings_telegram_action_failed();
    if (!telegramIntegration && !telegramAttempt) return m.settings_telegram_loading();
    if (telegramPending || telegramAttempt) return m.settings_telegram_connecting();

    const link = telegramIntegration?.link;
    if (link && telegramIntegration?.connection_active === false)
      return m.settings_telegram_repair_required();

    return telegramIntegration?.configured
      ? undefined
      : m.settings_telegram_unavailable();
  }
  const telegramDescription = telegramConnectionDescription();

  const recommendationDeliveryTime = recommendations
    ? formatDeliveryTime(
        recommendations.settings.schedule.hour,
        recommendations.settings.schedule.minute
      )
    : "08:00";
  const recommendationDeliveryTimeItems = useMemo(() => {
    const hours = Array.from({ length: 24 }, (_, hour) => formatDeliveryTime(hour, 0));
    // A saved time off the hour stays selectable and visible.
    const items = hours.includes(recommendationDeliveryTime)
      ? hours
      : [...hours, recommendationDeliveryTime].toSorted();
    return items.map((time) => ({ id: time, label: time }));
  }, [recommendationDeliveryTime]);

  // Each control writes only what it changed: a source toggle names that one
  // connection, and schedule or auto-enable changes name no source at all, so
  // a Settings tab opened before discovery ran cannot re-apply stale flags.
  const saveRecommendationSettings = async (
    patch: CommaRecommendationSettingsPatch
  ) => {
    if (!recommendationWorkspaceId || recommendationsPending) return;
    setRecommendationsSaving(true);
    setRecommendationsSaveError(false);
    try {
      await call("recommendations.updateSettings", {
        workspace: recommendationWorkspaceId,
        patch,
      });
    } catch {
      // The controls keep reading the last envelope, which the refused write
      // did not change; the schedule row says the save failed.
      setRecommendationsSaveError(true);
    } finally {
      setRecommendationsSaving(false);
    }
  };

  // Describe source content without promising mode-specific collection filters.
  // Unknown apps show no subtitle.
  const recommendationSourceDescriptions: Record<string, () => string> = {
    github: m.settings_recommendations_source_github,
    gmail: m.settings_recommendations_source_gmail,
    googlecalendar: m.settings_recommendations_source_googlecalendar,
    googledrive: m.settings_recommendations_source_googledrive,
    linear: m.settings_recommendations_source_linear,
    notion: m.settings_recommendations_source_notion,
    slack: m.settings_recommendations_source_slack,
  };
  const recommendationSourceDescription = (appId: string) => {
    const describe = recommendationSourceDescriptions[appId];
    return describe ? { description: describe() } : {};
  };

  // The schedule runs in the timezone of the device the member sets it on.
  const recommendationSchedulePatch = (
    settings: CommaRecommendationEnvelope["settings"],
    schedule: Partial<CommaRecommendationEnvelope["settings"]["schedule"]>
  ): CommaRecommendationSettingsPatch => ({
    autoEnableNewSources: settings.autoEnableNewSources,
    schedule: { ...settings.schedule, ...schedule, timezone: deviceTimeZone() },
  });

  // The core shows a new or removed avatar at once and puts the saved one back
  // when the server refuses the change; this only says it failed.
  const runAvatarOperation = async (operation: () => Promise<unknown>) => {
    setAvatarError(undefined);
    try {
      await operation();
    } catch {
      setAvatarError(m.settings_profile_save_failed());
    }
  };

  const chooseAvatar = (file?: File) => {
    if (!file) return;
    if (!isAcceptedAvatarFile(file)) {
      setAvatarError(m.settings_profile_avatar_help());
      return;
    }
    setAvatarError(undefined);
    setAvatarCropFile(file);
  };

  const uploadAvatar = async (file: File) => {
    const bytes = new Uint8Array(await file.arrayBuffer());
    setAvatarCropFile(undefined);
    await runAvatarOperation(() =>
      call("profile.uploadAvatar", { bytes, type: file.type, name: file.name })
    );
  };

  // The language belongs to the account, so every device and server-written
  // text follow it. This device switches once the account has it.
  const saveLocale = async (next: CommaLocale) => {
    if (next === locale) return;
    try {
      await call("profile.update", { locale: next });
      setLocalePreference(next);
    } catch {
      toast.error(m.settings_profile_save_failed());
    }
  };

  const saveName = async () => {
    const nextName = name.trim();
    if (!nextName || nextName.length > 64) return;

    // The core shows the new name at once and the saved one again if the server
    // refuses it; the dialog is done once it is asked for.
    setNameDialogOpen(false);
    try {
      await call("profile.update", { name: nextName });
    } catch {
      toast.error(m.settings_profile_save_failed());
    }
  };

  const normalizedName = name.trim();
  const nameInvalid = normalizedName.length > 64;
  const nameUnchanged = normalizedName === (profile?.name ?? "").trim();
  const currentName =
    profile?.name?.trim() || auth.userDisplayName?.trim() || auth.userEmail;

  function telegramConnectionControl(): SettingsControl {
    if (telegramAttempt) {
      return {
        type: "button",
        label: m.settings_telegram_cancel_connect(),
        onPress: () => void cancelTelegramConnect(),
      };
    }
    if (telegramIntegration?.link) {
      return {
        type: "menu",
        label: m.settings_telegram_manage(),
        disabled: telegramPending,
        items: [
          {
            id: "reconnect",
            label: m.settings_telegram_reconnect(),
            onPress: () => setTelegramReconnectOpen(true),
          },
          {
            id: "disconnect",
            label: m.settings_telegram_disconnect(),
            tone: "destructive",
            onPress: () => void disconnectTelegram(),
          },
        ],
      };
    }
    return {
      type: "button",
      label: m.settings_telegram_connect(),
      disabled:
        telegramPending || !telegramWorkspaceId || !telegramIntegration?.configured,
      onPress: () => void connectTelegram(),
    };
  }

  function telegramConnectionDetails(): NonNullable<SettingsPanelItem["integration"]> {
    const link = telegramIntegration?.link;
    let status: NonNullable<SettingsPanelItem["integration"]>["status"] = {
      label: m.settings_telegram_disconnected(),
      color: "gray",
    };
    if (telegramError) {
      status = { label: m.settings_telegram_needs_attention(), color: "warning" };
    } else if (!telegramIntegration && !telegramAttempt) {
      status = { label: m.settings_telegram_loading(), color: "gray", loading: true };
    } else if (telegramAttempt || telegramPending) {
      status = { label: m.settings_telegram_pending(), color: "blue" };
    } else if (link && telegramIntegration?.connection_active === false) {
      status = { label: m.settings_telegram_needs_attention(), color: "warning" };
    } else if (link) {
      status = { label: m.settings_telegram_connected(), color: "success" };
    }
    const botUsername = telegramIntegration?.bot_username;
    const canOpenBot = botUsername && /^[a-zA-Z0-9_]{5,32}$/.test(botUsername);
    let account: string = m.settings_telegram_disconnected();
    if (link) account = link.telegram_user_id;
    if (link?.telegram_username) account = `@${link.telegram_username}`;
    return {
      status,
      details: [
        {
          label: m.settings_telegram_account(),
          value: account,
        },
        {
          label: m.settings_telegram_bot(),
          value: botUsername ? `@${botUsername}` : "—",
          actionLabel: m.settings_telegram_open(),
          ...(canOpenBot
            ? {
                onPress: () => {
                  void openNativePlatformExternalUrl(
                    `https://t.me/${botUsername}`
                  ).catch(() => setTelegramFailedHere(true));
                },
              }
            : {}),
        },
      ],
      note: link
        ? m.settings_telegram_private_chat_note()
        : m.settings_telegram_setup_note(),
    };
  }

  const openNameDialog = () => {
    setName(profile?.name ?? auth.userDisplayName ?? "");
    setNameError(undefined);
    setNameDialogOpen(true);
  };

  const closeNameDialog = () => {
    setName(profile?.name ?? auth.userDisplayName ?? "");
    setNameError(undefined);
    setNameDialogOpen(false);
  };
  // The OS decides whether Comma may notify at all. When it says no, the master
  // switch still reads as off and stays interactive: turning it on opens a
  // dialog that jumps to System Settings. The stored choice is kept for when
  // the OS allows it again. An OS that has not asked the user yet
  // (`undetermined`) reads like an available one: its prompt comes with the
  // first banner. So does one Main could not ask (`unknown`): Electron decides
  // when the banner is posted.
  const systemNotificationsStatus =
    appPreferences?.systemNotificationsStatus ?? "available";
  const systemNotificationsBlocked =
    systemNotificationsStatus === "denied" ||
    systemNotificationsStatus === "unsupported";
  const systemNotificationsOn =
    (appPreferences?.systemNotifications ?? false) && !systemNotificationsBlocked;
  const systemNotificationsChecked =
    notificationPermissionDialogOpen || systemNotificationsOn;
  const systemNotificationsDescription =
    systemNotificationsStatus === "denied"
      ? m.settings_system_notifications_denied_description()
      : systemNotificationsStatus === "unsupported"
        ? m.settings_system_notifications_unsupported_description()
        : m.settings_system_notifications_description();
  const handleSystemNotificationsChange = (event: { target: { checked: boolean } }) => {
    const next = event.target.checked;
    if (next && systemNotificationsStatus === "denied") {
      setNotificationPermissionDialogOpen(true);
      if (!(appPreferences?.systemNotifications ?? false)) {
        void updateAppPreferences({ systemNotifications: true });
      }
      return;
    }
    setNotificationPermissionDialogOpen(false);
    void updateAppPreferences({
      systemNotifications: next,
    });
  };
  // macOS runs the sleep guard only after the user allows it once in Login
  // Items. Until then the choice waits: the switch reads off, turning it on
  // explains where to allow Comma, and Main's readback when a window regains
  // focus turns it on. Cancelling withdraws the choice, so a later approval
  // does not keep the Mac awake without the user asking again.
  const keepAwakeStatus = appPreferences?.keepAwakeWhenLidClosedStatus;
  const keepAwakeChosen = appPreferences?.keepAwakeWhenLidClosed ?? false;
  const keepAwakeWaiting =
    keepAwakeStatus === "not-registered" || keepAwakeStatus === "requires-approval";
  const keepAwakeOn =
    keepAwakeChosen &&
    (keepAwakeStatus === undefined || keepAwakeStatus === "available");
  const keepAwakeDescription =
    appPreferencesAvailability.keepAwakeWhenLidClosed &&
    keepAwakeStatus === "unavailable"
      ? m.settings_keep_awake_lid_closed_unavailable_description()
      : keepAwakeChosen && keepAwakeWaiting
        ? m.settings_keep_awake_lid_closed_requires_approval_description()
        : m.settings_keep_awake_lid_closed_description();
  const handleKeepAwakeChange = async (event: { target: { checked: boolean } }) => {
    if (!event.target.checked) {
      setKeepAwakeApprovalDialogOpen(false);
      void updateAppPreferences({ keepAwakeWhenLidClosed: false });
      return;
    }
    const acknowledged = await updateAppPreferences({ keepAwakeWhenLidClosed: true });
    if (
      acknowledged?.keepAwakeWhenLidClosed &&
      acknowledged.keepAwakeWhenLidClosedStatus === "requires-approval"
    ) {
      setKeepAwakeApprovalDialogOpen(true);
    }
  };
  const cancelKeepAwakeApproval = () => {
    setKeepAwakeApprovalDialogOpen(false);
    void updateAppPreferences({ keepAwakeWhenLidClosed: false });
  };
  const computerUseCategory: SettingsCategoryDefinition = {
    id: "computer-use",
    icon: "computer-use",
    label: m.settings_computer_use(),
    sections: [
      {
        id: "computer-use.access",
        title: m.settings_access(),
        items: [
          {
            id: "computer-use.accessibility",
            title: m.settings_computer_use_accessibility(),
            description: permissionStatus(computerUse.permissions?.accessibility),
          },
          {
            id: "computer-use.screen-recording",
            title: m.settings_computer_use_screen_recording(),
            description: permissionStatus(computerUse.permissions?.screenRecording),
          },
          {
            id: "computer-use.permissions",
            title: m.settings_computer_use_permissions(),
            description: m.settings_computer_use_permissions_description(),
            control: {
              type: "button",
              label: m.settings_computer_use_manage(),
              disabled: !desktopOnly && (!computerUse.available || computerUse.pending),
              onPress: desktopOnly
                ? () => requestDesktopApp("computer-use")
                : computerUse.open,
            },
          },
          {
            id: "computer-use.refresh",
            title: m.settings_computer_use_status(),
            description:
              computerUse.error ?? m.settings_computer_use_refresh_description(),
            control: {
              type: "button",
              label: m.settings_computer_use_refresh(),
              disabled: !desktopOnly && (!computerUse.available || computerUse.pending),
              onPress: desktopOnly
                ? () => requestDesktopApp("computer-use")
                : computerUse.refresh,
            },
          },
        ],
      },
    ],
  };
  const accountRegistry = createSettingsRegistry({
    groups: [
      {
        id: "preferences",
        label: m.settings_group_preferences(),
        categories: [
          {
            id: "general",
            icon: "general",
            label: m.settings_general(),
            overlay: airDropName.overlay,
            sections: [
              {
                id: "general.permissions",
                title: m.settings_permissions(),
                items: [
                  {
                    id: "permissions.label-changes",
                    title: m.settings_label_changes(),
                    description: labelProposalPolicy.error
                      ? m.settings_label_changes_failed()
                      : m.settings_label_changes_description(),
                    keywords: ["label", "标签"],
                    control: {
                      type: "dropdown",
                      value: labelProposalPolicy.value,
                      disabled: labelProposalPolicy.disabled,
                      placeholder: m.settings_label_changes_ask(),
                      items: [
                        { id: "ask", label: m.settings_label_changes_ask() },
                        { id: "auto", label: m.settings_label_changes_auto() },
                      ],
                      onChange: (value) => {
                        if (isLabelProposalPolicy(value))
                          labelProposalPolicy.set(value);
                      },
                    },
                  },
                ],
              },
              {
                id: "general.tone",
                title: m.settings_tone(),
                items: [
                  {
                    id: "replies.style",
                    title: m.settings_reply_style(),
                    description: replyStyle.error
                      ? m.settings_reply_style_failed()
                      : m.settings_reply_style_description(),
                    keywords: ["tone", "style", "concise", "语气", "风格", "简洁"],
                    control: {
                      type: "dropdown",
                      ariaLabel: m.settings_reply_style(),
                      // Empty until the Router is read.
                      value: replyStyle.value ?? "",
                      disabled: replyStyle.disabled,
                      placeholder: m.settings_reply_style_default(),
                      items: [
                        { id: "default", label: m.settings_reply_style_default() },
                        { id: "concise", label: m.settings_reply_style_concise() },
                      ],
                      onChange: (value) => {
                        if (isReplyStyle(value)) replyStyle.set(value);
                      },
                    },
                  },
                ],
              },
              {
                id: "general.system-prompt",
                title: m.settings_system_prompt(),
                items: [
                  {
                    id: "router.instructions",
                    title: m.settings_system_prompt_custom(),
                    description:
                      instructions.failure === "load"
                        ? m.settings_system_prompt_load_failed()
                        : instructions.content
                          ? m.settings_system_prompt_set()
                          : m.settings_system_prompt_description(),
                    keywords: [
                      "system prompt",
                      "instructions",
                      "custom",
                      "系统提示词",
                      "指令",
                      "自定义",
                    ],
                    control: {
                      type: "button",
                      label: m.settings_system_prompt_edit(),
                      // Only the owner's Router instructions can be read.
                      disabled: instructions.content === undefined || instructions.busy,
                      onPress: () => setInstructionsOpen(true),
                    },
                  },
                ],
              },
              {
                id: "general.application",
                title: m.settings_general(),
                items: [
                  {
                    id: "app.language",
                    title: m.settings_language(),
                    description: m.settings_language_description(),
                    keywords: ["locale", "语言"],
                    control: {
                      type: "dropdown",
                      value: locale,
                      placeholder: m.settings_language_select(),
                      items: [
                        { id: "en", label: m.settings_language_english() },
                        {
                          id: "zh-CN",
                          label: m.settings_language_simplified_chinese(),
                        },
                      ],
                      onChange: (value) => {
                        if (isLocale(value)) void saveLocale(value);
                      },
                    },
                  },
                  {
                    id: "app.launch-at-login",
                    title: m.settings_launch_at_login(),
                    description:
                      appPreferences?.launchAtLoginStatus === "requires-approval"
                        ? m.settings_launch_at_login_requires_approval_description()
                        : m.settings_launch_at_login_description(),
                    keywords: ["startup", "boot", "开机"],
                    control: {
                      type: "toggle",
                      checked: appPreferences?.launchAtLogin ?? false,
                      disabled:
                        !desktopOnly &&
                        (!appPreferencesAvailability.launchAtLogin ||
                          !appPreferences ||
                          appPreferences.launchAtLoginStatus === "requires-approval" ||
                          appPreferencesPending),
                      onChange: (event) => {
                        if (desktopOnly) return requestDesktopApp("launch-at-login");
                        void updateAppPreferences({
                          launchAtLogin: event.target.checked,
                        });
                      },
                    },
                  },
                  {
                    id: "app.menu-bar",
                    title: showInSystemTray
                      ? m.settings_show_in_system_tray()
                      : m.settings_show_in_menu_bar(),
                    description: showInSystemTray
                      ? m.settings_show_in_system_tray_description()
                      : m.settings_show_in_menu_bar_description(),
                    control: {
                      type: "toggle",
                      checked: appPreferences?.showInMenuBar ?? false,
                      disabled:
                        !desktopOnly &&
                        (!appPreferencesAvailability.showInMenuBar ||
                          !appPreferences ||
                          appPreferencesPending),
                      onChange: (event) => {
                        if (desktopOnly) return requestDesktopApp("menu-bar");
                        void updateAppPreferences({
                          showInMenuBar: event.target.checked,
                        });
                      },
                    },
                  },
                  // The Dock is macOS's: a desktop app elsewhere (Windows) has
                  // none to show the row for; the web shows it to offer the app.
                  ...(desktopOnly || appPreferencesAvailability.showInDock
                    ? [
                        {
                          id: "app.dock",
                          title: m.settings_show_in_dock(),
                          description: m.settings_show_in_dock_description(),
                          control: {
                            type: "toggle" as const,
                            checked: appPreferences?.showInDock ?? false,
                            disabled:
                              !desktopOnly &&
                              (!appPreferences || appPreferencesPending),
                            onChange: (event: { target: { checked: boolean } }) => {
                              if (desktopOnly) return requestDesktopApp("dock");
                              void updateAppPreferences({
                                showInDock: event.target.checked,
                              });
                            },
                          },
                        },
                      ]
                    : []),
                  // Where this machine can run Quick Chat (macOS 26, Windows): off,
                  // its helper stops and takes neither the key nor the microphone.
                  ...(appPreferences?.quickChatSupported
                    ? [
                        {
                          id: "app.quick-chat",
                          title: m.settings_quick_chat(),
                          description: quickChatOnWindows
                            ? m.settings_quick_chat_enabled_description_windows({
                                trigger: quickChatTrigger,
                              })
                            : m.settings_quick_chat_enabled_description({
                                trigger: quickChatTrigger,
                              }),
                          keywords: ["quick chat", "voice", "dictation", "语音"],
                          control: {
                            type: "toggle" as const,
                            checked: appPreferences.quickChatEnabled,
                            disabled: appPreferencesPending,
                            onChange: (event: { target: { checked: boolean } }) => {
                              void updateAppPreferences({
                                quickChatEnabled: event.target.checked,
                              });
                            },
                          },
                        },
                      ]
                    : []),
                  // Keeping a closed lid awake is the macOS app's (its sleep
                  // guard); a desktop app elsewhere has no such row.
                  ...(desktopOnly || appPreferencesAvailability.keepAwakeWhenLidClosed
                    ? [
                        {
                          id: "app.keep-awake-lid-closed",
                          title: m.settings_keep_awake_lid_closed(),
                          description: keepAwakeDescription,
                          keywords: ["sleep", "caffeinate", "休眠", "合盖"],
                          control: {
                            type: "toggle" as const,
                            checked: keepAwakeApprovalDialogOpen || keepAwakeOn,
                            disabled:
                              !desktopOnly &&
                              (!appPreferences ||
                                keepAwakeStatus === "unavailable" ||
                                appPreferencesPending),
                            onChange: (event: { target: { checked: boolean } }) => {
                              if (desktopOnly) return requestDesktopApp("keep-awake");
                              void handleKeepAwakeChange(event);
                            },
                          },
                        },
                      ]
                    : []),
                ],
              },
              // AirDrop reception exists only in the macOS desktop app.
              ...(appPreferencesAvailability.showInAirDrop
                ? [
                    {
                      id: "general.airdrop",
                      title: m.settings_airdrop(),
                      items: [
                        {
                          id: "app.airdrop",
                          title: m.settings_show_in_airdrop(),
                          description: m.settings_show_in_airdrop_description(),
                          keywords: ["airdrop", "隔空投送"],
                          control: {
                            type: "toggle" as const,
                            checked: appPreferences?.showInAirDrop ?? false,
                            disabled: !appPreferences || appPreferencesPending,
                            onChange: (event: { target: { checked: boolean } }) => {
                              void updateAppPreferences({
                                showInAirDrop: event.target.checked,
                              });
                            },
                          },
                        },
                        // Named only while nearby devices can see Comma.
                        ...(appPreferences?.showInAirDrop ? [airDropName.item] : []),
                      ],
                    },
                  ]
                : []),
              // The Notch exists only in the macOS desktop app.
              ...(appPreferencesAvailability.showInNotch
                ? [
                    {
                      id: "general.notch",
                      title: m.settings_notch(),
                      items: [
                        {
                          id: "app.notch",
                          title: m.settings_show_in_notch(),
                          description: m.settings_show_in_notch_description(),
                          keywords: ["notch", "dynamic island", "刘海", "灵动岛"],
                          control: {
                            type: "toggle" as const,
                            checked: appPreferences?.showInNotch ?? false,
                            disabled: !appPreferences || appPreferencesPending,
                            onChange: (event: { target: { checked: boolean } }) => {
                              void updateAppPreferences({
                                showInNotch: event.target.checked,
                              });
                            },
                          },
                          // No slot until the saved choice is known, so a Notch
                          // that is already on shows its preview without
                          // unfolding every time Settings opens.
                          content:
                            !appPreferences ? undefined : appPreferences.showInNotch ? (
                              <NotchWidthSetting
                                defaultValue={notchSideWidthRange.default}
                                labels={{
                                  preview: m.settings_notch_preview_on_notch(),
                                  reset: m.settings_notch_width_reset(),
                                  sampleTitle: m.settings_notch_preview_task(),
                                  valueText: (points) =>
                                    m.settings_notch_width_value({ points }),
                                  width: m.settings_notch_width(),
                                }}
                                max={notchSideWidthRange.max}
                                min={notchSideWidthRange.min}
                                onPreview={previewNotchSideWidth}
                                onValueCommit={commitNotchSideWidth}
                                value={notchSideWidth}
                              />
                            ) : null,
                        },
                      ],
                    },
                  ]
                : []),
              onboardingReplay,
            ],
          },
          {
            id: "profile",
            icon: "profile",
            label: m.settings_profile(),
            sections: [
              {
                id: "profile.account",
                title: `${m.settings_account()} · ${profile?.email ?? auth.userEmail}`,
                items: [
                  {
                    id: "account.avatar",
                    title: m.settings_profile_avatar(),
                    description: m.settings_profile_avatar_help(),
                    ...(avatarMessage ? { errorMessage: avatarMessage } : {}),
                    control: {
                      type: "custom",
                      content: (
                        <div className="flex items-center">
                          <div className="flex items-center">
                            <Button
                              aria-label={m.settings_profile_choose_avatar()}
                              {...(avatarMessage
                                ? {
                                    "aria-describedby": "settings-error-account.avatar",
                                  }
                                : {})}
                              className="size-10 rounded-full p-0 [&>span]:p-0"
                              disabled={profileLoading}
                              hierarchy="link-gray"
                              onPress={() => fileInput.current?.click()}
                              size="md"
                            >
                              <UserAvatar
                                {...(avatarUrl ? { avatarUrl } : {})}
                                displayName={name || auth.userDisplayName}
                                email={profile?.email ?? auth.userEmail}
                                size="md"
                              />
                            </Button>
                            <input
                              ref={fileInput}
                              accept={avatarTypes.join(",")}
                              aria-label={m.settings_profile_choose_avatar()}
                              className="hidden"
                              onChange={(event) => {
                                chooseAvatar(event.target.files?.[0]);
                                event.target.value = "";
                              }}
                              type="file"
                            />
                          </div>
                        </div>
                      ),
                    },
                  },
                  {
                    id: "account.name",
                    title: m.settings_profile_name(),
                    description: m.settings_profile_name_description(),
                    control: {
                      type: "custom",
                      content: (
                        <Button
                          aria-label={`${m.settings_profile_edit_name()}: ${currentName}`}
                          className="max-w-72 gap-xs text-quaternary"
                          hierarchy="link-gray"
                          iconTrailing={
                            <ChevronRightSmallIcon className="size-4 shrink-0" />
                          }
                          onPress={openNameDialog}
                          size="sm"
                        >
                          <span className="max-w-64 truncate">{currentName}</span>
                        </Button>
                      ),
                    },
                  },
                  {
                    id: "account.sign-out",
                    title: m.nav_sign_out(),
                    description: m.settings_sign_out_description(),
                    control: {
                      type: "custom",
                      content: (
                        <Button
                          hierarchy="secondary-gray"
                          onPress={() => auth.signOut()}
                          size="sm"
                        >
                          {m.nav_sign_out()}
                        </Button>
                      ),
                    },
                  },
                ],
              },
            ],
          },
          {
            id: "appearance",
            icon: "appearance",
            label: m.settings_appearance(),
            sections: [
              {
                id: "appearance.interface",
                title: m.settings_appearance(),
                items: [
                  {
                    id: "appearance.theme",
                    title: m.settings_theme(),
                    description: m.settings_theme_description(),
                    control: {
                      type: "custom",
                      content: <ThemePicker />,
                    },
                  },
                  ...(localFonts.supported
                    ? [
                        {
                          id: "appearance.font-family",
                          title: m.settings_font_family(),
                          description: m.settings_font_family_description(),
                          keywords: ["font", "typeface", "字体"],
                          control: {
                            type: "dropdown" as const,
                            width: "fixed" as const,
                            virtualized: true,
                            loading: localFonts.loading,
                            value:
                              fontFamily === null
                                ? defaultFontFamilyKey
                                : `${fontFamilyKeyPrefix}${fontFamily}`,
                            placeholder: m.settings_font_family_select(),
                            items: fontFamilyItems,
                            onOpenChange: (isOpen: boolean) => {
                              if (isOpen && !localFonts.families) localFonts.load();
                            },
                            onChange: (value: string) => {
                              setFontFamily(
                                value.startsWith(fontFamilyKeyPrefix)
                                  ? value.slice(fontFamilyKeyPrefix.length)
                                  : null
                              );
                            },
                          },
                        },
                      ]
                    : []),
                  {
                    id: "appearance.font-size",
                    title: m.settings_font_size(),
                    description: m.settings_font_size_description(),
                    control: {
                      type: "dropdown",
                      value: fontSize,
                      placeholder: m.settings_font_size_select(),
                      items: [
                        {
                          id: "small",
                          label: m.settings_font_size_small(),
                        },
                        { id: "default", label: m.settings_default() },
                        {
                          id: "large",
                          label: m.settings_font_size_large(),
                        },
                      ],
                      onChange: (value) => {
                        if (isFontSizePreference(value)) setFontSize(value);
                      },
                    },
                  },
                  ...(windowMaterial
                    ? [
                        {
                          id: "appearance.window-translucency",
                          title: m.settings_window_translucency(),
                          description: m.settings_window_translucency_description(),
                          keywords: [
                            "transparency",
                            "translucent",
                            "blur",
                            "vibrancy",
                            "透明",
                            "毛玻璃",
                          ],
                          control: {
                            type: "toggle" as const,
                            checked: windowTranslucency,
                            onChange: (event: { target: { checked: boolean } }) => {
                              setWindowTranslucency(event.target.checked);
                            },
                          },
                          content: windowTranslucency ? (
                            <WindowTransparencySetting />
                          ) : null,
                        },
                      ]
                    : []),
                  {
                    id: "appearance.pointer-cursors",
                    title: m.settings_pointer_cursors(),
                    description: m.settings_pointer_cursors_description(),
                    control: {
                      type: "toggle",
                      checked: pointerCursors,
                      onChange: (event) => {
                        setPointerCursors(event.target.checked);
                      },
                    },
                  },
                  {
                    id: "appearance.reduce-motion",
                    title: m.settings_reduce_motion(),
                    description: m.settings_reduce_motion_description(),
                    keywords: ["animation", "motion", "accessibility", "动画"],
                    control: {
                      type: "toggle",
                      checked: reducedMotion,
                      onChange: (event) => {
                        setReducedMotion(event.target.checked);
                      },
                    },
                  },
                ],
              },
            ],
          },
          {
            id: "notifications",
            icon: "notifications",
            label: m.settings_notifications(),
            keywords: ["notification", "通知"],
            sections: [
              {
                id: "notifications.delivery",
                // The page title is the heading; the card stands alone under it.
                title: "",
                items: [
                  {
                    id: "notifications.system",
                    title: m.settings_system_notifications(),
                    description: systemNotificationsDescription,
                    keywords: ["notification", "system", "banner", "通知", "系统"],
                    control: {
                      type: "toggle",
                      checked: systemNotificationsChecked,
                      disabled:
                        !desktopOnly &&
                        (!appPreferencesAvailability.notifications ||
                          !appPreferences ||
                          systemNotificationsStatus === "unsupported" ||
                          appPreferencesPending),
                      onChange: desktopOnly
                        ? () => requestDesktopApp("notifications")
                        : handleSystemNotificationsChange,
                    },
                  },
                  {
                    id: "notifications.router-messages",
                    title: m.settings_router_notifications(),
                    description: m.settings_router_notifications_description(),
                    keywords: ["notification", "router", "message", "通知", "消息"],
                    control: {
                      type: "toggle",
                      checked: appPreferences?.notifyRouterMessages ?? false,
                      disabled:
                        !appPreferencesAvailability.notifications ||
                        !appPreferences ||
                        !systemNotificationsOn ||
                        appPreferencesPending,
                      onChange: (event) => {
                        void updateAppPreferences({
                          notifyRouterMessages: event.target.checked,
                        });
                      },
                    },
                  },
                  {
                    id: "notifications.sound",
                    title: m.settings_notification_sound(),
                    description: m.settings_notification_sound_description(),
                    keywords: ["notification", "sound", "通知", "铃声"],
                    // Auditioning stays available while the toggle is off, so
                    // the sound can be heard before deciding to turn it on.
                    controlLeading: (
                      <Tooltip
                        content={m.settings_notification_sound_preview()}
                        placement="bottom"
                      >
                        <ShellIconButtonControl
                          aria-label={m.settings_notification_sound_preview()}
                          className="size-6 p-xxs"
                          icon={<VolumeFullIcon className="size-4" />}
                          onPress={playNotificationSound}
                        />
                      </Tooltip>
                    ),
                    control: {
                      type: "toggle",
                      checked: appPreferences?.notificationSound ?? false,
                      disabled:
                        !appPreferencesAvailability.notifications ||
                        !appPreferences ||
                        !systemNotificationsOn ||
                        !appPreferences.notifyRouterMessages ||
                        appPreferencesPending,
                      onChange: (event) => {
                        void updateAppPreferences({
                          notificationSound: event.target.checked,
                        });
                      },
                    },
                  },
                ],
              },
            ],
          },
          {
            id: "keyboard-shortcuts",
            icon: "keyboard-shortcuts",
            label: m.settings_keyboard_shortcuts(),
            titleAction: (
              <Button
                className="h-auto px-lg py-xs"
                disabled={appShortcutsAreDefault}
                hierarchy="secondary-gray"
                onPress={() => {
                  const openCommaConflict = electronRuntime
                    ? findAppShortcutConflictForGlobalShortcut(
                        defaultAppShortcutBindings,
                        clientSettings.settings.openCommaShortcut
                      )
                    : undefined;
                  if (openCommaConflict) {
                    setShortcutConflicts({ [openCommaConflict]: true });
                    return;
                  }
                  setShortcutConflicts({});
                  resetAppShortcuts();
                }}
                size="sm"
              >
                {m.settings_reset_shortcuts()}
              </Button>
            ),
            sections: [
              {
                id: "keyboard.general",
                title: m.settings_general_shortcuts(),
                items: settingsShortcutDefinitions.map((definition) => {
                  const copy = generalShortcutCopy[definition.id];
                  return {
                    id: definition.settingsItemId,
                    title: copy.title,
                    description: copy.description,
                    keywords: ["hotkey", "shortcut", "快捷键", copy.title],
                    control: {
                      type: "keybinding" as const,
                      value: appShortcutBindings[definition.id],
                      recordingLabel: m.settings_press_shortcut(),
                      onClear: () => {
                        setShortcutConflicts({});
                        setAppShortcutBinding(definition.id, null);
                      },
                      ...(shortcutConflicts[definition.id]
                        ? {
                            errorMessage: m.settings_shortcut_conflict(),
                          }
                        : {}),
                      onChange: (binding: AppKeybinding) => {
                        const conflictsWithOpenComma =
                          electronRuntime &&
                          (appBindingConflictsWithGlobalShortcut(
                            binding,
                            clientSettings.settings.openCommaShortcut
                          ) ||
                            appBindingConflictsWithGlobalShortcut(
                              binding,
                              quickChatChord
                            ));
                        if (
                          conflictFor(definition.id, binding) ||
                          conflictsWithOpenComma
                        ) {
                          setShortcutConflicts({ [definition.id]: true });
                          return;
                        }
                        setShortcutConflicts({});
                        setAppShortcutBinding(definition.id, binding);
                      },
                    },
                  };
                }),
              },
              {
                id: "keyboard.commands",
                title: m.settings_commands(),
                items: [
                  {
                    id: "keyboard.open-comma",
                    title: m.settings_open_comma(),
                    description: m.settings_open_comma_description(),
                    keywords: ["hotkey", "shortcut", "快捷键"],
                    ...(electronRuntime
                      ? {
                          control: {
                            type: "shortcut" as const,
                            value: clientSettings.settings.openCommaShortcut,
                            disabled: openCommaShortcutPending,
                            recordingLabel: m.settings_press_shortcut(),
                            onClear: () => setOpenCommaShortcut(null),
                            onChange: setOpenCommaShortcut,
                            ...(openCommaShortcutError ||
                            appPreferences?.openCommaShortcutStatus === "unavailable"
                              ? {
                                  errorMessage:
                                    openCommaShortcutError === "conflict"
                                      ? m.settings_shortcut_conflict()
                                      : m.settings_open_comma_shortcut_registration_failed(),
                                }
                              : {}),
                          },
                        }
                      : {}),
                  },
                  // Where Quick Chat is on: a double tap of a modifier (⌘ on macOS,
                  // Ctrl on Windows, by default) or a global shortcut. The App
                  // settings turn it off.
                  ...(appPreferences?.quickChatSupported &&
                  appPreferences.quickChatEnabled
                    ? [
                        {
                          id: "keyboard.quick-chat",
                          title: m.settings_quick_chat(),
                          description: m.settings_quick_chat_description({
                            trigger: quickChatTrigger,
                          }),
                          keywords: [
                            "voice",
                            "dictation",
                            "hotkey",
                            "shortcut",
                            "语音",
                            "快捷键",
                          ],
                          control: {
                            type: "shortcut" as const,
                            value: quickChatShortcut,
                            disabled: quickChatShortcutPending,
                            recordingLabel: m.settings_press_shortcut(),
                            modifierTaps: quickChatOnWindows
                              ? (["control", "alt", "shift"] as const)
                              : (["meta", "alt", "control", "shift"] as const),
                            onModifierTap: setQuickChatShortcut,
                            onChange: setQuickChatShortcut,
                            ...(clientSettings.settings.quickChatShortcut !== null
                              ? {
                                  onClear: () =>
                                    setQuickChatShortcut(
                                      resolveQuickChatShortcut(null, quickChatPlatform)
                                    ),
                                }
                              : {}),
                            ...(quickChatShortcutError ||
                            appPreferences.quickChatShortcutStatus === "unavailable"
                              ? {
                                  errorMessage:
                                    quickChatShortcutError === "conflict"
                                      ? m.settings_shortcut_conflict()
                                      : m.settings_open_comma_shortcut_registration_failed(),
                                }
                              : {}),
                          },
                        },
                      ]
                    : []),
                ],
              },
            ],
          },
          usageBillingCategory,
        ],
      },
      {
        id: "work",
        label: m.settings_group_work(),
        categories: [
          {
            id: "meeting",
            icon: "meeting",
            label: m.settings_meeting(),
            sections: [
              {
                id: "meeting.recording",
                title: m.settings_meeting(),
                items: [
                  {
                    id: "meeting.start",
                    title: m.settings_meeting_start(),
                    description: m.settings_meeting_start_description(),
                    control: {
                      type: "dropdown",
                      value: clientSettings.settings.meetingStartRecording,
                      placeholder: m.settings_meeting_start(),
                      disabled: clientSettingsPending,
                      items: [
                        { id: "reminder", label: m.settings_meeting_reminder() },
                        { id: "auto", label: m.settings_meeting_auto() },
                      ],
                      onChange: (value) => {
                        if (desktopOnly) return requestDesktopApp("meeting");
                        void clientSettings.update({
                          meetingStartRecording: value === "auto" ? "auto" : "reminder",
                        });
                      },
                    },
                  },
                  // The recorder's notch is the macOS app's; Windows' has none to hide.
                  ...(desktopOnly || appPreferencesAvailability.showInNotch
                    ? [
                        {
                          id: "meeting.hide",
                          title: m.settings_meeting_hide(),
                          description: m.settings_meeting_hide_description(),
                          control: {
                            type: "toggle" as const,
                            checked: clientSettings.settings.meetingHideRecorder,
                            disabled: clientSettingsPending,
                            onChange: (event: { target: { checked: boolean } }) => {
                              if (desktopOnly) return requestDesktopApp("meeting");
                              void clientSettings.update({
                                meetingHideRecorder: event.target.checked,
                              });
                            },
                          },
                        },
                      ]
                    : []),
                  {
                    id: "meeting.summary",
                    title: m.settings_meeting_summary(),
                    description: m.settings_meeting_summary_description(),
                    control: {
                      type: "toggle",
                      checked: clientSettings.settings.meetingSmartSummary,
                      disabled: clientSettingsPending,
                      onChange: (event) => {
                        if (desktopOnly) return requestDesktopApp("meeting");
                        void clientSettings.update({
                          meetingSmartSummary: event.target.checked,
                        });
                      },
                    },
                  },
                ],
              },
            ],
          },
          {
            id: "recommendations",
            icon: "recommendations",
            label: m.settings_recommendations(),
            sections: [
              {
                id: "recommendations.personal",
                title: m.settings_routine_personalization(),
                items: [
                  {
                    id: "recommendations.personal.mode",
                    title: m.settings_routine_member_mode(),
                    description: m.settings_routine_member_mode_help(),
                    control: {
                      type: "toggle",
                      checked: recommendations?.settings.relevanceMode === "member",
                      disabled: recommendationsPending || !recommendations,
                      onChange: (event) => {
                        if (!recommendations) return;
                        void saveRecommendationSettings({
                          autoEnableNewSources:
                            recommendations.settings.autoEnableNewSources,
                          schedule: recommendations.settings.schedule,
                          relevanceMode: event.target.checked ? "member" : "generic",
                        });
                      },
                    },
                  },
                  // Proactive messages judge the member's own items, so they
                  // need "Only matters involving me". Only the workspace owner has them.
                  ...(proactive.setting.kind === "owner-only"
                    ? []
                    : [
                        {
                          id: "recommendations.personal.proactive",
                          title: m.settings_routine_proactive(),
                          description:
                            proactive.failure === "load"
                              ? m.settings_routine_proactive_load_failed()
                              : proactive.failure === "save"
                                ? m.settings_routine_proactive_save_failed()
                                : recommendations &&
                                    recommendations.settings.relevanceMode !== "member"
                                  ? m.settings_routine_proactive_needs_member()
                                  : m.settings_routine_proactive_help(),
                          control: {
                            type: "toggle" as const,
                            checked:
                              proactive.setting.kind === "ready" &&
                              proactive.setting.enabled,
                            disabled:
                              proactive.pending ||
                              proactive.setting.kind !== "ready" ||
                              recommendations?.settings.relevanceMode !== "member",
                            onChange: (event: { target: { checked: boolean } }) =>
                              void proactive.toggle(event.target.checked),
                          },
                        },
                      ]),
                ],
              },
              {
                id: "recommendations.schedule",
                title: m.settings_recommendations_schedule(),
                items: [
                  {
                    id: "recommendations.schedule.enabled",
                    title: m.settings_recommendations_schedule(),
                    description: recommendationsSaveError
                      ? m.settings_recommendations_save_failed()
                      : m.settings_recommendations_schedule_description(),
                    control: {
                      type: "toggle",
                      checked: recommendations?.settings.schedule.enabled ?? true,
                      disabled: recommendationsPending || !recommendations,
                      onChange: (event) => {
                        if (!recommendations) return;
                        void saveRecommendationSettings(
                          recommendationSchedulePatch(recommendations.settings, {
                            enabled: event.target.checked,
                          })
                        );
                      },
                    },
                  },
                  {
                    id: "recommendations.schedule.time",
                    title: m.settings_recommendations_time(),
                    description: recommendations
                      ? `${m.settings_recommendations_time_description()} ${recommendations.settings.schedule.timezone}`
                      : m.settings_recommendations_time_description(),
                    control: {
                      type: "dropdown",
                      value: recommendationDeliveryTime,
                      disabled: recommendationsPending || !recommendations,
                      // The list never empties: an empty collection would show
                      // the placeholder in place of the saved time while a
                      // save or load is in flight.
                      items: recommendationDeliveryTimeItems,
                      onChange: (value) => {
                        if (!recommendations) return;
                        const [hour = "8", minute = "0"] = value.split(":");
                        void saveRecommendationSettings(
                          recommendationSchedulePatch(recommendations.settings, {
                            hour: Number(hour),
                            minute: Number(minute),
                          })
                        );
                      },
                    },
                  },
                ],
              },
              {
                id: "recommendations.sources",
                title: m.settings_recommendations_sources(),
                items: [
                  {
                    id: "recommendations.sources.accounts",
                    title: m.settings_routine_manage_accounts(),
                    description: m.settings_routine_manage_accounts_description(),
                    control: {
                      type: "button",
                      label: m.plugins_manage(),
                      onPress: () => {
                        closeSettings();
                        window.location.hash = "/plugins";
                      },
                    },
                  },
                  {
                    id: "recommendations.sources.auto",
                    title: m.settings_recommendations_auto_sources(),
                    description: m.settings_recommendations_auto_sources_description(),
                    control: {
                      type: "toggle",
                      checked: recommendations?.settings.autoEnableNewSources ?? true,
                      disabled: recommendationsPending || !recommendations,
                      onChange: (event) => {
                        if (!recommendations) return;
                        void saveRecommendationSettings({
                          autoEnableNewSources: event.target.checked,
                          schedule: recommendations.settings.schedule,
                        });
                      },
                    },
                  },
                  ...(recommendations?.settings.sources.length
                    ? recommendations.settings.sources.map((source) => ({
                        id: `recommendations.source.${source.connectionId}`,
                        title: source.appName,
                        ...recommendationSourceDescription(source.appId),
                        icon: <LinkProviderIcon source={source} />,
                        control: {
                          type: "toggle" as const,
                          checked: source.enabled,
                          disabled: recommendationsPending,
                          onChange: (event: { target: { checked: boolean } }) => {
                            void saveRecommendationSettings({
                              autoEnableNewSources:
                                recommendations.settings.autoEnableNewSources,
                              schedule: recommendations.settings.schedule,
                              sources: [
                                {
                                  connectionId: source.connectionId,
                                  enabled: event.target.checked,
                                },
                              ],
                            });
                          },
                        },
                      }))
                    : [
                        {
                          id: "recommendations.sources.empty",
                          title: recommendationsError
                            ? m.settings_recommendations_load_failed()
                            : recommendations &&
                                !recommendations.settings.sourcesCheckedAt
                              ? m.settings_recommendations_discovering_sources()
                              : m.settings_recommendations_no_sources(),
                          control: {
                            type: "button" as const,
                            disabled: true,
                            label: "—",
                          },
                        },
                      ]),
                ],
              },
            ],
          },
          {
            id: "channels",
            icon: "channels",
            label: m.settings_channels(),
            keywords: [
              "telegram",
              "tg",
              "wechat",
              "微信",
              "ClawBot",
              "signal",
              "imessage",
              "linear",
              "消息",
            ],
            ...(channelsOverlay ? { overlay: channelsOverlay } : {}),
            sections: [
              {
                id: "telegram.account",
                title: "",
                items: [
                  {
                    id: "telegram.connection",
                    title: m.settings_telegram(),
                    keywords: [
                      m.settings_telegram_connect(),
                      m.settings_telegram_reconnect(),
                      m.settings_telegram_disconnect(),
                      m.settings_telegram_cancel_connect(),
                    ],
                    icon: <TelegramProviderLogo />,
                    integration: telegramConnectionDetails(),
                    ...(telegramDescription
                      ? { description: telegramDescription }
                      : {}),
                    descriptionLoading:
                      !telegramError &&
                      ((!telegramIntegration && !telegramAttempt) ||
                        telegramPending ||
                        Boolean(telegramAttempt)),
                    control: telegramConnectionControl(),
                  },
                ],
              },
              { id: "wechat.account", title: "", items: [wechatItem] },
              { id: "signal.account", title: "", items: [signalChannel.item] },
              ...(imessageItem
                ? [{ id: "imessage.account", title: "", items: [imessageItem] }]
                : []),
              { id: "linear.account", title: "", items: [linearChannel.item] },
            ],
          },
          browserCategory,
          taskLabelsCategory,
          ...(clientSettings.settings.condensedWorkspaceSettingsVisible
            ? [condensedWorkspaceCategory]
            : []),
          models.category,
        ],
      },
      {
        id: "system",
        label: m.settings_group_system(),
        categories: [
          voiceCategory,
          // Computer Use is the macOS app's (its helper): a desktop app
          // elsewhere (Windows) has nothing to grant; the web offers the app.
          ...(desktopOnly || computerUse.available ? [computerUseCategory] : []),
          ...additionalSystemCategories.filter((category) => category.id !== "debug"),
        ],
      },
      {
        id: "archive",
        label: m.settings_archived(),
        categories: [archivedTasksCategory],
      },
      {
        id: "shared",
        label: m.settings_shared(),
        categories: [sharedTasksCategory, miniAppsCategory],
      },
      {
        id: "advanced",
        label: m.settings_group_advanced(),
        categories: [
          routerApiKeysCategory,
          devicesCategory,
          tailscaleCategory,
          {
            id: "debug",
            icon: "debug",
            label: m.settings_debug(),
            sections: [
              {
                id: "debug.session-history",
                title: m.session_history_title(),
                items: [
                  {
                    id: "debug.session-history.enabled",
                    title: m.settings_debug_session_history(),
                    description: m.settings_debug_session_history_description(),
                    control: {
                      type: "toggle",
                      checked: clientSettings.settings.sessionHistoryEnabled,
                      disabled: clientSettingsPending,
                      onChange: (event) =>
                        void clientSettings.update({
                          sessionHistoryEnabled: event.target.checked,
                        }),
                    },
                  },
                ],
              },
              {
                id: "debug.computer-use-screen",
                title: m.settings_debug_computer_use_screen_title(),
                items: [
                  {
                    id: "debug.computer-use-screen.enabled",
                    title: m.settings_debug_computer_use_screen(),
                    description: m.settings_debug_computer_use_screen_description(),
                    control: {
                      type: "toggle",
                      checked: clientSettings.settings.computerUseScreenEnabled,
                      disabled: clientSettingsPending,
                      onChange: (event) =>
                        void clientSettings.update({
                          computerUseScreenEnabled: event.target.checked,
                        }),
                    },
                  },
                ],
              },
              {
                id: "debug.condensed-workspace",
                title: m.settings_condensed_workspace(),
                items: [
                  {
                    id: "debug.condensed-workspace.visible",
                    title: m.settings_debug_condensed_workspace(),
                    description: m.settings_debug_condensed_workspace_description(),
                    control: {
                      type: "toggle",
                      checked:
                        clientSettings.settings.condensedWorkspaceSettingsVisible,
                      disabled: clientSettingsPending,
                      onChange: (event) =>
                        void clientSettings.update({
                          condensedWorkspaceSettingsVisible: event.target.checked,
                        }),
                    },
                  },
                ],
              },
              {
                id: "debug.voice-labs",
                title: m.settings_debug_voice_labs_title(),
                items: [
                  {
                    id: "debug.voice-labs.enabled",
                    title: m.settings_debug_voice_labs(),
                    description: m.settings_debug_voice_labs_description(),
                    control: {
                      type: "toggle",
                      checked: clientSettings.settings.voiceLabsEnabled,
                      disabled: clientSettingsPending,
                      onChange: (event) =>
                        void clientSettings.update({
                          voiceLabsEnabled: event.target.checked,
                        }),
                    },
                  },
                ],
              },
              ...additionalSystemCategories
                .filter((category) => category.id === "debug")
                .flatMap((category) => category.sections),
            ],
          },
        ],
      },
    ],
  });
  // A guest account has no profile to edit: it can sign up or be discarded.
  const guestAccountItems: SettingsPanelItem[] = [
    {
      id: "account.guest-sign-up",
      title: m.guest_banner_sign_up(),
      description: m.settings_guest_sign_up_description(),
      control: {
        type: "custom",
        content: (
          <Button
            disabled={!auth.beginGuestSignUp}
            hierarchy="primary"
            isPending={guestSignUpPending}
            onPress={beginGuestSignUp}
            size="sm"
          >
            {m.guest_banner_sign_up()}
          </Button>
        ),
      },
    },
    {
      id: "account.guest-discard",
      title: m.settings_guest_discard(),
      description: m.settings_guest_discard_description(),
      control: {
        type: "custom",
        content: (
          <Button
            hierarchy="secondary-gray"
            onPress={() => setGuestDiscardOpen(true)}
            size="sm"
          >
            {m.settings_guest_discard()}
          </Button>
        ),
      },
    },
  ];
  const registry = guest
    ? createSettingsRegistry({
        groups: guestSettingsGroups(accountRegistry.groups, guestAccountItems),
      })
    : accountRegistry;

  return (
    <>
      <SettingsDialog
        activeCategoryId={activeCategoryId}
        ariaLabel={m.settings_sections()}
        closeLabel={m.settings_close()}
        contentAriaLabel={m.shell_settings_content()}
        emptySearchDescription={m.settings_search_empty_description()}
        emptySearchTitle={m.settings_search_empty()}
        onActiveCategoryChange={setActiveCategoryId}
        onClose={closeSettings}
        registry={registry}
        searchAriaLabel={m.settings_search()}
        searchPlaceholder={m.settings_search_placeholder()}
      >
        {commandPalette?.paletteElement}
      </SettingsDialog>
      {telegramReconnectOpen && activeCategoryId === "channels" ? (
        <Dialog
          isOpen
          isDismissable
          onOpenChange={setTelegramReconnectOpen}
          title={m.settings_telegram_replace_title()}
          description={m.settings_telegram_replace_description()}
          actions={[
            {
              label: m.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setTelegramReconnectOpen(false),
            },
            {
              label: m.settings_telegram_reconnect(),
              hierarchy: "primary",
              disabled: telegramPending || !telegramWorkspaceId,
              onPress: () => {
                setTelegramReconnectOpen(false);
                void connectTelegram();
              },
            },
          ]}
        />
      ) : null}
      {guestDiscardOpen && guest ? (
        <Dialog
          isOpen
          isDismissable
          onOpenChange={setGuestDiscardOpen}
          title={m.settings_guest_discard_confirm_title()}
          description={m.settings_guest_discard_confirm_description()}
          actions={[
            {
              label: m.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setGuestDiscardOpen(false),
            },
            {
              label: m.settings_guest_discard(),
              hierarchy: "destructive",
              onPress: () => {
                setGuestDiscardOpen(false);
                auth.signOut();
              },
            },
          ]}
        />
      ) : null}
      {notificationPermissionDialogOpen ? (
        <Dialog
          isOpen
          isDismissable
          onOpenChange={setNotificationPermissionDialogOpen}
          title={m.settings_system_notifications_permission_title()}
          description={m.settings_system_notifications_permission_description()}
          actions={[
            {
              label: m.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setNotificationPermissionDialogOpen(false),
            },
            {
              label: m.settings_system_notifications_open_system_settings(),
              hierarchy: "primary",
              onPress: () => {
                setNotificationPermissionDialogOpen(false);
                void openNotificationSettings();
              },
            },
          ]}
        />
      ) : null}
      {keepAwakeApprovalDialogOpen ? (
        <Dialog
          isOpen
          isDismissable
          onOpenChange={(open) => {
            if (!open) cancelKeepAwakeApproval();
          }}
          title={m.settings_keep_awake_lid_closed_approval_title()}
          description={m.settings_keep_awake_lid_closed_approval_description()}
          actions={[
            {
              label: m.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              onPress: cancelKeepAwakeApproval,
            },
            {
              label: m.settings_keep_awake_lid_closed_open_login_items(),
              hierarchy: "primary",
              onPress: () => {
                setKeepAwakeApprovalDialogOpen(false);
                void openLoginItemsSettings();
              },
            },
          ]}
        />
      ) : null}
      {avatarCropFile ? (
        <AvatarCropDialog
          file={avatarCropFile}
          onCancel={() => setAvatarCropFile(undefined)}
          onConfirm={uploadAvatar}
        />
      ) : null}
      {instructionsOpen ? (
        <RouterInstructionsDialog
          instructions={instructions}
          onClose={() => setInstructionsOpen(false)}
        />
      ) : null}
      {nameDialogOpen ? (
        <Dialog
          actions={[
            {
              label: m.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              onPress: closeNameDialog,
            },
            {
              label: m.settings_profile_save(),
              hierarchy: "primary",
              disabled: !normalizedName || nameInvalid || nameUnchanged,
              onPress: () => void saveName(),
            },
          ]}
          description={m.settings_profile_name_description()}
          input={{
            "aria-label": m.settings_profile_name(),
            autoFocus: true,
            ...(nameMessage
              ? { errorMessage: nameMessage }
              : nameInvalid
                ? { errorMessage: m.settings_profile_name_too_long() }
                : {}),
            maxLength: 65,
            onChange: (event) => {
              setName(event.target.value);
              setNameError(undefined);
            },
            value: name,
          }}
          isDismissable
          isOpen
          onOpenChange={(open) => {
            if (!open) closeNameDialog();
          }}
          title={m.settings_profile_name()}
          variant="input"
        />
      ) : null}
    </>
  );
}
