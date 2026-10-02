import { getActiveCommaConfig } from "@comma/config";
import { useCommaMessages } from "@comma/i18n/react";
import { BellIcon, EyeIcon, WindowCursorIcon } from "@comma/ui";
import { useEffect, useId, useState, type ReactNode } from "react";
import { withRouterNameSpacing } from "../../router-identity/routerNameSpacing";
import { OnboardingCardFooter, OnboardingPrimaryButton } from "../OnboardingCard";
import {
  OnboardingRowAction,
  type OnboardingRowActionState,
} from "../OnboardingRowAction";
import {
  usePermissionsStep,
  type PermissionId,
  type PermissionRowState,
} from "./usePermissionsStep";

type Messages = ReturnType<typeof useCommaMessages>;

/** One grant as the panel shows it. */
export type OnboardingPermissionRow = {
  id: PermissionId;
  action: OnboardingRowActionState;
  /** macOS is asking, or the user is answering it elsewhere. */
  waiting: boolean;
  /** The last Allow could not put macOS's question in front of the user. */
  failed: boolean;
  /** macOS's answer for it could not be read at all (Computer Use grants). */
  unreadable?: boolean;
};

/**
 * What the panel reports when the user moves on: how many grants are allowed,
 * which are not, and whether both Computer Use grants are among the allowed.
 */
export type OnboardingPermissionsResult = {
  allowed: number;
  total: number;
  computerUse: boolean;
  missing: readonly PermissionId[];
};

/** Comma operates apps with Accessibility and sees them with Screen Recording. */
const computerUseGrants: readonly PermissionId[] = ["accessibility", "screenRecording"];

// The glyph says what the grant lets Comma do; the tile's colour is the one of
// the System Settings pane macOS opens for it.
const permissionIcons: Record<PermissionId, ReactNode> = {
  accessibility: <WindowCursorIcon />,
  screenRecording: <EyeIcon />,
  notifications: <BellIcon />,
};

/**
 * The grants card, live: macOS's own answers for the three grants, read when
 * the card comes up and again when the user comes back. Mount it only while
 * the card is up.
 */
export function LivePermissionsPanel({
  assistantName,
  onAdvance,
}: {
  assistantName: string;
  onAdvance: (result: OnboardingPermissionsResult) => void;
}) {
  const permissions = usePermissionsStep();
  const { grant, pendingId, reading, rows, unreadable } = permissions;
  // The Computer Use grants are answered in the Computer Use helper and System
  // Settings, one flow for both: a row waits from its Allow until the read
  // that follows the user's return. Notifications are answered in macOS's own
  // prompt, which the request itself waits for.
  const [answering, setAnswering] = useState<{
    ids: readonly PermissionId[];
    back: boolean;
    reading: boolean;
  }>();
  const unanswered = answering?.ids.filter(
    (id) => rows.find((row) => row.id === id)?.status !== "granted"
  );
  if (answering && unanswered?.length === 0) {
    setAnswering(undefined);
  } else if (answering?.back && reading && !answering.reading) {
    setAnswering({ ...answering, reading: true });
  } else if (answering?.back && answering.reading && !reading) {
    setAnswering(undefined);
  }
  // A grant whose flow did not open: the row says so until the next Allow.
  const [failed, setFailed] = useState<PermissionId>();
  const awaitingReturn = answering !== undefined && !answering.back;
  useEffect(() => {
    if (!awaitingReturn) return undefined;
    const back = () => {
      if (document.visibilityState !== "visible") return;
      setAnswering((current) => current && { ...current, back: true });
    };
    window.addEventListener("focus", back);
    document.addEventListener("visibilitychange", back);
    return () => {
      window.removeEventListener("focus", back);
      document.removeEventListener("visibilitychange", back);
    };
  }, [awaitingReturn]);

  return (
    <PermissionsPanel
      assistantName={assistantName}
      onAdvance={onAdvance}
      onAllow={(id) => {
        setFailed(undefined);
        if (id !== "notifications") {
          setAnswering((current) => ({
            back: false,
            ids: [...(current?.ids.filter((other) => other !== id) ?? []), id],
            reading: false,
          }));
        }
        void grant(id).then((opened) => {
          if (opened) return;
          // Nothing opened, so there is nothing to come back from.
          setAnswering((current) => {
            const ids = current?.ids.filter((other) => other !== id) ?? [];
            return current && ids.length > 0 ? { ...current, ids } : undefined;
          });
          setFailed(id);
        });
      }}
      onOpenSettings={() => {
        setFailed(undefined);
        void grant("notifications").then((opened) => {
          if (!opened) setFailed("notifications");
        });
      }}
      rows={rows.map((row) => ({
        ...panelRow(row, pendingId, answering?.ids ?? [], failed === row.id),
        ...(unreadable && row.id !== "notifications" ? { unreadable: true } : {}),
      }))}
    />
  );
}

function panelRow(
  row: PermissionRowState,
  pendingId: PermissionId | undefined,
  answering: readonly PermissionId[],
  failed: boolean
): OnboardingPermissionRow {
  const waiting =
    row.status === "notGranted" && (pendingId === row.id || answering.includes(row.id));
  const action: OnboardingRowActionState =
    row.status === "checking"
      ? "checking"
      : row.status === "granted"
        ? "done"
        : waiting
          ? "pending"
          : row.settingsOnly
            ? "settings"
            : "idle";
  return {
    action,
    failed: failed && !waiting && row.status === "notGranted",
    id: row.id,
    waiting,
  };
}

/**
 * The grants card: what macOS will ask about the two Computer Use grants,
 * then the three grants in one list, each a plugin row with a small solid
 * tile. The primary skips until every grant is allowed.
 */
export function PermissionsPanel({
  assistantName,
  onAdvance,
  onAllow,
  onOpenSettings,
  rows,
}: {
  assistantName: string;
  rows: readonly OnboardingPermissionRow[];
  onAllow: (id: PermissionId) => void;
  /** Notifications, once macOS has refused them. */
  onOpenSettings: () => void;
  onAdvance: (result: OnboardingPermissionsResult) => void;
}) {
  const messages = useCommaMessages();
  const allowed = rows.filter((row) => row.action === "done").length;

  return (
    <>
      <div className="comma-onboarding-card__content">
        <p className="comma-onboarding-permissions__helper">
          {messages.onboarding_permissions_helper({
            product: getActiveCommaConfig().productName,
          })}
        </p>
        <ul className="comma-onboarding-permissions">
          {rows.map((row) => (
            <PermissionRow
              assistantName={assistantName}
              key={row.id}
              messages={messages}
              onAllow={onAllow}
              onOpenSettings={onOpenSettings}
              row={row}
            />
          ))}
        </ul>
      </div>
      <OnboardingCardFooter
        primary={
          <OnboardingPrimaryButton
            done={allowed === rows.length}
            quietSkip
            onPress={() =>
              onAdvance({
                allowed,
                computerUse: computerUseGrants.every((id) =>
                  rows.some((row) => row.id === id && row.action === "done")
                ),
                total: rows.length,
                missing: rows
                  .filter((row) => row.action !== "done")
                  .map((row) => row.id),
              })
            }
          />
        }
      />
    </>
  );
}

function permissionCopy(id: PermissionId, messages: Messages, assistantName: string) {
  switch (id) {
    case "accessibility":
      return {
        title: messages.onboarding_permissions_accessibility(),
        description: messages.onboarding_permissions_accessibility_description(),
      };
    case "screenRecording":
      return {
        title: messages.onboarding_permissions_screen_recording(),
        description: messages.onboarding_permissions_screen_recording_description(),
      };
    case "notifications":
      return {
        title: messages.onboarding_permissions_notifications(),
        description: withRouterNameSpacing(
          messages.onboarding_permissions_notifications_description({
            name: assistantName,
          })
        ),
      };
  }
}

function PermissionRow({
  assistantName,
  messages,
  onAllow,
  onOpenSettings,
  row,
}: {
  assistantName: string;
  messages: Messages;
  row: OnboardingPermissionRow;
  onAllow: (id: PermissionId) => void;
  onOpenSettings: () => void;
}) {
  const titleId = useId();
  const { title, description } = permissionCopy(row.id, messages, assistantName);

  return (
    <li className="comma-onboarding-permission" data-permission={row.id}>
      <span
        aria-hidden="true"
        className="comma-onboarding-permission__tile"
        data-permission={row.id}
      >
        <span>{permissionIcons[row.id]}</span>
      </span>
      <span className="comma-onboarding-permission__text">
        <span className="comma-onboarding-permission__title" id={titleId}>
          {title}
        </span>
        {/* A grant whose window did not open says so in its description's
            place until the next Allow; the rare error may take two lines. */}
        <span
          aria-live="polite"
          className="comma-onboarding-permission__description"
          data-failed={row.failed || row.unreadable || undefined}
        >
          {row.failed
            ? messages.onboarding_permissions_open_failed()
            : row.unreadable
              ? messages.onboarding_permissions_unreadable()
              : description}
        </span>
      </span>
      <OnboardingRowAction
        actionAriaLabel={messages.onboarding_permissions_allow_named({
          permission: title,
        })}
        actionLabel={messages.onboarding_permissions_allow()}
        doneLabel={messages.onboarding_permissions_allowed()}
        onAction={() => onAllow(row.id)}
        pendingLabel={messages.onboarding_permissions_waiting()}
        state={row.action}
        {...(row.id === "notifications"
          ? {
              onSettings: onOpenSettings,
              settingsLabel: messages.onboarding_permissions_open_settings(),
            }
          : {})}
      />
    </li>
  );
}
