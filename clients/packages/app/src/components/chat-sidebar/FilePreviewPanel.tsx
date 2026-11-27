import type { ChatConversationFile } from "@comma/chat-contract";
import type { AttachmentUploadInput } from "@comma/core/chat";
import { CoreError, useCall, useTopic } from "@comma/core-client";
import { formatDate } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import {
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { uiClock } from "@comma/ui/clock";
import { CommaAuthContext } from "../auth-context";
import { CommaProductMark } from "../CommaProductMark";
import { getUserDisplayName, UserAvatar } from "../UserAvatar";
import { useProfileAvatarUrl } from "../useProfileAvatarUrl";
import { createFileDownloadCapability } from "../../runtime-files/fileDownloads";
import { createFileOpenInAction } from "../../runtime-files/fileOpenActions";
import {
  conversationFileSource,
  conversationFileSourceKey,
  readConversationFileRange,
  readFileBlob,
  resolveConversationFile,
  conversationFileLink,
  readConversationFileParts,
  saveConversationFile,
  type ConversationFileSource,
} from "../../runtime-files/fileSources";
import { useChatRegistry } from "../chat/ChatProvider";
import { driveStreamMediaType } from "../drive/driveStore";
import { filePreviewKind, textPreviewLimit } from "../file-preview/FilePreviewContent";
import { stagedDocumentPictures, type StagedDocumentPicture } from "./documentCarry";
import { savedDocumentEdits } from "./savedDocumentEdits";
import type { DocumentVersion } from "./sentDocuments";
import type { DocumentWriter } from "../file-preview/DocumentFilePreview";
import type { DocumentEdit } from "../file-preview/DocumentSelectionEdit";
import { toast } from "@comma/ui/components/toast";
import { InWindowNotice } from "@comma/ui/components/in-window-notice";
import { PictureInPictureIcon } from "@comma/ui/components/icons";
import { Tooltip } from "@comma/ui/components/tooltip";
import { ShellIconButtonControl } from "../ShellIconButton";
import { DocumentShareButton } from "./DocumentShareButton";
import {
  selectionFiles,
  useConversationDraftSelections,
  useStageDraftSelection,
} from "../chat/composer/draftSelections";
import { formatAttachmentSize } from "../chat/thread/attachments/attachmentLabels";
import type { DocumentImages } from "../file-preview/DocumentEditor";
import { MAX_ATTACHMENT_BYTES, MAX_ATTACHMENTS_PER_MESSAGE } from "@comma/core/chat";
import { documentFileMarkdown } from "../file-preview/documentExport";
import type { RangedFile } from "../file-preview/PdfFilePreview";
import { FilePreviewPanel as SharedFilePreviewPanel } from "../file-preview/FilePreviewPanel";

const imageTypeByExtension: Record<string, string> = {
  avif: "image/avif",
  bmp: "image/bmp",
  gif: "image/gif",
  ico: "image/x-icon",
  jpeg: "image/jpeg",
  jpg: "image/jpeg",
  png: "image/png",
  svg: "image/svg+xml",
  webp: "image/webp",
};

/** The type an audio, video or image attachment is read as: the one it declares, else its name's. */
export function streamMediaType(
  source: ConversationFileSource,
  kind: "audio" | "video" | "image"
) {
  const declared = source.mimeType?.split(";")[0]?.trim().toLowerCase();
  if (declared?.startsWith(`${kind}/`)) return declared;
  if (kind !== "image") return driveStreamMediaType(source.fileName);
  const extension = source.fileName.split(".").at(-1)?.toLowerCase() ?? "";
  return imageTypeByExtension[extension] ?? "image/png";
}

export { documentVersionsIn, type DocumentVersion } from "./sentDocuments";

const dayMs = 86_400_000;
const startOfDay = (at: number) => new Date(at).setHours(0, 0, 0, 0);

/** When a version was written, as a reader says it: "Today at 3:17 PM", "Yesterday at …", "Jul 3 at …". */
function versionTime(
  at: number,
  locale: ReturnType<typeof useCommaLocale>,
  messages: ReturnType<typeof useCommaMessages>
) {
  const now = uiClock.now();
  const days = Math.round((startOfDay(now) - startOfDay(at)) / dayMs);
  const day =
    days === 0
      ? messages.inbox_today()
      : days === 1
        ? messages.inbox_yesterday()
        : formatDate(at, locale, {
            day: "numeric",
            month: "short",
            ...(new Date(at).getFullYear() === new Date(now).getFullYear()
              ? {}
              : { year: "numeric" }),
          });
  return messages.file_preview_document_version_time({
    day,
    time: formatDate(at, locale, { timeStyle: "short" }),
  });
}

// The page goes on showing a picture from the file it was given once a message has carried it: reading it from
// the conversation again would show nothing new. The oldest go when a document has more than this many.
const maxStagedPictures = 16;
const pictureTypes: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/gif": "gif",
  "image/webp": "webp",
  "image/svg+xml": "svg",
  "video/webm": "webm",
  "video/mp4": "mp4",
  "video/quicktime": "mov",
};
/** The kind a picture's file is read as, by its name's ending: what the page draws it by. */
const pictureType = (name: string) => {
  const ending = /\.([^.]+)$/u.exec(name)?.[1]?.toLowerCase();
  return (
    Object.entries(pictureTypes).find(([, one]) => one === ending)?.[0] ??
    (ending === "jpeg" ? "image/jpeg" : "")
  );
};
/**
 * A file name a document names a picture by: the picture's own name without what a Markdown address cannot hold,
 * with its kind's ending, and a number after it where `taken` has the name.
 */
function pictureName(file: File, taken: (name: string) => boolean) {
  const ending = pictureTypes[file.type] ?? "png";
  const stem =
    file.name
      .replace(/\.[^.]*$/u, "")
      .replaceAll(/[\s/\\?#:()[\]]+/gu, "-")
      .replace(/^-+|-+$/gu, "") || "image";
  for (let count = 1; ; count += 1) {
    const name = `${stem}${count > 1 ? `-${count}` : ""}.${ending}`;
    if (!taken(name)) return name;
  }
}

// The versions whose writing a tab has shown: coming back to the tab does not write one again.
const writtenDocuments = new WeakSet<ConversationFileSource>();

export function FilePreviewPanel({
  source,
  writer,
  editConversationId,
  alone = false,
  shareable,
  pictures,
  versions,
  onSelectVersion,
  inWindow,
  panelId,
  onOpenBrowser,
  onAttachFiles,
  annotationContext,
  onAttachConversationFiles,
}: {
  annotationContext?:
    | {
        scope: string;
        onSend: (
          text: string,
          files?: { bytes: Uint8Array; name: string; size: number }[]
        ) => void;
      }
    | undefined;
  source: ConversationFileSource;
  /** The Agent whose version of a document `source` is, and whether it is at work now. */
  writer?: DocumentWriter | undefined;
  /** The document's versions the chat holds, oldest first, and how one of them is shown. */
  versions?: readonly DocumentVersion[] | undefined;
  onSelectVersion?: ((source: ConversationFileSource) => void) | undefined;
  /**
   * The document in a window of its own (desktop): how the panel moves it there (`from`: the panel it leaves), and
   * the window it is in. While it is in one, the panel says so in the document's place.
   */
  inWindow?:
    | { windowId?: string | undefined; onOpen: (from: Element | null) => void }
    | undefined;
  /** The conversation whose next message takes the passages a reader asks to have changed; none: read only. */
  editConversationId?: string | undefined;
  /**
   * The page has no chat beside it (the document's own window). The reader edits it, and the edits are saved on
   * the device. It does not ask Comma for a change and takes no new pictures: no message here carries either.
   */
  alone?: boolean | undefined;
  /** The document is a Task's, whose owner may give it a public link. */
  shareable?: boolean | undefined;
  /** The pictures the conversation's people sent, by file name: where each is read from (`sentPictures`). */
  pictures?: ReadonlyMap<string, string> | undefined;
  panelId: string;
  onOpenBrowser: (url: string) => void;
  onAttachFiles?: ((files: AttachmentUploadInput[]) => unknown) | undefined;
  onAttachConversationFiles?: ((files: ChatConversationFile[]) => unknown) | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const { beginAttempt } = useChatRegistry();
  const key = conversationFileSourceKey(source);
  const kind = filePreviewKind(source.fileName, source.mimeType);
  // Audio, video and images load from a ranged URL, so a file of any size
  // shows without the window holding it.
  const streamed = kind === "audio" || kind === "video" || kind === "image";
  const { value: stream } = useTopic(
    streamed
      ? {
          topic: "fileStream",
          source: JSON.stringify(conversationFileSource(source)),
          type: streamMediaType(source, kind),
        }
      : null
  );
  const mediaUrl = stream?.status === "ready" ? (stream.url ?? undefined) : undefined;
  // What the preview reads of the file: a stream (audio, video, an image), spans
  // as pages ask (a PDF) or one after another up to its limit (an office file), the
  // head it shows (text), or nothing (a type it cannot show). The file is read
  // whole only where the host cannot stream it.
  const reads = streamed
    ? stream?.status === "unsupported"
      ? "whole"
      : "stream"
    : kind === "pdf" ||
        kind === "slides" ||
        kind === "docx" ||
        kind === "xlsx" ||
        kind === "csv" ||
        kind === "notebook" ||
        kind === "json" ||
        kind === "jsonl" ||
        kind === "archive" ||
        kind === "tiff"
      ? "spans"
      : kind === "text" || kind === "markdown" || kind === "html"
        ? "head"
        : "none";
  const ranged = useMemo<RangedFile | undefined>(
    () =>
      reads === "spans"
        ? {
            read: (offset, length, signal) =>
              readConversationFileRange(call, source, offset, length, signal),
          }
        : undefined,
    [call, reads, source]
  );
  const [loaded, setState] = useState<{
    owner?: object;
    key?: string;
    blob?: Blob;
    error?: string;
  }>({});
  const state = loaded.owner === beginAttempt && loaded.key === key ? loaded : {};
  // A document's tab keeps the version it shows until the next one is read, so the page changes from one to the
  // other without a blank between them.
  const [document, setDocument] = useState<Blob>();
  const [playFirst] = useState(
    () => writer !== undefined && !writtenDocuments.has(source)
  );
  useEffect(() => {
    if (writer) writtenDocuments.add(source);
  }, [source, writer]);
  // Each mounted selection owns its request. Switch/close unmounts it; a late
  // response cannot publish another selection.
  useEffect(() => {
    if (reads !== "whole" && reads !== "head") return undefined;
    const controller = new AbortController();
    const attempt = beginAttempt();
    const signal = AbortSignal.any([controller.signal, attempt.signal]);
    let current = true;
    setState({ owner: beginAttempt, key });
    const clearRevoked = () => {
      if (current)
        setState({ owner: beginAttempt, key, error: messages.file_preview_failed() });
    };
    signal.addEventListener("abort", clearRevoked, { once: true });
    // One byte past what a text preview shows tells it whether the file goes on.
    const bytes =
      reads === "head"
        ? readConversationFileRange(call, source, 0, textPreviewLimit + 1, signal).then(
            (span) =>
              new Blob([span.bytes as Uint8Array<ArrayBuffer>], {
                type: source.mimeType ?? span.type,
              })
          )
        : resolveConversationFile(call, source, signal);
    void bytes.then(
      (blob) => {
        if (!current || signal.aborted || !attempt.isCurrent()) return;
        setState({ owner: beginAttempt, key, blob });
        if (kind === "markdown") setDocument(blob);
      },
      (error: unknown) => {
        if (current)
          setState({
            owner: beginAttempt,
            key,
            error:
              error instanceof CoreError && error.code === "too_large"
                ? messages.file_preview_too_large()
                : messages.file_preview_failed(),
          });
      }
    );
    return () => {
      current = false;
      signal.removeEventListener("abort", clearRevoked);
      controller.abort();
      attempt.release();
    };
  }, [call, key, kind, source, beginAttempt, messages, reads]);
  // The desktop saves it into Downloads as it arrives, and a browser downloads
  // it from its media URL: either at any size.
  const save = useMemo(() => saveConversationFile(call, source), [call, source]);
  const link = useMemo(() => conversationFileLink(call, source), [call, source]);
  const parts = useMemo(() => readConversationFileParts(call, source), [call, source]);
  const download = useMemo(
    () => ({
      fileName: source.fileName,
      // A document is saved as Markdown other products take, written from what was read of it; any other file is
      // saved as its own bytes, at any size.
      capability:
        kind === "markdown"
          ? createFileDownloadCapability(
              async (signal) =>
                new Blob(
                  [
                    documentFileMarkdown(
                      await (await resolveConversationFile(call, source, signal)).text()
                    ),
                  ],
                  { type: "text/markdown;charset=utf-8" }
                ),
              { locale }
            )
          : createFileDownloadCapability(
              (signal) => resolveConversationFile(call, source, signal),
              { locale },
              { save, link, parts }
            ),
    }),
    [call, kind, source, locale, save, link, parts]
  );
  // A passage a reader asks to have changed is staged with the chat's next message, as a picked element is.
  const stage = useStageDraftSelection();
  const { items: selections } = useConversationDraftSelections(editConversationId);
  const documentEdits = useMemo(
    () =>
      stage && editConversationId && kind === "markdown" && !alone
        ? {
            staged: selections.flatMap(({ id, about }) =>
              about.kind === "document" && about.reference === key
                ? [{ id, start: about.start, end: about.end, quote: about.quote }]
                : []
            ),
            onAdd: ({ note, ...passage }: DocumentEdit) => {
              const staged = stage(editConversationId, {
                note,
                about: {
                  kind: "document",
                  fileName: source.fileName,
                  reference: key,
                  ...passage,
                },
              });
              if (!staged) toast.warning(messages.chat_selections_full());
              return staged;
            },
          }
        : undefined,
    [alone, editConversationId, key, kind, messages, selections, source.fileName, stage]
  );
  // The version shown among the chat's, and the earlier one the page compares it with: the one before it, or
  // another the reader chose for this version.
  const versionIndex = versions?.findIndex(
    (version) => conversationFileSourceKey(version.source) === key
  );
  const previous =
    versionIndex !== undefined && versionIndex > 0
      ? versions![versionIndex - 1]!.source
      : undefined;
  const [comparing, setComparing] = useState<{ of: string; base: string }>();
  const [compared, setCompared] = useState<{ key: string; blob: Blob }>();
  const base =
    comparing === undefined || versionIndex === undefined
      ? undefined
      : ((comparing.of === key
          ? versions
              ?.slice(0, versionIndex)
              .find(
                (version) =>
                  conversationFileSourceKey(version.source) === comparing.base
              )?.source
          : undefined) ?? previous);
  const baseKey = base ? conversationFileSourceKey(base) : undefined;
  useEffect(() => {
    if (!base) return undefined;
    const controller = new AbortController();
    void readConversationFileRange(
      call,
      base,
      0,
      textPreviewLimit + 1,
      controller.signal
    ).then(
      (span) =>
        setCompared({
          key: conversationFileSourceKey(base),
          blob: new Blob([span.bytes as Uint8Array<ArrayBuffer>], { type: span.type }),
        }),
      // The earlier version cannot be read: the page stays the version itself.
      () => undefined
    );
    return () => controller.abort();
    // The version is its key: a new object for the same attachment reads nothing again.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [call, baseKey]);
  // The reader's own versions carry their name and picture, as their messages do.
  const auth = useContext(CommaAuthContext);
  const avatarUrl = useProfileAvatarUrl(
    kind === "markdown" ? auth?.avatarRevision : undefined
  );
  const you = auth
    ? getUserDisplayName({ displayName: auth.userDisplayName, email: auth.userEmail })
    : messages.file_preview_document_version_you();
  // The reader's edits are of the version shown: another version in the tab has its own, or none. They are saved on
  // this device as they are made (`savedDocumentEdits`). Nothing is sent for them alone, and the composer shows
  // nothing of them: the chat's next message carries them as a file of the document's name (`documentCarry`), so
  // Comma works from them when the reader next writes.
  const edits = kind === "markdown" && editConversationId !== undefined;
  const fileName = source.fileName;
  // The times the page's text was set from outside it (a version restored, edits discarded): the editor starts
  // anew on each.
  const [resets, setResets] = useState(0);
  const pictureScope = `${editConversationId ?? ""}\n${fileName}`;
  // What this page saved itself of the version it shows: edits that are not it came from outside the page.
  const ownSave = useRef<
    { reference: string; markdown: string | undefined } | undefined
  >(undefined);
  /** Saves the reader's version of the document, made from version `reference`; undefined: the file again. */
  const stageVersion = useCallback(
    (reference: string, markdown: string | undefined) => {
      ownSave.current = { reference, markdown };
      if (markdown === undefined) savedDocumentEdits.delete(reference);
      else savedDocumentEdits.set(reference, markdown);
    },
    []
  );
  // The document's pictures, for its page: the ones the reader put in and no message has carried yet, then the
  // ones the conversation's people sent. The page holds this for as long as it is the same document.
  const sent = useRef(pictures);
  sent.current = pictures;
  const groupId = source.groupId;
  // How many more files the chat's next message takes: its selections' files, the document, and the pictures the
  // reader put in it before.
  const picturesRoom = useRef<() => number>(() => 0);
  picturesRoom.current = () =>
    MAX_ATTACHMENTS_PER_MESSAGE -
    selectionFiles(selections).length -
    1 -
    (stagedDocumentPictures.get(pictureScope)?.size ?? 0);
  const allImages = useMemo<Required<DocumentImages>>(
    () => ({
      read: async (name) => {
        const staged = stagedDocumentPictures.get(pictureScope)?.get(name);
        if (staged) return staged.file;
        const path = sent.current?.get(name);
        if (path === undefined) return undefined;
        const file = await readFileBlob(call, {
          source: "group-file",
          group: groupId,
          path,
        });
        // The page draws it by its kind, which is its name's whatever the file was stored as.
        return new Blob([file], { type: pictureType(name) || file.type });
      },
      add: (files) => {
        const staged =
          stagedDocumentPictures.get(pictureScope) ??
          new Map<string, StagedDocumentPicture>();
        stagedDocumentPictures.set(pictureScope, staged);
        const room = picturesRoom.current();
        return files.flatMap((file, index) => {
          // A message takes files up to a size and a number: what is past either is said, not put in.
          if (file.size > MAX_ATTACHMENT_BYTES) {
            toast.warning(
              messages.chat_attachment_too_large({
                limit: formatAttachmentSize(MAX_ATTACHMENT_BYTES, locale) ?? "",
              })
            );
            return [];
          }
          if (index >= room) {
            if (index === room) toast.warning(messages.chat_selections_full());
            return [];
          }
          const name = pictureName(
            file,
            (one) => staged.has(one) || sent.current?.has(one) === true
          );
          const picture: StagedDocumentPicture = { file };
          if (staged.size >= maxStagedPictures)
            staged.delete(staged.keys().next().value!);
          staged.set(name, picture);
          // The picture goes with the reader's version once its bytes are read.
          void file.arrayBuffer().then((buffer) => {
            picture.bytes = new Uint8Array(buffer);
          });
          return [name];
        });
      },
    }),
    [call, groupId, locale, messages, pictureScope]
  );
  // A picture the reader puts in goes with the chat's next message. A page with no chat beside it (the document's
  // own window) has nothing to carry one: it draws the document's pictures and takes no new ones.
  const carries = stage !== undefined && !alone;
  const documentImages = useMemo<DocumentImages>(
    () => (carries ? allImages : { read: allImages.read }),
    [allImages, carries]
  );
  // The reader's edits as the device has them: another window of the app (the document's own) may save them.
  const draft = useSyncExternalStore(savedDocumentEdits.subscribe, () =>
    savedDocumentEdits.get(key)
  );
  const sentEdits = useSyncExternalStore(savedDocumentEdits.subscribe, () =>
    savedDocumentEdits.sent(key)
  );
  // The pictures a message is carrying now: the reader's version went with one, and they have not arrived yet.
  const carriedPictures = sentEdits
    ? [...(stagedDocumentPictures.get(pictureScope)?.keys() ?? [])]
        .filter((name) => !pictures?.has(name))
        .join("\n")
    : "";
  const sending = useMemo(
    () => (carriedPictures ? new Set(carriedPictures.split("\n")) : undefined),
    [carriedPictures]
  );
  // The version whose edits the page last had, those edits, and whether a message carried them.
  const known = useRef<
    { key: string; draft: string | undefined; sent: boolean } | undefined
  >(undefined);
  useEffect(() => {
    if (!edits) return;
    const before = known.current;
    known.current = { key, draft, sent: sentEdits };
    if (before?.key !== key) return;
    const own =
      ownSave.current?.reference === key ? ownSave.current.markdown : undefined;
    // Saved or discarded outside the page while it shows this version (the document's own window closed with
    // edits): the page starts anew on what the device has. A message carried the edits: the page starts anew on
    // them, and shows them until they arrive as the document's newest version.
    if ((before.draft !== draft && draft !== own) || (sentEdits && !before.sent))
      setResets((count) => count + 1);
  }, [draft, edits, key, sentEdits]);
  // A new version of the document ends the edits of the earlier ones that a message carried: they are in it. Edits
  // no message carried stay with the version they are of.
  const versionCount = versions?.length ?? 0;
  const countedVersions = useRef(versionCount);
  useEffect(() => {
    if (versionCount > countedVersions.current) {
      for (const version of versions ?? []) {
        const versionKey = conversationFileSourceKey(version.source);
        if (savedDocumentEdits.sent(versionKey)) savedDocumentEdits.delete(versionKey);
      }
      setResets((count) => count + 1);
    }
    countedVersions.current = versionCount;
    // The versions are counted: a new list of the same ones ends nothing.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [versionCount]);
  const documentEditing = useMemo(
    () =>
      edits
        ? {
            draft,
            resets,
            onDraft: (markdown: string | undefined) => stageVersion(key, markdown),
            images: documentImages,
            sending,
          }
        : undefined,
    [documentImages, draft, edits, key, resets, sending, stageVersion]
  );
  const yourPicture = useMemo(
    () => (
      <UserAvatar
        {...(avatarUrl ? { avatarUrl } : {})}
        displayName={you}
        email={auth?.userEmail ?? ""}
        size="compact"
      />
    ),
    [auth?.userEmail, avatarUrl, you]
  );
  const unsent = draft !== undefined && !sentEdits;
  const documentVersions = useMemo(
    () =>
      versions &&
      versions.length > 0 &&
      versionIndex !== undefined &&
      versionIndex >= 0 &&
      onSelectVersion
        ? {
            items: versions.map((version, index) => ({
              id: conversationFileSourceKey(version.source),
              // A version is known by when it was written; one with no time, by its place.
              title:
                version.at === undefined
                  ? messages.file_preview_document_version({ number: index + 1 })
                  : versionTime(version.at, locale, messages),
              author:
                version.author === "agent"
                  ? messages.file_preview_document_writer()
                  : you,
              avatar:
                version.author === "agent" ? (
                  <CommaProductMark
                    className="size-xl text-primary"
                    viewBox="2 2 16 16"
                  />
                ) : (
                  yourPicture
                ),
            })),
            current: key,
            onSelect: (id: string) => {
              const chosen = versions.find(
                (version) => conversationFileSourceKey(version.source) === id
              );
              if (chosen) onSelectVersion(chosen.source);
            },
            // Restoring a version sends nothing: its text becomes the reader's edits of the newest version, which
            // go with their next message as any edit of the page does.
            ...(edits
              ? {
                  onRestore: (id: string) => {
                    const chosen = versions.find(
                      (version) => conversationFileSourceKey(version.source) === id
                    );
                    const latest = versions.at(-1)!;
                    if (!chosen) return;
                    const latestKey = conversationFileSourceKey(latest.source);
                    const text = (version: DocumentVersion) =>
                      resolveConversationFile(call, version.source).then((blob) =>
                        blob.text()
                      );
                    void Promise.all([text(chosen), text(latest)]).then(
                      ([restored, current]) => {
                        stageVersion(
                          latestKey,
                          restored === current ? undefined : restored
                        );
                        setComparing(undefined);
                        setResets((count) => count + 1);
                        if (latestKey !== key) onSelectVersion(latest.source);
                      },
                      () =>
                        toast.error(messages.file_preview_document_restore_failed(), {
                          id: "comma-document-restore",
                          testId: "comma-document-restore",
                        })
                    );
                  },
                }
              : {}),
            ...(unsent
              ? {
                  unsent: {
                    title: messages.file_preview_document_version_unsent(),
                    author: you,
                    avatar: yourPicture,
                    onDiscard: () => {
                      stageVersion(key, undefined);
                      setResets((count) => count + 1);
                    },
                  },
                }
              : {}),
            comparing: baseKey,
            onCompare: (chosen: string | undefined) =>
              setComparing(
                chosen === undefined ? undefined : { of: key, base: chosen }
              ),
          }
        : undefined,
    [
      baseKey,
      call,
      edits,
      key,
      locale,
      messages,
      onSelectVersion,
      stageVersion,
      unsent,
      you,
      yourPicture,
      versionIndex,
      versions,
    ]
  );
  const openIn = useMemo(
    () =>
      createFileOpenInAction({
        call,
        source,
        bridge: getNativeBridge(),
        locale,
        beginAttempt,
      }),
    [call, source, locale, beginAttempt]
  );
  if (inWindow?.windowId !== undefined) {
    const windowId = inWindow.windowId;
    return (
      <section
        className="flex min-h-0 min-w-0 flex-1 flex-col"
        data-testid="file-preview-panel"
        id={panelId}
        role="tabpanel"
      >
        <InWindowNotice
          description={messages.file_preview_document_in_window_description()}
          onMoveBack={() =>
            void getNativeBridge()
              .windows.close({ windowId })
              .catch(() => {})
          }
          onShowWindow={() =>
            void getNativeBridge()
              .windows.focus({ windowId })
              .catch(() => {})
          }
          testId="document-notice-in-window"
          title={messages.file_preview_document_in_window_title()}
        />
      </section>
    );
  }
  const documentWindowAction =
    inWindow && kind === "markdown" ? (
      <Tooltip
        content={messages.file_preview_document_open_window()}
        placement="bottom"
      >
        <ShellIconButtonControl
          aria-label={messages.file_preview_document_open_window()}
          data-testid="file-preview-open-window"
          icon={<PictureInPictureIcon className="comma-input-icon" />}
          onPress={(event) =>
            inWindow.onOpen(
              event.target instanceof Element
                ? event.target.closest("[role='tabpanel']")
                : null
            )
          }
        />
      </Tooltip>
    ) : null;
  return (
    <SharedFilePreviewPanel
      extraActions={
        <>
          {/* A link shows a version an Agent sent: the reader's own is a file of the Group's uploads, which a
              public reader is given no way to. */}
          {shareable && kind === "markdown" && source.workspacePath === undefined ? (
            <DocumentShareButton target={source} />
          ) : null}
          {documentWindowAction}
        </>
      }
      annotationContext={
        annotationContext
          ? {
              storageKey: `comma:artifact-notes:${annotationContext.scope}:${key}`,
              onSend: (text) => annotationContext.onSend(`Attachment: ${key}\n${text}`),
            }
          : undefined
      }
      requestEdits={
        annotationContext
          ? { reference: key, send: annotationContext.onSend }
          : undefined
      }
      fileName={source.fileName}
      mimeType={source.mimeType}
      blob={state.blob ?? (state.error ? undefined : document)}
      documentEditing={documentEditing}
      documentPictures={kind === "markdown" ? documentImages.read : undefined}
      documentVersions={documentVersions}
      documentCompare={
        baseKey !== undefined && compared?.key === baseKey ? compared.blob : undefined
      }
      documentEdits={documentEdits}
      documentWriter={writer}
      documentPlayFirst={playFirst}
      mediaUrl={mediaUrl}
      mediaKey={key}
      ranged={ranged}
      error={stream?.status === "failed" ? messages.file_preview_failed() : state.error}
      {...(reads === "none"
        ? { placeholder: messages.file_preview_unavailable() }
        : {})}
      panelId={panelId}
      testId="file-preview-panel"
      download={download}
      save={save}
      link={link}
      parts={parts}
      openIn={openIn}
      onOpenBrowser={onOpenBrowser}
      onAttachFiles={onAttachFiles}
      // A sent file is no attachment of a message to attach again by reference.
      attachment={source.workspacePath === undefined ? source : undefined}
      onAttachConversationFiles={onAttachConversationFiles}
    />
  );
}
