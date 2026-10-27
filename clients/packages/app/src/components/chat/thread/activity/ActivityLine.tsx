import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { CommaLocale } from "@comma/i18n";
import { AiActivity } from "@comma/ui/components/ai-activity";
import { CommaLogoAnimation } from "@comma/ui/components/comma-mascot";
import { HoverPanel } from "@comma/ui/components/hover-card";
import { uiClock } from "@comma/ui/clock";
import {
  cloneElement,
  memo,
  useLayoutEffect,
  useMemo,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import type { ChatActivity, ChatParticipantStatus } from "@comma/core/chat";
import { FocusComputerUseScreen } from "../../../remote-screen/WorkerComputerUseScreen";
import { useRouterDisplayName } from "../../../router-identity/RouterIdentityProvider";
import { routerDisplayName } from "../../../router-identity/routerDisplayName";
import { withRouterNameSpacing } from "../../../router-identity/routerNameSpacing";
import type { ActivityFocus, ActivityFocusTask } from "./activityFocus";
import {
  ActivityFocusCard,
  activityFocusCardLabel,
  titledTasks,
  type TaskLink,
} from "./ActivityFocusCard";
import { stopNotice } from "../../../billing/fundingStops";
import { StopNoticeContent } from "../../../billing/StopNoticeContent";
import { participantStatusLabel } from "./participantStatusLabel";
import { clippedTaskTitle } from "./clippedTaskTitle";
import { toolActivityLabel } from "./toolActivityLabel";
import { WorkerModelMark } from "./WorkerModelMark";
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

export const ParticipantStatusSlot = memo(function ParticipantStatusSlot({
  activity,
  participantStatus,
  participantStatuses,
  reserveSpace = false,
  optimisticThinking = false,
  streaming = false,
  replyTimedOut = false,
  hasResponse = false,
  focus,
  taskLink,
  workerVendor,
  onSwitchRun,
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
  /** The Tasks behind the Router's work, or this chat's Workers while the Router is idle. */
  focus?: ActivityFocus | undefined;
  /**
   * This surface's link to a Task, as its Task chips use: a route link on Home.
   * The bubble becomes the link to the Task its line names.
   */
  taskLink?: TaskLink | undefined;
  /** In a Task: the maker of the model its Worker runs, whose mark stands for the Worker. */
  workerVendor?: string | undefined;
  /** In a Task the viewer may switch to another model: a way out of its Worker's stops. */
  onSwitchRun?: (() => void) | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const routerName = useRouterDisplayName();
  const generationFailed = messages.chat_generation_failed();
  const participant = participantPresentation(participantStatus, messages, locale);
  const taskPresentations = participantStatuses?.flatMap((taskParticipant) => {
    const presentation = participantPresentation(taskParticipant, messages, locale);
    return presentation
      ? [
          {
            ...presentation,
            // Participants snapshot the Agent name when they join; the
            // Router's current name comes from its identity.
            name:
              taskParticipant.actorRole === "router"
                ? routerName
                : routerDisplayName(taskParticipant.name, "Agent"),
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
  // Activity frames reach this chat only for its own input. While the owner
  // answers another Conversation, such as a Worker's report in a Task, a
  // retained frame is from an earlier round. A wait outlives the frame that
  // started it, so the Participant's structured wait words the whole wait.
  const routerActive =
    participantStatus?.state === "active" && participantStatus.loopWake !== true;
  const answersOtherConversation =
    routerActive && (participantStatus.workingConversationIds?.length ?? 0) > 0;
  const routerFocus =
    routerActive && focus && focus.mode !== "working" ? focus : undefined;
  const routerWaiting = routerActive && participantStatus.waiting === true;
  const waitedSeconds = useWaitedSeconds(
    routerActive ? participantStatus.waitStartedAt : undefined
  );
  const routerFocusLabel = routerFocus
    ? focusLabel(messages, routerFocus)
    : routerWaiting
      ? messages.chat_tool_wait()
      : undefined;
  const workerFocus =
    !routerActive && participantStatus?.state !== "error" && focus?.mode === "working"
      ? focus
      : undefined;
  const workerFocusLabel = workerFocus ? focusLabel(messages, workerFocus) : undefined;
  const liveActivity =
    !answersOtherConversation &&
    routerFocusLabel === undefined &&
    activity?.status === "running" &&
    participantStatus?.state !== "stopped" &&
    participantStatus?.loopWake !== true;
  // Tool work is worded here, in the reader's language, from the tool's
  // identity; the model's own label for its command comes first. The
  // producer's English summary only serves clients that cannot localize. A
  // tool without wording keeps the line it follows. A call still running
  // after its frame expired is named by the Participant's wait.
  const liveExecutionSummary =
    liveActivity && activity.phase === "execution" && activity.summaryClass === "public"
      ? activity.goal?.trim() ||
        toolActivityLabel(messages, activity.toolName, "running", activity.target)
      : !answersOtherConversation && routerFocusLabel === undefined && routerActive
        ? toolActivityLabel(messages, participantStatus.waitTool, "running")
        : undefined;
  // A source-bound Activity can end with the first send. The Participant
  // remains the authority for work that continues after that reply.
  const ongoingWork =
    hasResponse &&
    !streaming &&
    participantStatus?.state === "active" &&
    participantStatus.loopWake !== true;
  const fallbackSummary =
    routerFocusLabel ??
    (hasResponse
      ? messages.chat_activity_working()
      : messages.chat_activity_thinking());
  const activeSummary =
    streaming || (!hasResponse && liveActivity && activity.phase === "messaging")
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
    optimisticThinking && !hasResponse
      ? {
          actorRole: "router",
          key: "optimistic-thinking",
          label: messages.chat_activity_thinking(),
          state: "active",
        }
      : ((participant?.state === "error" ? participant : undefined) ??
        failedTurnPresentation(activity, generationFailed, executionFailed) ??
        (ongoingWork ||
        (!hasResponse &&
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
            : workerFocusLabel
              ? {
                  actorRole: "worker",
                  key: "task-workers",
                  label: workerFocusLabel,
                  state: "active",
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
      participantStatus?.loopWake === true
  );
  const active = presentations.filter((item) => item.state === "active");
  const errors = presentations.filter((item) => item.state === "error");
  const named = active.filter((item) => item.name);
  const router = named.find((item) => item.actorRole === "router");
  const workingProvider =
    !taskPresentations && errors.length === 0 ? active[0]?.workingProvider : undefined;
  // A lone stop the member fixes themselves (a funding stop, a model nothing
  // serves) names itself in the card, with what to do and the ways out.
  const stopped =
    errors.length === 1
      ? (participantStatuses ?? (participantStatus ? [participantStatus] : [])).find(
          (status) =>
            `${status.conversationId}:${status.participantId}` === errors[0]!.key
        )
      : undefined;
  const switchAction = onSwitchRun
    ? { label: messages.task_run_switch(), run: onSwitchRun }
    : undefined;
  const stoppedNotice = stopped && stopNotice(stopped, locale);
  // A Task's Worker stopped on its model: another model is a way out too.
  const notice =
    stoppedNotice && switchAction && stopped.actorRole === "worker"
      ? { ...stoppedNotice, actions: [...stoppedNotice.actions, switchAction] }
      : stoppedNotice;
  const statusSummary = workingProvider
    ? {
        wechat: messages.chat_activity_working_wechat,
        telegram: messages.chat_activity_working_telegram,
        signal: messages.chat_activity_working_signal,
      }[workingProvider]()
    : taskPresentations
      ? named.length > 0
        ? // Agent names are formatted into the copy; a CJK name sits flush.
          withRouterNameSpacing(
            named.length === 1
              ? messages.chat_active_single({ name: named[0]!.name! })
              : named.length === 2
                ? messages.chat_active_pair({
                    first: named[0]!.name!,
                    second: named[1]!.name!,
                  })
                : router
                  ? messages.chat_active_router_workers({
                      router: routerName,
                      count: named.length - 1,
                    })
                  : messages.chat_active_workers({ count: named.length })
          )
        : errors.map((item) => `${item.name} · ${item.label}`).join("; ")
      : (presentations[0]?.label ?? "");
  const summary = notice
    ? taskPresentations && errors[0]!.name
      ? `${errors[0]!.name} · ${notice.title}`
      : notice.title
    : statusSummary;
  const visible = presentations.length > 0;
  const thinkingBubble = errors.length === 0;
  // Avatars and the detail card belong to the Task work that the line names,
  // never to typing or local send feedback.
  const lead = presentations[0];
  const markedFocus =
    lead?.key === "task-workers"
      ? workerFocus
      : routerFocusLabel !== undefined && lead?.label === routerFocusLabel
        ? routerFocus
        : undefined;
  const cardFocus =
    thinkingBubble &&
    !taskPresentations &&
    markedFocus?.tasks.some((task) => task.title)
      ? markedFocus
      : undefined;
  // A Worker on Comma's own model shows the Comma mark, so the Task's avatars
  // draw that mark once: the Router's while it works, else the Worker's.
  const commaAvatar = presentations.find(isRouterAvatar) ?? presentations[0];
  const avatars =
    workerVendor === "comma" && commaAvatar ? [commaAvatar] : presentations;
  // A Worker at work may drive a computer; each one's screen shows beside the chat.
  const screenTasks = focus?.tasks.filter((task) => task.worker) ?? [];
  const detail = cardFocus
    ? ""
    : presentations
        .map((item) => (item.name ? `${item.name} · ${item.label}` : item.label))
        .join("\n");

  return (
    <div
      className="comma-chat-activity-slot"
      data-active={visible ? "true" : "false"}
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
            style={{ "--comma-status-count": avatars.length } as CSSProperties}
            aria-hidden
          >
            {avatars.map((item, index) => {
              const isRouter = isRouterAvatar(item);
              // Chat has one continuous reply mark. Changing from local feedback
              // to Participant/Activity authority must not remount its animation.
              // Tasks still identify each avatar by its actual participant.
              const avatarKey = taskPresentations ? item.key : "chat-reply";
              const avatarProps = {
                "data-participant-key": item.key,
                "data-actor-role": item.actorRole ?? (isRouter ? "router" : undefined),
                className:
                  "comma-chat-assistant-source-avatar comma-chat-activity-avatar",
                style: { "--comma-status-index": index } as CSSProperties,
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
                <WorkerModelMark
                  key={avatarKey}
                  {...avatarProps}
                  vendor={workerVendor}
                />
              );
            })}
          </div>
        ) : null}
        <ActivityBubble
          cardFocus={cardFocus}
          label={summary}
          className={
            thinkingBubble
              ? "comma-chat-thinking-bubble"
              : "comma-chat-activity-content"
          }
          taskLink={taskLink}
          workingProvider={workingProvider}
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
              <>
                {markedFocus?.mode !== "working" ? (
                  <span
                    className="comma-chat-thinking-logo"
                    data-participant-key={presentations[0]?.key}
                    aria-hidden
                  >
                    <CommaLogoAnimation paused={!visible || active.length === 0} />
                  </span>
                ) : null}
                {focusWorkers(markedFocus, markedFocus?.mode !== "working").map(
                  (worker) => (
                    <WorkerModelMark
                      key={worker.avatarId}
                      className="comma-chat-thinking-worker"
                      data-worker-avatar={worker.avatarId}
                      vendor={worker.vendor}
                    />
                  )
                )}
              </>
            )
          ) : null}
          <AiActivity
            // Keep one mounted activity through timestamp, text and participant
            // changes. Its existing text swap animates only a changed summary;
            // the time a wait has lasted ticks in place.
            activityKey={summary}
            className="comma-chat-activity-line"
            events={[]}
            notice={notice ? <StopNoticeContent notice={notice} /> : undefined}
            shimmer={active.length > 0 && errors.length === 0}
            status={errors.length ? "failed" : active.length ? "running" : "complete"}
            summary={
              routerFocusLabel !== undefined && summary === routerFocusLabel
                ? withWaited(
                    messages,
                    summary,
                    routerWaiting && routerFocus?.mode !== "following"
                      ? waitedSeconds
                      : undefined
                  )
                : liveExecutionSummary !== undefined &&
                    summary === liveExecutionSummary &&
                    participantStatus?.waitTool
                  ? withElapsed(messages, summary, waitedSeconds)
                  : summary
            }
          />
        </ActivityBubble>
      </div>
      {focus
        ? screenTasks.map((task) => (
            <FocusComputerUseScreen
              conversationId={task.conversationId}
              groupId={focus.groupId}
              key={task.conversationId}
              participantId={task.worker!.participantId}
            />
          ))
        : null}
    </div>
  );
});

/**
 * The status bubble. With Task work to show, it is this surface's link to the
 * Task that its line names, like a Task chip in the transcript. Hovering or
 * focusing it opens the card, whose rows open each Task.
 */
function ActivityBubble({
  cardFocus,
  children,
  className,
  label,
  taskLink,
  workingProvider,
}: {
  cardFocus: ActivityFocus | undefined;
  children: ReactNode;
  className: string;
  /** Browsers do not name a link or button from the live status region inside it. */
  label: string;
  taskLink: TaskLink | undefined;
  workingProvider: ChatParticipantStatus["workingProvider"];
}) {
  const messages = useCommaMessages();
  const named = cardFocus && titledTasks(cardFocus)[0];
  const link = named && taskLink?.(named);
  if (!cardFocus || !link) {
    return (
      <div data-working-provider={workingProvider} className={className}>
        {children}
      </div>
    );
  }
  return (
    <HoverPanel
      content={<ActivityFocusCard focus={cardFocus} taskLink={taskLink!} />}
      label={activityFocusCardLabel(messages, cardFocus)}
    >
      {cloneElement(link, {
        "aria-label": label,
        className: [className, link.props.className].filter(Boolean).join(" "),
        "data-interactive": "true",
        "data-working-provider": workingProvider,
        children,
      } as Partial<typeof link.props>)}
    </HoverPanel>
  );
}

function isRouterAvatar(item: SlotPresentation) {
  return item.actorRole === "router" || !item.name;
}

// At most two Worker avatars sit beside the Router mark, as in the channel capsule.
// A Worker on Comma's own model shows the Comma mark, so the bubble draws that
// mark once: beside the Router's mark, or a second Comma Worker, it would only
// repeat it.
function focusWorkers(focus: ActivityFocus | undefined, routerMark: boolean) {
  const workers = new Map<string, NonNullable<ActivityFocusTask["worker"]>>();
  let commaMark = routerMark;
  for (const task of focus ? titledTasks(focus) : []) {
    if (!task.worker || workers.has(task.worker.avatarId)) continue;
    if (task.worker.vendor === "comma") {
      if (commaMark) continue;
      commaMark = true;
    }
    workers.set(task.worker.avatarId, task.worker);
  }
  return [...workers.values()].slice(0, 2);
}

/**
 * The line for Task work, in the reader's language. A Task without a resolved
 * title has no line yet: the caller keeps its generic copy. Worker names stay
 * out of the line: the avatars stand for them and the card names them.
 */
function focusLabel(
  messages: ReturnType<typeof useCommaMessages>,
  focus: ActivityFocus
): string | undefined {
  // A Task without a title is one this reader cannot see yet: it is not named
  // or counted, and the card does not list it either.
  const titled = titledTasks(focus);
  const [first] = titled;
  const count = titled.length;
  const title = first?.title ? clippedTaskTitle(first.title) : undefined;
  switch (focus.mode) {
    case "following":
      if (!title) return undefined;
      return count > 1
        ? messages.chat_activity_following_tasks({ count })
        : messages.chat_activity_following_task({ title });
    case "waiting": {
      if (!title) return messages.chat_tool_wait();
      // A Worker that stopped with an error is not finishing anything: say
      // so, until it runs again or the Router is told.
      const failed = titled.filter((task) => task.worker?.failed === true);
      if (failed.length) {
        return count > 1
          ? messages.chat_activity_waiting_tasks_failed()
          : messages.chat_activity_waiting_task_failed({ title });
      }
      return count > 1
        ? messages.chat_activity_waiting_tasks({ count })
        : messages.chat_activity_waiting_task({ title });
    }
    case "working":
      if (!title) return undefined;
      return count > 1
        ? messages.chat_activity_worker_tasks({ count })
        : messages.chat_activity_worker_task({ title });
  }
}

// A wait shorter than this reads as the step itself; a longer one shows how
// long it has lasted, so a reader can see it is not stuck.
const WAITED_SHOWN_AFTER_SECONDS = 5;

function withWaited(
  messages: ReturnType<typeof useCommaMessages>,
  label: string,
  seconds: number | undefined
): string {
  if (seconds === undefined || seconds < WAITED_SHOWN_AFTER_SECONDS) return label;
  return seconds < 60
    ? messages.chat_activity_waited_seconds({ label, seconds })
    : messages.chat_activity_waited_minutes({
        label,
        minutes: Math.floor(seconds / 60),
      });
}

// A tool call that runs long shows how long it has run.
function withElapsed(
  messages: ReturnType<typeof useCommaMessages>,
  label: string,
  seconds: number | undefined
): string {
  if (seconds === undefined || seconds < WAITED_SHOWN_AFTER_SECONDS) return label;
  return seconds < 60
    ? messages.chat_activity_elapsed_seconds({ label, seconds })
    : messages.chat_activity_elapsed_minutes({
        label,
        minutes: Math.floor(seconds / 60),
      });
}

// Whole seconds since the wait began, by the server's start and this clock.
function useWaitedSeconds(startedAt: number | undefined): number | undefined {
  const [now, setNow] = useState(() => uiClock.now());
  useLayoutEffect(() => {
    if (startedAt === undefined) return;
    setNow(uiClock.now());
    return uiClock.every(1_000, () => setNow(uiClock.now()));
  }, [startedAt]);
  return startedAt === undefined
    ? undefined
    : Math.max(0, Math.floor((now - startedAt) / 1_000));
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
    const timer = uiClock.after(180, () => setRetained(stable));
    return () => timer();
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
  messages: ReturnType<typeof useCommaMessages>,
  locale: CommaLocale
): SlotPresentation | undefined {
  const label =
    participantStatus && participantStatusLabel(messages, participantStatus, locale);
  if (!participantStatus || label === undefined) {
    return undefined;
  }

  return {
    key: `${participantStatus.conversationId}:${participantStatus.participantId}`,
    label,
    state: participantStatus.state,
  };
}
