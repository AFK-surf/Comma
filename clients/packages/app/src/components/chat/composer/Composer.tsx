import { useApplicationMenu } from "../../application-menu/useApplicationMenu";
import {
  AiInput,
  AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX,
  GlobeIcon,
  isImeKeyEvent,
  PaperclipIcon,
  CubeIcon,
  resolveProviderBrandLogo,
  taskStatusIcon,
  toast,
  type AiInputAttachment,
  type AiInputMenuGroup,
  type AiInputMenuItem,
  type AiInputMenuRegistration,
  type AiInputSize,
} from "@comma/ui";
import { formatNumber, formatRelativeDate, type CommaLocale } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  memo,
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { nativePlatformClipboard } from "../../../runtime-chat/nativePlatformActions";
import type { CommaSkill } from "../../../api";
import { chatQuoteLabel, type ChatDraftQuote } from "./draftQuotes";
import { useComposerDraft, type ComposerDraftSource } from "./conversationDraft";
import { deriveMentionedSkills } from "./mentions";
import {
  linkMentionPlainText,
  taskMentionPlainText,
} from "../model/mentionSerialization";
import { MENTION_MENU_ID, projectMentionTokens } from "./mentionProjection";
import { ATTACHMENT_ACCEPT, isGroupImagePreviewPath } from "../model/protocol";
import type {
  AttachmentUploadInput,
  ChatImagePreviewRef,
  DraftAttachment,
  LocalFilePreview,
} from "../model/conversationChannel";
import { useRecordingFileActions } from "../../useRecordingFileActions";
import { useAudioCapture } from "../../useAudioCapture";
import { needsDesktopApp, requestDesktopApp } from "../../DesktopAppPrompt";
import {
  driveMentionSections,
  type ComposerDriveMentionItem,
  type ComposerMentionSources,
  type ComposerRoutineMentionItem,
} from "./useComposerMentionSources";
import { DriveFileIcon } from "../../drive/DriveFileIcon";
import {
  isLocalFilePreviewRef,
  useLocalFilePreviews,
} from "../thread/attachments/useLocalFilePreviews";

// Side Chat uses the small composer; collapsed height comes from that layout.
const SIDE_CHAT_TEXTAREA_MIN_HEIGHT = AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX;

/** Files the "@" panel's Drive section lists before its "View more" row. */
const DRIVE_MENU_LIMIT = 5;

/** English affordance synonyms; the localized label itself also matches. */
const addFilesKeywords = [
  "file",
  "files",
  "folder",
  "folders",
  "upload",
  "attach",
  "attachment",
] as const;

/**
 * Routine mentions carry their source's brand mark (Linear, Notion, ...);
 * unbranded entries fall back to what the mention is: a link or a Task.
 */
function RoutineMentionIcon({ routine }: { routine: ComposerRoutineMentionItem }) {
  const [failedIconUrl, setFailedIconUrl] = useState<string>();
  const BrandLogo = resolveProviderBrandLogo(routine.source?.appId);
  if (BrandLogo) {
    return <BrandLogo />;
  }
  const iconUrl = routine.source?.iconUrl;
  if (iconUrl && failedIconUrl !== iconUrl) {
    return (
      <img
        alt=""
        draggable={false}
        onError={() => setFailedIconUrl(iconUrl)}
        src={iconUrl}
      />
    );
  }
  return routine.kind === "task" ? <>{taskStatusIcon("backlog")}</> : <GlobeIcon />;
}

function PluginMentionIcon({
  brand,
  name,
}: {
  brand: string | null | undefined;
  name: string;
}) {
  const BrandLogo = resolveProviderBrandLogo(brand ?? name);
  if (BrandLogo) {
    return <BrandLogo />;
  }
  return (
    <span
      aria-hidden
      className="flex size-5 items-center justify-center rounded-xs bg-quaternary text-xs font-medium uppercase text-secondary"
    >
      {name.slice(0, 1)}
    </span>
  );
}

/**
 * The ref a draft image renders its own thumbnail from, if it has one. An
 * attachment without one will never receive a preview, so it must not be held
 * in a loading state waiting for something that is not coming.
 */
const imagePreviewRef = (attachment: DraftAttachment) =>
  isLocalFilePreviewRef(attachment.id)
    ? attachment.id
    : attachment.path && isGroupImagePreviewPath(attachment.path)
      ? attachment.path
      : undefined;

const attachmentsFromFiles = (files: File[]): AttachmentUploadInput[] =>
  files.map((file) => ({
    data: file,
    name: file.name,
    size: file.size,
  }));

// Memoized so stream-chunk emits (which change channel state but not the
// draft or any composer input) skip the composer subtree entirely.
export const Composer = memo(function Composer({
  disabled = false,
  draftSource,
  draftAttachments = [],
  draftQuotes = [],
  mentionSources,
  onAttachFiles,
  onContentHeightChange,
  onDraftChange,
  onPickAttachments,
  onPreviewLocalFile,
  onRemoveAttachment,
  onRemoveQuote,
  onRetryAttachment,
  onSend,
  placeholder,
  sendLabel,
  showVoiceButton = false,
  size,
  skills = [],
  controlCommandsEnabled = false,
  submitDisabled,
  submitPending = false,
  toolbarLeading,
  variant = "default",
}: {
  disabled?: boolean | undefined;
  /** The draft this composer edits. It subscribes alone, so a keystroke
   *  re-renders the composer and not the conversation around it. */
  draftSource: ComposerDraftSource;
  draftAttachments?: DraftAttachment[];
  draftQuotes?: ChatDraftQuote[];
  /** Tasks, routines, and plugins for the "@" panel; Add works without it. */
  mentionSources?: ComposerMentionSources | undefined;
  onAttachFiles?: (files: AttachmentUploadInput[]) => void;
  onContentHeightChange?: (height: number) => void;
  onDraftChange: (draft: string) => void;
  onPickAttachments?: () => unknown;
  onPreviewLocalFile?:
    | ((
        previewRef: ChatImagePreviewRef,
        signal?: AbortSignal
      ) => Promise<LocalFilePreview | undefined>)
    | undefined;
  onRemoveAttachment?: (id: string) => void;
  onRemoveQuote?: (id: string) => void;
  onRetryAttachment?: (id: string) => void;
  onSend: (draft: string, options: { skills: { location: string }[] }) => void;
  placeholder?: string;
  sendLabel?: string;
  showVoiceButton?: boolean;
  size?: AiInputSize;
  skills?: CommaSkill[];
  /** Only the group Router chat currently accepts Salix control commands. */
  controlCommandsEnabled?: boolean;
  submitDisabled: boolean;
  submitPending?: boolean;
  toolbarLeading?: ReactNode;
  variant?: "default" | "side-chat";
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const draft = useComposerDraft(draftSource);
  const driveRetryLabel = messages.common_retry();
  const audioCapture = useAudioCapture({ enabled: showVoiceButton });
  const { showSaved: showRecordingSaved } = useRecordingFileActions();
  const voiceCaptureToastId = `chat-voice-capture-${useId()}`;
  const voiceCaptureActive = showVoiceButton && audioCapture.available;
  // Main holds one tap for the whole app. `audioCapture.recording` reports it
  // whoever started it, so track which recordings are this composer's own.
  const [voiceOwned, setVoiceOwned] = useState(false);
  // While the meeting recorder owns the tap, hide the button rather than
  // offer a start Main would refuse.
  const voiceButtonVisible = showVoiceButton && (voiceOwned || !audioCapture.recording);
  const voiceCaptureError = audioCapture.error;
  const voiceCaptureSuspectedDenied =
    voiceOwned &&
    audioCapture.recording &&
    audioCapture.permission === "suspected_denied";
  const openAudioCapturePermissionSettings = audioCapture.openPermissionSettings;

  useEffect(() => {
    if (!voiceCaptureError) return;
    toast.error(messages.chat_voice_capture_failed({ reason: voiceCaptureError }), {
      id: voiceCaptureToastId,
      testId: "chat-voice-capture-error",
    });
  }, [messages, voiceCaptureError, voiceCaptureToastId]);

  useEffect(() => {
    if (!voiceCaptureSuspectedDenied) return;
    toast.error(messages.chat_voice_capture_permission_title(), {
      actions: [
        {
          label: messages.chat_voice_capture_open_settings(),
          onPress: () => {
            void openAudioCapturePermissionSettings();
          },
        },
      ],
      description: messages.chat_voice_capture_permission_detail(),
      id: voiceCaptureToastId,
      testId: "chat-voice-capture-permission",
    });
  }, [
    messages,
    openAudioCapturePermissionSettings,
    voiceCaptureSuspectedDenied,
    voiceCaptureToastId,
  ]);

  const startVoiceCapture = audioCapture.start;
  const stopVoiceCapture = audioCapture.stop;
  const cancelVoiceCapture = audioCapture.cancel;
  const handleVoicePress = useCallback(async () => {
    // Main can publish the live snapshot before the command resolves. Keep
    // this pending start's control visible through that render, or AiInput
    // would interpret a hidden voice button as cancellation.
    setVoiceOwned(true);
    const next = await startVoiceCapture(undefined, { microphone: true });
    if (!next || next.status !== "recording") {
      setVoiceOwned(false);
      throw new Error(next?.reason ?? "Audio capture did not start.");
    }
  }, [startVoiceCapture]);
  const handleVoiceCancel = useCallback(() => {
    setVoiceOwned(false);
    void cancelVoiceCapture();
  }, [cancelVoiceCapture]);
  const handleVoiceConfirm = useCallback(() => {
    setVoiceOwned(false);
    void stopVoiceCapture().then((result) => {
      if (result?.status === "ready") {
        showRecordingSaved(
          result.recording,
          voiceCaptureToastId,
          "chat-voice-capture-saved"
        );
      } else {
        toast.error(messages.meeting_recorder_save_failed(), {
          ...(result?.reason ? { description: result.reason } : {}),
          id: voiceCaptureToastId,
          testId: "chat-voice-capture-error",
        });
      }
    });
  }, [messages, showRecordingSaved, stopVoiceCapture, voiceCaptureToastId]);
  useApplicationMenu(
    showVoiceButton
      ? [
          {
            id: "record-start",
            enabled: voiceCaptureActive && !audioCapture.recording,
            run: handleVoicePress,
          },
          {
            id: "record-stop",
            enabled: voiceOwned && audioCapture.recording && !audioCapture.pending,
            run: handleVoiceConfirm,
          },
          {
            id: "record-pause",
            enabled:
              voiceOwned &&
              audioCapture.recording &&
              !audioCapture.paused &&
              !audioCapture.pending,
            run: audioCapture.pause,
          },
          {
            id: "record-resume",
            enabled: voiceOwned && audioCapture.paused && !audioCapture.pending,
            run: audioCapture.resume,
          },
        ]
      : []
  );
  const uploadErrorToastId = `chat-upload-error-${useId()}`;
  const driveAttachErrorToastId = `chat-drive-attach-error-${useId()}`;
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const pendingFilePickerFinishRef = useRef<(() => void) | null>(null);
  const [sideChatLayout, setSideChatLayout] = useState({
    contentHeight: SIDE_CHAT_TEXTAREA_MIN_HEIGHT,
    textareaHeight: SIDE_CHAT_TEXTAREA_MIN_HEIGHT,
  });
  // Key the exclusion set by VALUE: the mentioned-skill set changes on very
  // few keystrokes (only when a /mention is completed or removed), and the
  // menu registrations below must keep their identity for every keystroke in
  // between so AiInput's registration-driven work is not re-created per key.
  const excludedLocationsKey = useMemo(
    () =>
      deriveMentionedSkills(draft, skills)
        .map((skill) => skill.location)
        .toSorted()
        .join("\n"),
    [draft, skills]
  );
  const excludedLocations = useMemo(
    () => new Set(excludedLocationsKey === "" ? [] : excludedLocationsKey.split("\n")),
    [excludedLocationsKey]
  );
  const hasUploadedAttachment = draftAttachments.some(
    (attachment) => attachment.status === "uploaded"
  );
  const anyUploading = draftAttachments.some(
    (attachment) => attachment.status === "uploading"
  );
  const anyFailed = draftAttachments.some(
    (attachment) => attachment.status === "failed"
  );
  // A staged quote is message content in its own right, so it alone can
  // satisfy the "something to send" gate the same way an upload does.
  const hasDraftQuote = draftQuotes.length > 0;
  const effectiveSubmitDisabled =
    submitDisabled ||
    anyUploading ||
    anyFailed ||
    (!draft.trim() && !hasUploadedAttachment && !hasDraftQuote);
  const localImagePreviewRequests = useMemo(
    () =>
      draftAttachments.flatMap((attachment) => {
        const previewRef = imagePreviewRef(attachment);
        return attachment.isImage && attachment.status === "uploaded" && previewRef
          ? [{ key: attachment.id, previewRef }]
          : [];
      }),
    [draftAttachments]
  );
  const localImagePreviews = useLocalFilePreviews(
    localImagePreviewRequests,
    onPreviewLocalFile
  );
  const quoteAttachments = useMemo<AiInputAttachment[]>(
    () =>
      draftQuotes.map((quote) => ({
        detail: quote.text,
        id: quote.id,
        name: chatQuoteLabel(quote.text),
        onRemove: () => onRemoveQuote?.(quote.id),
        type: "quote" as const,
      })),
    [draftQuotes, onRemoveQuote]
  );
  const fileAttachments = useMemo<AiInputAttachment[]>(
    () =>
      draftAttachments.map((attachment) => {
        const meta = attachmentMeta(
          attachment,
          locale,
          messages.chat_uploading(),
          messages.chat_upload_failed()
        );
        const preview = localImagePreviews.get(attachment.id);
        // Keep the loading tile until the thumbnail is ready or unavailable.
        // Upload completion can precede the separate thumbnail request.
        const awaitingThumbnail =
          attachment.isImage &&
          attachment.status === "uploaded" &&
          onPreviewLocalFile !== undefined &&
          imagePreviewRef(attachment) !== undefined &&
          preview?.status !== "ready" &&
          preview?.status !== "unavailable";
        const inputAttachment: AiInputAttachment = {
          id: attachment.id,
          name: attachment.name,
          onRemove: () => onRemoveAttachment?.(attachment.id),
          // Image tiles carry their upload state on the tile itself; the file
          // chip keeps showing it as meta text.
          onRetry: () => onRetryAttachment?.(attachment.id),
          state:
            attachment.status === "failed"
              ? "error"
              : attachment.status === "uploading" || awaitingThumbnail
                ? "loading"
                : "ready",
          type: attachment.isImage ? "image" : "file",
        };
        if (meta) {
          inputAttachment.meta = meta;
        }
        if (preview?.status === "ready") {
          inputAttachment.thumbnailSrc = preview.url;
        }
        return inputAttachment;
      }),
    [
      draftAttachments,
      localImagePreviews,
      locale,
      messages,
      onPreviewLocalFile,
      onRemoveAttachment,
      onRetryAttachment,
    ]
  );
  // Quotes lead the row: they are the reason the message exists, and they are
  // also what the sent message puts first.
  const aiAttachments = useMemo(
    () => [...quoteAttachments, ...fileAttachments],
    [fileAttachments, quoteAttachments]
  );
  const failedAttachments = draftAttachments.filter(
    (attachment) => attachment.status === "failed"
  );
  // Upload failures surface as ONE aggregated error toast, however many
  // attachments failed - sonner updates the same id in place, so repeated
  // failures never stack or replay the enter animation. The toast dismisses
  // itself once every failure is retried away or removed.
  const failedAttachmentsKey = failedAttachments
    .map((attachment) => `${attachment.id}\u0000${attachment.error ?? ""}`)
    .join("\n");
  useEffect(() => {
    if (failedAttachments.length === 0) {
      toast.dismiss(uploadErrorToastId);
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

    toast.error(title, {
      ...(description ? { description } : {}),
      actions: [
        {
          label: messages.chat_retry_upload(),
          onPress: () => {
            for (const id of failedIds) onRetryAttachment?.(id);
          },
        },
        {
          hierarchy: "tertiary-gray",
          label: messages.chat_remove_attachment(),
          onPress: () => {
            for (const id of failedIds) onRemoveAttachment?.(id);
          },
        },
      ],
      id: uploadErrorToastId,
      testId: "chat-upload-error",
    });
    // failedAttachmentsKey covers the identity-unstable failedAttachments array.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    failedAttachmentsKey,
    messages,
    onRemoveAttachment,
    onRetryAttachment,
    uploadErrorToastId,
  ]);
  useEffect(
    () => () => {
      toast.dismiss(uploadErrorToastId);
    },
    [uploadErrorToastId]
  );

  const sideChatExpanded =
    variant === "side-chat" &&
    (sideChatLayout.textareaHeight > SIDE_CHAT_TEXTAREA_MIN_HEIGHT ||
      aiAttachments.length > 0);
  const reportSideChatLayout = useCallback(
    (layout: { contentHeight: number; textareaHeight: number }) => {
      setSideChatLayout(layout);
      onContentHeightChange?.(layout.contentHeight);
    },
    [onContentHeightChange]
  );
  const submit = (value: string) => {
    if (
      (!value.trim() && !hasUploadedAttachment && !hasDraftQuote) ||
      effectiveSubmitDisabled
    ) {
      return;
    }
    onSend(value, {
      skills: deriveMentionedSkills(value, skills),
    });
  };

  // Cmd/Ctrl+Enter is an alternate submit gesture. It uses the same direct
  // Conversation send path as the button and plain Enter.
  const handleComposerKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (event.defaultPrevented || disabled || isImeKeyEvent(event.nativeEvent)) return;
    if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey)) return;
    if (event.altKey || event.shiftKey) return;
    event.preventDefault();
    submit(draft);
  };

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

  // A Drive file chosen through "@" is attached the way a picked file is:
  // its bytes are read, then take the same intake as a drop or a paste. A
  // file the node cannot hand over says so instead of attaching nothing.
  const attachDriveFile = useCallback(
    async (entry: ComposerDriveMentionItem) => {
      try {
        const blob = await entry.read();
        onAttachFiles?.([{ data: blob, name: entry.file.name, size: blob.size }]);
      } catch (error) {
        toast.error(messages.chat_menu_drive_attach_failed({ name: entry.file.name }), {
          ...(error instanceof Error && error.message
            ? { description: error.message }
            : {}),
          id: driveAttachErrorToastId,
          testId: "chat-drive-attach-error",
        });
      }
    },
    [driveAttachErrorToastId, messages, onAttachFiles]
  );

  const skillMenuLabel = controlCommandsEnabled
    ? messages.chat_command_menu()
    : messages.chat_skill_menu();
  const skillMenuGroupLabel = messages.chat_skill_menu_group();
  const mentionMenuLabel = messages.chat_mention_menu();
  const addGroupLabel = messages.chat_menu_add_group();
  const addFilesLabel = messages.chat_menu_add_files_or_folders();
  const tasksGroupLabel = messages.chat_menu_tasks_group();
  const routinesGroupLabel = messages.chat_menu_routines_group();
  const pluginsGroupLabel = messages.chat_plugin_menu_group();
  const driveGroupLabel = messages.nav_drive();
  const driveViewMoreLabel = messages.chat_menu_drive_view_more();
  const driveSearchLabel = messages.chat_menu_drive_search();
  const driveEmptyLabel = messages.chat_menu_drive_empty();
  const driveNoResultsLabel = messages.chat_menu_drive_no_results();
  const canAttach = Boolean(onAttachFiles || onPickAttachments);
  const menuRegistrations = useMemo<AiInputMenuRegistration[]>(() => {
    const registrations: AiInputMenuRegistration[] = [];

    // Always registered: "/" with no configured skills answers with the
    // panel's "No results" state instead of silently ignoring the keystroke.
    registrations.push({
      id: "skills",
      trigger: "/",
      label: skillMenuLabel,
      maxItems: Number.POSITIVE_INFINITY,
      groups: [
        ...(controlCommandsEnabled
          ? [
              {
                id: "salix-commands",
                label: messages.chat_control_commands_group(),
                items: (
                  [
                    ["status", messages.chat_command_status(), "status"],
                    ["compact", messages.chat_command_compact(), "compact"],
                    [
                      "emergency-compact",
                      messages.chat_command_emergency_compact(),
                      "emergency-compact",
                    ],
                    ["help", messages.chat_command_help(), "help"],
                    ["ls", messages.chat_command_ls(), "ls /"],
                    ["cat", messages.chat_command_cat(), "cat /path/to/file"],
                  ] as const
                ).map(([command, description, body]) => ({
                  id: `salix-${command}`,
                  label: `/${command}`,
                  description,
                  descriptionPlacement: "inline" as const,
                  searchText: `salix-command ${command}`,
                  insertText: `<salix-command>${body}</salix-command>`,
                })),
              },
            ]
          : []),
        {
          id: "workspace-skills",
          label: skillMenuGroupLabel,
          items: skills
            .filter((skill) => !excludedLocations.has(skill.location))
            .map((skill) => ({
              id: skill.skill_id,
              label: skill.name,
              description: skill.description || skill.location,
              searchText: skill.skill_id,
              icon: <CubeIcon className="size-4!" />,
              descriptionPlacement: "inline",
              plainText: `/${skill.skill_id}`,
              data: { location: skill.location },
            })),
        },
      ],
    });

    const mentionGroups: AiInputMenuGroup[] = [];
    // Menu order is this push order: Add, Tasks, Routines, Plugins, Drive.
    if (canAttach) {
      mentionGroups.push({
        id: "add",
        label: addGroupLabel,
        items: [
          {
            id: "add-files-or-folders",
            label: addFilesLabel,
            icon: <PaperclipIcon />,
            keywords: addFilesKeywords,
            action: () => {
              void handleAttachPress();
            },
          },
        ],
      });
    }
    if (mentionSources) {
      mentionGroups.push(
        {
          id: "tasks",
          label: tasksGroupLabel,
          status: mentionSources.tasks.status,
          items: mentionSources.tasks.items.map((task) => ({
            id: `task:${task.conversationId}`,
            label: task.title,
            icon: taskStatusIcon(task.statusBucket),
            tokenLabel: task.title,
            plainText: taskMentionPlainText(task.title, task.conversationId),
            data: { kind: "task", conversationId: task.conversationId },
          })),
        },
        {
          id: "routines",
          label: routinesGroupLabel,
          status: mentionSources.routines.status,
          items: mentionSources.routines.items.map((routine) => ({
            id: `routine:${routine.id}`,
            label: routine.label,
            icon: <RoutineMentionIcon routine={routine} />,
            tokenLabel: routine.label,
            plainText:
              routine.kind === "link"
                ? linkMentionPlainText(routine.label, routine.href)
                : taskMentionPlainText(routine.label, routine.conversationId),
            data:
              routine.kind === "link"
                ? { kind: "routine-link", href: routine.href }
                : { kind: "task", conversationId: routine.conversationId },
          })),
        },
        {
          id: "plugins",
          label: pluginsGroupLabel,
          status: mentionSources.plugins.status,
          items: mentionSources.plugins.items.map((plugin) => ({
            id: `plugin:${plugin.id}`,
            label: plugin.name,
            icon: <PluginMentionIcon brand={plugin.brand} name={plugin.name} />,
            tokenLabel: plugin.name,
            plainText: `@${plugin.id}`,
            data: { kind: "plugin", pluginId: plugin.id },
            ...(plugin.summary ? { keywords: [plugin.summary] } : {}),
          })),
        }
      );
    }
    // Drive rows attach, so the section exists only where an attachment can
    // land. The menu shows the newest files; the whole tree, one section per
    // folder with its newest file first, sits behind "View more".
    if (mentionSources && onAttachFiles) {
      const driveRow = (
        entry: ComposerDriveMentionItem,
        description: string
      ): AiInputMenuItem => ({
        id: `drive:${entry.file.id}`,
        label: entry.file.name,
        description,
        icon: <DriveFileIcon file={entry.file} size="sm" />,
        keywords: [entry.location],
        action: () => {
          void attachDriveFile(entry);
        },
      });
      const now = Date.now();
      mentionGroups.push({
        id: "drive",
        label: driveGroupLabel,
        status: mentionSources.drive.status,
        prefiltered: !!mentionSources.drive.onMenuQueryChange,
        limit: DRIVE_MENU_LIMIT,
        items: [
          ...(mentionSources.drive.error
            ? [
                {
                  id: "drive:retry",
                  label: driveRetryLabel,
                  keepMenuOpen: true,
                  description: mentionSources.drive.error,
                  action: () => mentionSources.drive.retry?.(),
                },
              ]
            : []),
          ...mentionSources.drive.items.map((entry) => driveRow(entry, entry.location)),
        ],
        browse: {
          label: driveViewMoreLabel,
          title: driveGroupLabel,
          searchPlaceholder: driveSearchLabel,
          emptyLabel: driveEmptyLabel,
          noResultsLabel: driveNoResultsLabel,
          onQueryChange: mentionSources.drive.browse?.onQueryChange,
          onLoadMore: mentionSources.drive.browse?.cursor
            ? mentionSources.drive.browse.loadMore
            : undefined,
          loadingMore: mentionSources.drive.browse?.loadingMore,
          status: mentionSources.drive.browse?.status,
          error: mentionSources.drive.browse?.error,
          onRetry: mentionSources.drive.browse?.retry,
          retryLabel: driveRetryLabel,
          prefiltered: !!mentionSources.drive.browse,
          groups: driveMentionSections(
            mentionSources.drive.browse?.items ?? mentionSources.drive.items
          ).map((section) => ({
            id: `drive/${section.id}`,
            label: section.label,
            items: section.items.map((entry) =>
              driveRow(entry, formatRelativeDate(entry.file.modifiedAt, locale, now))
            ),
          })),
        },
      });
    }
    if (mentionGroups.length > 0) {
      registrations.push({
        id: MENTION_MENU_ID,
        trigger: "@",
        onQueryChange: mentionSources?.drive.onMenuQueryChange,
        label: mentionMenuLabel,
        maxItems: Number.POSITIVE_INFINITY,
        groups: mentionGroups,
      });
    }

    return registrations;
  }, [
    addFilesLabel,
    addGroupLabel,
    attachDriveFile,
    canAttach,
    driveRetryLabel,
    driveEmptyLabel,
    driveGroupLabel,
    driveNoResultsLabel,
    driveSearchLabel,
    driveViewMoreLabel,
    excludedLocations,
    handleAttachPress,
    locale,
    mentionMenuLabel,
    mentionSources,
    onAttachFiles,
    pluginsGroupLabel,
    routinesGroupLabel,
    controlCommandsEnabled,
    messages,
    skillMenuGroupLabel,
    skillMenuLabel,
    skills,
    tasksGroupLabel,
  ]);

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
    (transfer: DataTransfer) => {
      const files = Array.from(transfer.files);
      if (files.length === 0) {
        return;
      }
      onAttachFiles?.(attachmentsFromFiles(files));
    },
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

  return (
    <div
      className="comma-chat-composer-shell"
      data-side-chat-multiline={sideChatExpanded ? "true" : undefined}
    >
      {onAttachFiles ? (
        <input
          ref={fileInputRef}
          accept={ATTACHMENT_ACCEPT}
          className="app-sr-only"
          multiple
          onChange={handleFilesSelected}
          tabIndex={-1}
          type="file"
        />
      ) : null}
      <AiInput
        attachLabel={messages.chat_add_attachment()}
        attachments={aiAttachments}
        className="comma-chat-composer"
        clipboard={nativePlatformClipboard}
        disabled={disabled}
        menuRegistrations={menuRegistrations}
        onKeyDown={handleComposerKeyDown}
        onSubmit={submit}
        onValueChange={onDraftChange}
        richValueFromText={projectMentionTokens}
        {...(onAttachFiles || onPickAttachments
          ? { onAttachPress: handleAttachPress }
          : {})}
        {...(onAttachFiles
          ? {
              onDropFiles: handleTransferredFiles,
              onPasteFiles: handleTransferredFiles,
            }
          : {})}
        placeholder={placeholder ?? messages.chat_composer_placeholder()}
        richText
        sendLabel={sendLabel ?? messages.chat_send_message()}
        showAttachButton={Boolean(onAttachFiles || onPickAttachments)}
        showVoiceButton={voiceButtonVisible}
        {...(voiceCaptureActive
          ? {
              onVoiceCancel: handleVoiceCancel,
              onVoiceConfirm: handleVoiceConfirm,
              onVoicePress: handleVoicePress,
              voiceLevel: audioCapture.level,
            }
          : showVoiceButton && needsDesktopApp()
            ? { onVoicePress: requestDesktopVoice }
            : {})}
        {...(size ? { size } : {})}
        submitDisabled={effectiveSubmitDisabled}
        submitPending={submitPending}
        toolbarLeading={toolbarLeading}
        {...(variant === "side-chat"
          ? {
              onLayoutHeightChange: reportSideChatLayout,
              size: "small" as const,
              textareaMeasurementWidthMode: "narrowest" as const,
            }
          : {})}
        value={draft}
      />
    </div>
  );
});

function attachmentMeta(
  attachment: DraftAttachment,
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

// Voice input records through the desktop app's audio tap; a browser has none.
function requestDesktopVoice() {
  requestDesktopApp("voice");
  return false as const;
}
