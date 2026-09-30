import type { ReactNode, RefObject } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { cx } from "../../utils";
import { AiInputAttachmentRow } from "../attachments/AiInputAttachmentRow";
import { AiInputImagePreview } from "../attachments/AiInputImagePreview";
import type { AttachmentPreview } from "../attachments/useAttachmentPreview";
import { AiInputDropOverlay } from "../files/AiInputDropOverlay";
import type { FileDrop } from "../files/useFileDrop";
import type { useAiInputAutoSize } from "../sizing/useAiInputAutoSize";
import {
  AI_INPUT_DROP_OVERLAY_MIN_HEIGHT_PX,
  AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX,
  AI_INPUT_SMALL_TOOLBAR_HEIGHT_PX,
  aiInputComposer,
  aiInputContent,
  aiInputShell,
  aiInputSmallCompactContent,
  aiInputSmallCompactContentDefaultLeading,
  aiInputSmallCompactContentWithAccess,
  aiInputSmallCompactShell,
  aiInputSmallExpandedShell,
  aiInputSmallLayout,
  aiInputSmallShellMotion,
} from "../styles";
import type { AiInputAttachment, ForwardedAiInputProps } from "../types";

export interface AiInputShellProps extends ForwardedAiInputProps<
  "className" | "dropPlaceholder" | "onAttachmentRemove"
> {
  attachments: AiInputAttachment[];
  attachmentsRef: RefObject<HTMLDivElement | null>;
  disabled: boolean;
  drop: FileDrop;
  isSmall: boolean;
  isVoiceRecording: boolean;
  preview: AttachmentPreview;
  prompt: ReactNode;
  shellRef: RefObject<HTMLDivElement | null>;
  showAccessButton: boolean;
  sizing: ReturnType<typeof useAiInputAutoSize>;
  toolbar: ReactNode;
}

/**
 * The composer's frame: the shell (the drop target, compact or expanded) with
 * the staged attachments on top, the resize surface the prompt and toolbar
 * share below them, and the overlays above it all.
 */
export const AiInputShell = ({
  attachments,
  attachmentsRef,
  className,
  disabled,
  drop: { dropActive, dropEnabled, shellDropProps },
  dropPlaceholder,
  isSmall,
  isVoiceRecording,
  onAttachmentRemove,
  preview,
  prompt,
  shellRef,
  showAccessButton,
  sizing: { promptHeight, usesCompactLayout },
  toolbar,
}: AiInputShellProps) => {
  const messages = useCommaMessages();
  const hasAttachments = attachments.length > 0;
  const smallComposerHeight = usesCompactLayout
    ? AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX
    : `calc(${promptHeight + AI_INPUT_SMALL_TOOLBAR_HEIGHT_PX}px + var(--spacing-xs))`;

  return (
    <div
      className={cx(
        aiInputShell,
        "relative",
        !isSmall && "px-lg pt-lg pb-md",
        isSmall && aiInputSmallShellMotion,
        usesCompactLayout && !hasAttachments && aiInputSmallCompactShell,
        isSmall && (!usesCompactLayout || hasAttachments) && aiInputSmallExpandedShell,
        hasAttachments && "gap-md pt-xs",
        disabled && "opacity-60",
        className
      )}
      data-drop-active={dropActive ? "true" : undefined}
      data-compact={isSmall ? String(usesCompactLayout) : undefined}
      data-testid="ai-input-shell"
      ref={shellRef}
      style={
        dropActive ? { minHeight: AI_INPUT_DROP_OVERLAY_MIN_HEIGHT_PX } : undefined
      }
      {...shellDropProps}
    >
      <AiInputAttachmentRow
        attachments={attachments}
        onRemove={onAttachmentRemove}
        preview={preview}
        rowRef={attachmentsRef}
      />
      <div
        className={cx(
          isSmall && "t-resize",
          isSmall ? aiInputSmallLayout : aiInputComposer
        )}
        style={isSmall ? { height: smallComposerHeight } : undefined}
      >
        <div
          className={cx(
            aiInputContent,
            usesCompactLayout && aiInputSmallCompactContent,
            usesCompactLayout &&
              (showAccessButton
                ? aiInputSmallCompactContentWithAccess
                : aiInputSmallCompactContentDefaultLeading),
            isSmall && !usesCompactLayout && "min-h-0 overflow-hidden px-xs",
            "transition-[opacity] duration-[var(--motion-duration-state-change)] ease-[var(--motion-easing-smooth-out)]",
            isVoiceRecording && "pointer-events-none opacity-0"
          )}
          data-slot="ai-input-content"
          inert={isVoiceRecording || undefined}
          {...(isVoiceRecording ? { "aria-hidden": true } : {})}
        >
          {prompt}
        </div>
        {toolbar}
      </div>
      {dropEnabled ? (
        <AiInputDropOverlay
          active={dropActive}
          subtitle={messages.ui_ai_drop_types_hint()}
          title={dropPlaceholder ?? messages.ui_ai_drop_anything_here()}
        />
      ) : null}
      <AiInputImagePreview {...preview.dialogProps} />
    </div>
  );
};
