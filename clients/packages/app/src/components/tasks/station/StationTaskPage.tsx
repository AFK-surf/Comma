import type {
  StationAttachment,
  StationCardState,
  StationChatAgent,
  StationChatMessage,
  StationOutgoing,
} from "@comma/core/contract";
import { useCall, useTopic, type CallFn } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { AiInput, type AiInputAttachment } from "@comma/ui/components/ai-input";
import { Badge } from "@comma/ui/components/Badge";
import { Button } from "@comma/ui/components/Button";
import { ChatPanelMessageItem } from "@comma/ui/components/chat-panel";
import { ContentHeader } from "@comma/ui/components/content-header";
import { Indicator } from "@comma/ui/components/indicator";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { StopIcon } from "@comma/ui/components/icons";
import { toast } from "@comma/ui/components/toast";
import { useEffect, useMemo, useRef, useState } from "react";
import type { TaskDetailsPopoverProps } from "../../chat/tasks/TaskDetailsPopover";
import {
  TaskPanelBody,
  TaskPanelFoldedTrigger,
  useTaskPanelFold,
} from "../../chat/tasks/TaskPanelFold";
import { StationCard } from "./StationCard";
import { agentStateText, deciderText } from "./stationWords";

/** The most a file may weigh to go up with a message. */
const uploadMaxBytes = 8 * 1024 * 1024;

/** How a post ended its agent's turn, as a small mark under it. */
export function TurnEndingBadge({ ending }: { ending: string | undefined }) {
  const messages = useCommaMessages();
  if (ending === "all_done") {
    return (
      <Badge color="success" dot size="sm">
        {messages.stations_ending_all_done()}
      </Badge>
    );
  }
  if (ending === "need_help" || ending === "need_human" || ending === "need_decision") {
    return (
      <Badge color="warning" dot size="sm">
        {messages.stations_ending_need_human()}
      </Badge>
    );
  }
  if (ending === "waiting") {
    return (
      <Badge color="gray" dot size="sm">
        {messages.stations_ending_waiting()}
      </Badge>
    );
  }
  return null;
}

function time(at: number) {
  return new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function AttachmentList({ attachments }: { attachments: StationAttachment[] }) {
  if (attachments.length === 0) return null;
  return (
    <ul className="m-0 flex list-none flex-wrap gap-sm p-0">
      {attachments.map((file) => (
        <li
          className="rounded-md border-[0.5px] border-primary bg-popup-secondary px-md py-xs text-xs text-secondary"
          key={file.path}
        >
          {file.name}
        </li>
      ))}
    </ul>
  );
}

/** How a card ended, in words; none while it waits. */
function cardStateText(
  messages: ReturnType<typeof useCommaMessages>,
  state: StationCardState | undefined
) {
  const outcome = state?.outcome;
  if (!state?.resolved || !outcome) return undefined;
  const name = (by: string | null) => by ?? messages.stations_card_you();
  if (outcome.kind === "chose")
    return messages.stations_card_chose({
      label: outcome.label,
      name: name(outcome.by),
    });
  if (outcome.kind === "replied")
    return messages.stations_card_replied({ name: name(outcome.by) });
  return messages.stations_card_replaced();
}

export interface StationsMessageRowProps {
  message: StationChatMessage;
  station: string;
  workspace: string;
  call: CallFn;
}

/** One message of a station chat, drawn with Comma's chat rows. */
export function StationsMessageRow({
  call,
  message,
  station,
  workspace,
}: StationsMessageRowProps) {
  const messages = useCommaMessages();
  if (message.kind === "system") {
    return (
      <p
        className="m-0 text-center text-xs text-tertiary"
        data-testid="station-task-system-message"
      >
        {message.text}
      </p>
    );
  }
  const where = { seq: message.seq, station, thread: message.thread, workspace };
  const outcome = cardStateText(messages, message.cardState);
  const card = message.card ? (
    <StationCard
      assignee={deciderText(messages, message.card)}
      card={message.card}
      decision={{
        resolved: message.cardState?.resolved ?? false,
        ...(message.cardState?.dismissed ? { dismissed: true } : {}),
        ...(outcome ? { text: outcome } : {}),
      }}
      onAnswer={(option) => call("stations.answer", { ...where, option })}
      onReply={(text) => call("stations.reply", { ...where, text })}
    />
  ) : null;
  if (message.kind === "agent") {
    return (
      <ChatPanelMessageItem
        message={{
          author: message.author,
          content: (
            <MarkdownStream
              className="text-sm leading-5"
              content={message.text}
              final
            />
          ),
          footer: (
            <div className="flex w-full flex-col gap-md">
              <AttachmentList attachments={message.attachments} />
              {card}
              <div className="flex items-center gap-sm text-xs text-tertiary">
                <time dateTime={new Date(message.createdAt).toISOString()}>
                  {time(message.createdAt)}
                </time>
                <TurnEndingBadge ending={message.ending} />
              </div>
            </div>
          ),
          id: `${message.thread}:${message.seq}`,
          kind: "assistant",
        }}
        testId="station-task-agent-message"
        variant="task"
      />
    );
  }
  return (
    <ChatPanelMessageItem
      message={{
        author: message.mine ? undefined : message.author,
        attachments: message.attachments.map((file) => ({
          id: file.path,
          label: file.name,
        })),
        content: <span className="whitespace-pre-wrap">{message.text}</span>,
        footer:
          message.waiting && message.mine ? (
            <span className="text-xs text-tertiary">
              {messages.stations_message_not_taken()}
            </span>
          ) : undefined,
        id: `${message.thread}:${message.seq}`,
        kind: "user",
      }}
      testId={message.mine ? "station-task-my-message" : "station-task-person-message"}
      variant={message.mine ? "conversation" : "task"}
    />
  );
}

function OutgoingRow({
  outgoing,
  onDiscard,
  onRetry,
}: {
  outgoing: StationOutgoing;
  onDiscard: () => void;
  onRetry: () => void;
}) {
  const messages = useCommaMessages();
  const failed = outgoing.state === "failed";
  return (
    <ChatPanelMessageItem
      message={{
        content: <span className="whitespace-pre-wrap">{outgoing.text}</span>,
        footer: (
          <div className="flex items-center gap-sm text-xs text-tertiary">
            {failed ? (
              <>
                <span className="text-error-primary">
                  {outgoing.error || messages.stations_outbox_failed()}
                </span>
                <Button hierarchy="link-gray" onPress={onRetry} size="xs">
                  {messages.stations_outbox_retry()}
                </Button>
                <Button hierarchy="link-gray" onPress={onDiscard} size="xs">
                  {messages.stations_outbox_discard()}
                </Button>
              </>
            ) : (
              <span>{messages.stations_outbox_sending()}</span>
            )}
          </div>
        ),
        id: outgoing.id,
        kind: "user",
      }}
      testId="station-task-outgoing-message"
    />
  );
}

/** The chat's agents as they stand now: at work (with a stop), waiting, or done. */
function AgentStrip({
  agents,
  call,
  station,
  workspace,
}: {
  agents: StationChatAgent[];
  call: CallFn;
  station: string;
  workspace: string;
}) {
  const messages = useCommaMessages();
  if (agents.length === 0) return null;
  return (
    <div className="flex flex-wrap items-center gap-md px-xs pb-sm text-xs text-secondary">
      {agents.map((agent) => {
        const running = agent.running;
        return (
          <span className="flex items-center gap-xs" key={agent.session}>
            <Indicator color={running ? "brand" : "gray"} pulse={running} size="sm" />
            <span className="font-medium text-primary">{agent.name}</span>
            <span>{agentStateText(messages, agent.state)}</span>
            {running ? (
              <Button
                aria-label={messages.stations_agent_stop()}
                hierarchy="tertiary-gray"
                iconLeading={<StopIcon />}
                onPress={() =>
                  void call("stations.stopAgent", {
                    session: agent.session,
                    station,
                    workspace,
                  }).catch((error: unknown) =>
                    toast.error(String((error as Error).message ?? error))
                  )
                }
                size="xs"
              >
                {messages.stations_agent_stop()}
              </Button>
            ) : null}
          </span>
        );
      })}
    </div>
  );
}

const readAsBase64 = (file: File) =>
  new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.addEventListener("load", () => {
      const url = String(reader.result ?? "");
      resolve(url.slice(url.indexOf(",") + 1));
    });
    reader.addEventListener("error", () =>
      reject(reader.error ?? new Error("read failed"))
    );
    reader.readAsDataURL(file);
  });

let nextAttachmentId = 0;

interface PendingAttachment {
  id: string;
  name: string;
  attachment?: StationAttachment;
  error?: string;
}

export interface StationTaskPageProps {
  workspace: string;
  station: string;
  thread: number;
}

/**
 * A Task a station hosts, read and written on the station itself: its timeline (people, agents and their cards, how
 * each turn ended), where it runs, and a composer that sends at any time, also while an agent is at work: the station
 * hands it to the agent as it runs.
 */
export function StationTaskPage({ station, thread, workspace }: StationTaskPageProps) {
  const messages = useCommaMessages();
  const call = useCall();
  const target = { thread };
  const { error, value } = useTopic({
    topic: "stationChat",
    workspace,
    station,
    thread: String(thread),
    session: "",
  });
  const stations = useTopic({ topic: "stations", workspace }).value?.stations;
  // A Task just made is not listed yet: the labels its station answered show until it is.
  const [justSet, setJustSet] = useState<string[]>();
  const groupId = useTopic({ topic: "workspace", prefer: workspace }).value?.workspace
    ?.groupId;
  const routeRef = useRef<HTMLElement>(null);
  const fold = useTaskPanelFold(routeRef, true);
  const listed = useTopic({ topic: "stationTasks", workspace }).value?.tasks.find(
    (task) => task.station === station && task.thread === String(thread)
  );
  const [draft, setDraft] = useState("");
  const [files, setFiles] = useState<PendingAttachment[]>([]);
  const fileInput = useRef<HTMLInputElement>(null);
  // The chat opens at its latest message and follows new ones while the
  // reader is at its end; scrolled up to read, it stays where they are.
  const viewport = useRef<HTMLDivElement>(null);
  const atEnd = useRef(true);
  const followEnd = () => {
    const element = viewport.current;
    if (element && atEnd.current) element.scrollTop = element.scrollHeight;
  };

  // Seen to its end while this window shows it: the station marks it read.
  const shownThread = value?.thread ?? null;
  const newest = value?.messages.at(-1)?.seq ?? 0;
  useEffect(() => {
    if (shownThread === null) return;
    const seen = () => {
      if (document.visibilityState !== "visible" || !atEnd.current) return;
      void call("stations.read", { station, thread: shownThread, workspace }).catch(
        () => undefined
      );
    };
    seen();
    document.addEventListener("visibilitychange", seen);
    return () => document.removeEventListener("visibilitychange", seen);
  }, [call, newest, shownThread, station, workspace]);

  const ready = files.every((file) => file.attachment || file.error);
  const attachments = useMemo<AiInputAttachment[]>(
    () =>
      files.map((file) => ({
        id: file.id,
        name: file.name,
        onRemove: () => setFiles((all) => all.filter((f) => f.id !== file.id)),
        state: file.error ? "error" : file.attachment ? "ready" : "loading",
        ...(file.error ? { detail: file.error } : {}),
      })),
    [files]
  );

  const upload = async (list: FileList | null) => {
    for (const file of Array.from(list ?? [])) {
      // The same file picked twice is two attachments.
      const id = `${file.name}:${(nextAttachmentId += 1)}`;
      if (file.size > uploadMaxBytes) {
        setFiles((all) => [
          ...all,
          { error: messages.stations_attachment_too_large(), id, name: file.name },
        ]);
        continue;
      }
      setFiles((all) => [...all, { id, name: file.name }]);
      try {
        const bytes = await readAsBase64(file);
        const attachment = await call("stations.upload", {
          bytes,
          name: file.name,
          station,
          workspace,
        });
        setFiles((all) => all.map((f) => (f.id === id ? { ...f, attachment } : f)));
      } catch (failure) {
        setFiles((all) =>
          all.map((f) =>
            f.id === id ? { ...f, error: (failure as Error).message } : f
          )
        );
      }
    }
  };

  const send = (text: string) => {
    const body = text.trim();
    const uploaded = files.flatMap((file) =>
      file.attachment ? [file.attachment] : []
    );
    if (!body && uploaded.length === 0) return;
    const kept = files;
    const dropped = files.filter((file) => file.error).map((file) => file.name);
    if (dropped.length > 0) {
      toast.warning(
        messages.stations_attachments_not_sent({ names: dropped.join(", ") })
      );
    }
    setDraft("");
    setFiles([]);
    // A message the station core took shows in the chat's outbox, failed or not;
    // one it never took comes back to the composer with the reason.
    void call("stations.send", {
      station,
      text: body,
      workspace,
      ...target,
      ...(uploaded.length > 0 ? { attachments: uploaded } : {}),
    }).catch((failure: unknown) => {
      setDraft((current) => current || body);
      setFiles((current) =>
        current.length > 0 ? current : kept.filter((f) => f.attachment)
      );
      toast.error(messages.stations_send_failed(), {
        description: (failure as Error).message || String(failure),
      });
    });
  };

  const title = value?.title ?? listed?.title ?? "";
  // A Task just made is not in the list yet (the station reports it to Comma soon after): its machine is named from
  // the workspace's stations meanwhile.
  const machine =
    listed?.machine?.name ?? stations?.find((s) => s.id === station)?.name ?? undefined;
  // Who made it: as the station reported it, else (a Task just made) whoever wrote its first message.
  const creator =
    listed?.createdBy ??
    value?.messages.find((m) => m.kind === "person")?.author ??
    undefined;
  // The Task page's details column, as a Salix Task has it: status, and where it runs.
  const panel: TaskDetailsPopoverProps = {
    conversation: {
      id: `station:${station}:${thread}`,
      labels: listed?.labels ?? justSet ?? [],
      status: listed?.status ?? "in_progress",
    },
    // Its labels are the Group's, kept by its station: changed while the machine is reached.
    groupId: groupId ?? "",
    ...(creator ? { creator } : {}),
    ...(value?.link?.state === "online"
      ? {
          onSetLabels: (labels: string[]) =>
            call("stations.setLabels", { labels, station, thread, workspace }).then(
              (answer) => setJustSet(answer.labels),
              (failure: unknown) =>
                toast.error(messages.station_task_labels_failed(), {
                  description: (failure as Error).message || String(failure),
                })
            ),
        }
      : {}),
    run: {
      place: {
        kind: "station",
        deviceId: listed?.device ?? station,
        ...(machine ? { name: machine } : {}),
      },
      ...(listed?.model || listed?.runtime
        ? {
            model: {
              kind: "runtime" as const,
              ...(listed.runtime ? { provider: listed.runtime } : {}),
              ...(listed.model ? { name: listed.model } : {}),
            },
          }
        : {}),
    },
    onSetStatus: (status) =>
      call("stations.setStatus", {
        station,
        status: status === "completed" ? "done" : "cancelled",
        thread,
        workspace,
      }).catch((failure: unknown) =>
        toast.error(messages.station_task_status_failed(), {
          description: (failure as Error).message || String(failure),
        })
      ),
  };
  return (
    <section
      aria-label={title || messages.stations_chat_region()}
      className="comma-chat-route flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
      data-testid="station-task"
      ref={routeRef}
    >
      <ContentHeader className="comma-chat-header">
        <div
          className="flex min-w-0 flex-1 items-center gap-sm"
          data-task-header="true"
        >
          <h1 className="comma-chat-title">{title}</h1>
          {value?.link && value.link.state !== "online" ? (
            <Badge color="gray" size="sm">
              {value.link.state === "offline"
                ? messages.station_task_offline()
                : messages.stations_link_connecting()}
            </Badge>
          ) : null}
        </div>
        <TaskPanelFoldedTrigger fold={fold} panel={panel} />
      </ContentHeader>
      <TaskPanelBody floatingTrigger={false} fold={fold} panel={panel}>
        <div className="flex min-h-0 flex-1 flex-col items-center pb-xl">
          <div className="min-h-0 w-full max-w-[calc(744px+var(--spacing-md))] flex-1">
            <ScrollArea
              className="size-full"
              contentClassName="flex min-h-full flex-col justify-end gap-2xl px-lg pb-xl pt-3xl"
              edgeEffect="none"
              onContentResize={followEnd}
              onScroll={(event) => {
                const element = event.currentTarget;
                atEnd.current =
                  element.scrollHeight - element.scrollTop - element.clientHeight < 48;
              }}
              onViewportResize={followEnd}
              orientation="vertical"
              ref={viewport}
            >
              {value?.more ? (
                <div className="flex justify-center">
                  <Button
                    hierarchy="secondary-gray"
                    onPress={() =>
                      void call("stations.older", { station, thread, workspace })
                    }
                    size="xs"
                  >
                    {messages.stations_chat_load_older()}
                  </Button>
                </div>
              ) : null}
              {error && !value ? (
                <p className="m-0 text-center text-sm text-error-primary" role="alert">
                  {error.message}
                </p>
              ) : null}
              {(value?.messages ?? []).map((message) => (
                <StationsMessageRow
                  call={call}
                  key={`${message.thread}:${message.seq}`}
                  message={message}
                  station={station}
                  workspace={workspace}
                />
              ))}
              {(value?.outbox ?? []).map((outgoing) => (
                <OutgoingRow
                  key={outgoing.id}
                  onDiscard={() =>
                    shownThread !== null &&
                    void call("stations.discard", {
                      id: outgoing.id,
                      station,
                      thread: shownThread,
                      workspace,
                    })
                  }
                  onRetry={() =>
                    shownThread !== null &&
                    void call("stations.retry", {
                      id: outgoing.id,
                      station,
                      thread: shownThread,
                      workspace,
                    })
                  }
                  outgoing={outgoing}
                />
              ))}
            </ScrollArea>
          </div>
          <div className="w-full max-w-[744px] shrink-0">
            <AgentStrip
              agents={value?.agents ?? []}
              call={call}
              station={station}
              workspace={workspace}
            />
            <input
              aria-hidden
              className="hidden"
              multiple
              onChange={(event) => {
                void upload(event.target.files);
                event.target.value = "";
              }}
              ref={fileInput}
              tabIndex={-1}
              type="file"
            />
            <div className="comma-chat-composer-shell">
              <AiInput
                className="comma-chat-composer"
                size="small"
                attachLabel={messages.stations_composer_attach()}
                attachments={attachments}
                onAttachPress={() => fileInput.current?.click()}
                onSubmit={send}
                onValueChange={setDraft}
                placeholder={messages.stations_composer_placeholder()}
                sendLabel={messages.stations_composer_send()}
                showAccessButton={false}
                showAttachButton
                showVoiceButton={false}
                submitDisabled={!ready || (draft.trim() === "" && files.length === 0)}
                value={draft}
              />
            </div>
          </div>
        </div>
      </TaskPanelBody>
    </section>
  );
}

/**
 * The page of a Task a station hosts (`/tasks/$workspaceId/station/$station/$thread`). An app that reaches no station
 * (the web app, a phone) says where to open it instead.
 */
export function StationTaskRoute({
  station,
  thread,
  workspace,
}: {
  station: string;
  thread: string;
  workspace: string;
}) {
  const messages = useCommaMessages();
  const home = useTopic({ topic: "stationsHome" }).value;
  const number = Number(thread);
  if (home?.state === "unavailable" || !Number.isSafeInteger(number))
    return (
      <p className="m-auto max-w-[480px] p-xl text-center text-sm text-tertiary">
        {messages.station_task_open_on_desktop()}
      </p>
    );
  return <StationTaskPage station={station} thread={number} workspace={workspace} />;
}
