import { useCall } from "@comma/core-client";
import {
  isImageAttachment,
  isTranscodedImageAttachment,
  MAX_ATTACHMENTS_PER_MESSAGE,
  type AttachmentUploadInput,
} from "@comma/core/chat";
import { useCommaMessages } from "@comma/i18n/react";
import { toast } from "@comma/ui/components/toast";
import { useCallback, useEffect, useId, useRef, useState } from "react";
import type { IntakeUpload } from "../../chat/composer/fileIntake";
import { readAsBase64, stationUploadMaxBytes } from "./stationUpload";

/** A file put where its Task runs: a workspace file of the Router chat, or a file on the station. */
export type TaskUpload = { name: string; path: string; size: number };

/** A file staged for the new Task, and its upload to the place it was last chosen for. */
export type TaskAttachment = IntakeUpload & {
  file: AttachmentUploadInput;
  isImage: boolean;
  /** The image's own bytes as a blob URL, for its tile. */
  thumbnail?: string | undefined;
  /** Where its upload goes: the cloud (`cloud`) or a station's id; none until the window knows where the Task runs. */
  place: string | undefined;
  /** Counts its uploads, so an answer for one started before is not taken as the one under way. */
  attempt: number;
  upload?: TaskUpload | undefined;
  /**
   * It cannot go as it is: too many files (anywhere), or too large for a station (`size`, which another place is tried
   * for again). No upload is tried for it.
   */
  refused?: "count" | "size" | undefined;
};

let nextAttachmentId = 0;

/**
 * The files of a Task being made, taken as the composer takes them and uploaded as each is added, to where the Task
 * runs: the workspace's Router chat for the cloud (`chat.uploadTaskFile`), else the chosen station (`stations.upload`).
 * Choosing another place uploads them all again there; with no place yet, they wait for one. `uploads()` waits for
 * those under way.
 */
export function useTaskAttachments({
  cloud,
  place,
  workspace,
}: {
  /** The place id that means Comma's cloud. */
  cloud: string;
  place: string | undefined;
  workspace: string;
}) {
  const call = useCall();
  const messages = useCommaMessages();
  const heicToastId = `new-task-heic-${useId()}`;
  const [attachments, setAttachments] = useState<TaskAttachment[]>([]);
  const attachmentsRef = useRef(attachments);
  attachmentsRef.current = attachments;
  // The upload under way for each file, at its place and attempt.
  const inFlight = useRef(new Map<string, Promise<TaskUpload>>());

  const uploadTo = useCallback(
    async (to: string, file: AttachmentUploadInput): Promise<TaskUpload> =>
      to === cloud
        ? call("chat.uploadTaskFile", {
            workspaceId: workspace,
            name: file.name,
            bytes: new Uint8Array(await file.data.arrayBuffer()),
          })
        : call("stations.upload", {
            workspace,
            station: to,
            name: file.name,
            bytes: await readAsBase64(file.data),
          }),
    [call, cloud, workspace]
  );

  const start = useCallback(
    (attachment: TaskAttachment) => {
      const { attempt, id, place: to } = attachment;
      if (to === undefined) return;
      const settle = (patch: Partial<TaskAttachment>) =>
        setAttachments((current) =>
          current.map((a) =>
            a.id === id && a.attempt === attempt ? { ...a, ...patch } : a
          )
        );
      // A station takes 8 MB at most: said here, before the file is read to go up.
      if (to !== cloud && attachment.file.size > stationUploadMaxBytes) {
        inFlight.current.delete(id);
        settle({
          status: "failed",
          error: messages.stations_attachment_too_large(),
          refused: "size",
        });
        return;
      }
      const upload = uploadTo(to, attachment.file);
      inFlight.current.set(id, upload);
      upload.then(
        (done) => settle({ status: "uploaded", upload: done, error: undefined }),
        (failure: unknown) =>
          settle({
            status: "failed",
            error: failure instanceof Error ? failure.message : String(failure),
          })
      );
    },
    [cloud, messages, uploadTo]
  );

  const attach = useCallback(
    (files: AttachmentUploadInput[]) => {
      // A browser cannot decode HEIC/HEIF and the runtime cannot read it either, so with no host transcoder on this
      // path the file is turned away with guidance, as the composer turns it away.
      const admitted = files.filter((file) => !isTranscodedImageAttachment(file.name));
      if (admitted.length !== files.length)
        toast.error(messages.chat_heic_unsupported_browser(), {
          id: heicToastId,
          testId: "chat-heic-unsupported",
        });
      const staged = attachmentsRef.current.length;
      const added = admitted.map((file, index): TaskAttachment => {
        const isImage = isImageAttachment(file.name);
        const refused = staged + index >= MAX_ATTACHMENTS_PER_MESSAGE;
        return {
          attempt: 0,
          file,
          id: `task-file-${nextAttachmentId++}`,
          isImage,
          name: file.name,
          place,
          size: file.size,
          ...(refused
            ? {
                error: messages.chat_too_many_attachments(),
                refused: "count" as const,
                status: "failed" as const,
              }
            : { status: "uploading" as const }),
          ...(isImage ? { thumbnail: URL.createObjectURL(file.data) } : {}),
        };
      });
      if (added.length === 0) return;
      setAttachments((current) => [...current, ...added]);
      for (const attachment of added) if (!attachment.refused) start(attachment);
    },
    [heicToastId, messages, place, start]
  );

  // Another place chosen: each file goes up again there.
  useEffect(() => {
    if (place === undefined) return;
    const moved = attachmentsRef.current.flatMap((a) =>
      a.place === place || a.refused === "count"
        ? []
        : [
            {
              ...a,
              attempt: a.attempt + 1,
              place,
              status: "uploading" as const,
              upload: undefined,
              error: undefined,
              refused: undefined,
            },
          ]
    );
    if (moved.length === 0) return;
    const byId = new Map(moved.map((a) => [a.id, a]));
    setAttachments((current) => current.map((a) => byId.get(a.id) ?? a));
    for (const attachment of moved) start(attachment);
  }, [place, start]);

  const remove = useCallback((id: string) => {
    const gone = attachmentsRef.current.find((a) => a.id === id);
    if (gone?.thumbnail) URL.revokeObjectURL(gone.thumbnail);
    inFlight.current.delete(id);
    setAttachments((current) => current.filter((a) => a.id !== id));
  }, []);

  const retry = useCallback(
    (id: string) => {
      const failed = attachmentsRef.current.find((a) => a.id === id);
      if (!failed || failed.refused || failed.status !== "failed") return;
      const again = {
        ...failed,
        attempt: failed.attempt + 1,
        status: "uploading" as const,
        error: undefined,
      };
      setAttachments((current) => current.map((a) => (a.id === id ? again : a)));
      start(again);
    },
    [start]
  );

  // The thumbnails go with the window.
  useEffect(
    () => () => {
      for (const a of attachmentsRef.current)
        if (a.thumbnail) URL.revokeObjectURL(a.thumbnail);
    },
    []
  );

  /** Every staged file's upload at the place chosen now, once those under way have landed. */
  const uploads = useCallback(
    () =>
      Promise.all(
        attachmentsRef.current.map(
          (a) => inFlight.current.get(a.id) ?? Promise.reject(new Error(a.error))
        )
      ),
    []
  );

  return {
    attach,
    attachments,
    anyFailed: attachments.some((a) => a.status === "failed"),
    remove,
    retry,
    uploads,
  };
}
