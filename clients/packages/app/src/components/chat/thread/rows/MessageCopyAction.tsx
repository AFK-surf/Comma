import { useCommaMessages } from "@comma/i18n/react";
import { CheckIcon, CopyIcon, Tooltip, toast } from "@comma/ui";
import { memo, useEffect, useRef, useState } from "react";
import { Button as AriaButton } from "react-aria-components";
import { copyTextToClipboard } from "../inline/linkActions";

// Shared id so copying several messages in a row updates one toast in place
// instead of stacking, and a failure replaces the success it invalidates.
const COPY_TOAST_ID = "copy-feedback";

export const MessageCopyAction = memo(function MessageCopyAction({
  ariaLabel,
  copyText,
  messageId,
}: {
  ariaLabel: string;
  copyText: string;
  messageId: string;
}) {
  const messagesApi = useCommaMessages();
  const [copied, setCopied] = useState(false);
  const copiedTimerRef = useRef<number | undefined>(undefined);

  useEffect(
    () => () => {
      if (copiedTimerRef.current) {
        window.clearTimeout(copiedTimerRef.current);
      }
    },
    []
  );

  const handleCopy = async () => {
    try {
      await copyTextToClipboard(copyText);
    } catch {
      // The clipboard write used to fail silently; say so instead.
      toast.error(messagesApi.copy_failed_title(), {
        description: messagesApi.copy_failed_detail(),
        id: COPY_TOAST_ID,
        testId: "copy-feedback",
      });
      return;
    }
    toast.info(messagesApi.copy_message_title(), {
      description: messagesApi.copy_message_detail(),
      id: COPY_TOAST_ID,
      testId: "copy-feedback",
    });
    setCopied(true);
    if (copiedTimerRef.current) {
      window.clearTimeout(copiedTimerRef.current);
    }
    copiedTimerRef.current = window.setTimeout(() => {
      setCopied(false);
      copiedTimerRef.current = undefined;
    }, 800);
  };

  return (
    <div
      className="comma-chat-message-actions"
      data-testid={`chat-message-actions-${messageId}`}
    >
      <Tooltip content={messagesApi.common_copy()} placement="bottom">
        <AriaButton
          aria-label={copied ? messagesApi.chat_copied() : ariaLabel}
          className="comma-chat-message-action-button"
          data-no-press-feedback
          onPress={handleCopy}
          type="button"
        >
          <MessageCopyStateIcon copied={copied} />
        </AriaButton>
      </Tooltip>
    </div>
  );
});

function MessageCopyStateIcon({ copied }: { copied: boolean }) {
  return (
    <span
      aria-hidden="true"
      className="t-icon-swap size-4"
      data-state={copied ? "b" : "a"}
      data-swap-blur="none"
    >
      <span className="t-icon inline-flex size-4" data-icon="a">
        <CopyIcon className="size-4" />
      </span>
      <span
        className="comma-chat-message-copy-success-icon t-icon inline-flex size-4"
        data-icon="b"
      >
        <CheckIcon className="size-4 text-fg-success-primary" />
      </span>
    </span>
  );
}
