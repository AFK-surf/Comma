// A document's public link, from its toolbar beside a Task's chat. The link shows one version of the document: the
// one that was shown when the owner created or last updated the link. A later version stays private until then.
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import {
  ChainLinkIcon,
  CheckIcon,
  CircleInfoIcon,
  GlobeIcon,
  MoreHorizontalIcon,
} from "@comma/ui/components/icons";
import { Dialog, dialogActionButton } from "@comma/ui/components/dialog";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  menuCompactClasses,
} from "@comma/ui/components/menu";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { spacing } from "@comma/ui/tokens";
import { copyWithFeedback, toast } from "@comma/ui/components/toast";
import { useCall, type DocumentShare } from "@comma/core-client";
import { useCallback, useEffect, useState } from "react";
import {
  copyTextToClipboard,
  openUrlInExternalBrowser,
} from "../chat/thread/inline/linkActions";
import { ShellIconButtonControl } from "../ShellIconButton";

const SHARE_TOAST_ID = "document-share-feedback";

/** The version of a document that a link would show: a Message's attachment in the document's Task. */
export type DocumentShareTarget = {
  groupId: string;
  conversationId: string;
  messageId: string;
  attachmentIndex: number;
  fileName: string;
};

type Shown =
  | { status: "loading" | "failed" }
  | { status: "ready"; share: DocumentShare | null };

/**
 * One state of the copy button: its icon and label, centered in a shared cell at the icon-to-label distance a
 * Button's leading icon keeps.
 */
const copyLabelClassName =
  "col-start-1 row-start-1 inline-flex items-center justify-center gap-sm";

function DocumentShareDialog({
  target,
  onClose,
}: {
  target: DocumentShareTarget;
  onClose: () => void;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const [shown, setShown] = useState<Shown>({ status: "loading" });
  const [pending, setPending] = useState(false);
  const [copiedUrl, setCopiedUrl] = useState<string>();
  const document = {
    group: target.groupId,
    conversation: target.conversationId,
    fileName: target.fileName,
  };
  const { groupId, conversationId, fileName } = target;
  const read = useCallback(() => {
    let current = true;
    setShown({ status: "loading" });
    void call("documentShare.get", {
      group: groupId,
      conversation: conversationId,
      fileName,
    }).then(
      (share) => {
        if (current) setShown({ status: "ready", share });
      },
      () => {
        if (current) setShown({ status: "failed" });
      }
    );
    return () => {
      current = false;
    };
  }, [call, conversationId, fileName, groupId]);
  useEffect(() => read(), [read]);

  /** Makes a change of the link, and shows the link the server answered. */
  const run = async (change: () => Promise<DocumentShare | null>) => {
    setPending(true);
    try {
      const share = await change();
      setShown({ status: "ready", share });
      return share ?? undefined;
    } catch {
      toast.error(messages.task_share_failed(), { id: SHARE_TOAST_ID });
      return undefined;
    } finally {
      setPending(false);
    }
  };
  const copy = async (url: string, { reportFailure = true } = {}) => {
    setCopiedUrl(undefined);
    const copied = await copyWithFeedback(() => copyTextToClipboard(url), messages, {
      copied: messages.task_share_copied(),
      id: SHARE_TOAST_ID,
      reportFailure,
    });
    if (copied) setCopiedUrl(url);
  };
  const publish = () =>
    run(() =>
      call("documentShare.publish", {
        group: groupId,
        conversation: conversationId,
        message: target.messageId,
        index: target.attachmentIndex,
      })
    );
  // A new link is created to be pasted somewhere, so it lands on the clipboard. Safari denies a write that
  // late: that miss stays quiet, since the link and Copy link are on screen.
  const create = async () => {
    const created = await publish();
    if (created) await copy(created.url, { reportFailure: false });
  };
  const share = shown.status === "ready" ? (shown.share ?? undefined) : undefined;
  const copied = share !== undefined && copiedUrl === share.url;
  // The link shows another version than the page does.
  const other =
    share !== undefined &&
    (share.message_id !== target.messageId || share.index !== target.attachmentIndex);

  return (
    <Dialog
      description={messages.document_share_intro()}
      isOpen
      onOpenChange={(isOpen) => {
        if (!isOpen) onClose();
      }}
      showCloseButton
      title={messages.task_share_title({ title: fileName })}
    >
      <div className="flex w-full flex-col gap-xl" data-testid="document-share-dialog">
        {shown.status === "loading" ? (
          <output
            aria-busy="true"
            aria-label={messages.common_loading()}
            className="block h-4xl w-full rounded-md bg-quaternary motion-safe:animate-pulse"
          />
        ) : shown.status === "failed" ? (
          <div className="flex min-h-4xl items-center justify-between gap-md">
            <p className="text-sm text-error-primary" role="alert">
              {messages.task_share_load_failed()}
            </p>
            <Button
              className={dialogActionButton}
              hierarchy="secondary-gray"
              onPress={() => void read()}
              size="sm"
            >
              {messages.share_view_retry()}
            </Button>
          </div>
        ) : share ? (
          <div className="flex flex-col gap-md">
            {other ? (
              <div
                className="flex items-center gap-md rounded-lg bg-tertiary py-xs pr-xs pl-md"
                data-testid="document-share-other-version"
              >
                <CircleInfoIcon className="size-4 shrink-0 text-fg-quaternary" />
                <p className="min-w-0 flex-1 text-sm text-secondary">
                  {messages.document_share_other_version()}
                </p>
                <Button
                  className={dialogActionButton}
                  hierarchy="secondary-gray"
                  isPending={pending}
                  onPress={() => void publish()}
                  size="sm"
                >
                  {messages.task_share_update()}
                </Button>
              </div>
            ) : null}
            <div className="flex items-center gap-sm">
              <label className="flex h-4xl min-w-0 flex-1 cursor-text items-center gap-sm rounded-md border border-primary bg-primary px-md shadow-xs focus-within:shadow-focus-gray-shadow-xs">
                <GlobeIcon className="size-4 shrink-0 text-fg-quaternary" />
                <input
                  aria-label={messages.task_share_link_label()}
                  className="min-w-0 flex-1 truncate bg-transparent text-sm text-secondary outline-none"
                  data-testid="document-share-url"
                  onFocus={(event) => event.currentTarget.select()}
                  readOnly
                  value={share.url}
                />
              </label>
              <MenuTrigger>
                <Button
                  aria-label={messages.task_share_actions()}
                  className="size-8 rounded-md p-0"
                  hierarchy="secondary-gray"
                  iconLeading={<MoreHorizontalIcon />}
                  iconOnly
                  isPending={pending}
                  size="sm"
                />
                <MenuPopover offset={spacing.xs} placement="bottom end">
                  <Menu
                    aria-label={messages.task_share_actions()}
                    className={menuCompactClasses}
                    onAction={(key) => {
                      if (key === "open") void openUrlInExternalBrowser(share.url);
                      else if (key === "reset")
                        void run(() => call("documentShare.reset", document));
                      else if (key === "stop")
                        void run(() => call("documentShare.revoke", document));
                    }}
                  >
                    <MenuItem id="open">{messages.task_share_open()}</MenuItem>
                    <MenuItem id="reset">{messages.task_share_reset()}</MenuItem>
                    <MenuSeparator />
                    <MenuItem id="stop" tone="destructive">
                      {messages.task_share_stop()}
                    </MenuItem>
                  </Menu>
                </MenuPopover>
              </MenuTrigger>
              <Button
                className={dialogActionButton}
                hierarchy="primary"
                isPending={pending}
                onPress={() => void copy(share.url)}
                size="sm"
              >
                {/* Both states hold the cell, so confirming a copy never resizes the button or the link. */}
                <span className="-ml-xxs grid">
                  <span className={cx(copyLabelClassName, copied && "invisible")}>
                    <ChainLinkIcon className="size-4" />
                    {messages.task_share_copy()}
                  </span>
                  <span className={cx(copyLabelClassName, !copied && "invisible")}>
                    <CheckIcon className="size-4" />
                    {messages.task_share_copied()}
                  </span>
                </span>
              </Button>
            </div>
          </div>
        ) : (
          <div className="flex min-h-4xl items-center justify-between gap-md">
            <p className="text-sm text-tertiary">{messages.task_share_unshared()}</p>
            <Button
              className={dialogActionButton}
              hierarchy="primary"
              iconLeading={<ChainLinkIcon />}
              isPending={pending}
              onPress={() => void create()}
              size="sm"
            >
              {messages.task_share_create()}
            </Button>
          </div>
        )}
      </div>
    </Dialog>
  );
}

/** The document toolbar's Share: it opens the dialog of the document's public link. */
export function DocumentShareButton({ target }: { target: DocumentShareTarget }) {
  const messages = useCommaMessages();
  const [open, setOpen] = useState(false);
  return (
    <>
      <Tooltip content={messages.task_share_button()} placement="bottom">
        <ShellIconButtonControl
          aria-label={messages.task_share_button()}
          data-testid="file-preview-share"
          icon={<ChainLinkIcon className="comma-input-icon" />}
          onPress={() => setOpen(true)}
        />
      </Tooltip>
      {open ? (
        <DocumentShareDialog onClose={() => setOpen(false)} target={target} />
      ) : null}
    </>
  );
}
