import { useEffect, useState } from "react";
import {
  getNativeBridge,
  type BrowserCookieImportResult,
  type BrowserImportProfile,
} from "@comma/native-bridge";
import { formatNumber } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Checkbox } from "@comma/ui/components/checkbox";
import { Dialog } from "@comma/ui/components/dialog";
import {
  CircleCheckFilledIcon,
  CircleInfoIcon,
  GlobeIcon,
  XIcon,
} from "@comma/ui/components/icons";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { ShellIconButtonControl } from "../ShellIconButton";

const profileKey = (
  profile: Pick<BrowserImportProfile, "profileDirectory" | "source">
) => `${profile.source}:${profile.profileDirectory}`;

type ImportedResult = Extract<BrowserCookieImportResult, { status: "imported" }>;
type ProfileOutcome =
  | ({ read: true } & ImportedResult["profiles"][number])
  | ({ read: false } & ImportedResult["unread"][number]);

/**
 * Imports the sign-ins of browser profiles on this Mac into the browser
 * sidebar, in one step. Every profile Comma can read starts selected. Main
 * reads the browser data and decrypts the cookies; this dialog sees profile
 * names, app icons and counts.
 */
export function BrowserImportDialog({
  onClose,
  onImported,
}: {
  onClose: () => void;
  onImported?: ((result: BrowserCookieImportResult) => void) | undefined;
}) {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const bridge = getNativeBridge();
  const [profiles, setProfiles] = useState<BrowserImportProfile[]>();
  const [selected, setSelected] = useState<ReadonlySet<string>>(new Set());
  const [message, setMessage] = useState<string>();
  const [outcomes, setOutcomes] = useState<ProfileOutcome[]>([]);
  const [pending, setPending] = useState(false);
  const [done, setDone] = useState(false);

  useEffect(() => {
    let current = true;
    void bridge.browserSidebar
      .listImportProfiles()
      .then(({ profiles: found }) => {
        if (!current) return;
        setProfiles(found);
        setSelected(
          new Set(found.filter((profile) => profile.status === "ready").map(profileKey))
        );
        if (found.length === 0) setMessage(m.settings_browser_import_none());
      })
      .catch(() => {
        if (current) setMessage(m.settings_browser_import_failed());
      });
    return () => {
      current = false;
    };
  }, [bridge, m]);

  // Sites are what the user signed in to; cookies are not.
  const counted = (count: number) => ({
    count,
    formattedCount: formatNumber(count, locale),
  });
  const chosen = profiles?.filter((profile) => selected.has(profileKey(profile))) ?? [];
  const resultMessage = (result: BrowserCookieImportResult) => {
    switch (result.status) {
      case "imported": {
        // Sites are what the user signed in to; cookies are not.
        const outcome =
          result.importedSites > 0
            ? m.settings_browser_import_result_sites(counted(result.importedSites))
            : result.failed > 0
              ? m.settings_browser_import_failed()
              : result.unchanged > 0 && result.keptSites === 0
                ? m.settings_browser_import_result_unchanged()
                : m.settings_browser_import_result_none();
        if (result.keptSites === 0) return outcome;
        // Chinese sentences follow one another without a space.
        const separator = locale.startsWith("zh") ? "" : " ";
        return `${outcome}${separator}${m.settings_browser_import_result_kept(counted(result.keptSites))}`;
      }
      case "keychain-denied":
        return m.settings_browser_import_keychain_denied();
      case "permission-required":
        return m.settings_browser_import_permission();
      case "not-found":
        return m.settings_browser_import_not_found();
      case "busy":
        return m.settings_browser_import_busy();
      default:
        return m.settings_browser_import_failed();
    }
  };
  // What happened to one profile, as a short status beside it.
  const outcomeStatus = (outcome: ProfileOutcome) => {
    if (!outcome.read) {
      const reasons = {
        failed: m.browser_import_row_failed,
        "keychain-denied": m.browser_import_row_keychain,
        "not-found": m.browser_import_row_not_found,
        "permission-required": m.browser_import_needs_permission,
      } as const;
      return { tone: "warning", label: reasons[outcome.status]() } as const;
    }
    if (outcome.importedSites > 0) {
      return {
        tone: "success",
        label: m.browser_import_row_sites(counted(outcome.importedSites)),
      } as const;
    }
    return {
      tone: "neutral",
      label:
        outcome.unchangedSites > 0 && outcome.keptSites === 0
          ? m.browser_import_row_unchanged()
          : m.browser_import_row_none(),
    } as const;
  };
  const runImport = async () => {
    if (chosen.length === 0 || pending) return;
    setPending(true);
    setMessage(undefined);
    try {
      const result = await bridge.browserSidebar.importCookies({
        profiles: chosen.map(({ profileDirectory, source }) => ({
          profileDirectory,
          source,
        })),
      });
      setMessage(resultMessage(result));
      if (result.status === "imported") {
        setOutcomes([
          ...result.profiles.map((profile) => ({ read: true as const, ...profile })),
          ...result.unread.map((profile) => ({ read: false as const, ...profile })),
        ]);
        setDone(true);
        onImported?.(result);
      }
    } catch {
      setMessage(m.settings_browser_import_failed());
    } finally {
      setPending(false);
    }
  };

  return (
    <Dialog
      isOpen
      isDismissable={!pending}
      onOpenChange={(open) => {
        if (!open && !pending) onClose();
      }}
      title={m.browser_import_sign_ins()}
      description={message ?? m.browser_import_dialog_description()}
      actions={
        done
          ? [{ label: m.browser_import_done(), hierarchy: "primary", onPress: onClose }]
          : [
              {
                label: m.settings_profile_cancel(),
                hierarchy: "secondary-gray",
                disabled: pending,
                onPress: onClose,
              },
              {
                label: m.browser_import_confirm(),
                hierarchy: "primary",
                disabled: pending || chosen.length === 0,
                onPress: () => void runImport(),
              },
            ]
      }
    >
      {done && outcomes.length > 0 ? (
        <ul className="flex flex-col gap-1.5" aria-label={m.browser_import_profile()}>
          {outcomes.map((outcome) => {
            const profile = profiles?.find(
              (candidate) => profileKey(candidate) === profileKey(outcome)
            );
            const status = outcomeStatus(outcome);
            return (
              <li
                className="flex items-center gap-3 rounded-lg border border-primary px-3 py-2.5"
                key={profileKey(outcome)}
              >
                <ProfileIcon icon={profile?.icon} />
                <span className="flex min-w-0 flex-1 flex-col">
                  <span className="truncate text-sm font-medium text-primary">
                    {profile?.appName ?? outcome.source}
                  </span>
                  <span className="truncate text-xs text-tertiary">
                    {profile?.profileName ?? outcome.profileDirectory}
                  </span>
                </span>
                <span
                  className={cx(
                    "flex shrink-0 items-center gap-1 text-sm",
                    status.tone === "success" && "font-medium text-primary",
                    status.tone === "neutral" && "text-tertiary",
                    status.tone === "warning" && "text-fg-warning-secondary"
                  )}
                >
                  {status.tone === "success" ? (
                    <CircleCheckFilledIcon className="size-4 text-fg-success-primary" />
                  ) : status.tone === "warning" ? (
                    <CircleInfoIcon className="size-4" />
                  ) : null}
                  {status.label}
                </span>
              </li>
            );
          })}
        </ul>
      ) : null}
      {!done && profiles?.length ? (
        <fieldset className="flex flex-col gap-1.5">
          <legend className="sr-only">{m.browser_import_profile()}</legend>
          {profiles.map((candidate) => {
            const key = profileKey(candidate);
            const ready = candidate.status === "ready";
            return (
              <Checkbox
                checked={selected.has(key)}
                className="rounded-lg border border-primary px-3 py-2.5 transition-colors duration-150 hover:bg-secondary"
                disabled={pending || !ready}
                key={key}
                label={
                  <span className="flex items-center gap-3">
                    <ProfileIcon icon={candidate.icon} />
                    <span className="flex min-w-0 flex-col">
                      <span className="truncate text-sm font-medium text-primary">
                        {candidate.appName}
                      </span>
                      <span className="truncate text-xs font-normal text-tertiary">
                        {ready
                          ? candidate.userName
                            ? `${candidate.profileName} · ${candidate.userName}`
                            : candidate.profileName
                          : m.browser_import_needs_permission()}
                      </span>
                    </span>
                  </span>
                }
                onChange={(event) => {
                  const { checked } = event.target;
                  setSelected((previous) => {
                    const next = new Set(previous);
                    if (checked) next.add(key);
                    else next.delete(key);
                    return next;
                  });
                  setMessage(undefined);
                }}
              />
            );
          })}
        </fieldset>
      ) : null}
    </Dialog>
  );
}

function ProfileIcon({ icon }: { icon?: string | undefined }) {
  return icon ? (
    <img alt="" className="size-8 shrink-0" src={icon} />
  ) : (
    <GlobeIcon className="size-8 shrink-0 p-1 text-fg-quaternary" />
  );
}

const offerDismissedKey = "comma.browser-import-offer-dismissed";
let importableProfiles: Promise<BrowserImportProfile[]> | undefined;

/** The browser profiles on this Mac to import from. Read once per run. */
function listImportableProfiles() {
  importableProfiles ??= Promise.resolve()
    .then(() => getNativeBridge().browserSidebar.listImportProfiles())
    .then(({ profiles }) => profiles)
    .catch(() => []);
  return importableProfiles;
}

/** One icon per browser. Main lists the most recently used profile first. */
function browserIcons(profiles: BrowserImportProfile[], limit: number) {
  const icons = new Map<string, string>();
  for (const profile of profiles) {
    if (profile.icon && !icons.has(profile.source)) {
      icons.set(profile.source, profile.icon);
    }
  }
  return [...icons.values()].slice(0, limit);
}

function offerDismissed() {
  try {
    return localStorage.getItem(offerDismissedKey) === "1";
  } catch {
    return false;
  }
}

const offerDismissalListeners = new Set<() => void>();

/** Stops the browser sidebar from offering the import again on this device. */
export function dismissBrowserImportOffer() {
  try {
    localStorage.setItem(offerDismissedKey, "1");
  } catch {
    // The offer shows again next time; the import itself is unaffected.
  }
  for (const listener of offerDismissalListeners) listener();
}

/**
 * A one-line offer above the page in the browser sidebar, shown until the user
 * imports once or dismisses it, when this Mac has a browser to import from.
 * It shows the icons of those browsers and keeps its actions compact, so it
 * stays on one line in a narrow sidebar.
 */
export function BrowserImportOffer({ onImport }: { onImport: () => void }) {
  const m = useCommaMessages();
  const [icons, setIcons] = useState<string[]>();
  useEffect(() => {
    if (getNativeBridge().platform !== "electron" || offerDismissed()) return;
    let current = true;
    const hide = () => setIcons(undefined);
    offerDismissalListeners.add(hide);
    void listImportableProfiles().then((profiles) => {
      if (current && profiles.length > 0 && !offerDismissed()) {
        setIcons(browserIcons(profiles, 3));
      }
    });
    return () => {
      current = false;
      offerDismissalListeners.delete(hide);
    };
  }, []);
  if (!icons) return null;
  return (
    <div
      className="flex shrink-0 items-center gap-2 border-b border-primary py-1.5 pr-1.5 pl-3 text-sm text-secondary"
      role="note"
    >
      {icons.length > 0 ? (
        <span aria-hidden className="flex shrink-0 items-center gap-0.5">
          {icons.map((icon) => (
            <img alt="" className="size-4" key={icon} src={icon} />
          ))}
        </span>
      ) : null}
      <span className="min-w-0 flex-1">{m.browser_import_offer()}</span>
      <Button
        className="shrink-0"
        hierarchy="secondary-gray"
        size="xs"
        onPress={onImport}
      >
        {m.browser_import_offer_action()}
      </Button>
      <Tooltip content={m.browser_import_offer_dismiss()} placement="bottom">
        <ShellIconButtonControl
          aria-label={m.browser_import_offer_dismiss()}
          className="size-6 shrink-0 p-xxs"
          icon={<XIcon className="size-4" />}
          onPress={dismissBrowserImportOffer}
        />
      </Tooltip>
    </div>
  );
}
