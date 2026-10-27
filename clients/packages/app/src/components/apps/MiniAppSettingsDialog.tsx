import {
  useCall,
  useTopic,
  type MiniApp,
  type MiniAppValue,
  type MiniAppVersion,
  type MiniAppVisibility,
} from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import {
  SettingsSectionView,
  type SettingsPanelItem,
  type SettingsPanelSection,
} from "@comma/ui/components/settings-panel";
import { toast } from "@comma/ui/components/toast";
import { useState } from "react";
import { MiniAppLinkField } from "./MiniAppLinkField";

type Messages = ReturnType<typeof useCommaMessages>;

export type MiniAppSettingsTarget = { workspaceId: string; appId: string };

const isVisibility = (value: string): value is MiniAppVisibility =>
  value === "private" || value === "workspace" || value === "link";

function versionDescription(version: MiniAppVersion): string {
  return [version.commit?.slice(0, 7), version.notes]
    .filter((part): part is string => !!part)
    .join(" · ");
}

/** The Version's state as the row's status dot: live, failed or uploading. A ready Version that is not live has none. */
function versionStatus(
  messages: Messages,
  version: MiniAppVersion
): SettingsPanelItem["status"] {
  if (version.live) return { label: messages.mini_app_live_badge(), color: "success" };
  if (version.state === "failed")
    return { label: messages.mini_app_version_failed(), color: "error" };
  if (version.state === "uploading")
    return {
      label: messages.mini_app_version_uploading(),
      color: "gray",
      loading: true,
    };
  return undefined;
}

const definedStatus = (status: SettingsPanelItem["status"]) =>
  status ? { status } : {};

/**
 * An app's settings, over whatever opened them (the gallery, the app itself, a chat card): who can open it and its
 * link, its Versions and rollback, backend secrets, and disable, delete or remove. Changes apply at once.
 */
export function MiniAppSettingsDialog({
  workspaceId,
  appId,
  onClose,
  onRemoved,
}: MiniAppSettingsTarget & {
  onClose: () => void;
  /** After the app was deleted, or removed from this Workspace. */
  onRemoved?: (() => void) | undefined;
}) {
  const messages = useCommaMessages();
  const { value } = useTopic({ topic: "miniApp", workspace: workspaceId, app: appId });
  const app = value?.status === "ready" ? value.app : null;
  return (
    <Dialog
      className="w-dialog-preview rounded-2xl"
      description={
        app
          ? [
              app.description,
              app.author.name
                ? messages.mini_app_by_author({ author: app.author.name })
                : "",
              app.repo ? `${app.repo.owner}/${app.repo.name}` : "",
            ]
              .filter(Boolean)
              .join(" · ")
          : undefined
      }
      isOpen
      onOpenChange={(isOpen) => {
        if (!isOpen) onClose();
      }}
      showCloseButton
      title={app?.name ?? messages.mini_app_settings()}
    >
      <div className="flex w-full flex-col" data-testid="mini-app-settings-dialog">
        {!value || value.status === "loading" ? (
          <div className="flex min-h-6xl items-center justify-center">
            <LoadingIndicator label={messages.mini_apps_loading()} />
          </div>
        ) : !app ? (
          <p className="text-sm text-secondary" role="alert">
            {value.status === "missing"
              ? messages.mini_app_unavailable_title()
              : messages.mini_apps_load_failed()}
          </p>
        ) : (
          <AppSettings
            app={app}
            onClose={onClose}
            onRemoved={onRemoved}
            value={value}
            workspaceId={workspaceId}
          />
        )}
      </div>
    </Dialog>
  );
}

function AppSettings({
  app,
  value,
  workspaceId,
  onClose,
  onRemoved,
}: {
  app: MiniApp;
  value: MiniAppValue;
  workspaceId: string;
  onClose: () => void;
  onRemoved: (() => void) | undefined;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const owner = app.workspace_id === workspaceId;
  const [secret, setSecret] = useState<{ name: string; value: string }>();
  const [deleting, setDeleting] = useState(false);
  const target = { workspace: workspaceId, app: app.id };
  const change = (run: () => Promise<unknown>) =>
    void run().catch(() => toast.error(messages.mini_app_change_failed()));
  const removed = () => {
    onClose();
    onRemoved?.();
  };

  const access: SettingsPanelItem[] = [];
  if (owner) {
    access.push({
      id: "app.visibility",
      density: "compact",
      title: messages.mini_app_visibility(),
      control: {
        type: "dropdown",
        ariaLabel: messages.mini_app_visibility(),
        value: app.visibility,
        items: [
          { id: "private", label: messages.mini_app_visibility_private() },
          { id: "workspace", label: messages.mini_app_visibility_workspace() },
          { id: "link", label: messages.mini_app_visibility_link() },
        ],
        onChange: (visibility) => {
          if (!isVisibility(visibility)) return;
          // Anyone with the link needs the link: it is made at once.
          change(async () => {
            await call("miniApps.update", { ...target, visibility });
            if (visibility === "link" && !value.link)
              await call("miniApps.link.publish", target);
          });
        },
      },
    });
    if (app.visibility === "link")
      access.push({
        id: "app.link",
        title: messages.mini_app_share_link_label(),
        description: messages.mini_app_share_intro(),
        layout: "field",
        control: {
          type: "custom",
          content: (
            <MiniAppLinkField
              appId={app.id}
              link={value.link}
              workspaceId={workspaceId}
            />
          ),
        },
      });
  }

  const sections: SettingsPanelSection[] = [];
  // Who can open the app is what the dialog is most for: it leads, under no heading.
  if (access.length > 0) sections.push({ id: "app.access", title: "", items: access });
  if (owner && value.versions.length > 0)
    sections.push({
      id: "app.versions",
      title: messages.mini_app_versions(),
      items: value.versions.map((version) => ({
        id: `app.version.${version.number}`,
        density: "dense" as const,
        title: messages.mini_app_version({ version: String(version.number) }),
        description: versionDescription(version),
        ...definedStatus(versionStatus(messages, version)),
        ...(version.state === "ready" && !version.live
          ? {
              control: {
                type: "button" as const,
                label: messages.mini_app_rollback(),
                onPress: () =>
                  change(() =>
                    call("miniApps.rollback", { ...target, version: version.number })
                  ),
              },
            }
          : {}),
      })),
    });
  if (owner && app.secrets.length > 0)
    sections.push({
      id: "app.secrets",
      title: messages.mini_app_secrets(),
      description: messages.mini_app_secrets_description(),
      items: app.secrets.map((name) => ({
        id: `app.secret.${name}`,
        density: "compact" as const,
        title: name,
        control: {
          type: "menu" as const,
          label: messages.mini_app_secret_set(),
          items: [
            {
              id: "set",
              label: messages.mini_app_secret_set(),
              onPress: () => setSecret({ name, value: "" }),
            },
            {
              id: "delete",
              label: messages.mini_app_secret_delete(),
              tone: "destructive" as const,
              onPress: () =>
                change(() => call("miniApps.secret.delete", { ...target, name })),
            },
          ],
        },
      })),
    });
  const disabled = app.status === "disabled";
  sections.push({
    id: "app.manage",
    title: messages.mini_app_danger(),
    items: owner
      ? [
          {
            id: "app.disable",
            density: "compact",
            title: disabled ? messages.mini_app_enable() : messages.mini_app_disable(),
            description: messages.mini_app_disable_description(),
            ...(disabled
              ? {
                  status: {
                    label: messages.mini_apps_disabled_badge(),
                    color: "warning" as const,
                  },
                }
              : {}),
            control: {
              type: "button",
              label: disabled
                ? messages.mini_app_enable()
                : messages.mini_app_disable(),
              onPress: () =>
                change(() =>
                  call(disabled ? "miniApps.enable" : "miniApps.disable", target)
                ),
            },
          },
          {
            id: "app.delete",
            density: "compact",
            title: messages.mini_app_delete(),
            description: messages.mini_app_delete_description(),
            control: {
              type: "button",
              label: messages.mini_app_delete(),
              tone: "danger",
              onPress: () => setDeleting(true),
            },
          },
        ]
      : [
          {
            id: "app.remove",
            density: "compact",
            title: messages.mini_app_remove(),
            control: {
              type: "button",
              label: messages.mini_app_remove(),
              tone: "danger",
              onPress: () =>
                change(async () => {
                  await call("miniApps.uninstall", target);
                  removed();
                }),
            },
          },
        ],
  });

  return (
    <>
      {/* Each group is a Settings card on the dialog's content edge; the scroll bar keeps to the dialog's own edge.
          A group's title sits md over its card, groups 3xl apart: the space tells the groups apart. */}
      <div className="-mx-xl max-h-[calc(100vh-var(--spacing-10xl)-var(--spacing-3xl))]">
        <ScrollArea
          className="max-h-[inherit]"
          edgeEffect="mask"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="max-h-[inherit]"
        >
          <div className="flex flex-col gap-3xl px-xl pb-xxs">
            {sections.map((section) => (
              <SettingsSectionView
                appearance="grouped"
                key={section.id}
                section={section}
              />
            ))}
          </div>
        </ScrollArea>
      </div>
      {secret ? (
        <Dialog
          actions={[
            {
              label: messages.mini_app_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setSecret(undefined),
            },
            {
              label: messages.mini_app_save(),
              hierarchy: "primary",
              disabled: !secret.value,
              onPress: () => {
                const { name, value: entered } = secret;
                setSecret(undefined);
                change(() =>
                  call("miniApps.secret.set", { ...target, name, value: entered })
                );
              },
            },
          ]}
          input={{
            "aria-label": messages.mini_app_secret_value({ name: secret.name }),
            type: "password",
            value: secret.value,
            onChange: (event) => setSecret({ ...secret, value: event.target.value }),
            autoFocus: true,
          }}
          isOpen
          onOpenChange={(isOpen) => {
            if (!isOpen) setSecret(undefined);
          }}
          title={messages.mini_app_secret_value({ name: secret.name })}
          variant="input"
        />
      ) : null}
      {deleting ? (
        <Dialog
          actions={[
            {
              label: messages.mini_app_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setDeleting(false),
            },
            {
              label: messages.mini_app_delete_confirm(),
              hierarchy: "destructive",
              onPress: () => {
                setDeleting(false);
                change(async () => {
                  await call("miniApps.delete", target);
                  removed();
                });
              },
            },
          ]}
          description={messages.mini_app_delete_description()}
          isOpen
          onOpenChange={(isOpen) => {
            if (!isOpen) setDeleting(false);
          }}
          title={messages.mini_app_delete_title({ name: app.name })}
        />
      ) : null}
    </>
  );
}
