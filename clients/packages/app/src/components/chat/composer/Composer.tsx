import { uiClock } from "@comma/ui/clock";
import { useApplicationMenu } from "../../application-menu/useApplicationMenu";
import {
  AiInput,
  AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX,
  type AiInputAttachment,
  type AiInputMenuGroup,
  type AiInputMenuItem,
  type AiInputMenuRegistration,
  type AiInputSize,
} from "@comma/ui/components/ai-input";
import {
  CubeIcon,
  FileTextIcon,
  GlobeIcon,
  PaperclipIcon,
} from "@comma/ui/components/icons";
import { isImeKeyEvent } from "@comma/ui/components/utils";
import { resolveProviderBrandLogo } from "@comma/ui/components/provider-brand-logos";
import { taskNeutralIcon, taskStatusIcon } from "@comma/ui/components/task-workspace";
import { toast } from "@comma/ui/components/toast";
import { formatRelativeDate } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  memo,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { nativePlatformClipboard } from "../../../nativePlatformActions";
import type { CommaSkill } from "@comma/core/api-schemas";
import type { RecommendationSource } from "@comma/recommendation-contract";
import { animateSuggestionAcceptance } from "../suggestions/suggestionAcceptanceMotion";
import { chatQuoteLabel, type ChatDraftQuote } from "./draftQuotes";
import {
  chatSnippetTitle,
  PASTED_SNIPPET_MIN_LENGTH,
  type ChatDraftSnippet,
} from "./draftSnippets";
import {
  useComposerDraft,
  type ComposerDraftFill,
  type ComposerDraftSource,
} from "./conversationDraft";
import { deriveMentionedSkills } from "./mentions";
import {
  linkMentionPlainText,
  modelMentionPlainText,
  taskMentionPlainText,
} from "@comma/core/chat";
import { ModelVendorIcon } from "@comma/ui/components/model-icons/ModelVendorIcon";
import { MENTION_MENU_ID, projectMentionTokens } from "./mentionProjection";
import { attachmentMeta, useFileIntake, useUploadFailureToast } from "./fileIntake";
import { draftUploadPreviewRef, isGroupImagePreviewPath } from "@comma/core/chat";
import type {
  AttachmentUploadInput,
  ChatImagePreviewRef,
  DraftAttachment,
  LocalFilePreview,
} from "@comma/core/chat";
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
import { MAC_APPS_PLUGIN_ID, MacAppsPluginIcon } from "../../plugins/MacApps";
import {
  isLocalFilePreviewRef,
  useLocalFilePreviews,
} from "../thread/attachments/useLocalFilePreviews";

// The compact composer uses the small layout; collapsed height comes from it.
const COMPACT_TEXTAREA_MIN_HEIGHT = AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX;

/** Files the "@" panel's Drive section lists before its "View more" row. */
const DRIVE_MENU_LIMIT = 5;

const EMPTY_SNIPPETS: readonly ChatDraftSnippet[] = [];

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
 * A Routine source's brand mark (Linear, Notion, ...): its bundled logo, else
 * its icon URL. Unbranded sources show `fallback`.
 */
function RoutineSourceIcon({
  fallback,
  source,
}: {
  fallback: ReactNode;
  source: RecommendationSource | undefined;
}) {
  const [failedIconUrl, setFailedIconUrl] = useState<string>();
  const BrandLogo = resolveProviderBrandLogo(source?.appId);
  if (BrandLogo) {
    return <BrandLogo />;
  }
  const iconUrl = source?.iconUrl;
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
  return <>{fallback}</>;
}

/** Unbranded routine mentions show what the mention is: a link or a Task. */
function RoutineMentionIcon({ routine }: { routine: ComposerRoutineMentionItem }) {
  return (
    <RoutineSourceIcon
      fallback={routine.kind === "task" ? taskNeutralIcon() : <GlobeIcon />}
      source={routine.source}
    />
  );
}

function PluginMentionIcon({
  brand,
  id,
  name,
}: {
  brand: string | null | undefined;
  id: string;
  name: string;
}) {
  if (id === MAC_APPS_PLUGIN_ID) {
    return <MacAppsPluginIcon />;
  }
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
 * in a loading state waiting for something that is not coming. One still
 * uploading shows from the bytes the core holds; the preview is kept by the
 * attachment's id, so it stays as the ref moves to the uploaded file. A
 * message's attachment stored by reference has no bytes here: it shows from
 * the stored file.
 */
const imagePreviewRef = (attachment: DraftAttachment) =>
  isLocalFilePreviewRef(attachment.id)
    ? attachment.id
    : attachment.status === "uploading"
      ? attachment.byReference
        ? undefined
        : draftUploadPreviewRef(attachment.id)
      : attachment.path && isGroupImagePreviewPath(attachment.path)
        ? attachment.path
        : undefined;

// Memoized so stream-chunk emits (which change channel state but not the
// draft or any composer input) skip the composer subtree entirely.
export const Composer = memo(function Composer({
  disabled = false,
  draftSource,
  draftAttachments = [],
  draftQuotes = [],
  draftSnippets = EMPTY_SNIPPETS,
  fill,
  mentionSources,
  onAcceptSuggestion,
  onAttachFiles,
  onDraftChange,
  onPickAttachments,
  onPreviewLocalFile,
  onRemoveAttachment,
  onExpandSnippet,
  onPasteSnippet,
  onRemoveQuote,
  onRemoveSnippet,
  onRetryAttachment,
  onSend,
  placeholder,
  sendLabel,
  suggestion,
  showVoiceButton = false,
  size,
  skills = [],
  controlCommandsEnabled = false,
  submitDisabled,
  submitPending = false,
  surfaceDropActive,
  toolbarLeading,
  variant = "default",
}: {
  disabled?: boolean | undefined;
  /** The draft this composer edits. It subscribes alone, so a keystroke
   *  re-renders the composer and not the conversation around it. */
  draftSource: ComposerDraftSource;
  draftAttachments?: DraftAttachment[];
  draftQuotes?: ChatDraftQuote[];
  draftSnippets?: readonly ChatDraftSnippet[] | undefined;
  fill?: ComposerDraftFill | undefined;
  /** Tasks, routines, and plugins for the "@" panel; Add works without it. */
  mentionSources?: ComposerMentionSources | undefined;
  onAcceptSuggestion?: (() => void) | undefined;
  suggestion?: string | undefined;
  onAttachFiles?: (files: AttachmentUploadInput[]) => void;
  onDraftChange: (draft: string) => void;
  onPickAttachments?: () => unknown;
  onPreviewLocalFile?:
    | ((
        previewRef: ChatImagePreviewRef,
        signal?: AbortSignal
      ) => Promise<LocalFilePreview | undefined>)
    | undefined;
  onRemoveAttachment?: (id: string) => void;
  onExpandSnippet?: ((snippet: ChatDraftSnippet) => void) | undefined;
  /** Takes a paste of at least `PASTED_SNIPPET_MIN_LENGTH` characters. */
  onPasteSnippet?: ((text: string) => void) | undefined;
  onRemoveQuote?: (id: string) => void;
  onRemoveSnippet?: ((id: string) => void) | undefined;
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
  /** Set when the surface around the composer takes dropped files for it: files are dragged over that surface. */
  surfaceDropActive?: boolean | undefined;
  toolbarLeading?: ReactNode;
  variant?: "default" | "compact";
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
  const [compactTextareaHeight, setCompactTextareaHeight] = useState(
    COMPACT_TEXTAREA_MIN_HEIGHT
  );
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
  // A file still uploading goes with the message, which waits for it.
  const hasAttachment = draftAttachments.some(
    (attachment) =>
      attachment.status === "uploaded" || attachment.status === "uploading"
  );
  const anyFailed = draftAttachments.some(
    (attachment) => attachment.status === "failed"
  );
  // A staged quote or snippet is message content in its own right, so it
  // alone can satisfy the "something to send" gate the same way an upload does.
  const hasStagedText = draftQuotes.length > 0 || draftSnippets.length > 0;
  const effectiveSubmitDisabled =
    submitDisabled || anyFailed || (!draft.trim() && !hasAttachment && !hasStagedText);
  const localImagePreviewRequests = useMemo(
    () =>
      draftAttachments.flatMap((attachment) => {
        const previewRef = imagePreviewRef(attachment);
        return attachment.isImage && attachment.status !== "failed" && previewRef
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
  const handlePasteText = useCallback(
    (text: string) => {
      if (disabled || !onPasteSnippet || text.length < PASTED_SNIPPET_MIN_LENGTH) {
        return false;
      }
      onPasteSnippet(text);
      return true;
    },
    [disabled, onPasteSnippet]
  );
  const snippetAttachments = useMemo<AiInputAttachment[]>(
    () =>
      draftSnippets.map((snippet) => ({
        icon: <RoutineSourceIcon fallback={<FileTextIcon />} source={snippet.source} />,
        id: snippet.id,
        name: chatSnippetTitle(snippet.text),
        ...(onExpandSnippet ? { onExpand: () => onExpandSnippet(snippet) } : {}),
        onRemove: () => onRemoveSnippet?.(snippet.id),
        type: "snippet" as const,
      })),
    [draftSnippets, onExpandSnippet, onRemoveSnippet]
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
  // also what the sent message puts first. Snippets are text, so they come
  // before the files.
  const aiAttachments = useMemo(
    () => [...quoteAttachments, ...snippetAttachments, ...fileAttachments],
    [fileAttachments, quoteAttachments, snippetAttachments]
  );
  useUploadFailureToast(
    draftAttachments,
    uploadErrorToastId,
    onRetryAttachment,
    onRemoveAttachment
  );

  const compactExpanded =
    variant === "compact" &&
    (compactTextareaHeight > COMPACT_TEXTAREA_MIN_HEIGHT || aiAttachments.length > 0);
  const reportCompactLayout = useCallback(
    (layout: { textareaHeight: number }) =>
      setCompactTextareaHeight(layout.textareaHeight),
    []
  );
  const submit = (value: string) => {
    if (
      (!value.trim() && !hasAttachment && !hasStagedText) ||
      effectiveSubmitDisabled
    ) {
      return;
    }
    onSend(value, {
      skills: deriveMentionedSkills(value, skills),
    });
  };

  const shellRef = useRef<HTMLDivElement | null>(null);
  const playedFillRef = useRef<ComposerDraftFill | undefined>(undefined);
  useLayoutEffect(() => {
    if (!fill || fill === playedFillRef.current || draft !== fill.draft) return;
    playedFillRef.current = fill;
    const editor = shellRef.current?.querySelector<HTMLElement>('[role="textbox"]');
    if (!editor) return;
    // The rich editor has committed the draft before this effect. Continue from
    // the end of the written text, as if it had been typed, and show it.
    editor.focus({ preventScroll: true });
    const range = editor.ownerDocument.createRange();
    range.selectNodeContents(editor);
    range.collapse(false);
    const selection = editor.ownerDocument.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
    editor.scrollTop = editor.scrollHeight;
  }, [draft, fill]);

  const acceptedSuggestionRef = useRef<{
    editor: HTMLElement;
    text: string;
    at: number;
  } | null>(null);
  useLayoutEffect(() => {
    const accepted = acceptedSuggestionRef.current;
    if (!accepted) return;
    acceptedSuggestionRef.current = null;
    const { editor, text, at } = accepted;
    if (draft !== text || editor.ownerDocument.activeElement !== editor) return;
    // The rich editor has committed the controlled draft before this effect.
    const range = editor.ownerDocument.createRange();
    range.selectNodeContents(editor);
    range.collapse(false);
    const selection = editor.ownerDocument.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
    return animateSuggestionAcceptance(editor, at);
  }, [draft]);

  // Cmd/Ctrl+Enter is an alternate submit gesture. It uses the same direct
  // Conversation send path as the button and plain Enter.
  const handleComposerKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (event.defaultPrevented || disabled || isImeKeyEvent(event.nativeEvent)) return;
    if (
      event.key === "Tab" &&
      !event.shiftKey &&
      !event.altKey &&
      !event.metaKey &&
      !event.ctrlKey &&
      draft === "" &&
      suggestion
    ) {
      event.preventDefault();
      acceptedSuggestionRef.current = {
        editor: event.currentTarget,
        text: suggestion,
        // The wave's schedule counts from the key press.
        at: event.timeStamp,
      };
      onDraftChange(suggestion);
      onAcceptSuggestion?.();
      return;
    }
    if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey)) return;
    if (event.altKey || event.shiftKey) return;
    event.preventDefault();
    submit(draft);
  };

  const {
    attachPress: handleAttachPress,
    fileInput,
    transferFiles: handleTransferredFiles,
  } = useFileIntake({ onAttachFiles, onPickAttachments });

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
  const modelsGroupLabel = messages.chat_menu_models_group();
  const effortLabel = messages.settings_providers_picker_effort();
  const defaultEffortLabel = messages.settings_providers_picker_default_effort();
  const noResultsLabel = messages.ui_ai_menu_no_results();
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
          // Miniskills (`per-message`) attach automatically per message, so
          // the menu lists only skills a person picks.
          items: skills
            .filter(
              (skill) =>
                skill.activation !== "per-message" &&
                !excludedLocations.has(skill.location)
            )
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
    // Menu order is this push order: Add, Models, Tasks, Routines, Plugins, Drive.
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
              void handleAttachPress?.();
            },
          },
        ],
      });
    }
    // In the Router chat, a model named starts a Task with it and the rest of the message.
    if (
      mentionSources?.models.items.length ||
      mentionSources?.models.status === "loading"
    ) {
      mentionGroups.push({
        id: "models",
        label: modelsGroupLabel,
        status: mentionSources.models.status,
        items: mentionSources.models.items.map((model) => {
          const icon = <ModelVendorIcon vendor={model.vendor} />;
          // A row of its own for the default effort and for each it takes.
          const choice = (effort: string | null): AiInputMenuItem => {
            const name = effort ? `${model.name} · ${effort}` : model.name;
            return {
              id: `model:${model.id}${effort ? `:${effort}` : ""}`,
              label: effort ?? defaultEffortLabel,
              icon,
              tokenLabel: name,
              plainText: modelMentionPlainText(name, model.id, effort ?? undefined),
              data: { kind: "model", modelId: model.id, effort },
            };
          };
          return {
            ...choice(null),
            label: model.name,
            keywords: [model.id],
            ...(model.efforts.length > 0
              ? {
                  browse: {
                    compact: true,
                    label: model.name,
                    title: `${model.name} · ${effortLabel}`,
                    // The field heads the panel: which model these efforts are for.
                    searchPlaceholder: model.name,
                    emptyLabel: noResultsLabel,
                    noResultsLabel,
                    groups: [
                      {
                        id: `model:${model.id}/efforts`,
                        label: effortLabel,
                        items: [null, ...model.efforts].map(choice),
                      },
                    ],
                  },
                }
              : {}),
          };
        }),
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
            icon: (
              <PluginMentionIcon
                brand={plugin.brand}
                id={plugin.id}
                name={plugin.name}
              />
            ),
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
      const now = uiClock.now();
      mentionGroups.push({
        id: "drive",
        label: driveGroupLabel,
        status: mentionSources.drive.status,
        prefiltered: !!mentionSources.drive.prefiltered,
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
          onLoadMore: mentionSources.drive.browse?.more
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
    modelsGroupLabel,
    effortLabel,
    defaultEffortLabel,
    noResultsLabel,
    routinesGroupLabel,
    controlCommandsEnabled,
    messages,
    skillMenuGroupLabel,
    skillMenuLabel,
    skills,
    tasksGroupLabel,
  ]);

  return (
    <div
      ref={shellRef}
      className="comma-chat-composer-shell"
      data-compact-multiline={compactExpanded ? "true" : undefined}
    >
      {fileInput}
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
        {...(handleAttachPress ? { onAttachPress: handleAttachPress } : {})}
        {...(handleTransferredFiles
          ? {
              ...(surfaceDropActive === undefined
                ? { onDropFiles: handleTransferredFiles }
                : { surfaceDropActive }),
              onPasteFiles: handleTransferredFiles,
            }
          : {})}
        {...(onPasteSnippet ? { onPasteText: handlePasteText } : {})}
        placeholder={
          (draft === "" && !disabled ? suggestion : undefined) ??
          placeholder ??
          messages.chat_composer_placeholder()
        }
        richText
        sendLabel={sendLabel ?? messages.chat_send_message()}
        showAttachButton={handleAttachPress !== undefined}
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
        {...(variant === "compact"
          ? {
              onLayoutHeightChange: reportCompactLayout,
              size: "small" as const,
              textareaMeasurementWidthMode: "narrowest" as const,
            }
          : {})}
        value={draft}
      />
    </div>
  );
});

// Voice input records through the desktop app's audio tap; a browser has none.
function requestDesktopVoice() {
  requestDesktopApp("voice");
  return false as const;
}
