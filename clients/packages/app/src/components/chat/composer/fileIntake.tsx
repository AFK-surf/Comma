import { ATTACHMENT_ACCEPT, type AttachmentUploadInput } from "@comma/core/chat";
import { formatNumber, type CommaLocale } from "@comma/i18n";
import { useCommaMessages } from "@comma/i18n/react";
import { toast } from "@comma/ui/components/toast";
import {
  useCallback,
  useEffect,
  useRef,
  type ChangeEvent,
  type ReactNode,
} from "react";

/** A file as an attachment intake takes it: its bytes, name and size. */
export const attachmentsFromFiles = (files: File[]): AttachmentUploadInput[] =>
  files.map((file) => ({
    data: file,
    name: file.name,
    size: file.size,
  }));

/** The files of a drop's or a paste's DataTransfer, to `onAttachFiles`; nothing when it carries none. */
export const attachTransferredFiles = (
  transfer: DataTransfer,
  onAttachFiles: ((files: AttachmentUploadInput[]) => void) | undefined
) => {
  const files = Array.from(transfer.files);
  if (files.length > 0) onAttachFiles?.(attachmentsFromFiles(files));
};

/**
 * The composer's file intake, for any surface that takes files as the composer does: the file picker (the host's own,
 * `onPickAttachments`, or a hidden file input), a drop and a paste (one intake for both), and no window navigation to a
 * file dropped outside the surface. Each takes `onAttachFiles`.
 *
 * `fileInput` is the hidden input, to render where the surface renders; `attachPress` opens the picker and settles once
 * it closes; `transferFiles` takes a drop's or a paste's DataTransfer. Each is undefined when the surface takes no files.
 */
export function useFileIntake({
  onAttachFiles,
  onPickAttachments,
}: {
  onAttachFiles?: ((files: AttachmentUploadInput[]) => void) | undefined;
  onPickAttachments?: (() => unknown) | undefined;
}): {
  attachPress: (() => Promise<void> | undefined) | undefined;
  fileInput: ReactNode;
  transferFiles: ((transfer: DataTransfer) => void) | undefined;
} {
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const pendingFilePickerFinishRef = useRef<(() => void) | null>(null);

  const handleAttachPress = useCallback(() => {
    if (onPickAttachments) {
      try {
        return Promise.resolve(onPickAttachments()).then(
          () => undefined,
          () => undefined
        );
      } catch {
        // Native selection failures remain inside the Main-owned command boundary.
        return Promise.resolve();
      }
    }

    const input = fileInputRef.current;
    if (!input) return;

    pendingFilePickerFinishRef.current?.();
    return new Promise<void>((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        input.removeEventListener("change", finish);
        input.removeEventListener("cancel", finish);
        if (pendingFilePickerFinishRef.current === finish) {
          pendingFilePickerFinishRef.current = null;
        }
        resolve();
      };

      pendingFilePickerFinishRef.current = finish;
      input.addEventListener("change", finish, { once: true });
      input.addEventListener("cancel", finish, { once: true });
      try {
        input.click();
      } catch (error) {
        finish();
        throw error;
      }
    });
  }, [onPickAttachments]);

  useEffect(
    () => () => {
      pendingFilePickerFinishRef.current?.();
    },
    []
  );

  const handleFilesSelected = (event: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.currentTarget.files ?? []);
    if (files.length > 0) {
      onAttachFiles?.(attachmentsFromFiles(files));
    }
    event.currentTarget.value = "";
  };

  // Shared by the drop overlay and Cmd/Ctrl+V: both hand over a DataTransfer,
  // and both take the same intake, so a pasted file is admitted, reported, and
  // retried exactly like a dropped one.
  const handleTransferredFiles = useCallback(
    (transfer: DataTransfer) => attachTransferredFiles(transfer, onAttachFiles),
    [onAttachFiles]
  );

  useEffect(() => {
    if (!onAttachFiles) {
      return undefined;
    }

    const preventWindowFileNavigation = (event: DragEvent) => {
      if (!Array.from(event.dataTransfer?.types ?? []).includes("Files")) {
        return;
      }
      event.preventDefault();
    };

    window.addEventListener("dragover", preventWindowFileNavigation);
    window.addEventListener("drop", preventWindowFileNavigation);
    return () => {
      window.removeEventListener("dragover", preventWindowFileNavigation);
      window.removeEventListener("drop", preventWindowFileNavigation);
    };
  }, [onAttachFiles]);

  return {
    attachPress: onAttachFiles || onPickAttachments ? handleAttachPress : undefined,
    fileInput: onAttachFiles ? (
      <input
        ref={fileInputRef}
        accept={ATTACHMENT_ACCEPT}
        className="app-sr-only"
        multiple
        onChange={handleFilesSelected}
        tabIndex={-1}
        type="file"
      />
    ) : null,
    transferFiles: onAttachFiles ? handleTransferredFiles : undefined,
  };
}

/** An attachment's upload, as its chip tells it. */
export type IntakeUpload = {
  id: string;
  name: string;
  size?: number | undefined;
  status: "uploading" | "uploaded" | "failed";
  error?: string | undefined;
  /** Why it failed where trying again changes nothing (too many files, too large): the toast offers no retry for it. */
  refused?: string | undefined;
};

/**
 * Upload failures surface as ONE aggregated error toast (`toastId`), however many
 * attachments failed - sonner updates the same id in place, so repeated
 * failures never stack or replay the enter animation. The toast dismisses
 * itself once every failure is retried away or removed.
 */
export function useUploadFailureToast(
  attachments: readonly IntakeUpload[],
  toastId: string,
  onRetry: ((id: string) => void) | undefined,
  onRemove: ((id: string) => void) | undefined
) {
  const messages = useCommaMessages();
  const failedAttachments = attachments.filter(
    (attachment) => attachment.status === "failed"
  );
  const failedAttachmentsKey = failedAttachments
    .map((attachment) => `${attachment.id}\u0000${attachment.error ?? ""}`)
    .join("\n");
  useEffect(() => {
    if (failedAttachments.length === 0) {
      toast.dismiss(toastId);
      return;
    }

    const first = failedAttachments[0]!;
    const title =
      failedAttachments.length === 1
        ? messages.chat_upload_failed_named({ name: first.name })
        : messages.chat_upload_failed_count({ count: failedAttachments.length });
    // One shared failure reason (the common case - e.g. the connector is
    // down) reads as the detail; mixed reasons fall back to the file list.
    const distinctErrors = [
      ...new Set(
        failedAttachments.flatMap((attachment) =>
          attachment.error ? [attachment.error] : []
        )
      ),
    ];
    const description =
      failedAttachments.length === 1
        ? first.error
        : distinctErrors.length === 1
          ? distinctErrors[0]
          : failedAttachments.map((attachment) => attachment.name).join(", ");
    const failedIds = failedAttachments.map((attachment) => attachment.id);
    const retryIds = failedAttachments
      .filter((attachment) => !attachment.refused)
      .map((attachment) => attachment.id);

    toast.error(title, {
      ...(description ? { description } : {}),
      actions: [
        ...(retryIds.length > 0
          ? [
              {
                label: messages.chat_retry_upload(),
                onPress: () => {
                  for (const id of retryIds) onRetry?.(id);
                },
              },
            ]
          : []),
        {
          hierarchy: "tertiary-gray",
          label: messages.chat_remove_attachment(),
          onPress: () => {
            for (const id of failedIds) onRemove?.(id);
          },
        },
      ],
      id: toastId,
      testId: "chat-upload-error",
    });
    // failedAttachmentsKey covers the identity-unstable failedAttachments array.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [failedAttachmentsKey, messages, onRemove, onRetry, toastId]);
  useEffect(
    () => () => {
      toast.dismiss(toastId);
    },
    [toastId]
  );
}

/** What an attachment's chip says under its name: its upload under way or failed, or its size. */
export function attachmentMeta(
  attachment: Pick<IntakeUpload, "size" | "status">,
  locale: CommaLocale,
  uploadingLabel: string,
  uploadFailedLabel: string
) {
  if (attachment.status === "uploading") {
    return uploadingLabel;
  }

  if (attachment.status === "failed") {
    return uploadFailedLabel;
  }

  return formatAttachmentSize(attachment.size, locale);
}

function formatAttachmentSize(size: number | undefined, locale: CommaLocale) {
  if (size === undefined || !Number.isFinite(size) || size < 0) {
    return undefined;
  }

  if (size < 1024) {
    return `${formatNumber(size, locale, { maximumFractionDigits: 0 })} B`;
  }

  if (size < 1024 * 1024) {
    return `${formatNumber(size / 1024, locale, { maximumFractionDigits: 0 })} KB`;
  }

  return `${formatNumber(size / (1024 * 1024), locale, {
    maximumFractionDigits: 1,
  })} MB`;
}
