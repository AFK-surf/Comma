import { useCall, type MiniAppLink } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { GlobeIcon, MoreHorizontalIcon } from "@comma/ui/components/icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  menuCompactClasses,
} from "@comma/ui/components/menu";
import { toast } from "@comma/ui/components/toast";
import { spacing } from "@comma/ui/tokens";
import { useState } from "react";
import { copyTextToClipboard } from "../chat/thread/inline/linkActions";

const LINK_TOAST_ID = "mini-app-link-feedback";

/**
 * An app's link, where its settings say anyone with the link can open it: create it, copy it, reset it (the old link
 * stops working) or stop sharing. The link opens the app inside Comma; it is never a public page of the app. It shows
 * only what the server confirmed.
 */
export function MiniAppLinkField({
  workspaceId,
  appId,
  link,
}: {
  workspaceId: string;
  appId: string;
  /** The link as the app's settings read it. */
  link: MiniAppLink | null;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const [pending, setPending] = useState(false);
  const target = { workspace: workspaceId, app: appId };

  const run = async (change: () => Promise<unknown>) => {
    setPending(true);
    try {
      return await change();
    } catch {
      toast.error(messages.mini_app_share_failed(), { id: LINK_TOAST_ID });
      return undefined;
    } finally {
      setPending(false);
    }
  };
  const copy = async (url: string) => {
    try {
      await copyTextToClipboard(url);
      toast.success(messages.mini_app_share_copied(), { id: LINK_TOAST_ID });
    } catch {
      toast.error(messages.copy_failed_title(), {
        description: messages.copy_failed_detail(),
        id: LINK_TOAST_ID,
      });
    }
  };

  if (!link)
    return (
      <div
        className="flex min-h-4xl w-full items-center justify-between gap-md"
        data-testid="mini-app-link"
      >
        <p className="text-sm text-tertiary">{messages.mini_app_share_unshared()}</p>
        <Button
          hierarchy="secondary-gray"
          isPending={pending}
          onPress={() => void run(() => call("miniApps.link.publish", target))}
          size="xs"
        >
          {messages.mini_app_share_create()}
        </Button>
      </div>
    );
  return (
    <div className="flex w-full items-center gap-sm" data-testid="mini-app-link">
      <label className="flex h-4xl min-w-0 flex-1 cursor-text items-center gap-sm rounded-md bg-primary px-md shadow-xs ring-1 ring-primary ring-inset focus-within:shadow-focus-gray-shadow-xs">
        <GlobeIcon className="size-4 shrink-0 text-fg-quaternary" />
        <input
          aria-label={messages.mini_app_share_link_label()}
          className="min-w-0 flex-1 truncate bg-transparent text-sm text-secondary outline-none"
          data-testid="mini-app-link-url"
          onFocus={(event) => event.currentTarget.select()}
          readOnly
          value={link.url}
        />
      </label>
      <Button
        hierarchy="secondary-gray"
        isPending={pending}
        onPress={() => void copy(link.url)}
        size="xs"
      >
        {messages.mini_app_share_copy()}
      </Button>
      <MenuTrigger>
        <Button
          aria-label={messages.mini_app_actions()}
          hierarchy="tertiary-gray"
          iconLeading={<MoreHorizontalIcon />}
          iconOnly
          isPending={pending}
          size="xs"
        />
        <MenuPopover offset={spacing.xs} placement="bottom end">
          <Menu
            aria-label={messages.mini_app_actions()}
            className={menuCompactClasses}
            onAction={(key) => {
              if (key === "reset") void run(() => call("miniApps.link.reset", target));
              else if (key === "stop")
                void run(() => call("miniApps.link.revoke", target));
            }}
          >
            <MenuItem id="reset">{messages.mini_app_share_reset()}</MenuItem>
            <MenuSeparator />
            <MenuItem id="stop" tone="destructive">
              {messages.mini_app_share_stop()}
            </MenuItem>
          </Menu>
        </MenuPopover>
      </MenuTrigger>
    </div>
  );
}
