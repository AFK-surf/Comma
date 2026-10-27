import { type ReactNode, useEffect, useId, useRef, useState } from "react";
import { Focusable } from "react-aria-components";
import { useCommaMessages } from "@comma/i18n/react";
import { uiClock, type CancelUiTimer } from "../../clock";
import { motionDuration } from "../../tokens";
import { Tooltip } from "../tooltip";
import { cx } from "../utils";
import {
  type ChatPanelMediaDownloadAction,
  type ChatPanelMediaDownloadKind,
  type ChatPanelMediaDownloadResult,
  formatMediaFileSize,
} from "./ChatPanelMediaDownload";
import { useHoverOnlyTooltip } from "./useHoverOnlyTooltip";
import { usePointerPressFeedback } from "./usePointerPressFeedback";

export type ChatPanelMediaDownloadState =
  | { status: "idle" }
  | { status: "pending" }
  | { status: "started" }
  | { status: "success" }
  | Extract<ChatPanelMediaDownloadResult, { status: "error" }>;

export interface ChatPanelMediaDownloadController {
  canExecute: boolean;
  execute: () => Promise<void>;
  fileSizeLabel?: string;
  state: ChatPanelMediaDownloadState;
}

interface ChatPanelMediaDownloadControlProps {
  buttonClassName: string;
  controller: ChatPanelMediaDownloadController;
  feedbackPlacement: "above" | "below";
  icon: ReactNode;
  kind: ChatPanelMediaDownloadKind;
}

interface UseChatPanelMediaDownloadControllerOptions {
  action: ChatPanelMediaDownloadAction | undefined;
  kind: ChatPanelMediaDownloadKind;
  /** Absent for downloadables the renderer cannot address by URL. */
  source?: string | undefined;
}

const successFeedbackDuration =
  motionDuration.feedbackOut * 8 + motionDuration.stateChange;

const unexpectedDownloadFailure: ChatPanelMediaDownloadResult = {
  code: "unknown",
  retryable: true,
  status: "error",
};

const mediaNoun: Record<ChatPanelMediaDownloadKind, string> = {
  audio: "Audio",
  file: "File",
  image: "Image",
  video: "Video",
};

const canExecuteDownload = (state: ChatPanelMediaDownloadState) =>
  state.status === "idle" ||
  state.status === "started" ||
  state.status === "success" ||
  (state.status === "error" && state.retryable);

const getDownloadCopy = (
  kind: ChatPanelMediaDownloadKind,
  state: ChatPanelMediaDownloadState,
  messages: ReturnType<typeof useCommaMessages>
) => {
  switch (state.status) {
    case "started":
      return {
        feedback: messages.ui_file_download_started_feedback(),
        label: messages.file_download_started_title(),
      };
    case "pending":
      return {
        feedback: `Downloading ${kind}…`,
        label: `Downloading ${kind}`,
      };
    case "success":
      return {
        feedback: `${mediaNoun[kind]} downloaded.`,
        label: `Downloaded ${kind}`,
      };
    case "error":
      return state.retryable
        ? {
            feedback: `Could not download ${kind}. Try again.`,
            label: `Download ${kind} failed. Try again`,
          }
        : {
            feedback: `Could not download ${kind}.`,
            label: `Download ${kind} failed`,
          };
    case "idle":
      return {
        feedback: "",
        label: `Download ${kind}`,
      };
  }
};

export const useChatPanelMediaDownloadController = ({
  action,
  kind,
  source,
}: UseChatPanelMediaDownloadControllerOptions): ChatPanelMediaDownloadController => {
  const [state, setState] = useState<ChatPanelMediaDownloadState>({
    status: "idle",
  });
  const stateRef = useRef(state);
  stateRef.current = state;
  const requestGenerationRef = useRef(0);
  const requestContextRef = useRef({
    execute: action?.capability.execute,
    fileName: action?.fileName,
    kind,
    source,
  });
  requestContextRef.current = {
    execute: action?.capability.execute,
    fileName: action?.fileName,
    kind,
    source,
  };
  const successTimerRef = useRef<CancelUiTimer | null>(null);

  useEffect(() => {
    requestGenerationRef.current += 1;
    const idleState: ChatPanelMediaDownloadState = { status: "idle" };
    stateRef.current = idleState;
    setState(idleState);
    if (successTimerRef.current) {
      successTimerRef.current();
      successTimerRef.current = null;
    }

    return () => {
      requestGenerationRef.current += 1;
      if (successTimerRef.current) successTimerRef.current();
    };
  }, [action?.capability.execute, action?.fileName, kind, source]);

  const execute = async () => {
    const request = requestContextRef.current;
    if (
      !request.execute ||
      request.fileName === undefined ||
      !canExecuteDownload(stateRef.current)
    ) {
      return;
    }

    const requestGeneration = requestGenerationRef.current + 1;
    requestGenerationRef.current = requestGeneration;
    if (successTimerRef.current) {
      successTimerRef.current();
      successTimerRef.current = null;
    }
    const pendingState: ChatPanelMediaDownloadState = { status: "pending" };
    stateRef.current = pendingState;
    setState(pendingState);

    let result: ChatPanelMediaDownloadResult;
    try {
      result = await request.execute({
        fileName: request.fileName,
        kind: request.kind,
        ...(request.source === undefined ? {} : { source: request.source }),
      });
    } catch {
      result = unexpectedDownloadFailure;
    }

    const latestRequest = requestContextRef.current;
    if (
      requestGenerationRef.current !== requestGeneration ||
      latestRequest.execute !== request.execute ||
      latestRequest.fileName !== request.fileName ||
      latestRequest.kind !== request.kind ||
      latestRequest.source !== request.source
    ) {
      return;
    }
    if (result.status === "error") {
      stateRef.current = result;
      setState(result);
      return;
    }

    stateRef.current = result;
    setState(result);
    successTimerRef.current = uiClock.after(successFeedbackDuration, () => {
      if (requestGenerationRef.current === requestGeneration) {
        const idleState: ChatPanelMediaDownloadState = { status: "idle" };
        stateRef.current = idleState;
        setState(idleState);
      }
      successTimerRef.current = null;
    });
  };

  return {
    canExecute: Boolean(action) && canExecuteDownload(state),
    execute,
    ...(action?.fileSize === undefined
      ? {}
      : { fileSizeLabel: formatMediaFileSize(action.fileSize) }),
    state,
  };
};

export const ChatPanelMediaDownloadControl = ({
  buttonClassName,
  controller,
  feedbackPlacement,
  icon,
  kind,
}: ChatPanelMediaDownloadControlProps) => {
  const messages = useCommaMessages();
  const feedbackId = useId();
  const buttonPressFeedback = usePointerPressFeedback<HTMLButtonElement>();
  const copy = getDownloadCopy(kind, controller.state, messages);
  const hasFeedback = copy.feedback.length > 0;
  const isPending = controller.state.status === "pending";
  const isIdle = controller.state.status === "idle";
  const tooltip = useHoverOnlyTooltip();

  return (
    <span
      className="chat-panel-media-download-anchor"
      data-error-code={
        controller.state.status === "error" ? controller.state.code : undefined
      }
      data-feedback-placement={feedbackPlacement}
      data-state={controller.state.status}
    >
      <Tooltip
        content={isIdle ? "Download" : copy.label}
        isOpen={tooltip.isOpen}
        onOpenChange={tooltip.onOpenChange}
        placement="top"
        {...(isIdle && controller.fileSizeLabel
          ? { suffix: controller.fileSizeLabel }
          : {})}
      >
        <Focusable>
          <button
            aria-busy={isPending}
            aria-describedby={hasFeedback ? feedbackId : undefined}
            aria-disabled={isPending || undefined}
            aria-label={copy.label}
            className={buttonClassName}
            data-download-state={controller.state.status}
            disabled={!controller.canExecute && !isPending}
            {...(controller.canExecute
              ? buttonPressFeedback
              : { "data-no-press-feedback": true })}
            onClick={() => void controller.execute()}
            type="button"
          >
            {icon}
          </button>
        </Focusable>
      </Tooltip>
      <output
        aria-atomic="true"
        aria-live="polite"
        className={cx(
          "chat-panel-media-download-feedback",
          controller.state.status === "error" && "is-error",
          controller.state.status === "success" && "is-success"
        )}
        data-visible={hasFeedback ? "true" : "false"}
        id={feedbackId}
      >
        {copy.feedback}
      </output>
    </span>
  );
};
