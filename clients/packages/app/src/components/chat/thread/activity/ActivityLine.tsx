import { useCommaMessages } from "@comma/i18n/react";
import { AiActivity, CommaLogoAnimation } from "@comma/ui";
import { useLayoutEffect, useMemo, useState, type CSSProperties } from "react";
import type {
  ChatActivity,
  ChatParticipantStatus,
} from "../../model/conversationChannel";
import { participantStatusLabel } from "./participantStatusLabel";
import { toolActivityLabel } from "./toolActivityLabel";
import { workerMeshGradientStyle } from "./workerAvatar";
import wechatActivityLogo from "../../assets/wechat-activity.svg";
import telegramActivityLogo from "../../assets/telegram-activity.svg";
import signalActivityLogo from "../../assets/signal-activity.svg";
import commaActivityLogo from "../../assets/comma-activity.svg";

type SlotPresentation = {
  key: string;
  label: string;
  name?: string;
  actorId?: string | undefined;
  actorRole?: "router" | "worker" | undefined;
  state: ChatParticipantStatus["state"] | "waiting";
  workingProvider?: ChatParticipantStatus["workingProvider"];
};

export function ParticipantStatusSlot({
  activity,
  participantStatus,
  participantStatuses,
  reserveSpace = false,
  optimisticThinking = false,
  streaming = false,
  replyTimedOut = false,
  hasResponse = false,
  toolPresentation = "inline",
}: {
  activity?: ChatActivity | undefined;
  participantStatus: ChatParticipantStatus | undefined;
  participantStatuses?: ChatParticipantStatus[] | undefined;
  reserveSpace?: boolean | undefined;
  optimisticThinking?: boolean | undefined;
  streaming?: boolean | undefined;
  /** Local acknowledgement without a reply; never a runtime failure claim. */
  replyTimedOut?: boolean | undefined;
  /** A reply ends local waiting, not the Participant's ongoing work. */
  hasResponse?: boolean | undefined;
  /** Side Chat keeps the current tool execution in its own transcript bubble. */
  toolPresentation?: "inline" | "bubble";
}) {
  const messages = useCommaMessages();
  const generationFailed = messages.chat_generation_failed();
  const participant = participantPresentation(participantStatus, messages);
  const taskPresentations = participantStatuses?.flatMap((taskParticipant) => {
    const presentation = participantPresentation(taskParticipant, messages);
    return presentation
      ? [
          {
            ...presentation,
            name:
              taskParticipant.name?.replace(/^Default workspace\s+/i, "").trim() ||
              "Agent",
            actorId: taskParticipant.actorId,
            actorRole: taskParticipant.actorRole,
          },
        ]
      : [];
  });
  // Local send feedback bridges only this client's unsettled send. The channel
  // retires it on source-bound progress, failure or timeout; a replayed stopped
  // Participant snapshot from the preceding turn cannot cancel that feedback.
  // Participant snapshots precede their Activity frames on the same feed.
  // A stopped owner therefore also hides a retained running presentation.
  const liveActivity =
    activity?.status === "running" &&
    participantStatus?.state !== "stopped" &&
    participantStatus?.loopWake !== true;
  // Tool work is worded here, in the reader's language, from the tool's
  // identity; the model's own label for its command comes first. The
  // producer's English summary only serves clients that cannot localize.
  const liveExecutionSummary =
    liveActivity && activity.phase === "execution" && activity.summaryClass === "public"
      ? activity.goal?.trim() ||
        toolActivityLabel(messages, activity.toolName, "running") ||
        messages.chat_activity_working()
      : undefined;
  const liveToolSummary =
    toolPresentation === "bubble" && !participantStatuses
      ? liveExecutionSummary
      : undefined;
  // A source-bound Activity can end with the first send. The Participant
  // remains the authority for work that continues after that reply.
  const ongoingWork =
    hasResponse &&
    !streaming &&
    participantStatus?.state === "active" &&
    participantStatus.loopWake !== true;
  const fallbackSummary = hasResponse
    ? messages.chat_activity_working()
    : messages.chat_activity_thinking();
  const activeSummary = liveToolSummary
    ? liveToolSummary
    : streaming || (!hasResponse && liveActivity && activity.phase === "messaging")
      ? messages.chat_activity_typing()
      : liveExecutionSummary
        ? liveExecutionSummary
        : liveActivity &&
            activity.summaryClass === "public" &&
            activity.phase === "thinking"
          ? activity.summary?.trim() || fallbackSummary
          : fallbackSummary;
  const executionFailed =
    toolActivityLabel(messages, activity?.toolName, "failed") ??
    messages.chat_tool_failed();
  const presentation: SlotPresentation | undefined =
    optimisticThinking && !hasResponse && !liveToolSummary
      ? {
          actorRole: "router",
          key: "optimistic-thinking",
          label: messages.chat_activity_thinking(),
          state: "active",
        }
      : ((participant?.state === "error" ? participant : undefined) ??
        failedTurnPresentation(activity, generationFailed, executionFailed) ??
        (ongoingWork ||
        ((!hasResponse || liveToolSummary) &&
          (streaming ||
            liveActivity ||
            (participant?.state === "active" && participantStatus?.loopWake !== true)))
          ? {
              actorRole: "router",
              key: participant?.key ?? "reply-activity",
              label: activeSummary,
              state: "active",
              workingProvider: participantStatus?.workingProvider,
            }
          : replyTimedOut
            ? {
                key: "reply-wait-expired",
                label: messages.chat_timeout(),
                state: "waiting",
              }
            : undefined));

  const requestedPresentations: SlotPresentation[] = taskPresentations
    ? taskPresentations.toSorted(
        (a, b) =>
          Number(b.actorRole === "router") - Number(a.actorRole === "router") ||
          a.key.localeCompare(b.key)
      )
    : presentation
      ? [presentation]
      : [];
  const handingOffToBubble = hasResponse && streaming;
  const presentations = useThinkingContinuity(
    requestedPresentations,
    handingOffToBubble ||
      participantStatus?.state === "stopped" ||
      participantStatus?.loopWake === true ||
      (toolPresentation === "bubble" && activity?.phase === "execution")
  );
  const active = presentations.filter((item) => item.state === "active");
  const errors = presentations.filter((item) => item.state === "error");
  const named = active.filter((item) => item.name);
  const router = named.find((item) => item.actorRole === "router");
  const workingProvider =
    !taskPresentations && errors.length === 0 ? active[0]?.workingProvider : undefined;
  const summary = workingProvider
    ? {
        wechat: messages.chat_activity_working_wechat,
        telegram: messages.chat_activity_working_telegram,
        signal: messages.chat_activity_working_signal,
      }[workingProvider]()
    : taskPresentations
      ? named.length === 1
        ? messages.chat_active_single({ name: named[0]!.name! })
        : named.length === 2
          ? messages.chat_active_pair({
              first: named[0]!.name!,
              second: named[1]!.name!,
            })
          : named.length > 2
            ? router
              ? messages.chat_active_router_workers({
                  router: messages.chat_actor_router(),
                  count: named.length - 1,
                })
              : messages.chat_active_workers({ count: named.length })
            : errors.map((item) => `${item.name} · ${item.label}`).join("; ")
      : (presentations[0]?.label ?? "");
  const visible = presentations.length > 0;
  const toolBubble = Boolean(
    !workingProvider && liveToolSummary && presentation?.state === "active"
  );
  const thinkingBubble = !toolBubble && errors.length === 0;
  const detail = presentations
    .map((item) => (item.name ? `${item.name} · ${item.label}` : item.label))
    .join("\n");

  return (
    <div
      className="comma-chat-activity-slot"
      data-active={visible ? "true" : "false"}
      data-presentation={toolBubble ? "tool-call" : undefined}
      data-tool-name={toolBubble ? activity?.toolName?.trim() : undefined}
      data-reserve-space={reserveSpace ? "true" : "false"}
      data-state={
        errors.length
          ? "error"
          : active.length
            ? "active"
            : presentation?.state === "waiting"
              ? "waiting"
              : participantStatus?.state
      }
      data-testid="participant-status-slot"
      title={detail || undefined}
    >
      <div className="comma-chat-activity-row" aria-hidden={!visible} inert={!visible}>
        {taskPresentations && active.length > 0 && errors.length === 0 ? (
          <div
            className="comma-chat-activity-avatars"
            style={{ "--comma-status-count": presentations.length } as CSSProperties}
            aria-hidden
          >
            {presentations.map((item, index) => {
              const isRouter = item.actorRole === "router" || !item.name;
              // Chat has one continuous reply mark. Changing from local feedback
              // to Participant/Activity authority must not remount its animation.
              // Tasks still identify each avatar by its actual participant.
              const avatarKey = taskPresentations ? item.key : "chat-reply";
              const avatarProps = {
                "data-participant-key": item.key,
                "data-actor-role": item.actorRole ?? (isRouter ? "router" : undefined),
                className:
                  "comma-chat-assistant-source-avatar comma-chat-activity-avatar",
                style: {
                  ...(!isRouter
                    ? workerMeshGradientStyle(item.actorId ?? item.key)
                    : {}),
                  "--comma-status-index": index,
                } as CSSProperties,
              };
              return isRouter ? (
                <span
                  key={avatarKey}
                  {...avatarProps}
                  className={`${avatarProps.className} comma-chat-assistant-router-mark`}
                >
                  <CommaLogoAnimation />
                </span>
              ) : (
                <span key={avatarKey} {...avatarProps} />
              );
            })}
          </div>
        ) : null}
        <div
          data-working-provider={workingProvider}
          className={
            thinkingBubble
              ? "comma-chat-thinking-bubble"
              : "comma-chat-activity-content"
          }
        >
          {thinkingBubble && !taskPresentations ? (
            workingProvider ? (
              <span className="comma-chat-channel-logos" aria-hidden>
                <span className="comma-chat-channel-logo">
                  <img
                    src={
                      {
                        wechat: wechatActivityLogo,
                        telegram: telegramActivityLogo,
                        signal: signalActivityLogo,
                      }[workingProvider]
                    }
                    alt=""
                  />
                </span>
                <span className="comma-chat-channel-comma">
                  <img src={commaActivityLogo} alt="" />
                </span>
              </span>
            ) : (
              <span
                className="comma-chat-thinking-logo"
                data-participant-key={presentations[0]?.key}
                aria-hidden
              >
                <CommaLogoAnimation paused={!visible || active.length === 0} />
              </span>
            )
          ) : null}
          <AiActivity
            // Keep one mounted activity through timestamp, text and participant
            // changes. Its existing text swap animates only a changed summary.
            activityKey={summary}
            className="comma-chat-activity-line"
            events={[]}
            shimmer={active.length > 0 && errors.length === 0}
            status={errors.length ? "failed" : active.length ? "running" : "complete"}
            summary={summary}
          />
        </div>
      </div>
    </div>
  );
}

// One trailing timer per shared status slot, not one per participant. Preserve
// the actual content through brief empty snapshots so avatars do not remount.
function useThinkingContinuity(items: SlotPresentation[], immediateHide: boolean) {
  const signature = JSON.stringify(items);
  const stable = useMemo(
    () => JSON.parse(signature) as SlotPresentation[],
    [signature]
  );
  const [retained, setRetained] = useState(stable);
  const hold =
    !immediateHide &&
    retained.length > 0 &&
    retained.every((item) => item.state === "active");
  useLayoutEffect(() => {
    if (stable.length || !hold) {
      setRetained(stable);
      return;
    }
    const timer = setTimeout(() => setRetained(stable), 180);
    return () => clearTimeout(timer);
  }, [stable, hold]);
  return stable.length || !hold ? stable : retained;
}

// A failed round can settle before the durable Participant projection arrives.
// Keep its source-bound terminal frame visible, but preserve the frame's exact
// summary authority: Activity lifecycle alone cannot identify a model failure.
function failedTurnPresentation(
  activity: ChatActivity | undefined,
  generationFailed: string,
  executionFailed: string
): SlotPresentation | undefined {
  if (activity?.status !== "failed") {
    return undefined;
  }

  const label =
    activity.phase === "thinking" && activity.summaryClass === "generic"
      ? generationFailed
      : activity.phase === "execution" && activity.summaryClass === "public"
        ? executionFailed
        : undefined;
  if (!label) return undefined;

  return {
    key: `activity:${activity.responseKey ?? ""}`,
    label,
    state: "error",
  };
}

// Participant status is the canonical, durable outcome and therefore wins
// over an Activity presentation frame. Its words come from the state and the
// stable issue code, never from the runtime's own status text.
function participantPresentation(
  participantStatus: ChatParticipantStatus | undefined,
  messages: ReturnType<typeof useCommaMessages>
): SlotPresentation | undefined {
  const label =
    participantStatus && participantStatusLabel(messages, participantStatus);
  if (!participantStatus || label === undefined) {
    return undefined;
  }

  return {
    key: `${participantStatus.conversationId}:${participantStatus.participantId}`,
    label,
    state: participantStatus.state,
  };
}
