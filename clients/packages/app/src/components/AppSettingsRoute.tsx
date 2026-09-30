import { useBrowserSettingsCategory } from "./chat/useBrowserSettingsCategory";
import { useAirDropNameSetting } from "./useAirDropNameSetting";
import { useProactiveSetting } from "./recommendations/useProactiveSetting";
import { useComputeNodeCategory } from "./useComputeNodeCategory";
import { useComputerUsePermissions } from "./useComputerUsePermissions";
import { useWeChatIntegration } from "./useWeChatIntegration";
import { useSubscriptionAccountsSections } from "./useSubscriptionAccountsSections";
import { useModelTemplatesCategory } from "./useModelTemplatesCategory";
import { useArchivedTasksCategory } from "./tasks/useArchivedTasksCategory";
import { useSharedTasksCategory } from "./tasks/useSharedTasksCategory";
import { useDeviceSettingsCategory } from "./devices/useDeviceSettingsCategory";
import { useTaskLabelsCategory } from "./tasks/useTaskLabelsCategory";
import { useRouterApiKeysCategory } from "./inbound-api/useRouterApiKeysCategory";
import { useVoiceSettingsCategory } from "./voice/useVoiceSettingsCategory";
import { useSignalIntegration } from "./signal/useSignalIntegration";
import type { CommaLocalePreference } from "@comma/i18n";
import {
  getNativeBridge,
  notchSideWidthRange,
  type SideChatShortcut,
} from "@comma/native-bridge";
import { useEffect, useMemo, useRef, useState } from "react";
import { useCommaI18n, useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  ChevronRightSmallIcon,
  createSettingsRegistry,
  Dialog,
  fontFamily as fontFamilyTokens,
  NotchWidthSetting,
  SettingsDialog,
  TelegramProviderLogo,
  Tooltip,
  VolumeFullIcon,
  type AppKeybinding,
  type DropdownItem,
  type SettingsCategoryDefinition,
  type SettingsControl,
  type SettingsPanelItem,
} from "@comma/ui";
import {
  type CommaRecommendationEnvelope,
  type CommaRecommendationSettingsPatch,
  type CommaTelegramIntegrationState,
  type CommaUserProfile,
} from "../api";
import { ThemePicker } from "./commaCustomThemeStudio";
import {
  commaFontFamilyStack,
  useCommaAppearance,
  type CommaFontSizePreference,
} from "./commaAppearance";
import { useLocalFontFamilies } from "./localFontFamilies";
import { useCommaSideChatShortcut } from "./commaSideChatShortcut";
import { useCommaAppPreferences } from "./commaAppPreferences";
import { isLabelProposalPolicy } from "./tasks/labelProposalPolicy";
import {
  useCommaClientSettings,
  useCommaClientSettingsPending,
} from "./commaClientSettings";
import { playNotificationSound } from "./notifications/notificationSound";
import { ShellIconButtonControl } from "./ShellIconButton";
import { isElectronSideChatRuntime } from "../runtime-side-chat/nativeSideChat";
import { driveSynchronicityAvailable } from "./drive/driveSynchronicityBackend";
import { useCommaAuth } from "./auth-context";
import { useOptionalChatActionRegistry } from "./chat/ChatProvider";
import { UserAvatar } from "./UserAvatar";
import { LinkProviderIcon } from "./links/linkPreviewCards";
import { useProfileAvatarUrl } from "./useProfileAvatarUrl";
import { useOptionalCommandPalette } from "./search/CommandPaletteContext";
import { useCommaSettingsOverlay } from "./settingsOverlay";
import {
  appShortcutDefinitions,
  type AppShortcutId,
} from "./shortcuts/appShortcutRegistry";
import { useCommaAppShortcuts } from "./shortcuts/commaAppShortcuts";
import {
  appBindingConflictsWithSideChatShortcut,
  findAppShortcutConflictForSideChat,
  sameGlobalShortcut,
} from "./shortcuts/sideChatShortcutConflict";
import { readActiveWorkspaceId } from "./activeWorkspace";
import { useUsageBillingCategory } from "./billing/useUsageBillingCategory";
import {
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../runtime-chat/nativePlatformActions";

const localePreferences = ["system", "en", "zh-CN"] as const;
const fontSizePreferences = ["small", "default", "large"] as const;
// Font menu keys. The prefix keeps a family named "default" apart from Comma's own.
const defaultFontFamilyKey = "default";
const fontFamilyKeyPrefix = "family:";
const avatarTypes = ["image/jpeg", "image/png", "image/webp"];
const maxAvatarBytes = 102_400;
// Initial source discovery is one provider listing with an 8-second transport
// budget; wait it out here instead of reporting a load failure early.
const recommendationSourcePollAttempts = 15;
const recommendationSourcePollDelayMs = 800;
const telegramConnectPollAttempts = 200;
const telegramConnectPollDelayMs = 1_500;

function deviceTimeZone() {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

function formatDeliveryTime(hour: number, minute: number) {
  return `${hour.toString().padStart(2, "0")}:${minute.toString().padStart(2, "0")}`;
}

function abortableDelay(milliseconds: number, signal: AbortSignal) {
  return new Promise<void>((resolve, reject) => {
    if (signal.aborted) {
      reject(new DOMException("Aborted", "AbortError"));
      return;
    }
    let timeout: number;
    const onAbort = () => {
      window.clearTimeout(timeout);
      reject(new DOMException("Aborted", "AbortError"));
    };
    timeout = window.setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, milliseconds);
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

function isLocalePreference(value: string): value is CommaLocalePreference {
  return localePreferences.some((preference) => preference === value);
}

function isFontSizePreference(value: string): value is CommaFontSizePreference {
  return fontSizePreferences.some((preference) => preference === value);
}

// Read from the hash rather than the router: this route also renders in the
// Side Chat settings window and in unit tests, neither of which has a
// RouterProvider above it.
function readLinkedSettingsCategory(): string | undefined {
  if (typeof window === "undefined") return undefined;
  const hash = window.location.hash;
  const queryStart = hash.indexOf("?");
  if (queryStart < 0) return undefined;
  const category = new URLSearchParams(hash.slice(queryStart + 1)).get("category");
  return category ? category : undefined;
}

function useLinkedSettingsCategory(): string | undefined {
  const [category, setCategory] = useState(readLinkedSettingsCategory);
  useEffect(() => {
    if (typeof window === "undefined") return undefined;
    const sync = () => setCategory(readLinkedSettingsCategory());
    sync();
    window.addEventListener("hashchange", sync);
    window.addEventListener("popstate", sync);
    return () => {
      window.removeEventListener("hashchange", sync);
      window.removeEventListener("popstate", sync);
    };
  }, []);
  return category;
}

export function AppSettingsRoute({
  additionalSystemCategories = [],
}: {
  additionalSystemCategories?: readonly SettingsCategoryDefinition[];
}) {
  // `/#/settings?category=<id>` opens Settings on that category (the Routines
  // menu links straight to Routines). Local state still owns the
  // selection afterwards, so clicking another category does not fight the URL.
  const linkedCategoryId = useLinkedSettingsCategory();
  const [activeCategoryId, setActiveCategoryId] = useState(
    () => linkedCategoryId ?? "general"
  );
  useEffect(() => {
    if (linkedCategoryId) setActiveCategoryId(linkedCategoryId);
  }, [linkedCategoryId]);
  const m = useCommaMessages();
  const clientSettings = useCommaClientSettings();
  const clientSettingsPending = useCommaClientSettingsPending();
  const auth = useCommaAuth();
  const { closeSettings } = useCommaSettingsOverlay();
  // The palette opened over Settings renders inside the modal, so its focus
  // scope nests in the modal's rather than contending with it.
  const commandPalette = useOptionalCommandPalette();
  const claimPaletteHost = commandPalette?.claimPaletteHost;
  useEffect(() => claimPaletteHost?.(), [claimPaletteHost]);
  // Settings is an overlay on the product session, so it reads and writes
  // through that session's API and shares its caches: a label renamed here is
  // the name every page shows, and the labels the pages already read show at
  // once. A render without a product session uses the signed-in client.
  const api = useOptionalChatActionRegistry()?.api ?? auth.api;
  const browserCategory = useBrowserSettingsCategory(api);
  const subscriptionAccounts = useSubscriptionAccountsSections(
    api,
    activeCategoryId === "models"
  );
  const modelTemplates = useModelTemplatesCategory(
    api,
    activeCategoryId === "models",
    subscriptionAccounts.modelCatalogRevision
  );
  const devicesCategory = useDeviceSettingsCategory(
    api,
    activeCategoryId === "devices"
  );
  const archivedTasksCategory = useArchivedTasksCategory(
    api,
    activeCategoryId === "archived-tasks"
  );
  const sharedTasksCategory = useSharedTasksCategory(
    api,
    activeCategoryId === "shared-tasks"
  );
  const { category: taskLabelsCategory, approvalPolicy: labelProposalPolicy } =
    useTaskLabelsCategory(
      api,
      activeCategoryId === "labels",
      activeCategoryId === "general"
    );
  const routerApiKeysCategory = useRouterApiKeysCategory(
    api,
    activeCategoryId === "inbound-api"
  );
  const voiceCategory = useVoiceSettingsCategory(api, activeCategoryId === "voice");
  const usageBillingCategory = useUsageBillingCategory(
    api,
    activeCategoryId === "usage-billing"
  );
  const proactive = useProactiveSetting(api, activeCategoryId === "recommendations");
  const [profile, setProfile] = useState<CommaUserProfile>();
  const [name, setName] = useState(auth.userDisplayName ?? "");
  const [nameDialogOpen, setNameDialogOpen] = useState(false);
  const [notificationPermissionDialogOpen, setNotificationPermissionDialogOpen] =
    useState(false);
  const [profileLoading, setProfileLoading] = useState(false);
  const [avatarPending, setAvatarPending] = useState(false);
  const [namePending, setNamePending] = useState(false);
  const [avatarError, setAvatarError] = useState<string>();
  const [nameError, setNameError] = useState<string>();
  const [recommendationWorkspaceId, setRecommendationWorkspaceId] = useState<string>();
  const [recommendations, setRecommendations] = useState<CommaRecommendationEnvelope>();
  const [recommendationsPending, setRecommendationsPending] = useState(false);
  const [recommendationsError, setRecommendationsError] = useState(false);
  const [recommendationsSaveError, setRecommendationsSaveError] = useState(false);
  const [telegramWorkspaceId, setTelegramWorkspaceId] = useState<string>();
  const wechatItem = useWeChatIntegration(
    api,
    telegramWorkspaceId,
    activeCategoryId === "channels"
  );
  const signalChannel = useSignalIntegration(
    api,
    telegramWorkspaceId,
    activeCategoryId === "channels"
  );
  const [telegramReconnectOpen, setTelegramReconnectOpen] = useState(false);
  const [telegramIntegration, setTelegramIntegration] =
    useState<CommaTelegramIntegrationState>();
  const [telegramPending, setTelegramPending] = useState(false);
  const [telegramError, setTelegramError] = useState(false);
  const [telegramAttempt, setTelegramAttempt] = useState<{ state: string }>();
  const telegramActionController = useRef<AbortController | undefined>(undefined);
  const fileInput = useRef<HTMLInputElement>(null);
  const avatarRevision = profile
    ? (profile.avatar_id ?? undefined)
    : auth.avatarRevision;
  const avatarUrl = useProfileAvatarUrl(avatarRevision);
  const { locale, localePreference, setLocalePreference } = useCommaI18n();
  const {
    fontFamily,
    fontSize,
    pointerCursors,
    reducedMotion,
    setFontFamily,
    setFontSize,
    setPointerCursors,
    setReducedMotion,
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
    registrationFailed: sideChatShortcutRegistrationFailed,
    registrationPending: sideChatShortcutRegistrationPending,
    setShortcut: setSideChatShortcut,
    shortcut: sideChatShortcut,
  } = useCommaSideChatShortcut();
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
  const [sideChatShortcutConflict, setSideChatShortcutConflict] = useState(false);
  const electronRuntime = isElectronSideChatRuntime();
  const [openCommaShortcutError, setOpenCommaShortcutError] = useState<
    "conflict" | "registration"
  >();
  const [openCommaShortcutPending, setOpenCommaShortcutPending] = useState(false);
  const setOpenCommaShortcut = async (shortcut: SideChatShortcut | null) => {
    if (
      findAppShortcutConflictForSideChat(appShortcutBindings, shortcut) ||
      sameGlobalShortcut(shortcut, sideChatShortcut)
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
  const computeNodeCategory = useComputeNodeCategory(
    api,
    activeCategoryId === "compute-node"
  );
  const computerUse = useComputerUsePermissions(activeCategoryId === "computer-use");
  const permissionStatus = (granted: boolean | undefined) =>
    !computerUse.available
      ? m.settings_computer_use_macos_only()
      : granted === undefined
        ? m.settings_computer_use_unknown()
        : granted
          ? m.settings_computer_use_granted()
          : m.settings_computer_use_missing();

  // The web client shows no Drive, so it offers no shortcut to it.
  const settingsShortcutDefinitions = appShortcutDefinitions.filter(
    (definition) => definition.id !== "go-drive" || driveSynchronicityAvailable()
  );
  const generalShortcutCopy: Record<
    AppShortcutId,
    { title: string; description: string }
  > = {
    "go-settings": {
      title: m.settings_go_settings(),
      description: m.settings_go_settings_description(),
    },
    "go-comma-assistant": {
      title: m.settings_go_comma_assistant(),
      description: m.settings_go_comma_assistant_description(),
    },
    "go-search": {
      title: m.settings_go_search(),
      description: m.settings_go_search_description(),
    },
    "go-inbox": {
      title: m.settings_go_inbox(),
      description: m.settings_go_inbox_description(),
    },
    "go-drive": {
      title: m.settings_go_drive(),
      description: m.settings_go_drive_description(),
    },
    "go-tasks": {
      title: m.settings_go_tasks(),
      description: m.settings_go_tasks_description(),
    },
    "go-plugins": {
      title: m.settings_go_plugins(),
      description: m.settings_go_plugins_description(),
    },
    "toggle-left-sidebar": {
      title: m.settings_toggle_left_sidebar(),
      description: m.settings_toggle_left_sidebar_description(),
    },
    "history-back": {
      title: m.settings_history_back(),
      description: m.settings_history_back_description(),
    },
    "history-forward": {
      title: m.settings_history_forward(),
      description: m.settings_history_forward_description(),
    },
    "toggle-right-sidebar": {
      title: m.settings_toggle_right_sidebar(),
      description: m.settings_toggle_right_sidebar_description(),
    },
  };
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

  useEffect(() => {
    if (activeCategoryId !== "profile" || profile) return;
    const controller = new AbortController();
    setProfileLoading(true);
    setAvatarError(undefined);
    setNameError(undefined);

    void api
      .getProfile({ signal: controller.signal })
      .then((next) => {
        setProfile(next);
        setName(next.name ?? "");
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          const message = m.settings_profile_load_failed();
          setAvatarError(message);
          setNameError(message);
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) setProfileLoading(false);
      });

    return () => controller.abort();
  }, [activeCategoryId, api, m, profile]);

  useEffect(() => {
    if (activeCategoryId !== "recommendations") {
      return;
    }
    // The Settings route can be the first recommendations surface opened in a
    // session. Report the resolved app locale on every category activation so
    // this path reconciles the durable renderer just like the Home rail does.
    const controller = new AbortController();
    setRecommendationsPending(true);
    setRecommendationsError(false);
    setRecommendationsSaveError(false);

    void api
      .listWorkspaces({ signal: controller.signal })
      .then(async (workspaces) => {
        const preferredWorkspaceId = readActiveWorkspaceId();
        const workspace =
          workspaces.find((candidate) => candidate.id === preferredWorkspaceId) ??
          workspaces[0];
        if (!workspace) throw new Error("workspace unavailable");
        let envelope = await api.getRecommendations(workspace.id, {
          locale,
          signal: controller.signal,
          timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        });

        // The first read creates the projection and enqueues bounded source
        // discovery. Keep this screen in its honest loading state until that
        // initial discovery finishes instead of rendering a false empty state;
        // a discovery that outlasts these checks is still discovering, not a
        // failed load.
        for (
          let attempt = 0;
          !envelope.settings.sourcesCheckedAt &&
          attempt < recommendationSourcePollAttempts;
          attempt += 1
        ) {
          await abortableDelay(recommendationSourcePollDelayMs, controller.signal);
          envelope = await api.getRecommendations(workspace.id, {
            locale,
            signal: controller.signal,
            timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
          });
        }

        if (!controller.signal.aborted) {
          setRecommendationWorkspaceId(workspace.id);
          setRecommendations(envelope);
        }
      })
      .catch(() => {
        if (!controller.signal.aborted) setRecommendationsError(true);
      })
      .finally(() => {
        if (!controller.signal.aborted) setRecommendationsPending(false);
      });

    return () => controller.abort();
  }, [activeCategoryId, api, locale]);

  useEffect(() => {
    if (activeCategoryId !== "channels") return;
    const controller = new AbortController();
    setTelegramError(false);

    setTelegramWorkspaceId(undefined);
    setTelegramReconnectOpen(false);
    setTelegramIntegration(undefined);
    setTelegramAttempt(undefined);
    setTelegramPending(false);

    void api
      .listWorkspaces({ signal: controller.signal })
      .then((workspaces) => {
        if (controller.signal.aborted) return;
        // Comma v1 owns exactly one workspace per account. Do not turn invalid
        // account data or a navigation hint into a user-facing scope choice.
        if (workspaces.length !== 1) {
          setTelegramError(true);
          return;
        }
        setTelegramWorkspaceId(workspaces[0]?.id);
      })
      .catch(() => {
        if (!controller.signal.aborted) setTelegramError(true);
      });

    return () => controller.abort();
  }, [activeCategoryId, api]);

  useEffect(() => {
    if (activeCategoryId !== "channels" || !telegramWorkspaceId) return;
    const controller = new AbortController();
    setTelegramPending(true);
    setTelegramError(false);
    setTelegramIntegration(undefined);
    setTelegramAttempt(undefined);

    void api
      .getTelegramIntegration(telegramWorkspaceId, { signal: controller.signal })
      .then((state) => {
        if (!controller.signal.aborted) setTelegramIntegration(state);
      })
      .catch(() => {
        if (!controller.signal.aborted) setTelegramError(true);
      })
      .finally(() => {
        if (!controller.signal.aborted) setTelegramPending(false);
      });

    return () => {
      controller.abort();
      // Reads and user actions belong to this workspace view. Cancellation
      // fences late UI completions; it cannot undo a server-side mutation.
      telegramActionController.current?.abort();
      telegramActionController.current = undefined;
    };
  }, [activeCategoryId, api, telegramWorkspaceId]);

  const pollTelegramIntegrationUntilLinked = async (
    workspaceId: string,
    controller: AbortController,
    previousLink: CommaTelegramIntegrationState["link"],
    popup?: Window
  ) => {
    for (let attempt = 0; attempt < telegramConnectPollAttempts; attempt += 1) {
      const state = await api.getTelegramIntegration(workspaceId, {
        signal: controller.signal,
      });
      if (controller.signal.aborted) return false;
      setTelegramIntegration(state);
      if (
        state.link &&
        state.connection_active !== false &&
        (!previousLink ||
          state.link.connection_id !== previousLink.connection_id ||
          state.link.telegram_user_id !== previousLink.telegram_user_id ||
          state.link.updated_at !== previousLink.updated_at)
      ) {
        setTelegramAttempt(undefined);
        return true;
      }
      if (popup?.closed) throw new Error("Telegram authorization window was closed");
      await abortableDelay(telegramConnectPollDelayMs, controller.signal);
    }
    return false;
  };

  const connectTelegram = async () => {
    if (!telegramWorkspaceId || telegramPending) return;
    telegramActionController.current?.abort();
    const controller = new AbortController();
    telegramActionController.current = controller;
    setTelegramPending(true);
    setTelegramError(false);
    let attemptState: string | undefined;
    let popup: Window | undefined;

    try {
      popup = await openNativePlatformExternalUrlFromUserAction(async () => {
        const attempt = await api.startTelegramConnect(telegramWorkspaceId);
        controller.signal.throwIfAborted();
        const state = new URL(attempt.authorization_url).searchParams.get("state");
        if (!state) throw new Error("Telegram login state is missing");
        attemptState = state;
        setTelegramAttempt({ state });
        return attempt.authorization_url;
      });

      controller.signal.throwIfAborted();
      const linked = await pollTelegramIntegrationUntilLinked(
        telegramWorkspaceId,
        controller,
        telegramIntegration?.link ?? null,
        popup
      );
      if (!linked && !controller.signal.aborted) setTelegramError(true);
    } catch {
      if (!controller.signal.aborted) {
        setTelegramError(true);
        if (popup?.closed && attemptState) {
          try {
            await api.cancelTelegramConnect(telegramWorkspaceId, {
              state: attemptState,
            });
            if (!controller.signal.aborted) setTelegramAttempt(undefined);
          } catch {
            // Keep explicit cancellation available if revocation was not confirmed.
          }
        }
      }
    } finally {
      if (!controller.signal.aborted) setTelegramPending(false);
      if (telegramActionController.current === controller)
        telegramActionController.current = undefined;
    }
  };

  const cancelTelegramConnect = async () => {
    if (!telegramWorkspaceId || !telegramAttempt) return;
    telegramActionController.current?.abort();
    const controller = new AbortController();
    telegramActionController.current = controller;
    setTelegramPending(true);
    setTelegramError(false);
    try {
      await api.cancelTelegramConnect(telegramWorkspaceId, telegramAttempt);
      const state = await api.getTelegramIntegration(telegramWorkspaceId, {
        signal: controller.signal,
      });
      controller.signal.throwIfAborted();
      setTelegramIntegration(state);
      setTelegramAttempt(undefined);
    } catch {
      if (!controller.signal.aborted) setTelegramError(true);
    } finally {
      if (!controller.signal.aborted) setTelegramPending(false);
    }
  };

  const disconnectTelegram = async () => {
    if (!telegramWorkspaceId || telegramPending) return;
    telegramActionController.current?.abort();
    const controller = new AbortController();
    telegramActionController.current = controller;
    setTelegramPending(true);
    setTelegramError(false);
    try {
      await api.disconnectTelegram(telegramWorkspaceId);
      controller.signal.throwIfAborted();
      const state = await api.getTelegramIntegration(telegramWorkspaceId, {
        signal: controller.signal,
      });
      controller.signal.throwIfAborted();
      setTelegramIntegration(state);
      setTelegramAttempt(undefined);
    } catch {
      if (!controller.signal.aborted) setTelegramError(true);
    } finally {
      if (!controller.signal.aborted) setTelegramPending(false);
      if (telegramActionController.current === controller) {
        telegramActionController.current = undefined;
      }
    }
  };

  function telegramConnectionDescription(): string {
    if (telegramError) return m.settings_telegram_action_failed();
    if (!telegramIntegration && !telegramAttempt) return m.settings_telegram_loading();
    if (telegramPending || telegramAttempt) return m.settings_telegram_connecting();

    const link = telegramIntegration?.link;
    if (link && telegramIntegration?.connection_active === false)
      return m.settings_telegram_repair_required();

    return telegramIntegration?.configured
      ? m.settings_telegram_description()
      : m.settings_telegram_unavailable();
  }

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
    setRecommendationsPending(true);
    setRecommendationsSaveError(false);
    try {
      setRecommendations(
        await api.updateRecommendationSettings(recommendationWorkspaceId, patch)
      );
    } catch {
      // The controls keep reading the last envelope, which the refused write
      // did not change; the schedule row says the save failed.
      setRecommendationsSaveError(true);
    } finally {
      setRecommendationsPending(false);
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

  const publishProfile = (next: CommaUserProfile) => {
    setProfile(next);
    setName(next.name ?? "");
    auth.publishProfile?.(next);
  };

  const runAvatarOperation = async (operation: () => Promise<CommaUserProfile>) => {
    setAvatarPending(true);
    setAvatarError(undefined);
    try {
      publishProfile(await operation());
    } catch {
      setAvatarError(m.settings_profile_save_failed());
    } finally {
      setAvatarPending(false);
    }
  };

  const uploadAvatar = (file?: File) => {
    if (!file) return;
    if (!avatarTypes.includes(file.type) || file.size > maxAvatarBytes) {
      setAvatarError(m.settings_profile_avatar_help());
      return;
    }
    void runAvatarOperation(() => api.uploadAvatar(file));
  };

  const saveName = async () => {
    const nextName = name.trim();
    if (!nextName || nextName.length > 64) return;

    setNamePending(true);
    setNameError(undefined);
    try {
      publishProfile(await api.updateProfile({ name: nextName }));
      setNameDialogOpen(false);
    } catch {
      setNameError(m.settings_profile_save_failed());
    } finally {
      setNamePending(false);
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
                  ).catch(() => setTelegramError(true));
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
    if (namePending) return;
    setName(profile?.name ?? auth.userDisplayName ?? "");
    setNameError(undefined);
    setNameDialogOpen(false);
  };
  // The OS decides whether Comma may notify at all. When it says no, the master
  // switch still reads as off and stays interactive: turning it on opens a
  // dialog that jumps to System Settings. The stored choice is kept for when
  // the OS allows it again.
  const systemNotificationsStatus =
    appPreferences?.systemNotificationsStatus ?? "available";
  const systemNotificationsBlocked = systemNotificationsStatus !== "available";
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
  const registry = createSettingsRegistry({
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
                      value: localePreference,
                      placeholder: m.settings_language_select(),
                      items: [
                        { id: "system", label: m.settings_language_system() },
                        { id: "en", label: m.settings_language_english() },
                        {
                          id: "zh-CN",
                          label: m.settings_language_simplified_chinese(),
                        },
                      ],
                      onChange: (value) => {
                        if (isLocalePreference(value)) {
                          setLocalePreference(value);
                        }
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
                        !appPreferencesAvailability.launchAtLogin ||
                        !appPreferences ||
                        appPreferences.launchAtLoginStatus === "requires-approval" ||
                        appPreferencesPending,
                      onChange: (event) => {
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
                        !appPreferencesAvailability.showInMenuBar ||
                        !appPreferences ||
                        appPreferencesPending,
                      onChange: (event) => {
                        void updateAppPreferences({
                          showInMenuBar: event.target.checked,
                        });
                      },
                    },
                  },
                  {
                    id: "app.dock",
                    title: m.settings_show_in_dock(),
                    description: m.settings_show_in_dock_description(),
                    control: {
                      type: "toggle",
                      checked: appPreferences?.showInDock ?? false,
                      disabled:
                        !appPreferencesAvailability.showInDock ||
                        !appPreferences ||
                        appPreferencesPending,
                      onChange: (event) => {
                        void updateAppPreferences({
                          showInDock: event.target.checked,
                        });
                      },
                    },
                  },
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
            ],
          },
          {
            id: "profile",
            icon: "profile",
            label: m.settings_profile(),
            sections: [
              {
                id: "profile.account",
                title: m.settings_account(),
                items: [
                  {
                    id: "account.avatar",
                    title: m.settings_profile_avatar(),
                    description: m.settings_profile_avatar_help(),
                    ...(avatarError ? { errorMessage: avatarError } : {}),
                    control: {
                      type: "custom",
                      content: (
                        <div className="flex items-center">
                          <div className="flex items-center">
                            <Button
                              aria-label={m.settings_profile_choose_avatar()}
                              {...(avatarError
                                ? {
                                    "aria-describedby": "settings-error-account.avatar",
                                  }
                                : {})}
                              className="size-10 rounded-full p-0 [&>span]:p-0"
                              disabled={profileLoading || avatarPending}
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
                                uploadAvatar(event.target.files?.[0]);
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
                        !appPreferencesAvailability.notifications ||
                        !appPreferences ||
                        systemNotificationsStatus === "unsupported" ||
                        appPreferencesPending,
                      onChange: handleSystemNotificationsChange,
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
                disabled={appShortcutsAreDefault || sideChatShortcutRegistrationPending}
                hierarchy="secondary-gray"
                onPress={() => {
                  const sideChatConflict = electronRuntime
                    ? (findAppShortcutConflictForSideChat(
                        defaultAppShortcutBindings,
                        sideChatShortcut
                      ) ??
                      findAppShortcutConflictForSideChat(
                        defaultAppShortcutBindings,
                        clientSettings.settings.openCommaShortcut
                      ))
                    : undefined;
                  if (sideChatConflict) {
                    setShortcutConflicts({ [sideChatConflict]: true });
                    return;
                  }
                  setShortcutConflicts({});
                  setSideChatShortcutConflict(false);
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
                      disabled: electronRuntime && sideChatShortcutRegistrationPending,
                      recordingLabel: m.settings_press_shortcut(),
                      onClear: () => {
                        setShortcutConflicts({});
                        setAppShortcutBinding(definition.id, null);
                        setSideChatShortcutConflict(false);
                      },
                      ...(shortcutConflicts[definition.id]
                        ? {
                            errorMessage: m.settings_shortcut_conflict(),
                          }
                        : {}),
                      onChange: (binding: AppKeybinding) => {
                        const conflictsWithSideChat =
                          electronRuntime &&
                          (appBindingConflictsWithSideChatShortcut(
                            binding,
                            sideChatShortcut
                          ) ||
                            appBindingConflictsWithSideChatShortcut(
                              binding,
                              clientSettings.settings.openCommaShortcut
                            ));
                        const conflict =
                          conflictFor(definition.id, binding) ??
                          (conflictsWithSideChat ? "side-chat" : undefined);
                        if (conflict) {
                          setShortcutConflicts({ [definition.id]: true });
                          return;
                        }
                        setShortcutConflicts({});
                        setSideChatShortcutConflict(false);
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
                  ...(electronRuntime
                    ? [
                        {
                          id: "keyboard.open-side-chat",
                          title: m.settings_open_side_chat(),
                          description: m.settings_open_side_chat_description(),
                          keywords: ["side chat", "hotkey", "shortcut", "侧边聊天"],
                          control: {
                            type: "shortcut" as const,
                            value: sideChatShortcut,
                            onClear: () => {
                              setSideChatShortcutConflict(false);
                              return setSideChatShortcut(null);
                            },
                            disabled: sideChatShortcutRegistrationPending,
                            ...(sideChatShortcutConflict
                              ? {
                                  errorMessage: m.settings_shortcut_conflict(),
                                }
                              : sideChatShortcutRegistrationFailed
                                ? {
                                    errorMessage:
                                      m.settings_shortcut_registration_failed(),
                                  }
                                : {}),
                            recordingLabel: m.settings_press_shortcut(),
                            onChange: (shortcut: SideChatShortcut) => {
                              if (
                                findAppShortcutConflictForSideChat(
                                  appShortcutBindings,
                                  shortcut
                                ) ||
                                sameGlobalShortcut(
                                  shortcut,
                                  clientSettings.settings.openCommaShortcut
                                )
                              ) {
                                setSideChatShortcutConflict(true);
                                return;
                              }
                              setSideChatShortcutConflict(false);
                              setShortcutConflicts({});
                              return setSideChatShortcut(shortcut);
                            },
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
                        void clientSettings.update({
                          meetingStartRecording: value === "auto" ? "auto" : "reminder",
                        });
                      },
                    },
                  },
                  {
                    id: "meeting.hide",
                    title: m.settings_meeting_hide(),
                    description: m.settings_meeting_hide_description(),
                    control: {
                      type: "toggle",
                      checked: clientSettings.settings.meetingHideRecorder,
                      disabled: clientSettingsPending,
                      onChange: (event) => {
                        void clientSettings.update({
                          meetingHideRecorder: event.target.checked,
                        });
                      },
                    },
                  },
                  {
                    id: "meeting.summary",
                    title: m.settings_meeting_summary(),
                    description: m.settings_meeting_summary_description(),
                    control: {
                      type: "toggle",
                      checked: clientSettings.settings.meetingSmartSummary,
                      disabled: clientSettingsPending,
                      onChange: (event) => {
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
                  // need "Only my work". Only the workspace owner has them.
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
            keywords: ["telegram", "tg", "wechat", "微信", "ClawBot", "signal", "消息"],
            ...(signalChannel.overlay ? { overlay: signalChannel.overlay } : {}),
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
                    description: telegramConnectionDescription(),
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
            ],
          },
          browserCategory,
          taskLabelsCategory,
          {
            ...modelTemplates.category,
            keywords: ["BYOK", "API Key", "Codex", "Claude", "OAuth"],
            sections: [
              ...subscriptionAccounts.sections,
              ...modelTemplates.category.sections,
            ],
            ...(subscriptionAccounts.detail
              ? { detail: subscriptionAccounts.detail }
              : {}),
          },
        ],
      },
      {
        id: "system",
        label: m.settings_group_system(),
        categories: [
          routerApiKeysCategory,
          voiceCategory,
          devicesCategory,
          {
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
                    description: permissionStatus(
                      computerUse.permissions?.accessibility
                    ),
                  },
                  {
                    id: "computer-use.screen-recording",
                    title: m.settings_computer_use_screen_recording(),
                    description: permissionStatus(
                      computerUse.permissions?.screenRecording
                    ),
                  },
                  {
                    id: "computer-use.permissions",
                    title: m.settings_computer_use_permissions(),
                    description: m.settings_computer_use_permissions_description(),
                    control: {
                      type: "button",
                      label: m.settings_computer_use_manage(),
                      disabled: !computerUse.available || computerUse.pending,
                      onPress: computerUse.open,
                    },
                  },
                  {
                    id: "computer-use.refresh",
                    title: m.settings_computer_use_status(),
                    description:
                      computerUse.error ??
                      m.settings_computer_use_refresh_description(),
                    control: {
                      type: "button",
                      label: m.settings_computer_use_refresh(),
                      disabled: !computerUse.available || computerUse.pending,
                      onPress: computerUse.refresh,
                    },
                  },
                ],
              },
            ],
          },
          computeNodeCategory,
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
              ...additionalSystemCategories
                .filter((category) => category.id === "debug")
                .flatMap((category) => category.sections),
            ],
          },
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
        categories: [sharedTasksCategory],
      },
    ],
  });

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
      {nameDialogOpen ? (
        <Dialog
          actions={[
            {
              label: m.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              disabled: namePending,
              onPress: closeNameDialog,
            },
            {
              label: m.settings_profile_save(),
              hierarchy: "primary",
              disabled: namePending || !normalizedName || nameInvalid || nameUnchanged,
              onPress: () => void saveName(),
            },
          ]}
          description={m.settings_profile_name_description()}
          input={{
            "aria-label": m.settings_profile_name(),
            autoFocus: true,
            disabled: namePending,
            ...(nameError
              ? { errorMessage: nameError }
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
          isDismissable={!namePending}
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
